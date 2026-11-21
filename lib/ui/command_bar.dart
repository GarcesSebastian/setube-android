// Barra de comandos: links (uno o varios por línea) o una búsqueda, más el selector de salida.

import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/errors.dart';
import '../core/format.dart';
import '../core/formats.dart';
import '../core/url.dart';
import '../state/queue.dart';
import '../state/search.dart';
import '../state/settings.dart';
import 'theme.dart';
import 'widgets.dart';

class CommandBar extends StatefulWidget {
  const CommandBar({super.key, required this.queue, required this.search, required this.controller, required this.focus});
  final QueueModel queue;
  final SearchModel search;
  final TextEditingController controller;
  final FocusNode focus;

  @override
  State<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends State<CommandBar> {
  String _last = '';

  TextEditingController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final t = _c.text;
    // Pegar links (solos o dentro de un mensaje de WhatsApp) los agrega al momento
    if (t.length - _last.length > 12 && extractYouTubeLinks(t).isNotEmpty) {
      _last = '';
      WidgetsBinding.instance.addPostFrameCallback((_) => submit());
      return;
    }
    _last = t;
    setState(() {});
  }

  void submit() {
    final text = _c.text;
    // Si hay links en el texto, se agregan esos y el resto (fechas, nombres, comentarios) se descarta
    final links = extractYouTubeLinks(text);
    if (links.isNotEmpty) {
      final q = widget.queue;
      final noisy = !onlyLinks(text);
      final before = q.items.length + q.playlists.length;
      q.addLines(links, quiet: noisy);
      final added = q.items.length + q.playlists.length - before;
      _c.clear();
      _last = '';
      widget.search.close();
      FocusScope.of(context).unfocus();
      if (noisy) {
        final n = links.length;
        final dup = n - added;
        q.toast(n == 1
            ? (added == 1 ? 'Encontré 1 link en el texto y lo agregué' : 'El link del texto ya estaba en la cola')
            : 'Encontré $n links en el texto${dup > 0 ? ' ($dup ya estaban en la cola)' : ''}');
      }
      return;
    }
    final q = searchQuery(text);
    if (q != null) {
      widget.search.search(q);
      FocusScope.of(context).unfocus();
      return;
    }
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.every((l) => l.trim().isEmpty)) return;
    final invalid = widget.queue.addLines(lines);
    _c.text = invalid.join('\n');
    _last = _c.text;
    if (invalid.isEmpty) widget.search.close();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t == null || t.isEmpty) return;
    _last = _c.text.trim().isEmpty ? t : '${_c.text.trimRight()}\n$t';
    _c.text = _last;
    _c.selection = TextSelection.collapsed(offset: _c.text.length);
    if (extractYouTubeLinks(_c.text).isNotEmpty || searchQuery(_c.text) != null) submit();
  }

  ({int videos, int lists, int invalid}) _classify() {
    var v = 0, l = 0, inv = 0;
    final links = extractYouTubeLinks(_c.text);
    if (links.isNotEmpty) {
      for (final u in links) {
        parseYouTubeUrl(u)!.kind == UrlKind.playlist ? l++ : v++;
      }
      return (videos: v, lists: l, invalid: 0);
    }
    for (final raw in _c.text.split(RegExp(r'\r?\n'))) {
      if (raw.trim().isNotEmpty) inv++;
    }
    return (videos: v, lists: l, invalid: inv);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final isSearch = extractYouTubeLinks(_c.text).isEmpty && searchQuery(_c.text) != null;
    final empty = _c.text.trim().isEmpty;
    final cls = _classify();
    final parts = [
      if (cls.videos > 0) '${cls.videos} ${cls.videos == 1 ? 'video' : 'videos'}',
      if (cls.lists > 0) '${cls.lists} ${cls.lists == 1 ? 'playlist' : 'playlists'}',
      if (cls.invalid > 0) '${cls.invalid} no ${cls.invalid == 1 ? 'válida' : 'válidas'}',
    ];
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 8),
              child: Icon(isSearch ? LucideIcons.search : LucideIcons.link, size: 18, color: p.inkMuted),
            ),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: widget.focus,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => submit(),
                style: body(16, color: p.ink),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: 'Pega links (o un mensaje de WhatsApp con links) o escribe para buscar',
                  hintStyle: body(15, color: p.inkMuted),
                ),
              ),
            ),
            if (!empty)
              IconBtn(
                icon: LucideIcons.x,
                tooltip: 'Limpiar',
                onPressed: () {
                  _c.clear();
                  widget.search.close();
                },
              )
            else
              IconBtn(icon: LucideIcons.clipboardPaste, tooltip: 'Pegar', onPressed: _paste),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(children: [
            Expanded(
              child: Text(
                isSearch ? 'Buscar en YouTube' : (parts.isEmpty ? 'Uno por línea · videos, Shorts, Music o playlists' : parts.join(' · ')),
                style: body(13, color: cls.invalid > 0 && !isSearch ? p.redInk : p.inkMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Btn(
              label: isSearch ? 'Buscar' : 'Agregar',
              icon: isSearch ? LucideIcons.search : LucideIcons.plus,
              kind: BtnKind.primary,
              compact: true,
              onPressed: empty ? null : submit,
            ),
          ]),
        ),
        Divider(height: 1, color: p.line),
        OutputBar(queue: widget.queue),
      ]),
    );
  }
}
