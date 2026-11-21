// Formatos de YouTube: qué hay en cada video, qué se descarga para cada salida, cuánto ocupa y qué se
// puede reproducir. Es el mismo criterio de la API (formats.ts), sin el servidor en medio.

enum OutFormat { mp3, m4a, wav, mp4 }

extension OutFormatX on OutFormat {
  bool get isVideo => this == OutFormat.mp4;
  String get ext => name;
  String get label => name.toUpperCase();
  String get mime => switch (this) {
        OutFormat.mp3 => 'audio/mpeg',
        OutFormat.m4a => 'audio/mp4',
        OutFormat.wav => 'audio/wav',
        OutFormat.mp4 => 'video/mp4',
      };
}

OutFormat? outFormatOf(String? s) {
  for (final f in OutFormat.values) {
    if (f.name == s) return f;
  }
  return null;
}

/// Calidad «Mejor» de mp4.
const int bestQuality = 0;
const mp3Qualities = [128, 192, 320];
const mp4Qualities = [360, 480, 720, 1080, bestQuality];

int? defaultQuality(OutFormat f) => switch (f) {
      OutFormat.mp3 => 192,
      OutFormat.mp4 => 720,
      _ => null,
    };

int? normalizeQuality(OutFormat f, int? q) {
  if (f == OutFormat.mp3) return mp3Qualities.contains(q) ? q : 192;
  if (f == OutFormat.mp4) return mp4Qualities.contains(q) ? q : 720;
  return null;
}

String qualityLabel(OutFormat f, int? q) {
  if (f == OutFormat.mp3) return '${q ?? 192} kbps';
  if (f == OutFormat.mp4) return q == bestQuality ? 'Mejor' : '${q ?? 720}p';
  if (f == OutFormat.m4a) return 'Original';
  return '16 bits · 44,1 kHz';
}

typedef Json = Map<String, dynamic>;

num? _num(Object? v) => v is num && v.isFinite && v >= 0 ? v : null;
String _str(Object? v) => v is String ? v : '';
int? _bytesOf(Json f) {
  final b = _num(f['filesize']) ?? _num(f['filesize_approx']);
  return b?.round();
}

bool _isAudioOnly(Json f) {
  final a = _str(f['acodec']);
  final v = _str(f['vcodec']);
  return a.isNotEmpty && a != 'none' && (v == 'none' || v.isEmpty);
}

/// Estéreo o mono. Las pistas 5.1 (AC-3, E-AC-3, AAC 5.1, IAMF) pesan el triple y hay que mezclarlas a estéreo
/// al convertir, lo que en el teléfono es lento.
bool _isStereo(Json f) {
  final ch = f['audio_channels'];
  return ch is! num || ch <= 2;
}

/// Bitrate, con las versiones de volumen normalizado (DRC) detrás de la original.
num _audioScore(Json f) => _rate(f) - (_drc.hasMatch(_str(f['format_id'])) ? 0.5 : 0);

bool _isHttps(Json f) => _str(f['protocol']) == 'https';
num _rate(Json f) => _num(f['abr']) ?? _num(f['tbr']) ?? 0;

T? _best<T>(Iterable<T> list, num Function(T) score) {
  T? out;
  for (final f in list) {
    if (out == null || score(f) > score(out)) out = f;
  }
  return out;
}

class AudioFmt {
  const AudioFmt(this.formatId, this.abr, this.bytes, {this.acodec = ''});
  final String formatId;
  final num? abr;
  final int? bytes;
  final String acodec;
  Json toJson() => {'formatId': formatId, 'abr': abr, 'bytes': bytes, 'acodec': acodec};
  static AudioFmt? fromJson(Object? j) =>
      j is Map ? AudioFmt(_str(j['formatId']), _num(j['abr']), _num(j['bytes'])?.round(), acodec: _str(j['acodec'])) : null;
}

