// Ajustes: sesión de YouTube, motor yt-dlp, carpetas, tema y notificaciones push.

import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../native/bridge.dart';
import '../state/pc.dart';
import '../state/settings.dart';
import 'pc_ui.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, required this.pc});
  final Settings settings;
  final PcModel pc;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SessionStatus? _session;
  String? _version;
  bool _busy = false;
  bool _updating = false;
  bool _diagnosing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await Session.status();
    if (mounted) setState(() => _session = s);
    try {
      final v = await Engine.version();
      if (mounted) setState(() => _version = '${v['ytdlp'] ?? ''}');
    } catch (_) {}
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(Future<SessionStatus> Function() f) async {
    setState(() => _busy = true);
    try {
      final s = await f();
      if (mounted) setState(() => _session = s);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importar cookies.txt'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Pega el contenido de un cookies.txt (formato Netscape) exportado de una sesión de YouTube.'),
          const SizedBox(height: 12),
          TextField(controller: c, maxLines: 6, minLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Importar')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _run(() => Session.importCookies(text));
    if (_session?.loggedIn != true) _snack('No se encontraron cookies de sesión de YouTube en el texto.');
  }

  Future<void> _update(String channel) async {
    setState(() => _updating = true);
    try {
      final r = await Engine.update(channel);
      if (!mounted) return;
      setState(() => _version = '${r['version'] ?? _version}');
      _snack(r['status'] == 'ALREADY_UP_TO_DATE' ? 'yt-dlp ya está al día' : 'yt-dlp actualizado a ${r['version']}');
    } catch (e) {
      _snack('No se pudo actualizar yt-dlp');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _diagnose() async {
    setState(() => _diagnosing = true);
    String report;
    try {
      report = await Engine.diagnose();
    } catch (e) {
      report = 'No se pudo completar el diagnóstico: $e';
    }
    if (!mounted) return;
    setState(() => _diagnosing = false);
    final p = context.pal;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnóstico'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(report, style: mono(11, color: p.ink))),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              Navigator.pop(ctx);
              _snack('Informe copiado');
            },
            child: const Text('Copiar'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = _session;
    final st = widget.settings;
    Widget radio(String value, String title, String sub) => RadioListTile<String>(
          value: value,
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: body(14.5, color: p.ink)),
          subtitle: Text(sub, style: body(12.5, color: p.inkMuted)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        const SectionTitle('Enviar al PC'),
        ListenableBuilder(
          listenable: widget.pc,
          builder: (context, _) {
            final pc = widget.pc;
            final f = pc.favorite;
            return Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(LucideIcons.monitor, color: f != null ? p.ok : p.inkMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f?.alias ?? 'Sin PC', style: body(15, weight: FontWeight.w600, color: p.ink)),
                      Text(
                        f == null
                            ? 'Manda las canciones a una carpeta del PC por la Wi‑Fi, con LocalSend.'
                            : (pc.auto ? 'Cada descarga se envía sola' : 'Toca «Enviar al PC» en cada descarga'),
                        style: body(12.5, color: p.inkMuted),
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Btn(
                    label: f == null ? 'Configurar' : 'Ajustes del PC',
                    icon: f == null ? LucideIcons.plus : LucideIcons.settings,
                    compact: true,
                    kind: f == null ? BtnKind.primary : BtnKind.secondary,
                    onPressed: () => showPcSetup(context, pc),
                  ),
                ),
              ]),
            );
          },
        ),
        const SectionTitle('Sesión de YouTube'),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(s?.loggedIn == true ? LucideIcons.shieldCheck : LucideIcons.user, color: s?.loggedIn == true ? p.ok : p.inkMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    s == null ? 'Comprobando…' : (s.loggedIn ? 'Sesión iniciada' : 'Sin sesión'),
                    style: body(15, weight: FontWeight.w600, color: p.ink),
                  ),
                  if (s != null && s.loggedIn)
                    Text(
                      '${s.source == 'imported' ? 'cookies.txt importado' : 'WebView de la app'} · ${s.count} cookies'
                      '${s.lastRefresh == null ? '' : ' · renovada ${formatDate(s.lastRefresh!)}'}',
                      style: body(12.5, color: p.inkMuted),
                    ),
                ]),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              'YouTube a veces pide confirmar que no eres un bot. Con la sesión iniciada en la app, yt-dlp usa las cookies '
              'del WebView, que se renuevan solas al abrir Setube. Usa una cuenta secundaria: YouTube puede limitar la cuenta.',
              style: body(13, color: p.inkMuted),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (s?.loggedIn == true) ...[
                Btn(label: 'Renovar ahora', icon: LucideIcons.refreshCw, compact: true, loading: _busy, onPressed: () => _run(() => Session.refresh(force: true))),
                Btn(label: 'Cerrar sesión', icon: LucideIcons.logOut, compact: true, kind: BtnKind.danger, onPressed: _busy ? null : () => _run(Session.logout)),
              ] else ...[
                Btn(label: 'Iniciar sesión', icon: LucideIcons.logIn, compact: true, kind: BtnKind.primary, loading: _busy, onPressed: () => _run(Session.login)),
                Btn(label: 'Importar cookies.txt', icon: LucideIcons.cookie, compact: true, onPressed: _busy ? null : _import),
              ],
            ]),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: s?.mode ?? 'auto',
              onChanged: (v) => v == null ? null : _run(() => Session.setMode(v)),
              child: Column(children: [
                radio('auto', 'Solo cuando YouTube la pida', 'Recomendado: primero sin sesión y, si YouTube bloquea, con la sesión.'),
                radio('always', 'Siempre', 'Todas las llamadas con la sesión. Necesario para videos con restricción de edad.'),
                radio('off', 'Nunca', 'No usa la sesión aunque esté iniciada.'),
              ]),
            ),
          ]),
        ),
        const SectionTitle('Motor de descarga'),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('yt-dlp', style: body(14.5, weight: FontWeight.w600, color: p.ink)),
              const Spacer(),
              Text(_version ?? '…', style: mono(13, color: p.inkMuted)),
            ]),
            const SizedBox(height: 6),
            Text(
              'YouTube cambia a menudo. Si algo deja de funcionar, actualiza yt-dlp: no hace falta instalar otro APK.',
              style: body(13, color: p.inkMuted),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              Btn(label: 'Actualizar', icon: LucideIcons.cloudDownload, compact: true, loading: _updating, onPressed: () => _update('stable')),
              Btn(label: 'Versión nightly', compact: true, kind: BtnKind.ghost, onPressed: _updating ? null : () => _update('nightly')),
            ]),
            const SizedBox(height: 12),
            Text(
              'Si YouTube rechaza las descargas o van lentas, el diagnóstico prueba un video con y sin sesión y mide la '
              'velocidad real. Copia el informe para revisarlo.',
              style: body(13, color: p.inkMuted),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Btn(label: 'Diagnóstico', icon: LucideIcons.gauge, compact: true, loading: _diagnosing, onPressed: _diagnose),
            ),
          ]),
        ),
        const SectionTitle('Carpetas'),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final (label, path, icon) in const [
              ('Audio', 'Music/Setube', LucideIcons.music2),
              ('Video', 'Movies/Setube', LucideIcons.film),
              ('ZIP', 'Download/Setube', LucideIcons.fileArchive),
            ])
              ListTile(
                leading: Icon(icon, color: p.inkMuted),
                title: Text(label, style: body(14.5, color: p.ink)),
                subtitle: Text(path, style: mono(12.5, color: p.inkMuted)),
                trailing: Icon(LucideIcons.folderOpen, color: p.ink, size: 20),
                onTap: () async {
                  if (!await Downloads.openFolder(path)) _snack('No se pudo abrir el gestor de archivos');
                },
              ),
          ]),
        ),
        const SectionTitle('Apariencia'),
        Panel(
          child: ListenableBuilder(
            listenable: st,
            builder: (_, _) => Segmented<ThemeMode>(
              value: st.theme,
              options: const [(ThemeMode.dark, 'Oscuro', LucideIcons.moon), (ThemeMode.light, 'Claro', LucideIcons.sun)],
              onChanged: (m) => st.theme = m,
            ),
          ),
        ),
        const SectionTitle('Aviso'),
        Text(
          'Setube es para contenido propio o sobre el que tengas permiso. Descargar material protegido sin autorización '
          'puede infringir los derechos de autor y los términos de YouTube.',
          style: body(13, color: p.inkMuted),
        ),
      ]),
    );
  }
}
