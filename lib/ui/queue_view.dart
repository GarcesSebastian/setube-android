// Resultados de búsqueda, tarjetas de playlist y filas de la cola con progreso, ficha y acciones.

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/errors.dart';
import '../core/format.dart';
import '../core/formats.dart';
import '../core/parse.dart';
import '../native/bridge.dart';
import '../state/history.dart';
import '../state/pc.dart';
import '../state/player.dart';
import '../state/queue.dart';
import '../state/search.dart';
import 'command_bar.dart';
import 'pc_ui.dart';
import 'theme.dart';
import 'widgets.dart';

class SearchResults extends StatelessWidget {
  const SearchResults({super.key, required this.search, required this.queue});
  final SearchModel search;
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final q = search.query!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(
        'Resultados para «$q»',
        trailing: IconBtn(icon: LucideIcons.x, tooltip: 'Cerrar resultados', onPressed: search.close, size: 36),
      ),
      if (search.loading)
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const Skeleton(width: 120, height: 68, radius: radiusControl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                  Skeleton(height: 14),
                  SizedBox(height: 8),
                  Skeleton(width: 140, height: 12),
                ]),
              ),
            ]),
          )
      else if (search.error != null)
        Panel(
          child: Row(children: [
            Icon(LucideIcons.circleAlert, color: p.redInk, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(searchErrorText(search.error!), style: body(14, color: p.ink))),
            Btn(label: 'Buscar de nuevo', compact: true, onPressed: () => search.search(q)),
          ]),
        )
      else if (search.results.isEmpty)
        Text('Sin resultados.', style: body(14, color: p.inkMuted))
      else
        for (final r in [...search.results.where((r) => !r.live), ...search.results.where((r) => r.live)])
          _SearchRow(item: r, queue: queue),
    ]);
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.item, required this.queue});
  final SearchItem item;
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final inQueue = queue.contains(item.videoId);
    final sub = [item.author, if (item.views != null) '${formatViews(item.views)} vistas'].whereType<String>().join(' · ');
    return InkWell(
      onTap: item.live || inQueue ? null : () => queue.addSearchItem(item),
      borderRadius: BorderRadius.circular(radiusControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          VideoThumb(
            url: item.thumbnail,
            width: 120,
            child: Align(
              alignment: Alignment.bottomRight,
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: item.live ? p.red : Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(radiusSeg),
                ),
                child: Text(item.live ? 'En vivo' : formatDuration(item.duration),
                    style: mono(11, weight: FontWeight.w600, color: Colors.white)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title ?? 'Video de YouTube', maxLines: 2, overflow: TextOverflow.ellipsis, style: body(14.5, weight: FontWeight.w500, color: p.ink, height: 1.3)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(12.5, color: p.inkMuted)),
              if (inQueue) Text('En la cola', style: body(12.5, weight: FontWeight.w600, color: p.ok)),
            ]),
          ),
          IconBtn(
            icon: inQueue ? LucideIcons.check : LucideIcons.plus,
            tooltip: inQueue ? 'En la cola' : 'Agregar a la cola',
            color: inQueue ? p.ok : p.ink,
            onPressed: item.live || inQueue ? null : () => queue.addSearchItem(item),
          ),
        ]),
      ),
    );
  }
}

class PlaylistCardView extends StatelessWidget {
  const PlaylistCardView({super.key, required this.card, required this.queue});
  final PlaylistCard card;
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          if (card.thumbnail != null) VideoThumb(url: card.thumbnail!, width: 88) else const Skeleton(width: 88, height: 50, radius: radiusControl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Playlist', style: body(12, weight: FontWeight.w600, color: p.redInk)),
              if (card.loading)
                const Padding(padding: EdgeInsets.only(top: 4), child: Skeleton(width: 160, height: 14))
              else if (card.error != null)
                Text(messageFor(card.error!), style: body(13.5, color: p.ink))
              else ...[
                Text(card.title ?? 'Playlist', maxLines: 2, overflow: TextOverflow.ellipsis, style: body(14.5, weight: FontWeight.w500, color: p.ink)),
                Text(
                  [
                    '${card.count ?? 0} videos',
                    card.author,
                    if (card.skipped > 0) '${card.skipped} ocultos',
                  ].whereType<String>().join(' · '),
                  style: body(12.5, color: p.inkMuted),
                ),
              ],
            ]),
          ),
          IconBtn(icon: LucideIcons.x, tooltip: 'Quitar tarjeta', onPressed: () => queue.removePlaylistCard(card.key), size: 36),
        ]),
      ),
    );
  }
}

