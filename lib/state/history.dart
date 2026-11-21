// Registro de descargas: cada archivo o ZIP guardado, con acciones para abrirlo, ir a su carpeta y compartirlo.

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../native/bridge.dart';

class HistoryItem {
  const HistoryItem({required this.videoId, this.title, this.author});
  final String videoId;
  final String? title;
  final String? author;
}

class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.name,
    required this.uri,
    required this.relativePath,
    required this.mime,
    required this.bytes,
    required this.format,
    this.quality,
    required this.count,
    required this.failed,
    required this.items,
    this.raw = const {},
  });

  /// La entrada tal como la guardó Kotlin (para enviarla al PC).
  final Map raw;
  final String id;
  final DateTime createdAt;

  /// `file` o `zip`.
  final String kind;
  final String name;
  final String uri;
  final String relativePath;
  final String mime;
  final int bytes;
  final String format;
  final int? quality;
  final int count;
  final int failed;
  final List<HistoryItem> items;
  bool exists = true;

  static HistoryEntry fromJson(Map j) => HistoryEntry(
        id: '${j['id']}',
        createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num?)?.toInt() ?? 0),
        kind: '${j['kind'] ?? 'file'}',
        name: '${j['name'] ?? ''}',
        uri: '${j['uri'] ?? ''}',
        relativePath: '${j['relativePath'] ?? ''}',
        mime: '${j['mime'] ?? '*/*'}',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        format: '${j['format'] ?? ''}',
        quality: (j['quality'] as num?)?.toInt(),
        count: (j['count'] as num?)?.toInt() ?? 1,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        items: [
          for (final i in (j['items'] as List? ?? const []))
            if (i is Map) HistoryItem(videoId: '${i['videoId']}', title: i['title'] as String?, author: i['author'] as String?),
        ],
        raw: j,
      );
}

bool _isVideo(HistoryEntry e) => e.format == 'mp4' || e.mime.startsWith('video');

String _noun(HistoryEntry e, int n) => _isVideo(e) ? (n == 1 ? 'video' : 'videos') : (n == 1 ? 'canción' : 'canciones');

String _withoutExt(String name) => name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');

/// Título para el registro: «12 canciones en MP3» o el título de la canción.
String entryTitle(HistoryEntry e) {
  if (e.kind == 'zip') return '${e.count} ${_noun(e, e.count)} en ${e.format.toUpperCase()}';
  final t = e.items.isNotEmpty ? e.items.first.title : null;
  return (t != null && t.trim().isNotEmpty) ? t.trim() : _withoutExt(e.name);
}

/// Qué hay dentro de un ZIP: «Monaco, Me at the zoo y 10 más». `null` en archivos sueltos.
String? entryContents(HistoryEntry e) {
  if (e.kind != 'zip') return e.items.isNotEmpty ? e.items.first.author : null;
  final titles = [for (final i in e.items) if (i.title != null && i.title!.trim().isNotEmpty) i.title!.trim()];
  if (titles.isEmpty) return null;
  final shown = titles.take(2).join(', ');
  final rest = e.count - titles.take(2).length;
  return rest > 0 ? '$shown y $rest más' : shown;
}

/// «Canción MP3 · 2:05 p. m. · 5,1 MB» o «ZIP · 2:05 p. m. · 120 MB» (el día va en el encabezado del grupo).
String entryDetails(HistoryEntry e) {
  final kind = e.kind == 'zip' ? 'ZIP' : '${_isVideo(e) ? 'Video' : 'Canción'} ${e.format.toUpperCase()}';
  return [kind, friendlyTime(e.createdAt), if (e.bytes > 0) formatBytes(e.bytes)].join(' · ');
}

/// Carpeta del teléfono con nombres en español: «Música/Setube», «Películas/Setube», «Descargas/Setube».
String friendlyPath(String relativePath) => relativePath
    .replaceFirst(RegExp(r'^Music(?=/|$)'), 'Música')
    .replaceFirst(RegExp(r'^Movies(?=/|$)'), 'Películas')
    .replaceFirst(RegExp(r'^Download(?=/|$)'), 'Descargas');

/// Aviso al guardar: «12 canciones guardadas en Descargas/Setube (ZIP)».
String savedMessage(HistoryEntry e) => e.kind == 'zip'
    ? '${e.count} ${_noun(e, e.count)} guardadas en ${friendlyPath(e.relativePath)} (ZIP)'
    : '${_isVideo(e) ? 'Video guardado' : 'Canción guardada'} en ${friendlyPath(e.relativePath)}';

class HistoryModel extends ChangeNotifier {
  final entries = <HistoryEntry>[];
  bool loaded = false;

  Future<void> load() async {
    try {
      final raw = await Downloads.history();
      entries
        ..clear()
        ..addAll(raw.map(HistoryEntry.fromJson));
      loaded = true;
      notifyListeners();
      final uris = [for (final e in entries) e.uri];
      final ex = await Downloads.exists(uris);
      final byUri = {for (var i = 0; i < ex.length && i < uris.length; i++) uris[i]: ex[i]};
      for (final e in entries) {
        e.exists = byUri[e.uri] ?? e.exists;
      }
      notifyListeners();
    } catch (_) {
      loaded = true;
      notifyListeners();
    }
  }

  void add(HistoryEntry e) {
    entries.removeWhere((x) => x.id == e.id);
    entries.insert(0, e);
    notifyListeners();
  }

  Future<bool> open(HistoryEntry e) => Downloads.open(e.uri, e.mime);

  Future<bool> openFolder(HistoryEntry e) => Downloads.openFolder(e.relativePath);

  Future<bool> share(HistoryEntry e) => Downloads.share([e.uri], e.mime);

  Future<void> remove(HistoryEntry e, {required bool deleteFile}) async {
    entries.removeWhere((x) => x.id == e.id);
    notifyListeners();
    await Downloads.deleteHistory(e.id, deleteFile: deleteFile);
  }

  Future<void> clear() async {
    entries.clear();
    notifyListeners();
    await Downloads.clearHistory();
  }
}
