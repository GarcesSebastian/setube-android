// Lectura de la salida JSON de yt-dlp para búsquedas y playlists (igual que search.ts y playlist.ts de la API).

import 'formats.dart';
import 'url.dart';

class SearchItem {
  const SearchItem({
    required this.videoId,
    this.title,
    this.author,
    this.duration,
    this.views,
    this.live = false,
  });
  final String videoId;
  final String? title;
  final String? author;
  final int? duration;
  final int? views;
  final bool live;
  String get thumbnail => thumbnailUrl(videoId);
}

class SearchResult {
  const SearchResult(this.query, this.items);
  final String query;
  final List<SearchItem> items;
}

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
int? _pos(Object? v) => v is num && v.isFinite && v >= 0 ? v.round() : null;

SearchResult toSearchResult(String query, Json raw, int maxResults) {
  final entries = raw['entries'] is List ? raw['entries'] as List : const [];
  final seen = <String>{};
  final items = <SearchItem>[];
  for (final e in entries) {
    if (e is! Map) continue;
    final id = e['id'];
    if (!isVideoId(id) || seen.contains(id) || (e['ie_key'] != null && e['ie_key'] != 'Youtube')) continue;
    seen.add(id as String);
    final ls = e['live_status'];
    items.add(SearchItem(
      videoId: id,
      title: _s(e['title']),
      author: _s(e['channel']) ?? _s(e['uploader']),
      duration: _pos(e['duration']),
      views: _pos(e['view_count']),
      live: ls is String && (ls == 'is_live' || ls == 'is_upcoming'),
    ));
    if (items.length >= maxResults) break;
  }
  return SearchResult(query, items);
}

class PlaylistItem {
  const PlaylistItem({required this.videoId, this.title, this.duration});
  final String videoId;
  final String? title;
  final int? duration;
}

class PlaylistResult {
  const PlaylistResult({
    required this.playlistId,
    this.title,
    this.author,
    required this.count,
    required this.skipped,
    required this.items,
  });
  final String playlistId;
  final String? title;
  final String? author;
  final int count;
  final int skipped;
  final List<PlaylistItem> items;
  String? get thumbnail => items.isEmpty ? null : thumbnailUrl(items.first.videoId);
}

const _hiddenTitles = {'[Private video]', '[Deleted video]'};

PlaylistResult toPlaylistResult(String playlistId, Json raw) {
  final entries = raw['entries'] is List ? raw['entries'] as List : const [];
  var skipped = 0;
  final items = <PlaylistItem>[];
  final seen = <String>{};
  for (final e in entries) {
    final id = e is Map ? e['id'] : null;
    final title = e is Map && e['title'] is String ? e['title'] as String : null;
    if (!isVideoId(id) || (title != null && _hiddenTitles.contains(title)) || seen.contains(id)) {
      skipped++;
      continue;
    }
    seen.add(id as String);
    final d = (e as Map)['duration'];
    items.add(PlaylistItem(videoId: id, title: title, duration: d is num && d.isFinite ? d.round() : null));
  }
  final count = raw['playlist_count'] is num ? (raw['playlist_count'] as num).round() : entries.length;
  return PlaylistResult(
    playlistId: playlistId,
    title: _s(raw['title']),
    author: _s(raw['channel']) ?? _s(raw['uploader']),
    count: count,
    skipped: skipped,
    items: items,
  );
}

const searchMaxResults = 20;

List<String> searchArgs(String query, {int max = searchMaxResults}) =>
    ['--flat-playlist', '-J', '--no-warnings', '--', 'ytsearch$max:$query'];

List<String> playlistArgs(String playlistId) => ['--flat-playlist', '-J', '--no-warnings', '--', playlistUrl(playlistId)];
