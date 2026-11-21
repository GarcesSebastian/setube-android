// Cola de videos: links pegados, búsquedas, playlists, metadata, conversión y progreso.
// Mismo modelo que la web (queue.ts), pero el «servidor» es el servicio de descargas de Kotlin.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/formats.dart';
import '../core/parse.dart';
import '../core/url.dart';
import '../native/bridge.dart';
import '../services/youtube.dart';
import 'history.dart';
import 'pc.dart';
import 'settings.dart';

enum RowStatus { idle, queued, fetching, downloading, converting, done, error, canceled }

RowStatus _rowStatus(String? s) => switch (s) {
      'queued' => RowStatus.queued,
      'fetching' => RowStatus.fetching,
      'downloading' => RowStatus.downloading,
      'converting' => RowStatus.converting,
      'done' => RowStatus.done,
      'error' => RowStatus.error,
      'canceled' => RowStatus.canceled,
      _ => RowStatus.idle,
    };

enum MetaState { local, quick, full, error }

class QueueItem {
  QueueItem({required this.key, required this.videoId, this.listId, this.origin, this.title, this.duration});

  final String key;
  final String videoId;

  /// Playlist del link `watch?v=X&list=Y` (para «Agregar la playlist completa»).
  String? listId;

  /// Título de la playlist de la que vino.
  String? origin;
  String? title;
  String? author;
  int? duration;
  Meta? meta;
  MetaState metaState = MetaState.local;
  ErrCode? metaError;

  RowStatus status = RowStatus.idle;
  double pct = 0;
  double speed = 0;

  /// Velocidad de la conversión (× tiempo real) y datos de la última descarga, para enseñarlos en la fila.
  double conv = 0;
  int dlBytes = 0;
  int dlMs = 0;
  int convMs = 0;
  ErrCode? error;
  String? jobId;
  HistoryEntry? entry;

  String get url => watchUrl(videoId);
  String get thumbnail => thumbnailUrl(videoId);
  bool get active => const {RowStatus.queued, RowStatus.fetching, RowStatus.downloading, RowStatus.converting}.contains(status);
  bool get convertible => metaState != MetaState.error && !(meta?.live ?? false);
  bool get loadingMeta => metaState == MetaState.local || metaState == MetaState.quick;
}

class PlaylistCard {
  PlaylistCard({required this.key, required this.playlistId});
  final String key;
  final String playlistId;
  String? title;
  String? author;
  String? thumbnail;
  int? count;
  int skipped = 0;
  bool loading = true;
  ErrCode? error;
}

/// Resumen de la última tanda convertida, para la barra de abajo.
class RunSummary {
  const RunSummary({required this.ok, required this.total, required this.bytes, required this.avgBps, required this.elapsed});
  final int ok;
  final int total;
  final int bytes;
  final double avgBps;
  final Duration elapsed;
}

/// Lo que pasa ahora en la tanda: fase, velocidad de descarga, bytes bajados y velocidad de conversión.
class LiveRun {
  const LiveRun({
    required this.preparing,
    required this.downloading,
    required this.converting,
    required this.finished,
    required this.total,
    required this.speed,
    required this.bytes,
    required this.conv,
    required this.elapsed,
  });
  final int preparing;
  final int downloading;
  final int converting;
  final int finished;
  final int total;
  final double speed;
  final int bytes;
  final double conv;
  final Duration elapsed;
}

class Toast {
  const Toast(this.message, {this.action, this.onAction, this.secondary, this.onSecondary});
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;
}
