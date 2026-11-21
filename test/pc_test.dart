import 'package:flutter_test/flutter_test.dart';
import 'package:setube/state/history.dart';
import 'package:setube/state/pc.dart';

HistoryEntry entry(String kind, String name) => HistoryEntry(
      id: 'x',
      createdAt: DateTime(2026, 11, 21, 14, 5),
      kind: kind,
      name: name,
      uri: 'content://x',
      relativePath: 'Download/Setube',
      mime: 'application/zip',
      bytes: 1,
      format: 'mp3',
      count: 3,
      failed: 0,
      items: const [],
    );

void main() {
  test('carpeta propuesta con fecha legible', () {
    expect(defaultFolder(entry('zip', 'Setube 2026-11-21 14.05 (3 canciones).zip')), '3 canciones del 21 nov 2026');
    expect(defaultFolder(entry('file', 'Canción.mp3')), 'Canciones del 21 nov 2026');
  });

  test('el nombre de carpeta queda válido en Windows', () {
    expect(cleanFolderName('  Bachata: 2026/éxitos?  '), 'Bachata 2026 éxitos');
    expect(cleanFolderName('Mis "temas" <dj>|'), 'Mis temas dj');
    expect(cleanFolderName('Salsa...'), 'Salsa');
    expect(cleanFolderName(r'..\..\Windows'), 'Windows');
    expect(cleanFolderName('   '), '');
  });
}
