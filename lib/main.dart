import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'core/url.dart';
import 'native/bridge.dart';
import 'state/history.dart';
import 'state/pc.dart';
import 'state/player.dart';
import 'state/queue.dart';
import 'state/search.dart';
import 'state/settings.dart';
import 'ui/history_page.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final settings = await Settings.load();
  runApp(SetubeApp(settings: settings));
}

class SetubeApp extends StatefulWidget {
  const SetubeApp({super.key, required this.settings});
  final Settings settings;

  @override
  State<SetubeApp> createState() => _SetubeAppState();
}

class _SetubeAppState extends State<SetubeApp> with WidgetsBindingObserver {
  final _nav = GlobalKey<NavigatorState>();
  final _input = TextEditingController();
  late final history = HistoryModel();
  late final queue = QueueModel(widget.settings, history);
  late final search = SearchModel(widget.settings);
  late final player = PlayerModel(queue, widget.settings);
  late final pc = PcModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    queue.pc = pc;
    unawaited(queue.restore());
    unawaited(_autoUpdateEngine());
    unawaited(history.load());
    unawaited(_keepSessionAlive());
    AppNative.onCall((method, arg) {
      if (method == 'route' && arg == 'history') _openHistory();
      if (method == 'shared' && arg != null) _onShared(arg);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final init = await AppNative.initial();
        if (init.route == 'history') _openHistory();
        if (init.shared != null) _onShared(init.shared!);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_keepSessionAlive());
  }

  /// Renueva la sesión de YouTube (si hay y toca: cada 6 h) abriendo YouTube en un WebView sin interfaz.
  Future<void> _keepSessionAlive() async {
    try {
      await Session.refresh();
    } catch (_) {}
  }

  /// yt-dlp se actualiza solo una vez por semana: YouTube cambia a menudo y sin esto las descargas se rompen.
  Future<void> _autoUpdateEngine() async {
    final last = widget.settings.engineCheckedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(days: 7)) return;
    // La primera vez, enseguida: el yt-dlp que trae el APK puede tener meses. El reemplazo espera a que
    // terminen los procesos en curso (Engine.binLock).
    if (last != null) await Future<void>.delayed(const Duration(seconds: 20));
    try {
      await Engine.update('stable');
      widget.settings.engineCheckedAt = DateTime.now();
    } catch (_) {}
  }

  void _openHistory() => _nav.currentState?.push(MaterialPageRoute<void>(builder: (_) => HistoryPage(history: history, pc: pc, settings: widget.settings)));

  /// Texto compartido desde otra app (YouTube): si trae links se agregan a la cola.
  void _onShared(String text) {
    final found = extractYouTubeLinks(text);
    if (found.isNotEmpty) {
      queue.addLines(found);
    } else {
      _input.text = text.trim();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final dark = widget.settings.theme == ThemeMode.dark;
        SystemChrome.setSystemUIOverlayStyle(dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
        return MaterialApp(
          navigatorKey: _nav,
          title: 'Setube',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: widget.settings.theme,
          home: HomePage(
            settings: widget.settings,
            queue: queue,
            search: search,
            player: player,
            history: history,
            pc: pc,
            input: _input,
          ),
        );
      },
    );
  }
}
