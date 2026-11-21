import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/dash.dart';
import 'package:setube/core/formats.dart';

Uint8List box(String type, [int payload = 0]) {
  final b = ByteData(8 + payload);
  b.setUint32(0, 8 + payload);
  for (var i = 0; i < 4; i++) {
    b.setUint8(4 + i, type.codeUnitAt(i));
  }
  return b.buffer.asUint8List();
}

Uint8List concat(List<Uint8List> parts) => Uint8List.fromList([for (final p in parts) ...p]);

void main() {
  test('ftyp + moov + sidx: rangos de init e índice', () {
    final ftyp = box('ftyp', 16);
    final moov = box('moov', 700);
    final sidx = box('sidx', 120);
    final data = concat([ftyp, moov, sidx, box('moof', 50), box('mdat', 500)]);
    final r = parseMp4Layout(data);
    expect(r.layout, isNotNull);
    final initEnd = ftyp.length + moov.length - 1;
    expect(r.layout!.initEnd, initEnd);
    expect(r.layout!.indexStart, initEnd + 1);
    expect(r.layout!.indexEnd, initEnd + sidx.length);
  });

  test('si el sidx no cabe pide más bytes', () {
    final data = concat([box('ftyp', 16), box('moov', 5000)]);
    final r = parseMp4Layout(Uint8List.sublistView(data, 0, 1024));
    expect(r.layout, isNull);
    expect(r.needBytes, greaterThan(1024));
  });

  test('archivos sin sidx o que no empiezan por ftyp no valen', () {
    expect(parseMp4Layout(concat([box('ftyp', 8), box('moov', 10), box('moof', 10)])).layout, isNull);
    expect(parseMp4Layout(concat([box('moov', 10)])).needBytes, isNull);
  });

  test('MPD con variantes, audio y URIs internas escapadas', () {
    StreamSource src(String id, String mime, {int? h, int? w, String codecs = 'avc1.4d401f'}) =>
        StreamSource(formatId: id, url: 'https://x.googlevideo.com/v?a=1&b=2', headers: const {}, mime: mime, codecs: codecs, height: h, width: w, tbr: 500, fps: 30);
    const l = Mp4Layout(initEnd: 731, indexStart: 732, indexEnd: 1999);
    final mpd = buildMpd(
      videoId: 'jNQXAC9IVRw',
      durationSec: 19,
      video: [DashRep(src('134', 'video/mp4', h: 360, w: 640), l), DashRep(src('136', 'video/mp4', h: 720, w: 1280), l)],
      audio: DashRep(src('140-drc', 'audio/mp4', codecs: 'mp4a.40.2'), l),
    );
    expect(mpd, contains('mediaPresentationDuration="PT19S"'));
    expect(mpd, contains('<Representation id="136" bandwidth="500000" codecs="avc1.4d401f" width="1280" height="720" frameRate="30">'));
    expect(mpd, contains('<BaseURL>setube://media/jNQXAC9IVRw/140-drc</BaseURL>'));
    expect(mpd, contains('indexRange="732-1999"'));
    expect(mpd, contains('<Initialization range="0-731"/>'));
    expect(mpd, isNot(contains('googlevideo')));
    expect('<Period'.allMatches(mpd).length, 1);
  });
}
