import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/formats.dart';

void main() {
  final info = jsonDecode(File('test/fixtures/info-sample.json').readAsStringSync()) as Map<String, dynamic>;
  final meta = deriveMeta('jNQXAC9IVRw', info);

  test('deriveMeta: audio, variantes avc1 y huecos', () {
    expect(meta.title, isNotNull);
    expect(meta.duration, greaterThan(0));
    expect(meta.m4a?.formatId, '140');
    expect(meta.opus?.formatId, '251');
    expect(meta.hls, isNull);
    expect(meta.video.map((v) => v.height), [144, 240, 360]);
    expect(meta.video.last.formatId, '134');
    expect(meta.gaps, isEmpty);
  });

  test('Meta se guarda y se lee igual', () {
    final back = Meta.fromJson(jsonDecode(jsonEncode(meta.toJson())) as Map);
    expect(back.video.map((v) => v.formatId), meta.video.map((v) => v.formatId));
    expect(back.m4a?.bytes, meta.m4a?.bytes);
    expect(back.duration, meta.duration);
  });

  test('selectFormats: mp4 toma la mayor altura ≤ la pedida, o la más baja', () {
    expect(selectFormats(meta, OutFormat.mp4, 720)!.formatSel, '134+140');
    expect(selectFormats(meta, OutFormat.mp4, 240)!.formatSel, '133+140');
    expect(selectFormats(meta, OutFormat.mp4, bestQuality)!.height, 360);
    expect(selectFormats(meta, OutFormat.mp4, 720)!.bytes, 500000 + 300000);
  });

  test('selectFormats: audio', () {
    expect(selectFormats(meta, OutFormat.m4a, null)!.formatSel, '140');
    expect(selectFormats(meta, OutFormat.m4a, null)!.transcode, isFalse);
    // mp3 y wav parten del de mayor bitrate (opus 135 > aac 129)
    expect(selectFormats(meta, OutFormat.mp3, 192)!.formatSel, '251');
  });

  test('sin m4a: m4a recodifica desde opus y no hay mp4', () {
    final f = (info['formats'] as List).where((x) => x['format_id'] != '140' && x['format_id'] != '139').toList();
    final m = deriveMeta('x', {...info, 'formats': f});
    expect(m.gaps, contains('no_m4a'));
    expect(selectFormats(m, OutFormat.m4a, null)!.transcode, isTrue);
    expect(selectFormats(m, OutFormat.mp4, 720), isNull);
  });

  test('las pistas 5.1 y las DRC no se eligen para convertir', () {
    final f = [
      ...(info['formats'] as List),
      {'format_id': '258', 'ext': 'm4a', 'protocol': 'https', 'vcodec': 'none', 'acodec': 'mp4a.40.2', 'abr': 384, 'audio_channels': 6, 'url': 'https://r.googlevideo.com/v?itag=258'},
      {'format_id': '380', 'ext': 'mp4', 'protocol': 'https', 'vcodec': 'none', 'acodec': 'ac-3', 'abr': 384, 'audio_channels': 6, 'url': 'https://r.googlevideo.com/v?itag=380'},
      {'format_id': '140-drc', 'ext': 'm4a', 'protocol': 'https', 'vcodec': 'none', 'acodec': 'mp4a.40.2', 'abr': 129.5, 'audio_channels': 2, 'url': 'https://r.googlevideo.com/v?itag=140'},
    ];
    final m = deriveMeta('x', {...info, 'formats': f});
    expect(m.m4a?.formatId, '140');
    expect(selectFormats(m, OutFormat.mp3, 192)!.formatSel, '251');
    expect(rankAudioSources({...info, 'formats': f}).map((s) => s.formatId), isNot(contains('258')));
  });

  test('estimateBytes', () {
    expect(estimateBytes(meta, OutFormat.mp3, 128), (128000 / 8 * meta.duration).round());
    expect(estimateBytes(meta, OutFormat.wav, null), 44100 * 4 * meta.duration + 44);
    expect(estimateBytes(meta, OutFormat.m4a, null), 300000);
  });

  test('normalizeQuality', () {
    expect(normalizeQuality(OutFormat.mp3, 999), 192);
    expect(normalizeQuality(OutFormat.mp4, bestQuality), bestQuality);
    expect(normalizeQuality(OutFormat.wav, 320), isNull);
  });

  test('rankAudioSources: AAC primero, sin cabeceras de cookies', () {
    final a = rankAudioSources(info);
    expect(a.first.formatId, '140');
    expect(a.first.mime, 'audio/mp4');
    expect(a.map((s) => s.formatId), containsAll(['140', '139', '251']));
    expect(a.first.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
    expect(rankAudioSources(info, opus: true).first.formatId, '251');
  });

  test('videoRenditions: avc1 https de googlevideo por calidad', () {
    final v = videoRenditions(info);
    expect(v.map((r) => r.formatId), ['160', '133', '134']);
    expect(videoRenditions(info, maxHeight: 240).map((r) => r.formatId), ['160', '133']);
  });

  test('genericSelector', () {
    expect(genericSelector(OutFormat.mp4, 480), startsWith('bv*[vcodec^=avc1][ext=mp4][height<=480]+ba[ext=m4a]'));
    expect(genericSelector(OutFormat.mp3, 192), 'ba/b');
  });

  test('infoExpiresAt lee expire= de las URLs', () {
    expect(infoExpiresAt(info), 1999999999);
  });
}
