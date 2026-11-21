// Envío al PC: configuración en pocos pasos, botón en cada descarga y aviso de progreso.

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../native/bridge.dart';
import '../state/history.dart';
import '../state/pc.dart';
import '../state/settings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Pide la carpeta y envía la entrada al PC guardado (o, si aún no hay, abre la configuración).
Future<void> sendToPc(BuildContext context, PcModel pc, HistoryEntry e, Settings settings) async {
  if (pc.favorite == null) {
    await showPcSetup(context, pc);
    if (pc.favorite == null || !context.mounted) return;
  }
  final folder = await askPcFolder(context, e, settings, pc.favorite!.alias);
  if (folder == null) return;
  settings.addPcFolder(folder);
  await pc.send(e, folder: folder);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Enviando a ${pc.favorite!.alias}, carpeta «$folder»…')));
  }
}

/// Nombre de la carpeta del PC donde se guardan. `null` si se cancela.
Future<String?> askPcFolder(BuildContext context, HistoryEntry e, Settings settings, String pcName) {
  final c = TextEditingController(text: defaultFolder(e));
  c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
  final recent = settings.pcFolders;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final p = ctx.pal;
      void submit() {
        final v = cleanFolderName(c.text);
        if (v.isNotEmpty) Navigator.pop(ctx, v);
      }

      return AlertDialog(
        title: const Text('¿En qué carpeta?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              e.kind == 'zip'
                  ? 'Las ${e.count} canciones llegan sueltas (sin ZIP) a esta carpeta, dentro del destino de LocalSend en $pcName.'
                  : 'El archivo llega a esta carpeta, dentro del destino de LocalSend en $pcName.',
              style: body(13.5, color: p.inkMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => submit(),
              style: body(16, color: p.ink),
              decoration: InputDecoration(
                prefixIcon: Icon(LucideIcons.folder, color: p.inkMuted),
                border: const OutlineInputBorder(),
                hintText: 'Por ejemplo: Bachata',
              ),
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Usadas antes', style: body(12.5, color: p.inkMuted)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in recent)
                  ActionChip(
                    avatar: Icon(LucideIcons.folder, size: 16, color: p.ink),
                    label: Text(f, style: body(13.5, color: p.ink)),
                    onPressed: () => Navigator.pop(ctx, f),
                  ),
              ]),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton.icon(onPressed: submit, icon: const Icon(LucideIcons.send, size: 18), label: const Text('Enviar')),
        ],
      );
    },
  );
}

Future<void> showPcSetup(BuildContext context, PcModel pc) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.88, child: PcSetup(pc: pc)),
    );

class PcSetup extends StatefulWidget {
  const PcSetup({super.key, required this.pc});
  final PcModel pc;

  @override
  State<PcSetup> createState() => _PcSetupState();
}

