// Formato de cifras en español, igual que la web (format.ts).

String _fixed1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

String _int(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return (v < 0 ? '-' : '') + b.toString();
}

/// 3725 → «1:02:05»; 222 → «3:42».
String formatDuration(num? sec) {
  if (sec == null || !sec.isFinite || sec < 0) return '';
  final s = sec.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// Bytes en unidades de 1000: 5_200_000 → «5,2 MB».
String formatBytes(num? bytes) {
  if (bytes == null || !bytes.isFinite || bytes < 0) return '';
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1000 && i < _units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${i == 0 ? _int(v) : _fixed1(v)} ${_units[i]}';
}

/// 2_400_000 → «2,4 MB/s».
String formatSpeed(num? bps) {
  if (bps == null || !bps.isFinite || bps <= 0) return '';
  return '${formatBytes(bps)}/s';
}

/// Un decimal mientras avanza, entero al terminar: «38,1 %», «100 %».
String formatPct(num pct, {bool done = false}) {
  final p = pct.isFinite ? pct.clamp(0, 100).toDouble() : 0.0;
  if (done || p >= 100) return '${_int(p)} %';
  return '${_fixed1((p * 10).floor() / 10)} %';
}
