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