class VideoFmt {
  const VideoFmt(this.height, this.formatId, this.fps, this.bytes);
  final int height;
  final String formatId;
  final num? fps;
  final int? bytes;
  Json toJson() => {'height': height, 'formatId': formatId, 'fps': fps, 'bytes': bytes};
  static VideoFmt fromJson(Map j) =>
      VideoFmt((_num(j['height']) ?? 0).round(), _str(j['formatId']), _num(j['fps']), _num(j['bytes'])?.round());
}

/// Lo que se sabe de un video tras extraer su info con yt-dlp.
class Meta {
  Meta({
    required this.videoId,
    this.title,
    this.author,
    this.duration = 0,
    this.live = false,
    this.description,
    this.ageLimit = 0,
    this.opus,
    this.m4a,
    this.hls,
    this.video = const [],
    this.gaps = const {},
    required this.fetchedAt,
  });

  final String videoId;
  final String? title;
  final String? author;
  final int duration;
  final bool live;
  final String? description;
  final int ageLimit;
  final AudioFmt? opus;
  final AudioFmt? m4a;
  final AudioFmt? hls;
  final List<VideoFmt> video;
  final Set<String> gaps;
  final DateTime fetchedAt;

  AudioFmt? get audioForVideo => m4a;
  List<int> get qualities => [for (final v in video) v.height];
  bool get canPreview => m4a != null || opus != null;
  bool get canWatch => video.isNotEmpty && m4a != null;

