import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class InteractiveWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final MouseCursor cursor;
  final double hoverScale;
  final double pressScale;
  final Offset hoverOffset;
  final Offset pressOffset;
  final Duration duration;

  const InteractiveWrapper({
    super.key,
    required this.child,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
    this.hoverScale = 1.02,
    this.pressScale = 0.98,
    this.hoverOffset = const Offset(0, -1.5),
    this.pressOffset = Offset.zero,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  State<InteractiveWrapper> createState() => _InteractiveWrapperState();
}

class _InteractiveWrapperState extends State<InteractiveWrapper> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale =
        _pressed ? widget.pressScale : (_hovered ? widget.hoverScale : 1.0);
    final offset = _pressed
        ? widget.pressOffset
        : (_hovered ? widget.hoverOffset : Offset.zero);

    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()
            ..translate(offset.dx, offset.dy)
            ..scale(scale),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
  }
}

class HoverButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? normalColor;
  final Color? hoverColor;
  final Color? pressColor;
  final Color? borderColor;
  final Color? hoverBorderColor;
  final double borderWidth;
  final double hoverBorderWidth;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final List<BoxShadow>? normalShadow;
  final List<BoxShadow>? hoverShadow;
  final Duration duration;

  const HoverButton({
    super.key,
    required this.child,
    this.onTap,
    this.normalColor,
    this.hoverColor,
    this.pressColor,
    this.borderColor,
    this.hoverBorderColor,
    this.borderWidth = 2,
    this.hoverBorderWidth = 2.2,
    this.borderRadius = 6,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    this.normalShadow,
    this.hoverShadow,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  State<HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<HoverButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = _pressed
        ? (widget.pressColor ??
            widget.hoverColor ??
            widget.normalColor ??
            AppColors.buttonBackground)
        : (_hovered
            ? (widget.hoverColor ?? AppColors.buttonBackground)
            : (widget.normalColor ?? AppColors.buttonBackground));
    final bColor = _hovered
        ? (widget.hoverBorderColor ?? widget.borderColor ?? AppColors.border)
        : (widget.borderColor ?? AppColors.border);
    final bWidth = _hovered ? widget.hoverBorderWidth : widget.borderWidth;
    final shadow = _hovered
        ? (widget.hoverShadow ??
            [
              const BoxShadow(
                  color: Color(0x338B7355), offset: Offset(0, 3), blurRadius: 8)
            ])
        : (widget.normalShadow ??
            [
              BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ]);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: widget.duration,
          curve: Curves.easeOutCubic,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: bColor, width: bWidth),
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: shadow,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
