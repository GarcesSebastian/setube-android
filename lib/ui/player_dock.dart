// Parte fija de abajo: panel de video, mini reproductor y barra general con Convertir/Cancelar.

import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../state/pc.dart';
import '../state/player.dart';
import '../state/queue.dart';
import 'pc_ui.dart';
import 'theme.dart';
import 'widgets.dart';

class BottomDock extends StatelessWidget {
  const BottomDock({super.key, required this.queue, required this.player, required this.pc});
  final QueueModel queue;
  final PlayerModel player;
  final PcModel pc;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([queue, player, pc]),
      builder: (context, _) {
        final showMaster = queue.items.isNotEmpty;
        final showPc = pc.transfer != null;
        if (!player.hasTrack && !showMaster && !showPc) return const SizedBox.shrink();
        return Container(
          decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.line))),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (showPc) PcBanner(pc: pc),
              if (player.watching) VideoPanel(player: player),
              if (player.hasTrack) MiniPlayer(player: player),
              if (showMaster) MasterBar(queue: queue),
            ]),
          ),
        );
      },
    );
  }
}

class MasterBar extends StatelessWidget {
  const MasterBar({super.key, required this.queue});
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final o = queue.overall;
    final busy = queue.busy;
    final pending = queue.pending.length;
    final done = o.total > 0 && o.done == o.total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Meter(pct: o.pct, master: true, state: o.total == 0 ? MeterState.idle : (done ? MeterState.done : MeterState.active)),
            const SizedBox(height: 4),
            Text(
              o.total == 0
                  ? (pending == 0 ? 'Todo convertido' : '$pending ${pending == 1 ? 'video listo' : 'videos listos'} para convertir')
                  : '${o.done} de ${o.total} · ${formatPct(o.pct, done: done)}',
              style: mono(12.5, weight: FontWeight.w600, color: p.ink),
            ),
            // Velocidad general: en vivo mientras convierte y, al terminar, el resumen de la tanda
            ValueListenableBuilder<int>(
              valueListenable: queue.clock,
              builder: (_, _, _) {
                final line = speedLine(queue);
                if (line == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: mono(12, color: p.inkMuted)),
                );
              },
            ),
          ]),
        ),
        const SizedBox(width: 12),
        if (busy)
          Btn(label: 'Cancelar', icon: LucideIcons.x, kind: BtnKind.secondary, onPressed: queue.cancel)
        else
          Btn(
            label: pending > 1 ? 'Convertir $pending' : 'Convertir',
            icon: LucideIcons.download,
            kind: BtnKind.primary,
            onPressed: queue.canConvert ? () => queue.convert() : null,
          ),
      ]),
    );
  }
}

String _clock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// «↓ 16,4 MB/s · 12,3 MB · 0:07», «Convirtiendo 2 · 38× tiempo real · 0:12» o el resumen de la última tanda.
String? speedLine(QueueModel q) {
  final l = q.live;
  if (l != null) {
    final parts = <String>[
      if (l.preparing > 0) 'Preparando ${l.preparing}',
      if (l.downloading > 0) '↓ ${l.downloading} ${formatSpeed(l.speed).isEmpty ? '…' : formatSpeed(l.speed)}',
      if (l.converting > 0)
        'Convirtiendo ${l.converting}${l.conv > 0 ? ' ${l.conv.toStringAsFixed(l.conv < 10 ? 1 : 0).replaceAll('.', ',')}×' : ''}',
      if (l.preparing == 0 && l.downloading == 0 && l.converting == 0) (l.finished == l.total ? 'Guardando' : 'En cola'),
      if (l.bytes > 0) formatBytes(l.bytes),
      _clock(l.elapsed),
    ];
    return parts.join(' · ');
  }
  final r = q.lastRun;
  if (r == null) return null;
  final secs = '${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
  return [
    'Última: ${r.ok} de ${r.total} en $secs',
    if (r.bytes > 0) formatBytes(r.bytes),
    if (r.avgBps > 0) '↓ ${formatSpeed(r.avgBps)}',
  ].join(' · ');
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.player});
  final PlayerModel player;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final t = player.track!;
    final dur = player.durationMs;
    final pos = player.positionMs.clamp(0, dur > 0 ? dur : player.positionMs);
    final loading = player.status == PlayStatus.loading || player.status == PlayStatus.buffering;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 18,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: dur > 0 ? pos / dur : 0,
            onChanged: dur > 0 ? (v) => player.seek((v * dur).round()) : null,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
        child: Row(children: [
          VideoThumb(url: t.thumbnail, width: 56),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title ?? 'Video de YouTube', maxLines: 1, overflow: TextOverflow.ellipsis, style: body(13.5, weight: FontWeight.w600, color: p.ink)),
              Text(
                '${formatDuration(pos / 1000)} / ${formatDuration(dur / 1000)}${t.author == null ? '' : ' · ${t.author}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(11.5, color: p.inkMuted),
              ),
            ]),
          ),
          IconBtn(icon: LucideIcons.skipBack, tooltip: 'Anterior', size: 40, onPressed: player.prev),
          SizedBox(
            width: 44,
            height: 44,
            child: loading
                ? Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: p.ink))
                : IconBtn(
                    icon: player.isPlaying ? LucideIcons.pause : LucideIcons.play,
                    tooltip: player.isPlaying ? 'Pausar' : 'Reproducir',
                    onPressed: player.playPause,
                  ),
          ),
          IconBtn(icon: LucideIcons.skipForward, tooltip: 'Siguiente', size: 40, onPressed: player.neighbor(1) == null ? null : player.next),
          IconBtn(
            icon: player.watching ? LucideIcons.headphones : LucideIcons.monitorPlay,
            tooltip: player.watching ? 'Solo audio' : 'Ver video',
            size: 40,
            onPressed: () => player.setMode(player.watching ? 'audio' : 'video'),
          ),
          IconBtn(icon: LucideIcons.x, tooltip: 'Cerrar', size: 40, onPressed: player.close),
        ]),
      ),
    ]);
  }
}
