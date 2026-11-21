// Preferencias guardadas en el teléfono, con las mismas claves que la web en localStorage.

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/formats.dart';

const urlsKey = 'setube_urls';
const prefsKey = 'setube_prefs';
const themeKey = 'setube_theme';
const searchesKey = 'setube_searches';
const playerModeKey = 'setube_player_mode';
const maxRecentSearches = 8;

class Settings extends ChangeNotifier {
  Settings._(this._p);
  final SharedPreferences _p;

  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  ThemeMode get theme => _p.getString(themeKey) == 'light' ? ThemeMode.light : ThemeMode.dark;
  set theme(ThemeMode m) {
    _p.setString(themeKey, m == ThemeMode.light ? 'light' : 'dark');
    notifyListeners();
  }

  ({OutFormat format, int? quality}) get output {
    try {
      final j = jsonDecode(_p.getString(prefsKey) ?? '{}') as Map;
      final f = outFormatOf(j['format'] as String?) ?? OutFormat.mp3;
      final q = j['quality'] == 'best' ? bestQuality : (j['quality'] as num?)?.toInt();
      return (format: f, quality: normalizeQuality(f, q));
    } catch (_) {
      return (format: OutFormat.mp3, quality: 192);
    }
  }

  void saveOutput(OutFormat f, int? q) => _p.setString(
        prefsKey,
        jsonEncode({'kind': f.isVideo ? 'video' : 'audio', 'format': f.name, 'quality': q == bestQuality ? 'best' : q}),
      );

  List<String> get urls {
    try {
      final j = jsonDecode(_p.getString(urlsKey) ?? '') as Map;
      if (j['v'] != 2) return const [];
      return [for (final u in (j['urls'] as List)) if (u is String && u.isNotEmpty && u.length <= 2048) u];
    } catch (_) {
      return const [];
    }
  }

  void saveUrls(List<String> urls) => _p.setString(urlsKey, jsonEncode({'v': 2, 'urls': urls}));

  /// `audio` o `video`: si al reproducir prefieres escuchar o ver.
  String get playerMode => _p.getString(playerModeKey) == 'video' ? 'video' : 'audio';
  set playerMode(String m) => _p.setString(playerModeKey, m == 'video' ? 'video' : 'audio');

  List<String> get recentSearches {
    try {
      return [for (final s in (jsonDecode(_p.getString(searchesKey) ?? '[]') as List)) if (s is String) s];
    } catch (_) {
      return const [];
    }
  }

  void _saveSearches(List<String> l) {
    _p.setString(searchesKey, jsonEncode(l.take(maxRecentSearches).toList()));
    notifyListeners();
  }

  /// Repetir una sin distinguir mayúsculas la sube al principio en vez de duplicarla.
  void addSearch(String q) {
    final t = q.trim();
    if (t.isEmpty || t.length > 200) return;
    final l = recentSearches.where((s) => s.toLowerCase() != t.toLowerCase()).toList()..insert(0, t);
    _saveSearches(l);
  }

  void removeSearch(String q) => _saveSearches(recentSearches.where((s) => s != q).toList());
  void restoreSearches(List<String> l) => _saveSearches(l);
  void clearSearches() => _saveSearches(const []);

  DateTime? get engineCheckedAt {
    final ms = _p.getInt('setube_ytdlp_checked');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set engineCheckedAt(DateTime? d) => d == null ? _p.remove('setube_ytdlp_checked') : _p.setInt('setube_ytdlp_checked', d.millisecondsSinceEpoch);

  /// Últimas carpetas usadas al enviar al PC, para elegirlas con un toque.
  List<String> get pcFolders {
    try {
      return [for (final s in (jsonDecode(_p.getString('setube_pc_folders') ?? '[]') as List)) if (s is String) s];
    } catch (_) {
      return const [];
    }
  }

  void addPcFolder(String f) {
    final l = pcFolders.where((x) => x.toLowerCase() != f.toLowerCase()).toList()..insert(0, f);
    _p.setString('setube_pc_folders', jsonEncode(l.take(6).toList()));
  }

  bool get notificationsAsked => _p.getBool('setube_notif_asked') ?? false;
  set notificationsAsked(bool v) => _p.setBool('setube_notif_asked', v);
}