/// «10,0 MB a 16,4 MB/s · convertido en 5,2 s» cuando terminó.
String doneStats(QueueItem i) {
  String secs(int ms) => '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
  final parts = <String>[
    if (i.dlBytes > 0 && i.dlMs > 0) '${formatBytes(i.dlBytes)} a ${formatSpeed(i.dlBytes / (i.dlMs / 1000))}',
    if (i.convMs > 0) 'convertido en ${secs(i.convMs)}',
  ];
  return parts.join(' · ');
}

String phaseLabel(QueueItem i) => switch (i.status) {
      RowStatus.idle => '',
      RowStatus.queued => 'En cola',
      RowStatus.fetching => 'Obteniendo datos',
      RowStatus.downloading => 'Descargando',
      RowStatus.converting => 'Convirtiendo',
      RowStatus.done => 'Listo',
      RowStatus.error => 'Error',
      RowStatus.canceled => 'Cancelada',
    };

MeterState meterState(QueueItem i) => switch (i.status) {
      RowStatus.done => MeterState.done,
      RowStatus.error => MeterState.error,
      RowStatus.idle || RowStatus.canceled => MeterState.idle,
      _ => MeterState.active,
    };

class QueueRow extends StatefulWidget {
  const QueueRow({super.key, required this.item, required this.queue, required this.player, required this.history, required this.pc});
  final QueueItem item;
  final QueueModel queue;
  final PlayerModel player;
  final HistoryModel history;
  final PcModel pc;

  @override
  State<QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<QueueRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final i = widget.item;
    final q = widget.queue;
    final pl = widget.player;
    final current = pl.track?.key == i.key;
    final playing = current && pl.isPlaying;
    final playable = pl.canPlay(i);
    final watchable = pl.canWatch(i);
    final m = i.meta;
    final size = m == null ? null : estimateBytes(m, q.format, q.quality);
    final st = meterState(i);
    final showMeter = i.status != RowStatus.idle;
    final phase = phaseLabel(i);
    final speed = switch (i.status) {
      RowStatus.downloading => formatSpeed(i.speed),
      RowStatus.converting => i.conv > 0 ? '${i.conv.toStringAsFixed(i.conv < 10 ? 1 : 0).replaceAll('.', ',')}× tiempo real' : '',
      _ => '',
    };
    final stats = i.status == RowStatus.done ? doneStats(i) : '';
    final sub = [
      i.author,
      if (i.duration != null && i.duration! > 0) formatDuration(i.duration),
      if (size != null) '~${formatBytes(size)}',
    ].whereType<String>().join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(
            onTap: playable ? () => pl.toggle(i) : null,
            child: VideoThumb(
              url: i.thumbnail,
              width: 96,
              ring: current,
              child: playable
                  ? Center(
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), shape: BoxShape.circle),
                        child: Icon(playing ? LucideIcons.pause : LucideIcons.play, size: 16, color: Colors.white),
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (i.title == null && i.loadingMeta)
                const Padding(padding: EdgeInsets.only(top: 2, bottom: 6), child: Skeleton(height: 14))
              else
                Text(i.title ?? 'Video de YouTube', maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: body(14.5, weight: FontWeight.w500, color: p.ink, height: 1.3)),
              if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(12.5, color: p.inkMuted)),
              if (i.origin != null)
                Text('De la playlist ${i.origin}', maxLines: 1, overflow: TextOverflow.ellipsis, style: body(12, color: p.inkMuted)),
            ]),
          ),
          IconBtn(icon: LucideIcons.x, tooltip: 'Quitar', size: 36, onPressed: () => q.remove(i.key)),
        ]),
        if (showMeter) ...[
          const SizedBox(height: 8),
          Meter(pct: i.pct, state: st),
          const SizedBox(height: 4),
          Row(children: [
            Text(
              st == MeterState.error ? '' : formatPct(i.pct, done: i.status == RowStatus.done),
              style: mono(12.5, weight: FontWeight.w600, color: p.ink),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(phase, style: body(12.5, color: i.status == RowStatus.error ? p.redInk : p.inkMuted))),
            if (speed.isNotEmpty) Text(speed, style: mono(12, color: p.inkMuted)),
          ]),
          if (stats.isNotEmpty) Text(stats, style: mono(11.5, color: p.inkMuted)),
        ],
        if (i.status == RowStatus.error && i.error != null)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(messageFor(i.error!), style: body(13, color: p.redInk))),
        if (i.metaState == MetaState.error && i.metaError != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(messageFor(i.metaError!), style: body(13, color: p.redInk))),
        if (i.loadingMeta && i.title != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(i.metaError != null ? 'No se pudieron leer los detalles.' : 'Leyendo detalles…', style: body(12, color: p.inkMuted)),
          ),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (watchable)
            Btn(
              label: current && pl.mode == 'video' ? 'Viendo' : 'Ver video',
              icon: LucideIcons.monitorPlay,
              compact: true,
              onPressed: () => current ? pl.setMode('video') : pl.playItem(i, video: true),
            ),
          if (i.status == RowStatus.done && i.entry != null && i.entry!.kind == 'file') ...[
            Btn(label: 'Abrir', icon: LucideIcons.play, compact: true, onPressed: () => widget.history.open(i.entry!)),
            Btn(label: 'Compartir', icon: LucideIcons.share2, compact: true, onPressed: () => widget.history.share(i.entry!)),
            Btn(label: 'Al PC', icon: LucideIcons.monitor, compact: true, onPressed: () => sendToPc(context, widget.pc, i.entry!, widget.queue.settings)),
          ] else if (i.status == RowStatus.done && i.entry != null)
            ...[
              Btn(label: 'Ver ZIP', icon: LucideIcons.fileArchive, compact: true, onPressed: () => widget.history.openFolder(i.entry!)),
              Btn(label: 'Al PC', icon: LucideIcons.monitor, compact: true, onPressed: () => sendToPc(context, widget.pc, i.entry!, widget.queue.settings)),
            ]
          else if (i.status == RowStatus.error || i.status == RowStatus.canceled)
            Btn(label: 'Reintentar', icon: LucideIcons.rotateCcw, compact: true, onPressed: q.busy ? null : () => q.retry(i))
          else if (!i.active && i.convertible)
            Btn(label: 'Descargar', icon: LucideIcons.download, compact: true, onPressed: q.busy ? null : () => q.convert(only: [i])),
          if (i.metaState == MetaState.error || (i.metaError != null && !isDefinitive(i.metaError!)))
            Btn(label: 'Reintentar detalles', icon: LucideIcons.refreshCw, compact: true, onPressed: () => q.retryMeta(i)),
          if (i.listId != null)
            Btn(label: 'Agregar la playlist', icon: LucideIcons.listPlus, compact: true, onPressed: () {
              final id = i.listId!;
              i.listId = null;
              q.addPlaylist(id);
            }),
          Btn(
            label: _open ? 'Ocultar ficha' : 'Ficha',
            icon: LucideIcons.info,
            kind: BtnKind.ghost,
            compact: true,
            onPressed: () => setState(() => _open = !_open),
          ),
        ]),
        if (_open) _Ficha(item: i, queue: q),
      ]),
    );
  }
}

