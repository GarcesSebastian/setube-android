// Tokens visuales de la web (globals.css): mismos colores, radios y tipografías.

import 'package:material_ui/material_ui.dart';

@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.panel,
    required this.line,
    required this.edge,
    required this.ink,
    required this.inkMuted,
    required this.red,
    required this.redInk,
    required this.ok,
  });

  final Color bg, panel, line, edge, ink, inkMuted, red, redInk, ok;

  static const dark = Palette(
    bg: Color(0xFF16181B),
    panel: Color(0xFF1F2226),
    line: Color(0xFF2A2E33),
    edge: Color(0xFF6B727B),
    ink: Color(0xFFE9E7E2),
    inkMuted: Color(0xFF9BA1A9),
    red: Color(0xFFD7262C),
    redInk: Color(0xFFFF4D4F),
    ok: Color(0xFF47C47A),
  );

  static const light = Palette(
    bg: Color(0xFFECEEF0),
    panel: Color(0xFFFFFFFF),
    line: Color(0xFFD9DCE0),
    edge: Color(0xFF7A818B),
    ink: Color(0xFF15171A),
    inkMuted: Color(0xFF565D67),
    red: Color(0xFFC4161C),
    redInk: Color(0xFFC4161C),
    ok: Color(0xFF1C7A42),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) => t < 0.5 ? this : (other as Palette? ?? this);
}

const radiusPanel = 10.0;
const radiusControl = 6.0;
const radiusSeg = 2.0;

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}

/// Títulos: Archivo ancho (font-stretch 112,5 %) y negrita.
TextStyle display(double size, {FontWeight weight = FontWeight.w700, Color? color}) => TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      height: 1.2,
      color: color,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble()), const FontVariation('wdth', 112.5)],
    );

/// Cifras: JetBrains Mono con números tabulares.
TextStyle mono(double size, {FontWeight weight = FontWeight.w400, Color? color}) => TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: size,
      color: color,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      fontFeatures: const [FontFeature.tabularFigures()],
    );

TextStyle body(double size, {FontWeight weight = FontWeight.w400, Color? color, double height = 1.45}) => TextStyle(
      fontFamily: 'Plex',
      fontSize: size,
      height: height,
      color: color,
      fontWeight: weight,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
    );

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.dark ? Palette.dark : Palette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: p.red,
    brightness: b,
    primary: p.red,
    onPrimary: Colors.white,
    surface: p.panel,
    onSurface: p.ink,
    error: p.redInk,
  );
  final base = ThemeData(brightness: b, colorScheme: scheme, useMaterial3: true, fontFamily: 'Plex');
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.line,
    extensions: [p],
    textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink, fontFamily: 'Plex'),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: display(18, weight: FontWeight.w800, color: p.ink),
      shape: Border(bottom: BorderSide(color: p.line)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.ink,
      selectionColor: p.red.withValues(alpha: 0.45),
      selectionHandleColor: p.red,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.panel,
      contentTextStyle: body(14, color: p.ink),
      actionTextColor: p.redInk,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusControl),
        side: BorderSide(color: p.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusPanel), side: BorderSide(color: p.line)),
      titleTextStyle: display(18, color: p.ink),
      contentTextStyle: body(14, color: p.ink),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      textStyle: body(14, color: p.ink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusControl), side: BorderSide(color: p.line)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(radiusPanel)),
        side: BorderSide(color: p.line),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.red,
      inactiveTrackColor: p.line,
      thumbColor: p.ink,
      overlayColor: p.red.withValues(alpha: 0.15),
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : p.edge),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.red : p.line),
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.red : p.edge)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.red, linearTrackColor: p.line),
  );
}
