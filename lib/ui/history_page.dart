// Registro de descargas: abrir, ir a la carpeta, compartir (WhatsApp y demás) y borrar.

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../state/history.dart';
import '../state/pc.dart';
import '../state/settings.dart';
import 'pc_ui.dart';
import 'theme.dart';
import 'widgets.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.history, required this.pc, required this.settings});
  final HistoryModel history;
  final PcModel pc;
  final Settings settings;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    widget.history.load();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar el registro'),
        content: const Text('Se borra la lista de descargas. Los archivos se quedan en el teléfono.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok == true) await widget.history.clear();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final h = widget.history;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Descargas'),
        actions: [
          ListenableBuilder(
            listenable: h,
            builder: (_, _) => h.entries.isEmpty
                ? const SizedBox.shrink()
                : IconBtn(icon: LucideIcons.trash2, tooltip: 'Borrar el registro', onPressed: _clear),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: SafeArea(top: false, child: PcBanner(pc: widget.pc)),
      body: ListenableBuilder(
        listenable: h,
        builder: (context, _) {
          if (!h.loaded) return const Center(child: CircularProgressIndicator());
          if (h.entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Todavía no hay descargas', style: display(20, color: p.ink)),
                const SizedBox(height: 6),
                Text(
                  'Cada archivo o ZIP que guardes aparece aquí. Un video va a Música/Setube o Películas/Setube; '
                  'varios a la vez, en un ZIP dentro de Descargas/Setube.',
                  style: body(14, color: p.inkMuted),
                ),
              ]),
            );
          }
          // Agrupado por día: «Hoy», «Ayer», «Lunes», «17 de noviembre»…
          final rows = <Widget>[];
          String? day;
          for (final e in h.entries) {
            final d = friendlyDay(e.createdAt);
            if (d != day) {
              day = d;
              rows.add(Padding(
                padding: EdgeInsets.fromLTRB(4, rows.isEmpty ? 4 : 18, 4, 8),
                child: Text(d, style: display(15, color: p.ink)),
              ));
            }
            rows.add(Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EntryCard(entry: e, history: h, pc: widget.pc, settings: widget.settings, snack: _snack),
            ));
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: rows);
        },
      ),
    );
  }
}

class _EntryCard extends StatefulWidget {
  const _EntryCard({required this.entry, required this.history, required this.pc, required this.settings, required this.snack});
  final HistoryEntry entry;
  final HistoryModel history;
  final PcModel pc;
  final Settings settings;
  final void Function(String) snack;

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  bool _open = false;

  Future<void> _delete() async {
    final e = widget.entry;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entryTitle(e), maxLines: 2, overflow: TextOverflow.ellipsis),
        content: const Text('¿Quitarlo solo del registro o borrar también el archivo del teléfono?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'entry'), child: const Text('Solo del registro')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'file'), child: const Text('Borrar archivo')),
        ],
      ),
    );
    if (choice == null) return;
    await widget.history.remove(e, deleteFile: choice == 'file');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final e = widget.entry;
    final h = widget.history;
    final icon = e.kind == 'zip'
        ? LucideIcons.fileArchive
        : (e.mime.startsWith('video') ? LucideIcons.fileVideo : LucideIcons.fileAudio);
    final contents = entryContents(e);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(radiusControl), border: Border.all(color: p.line)),
            child: Icon(icon, color: e.exists ? p.redInk : p.edge, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entryTitle(e), maxLines: 2, overflow: TextOverflow.ellipsis, style: body(15, weight: FontWeight.w600, color: p.ink, height: 1.3)),
              if (contents != null)
                Text(contents, maxLines: 2, overflow: TextOverflow.ellipsis, style: body(13, color: p.ink, height: 1.35)),
              const SizedBox(height: 2),
              Text(entryDetails(e), style: body(12.5, color: p.inkMuted)),
              Text(
                e.exists ? 'En ${friendlyPath(e.relativePath)}' : 'El archivo ya no está en el teléfono',
                style: body(12.5, color: e.exists ? p.inkMuted : p.redInk),
              ),
              if (e.failed > 0) Text('${e.failed} no se pudieron convertir', style: body(12.5, color: p.redInk)),
            ]),
          ),
          IconBtn(icon: LucideIcons.trash2, tooltip: 'Borrar', size: 36, onPressed: _delete),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Btn(
            label: 'Abrir',
            icon: e.kind == 'zip' ? LucideIcons.fileArchive : LucideIcons.play,
            compact: true,
            onPressed: e.exists ? () async => (await h.open(e)) ? null : widget.snack('No hay una app para abrir este archivo') : null,
          ),
          Btn(
            label: 'Carpeta',
            icon: LucideIcons.folderOpen,
            compact: true,
            onPressed: () async => (await h.openFolder(e)) ? null : widget.snack('No se pudo abrir el gestor de archivos'),
          ),
          Btn(
            label: 'Enviar al PC',
            icon: LucideIcons.monitor,
            compact: true,
            kind: BtnKind.primary,
            onPressed: e.exists ? () => sendToPc(context, widget.pc, e, widget.settings) : null,
          ),
          Btn(
            label: 'Compartir',
            icon: LucideIcons.share2,
            compact: true,
            onPressed: e.exists ? () => h.share(e) : null,
          ),
          if (e.items.length > 1)
            Btn(
              label: _open ? 'Ocultar contenido' : 'Contenido',
              icon: LucideIcons.listMusic,
              kind: BtnKind.ghost,
              compact: true,
              onPressed: () => setState(() => _open = !_open),
            ),
        ]),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final it in e.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• ${it.title ?? it.videoId}${it.author == null ? '' : ' — ${it.author}'}',
                      style: body(13, color: p.inkMuted)),
                ),
            ]),
          ),
      ]),
    );
  }
}
