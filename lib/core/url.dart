// Reconocimiento de links de YouTube. Mismas reglas que la web y la API (youtube-url.ts / url.ts).

enum UrlKind { video, playlist }

class ParsedUrl {
  const ParsedUrl({required this.kind, this.videoId, this.playlistId, required this.canonicalUrl});
  final UrlKind kind;
  final String? videoId;
  final String? playlistId;
  final String canonicalUrl;
}

final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _playlistId = RegExp(r'^[A-Za-z0-9_-]{2,64}$');
const _hosts = {'youtube.com', 'music.youtube.com', 'youtu.be', 'youtube-nocookie.com'};
const _pathPrefixes = ['shorts', 'live', 'embed', 'v'];

String watchUrl(String videoId) => 'https://www.youtube.com/watch?v=$videoId';
String playlistUrl(String playlistId) => 'https://www.youtube.com/playlist?list=$playlistId';
String thumbnailUrl(String videoId) => 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';

bool isVideoId(Object? s) => s is String && _videoId.hasMatch(s);
bool isPlaylistId(Object? s) => s is String && _playlistId.hasMatch(s);

String _normalizeHost(String host) {
  var h = host.toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.startsWith('www.')) {
    h = h.substring(4);
  } else if (h.startsWith('m.')) {
    h = h.substring(2);
  }
  return h;
}

/// Devuelve `null` si la URL no es de YouTube o no contiene ids válidos.
ParsedUrl? parseYouTubeUrl(String input) {
  var s = input.trim();
  if (s.isEmpty || RegExp(r'\s').hasMatch(s)) return null;
  if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(s)) s = 'https://$s';
  final Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return null;
  }
  if (u.scheme != 'https' && u.scheme != 'http') return null;
  if (u.userInfo.isNotEmpty || u.hasPort) return null;
  final host = _normalizeHost(u.host);
  if (!_hosts.contains(host)) return null;

  final segs = u.pathSegments.where((p) => p.isNotEmpty).toList();
  String? videoId;
  final Map<String, List<String>> params;
  try {
    params = u.queryParametersAll;
  } catch (_) {
    return null;
  }
  String? param(String k) => params[k]?.first;

  if (host == 'youtu.be') {
    if (segs.isNotEmpty && isVideoId(segs[0])) {
      videoId = segs[0];
    } else {
      return null;
    }
  } else if (segs.isNotEmpty && segs[0] == 'watch' && segs.length == 1) {
    final v = param('v');
    if (v != null) {
      if (!isVideoId(v)) return null;
      videoId = v;
    }
  } else if (segs.isNotEmpty && _pathPrefixes.contains(segs[0]) && segs.length >= 2) {
    if (!isVideoId(segs[1])) return null;
    videoId = segs[1];
  } else if (!(segs.isNotEmpty && segs[0] == 'playlist' && segs.length == 1)) {
    return null;
  }

  final list = param('list');
  final playlistId = list != null && isPlaylistId(list) ? list : null;

  if (videoId != null) {
    return ParsedUrl(kind: UrlKind.video, videoId: videoId, playlistId: playlistId, canonicalUrl: watchUrl(videoId));
  }
  if (playlistId != null) {
    return ParsedUrl(kind: UrlKind.playlist, playlistId: playlistId, canonicalUrl: playlistUrl(playlistId));
  }
  return null;
}
