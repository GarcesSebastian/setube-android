// Acceso a YouTube desde el teléfono: oEmbed por HTTP y el resto con yt-dlp (vía Kotlin).
// Cachea en memoria y en archivos de `cache/` lo mismo que la API guardaba en Redis.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/errors.dart';
import '../core/formats.dart';
import '../core/parse.dart';
import '../core/url.dart';
import '../native/bridge.dart';

class YtError implements Exception {
  const YtError(this.code, [this.detail]);
  final ErrCode code;
  final String? detail;
  @override
  String toString() => 'YtError(${code.name}${detail == null ? '' : ': $detail'})';
}

class OEmbed {
  const OEmbed({this.title, this.author});
  final String? title;
  final String? author;
}

const _metaTtl = Duration(hours: 6);
const _negativeTtl = Duration(minutes: 10);
const _infoTtl = Duration(hours: 3);
const _searchTtl = Duration(hours: 1);
const _playlistTtl = Duration(minutes: 30);
const _batch = 8;

class YouTube {
  YouTube._();
  static final instance = YouTube._();

  Directory? _cache;
  final _meta = <String, Meta>{};
  final _metaErr = <String, (ErrCode, DateTime)>{};
  final _pendingMeta = <String, Completer<Meta>>{};
  final _metaQueue = <String>[];
  var _metaRunning = 0;
  final _oembed = <String, OEmbed>{};
  final _search = <String, (SearchResult, DateTime)>{};
  final _playlists = <String, (PlaylistResult, DateTime)>{};
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<Directory> _dir(String name) async {
    _cache ??= await getTemporaryDirectory();
    final d = Directory('${_cache!.path}/$name');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Meta? cachedMeta(String videoId) => _meta[videoId];

  /// Metadata completa. Las peticiones de varios videos se juntan en un proceso de yt-dlp (dos a la vez).
  /// `priority` adelanta el video en la cola (lo que el usuario quiere escuchar ya).
  Future<Meta> meta(String videoId, {bool force = false, bool priority = false}) async {
    if (!force) {
      final m = _meta[videoId];
      if (m != null && DateTime.now().difference(m.fetchedAt) < _metaTtl) return m;
      final neg = _metaErr[videoId];
      if (neg != null && DateTime.now().difference(neg.$2) < _negativeTtl) throw YtError(neg.$1);
      final disk = await _readMeta(videoId);
      if (disk != null) return _meta[videoId] = disk;
    }
    final running = _pendingMeta[videoId];
    if (running != null) {
      if (priority && _metaQueue.remove(videoId)) {
        _metaQueue.insert(0, videoId);
        _pumpMeta(solo: true);
      }
      return running.future;
    }
    final c = Completer<Meta>();
    _pendingMeta[videoId] = c;
    if (priority) {
      _metaQueue.insert(0, videoId);
    } else {
      _metaQueue.add(videoId);
    }
    _pumpMeta(solo: priority);
    return c.future;
  }

  /// `solo`: el primer lote lleva solo el video prioritario, para que no espere a otros cuatro.
  Future<void> _pumpMeta({bool solo = false}) async {
    if (_metaRunning >= 3) return;
    _metaRunning++;
    try {
      var first = true;
      while (_metaQueue.isNotEmpty) {
        // Un instante para juntar los videos que se pegan a la vez
        if (!(solo && first)) await Future<void>.delayed(const Duration(milliseconds: 120));
        if (_metaQueue.isEmpty) break;
        final ids = _metaQueue.take(solo && first ? 1 : _batch).toList();
        first = false;
        _metaQueue.removeRange(0, ids.length);
        List<InfoResult> results;
        try {
          results = await Engine.info(ids, priority: solo && ids.length == 1);
        } catch (e) {
          for (final id in ids) {
            _pendingMeta.remove(id)?.completeError(YtError(ErrCode.engine, '$e'));
          }
          continue;
        }
        final byId = {for (final r in results) r.id: r};
        for (final id in ids) {
          final c = _pendingMeta.remove(id);
          final r = byId[id];
          if (c == null) continue;
          if (r == null || r.path == null) {
            final code = errCodeOf(r?.error);
            if (isDefinitive(code)) _metaErr[id] = (code, DateTime.now());
            c.completeError(YtError(r == null ? ErrCode.upstreamError : code, r?.message));
            continue;
          }
          try {
            final info = jsonDecode(await File(r.path!).readAsString()) as Json;
            final m = deriveMeta(id, info);
            _meta[id] = m;
            _metaErr.remove(id);
            unawaited(_writeMeta(m));
            c.complete(m);
          } catch (e) {
            c.completeError(YtError(ErrCode.upstreamError, '$e'));
          }
        }
      }
    } finally {
      _metaRunning--;
    }
  }

  Future<Meta?> _readMeta(String id) async {
    try {
      final f = File('${(await _dir('meta')).path}/$id.json');
      if (!f.existsSync()) return null;
      final m = Meta.fromJson(jsonDecode(await f.readAsString()) as Map);
      return DateTime.now().difference(m.fetchedAt) < _metaTtl ? m : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMeta(Meta m) async {
    try {
      await File('${(await _dir('meta')).path}/${m.videoId}.json').writeAsString(jsonEncode(m.toJson()));
    } catch (_) {}
  }

  /// Info JSON con las URLs firmadas, para reproducir. La de disco vale si no caducó.
  Future<Json> info(String videoId, {bool fresh = false}) async {
    final f = File('${(await _dir('info')).path}/$videoId.json');
    if (!fresh && f.existsSync() && DateTime.now().difference(f.lastModifiedSync()) < _infoTtl) {
      try {
        final info = jsonDecode(await f.readAsString()) as Json;
        final exp = infoExpiresAt(info);
        if (exp == null || exp - DateTime.now().millisecondsSinceEpoch ~/ 1000 > 1800) return info;
      } catch (_) {}
    }
    await meta(videoId, force: true, priority: true);
    return jsonDecode(await f.readAsString()) as Json;
  }

  Future<OEmbed> oembed(String videoId) async {
    final hit = _oembed[videoId];
    if (hit != null) return hit;
    try {
      final uri = Uri.https('www.youtube.com', '/oembed', {'format': 'json', 'url': watchUrl(videoId)});
      final req = await _http.getUrl(uri).timeout(const Duration(seconds: 8));
      req.headers.set('accept', 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) {
        final j = jsonDecode(body) as Map;
        return _oembed[videoId] = OEmbed(title: j['title'] as String?, author: j['author_name'] as String?);
      }
      if (res.statusCode == 404 || res.statusCode == 401 || res.statusCode == 403) {
        throw const YtError(ErrCode.videoUnavailable);
      }
    } on YtError {
      rethrow;
    } catch (_) {}
    return const OEmbed();
  }

  Future<SearchResult> search(String raw) async {
    final q = normalizeQuery(raw);
    if (q == null) return SearchResult(raw, const []);
    final key = q.toLowerCase();
    final hit = _search[key];
    if (hit != null && DateTime.now().difference(hit.$2) < _searchTtl) return SearchResult(q, hit.$1.items);
    final r = await _runJson(searchArgs(q));
    final res = toSearchResult(q, r, searchMaxResults);
    _search[key] = (res, DateTime.now());
    return res;
  }

  Future<PlaylistResult> playlist(String playlistId) async {
    final hit = _playlists[playlistId];
    if (hit != null && DateTime.now().difference(hit.$2) < _playlistTtl) return hit.$1;
    final Json raw;
    try {
      raw = await _runJson(playlistArgs(playlistId));
    } on YtError catch (e) {
      if (e.code == ErrCode.videoUnavailable ||
          e.code == ErrCode.privateVideo ||
          RegExp(r'playlist does not exist|playlist is private|playlist.*unavailable', caseSensitive: false)
              .hasMatch(e.detail ?? '')) {
        throw const YtError(ErrCode.playlistUnavailable);
      }
      rethrow;
    }
    final res = toPlaylistResult(playlistId, raw);
    if (res.items.isEmpty) throw const YtError(ErrCode.playlistEmpty);
    _playlists[playlistId] = (res, DateTime.now());
    return res;
  }

  Future<Json> _runJson(List<String> args) async {
    final RunResult r;
    try {
      r = await Engine.run(args);
    } catch (e) {
      throw YtError(ErrCode.engine, '$e');
    }
    if (!r.ok) throw YtError(classifyYtdlpError(r.err, exitCode: r.exit), r.err);
    try {
      return jsonDecode(r.out) as Json;
    } catch (_) {
      throw const YtError(ErrCode.upstreamError, 'invalid_json');
    }
  }
}
