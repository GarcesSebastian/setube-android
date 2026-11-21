import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/url.dart';

void main() {
  group('parseYouTubeUrl (mismos casos que la web y la API)', () {
    final cases = jsonDecode(File('test/fixtures/url-cases.json').readAsStringSync()) as List;
    for (final c in cases) {
      final input = c['input'] as String;
      final exp = c['expected'] as Map?;
      test(input.isEmpty ? '(vacío)' : input, () {
        final r = parseYouTubeUrl(input);
        if (exp == null) {
          expect(r, isNull);
          return;
        }
        expect(r, isNotNull);
        expect(r!.kind.name, exp['kind']);
        expect(r.videoId, exp['videoId']);
        expect(r.playlistId, exp['playlistId']);
      });
    }
  });

  group('searchQuery', () {
    test('una línea que no es link se busca', () {
      expect(searchQuery('  bad   bunny monaco '), 'bad bunny monaco');
    });
    test('links y URLs de otros sitios no se buscan', () {
      expect(searchQuery('https://youtu.be/jNQXAC9IVRw'), isNull);
      expect(searchQuery('www.ejemplo.com/algo'), isNull);
      expect(searchQuery('ejemplo.com'), isNull);
    });
    test('varias líneas son links', () {
      expect(searchQuery('uno\ndos'), isNull);
    });
  });

  test('normalizeQuery quita controles y recorta a 100', () {
    expect(normalizeQuery('a\u0000b\n\nc'), 'a b c');
    expect(normalizeQuery('   '), isNull);
    expect(normalizeQuery('x' * 150)!.length, 100);
  });

  group('extractYouTubeLinks', () {
    const whatsapp = '''[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/LqkXOXf-es8?si=AeiFgb19STDsxE_2
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/J4ObGwlvwgk?si=-7r6giVa8yIMGQYH
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/m3rLhp8-VEQ?si=xRn8jfuDAHnfxshi
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/FaClXm22Pjg?si=PD-xM6wo-1ihn1dK
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/kr8xEPCZDgM?si=QOC8Fw2riVKf2-eK
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/icwzHEyH3GE?si=4UlNL4aueVSSV_Yx
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/jt0XOKnieMo?si=XcKqbexTGgfJyLs1
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/Bjh34NUvkYo?si=k4hJOeusZ2Oc7bl4
[2/3/2025, 2:19 p.m.] Papa: https://youtu.be/WtdcO4dbq3E?si=b3bJxwqRaUYWgCg0''';

    test('mensaje de WhatsApp: los 9 links, sin fechas ni nombres', () {
      final l = extractYouTubeLinks(whatsapp);
      expect(l.length, 9);
      expect(l.map((u) => parseYouTubeUrl(u)!.videoId), [
        'LqkXOXf-es8', 'J4ObGwlvwgk', 'm3rLhp8-VEQ', 'FaClXm22Pjg', 'kr8xEPCZDgM', 'icwzHEyH3GE', 'jt0XOKnieMo', 'Bjh34NUvkYo', 'WtdcO4dbq3E',
      ]);
      expect(onlyLinks(whatsapp), isFalse);
    });

    test('repetidos, puntuación pegada, sin https y otros sitios', () {
      final l = extractYouTubeLinks(
          'Mira esto (https://www.youtube.com/watch?v=dQw4w9WgXcQ). También youtu.be/dQw4w9WgXcQ, '
          'y este short: youtube.com/shorts/aqz-KE-bpKQ! Nada de https://notyoutube.com/watch?v=jNQXAC9IVRw ni https://vimeo.com/1 '
          'playlist: https://music.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG');
      expect(l.map((u) => parseYouTubeUrl(u)!.videoId ?? parseYouTubeUrl(u)!.playlistId),
          ['dQw4w9WgXcQ', 'aqz-KE-bpKQ', 'PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG']);
    });

    test('texto sin links y links solos', () {
      expect(extractYouTubeLinks('hola papá, ¿cómo estás?'), isEmpty);
      expect(onlyLinks('https://youtu.be/jNQXAC9IVRw\nhttps://youtu.be/dQw4w9WgXcQ'), isTrue);
    });
  });
}
