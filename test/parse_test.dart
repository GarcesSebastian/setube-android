import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/parse.dart';

void main() {
  test('búsqueda: solo videos, sin repetir, directos marcados', () {
    final r = toSearchResult('q', {
      'entries': [
        {'id': '_PJvpq8uOZM', 'title': 'BAD BUNNY - MONACO', 'channel': 'Bad Bunny', 'duration': 440.0, 'view_count': 249332660},
        {'id': '_PJvpq8uOZM', 'title': 'repetido'},
        {'id': 'UC38IQsAvIsxxjztdMZQtwHA', 'ie_key': 'YoutubeTab', 'title': 'canal'},
        {'id': 'jNQXAC9IVRw', 'title': 'live', 'live_status': 'is_live', 'uploader': 'x'},
      ],
    }, 20);
    expect(r.items.map((i) => i.videoId), ['_PJvpq8uOZM', 'jNQXAC9IVRw']);
    expect(r.items.first.duration, 440);
    expect(r.items.first.views, 249332660);
    expect(r.items.last.live, isTrue);
    expect(r.items.last.author, 'x');
  });

  test('playlist: cuenta ocultos y repetidos', () {
    final r = toPlaylistResult('PL1', {
      'title': 'Mix',
      'channel': 'Yo',
      'playlist_count': 4,
      'entries': [
        {'id': 'jNQXAC9IVRw', 'title': 'Me at the zoo', 'duration': 19},
        {'id': 'dQw4w9WgXcQ', 'title': '[Private video]'},
        {'id': 'bad'},
        {'id': 'jNQXAC9IVRw', 'title': 'otra vez'},
      ],
    });
    expect(r.items.length, 1);
    expect(r.skipped, 3);
    expect(r.count, 4);
    expect(r.title, 'Mix');
    expect(r.thumbnail, 'https://i.ytimg.com/vi/jNQXAC9IVRw/mqdefault.jpg');
  });

  test('argumentos: el texto va después de -- con prefijo fijo', () {
    final a = searchArgs('--exec rm');
    expect(a.sublist(a.length - 2), ['--', 'ytsearch20:--exec rm']);
  });
}
