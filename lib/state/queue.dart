// Cola de videos: links pegados, búsquedas, playlists, metadata, conversión y progreso.
// Mismo modelo que la web (queue.ts), pero el «servidor» es el servicio de descargas de Kotlin.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/formats.dart';
import '../core/parse.dart';
import '../core/url.dart';
import '../native/bridge.dart';
import '../services/youtube.dart';
import 'history.dart';
import 'pc.dart';
import 'settings.dart';

enum RowStatus { idle, queued, fetching, downloading, converting, done, error, canceled }

RowStatus _rowStatus(String? s) => switch (s) {
      'queued' => RowStatus.queued,
      'fetching' => RowStatus.fetching,
      'downloading' => RowStatus.downloading,
      'converting' => RowStatus.converting,
      'done' => RowStatus.done,
      'error' => RowStatus.error,
      'canceled' => RowStatus.canceled,
      _ => RowStatus.idle,
    };

enum MetaState { local, quick, full, error }

class QueueItem {
  QueueItem({required this.key, required this.videoId, this.listId, this.origin, this.title, this.duration});

  final String key;
  final String videoId;

  /// Playlist del link `watch?v=X&list=Y` (para «Agregar la playlist completa»).
  String? listId;

  /// Título de la playlist de la que vino.
  String? origin;
  String? title;
  String? author;
  int? duration;
  Meta? meta;
  MetaState metaState = MetaState.local;
  ErrCode? metaError;

  RowStatus status = RowStatus.idle;
  double pct = 0;
  double speed = 0;

  /// Velocidad de la conversión (× tiempo real) y datos de la última descarga, para enseñarlos en la fila.
  double conv = 0;
  int dlBytes = 0;
  int dlMs = 0;
  int convMs = 0;
  ErrCode? error;
  String? jobId;
  HistoryEntry? entry;

  String get url => watchUrl(videoId);
  String get thumbnail => thumbnailUrl(videoId);
  bool get active => const {RowStatus.queued, RowStatus.fetching, RowStatus.downloading, RowStatus.converting}.contains(status);
  bool get convertible => metaState != MetaState.error && !(meta?.live ?? false);
  bool get loadingMeta => metaState == MetaState.local || metaState == MetaState.quick;
}

class PlaylistCard {
  PlaylistCard({required this.key, required this.playlistId});
  final String key;
  final String playlistId;
  String? title;
  String? author;
  String? thumbnail;
  int? count;
  int skipped = 0;
  bool loading = true;
  ErrCode? error;
}

/// Resumen de la última tanda convertida, para la barra de abajo.
class RunSummary {
  const RunSummary({required this.ok, required this.total, required this.bytes, required this.avgBps, required this.elapsed});
  final int ok;
  final int total;
  final int bytes;
  final double avgBps;
  final Duration elapsed;
}

/// Lo que pasa ahora en la tanda: fase, velocidad de descarga, bytes bajados y velocidad de conversión.
class LiveRun {
  const LiveRun({
    required this.preparing,
    required this.downloading,
    required this.converting,
    required this.finished,
    required this.total,
    required this.speed,
    required this.bytes,
    required this.conv,
    required this.elapsed,
  });
  final int preparing;
  final int downloading;
  final int converting;
  final int finished;
  final int total;
  final double speed;
  final int bytes;
  final double conv;
  final Duration elapsed;
}

class Toast {
  const Toast(this.message, {this.action, this.onAction, this.secondary, this.onSecondary});
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;
}

class QueueModel extends ChangeNotifier {
  QueueModel(this.settings, this.history) {
    final o = settings.output;
    format = o.format;
    quality = o.quality;
    _sub = Downloads.events().listen(_onEvent);
  }

  final Settings settings;
  final HistoryModel history;

  /// Para enviar al PC al terminar (envío automático o botón del aviso).
  PcModel? pc;

  /// La interfaz pregunta la carpeta y envía (lo pone HomePage, que tiene el contexto).
  void Function(HistoryEntry)? onSendToPc;
  final _yt = YouTube.instance;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _rand = Random();

  final items = <QueueItem>[];
  final playlists = <PlaylistCard>[];
  OutFormat format = OutFormat.mp3;
  int? quality = 192;
  ({List<QueueItem> items, List<PlaylistCard> playlists})? _cleared;
  final _jobs = <String, Set<String>>{};