class _Ficha extends StatelessWidget {
  const _Ficha({required this.item, required this.queue});
  final QueueItem item;
  final QueueModel queue;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = item.meta;
    Widget row(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 92, child: Text(k, style: body(13, color: p.inkMuted))),
            Expanded(child: v),
          ]),
        );
    String size(OutFormat f, int? q) {
      final b = m == null ? null : estimateBytes(m, f, q);
      return b == null ? '—' : formatBytes(b);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Panel(
        color: p.bg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          row('Canal', Text(item.author ?? '—', style: body(13.5, color: p.ink))),
          row('Duración', Text(formatDuration(item.duration).isEmpty ? '—' : formatDuration(item.duration), style: mono(13, color: p.ink))),
          if (item.origin != null) row('Playlist', Text(item.origin!, style: body(13.5, color: p.ink))),
          if (m != null && m.video.isNotEmpty)
            row('Resoluciones', Wrap(spacing: 4, runSpacing: 4, children: [for (final v in m.video) StatPill('${v.height}p')])),
          if (m != null) ...[
            row(
              'Audio',
              Text('MP3 ${size(OutFormat.mp3, 128)} / ${size(OutFormat.mp3, 192)} / ${size(OutFormat.mp3, 320)}\n'
                  'M4A ${size(OutFormat.m4a, null)} · WAV ${size(OutFormat.wav, null)}',
                  style: mono(12.5, color: p.ink)),
            ),
            if (m.video.isNotEmpty)
              row(
                'Video',
                Text([for (final q in const [360, 480, 720, 1080]) if (m.video.any((v) => v.height >= q)) '${q}p ${size(OutFormat.mp4, q)}'].join('\n'),
                    style: mono(12.5, color: p.ink)),
              ),
          ],
          if (m?.description != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(m!.description!, style: body(13, color: p.inkMuted))),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Btn(
                label: 'Abrir en YouTube',
                icon: LucideIcons.externalLink,
                kind: BtnKind.ghost,
                compact: true,
                onPressed: () => AppNative.openUrl(item.url),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