class _PcSetupState extends State<PcSetup> {
  bool _searching = false;
  List<PcDevice>? _found;

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _found = null;
    });
    List<PcDevice> r;
    try {
      r = await widget.pc.discover();
    } catch (_) {
      r = const [];
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final pc = widget.pc;
    Widget step(int n, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: p.red, shape: BoxShape.circle),
              child: Text('$n', style: mono(14, weight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: body(15, weight: FontWeight.w600, color: p.ink)),
                Text(text, style: body(13.5, color: p.inkMuted)),
              ]),
            ),
          ]),
        );
    return ListenableBuilder(
      listenable: pc,
      builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
        Text('Enviar al PC', style: display(22, color: p.ink)),
        const SizedBox(height: 4),
        Text(
          'Las canciones llegan solas a una carpeta del PC, por la Wi‑Fi de la casa. Se configura una sola vez.',
          style: body(14, color: p.inkMuted),
        ),
        const SizedBox(height: 18),
        if (pc.favorite != null) ...[
          Panel(
            child: Row(children: [
              Icon(LucideIcons.monitor, color: p.ok),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pc.favorite!.alias, style: body(15.5, weight: FontWeight.w600, color: p.ink)),
                  Text('PC guardado · ${pc.favorite!.ip}', style: mono(12, color: p.inkMuted)),
                ]),
              ),
              TextButton(onPressed: pc.forget, child: Text('Olvidar', style: body(13.5, weight: FontWeight.w600, color: p.redInk))),
            ]),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: pc.auto,
            onChanged: pc.setAuto,
            title: Text('Enviar cada descarga automáticamente', style: body(15, color: p.ink)),
            subtitle: Text('Al terminar de convertir, las canciones se mandan solas al PC.', style: body(13, color: p.inkMuted)),
          ),
          const SizedBox(height: 8),
          Text('¿Cambiaste de PC?', style: body(13.5, weight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 4),
        ] else ...[
          step(1, 'Instala LocalSend en el PC',
              'Es gratis. En el PC abre el navegador, entra a localsend.org, toca «Descargar» y elige Windows. Al abrirlo por primera vez, si Windows pregunta, toca «Permitir acceso».'),
          step(2, 'Déjalo listo para recibir',
              'En LocalSend del PC ve a Ajustes y activa «Guardado rápido». En «Destino» elige la carpeta de la música (la que abres en VirtualDJ). Activa también «Iniciar con el sistema» para que esté siempre abierto.'),
          step(3, 'Misma Wi‑Fi', 'El teléfono y el PC conectados a la misma red de la casa. Luego toca «Buscar PC».'),
          Align(
            alignment: Alignment.centerLeft,
            child: Btn(label: 'Abrir localsend.org aquí', icon: LucideIcons.externalLink, compact: true, kind: BtnKind.ghost, onPressed: PcNative.installLink),
          ),
          const SizedBox(height: 12),
        ],
        Btn(
          label: _searching ? 'Buscando…' : 'Buscar PC',
          icon: LucideIcons.search,
          kind: BtnKind.primary,
          expand: true,
          loading: _searching,
          onPressed: _searching ? null : _search,
        ),
        const SizedBox(height: 12),
        if (_found != null && _found!.isEmpty)
          Panel(
            child: Text(
              'No encontré ningún PC. Revisa que LocalSend esté abierto en el PC, que los dos estén en la misma Wi‑Fi y que '
              'Windows le haya dado permiso de red (si no, ciérralo y ábrelo de nuevo: preguntará otra vez).',
              style: body(13.5, color: p.ink),
            ),
          ),
        if (_found != null)
          for (final d in _found!)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(children: [
                  Icon(d.isDesktop ? LucideIcons.monitor : LucideIcons.smartphone, color: p.ink),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.alias, style: body(15, weight: FontWeight.w600, color: p.ink)),
                      Text([d.model, d.ip].whereType<String>().join(' · '), style: mono(12, color: p.inkMuted)),
                    ]),
                  ),
                  Btn(
                    label: pc.favorite?.ip == d.ip ? 'Guardado' : 'Usar este',
                    compact: true,
                    kind: pc.favorite?.ip == d.ip ? BtnKind.secondary : BtnKind.primary,
                    onPressed: () async {
                      await pc.choose(d);
                      if (context.mounted) Navigator.of(context).maybePop();
                    },
                  ),
                ]),
              ),
            ),
      ]),
    );
  }
}

/// Aviso del envío en curso (o del último resultado) para la barra de abajo y el registro.
class PcBanner extends StatelessWidget {
  const PcBanner({super.key, required this.pc});
  final PcModel pc;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListenableBuilder(
      listenable: pc,
      builder: (context, _) {
        final t = pc.transfer;
        if (t == null) return const SizedBox.shrink();
        final done = t.status == 'done';
        final error = t.status == 'error';
        if (!t.active && !done && !error) return const SizedBox.shrink();
        final text = switch (t.status) {
          'queued' || 'connecting' => 'Buscando ${pc.favorite?.alias ?? 'el PC'}…',
          'sending' => 'Enviando a ${t.pc} · ${t.filesTotal > 1 ? '${t.files} de ${t.filesTotal} · ' : ''}'
              '${formatPct(t.fraction * 100)}${t.bps > 0 ? ' · ${formatSpeed(t.bps)}' : ''}',
          'done' => 'Enviado a ${t.pc}: ${t.filesTotal > 1 ? '${t.filesTotal} archivos' : t.name}',
          _ => pcErrorText(t.code),
        };
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: Row(children: [
            Icon(error ? LucideIcons.circleAlert : (done ? LucideIcons.circleCheck : LucideIcons.monitor),
                size: 18, color: error ? p.redInk : (done ? p.ok : p.ink)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: body(13, color: p.ink)),
                if (t.status == 'sending') ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radiusSeg),
                    child: LinearProgressIndicator(value: t.fraction, minHeight: 4),
                  ),
                ],
              ]),
            ),
            if (t.active)
              TextButton(onPressed: pc.cancel, child: Text('Cancelar', style: body(13, weight: FontWeight.w600, color: p.inkMuted)))
            else
              IconBtn(icon: LucideIcons.x, tooltip: 'Cerrar', size: 36, onPressed: pc.dismiss),
          ]),
        );
      },
    );
  }
}