  Json toJson() => {
        'videoId': videoId,
        'title': title,
        'author': author,
        'duration': duration,
        'live': live,
        'description': description,
        'ageLimit': ageLimit,
        'opus': opus?.toJson(),
        'm4a': m4a?.toJson(),
        'hls': hls?.toJson(),
        'video': [for (final v in video) v.toJson()],
        'gaps': gaps.toList(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  static Meta fromJson(Map j) => Meta(
        videoId: _str(j['videoId']),
        title: j['title'] as String?,
        author: j['author'] as String?,
        duration: (_num(j['duration']) ?? 0).round(),
        live: j['live'] == true,
        description: j['description'] as String?,
        ageLimit: (_num(j['ageLimit']) ?? 0).round(),
        opus: AudioFmt.fromJson(j['opus']),
        m4a: AudioFmt.fromJson(j['m4a']),
        hls: AudioFmt.fromJson(j['hls']),
        video: [for (final v in (j['video'] as List? ?? const [])) VideoFmt.fromJson(v as Map)],
        gaps: {for (final g in (j['gaps'] as List? ?? const [])) g as String},
        fetchedAt: DateTime.tryParse(_str(j['fetchedAt'])) ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

const _liveStatuses = {'is_live', 'is_upcoming', 'post_live'};

String? clipDescription(Object? s) {
  if (s is! String) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  final cps = t.runes.toList();
  return cps.length > 200 ? '${String.fromCharCodes(cps.take(200))}…' : t;
}

List<Json> _formatsOf(Json info) =>
    [for (final f in (info['formats'] as List? ?? const [])) if (f is Map) f.cast<String, dynamic>()];

Meta deriveMeta(String videoId, Json info, {DateTime? now}) {
  String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
  final raw = _formatsOf(info)
      .where((f) => _str(f['format_id']).isNotEmpty && _str(f['format_note']) != 'storyboard' && _str(f['ext']) != 'mhtml')
      .toList();
  final audioAll = raw.where((f) => _isAudioOnly(f) && _isStereo(f)).toList();
  final audioHttps = audioAll.where(_isHttps).toList();
  final opus = _best(audioHttps.where((f) => _str(f['acodec']).startsWith('opus')), _audioScore);
  final m4a = _best(audioHttps.where((f) => _str(f['ext']) == 'm4a' && _str(f['acodec']).startsWith('mp4a')), _audioScore);
  AudioFmt toAudio(Json f) => AudioFmt(_str(f['format_id']), _num(f['abr']), _bytesOf(f), acodec: _str(f['acodec']));
  AudioFmt? hls;
  if (audioHttps.isEmpty) {
    final h = _best(audioAll.where((f) => _str(f['protocol']) == 'm3u8_native'), _rate);
    if (h != null) hls = AudioFmt(_str(h['format_id']), _num(h['abr']), null, acodec: _str(h['acodec']));
  }

  final avc1All = raw
      .where((f) =>
          _str(f['vcodec']).startsWith('avc1') && _str(f['acodec']) == 'none' && _str(f['ext']) == 'mp4' && (_num(f['height']) ?? 0) > 0)
      .toList();
  final byHeight = <int, Json>{};
  for (final f in avc1All.where((f) => _isHttps(f) && (_num(f['height']) ?? 0) <= 1080)) {
    final h = _num(f['height'])!.round();
    final prev = byHeight[h];
    if (prev == null || (_num(f['tbr']) ?? 0) > (_num(prev['tbr']) ?? 0)) byHeight[h] = f;
  }
  final heights = byHeight.keys.toList()..sort();
  final video = [for (final h in heights) VideoFmt(h, _str(byHeight[h]!['format_id']), _num(byHeight[h]!['fps']), _bytesOf(byHeight[h]!))];

  final gaps = <String>{};
  if ((audioHttps.isEmpty && audioAll.isNotEmpty) || (video.isEmpty && avc1All.any((f) => !_isHttps(f)))) gaps.add('only_fragmented');
  if (avc1All.isEmpty) gaps.add('no_avc1');
  if (m4a == null) gaps.add('no_m4a');

  final dur = info['duration'];
  return Meta(
    videoId: videoId,
    title: s(info['title']),
    author: s(info['channel']) ?? s(info['uploader']),
    duration: dur is num && dur.isFinite ? dur.round() : 0,
    live: info['live_status'] is String && _liveStatuses.contains(info['live_status']),
    description: clipDescription(info['description']),
    ageLimit: info['age_limit'] is num ? (info['age_limit'] as num).round() : 0,
    opus: opus == null ? null : toAudio(opus),
    m4a: m4a == null ? null : toAudio(m4a),
    hls: hls,
    video: video,
    gaps: gaps,
    fetchedAt: now ?? DateTime.now(),
  );
}

/// Qué pedirle a yt-dlp para una salida concreta.
class Selection {
  const Selection({required this.formatSel, required this.transcode, this.height, this.bytes, this.hls = false});
  final String formatSel;
  final bool transcode;
  final int? height;
  final int? bytes;
  final bool hls;
}

/// `null` si el video no tiene una versión válida para esa salida.
Selection? selectFormats(Meta meta, OutFormat format, int? quality) {
  if (format == OutFormat.mp4) {
    final a = meta.audioForVideo;
    if (meta.video.isEmpty || a == null) return null;
    final target = quality == null || quality == bestQuality ? 1080 : quality;
    final below = meta.video.where((v) => v.height <= target).toList();
    final v = below.isNotEmpty ? below.last : meta.video.first;
    final bytes = v.bytes != null && a.bytes != null ? v.bytes! + a.bytes! : null;
    return Selection(formatSel: '${v.formatId}+${a.formatId}', transcode: false, height: v.height, bytes: bytes);
  }
  if (format == OutFormat.m4a) {
    final src = meta.m4a ?? meta.opus;
    if (src != null) return Selection(formatSel: src.formatId, transcode: meta.m4a == null, bytes: src.bytes);
  } else {
    final src = _best([meta.opus, meta.m4a].whereType<AudioFmt>(), (a) => a.abr ?? 0);
    if (src != null) return Selection(formatSel: src.formatId, transcode: false, bytes: src.bytes);
  }
  final h = meta.hls;
  if (h != null) {
    return Selection(formatSel: h.formatId, transcode: format == OutFormat.m4a && !h.acodec.startsWith('mp4a'), hls: true);
  }
  return null;
}

/// Selector genérico para cuando no hay metadata: yt-dlp elige.
String genericSelector(OutFormat format, int? quality) {
  switch (format) {
    case OutFormat.mp4:
      final h = quality == null || quality == bestQuality ? 1080 : quality;
      return 'bv*[vcodec^=avc1][ext=mp4][height<=$h]+ba[ext=m4a]/bv*[height<=$h]+ba/b[height<=$h]/bv*+ba/b';
    case OutFormat.m4a:
      return 'ba[ext=m4a]/ba/b';
    default:
      return 'ba/b';
  }
}

/// Tamaño estimado del archivo final.
int? estimateBytes(Meta meta, OutFormat format, int? quality) {
  final d = meta.duration;
  if (format == OutFormat.mp3) return ((quality ?? 192) * 1000 / 8 * d).round();
  if (format == OutFormat.wav) return 44100 * 2 * 2 * d + 44;
  final s = selectFormats(meta, format, quality);
  if (s == null) return null;
  if (s.transcode) return (192 * 1000 / 8 * d).round();
  return s.bytes;
}

// Reproducción

/// Una fuente de googlevideo que el reproductor puede pedir directamente (la URL está atada a la IP del teléfono).
class StreamSource {
  StreamSource({
    required this.formatId,
    required this.url,
    required this.headers,
    required this.mime,
    this.size,
    this.codecs = '',
    this.width,
    this.height,
    this.fps,
    this.tbr,
    this.abr,
  });
  final String formatId;
  final String url;
  final Map<String, String> headers;
  final String mime;
  final int? size;
  final String codecs;
  final int? width;
  final int? height;
  final num? fps;
  final num? tbr;
  final num? abr;

  /// Calidad nominal: el lado corto, como YouTube (un Short 1080x1920 es 1080p).
  int get quality => width == null ? (height ?? 0) : (width! < (height ?? 0) ? width! : (height ?? 0));

  Json toJson() => {'formatId': formatId, 'url': url, 'headers': headers, 'mime': mime, 'size': size};
}

Uri? _googlevideo(Object? raw) {
  if (raw is! String) return null;
  final u = Uri.tryParse(raw);
  return u != null && u.scheme == 'https' && u.host.endsWith('.googlevideo.com') ? u : null;
}

Map<String, String> streamHeaders(Object? raw) {
  final out = <String, String>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      final lk = '$k'.toLowerCase();
      if (lk == 'cookie' || lk == 'accept-encoding' || lk == 'range' || v is! String) return;
      out['$k'] = v;
    });
  }
  return out;
}

int? _posInt(Object? v) {
  final n = v is String && RegExp(r'^\d+$').hasMatch(v) ? int.tryParse(v) : v;
  return n is num && n > 0 && n.isFinite ? n.round() : null;
}

StreamSource _source(Json f, Uri u, String mime) => StreamSource(
      formatId: _str(f['format_id']),
      url: f['url'] as String,
      headers: streamHeaders(f['http_headers']),
      mime: mime,
      size: _posInt(f['filesize']) ?? _posInt(f['clen']) ?? _posInt(u.queryParameters['clen']),
      codecs: mime.startsWith('video') ? _str(f['vcodec']) : _str(f['acodec']),
      width: _posInt(f['width']),
      height: _posInt(f['height']),
      fps: _num(f['fps']),
      tbr: _num(f['tbr']),
      abr: _num(f['abr']) ?? _num(f['tbr']),
    );

final _drc = RegExp(r'(^|-)drc(-|$)');

/// Audio para escuchar: AAC primero (o Opus con `opus: true`), sin DRC, idioma original y mejor calidad.
List<StreamSource> rankAudioSources(Json info, {bool opus = false}) {
  final cands = <({Json f, Uri u, bool aac})>[];
  for (final f in _formatsOf(info)) {
    if (_str(f['vcodec']) != 'none' || _str(f['acodec']).isEmpty || _str(f['acodec']) == 'none') continue;
    if (_str(f['protocol']) != 'https' || f['has_drm'] == true || _str(f['format_id']).isEmpty || !_isStereo(f)) continue;
    final u = _googlevideo(f['url']);
    if (u == null) continue;
    final ac = _str(f['acodec']);
    final ext = _str(f['ext']);
    if (ext == 'm4a' && ac.startsWith('mp4a')) {
      cands.add((f: f, u: u, aac: true));
    } else if (ext == 'webm' && ac.startsWith('opus')) {
      cands.add((f: f, u: u, aac: false));
    }
  }
  num n(Object? v) => v is num && v.isFinite ? v : double.negativeInfinity;
  int lc(String s) => s.startsWith('mp4a.40.2') ? 0 : (s.startsWith('mp4a.40.5') ? 1 : 2);
  int cmp(num a, num b) => a == b ? 0 : (a < b ? -1 : 1);
  cands.sort((a, b) {
    final ida = _str(a.f['format_id']);
    final idb = _str(b.f['format_id']);
    int first(({Json f, Uri u, bool aac}) x) => x.aac != opus ? 0 : 1;
    var r = cmp(first(a), first(b));
    if (r != 0) return r;
    r = cmp(_drc.hasMatch(ida) ? 1 : 0, _drc.hasMatch(idb) ? 1 : 0);
    if (r != 0) return r;
    r = cmp(n(b.f['language_preference']), n(a.f['language_preference']));
    if (r != 0) return r;
    r = cmp(lc(_str(a.f['acodec'])), lc(_str(b.f['acodec'])));
    if (r != 0) return r;
    r = cmp(n(b.f['quality']), n(a.f['quality']));
    if (r != 0) return r;
    r = cmp(n(b.f['abr']), n(a.f['abr']));
    if (r != 0) return r;
    return ida.compareTo(idb);
  });
  return [for (final c in cands) _source(c.f, c.u, c.aac ? 'audio/mp4' : 'audio/webm')];
}

/// Variantes de video para ver en la app: avc1 en mp4 sin audio, https, sin DRM; la de mayor tbr por calidad.
List<StreamSource> videoRenditions(Json info, {int maxHeight = 1080}) {
  final byQ = <int, StreamSource>{};
  for (final f in _formatsOf(info)) {
    if (!_str(f['vcodec']).startsWith('avc1') || _str(f['acodec']) != 'none' || _str(f['ext']) != 'mp4') continue;
    if (_str(f['protocol']) != 'https' || f['has_drm'] == true || _str(f['format_id']).isEmpty) continue;
    if (_posInt(f['height']) == null) continue;
    final u = _googlevideo(f['url']);
    if (u == null) continue;
    final r = _source(f, u, 'video/mp4');
    if (r.quality > maxHeight) continue;
    final prev = byQ[r.quality];
    if (prev == null || _better(r, prev)) byQ[r.quality] = r;
  }
  final list = byQ.values.toList()..sort((a, b) => a.quality.compareTo(b.quality));
  return list;
}

bool _better(StreamSource a, StreamSource b) {
  final ta = a.tbr ?? -1, tb = b.tbr ?? -1;
  if (ta != tb) return ta > tb;
  final fa = a.fps ?? -1, fb = b.fps ?? -1;
  if (fa != fb) return fa > fb;
  return a.formatId.compareTo(b.formatId) < 0;
}

/// Segundos que le quedan a las URLs firmadas de la info (`expire=`). `null` si no se sabe.
int? infoExpiresAt(Json info) {
  for (final f in _formatsOf(info)) {
    final u = Uri.tryParse(_str(f['url']));
    if (u == null) continue;
    final e = u.queryParameters['expire'] ?? RegExp(r'/expire/(\d+)').firstMatch(u.path)?.group(1);
    if (e != null && RegExp(r'^\d+$').hasMatch(e)) return int.parse(e);
  }
  return null;
}
