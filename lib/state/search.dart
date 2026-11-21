// Búsqueda de videos con yt-dlp (`ytsearch`). Una búsqueda nueva deja sin efecto la anterior.

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/parse.dart';
import '../services/youtube.dart';
import 'settings.dart';

class SearchModel extends ChangeNotifier {
  SearchModel(this.settings);
  final Settings settings;

  String? query;
  List<SearchItem> results = const [];
  bool loading = false;
  ErrCode? error;
  int _seq = 0;

  bool get open => query != null;

  Future<void> search(String q) async {
    final seq = ++_seq;
    query = q;
    loading = true;
    error = null;
    results = const [];
    notifyListeners();
    settings.addSearch(q);
    try {
      final r = await YouTube.instance.search(q);
      if (seq != _seq) return;
      results = r.items;
    } on YtError catch (e) {
      if (seq != _seq) return;
      error = const {ErrCode.upstreamBlocked, ErrCode.engine, ErrCode.network}.contains(e.code) ? e.code : ErrCode.upstreamError;
    } catch (_) {
      if (seq != _seq) return;
      error = ErrCode.unknown;
    }
    loading = false;
    notifyListeners();
  }

  void close() {
    _seq++;
    query = null;
    results = const [];
    loading = false;
    error = null;
    notifyListeners();
  }
}
