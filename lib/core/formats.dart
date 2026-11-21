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