  /// Cada segundo mientras convierte, para el cronómetro de la barra (sin redibujar la cola entera).
  final clock = ValueNotifier<int>(0);
  Timer? _clockTimer;
  DateTime? _runStart;
  final _runKeys = <String>{};
  RunSummary? lastRun;

  void _startClock() {
    _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => clock.value++);
  }

  void _stopClock() {
    _clockTimer?.cancel();
    _clockTimer = null;
  }

  /// Avisos para la interfaz (snackbars).
  final toasts = StreamController<Toast>.broadcast();

  String _key() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 30).toRadixString(36)}';

  @override
  void dispose() {
    _stopClock();
    _notifyTimer?.cancel();
    clock.dispose();
    _sub?.cancel();
    toasts.close();
    super.dispose();
  }

  void _changed({bool persist = true}) {
    if (persist) settings.saveUrls([for (final i in items) i.listId == null ? i.url : '${i.url}&list=${i.listId}']);
    notifyListeners();
  }

  void toast(String m, {String? action, VoidCallback? onAction, String? secondary, VoidCallback? onSecondary}) =>
      toasts.add(Toast(m, action: action, onAction: onAction, secondary: secondary, onSecondary: onSecondary));

  // Salida

  void setFormat(OutFormat f) {
    if (f == format) return;
    final old = format;
    format = f;
    quality = normalizeQuality(f, f.isVideo == old.isVideo ? quality : null);
    settings.saveOutput(format, quality);
    notifyListeners();
  }

  void setKind(bool video) {
    if (video == format.isVideo) return;
    setFormat(video ? OutFormat.mp4 : OutFormat.mp3);
  }

  void setQuality(int? q) {
    quality = normalizeQuality(format, q);
    settings.saveOutput(format, quality);
    notifyListeners();
  }

  // Entrada

  /// Restaura la cola guardada al abrir la app y se reengancha a las descargas que siguen en curso
  /// (el servicio nativo sigue convirtiendo aunque se cierre la interfaz).
  Future<void> restore() async {
    var jobs = const <Map<String, dynamic>>[];
    try {
      jobs = await Downloads.active();
    } catch (_) {}
    try {
      for (final job in jobs) {
        if (job['status'] != 'active') continue;
        final jobId = '${job['jobId']}';
        final ids = <String>{};
        for (final raw in (job['items'] as List? ?? const [])) {
          final m = (raw as Map).cast<String, dynamic>();
          final videoId = '${m['videoId']}';
          if (!isVideoId(videoId) || contains(videoId)) continue;
          final it = QueueItem(key: '${m['itemId']}', videoId: videoId, title: m['title'] as String?)..jobId = jobId;
          items.add(it);
          ids.add(it.key);
          _onEvent({...m, 'jobId': jobId, 'type': 'item'});
          _loadMeta(it, skipOembed: it.title != null);
        }
        if (ids.isNotEmpty) _jobs[jobId] = ids;
      }
    } catch (_) {}
    final urls = settings.urls;
    if (urls.isNotEmpty) addLines(urls, quiet: true);
    // Lo que terminó con la interfaz cerrada (el servicio lo recuerda 10 min) no vuelve como pendiente
    for (final job in jobs) {
      if (job['status'] == 'active') continue;
      HistoryEntry? entry;
      try {
        final raw = job['entry'] as String?;
        if (raw != null) entry = HistoryEntry.fromJson(jsonDecode(raw) as Map);
      } catch (_) {}
      for (final raw in (job['items'] as List? ?? const [])) {
        final m = (raw as Map).cast<String, dynamic>();
        if (m['status'] != 'done') continue;
        for (final it in items.where((i) => i.videoId == m['videoId'] && i.status == RowStatus.idle)) {
          it
            ..status = RowStatus.done
            ..pct = 100
            ..entry = entry;
        }
      }
    }
    notifyListeners();
  }

  /// Agrega links (uno por línea). Devuelve las líneas no válidas para que se queden en el campo.
  List<String> addLines(List<String> lines, {bool quiet = false}) {
    final invalid = <String>[];
    var dup = 0;
    final seen = {for (final i in items) i.videoId};
    final seenLists = {for (final p in playlists) p.playlistId};
    final added = <QueueItem>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final p = parseYouTubeUrl(line);
      if (p == null) {
        invalid.add(line);
        continue;
      }
      if (p.kind == UrlKind.playlist) {
        if (seenLists.add(p.playlistId!)) {
          final card = PlaylistCard(key: _key(), playlistId: p.playlistId!);
          playlists.add(card);
          _loadPlaylist(card);
        } else {
          dup++;
        }
        continue;
      }
      if (!seen.add(p.videoId!)) {
        dup++;
        continue;
      }
      final it = QueueItem(key: _key(), videoId: p.videoId!, listId: p.playlistId);
      items.add(it);
      added.add(it);
    }
    for (final it in added) {
      _loadMeta(it);
    }
    if (!quiet) {
      if (invalid.isNotEmpty) {
        toast(invalid.length == 1 ? 'Esa línea no es un link de YouTube' : 'Estas líneas no son links de YouTube: ${invalid.length}');
      } else if (dup > 0 && added.isEmpty) {
        toast(dup == 1 ? 'Ese video ya está en la cola' : 'Esos videos ya están en la cola');
      }
    }
    _changed();
    return invalid;
  }

  bool contains(String videoId) => items.any((i) => i.videoId == videoId);

  void addSearchItem(SearchItem s) {
    if (contains(s.videoId)) return;
    final it = QueueItem(key: _key(), videoId: s.videoId, title: s.title, duration: s.duration)..author = s.author;
    items.add(it);
    _loadMeta(it, skipOembed: s.title != null);
    _changed();
  }

  Future<void> addPlaylist(String playlistId) async {
    if (playlists.any((p) => p.playlistId == playlistId)) return;
    final card = PlaylistCard(key: _key(), playlistId: playlistId);
    playlists.add(card);
    notifyListeners();
    await _loadPlaylist(card);
  }

  Future<void> _loadPlaylist(PlaylistCard card) async {
    try {
      final r = await _yt.playlist(card.playlistId);
      card
        ..title = r.title
        ..author = r.author
        ..thumbnail = r.thumbnail
        ..count = r.count
        ..skipped = r.skipped
        ..loading = false;
      final seen = {for (final i in items) i.videoId};
      final added = <QueueItem>[];
      for (final p in r.items) {
        if (!seen.add(p.videoId)) continue;
        final it = QueueItem(key: _key(), videoId: p.videoId, origin: r.title, title: p.title, duration: p.duration);
        items.add(it);
        added.add(it);
      }
      for (final it in added) {
        _loadMeta(it, skipOembed: it.title != null);
      }
    } on YtError catch (e) {
      card
        ..loading = false
        ..error = e.code;
    } catch (_) {
      card
        ..loading = false
        ..error = ErrCode.unknown;
    }
    _changed();
  }

  void removePlaylistCard(String key) {
    playlists.removeWhere((p) => p.key == key);
    notifyListeners();
  }

  Future<void> _loadMeta(QueueItem it, {bool skipOembed = false}) async {
    final cached = _yt.cachedMeta(it.videoId);
    if (cached != null) {
      _applyMeta(it, cached);
      notifyListeners();
      return;
    }
    if (!skipOembed) {
      try {
        final o = await _yt.oembed(it.videoId);
        it.title ??= o.title;
        it.author ??= o.author;
        if (it.metaState == MetaState.local) it.metaState = MetaState.quick;
        notifyListeners();
      } on YtError catch (e) {
        it
          ..metaState = MetaState.error
          ..metaError = e.code;
        notifyListeners();
        return;
      }
    } else {
      it.metaState = MetaState.quick;
    }
    await retryMeta(it);
  }

  Future<void> retryMeta(QueueItem it) async {
    if (it.metaState == MetaState.error) it.metaState = MetaState.quick;
    it.metaError = null;
    notifyListeners();
    try {
      final m = await _yt.meta(it.videoId);
      _applyMeta(it, m);
    } on YtError catch (e) {
      if (isDefinitive(e.code)) {
        it.metaState = MetaState.error;
      } else {
        // Transitorio: la fila sigue convertible (yt-dlp vuelve a intentarlo al descargar)
        it.metaState = MetaState.quick;
      }
      it.metaError = e.code;
    }
    notifyListeners();
  }

  void _applyMeta(QueueItem it, Meta m) {
    it
      ..meta = m
      ..title = m.title ?? it.title
      ..author = m.author ?? it.author
      ..duration = m.duration > 0 ? m.duration : it.duration
      ..metaState = m.live ? MetaState.error : MetaState.full
      ..metaError = m.live ? ErrCode.liveNotSupported : null;
  }

  QueueItem? byKey(String key) {
    for (final i in items) {
      if (i.key == key) return i;
    }
    return null;
  }

  void remove(String key) {
    final it = byKey(key);
    if (it == null) return;
    if (it.active && it.jobId != null) unawaited(Downloads.cancelItem(it.jobId!, it.key));
    final idx = items.indexOf(it);
    items.removeAt(idx);
    _changed();
    toast('Quitado de la cola', action: 'Deshacer', onAction: () {
      if (contains(it.videoId)) return;
      items.insert(min(idx, items.length), it);
      _changed();
    });
  }

  void clear() {
    if (items.isEmpty && playlists.isEmpty) return;
    cancel();
    _cleared = (items: [...items], playlists: [...playlists]);
    items.clear();
    playlists.clear();
    _changed();
    toast('Cola vaciada', action: 'Deshacer', onAction: undoClear);
  }

  void undoClear() {
    final c = _cleared;
    if (c == null) return;
    _cleared = null;
    for (final i in c.items) {
      if (!contains(i.videoId)) items.add(i);
    }
    playlists.addAll(c.playlists.where((p) => !playlists.any((q) => q.playlistId == p.playlistId)));
    _changed();
  }

  // Conversión

  bool get busy => items.any((i) => i.active);

  List<QueueItem> get pending =>
      items.where((i) => i.convertible && !i.active && !(i.status == RowStatus.done && i.entry != null)).toList();

  bool get canConvert => !busy && pending.isNotEmpty;

  /// Convierte lo pendiente; con varios videos el resultado es un ZIP.
  Future<void> convert({List<QueueItem>? only}) async {
    final list = (only ?? pending).where((i) => i.convertible && !i.active).toList();
    if (list.isEmpty) return;
    if (!settings.notificationsAsked) {
      settings.notificationsAsked = true;
      unawaited(AppNative.requestNotifications());
    }
    final jobId = _key();
    final payload = <Map<String, dynamic>>[];
    for (final it in list) {
      final m = it.meta;
      final sel = m == null ? null : selectFormats(m, format, quality);
      if (m != null && sel == null) {
        it
          ..status = RowStatus.error
          ..error = ErrCode.formatUnavailable;
        continue;
      }
      it
        ..status = RowStatus.queued
        ..pct = 0
        ..speed = 0
        ..conv = 0
        ..dlBytes = 0
        ..dlMs = 0
        ..convMs = 0
        ..error = null
        ..entry = null
        ..jobId = jobId;
      payload.add({
        'itemId': it.key,
        'videoId': it.videoId,
        'title': it.title,
        'author': it.author,
        'sel': sel?.formatSel,
        'bytes': sel?.bytes,
        'hls': sel?.hls ?? false,
      });
    }
    notifyListeners();
    if (payload.isEmpty) return;
    _jobs[jobId] = {for (final p in payload) p['itemId'] as String};
    if (_runKeys.isEmpty || _jobs.length == 1) {
      _runKeys.clear();
      _runStart = DateTime.now();
      lastRun = null;
    }
    _runKeys.addAll(_jobs[jobId]!);
    _startClock();
    try {
      await Downloads.enqueue({'jobId': jobId, 'format': format.name, 'quality': quality, 'items': payload});
    } catch (e) {
      for (final it in list) {
        if (it.jobId == jobId) {
          it
            ..status = RowStatus.error
            ..error = ErrCode.engine;
        }
      }
      notifyListeners();
    }
  }

  void cancel() {
    for (final id in _jobs.keys.toList()) {
      unawaited(Downloads.cancelJob(id));
    }
  }

  void retry(QueueItem it) => convert(only: [it]);

  Timer? _notifyTimer;

  /// Con cientos de filas llegan muchos eventos por segundo: se redibuja como mucho cada 150 ms.
  void _notifySoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 150), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'item') {
      final it = byKey('${e['itemId']}');
      if (it == null || it.jobId != e['jobId']) return;
      it
        ..status = _rowStatus(e['status'] as String?)
        ..pct = (e['pct'] as num?)?.toDouble() ?? it.pct
        ..speed = (e['speed'] as num?)?.toDouble() ?? 0
        ..conv = (e['conv'] as num?)?.toDouble() ?? it.conv
        ..dlBytes = (e['dlBytes'] as num?)?.toInt() ?? it.dlBytes
        ..dlMs = (e['dlMs'] as num?)?.toInt() ?? it.dlMs
        ..convMs = (e['convMs'] as num?)?.toInt() ?? it.convMs
        ..error = e['error'] == null ? null : errCodeOf(e['error'] as String);
      _notifySoon();
    } else if (e['type'] == 'job') {
      final jobId = '${e['jobId']}';
      final keys = _jobs.remove(jobId) ?? const <String>{};
      if (_jobs.isEmpty) _finishRun();
      final raw = e['entry'] as String?;
      HistoryEntry? entry;
      if (raw != null) {
        try {
          entry = HistoryEntry.fromJson(jsonDecode(raw) as Map);
        } catch (_) {}
      }
      if (entry != null) {
        history.add(entry);
        for (final k in keys) {
          final it = byKey(k);
          if (it != null && it.status == RowStatus.done) it.entry = entry;
        }
        final saved = entry;
        final where = savedMessage(saved);
        final pc = this.pc;
        if (pc != null && pc.auto && pc.favorite != null) {
          unawaited(pc.send(saved));
          toast('$where · enviando a ${pc.favorite!.alias}', action: 'Compartir', onAction: () => history.share(saved));
        } else if (pc != null && pc.favorite != null) {
          toast(
            where,
            action: 'Enviar al PC',
            onAction: () => onSendToPc != null ? onSendToPc!(saved) : pc.send(saved),
            secondary: 'Compartir',
            onSecondary: () => history.share(saved),
          );
        } else {
          toast(where, action: 'Compartir', onAction: () => history.share(saved), secondary: 'Abrir', onSecondary: () => history.open(saved));
        }
      } else if (e['status'] == 'failed') {
        toast('No se pudo convertir. Revisa los errores de cada video.');
      }
      notifyListeners();
    }
  }

  void _finishRun() {
    _stopClock();
    final its = [for (final k in _runKeys) ?byKey(k)];
    if (its.isNotEmpty && _runStart != null) {
      var bytes = 0, ms = 0;
      for (final i in its) {
        if (i.dlBytes > 0 && i.dlMs > 0) {
          bytes += i.dlBytes;
          ms += i.dlMs;
        }
      }
      lastRun = RunSummary(
        ok: its.where((i) => i.status == RowStatus.done).length,
        total: its.length,
        bytes: bytes,
        avgBps: ms > 0 ? bytes / (ms / 1000) : 0,
        elapsed: DateTime.now().difference(_runStart!),
      );
    }
    _runKeys.clear();
    _runStart = null;
  }

  LiveRun? get live {
    if (_runStart == null) return null;
    var prep = 0, dl = 0, cv = 0, fin = 0, total = 0, bytes = 0;
    var speed = 0.0, conv = 0.0;
    for (final k in _runKeys) {
      final i = byKey(k);
      if (i == null) continue;
      total++;
      bytes += i.dlBytes;
      if (i.status == RowStatus.fetching) prep++;
      if (i.status == RowStatus.done || i.status == RowStatus.error || i.status == RowStatus.canceled) fin++;
      if (i.status == RowStatus.downloading) {
        dl++;
        speed += i.speed;
      } else if (i.status == RowStatus.converting) {
        cv++;
        if (i.conv > conv) conv = i.conv;
      }
    }
    return LiveRun(
      preparing: prep,
      downloading: dl,
      converting: cv,
      finished: fin,
      total: total,
      speed: speed,
      bytes: bytes,
      conv: conv,
      elapsed: DateTime.now().difference(_runStart!),
    );
  }

  /// Progreso total de lo que está en curso o acaba de terminar.
  ({double pct, int done, int total, double speed}) get overall {
    final act = items.where((i) => i.jobId != null && _jobs.containsKey(i.jobId)).toList();
    if (act.isEmpty) return (pct: 0, done: 0, total: 0, speed: 0);
    var sum = 0.0;
    var done = 0;
    var speed = 0.0;
    for (final i in act) {
      if (i.status == RowStatus.downloading) speed += i.speed;
      final finished = i.status == RowStatus.done || i.status == RowStatus.error || i.status == RowStatus.canceled;
      if (finished) done++;
      sum += finished ? 100 : i.pct;
    }
    return (pct: sum / act.length, done: done, total: act.length, speed: speed);
  }

  /// Duración total y tamaño estimado de la cola para la salida elegida.
  ({int count, int duration, int bytes, int known}) get totals {
    var duration = 0, bytes = 0, known = 0, count = 0;
    for (final i in items) {
      if (!i.convertible) continue;
      count++;
      duration += i.duration ?? 0;
      final m = i.meta;
      final b = m == null ? null : estimateBytes(m, format, quality);
      if (b != null) {
        bytes += b;
        known++;
      }
    }
    return (count: count, duration: duration, bytes: bytes, known: known);
  }
}
