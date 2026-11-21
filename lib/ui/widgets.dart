// Piezas comunes de la interfaz con el estilo de la web: paneles con borde, botones, chips y el medidor segmentado.

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.color});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.panel,
        borderRadius: BorderRadius.circular(radiusPanel),
        border: Border.all(color: p.line),
      ),
      child: child,
    );
  }
}

enum BtnKind { primary, secondary, ghost, danger }

class Btn extends StatelessWidget {
  const Btn({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.kind = BtnKind.secondary,
    this.expand = false,
    this.compact = false,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool expand;
  final bool compact;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final enabled = onPressed != null && !loading;
    final (Color bg, Color fg, Color border) = switch (kind) {
      BtnKind.primary => (p.red, Colors.white, p.red),
      BtnKind.secondary => (p.panel, p.ink, p.line),
      BtnKind.ghost => (Colors.transparent, p.ink, Colors.transparent),
      BtnKind.danger => (Colors.transparent, p.redInk, p.line),
    };
    final h = compact ? 36.0 : 44.0;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        else if (icon != null)
          Icon(icon, size: 18, color: fg),
        if ((icon != null || loading) && label.isNotEmpty) const SizedBox(width: 8),
        if (label.isNotEmpty)
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: body(14.5, weight: FontWeight.w600, color: fg))),
      ],
    );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusControl), side: BorderSide(color: border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Container(
            height: h,
            padding: EdgeInsets.symmetric(horizontal: label.isEmpty ? 0 : (compact ? 12 : 16)),
            width: label.isEmpty ? h : null,
            child: Align(widthFactor: expand ? null : 1, child: content),
          ),
        ),
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn({super.key, required this.icon, required this.tooltip, this.onPressed, this.color, this.size = 44, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: active ? p.line : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusControl)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(icon, size: 20, color: onPressed == null ? p.edge : (color ?? p.ink)),
          ),
        ),
      ),
    );
  }
}

/// Control segmentado (Audio | Video).
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String, IconData?)> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(radiusControl),
        border: Border.all(color: p.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label, icon) in options)
            GestureDetector(
              onTap: onChanged == null ? null : () => onChanged!(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: v == value ? p.panel : Colors.transparent,
                  borderRadius: BorderRadius.circular(radiusControl - 2),
                  border: Border.all(color: v == value ? p.line : Colors.transparent),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: v == value ? p.ink : p.inkMuted), const SizedBox(width: 6)],
                  Text(label, style: body(14, weight: FontWeight.w600, color: v == value ? p.ink : p.inkMuted)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class ChoiceChipX extends StatelessWidget {
  const ChoiceChipX({super.key, required this.label, required this.selected, this.onTap, this.monoFont = true});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool monoFont;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Material(
      color: selected ? p.ink : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusControl),
        side: BorderSide(color: selected ? p.ink : p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            widthFactor: 1,
            child: Text(
            label,
            style: monoFont
                ? mono(13.5, weight: FontWeight.w600, color: selected ? p.bg : p.ink)
                : body(14, weight: FontWeight.w500, color: selected ? p.bg : p.ink),
            ),
          ),
        ),
      ),
    );
  }
}

enum MeterState { idle, active, done, error }

/// Medidor segmentado de la web: 20 segmentos por fila y 24 en la barra general.
class Meter extends StatelessWidget {
  const Meter({super.key, required this.pct, this.state = MeterState.active, this.master = false});
  final double pct;
  final MeterState state;
  final bool master;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SizedBox(
      height: master ? 14 : 10,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: state == MeterState.error ? 0 : (pct.clamp(0, 100) / 100)),
        duration: const Duration(milliseconds: 200),
        builder: (_, v, _) => CustomPaint(
          painter: _MeterPainter(
            fraction: v,
            segs: master ? 24 : 20,
            off: p.line,
            on: state == MeterState.done ? p.ok : p.red,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({required this.fraction, required this.segs, required this.off, required this.on});
  final double fraction;
  final int segs;
  final Color off;
  final Color on;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / segs;
    final paint = Paint();
    final fillW = size.width * fraction;
    for (var i = 0; i < segs; i++) {
      final x = i * w;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w - 2, size.height), const Radius.circular(radiusSeg));
      paint.color = off;
      canvas.drawRRect(r, paint);
      if (fillW > x) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(x, 0, (fillW - x).clamp(0, w), size.height));
        paint.color = on;
        canvas.drawRRect(r, paint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_MeterPainter o) => o.fraction != fraction || o.on != on || o.off != off;
}

class VideoThumb extends StatelessWidget {
  const VideoThumb({super.key, required this.url, this.width = 96, this.ring = false, this.child});
  final String url;
  final double width;
  final bool ring;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: width,
      height: width * 9 / 16,
      decoration: BoxDecoration(
        color: p.line,
        borderRadius: BorderRadius.circular(radiusControl),
        border: ring ? Border.all(color: p.red, width: 2) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: (width * dpr).round(),
          errorBuilder: (_, _, _) => Icon(LucideIcons.music, color: p.edge),
        ),
        ?child,
      ]),
    );
  }
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 12, this.radius = radiusSeg});
  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(widget.radius)),
      ),
    );
  }
}

class StatPill extends StatelessWidget {
  const StatPill(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(radiusControl),
        border: Border.all(color: p.line),
      ),
      child: Text(text, style: mono(12.5, weight: FontWeight.w600, color: p.ink)),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
      child: Row(children: [
        Expanded(child: Text(text, style: display(16, color: context.pal.ink))),
        ?trailing,
      ]),
    );
  }
}
