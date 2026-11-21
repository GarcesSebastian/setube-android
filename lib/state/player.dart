// Reproductor único: escucha o ve un video de la cola sin convertirlo. El audio y el video salen directo de
// googlevideo (las URLs están atadas a la IP del teléfono), sin servidor en medio.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/dash.dart';
import '../core/errors.dart';
import '../core/formats.dart';
import '../native/bridge.dart';
import '../services/youtube.dart';
import 'queue.dart';
import 'settings.dart';

enum PlayStatus { idle, loading, playing, paused, buffering, ended, error }

class Track {
  const Track({required this.key, required this.videoId, this.title, this.author, this.duration});
  final String key;
  final String videoId;
  final String? title;
  final String? author;
  final int? duration;
  String get thumbnail => 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';
  String get artwork => 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
}

class PlayerModel extends ChangeNotifier {
  PlayerModel(this.queue, this.settings) {
    _sub = NativePlayer.events().listen(_onEvent);
    queue.addListener(_syncNeighbors);
  }

  final QueueModel queue;
  final Settings settings;
  StreamSubscription<Map<String, dynamic>>? _sub;

  Track? track;
  PlayStatus status = PlayStatus.idle;

  /// `audio` o `video`: lo que suena ahora.
  String mode = 'audio';
  int positionMs = 0;
  int durationMs = 0;
  int bufferedMs = 0;
  int videoWidth = 0;
  int videoHeight = 0;
  int? textureId;
  double volume = 1;
  bool _triedOpus = false;
  int _loadSeq = 0;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  bool get hasTrack => track != null;
  bool get isPlaying => status == PlayStatus.playing || status == PlayStatus.buffering || status == PlayStatus.loading;
  bool get watching => mode == 'video' && track != null;

  @override
  void dispose() {
    _sub?.cancel();
    queue.removeListener(_syncNeighbors);
    super.dispose();
  }

  bool canPlay(QueueItem i) => i.metaState != MetaState.error && !(i.meta?.live ?? false);
  bool canWatch(QueueItem i) => canPlay(i) && (i.meta == null || i.meta!.canWatch);

  List<QueueItem> get _playable => queue.items.where(canPlay).toList();

  void _syncNeighbors() {
    final t = track;
    if (t == null) return;
    final list = _playable;
    final idx = list.indexWhere((i) => i.key == t.key);
    unawaited(NativePlayer.setNeighbors(prev: idx > 0, next: idx >= 0 && idx < list.length - 1));
  }

  QueueItem? neighbor(int delta) {
    final t = track;
    if (t == null) return null;
    final list = _playable;
    final idx = list.indexWhere((i) => i.key == t.key);
    final n = idx + delta;
    return idx < 0 || n < 0 || n >= list.length ? null : list[n];
  }

  Future<void> playItem(QueueItem i, {bool? video}) async {
    final wantVideo = video ?? (settings.playerMode == 'video' && canWatch(i));
    await _load(Track(key: i.key, videoId: i.videoId, title: i.title, author: i.author, duration: i.duration),
        video: wantVideo, positionMs: 0);
  }

  Future<void> toggle(QueueItem i) async {
    if (track?.key == i.key) {
      if (status == PlayStatus.playing || status == PlayStatus.buffering) {
        await NativePlayer.pause();
      } else if (status == PlayStatus.ended) {
        await NativePlayer.seek(0);
        await NativePlayer.play();
      } else {
        await NativePlayer.play();
      }
      return;
    }
    await playItem(i);
  }

  Future<void> playPause() async {
    if (track == null) return;
    if (status == PlayStatus.playing || status == PlayStatus.buffering) {
      await NativePlayer.pause();
    } else {
      if (status == PlayStatus.ended) await NativePlayer.seek(0);
      await NativePlayer.play();
    }
  }

  Future<void> seek(int ms) async {
    positionMs = ms;
    notifyListeners();
    await NativePlayer.seek(ms);
  }

  Future<void> skip(int deltaMs) => seek((positionMs + deltaMs).clamp(0, durationMs > 0 ? durationMs : 1 << 31));

