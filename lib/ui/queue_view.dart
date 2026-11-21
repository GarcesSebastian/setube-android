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
