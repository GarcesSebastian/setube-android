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

String formatHint(OutFormat f) => switch (f) {
      OutFormat.mp3 => 'MP3 suena en cualquier sitio. Recodifica el audio a la calidad elegida.',
      OutFormat.m4a => 'M4A copia el audio AAC original, sin perder calidad.',
      OutFormat.wav => 'WAV sin compresión, 16 bits a 44,1 kHz. Ocupa mucho más.',
      OutFormat.mp4 => 'MP4 une el video y el audio originales sin recodificar.',
    };

class OutputBar extends StatelessWidget {
  const OutputBar({super.key, required this.queue});
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final f = queue.format;
    final t = queue.totals;
    final formats = f.isVideo ? const [OutFormat.mp4] : const [OutFormat.mp3, OutFormat.m4a, OutFormat.wav];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Segmented<bool>(
            value: f.isVideo,
            options: const [(false, 'Audio', LucideIcons.headphones), (true, 'Video', LucideIcons.film)],
            onChanged: queue.busy ? null : queue.setKind,
          ),
          for (final x in formats)
            ChoiceChipX(label: x.label, selected: x == f, onTap: queue.busy ? null : () => queue.setFormat(x)),
          _QualityButton(queue: queue),
        ]),
        const SizedBox(height: 10),
        Text(formatHint(f), style: body(13, color: p.inkMuted)),
        if (t.count > 0) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            StatPill('${t.count} ${t.count == 1 ? 'video' : 'videos'}'),
            if (t.duration > 0) StatPill(formatDuration(t.duration)),
            if (t.known > 0) StatPill('${t.known < t.count ? '≥ ' : '~'}${formatBytes(t.bytes)}'),
            if (t.count > 1) Text('Se guardan en un ZIP', style: body(13, color: p.inkMuted)),
          ]),
        ],
      ]),
    );
  }
}

class _QualityButton extends StatelessWidget {
  const _QualityButton({required this.queue});
  final QueueModel queue;

  List<int?> get _options => switch (queue.format) {
        OutFormat.mp3 => mp3Qualities,
        OutFormat.mp4 => mp4Qualities,
        _ => const [null],
      };

  /// Con un solo video en la cola se deshabilitan las calidades que no tiene.
  bool _available(int? q) {
    if (queue.format != OutFormat.mp4 || q == null || q == bestQuality) return true;
    final convertible = queue.items.where((i) => i.convertible).toList();
    if (convertible.length != 1) return true;
    final m = convertible.first.meta;
    if (m == null || m.video.isEmpty) return true;
    return m.video.any((v) => v.height >= q);
  }

  int? _size(int? q) {
    final convertible = queue.items.where((i) => i.convertible && i.meta != null).toList();
    if (convertible.isEmpty) return null;
    var sum = 0;
    for (final i in convertible) {
      final b = estimateBytes(i.meta!, queue.format, q);
      if (b == null) return null;
      sum += b;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final f = queue.format;
    final fixed = f == OutFormat.m4a || f == OutFormat.wav;
    final label = qualityLabel(f, queue.quality);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusControl), side: BorderSide(color: p.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: fixed || queue.busy ? null : () => _pick(context),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: mono(13.5, weight: FontWeight.w600, color: p.ink)),
            if (!fixed) ...[const SizedBox(width: 6), Icon(LucideIcons.chevronDown, size: 16, color: p.inkMuted)],
          ]),
        ),
      ),
    );
  }

  void _pick(BuildContext context) {
    final p = context.pal;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Calidad ${queue.format.label}', style: display(18, color: p.ink)),
          ),
          for (final q in _options)
            ListTile(
              enabled: _available(q),
              onTap: () {
                queue.setQuality(q);
                Navigator.pop(ctx);
              },
              leading: Icon(
                q == queue.quality ? LucideIcons.circleCheck : LucideIcons.circle,
                color: q == queue.quality ? p.red : p.edge,
                size: 20,
              ),
              title: Text(qualityLabel(queue.format, q), style: mono(15, weight: FontWeight.w600, color: p.ink)),
              trailing: Text(
                !_available(q) ? 'No disponible' : (_size(q) == null ? '' : '~${formatBytes(_size(q))}'),
                style: mono(13, color: p.inkMuted),
              ),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Mensaje de error para la búsqueda.
String searchErrorText(ErrCode c) =>
    c == ErrCode.upstreamBlocked ? messageFor(c) : 'No se pudo buscar en YouTube. ${messageFor(c)}';

class RecentSearches extends StatelessWidget {
  const RecentSearches({super.key, required this.settings, required this.onPick, required this.queue});
  final Settings settings;
  final QueueModel queue;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final list = settings.recentSearches;
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Búsquedas recientes', style: body(13, color: p.inkMuted)),
          const Spacer(),
          TextButton(
            onPressed: () {
              final old = [...list];
              settings.clearSearches();
              queue.toast('Historial de búsqueda borrado', action: 'Deshacer', onAction: () => settings.restoreSearches(old));
            },
            child: Text('Borrar historial', style: body(13, weight: FontWeight.w600, color: p.inkMuted)),
          ),
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final q in list)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radiusControl),
                border: Border.all(color: p.line),
                color: p.panel,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  onTap: () => onPick(q),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(q, overflow: TextOverflow.ellipsis, style: body(14, color: p.ink)),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => settings.removeSearch(q),
                  child: Padding(padding: const EdgeInsets.all(8), child: Icon(LucideIcons.x, size: 14, color: p.inkMuted)),
                ),
              ]),
            ),
        ]),
      ]),
    );
  }
}
