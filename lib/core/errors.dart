// Códigos de error y mensajes. Los de YouTube salen de la salida de yt-dlp, como en la API (ytdlp-errors.ts).

enum ErrCode {
  invalidUrl,
  videoUnavailable,
  privateVideo,
  ageRestricted,
  liveNotSupported,
  formatUnavailable,
  playlistUnavailable,
  playlistEmpty,
  upstreamBlocked,
  upstreamForbidden,
  upstreamError,
  upstreamTimeout,
  canceled,
  engine,
  network,
  storage,
  playerError,
  videoUnsupported,
  unknown,
}

ErrCode errCodeOf(String? s) {
  for (final c in ErrCode.values) {
    if (c.name == s) return c;
  }
  return ErrCode.unknown;
}

final _rules = <(RegExp, ErrCode)>[
  (RegExp(r'Sign in to confirm you.?re not a bot|confirm you are not a robot|LOGIN_REQUIRED', caseSensitive: false), ErrCode.upstreamBlocked),
  (RegExp(r'Private video', caseSensitive: false), ErrCode.privateVideo),
  (RegExp(r'confirm your age|age-restricted|inappropriate for some users', caseSensitive: false), ErrCode.ageRestricted),
  (
    RegExp(r'live event will begin|is live|Premieres in|This live stream recording is not available', caseSensitive: false),
    ErrCode.liveNotSupported
  ),
  (
    RegExp(r'Video unavailable|has been removed|account .* terminated|not (made this video )?available in your country',
        caseSensitive: false),
    ErrCode.videoUnavailable
  ),
  (RegExp(r'Requested format is not available', caseSensitive: false), ErrCode.formatUnavailable),
  (RegExp(r'HTTP Error 403|HTTP Error 410|The info failed to download', caseSensitive: false), ErrCode.upstreamForbidden),
  (RegExp(r'timed out|Connection reset|HTTP Error 5\d\d|Unable to download|Network is unreachable|Failed to resolve', caseSensitive: false),
      ErrCode.upstreamError),
];

ErrCode classifyYtdlpError(String stderr, {int exitCode = 1}) {
  for (final (re, code) in _rules) {
    if (re.hasMatch(stderr)) return code;
  }
  return exitCode == 0 ? ErrCode.unknown : ErrCode.upstreamError;
}

/// Errores que no cambian al reintentar: el video no se puede convertir.
bool isDefinitive(ErrCode c) => const {
      ErrCode.videoUnavailable,
      ErrCode.privateVideo,
      ErrCode.ageRestricted,
      ErrCode.liveNotSupported,
      ErrCode.invalidUrl,
    }.contains(c);

String messageFor(ErrCode c) => switch (c) {
      ErrCode.invalidUrl => 'Esto no parece un link de YouTube.',
      ErrCode.videoUnavailable => 'Este video no está disponible.',
      ErrCode.privateVideo => 'Este video es privado.',
      ErrCode.ageRestricted => 'Este video tiene restricción de edad. Inicia sesión para convertirlo.',
      ErrCode.liveNotSupported => 'Las transmisiones en vivo no se pueden convertir.',
      ErrCode.formatUnavailable => 'Este video no tiene una versión compatible con el formato elegido.',
      ErrCode.playlistUnavailable => 'No se pudo obtener la información de la playlist. Verifica la URL.',
      ErrCode.playlistEmpty => 'La playlist no tiene videos disponibles.',
      ErrCode.upstreamBlocked => 'YouTube pide iniciar sesión para confirmar que no eres un bot. Inicia sesión en Ajustes.',
      ErrCode.upstreamForbidden => 'YouTube rechazó la descarga. Intenta de nuevo en unos minutos.',
      ErrCode.upstreamError => 'No se pudo obtener el video de YouTube. Reintenta.',
      ErrCode.upstreamTimeout => 'YouTube tardó demasiado en responder. Reintenta.',
      ErrCode.canceled => 'La conversión fue cancelada.',
      ErrCode.engine => 'El motor de descarga no arrancó. Reinicia la app.',
      ErrCode.network => 'Sin conexión. Revisa tu red e intenta de nuevo.',
      ErrCode.storage => 'No se pudo guardar el archivo en el teléfono.',
      ErrCode.playerError => 'No se pudo reproducir el audio.',
      ErrCode.videoUnsupported => 'No se pudo reproducir el video. Cambiamos a solo audio.',
      ErrCode.unknown => 'Ocurrió un error inesperado. Intenta de nuevo.',
    };
