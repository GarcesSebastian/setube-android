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