  Future<void> next() async {
    final n = neighbor(1);
    if (n != null) await playItem(n, video: mode == 'video' && canWatch(n));
  }

  Future<void> prev() async {
    if (positionMs > 3000) return seek(0);
    final p = neighbor(-1);
    if (p != null) await playItem(p, video: mode == 'video' && canWatch(p));
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0, 1);
    notifyListeners();
    await NativePlayer.setVolume(volume);
  }

  Future<void> close() async {
    _loadSeq++;
    track = null;
    status = PlayStatus.idle;
    mode = 'audio';
    await _detach();
    notifyListeners();
    await NativePlayer.stop();
  }

  /// Cambia entre escuchar y ver sin perder el segundo.
  Future<void> setMode(String m) async {
    final t = track;
    if (t == null || m == mode) return;
    settings.playerMode = m;
    await _load(t, video: m == 'video', positionMs: positionMs);
  }

  Future<void> _detach() async {
    if (textureId != null) {
      textureId = null;
      await NativePlayer.detachVideo();
    }
  }

  Future<void> _load(Track t, {required bool video, required int positionMs}) async {
    final seq = ++_loadSeq;
    final sameTrack = track?.key == t.key;
    track = t;
    status = PlayStatus.loading;
    this.positionMs = positionMs;
    if (!sameTrack) {
      durationMs = (t.duration ?? 0) * 1000;
      bufferedMs = 0;
      _triedOpus = false;
    }
    notifyListeners();
    try {
      var info = await YouTube.instance.info(t.videoId);
      if (seq != _loadSeq) return;
      var audios = rankAudioSources(info);
      if (audios.isEmpty) {
        info = await YouTube.instance.info(t.videoId, fresh: true);
        if (seq != _loadSeq) return;
        audios = rankAudioSources(info);
      }
      if (audios.isEmpty) throw const YtError(ErrCode.formatUnavailable);
      final audio = audios.first;
      String? mpd;
      final sources = <StreamSource>[audio];
      if (video) {
        mpd = await _buildMpd(t.videoId, info, sources);
        if (seq != _loadSeq) return;
        if (mpd == null) {
          queue.toast(messageFor(ErrCode.videoUnsupported));
          video = false;
        }
      }
      if (video) {
        textureId ??= await NativePlayer.attachVideo();
      } else {
        await _detach();
      }
      if (seq != _loadSeq) {
        if (track == null || mode != 'video') await _detach();
        return;
      }
      mode = video ? 'video' : 'audio';
      final dur = info['duration'];
      await NativePlayer.load({
        'key': t.key,
        'videoId': t.videoId,
        'title': t.title ?? info['title'],
        'author': t.author ?? info['channel'] ?? info['uploader'],
        'artwork': t.artwork,
        'mode': mode,
        'positionMs': positionMs,
        'autoplay': true,
        'durationSec': dur is num ? dur.round() : 0,
        'audioFormat': audio.formatId,
        'mpd': mpd,
        'sources': [for (final s in sources) s.toJson()],
      });
      await NativePlayer.setVolume(volume);
      _syncNeighbors();
      notifyListeners();
    } on YtError catch (e) {
      if (seq != _loadSeq) return;
      status = PlayStatus.error;
      queue.toast(e.code == ErrCode.upstreamBlocked ? messageFor(e.code) : messageFor(ErrCode.playerError));
      notifyListeners();
    } catch (_) {
      if (seq != _loadSeq) return;
      status = PlayStatus.error;
      queue.toast(messageFor(ErrCode.playerError));
      notifyListeners();
    }
  }

  /// MPD con las variantes de video avc1 y el audio AAC. `null` si el video no se puede ver.
  Future<String?> _buildMpd(String videoId, Json info, List<StreamSource> out) async {
    final videos = videoRenditions(info);
    final aac = rankAudioSources(info).where((s) => s.mime == 'audio/mp4').toList();
    if (videos.isEmpty || aac.isEmpty) return null;
    final audio = aac.first;
    final heads = await Future.wait([audio, ...videos].map(_layoutOf));
    final aLayout = heads.first;
    if (aLayout == null) return null;
    final reps = <DashRep>[];
    for (var i = 0; i < videos.length; i++) {
      final l = heads[i + 1];
      if (l != null) reps.add(DashRep(videos[i], l));
    }
    if (reps.isEmpty) return null;
    out
      ..clear()
      ..add(audio)
      ..addAll(reps.map((r) => r.source));
    final dur = info['duration'];
    return buildMpd(
      videoId: videoId,
      durationSec: dur is num ? dur.round() : 0,
      video: reps,
      audio: DashRep(audio, aLayout),
    );
  }

  Future<Mp4Layout?> _layoutOf(StreamSource s) async {
    var want = 65536;
    for (var attempt = 0; attempt < 3; attempt++) {
      final bytes = await _head(s, want);
      if (bytes == null) return null;
      final r = parseMp4Layout(bytes);
      if (r.layout != null) return r.layout;
      if (r.needBytes == null || bytes.length < want) return null;
      want = r.needBytes! > want ? r.needBytes! : want * 4;
      if (want > 1 << 20) return null;
    }
    return null;
  }

  Future<Uint8List?> _head(StreamSource s, int n) async {
    try {
      final req = await _http.getUrl(Uri.parse(s.url)).timeout(const Duration(seconds: 10));
      s.headers.forEach(req.headers.set);
      req.headers.set('range', 'bytes=0-${n - 1}');
      req.headers.set('accept-encoding', 'identity');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 206 && res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final b = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 15))) {
        b.add(chunk);
        if (b.length >= n) break;
      }
      final all = b.takeBytes();
      return all.length > n ? Uint8List.sublistView(all, 0, n) : all;
    } catch (_) {
      return null;
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'state':
        if (track == null || e['key'] != track!.key) return;
        status = switch (e['state']) {
          'playing' => PlayStatus.playing,
          'paused' => PlayStatus.paused,
          'buffering' => PlayStatus.buffering,
          'ended' => PlayStatus.ended,
          'idle' => status == PlayStatus.loading ? PlayStatus.loading : PlayStatus.idle,
          _ => status,
        };
        if (status == PlayStatus.paused && e['playWhenReady'] == true) status = PlayStatus.buffering;
        positionMs = (e['positionMs'] as num?)?.toInt() ?? positionMs;
        final d = (e['durationMs'] as num?)?.toInt() ?? 0;
        if (d > 0) durationMs = d;
        bufferedMs = (e['bufferedMs'] as num?)?.toInt() ?? bufferedMs;
        videoWidth = (e['width'] as num?)?.toInt() ?? 0;
        videoHeight = (e['height'] as num?)?.toInt() ?? 0;
        notifyListeners();
        if (status == PlayStatus.ended) unawaited(next());
      case 'error':
        final t = track;
        if (t == null || e['key'] != t.key) return;
        if (e['mode'] == 'video') {
          // Si el video falla, se vuelve al audio en el mismo punto
          queue.toast(messageFor(ErrCode.videoUnsupported));
          unawaited(_load(t, video: false, positionMs: positionMs));
        } else if (!_triedOpus) {
          _triedOpus = true;
          unawaited(_reloadFresh(t));
        } else {
          status = PlayStatus.error;
          queue.toast(messageFor(ErrCode.playerError));
          notifyListeners();
        }
      case 'cmd':
        if (e['cmd'] == 'next') unawaited(next());
        if (e['cmd'] == 'prev') unawaited(prev());
    }
  }

  /// Segundo intento de audio: info nueva (las URLs pudieron caducar).
  Future<void> _reloadFresh(Track t) async {
    final seq = _loadSeq;
    try {
      await YouTube.instance.info(t.videoId, fresh: true);
    } catch (_) {}
    if (seq != _loadSeq || track?.key != t.key) return;
    await _load(t, video: false, positionMs: positionMs);
  }
}
