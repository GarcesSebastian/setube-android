// Canales con la parte nativa (Kotlin): yt-dlp, sesión de YouTube, descargas en segundo plano,
// archivos guardados y reproductor.

import 'dart:async';

import 'package:flutter/services.dart';

const _engine = MethodChannel('setube/engine');
const _session = MethodChannel('setube/session');
const _downloads = MethodChannel('setube/downloads');
const _downloadEvents = EventChannel('setube/downloads/events');
const _player = MethodChannel('setube/player');
const _playerEvents = EventChannel('setube/player/events');
const _app = MethodChannel('setube/app');
const _pc = MethodChannel('setube/pc');
const _pcEvents = EventChannel('setube/pc/events');

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

class RunResult {
  const RunResult(this.exit, this.out, this.err);
  final int exit;
  final String out;
  final String err;
  bool get ok => exit == 0;
}

class InfoResult {
  const InfoResult({required this.id, this.path, this.error, this.message});
  final String id;
  final String? path;
  final String? error;
  final String? message;
}

class Engine {
  /// Extrae la info de varios videos en un solo proceso de yt-dlp. Kotlin guarda cada info JSON (sin campos
  /// pesados ni cookies) en `cache/info/<id>.json` y devuelve la ruta.
  static Future<List<InfoResult>> info(List<String> ids, {bool priority = false}) async {
    final r = _map(await _engine.invokeMethod('info', {'ids': ids, 'priority': priority}));
    return [
      for (final e in (r['results'] as List? ?? const []))
        if (e is Map)
          InfoResult(
            id: '${e['id']}',
            path: e['path'] as String?,
            error: e['code'] as String?,
            message: e['message'] as String?,
          ),
    ];
  }

  static Future<RunResult> run(List<String> args) async {
    final r = _map(await _engine.invokeMethod('run', {'args': args}));
    return RunResult((r['exit'] as num?)?.toInt() ?? 1, '${r['out'] ?? ''}', '${r['err'] ?? ''}');
  }

  static Future<Map<String, dynamic>> version() async => _map(await _engine.invokeMethod('version'));

  static Future<Map<String, dynamic>> update(String channel) async =>
      _map(await _engine.invokeMethod('update', {'channel': channel}));

  /// Informe de diagnóstico: yt-dlp verboso con un video de prueba, PO token, formatos y velocidad.
  static Future<String> diagnose({String videoId = 'aqz-KE-bpKQ'}) async =>
      '${await _engine.invokeMethod('diagnose', {'videoId': videoId}) ?? ''}';
}

class SessionStatus {
  const SessionStatus({
    this.loggedIn = false,
    this.count = 0,
    this.source = 'none',
    this.lastRefresh,
    this.mode = 'auto',
  });
  final bool loggedIn;
  final int count;

  /// `webview`, `imported` o `none`.
  final String source;
  final DateTime? lastRefresh;

  /// `auto` (solo si YouTube la pide), `always` u `off`.
  final String mode;

  static SessionStatus fromMap(Object? v) {
    final m = _map(v);
    final lr = (m['lastRefresh'] as num?)?.toInt() ?? 0;
    return SessionStatus(
      loggedIn: m['loggedIn'] == true,
      count: (m['count'] as num?)?.toInt() ?? 0,
      source: '${m['source'] ?? 'none'}',
      lastRefresh: lr > 0 ? DateTime.fromMillisecondsSinceEpoch(lr) : null,
      mode: '${m['mode'] ?? 'auto'}',
    );
  }
}

class Session {
  static Future<SessionStatus> status() async => SessionStatus.fromMap(await _session.invokeMethod('status'));
  static Future<SessionStatus> login() async => SessionStatus.fromMap(await _session.invokeMethod('login'));
  static Future<SessionStatus> logout() async => SessionStatus.fromMap(await _session.invokeMethod('logout'));

  /// Abre YouTube unos segundos en un WebView sin interfaz para que rote las cookies de la sesión.
  static Future<SessionStatus> refresh({bool force = false}) async =>
      SessionStatus.fromMap(await _session.invokeMethod('refresh', {'force': force}));
  static Future<SessionStatus> setMode(String mode) async =>
      SessionStatus.fromMap(await _session.invokeMethod('setMode', {'mode': mode}));
  static Future<SessionStatus> importCookies(String text) async =>
      SessionStatus.fromMap(await _session.invokeMethod('importCookies', {'text': text}));
}

class Downloads {
  static Stream<Map<String, dynamic>>? _events;

  static Stream<Map<String, dynamic>> events() =>
      _events ??= _downloadEvents.receiveBroadcastStream().map(_map).asBroadcastStream();

