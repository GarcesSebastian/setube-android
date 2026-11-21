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
