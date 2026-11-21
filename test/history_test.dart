import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/format.dart';
import 'package:setube/state/history.dart';

HistoryEntry entry({String kind = 'zip', int count = 12, String format = 'mp3', List<HistoryItem> items = const [], String name = 'x.zip', String path = 'Download/Setube'}) =>
    HistoryEntry(
      id: 'x',
      createdAt: DateTime(2026, 11, 21, 14, 5),
      kind: kind,
      name: name,
      uri: 'content://x',
      relativePath: path,
      mime: format == 'mp4' ? 'video/mp4' : (kind == 'zip' ? 'application/zip' : 'audio/mpeg'),
      bytes: 120000000,
      format: format,
      count: count,
      failed: 0,
      items: items,
    );

void main() {
  final now = DateTime(2026, 11, 21, 20, 0);

  test('días legibles', () {
    expect(friendlyDay(DateTime(2026, 11, 21, 9), now: now), 'Hoy');
    expect(friendlyDay(DateTime(2026, 11, 20, 23), now: now), 'Ayer');
    expect(friendlyDay(DateTime(2026, 11, 17), now: now), 'Martes');
    expect(friendlyDay(DateTime(2026, 11, 2), now: now), '2 de noviembre');
    expect(friendlyDay(DateTime(2025, 3, 2), now: now), '2 de marzo de 2025');
  });

  test('hora como en WhatsApp', () {
    expect(friendlyTime(DateTime(2026, 1, 1, 14, 5)), '2:05 p. m.');
    expect(friendlyTime(DateTime(2026, 1, 1, 0, 30)), '12:30 a. m.');
    expect(shortDate(DateTime(2026, 11, 21)), '21 nov 2026');
  });

  test('ZIP: título con cantidad y contenido', () {
    final e = entry(items: const [
      HistoryItem(videoId: 'a', title: 'Monaco'),
      HistoryItem(videoId: 'b', title: 'Me at the zoo'),
      HistoryItem(videoId: 'c', title: 'Otra'),
    ]);
    expect(entryTitle(e), '12 canciones en MP3');
    expect(entryContents(e), 'Monaco, Me at the zoo y 10 más');
    expect(entryDetails(e), 'ZIP · 2:05 p. m. · 120,0 MB');
    expect(savedMessage(e), '12 canciones guardadas en Descargas/Setube (ZIP)');
  });

  test('canción suelta: su título y el canal', () {
    final e = entry(kind: 'file', count: 1, name: 'Monaco.mp3', path: 'Music/Setube', items: const [HistoryItem(videoId: 'a', title: 'MONACO', author: 'Bad Bunny')]);
    expect(entryTitle(e), 'MONACO');
    expect(entryContents(e), 'Bad Bunny');
    expect(entryDetails(e), 'Canción MP3 · 2:05 p. m. · 120,0 MB');
    expect(friendlyPath(e.relativePath), 'Música/Setube');
    expect(savedMessage(e), 'Canción guardada en Música/Setube');
    expect(entryTitle(entry(kind: 'file', name: 'Video viejo.mp4', format: 'mp4')), 'Video viejo');
  });
}
