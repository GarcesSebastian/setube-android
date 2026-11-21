// Envío al PC con LocalSend: el PC guardado, el envío en curso y el envío automático al terminar.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../native/bridge.dart';
import 'history.dart';

class PcDevice {
  const PcDevice(this.raw);
  final Map<String, dynamic> raw;
  String get alias => '${raw['alias'] ?? 'PC'}';
  String get ip => '${raw['ip'] ?? ''}';
  bool get isDesktop => raw['type'] == null || raw['type'] == 'desktop';
  String? get model => raw['model'] as String?;
}

class PcTransfer {
  const PcTransfer(this.m);
  final Map<String, dynamic> m;
  String get status => '${m['status']}';
  String get name => '${m['name'] ?? ''}';
  String get pc => '${m['pc'] ?? 'el PC'}';
  int get sent => (m['sent'] as num?)?.toInt() ?? 0;
  int get total => (m['total'] as num?)?.toInt() ?? 0;
  int get files => (m['files'] as num?)?.toInt() ?? 0;
  int get filesTotal => (m['filesTotal'] as num?)?.toInt() ?? 0;
  int get pending => (m['pending'] as num?)?.toInt() ?? 0;
  double get bps => (m['bps'] as num?)?.toDouble() ?? 0;
  String? get code => m['code'] as String?;
  bool get active => status == 'queued' || status == 'connecting' || status == 'sending';
  double get fraction => total > 0 ? sent / total : 0;
}

String pcErrorText(String? code) => switch (code) {
      'rejected' => 'El PC rechazó el envío.',
      'busy' => 'El PC está recibiendo otra cosa. Intenta en un momento.',
      'pin' => 'LocalSend del PC pide un PIN. Quítalo en sus ajustes.',
      'pc_changed' => 'El PC guardado cambió. Vuelve a buscarlo en Ajustes.',
      'unreachable' => 'No se encontró el PC. Abre LocalSend en el PC y conéctalo a la misma Wi‑Fi.',
      'no_pc' => 'Primero elige el PC en Ajustes.',
      'canceled' => 'Envío cancelado.',
      _ => 'Se cortó la conexión con el PC. Intenta de nuevo.',
    };

/// Carpeta propuesta: «12 canciones del 21 nov 2026» o «Canciones del 21 nov 2026».
String defaultFolder(HistoryEntry e) {
  final video = e.format == 'mp4' || e.mime.startsWith('video');
  final date = shortDate(e.createdAt);
  if (e.kind == 'zip') return '${e.count} ${video ? 'videos' : 'canciones'} del $date';
  return '${video ? 'Videos' : 'Canciones'} del $date';
}

/// Lo mismo que limpia Kotlin: sin los caracteres que Windows no admite en carpetas.
String cleanFolderName(String s) => s
    .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');

class PcModel extends ChangeNotifier {
  PcModel() {
    _sub = PcNative.events().listen((e) {
      transfer = PcTransfer(e);
      notifyListeners();
    });
    unawaited(load());
  }

  StreamSubscription<Map<String, dynamic>>? _sub;
  PcDevice? favorite;
  bool auto = false;
  PcTransfer? transfer;
  bool loaded = false;

  void _apply(Map<String, dynamic> s) {
    final f = s['favorite'];
    favorite = f is Map ? PcDevice(f.cast<String, dynamic>()) : null;
    auto = s['auto'] == true;
    loaded = true;
    notifyListeners();
  }

  Future<void> load() async {
    try {
      _apply(await PcNative.state());
    } catch (_) {}
  }

  Future<List<PcDevice>> discover() async => [for (final d in await PcNative.discover()) PcDevice(d)];

  Future<void> choose(PcDevice d) async => _apply(await PcNative.choose(d.raw));
  Future<void> forget() async => _apply(await PcNative.forget());
  Future<void> setAuto(bool on) async => _apply(await PcNative.setAuto(on));

  /// Envía la entrada al PC dentro de `folder` (una carpeta en el destino de LocalSend).
  Future<void> send(HistoryEntry e, {String? folder}) => PcNative.send(jsonEncode({...e.raw, 'pcFolder': folder ?? defaultFolder(e)}));
  Future<void> cancel() => PcNative.cancel();

  void dismiss() {
    transfer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
