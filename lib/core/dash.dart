// Video en la app: los formatos adaptativos de YouTube (video avc1 sin audio y audio AAC) son MP4 fragmentados
// con un índice `sidx` al principio. Con el rango del init (ftyp + moov) y el del sidx se arma un MPD de DASH
// «on demand» y ExoPlayer pide cada fragmento con un rango cerrado. Es la misma idea del HLS de la API,
// pero aquí el troceo lo hace el reproductor a partir del sidx.

import 'dart:typed_data';

import 'formats.dart';

class Mp4Layout {
  const Mp4Layout({required this.initEnd, required this.indexStart, required this.indexEnd});

  /// Último byte (inclusivo) de ftyp + moov.
  final int initEnd;

  /// Primer y último byte (inclusivos) del sidx.
  final int indexStart;
  final int indexEnd;
}

/// Resultado de leer la cabecera: el layout, o cuántos bytes hacen falta para encontrar el sidx.
class LayoutResult {
  const LayoutResult.found(Mp4Layout this.layout) : needBytes = null;
  const LayoutResult.needMore(int this.needBytes) : layout = null;
  const LayoutResult.invalid()
      : layout = null,
        needBytes = null;
  final Mp4Layout? layout;
  final int? needBytes;
}

/// Recorre las cajas de primer nivel de `head` (los primeros bytes del archivo).
LayoutResult parseMp4Layout(Uint8List head) {
  final bd = ByteData.sublistView(head);
  var off = 0;
  int? moovEnd;
  var sawFtyp = false;
  while (off + 8 <= head.length) {
    var size = bd.getUint32(off);
    final type = String.fromCharCodes(head.sublist(off + 4, off + 8));
    var header = 8;
    if (size == 1) {
      if (off + 16 > head.length) return LayoutResult.needMore(off + 16);
      final hi = bd.getUint32(off + 8);
      final lo = bd.getUint32(off + 12);
      size = hi * 0x100000000 + lo;
      header = 16;
    } else if (size == 0) {
      return const LayoutResult.invalid();
    }
    if (size < header) return const LayoutResult.invalid();
    if (off == 0 && type != 'ftyp') return const LayoutResult.invalid();
    if (type == 'ftyp') sawFtyp = true;
    if (type == 'moov') moovEnd = off + size - 1;
    if (type == 'sidx') {
      if (!sawFtyp || moovEnd == null) return const LayoutResult.invalid();
      return LayoutResult.found(Mp4Layout(initEnd: moovEnd, indexStart: off, indexEnd: off + size - 1));
    }
    if (type == 'moof' || type == 'mdat') return const LayoutResult.invalid();
    off += size;
  }
  return LayoutResult.needMore(off + 8 > head.length ? off + 4096 : head.length * 2);
}

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// URI interna con la que el reproductor nativo pide un formato (la resuelve a la URL firmada de googlevideo).
String mediaUri(String videoId, String formatId) =>
    'setube://media/${Uri.encodeComponent(videoId)}/${Uri.encodeComponent(formatId)}';

class DashRep {
  const DashRep(this.source, this.layout);
  final StreamSource source;
  final Mp4Layout layout;
}

int _bandwidth(StreamSource s, int durationSec) {
  if (s.tbr != null && s.tbr! > 0) return (s.tbr! * 1000).round();
  if (s.size != null && durationSec > 0) return (s.size! * 8 / durationSec).round();
  if (s.abr != null && s.abr! > 0) return (s.abr! * 1000).round();
  return 1000000;
}

String _segmentBase(Mp4Layout l) =>
    '<SegmentBase indexRange="${l.indexStart}-${l.indexEnd}" indexRangeExact="true">'
    '<Initialization range="0-${l.initEnd}"/></SegmentBase>';

/// MPD estático con las variantes de video y una pista de audio.
String buildMpd({required String videoId, required int durationSec, required List<DashRep> video, required DashRep audio}) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>')
    ..write('<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" '
        'type="static" minBufferTime="PT2S" mediaPresentationDuration="PT${durationSec > 0 ? durationSec : 1}S">')
    ..write('<Period id="0" start="PT0S">')
    ..write('<AdaptationSet id="0" contentType="video" mimeType="video/mp4" segmentAlignment="true" '
        'subsegmentAlignment="true" subsegmentStartsWithSAP="1">');
  for (final r in video) {
    final s = r.source;
    b.write('<Representation id="${_xml(s.formatId)}" bandwidth="${_bandwidth(s, durationSec)}" '
        'codecs="${_xml(s.codecs)}"');
    if (s.width != null) b.write(' width="${s.width}"');
    if (s.height != null) b.write(' height="${s.height}"');
    if (s.fps != null && s.fps! > 0) b.write(' frameRate="${s.fps!.round()}"');
    b.write('><BaseURL>${_xml(mediaUri(videoId, s.formatId))}</BaseURL>${_segmentBase(r.layout)}</Representation>');
  }
  b.write('</AdaptationSet>');
  final a = audio.source;
  b
    ..write('<AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" lang="und" subsegmentAlignment="true" '
        'subsegmentStartsWithSAP="1">')
    ..write('<Representation id="${_xml(a.formatId)}" bandwidth="${_bandwidth(a, durationSec)}" '
        'codecs="${_xml(a.codecs)}" audioSamplingRate="44100">')
    ..write('<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>')
    ..write('<BaseURL>${_xml(mediaUri(videoId, a.formatId))}</BaseURL>${_segmentBase(audio.layout)}</Representation>')
    ..write('</AdaptationSet></Period></MPD>');
  return b.toString();
}
