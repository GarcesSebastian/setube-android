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