  static Future<void> enqueue(Map<String, dynamic> job) => _downloads.invokeMethod('enqueue', {'job': job});
  static Future<void> cancelJob(String jobId) => _downloads.invokeMethod('cancelJob', {'jobId': jobId});
  static Future<void> cancelItem(String jobId, String itemId) =>
      _downloads.invokeMethod('cancelItem', {'jobId': jobId, 'itemId': itemId});
  static Future<List<Map<String, dynamic>>> active() async =>
      [for (final e in (await _downloads.invokeMethod('active') as List? ?? const [])) _map(e)];

  static Future<List<Map<String, dynamic>>> history() async =>
      [for (final e in (await _downloads.invokeMethod('history') as List? ?? const [])) _map(e)];
  static Future<void> deleteHistory(String id, {required bool deleteFile}) =>
      _downloads.invokeMethod('deleteHistory', {'id': id, 'deleteFile': deleteFile});
  static Future<void> clearHistory() => _downloads.invokeMethod('clearHistory');
  static Future<List<bool>> exists(List<String> uris) async =>
      [for (final e in (await _downloads.invokeMethod('exists', {'uris': uris}) as List? ?? const [])) e == true];

  static Future<bool> open(String uri, String mime) async =>
      await _downloads.invokeMethod('open', {'uri': uri, 'mime': mime}) == true;
  static Future<bool> share(List<String> uris, String mime, {String? text}) async =>
      await _downloads.invokeMethod('share', {'uris': uris, 'mime': mime, 'text': text}) == true;
  static Future<bool> openFolder(String relativePath) async =>
      await _downloads.invokeMethod('openFolder', {'relativePath': relativePath}) == true;
}

class NativePlayer {
  static Stream<Map<String, dynamic>>? _events;

  static Stream<Map<String, dynamic>> events() =>
      _events ??= _playerEvents.receiveBroadcastStream().map(_map).asBroadcastStream();

  static Future<void> load(Map<String, dynamic> track) => _player.invokeMethod('load', track);
  static Future<void> play() => _player.invokeMethod('play');
  static Future<void> pause() => _player.invokeMethod('pause');
  static Future<void> seek(int ms) => _player.invokeMethod('seek', {'ms': ms});
  static Future<void> stop() => _player.invokeMethod('stop');
  static Future<void> setVolume(double v) => _player.invokeMethod('setVolume', {'volume': v});
  static Future<void> setNeighbors({required bool prev, required bool next}) =>
      _player.invokeMethod('setNeighbors', {'prev': prev, 'next': next});

  /// Crea la textura donde se pinta el video y devuelve su id para `Texture`.
  static Future<int> attachVideo() async => (await _player.invokeMethod('attachVideo') as num).toInt();
  static Future<void> detachVideo() => _player.invokeMethod('detachVideo');
}

/// Envío al PC con LocalSend.
class PcNative {
  static Stream<Map<String, dynamic>>? _events;

  static Stream<Map<String, dynamic>> events() =>
      _events ??= _pcEvents.receiveBroadcastStream().map(_map).asBroadcastStream();

  static Future<Map<String, dynamic>> state() async => _map(await _pc.invokeMethod('state'));
  static Future<List<Map<String, dynamic>>> discover() async =>
      [for (final e in (await _pc.invokeMethod('discover') as List? ?? const [])) _map(e)];
  static Future<Map<String, dynamic>> choose(Map<String, dynamic> device) async => _map(await _pc.invokeMethod('choose', device));
  static Future<Map<String, dynamic>> forget() async => _map(await _pc.invokeMethod('forget'));
  static Future<Map<String, dynamic>> setAuto(bool on) async => _map(await _pc.invokeMethod('setAuto', {'on': on}));
  static Future<void> send(String entryJson) => _pc.invokeMethod('send', {'entry': entryJson});
  static Future<void> cancel() => _pc.invokeMethod('cancel');
  static Future<void> installLink() => _pc.invokeMethod('installLink');
}

class AppNative {
  static Future<bool> requestNotifications() async => await _app.invokeMethod('requestNotifications') == true;
  static Future<void> keepScreenOn(bool on) => _app.invokeMethod('keepScreenOn', {'on': on});
  static Future<bool> openUrl(String url) async => await _app.invokeMethod('openUrl', {'url': url}) == true;

  /// Ruta (`history`) y texto compartido con los que se abrió la app.
  static Future<({String? route, String? shared})> initial() async {
    final m = _map(await _app.invokeMethod('initial'));
    return (route: m['route'] as String?, shared: m['shared'] as String?);
  }

  /// Avisos de la parte nativa con la app abierta: `route` (tocar una notificación) y `shared` (texto compartido).
  static void onCall(void Function(String method, String? arg) handler) {
    _app.setMethodCallHandler((call) async {
      handler(call.method, call.arguments as String?);
      return null;
    });
  }
}
