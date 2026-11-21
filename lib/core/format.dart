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

/// Vistas abreviadas: 950 → «950», 12_345 → «12 mil», 6_562_112 → «6,6 M», 1_531_204_677 → «1,5 mil M».
String formatViews(num? n) {
  if (n == null || !n.isFinite || n < 0) return '';
  String short(double v) => v < 10 ? _fixed1((v * 10).floor() / 10).replaceAll(RegExp(r',0$'), '') : _int(v.floor());
  if (n < 1000) return _int(n);
  if (n < 1e6) return '${short(n / 1e3)} mil';
  if (n < 1e9) return '${short(n / 1e6)} M';
  return '${short(n / 1e9)} mil M';
}

const _monthsShort = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const _months = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];
const _weekdays = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Hora como en WhatsApp: «2:05 p. m.».
String friendlyTime(DateTime d) {
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'a. m.' : 'p. m.'}';
}

/// «Hoy», «Ayer», «Lunes» (esta semana), «21 de noviembre» o «21 de noviembre de 2025» (otro año).
String friendlyDay(DateTime d, {DateTime? now}) {
  final l = d.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final day = DateTime(l.year, l.month, l.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Ayer';
  if (diff > 1 && diff < 7) return _cap(_weekdays[l.weekday - 1]);
  return '${l.day} de ${_months[l.month - 1]}${l.year == n.year ? '' : ' de ${l.year}'}';
}

/// Fecha corta para nombres de carpeta: «21 nov 2026».
String shortDate(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_monthsShort[l.month - 1]} ${l.year}';
}

/// Fecha corta local: «21 nov 2026, 14:05».
String formatDate(DateTime d) {
  final l = d.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${_monthsShort[l.month - 1]} ${l.year}, $hh:$mm';
}
