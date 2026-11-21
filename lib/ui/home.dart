// Pantalla principal: barra de comandos, búsqueda, cola y la parte fija de abajo.

import 'dart:async';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../state/history.dart';
import '../state/pc.dart';
import '../state/player.dart';
import '../state/queue.dart';
import '../state/search.dart';
import '../state/settings.dart';
import 'command_bar.dart';
import 'history_page.dart';
import 'pc_ui.dart';
import 'player_dock.dart';
import 'queue_view.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.queue,
    required this.search,
    required this.player,
    required this.history,
    required this.pc,
    required this.input,
  });

  final Settings settings;
  final QueueModel queue;
  final SearchModel search;
  final PlayerModel player;
  final HistoryModel history;
  final PcModel pc;
  final TextEditingController input;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _focus = FocusNode();
  StreamSubscription<Toast>? _toasts;

  @override
  void initState() {
    super.initState();
    _toasts = widget.queue.toasts.stream.listen(_showToast);
    widget.queue.onSendToPc = (e) {
      if (mounted) sendToPc(context, widget.pc, e, widget.settings);
    };
  }

  @override
  void dispose() {
    _toasts?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _showToast(Toast t) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    final p = context.pal;
    m.showSnackBar(SnackBar(
      duration: Duration(seconds: t.action == null ? 3 : 6),
      content: Row(children: [
        Expanded(child: Text(t.message)),
        if (t.secondary != null)
          TextButton(
            onPressed: () {
              m.hideCurrentSnackBar();
              t.onSecondary?.call();
            },
            child: Text(t.secondary!, style: body(14, weight: FontWeight.w600, color: p.ink)),
          ),
      ]),
      action: t.action == null ? null : SnackBarAction(label: t.action!, onPressed: t.onAction ?? () {}),
    ));
  }

  void _openHistory() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HistoryPage(history: widget.history, pc: widget.pc, settings: widget.settings)));

  void _openSettings() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(settings: widget.settings, pc: widget.pc)));

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          Image.asset('assets/logo.png', width: 29, height: 26),
          const SizedBox(width: 10),
          const Text('Setube'),
        ]),
        actions: [
          IconBtn(icon: LucideIcons.history, tooltip: 'Descargas', onPressed: _openHistory),
          ListenableBuilder(
            listenable: s,
            builder: (_, _) => IconBtn(
              icon: s.theme == ThemeMode.dark ? LucideIcons.sun : LucideIcons.moon,
              tooltip: s.theme == ThemeMode.dark ? 'Tema claro' : 'Tema oscuro',
              onPressed: () => s.theme = s.theme == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
            ),
          ),
          IconBtn(icon: LucideIcons.settings, tooltip: 'Ajustes', onPressed: _openSettings),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: BottomDock(queue: widget.queue, player: widget.player, pc: widget.pc),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.queue, widget.search, widget.player, s]),
          builder: (context, _) {
            final q = widget.queue;
            final sr = widget.search;
            return ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                CommandBar(queue: q, search: sr, controller: widget.input, focus: _focus),
                if (!sr.open && widget.input.text.trim().isEmpty)
                  RecentSearches(
                    settings: s,
                    queue: q,
                    onPick: (t) {
                      widget.input.text = t;
                      sr.search(t);
                    },
                  ),
                if (sr.open) SearchResults(search: sr, queue: q),
                if (q.playlists.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  for (final c in q.playlists) PlaylistCardView(card: c, queue: q),
                ],
                if (q.items.isEmpty && q.playlists.isEmpty && !sr.open)
                  const _EmptyState()
                else if (q.items.isNotEmpty) ...[
                  SectionTitle(
                    'Cola · ${q.items.length}',
                    trailing: TextButton.icon(
                      onPressed: q.clear,
                      icon: Icon(LucideIcons.trash2, size: 16, color: p.inkMuted),
                      label: Text('Vaciar', style: body(13.5, weight: FontWeight.w600, color: p.inkMuted)),
                    ),
                  ),
                  for (var i = 0; i < q.items.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: p.line),
                    QueueRow(
                      key: ValueKey(q.items[i].key),
                      item: q.items[i],
                      queue: q,
                      player: widget.player,
                      history: widget.history,
                      pc: widget.pc,
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  static const _steps = [
    ('Pega los links', 'Uno por línea, todos a la vez. Las playlists se abren en sus videos. También puedes compartir desde la app de YouTube.'),
    ('Elige la salida', 'MP3, M4A, WAV o MP4 con la calidad exacta.'),
    ('Convierte', 'Todo pasa en el teléfono. Un video se guarda como archivo; varios, en un ZIP.'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Tu cola está vacía', style: display(20, color: p.ink)),
        const SizedBox(height: 4),
        Text('Pega un link de video o de playlist, o busca por nombre.', style: body(14.5, color: p.inkMuted)),
        const SizedBox(height: 16),
        for (var i = 0; i < _steps.length; i++)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 24, child: Text('${i + 1}', style: mono(14, color: p.redInk))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_steps[i].$1, style: body(14.5, weight: FontWeight.w600, color: p.ink)),
                  Text(_steps[i].$2, style: body(13.5, color: p.inkMuted)),
                ]),
              ),
            ]),
          ),
        const SizedBox(height: 18),
        Text('Links que reconoce', style: body(13, color: p.inkMuted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in const ['youtube.com/watch?v=…', 'youtu.be/…', 'youtube.com/shorts/…', 'music.youtube.com/watch?v=…', 'youtube.com/playlist?list=…'])
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(radiusControl), border: Border.all(color: p.line)),
              child: Text(f, style: mono(12, color: p.ink)),
            ),
        ]),
      ]),
    );
  }
}
