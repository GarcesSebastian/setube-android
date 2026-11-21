import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/format.dart';

void main() {
  test('velocidad con coma decimal', () {
    expect(formatSpeed(2400000), '2,4 MB/s');
    expect(formatSpeed(null), '');
    expect(formatSpeed(0), '');
  });

  test('duración h:mm:ss y m:ss', () {
    expect(formatDuration(3725), '1:02:05');
    expect(formatDuration(222), '3:42');
    expect(formatDuration(19), '0:19');
    expect(formatDuration(null), '');
  });

  test('bytes', () {
    expect(formatBytes(5200000), '5,2 MB');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1500000000), '1,5 GB');
  });

  test('porcentaje: un decimal mientras avanza, entero al terminar', () {
    expect(formatPct(38.14), '38,1 %');
    expect(formatPct(99.99), '99,9 %');
    expect(formatPct(100), '100 %');
    expect(formatPct(57.3, done: true), '57 %');
  });

  test('vistas abreviadas', () {
    expect(formatViews(950), '950');
    expect(formatViews(12345), '12 mil');
    expect(formatViews(6562112), '6,5 M');
    expect(formatViews(1531204677), '1,5 mil M');
    expect(formatViews(249332660), '249 M');
  });
}
