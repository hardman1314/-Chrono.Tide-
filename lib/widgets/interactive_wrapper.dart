import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_theme_manager.dart';

/// v3.9 按钮体系：语义变体（方案 button_system_upgrade_plan.md §2.1）
enum CtButtonVariant { primary, secondary, ghost, danger }

/// v3.9 按钮体系：尺寸档（影响默认 padding 与圆角）
enum CtButtonSize { lg, md, sm }

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
    // UX-27: onTap 为 null 时视为禁用态——不应用 hover 缩放/位移，光标改为 basic，
    // 避免禁用按钮（如"即将推出"）呈现可点击的悬停效果造成误导。
    final disabled = widget.onTap == null;
    final scale = disabled
        ? 1.0
        : (_pressed ? widget.pressScale : (_hovered ? widget.hoverScale : 1.0));
    final offset = disabled
        ? Offset.zero
        : (_pressed
            ? widget.pressOffset
            : (_hovered ? widget.hoverOffset : Offset.zero));
    final effectiveCursor = disabled ? SystemMouseCursors.basic : widget.cursor;

    return MouseRegion(
      cursor: effectiveCursor,
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

  /// v3.9：语义变体。非 null 时走语义令牌分支（忽略下方手填颜色参数，
  /// 文字/图标颜色经 DefaultTextStyle/IconTheme 继承）；
  /// null 时保持传统模式（历史调用点零回归）。
  final CtButtonVariant? variant;

  /// v3.9：尺寸档（仅语义模式生效），默认 md
  final CtButtonSize size;

  /// 语义模式下保持选中态样式（如锁定钮）
  final bool selected;
  final Color? normalColor;
  final Color? hoverColor;
  final Color? pressColor;
  final Color? borderColor;
  final Color? hoverBorderColor;
  final double borderWidth;
  final double hoverBorderWidth;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow>? normalShadow;
  final List<BoxShadow>? hoverShadow;
  final Duration duration;

  const HoverButton({
    super.key,
    required this.child,
    this.onTap,
    this.variant,
    this.size = CtButtonSize.md,
    this.selected = false,
    this.normalColor,
    this.hoverColor,
    this.pressColor,
    this.borderColor,
    this.hoverBorderColor,
    this.borderWidth = 2,
    this.hoverBorderWidth = 2.2,
    this.borderRadius = 6,
    this.padding,
    this.normalShadow,
    this.hoverShadow,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  State<HoverButton> createState() => _HoverButtonState();
}

/// v3.9 语义按钮解析结果（私有数据类，规避旧 analyzer 跨行 record 返回类型误析）
class _CtButtonVisual {
  final Color bg;
  final Border border;
  final List<BoxShadow>? shadow;
  final double radius;
  final EdgeInsetsGeometry padding;
  final TextStyle textStyle;
  final IconThemeData icon;
  const _CtButtonVisual({
    required this.bg,
    required this.border,
    required this.shadow,
    required this.radius,
    required this.padding,
    required this.textStyle,
    required this.icon,
  });
}

class _HoverButtonState extends State<HoverButton> {
  bool _hovered = false;
  bool _pressed = false;

  /// v3.9 语义模式：按变体解析 颜色/边/阴影/圆角/padding（方案 §2.2）
  _CtButtonVisual _resolveSemanticStyle() {
    final modern = AppStyle.isModern;
    final t = AppThemeManager.colors;
    final v = widget.variant!;
    final disabled = widget.onTap == null;
    final selected = widget.selected;

    // 尺寸档 → padding 与圆角
    final (EdgeInsetsGeometry pad, double radius) = switch (widget.size) {
      CtButtonSize.lg => (
          const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
          AppStyle.rLg
        ),
      CtButtonSize.sm => (
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          AppStyle.rSm
        ),
      CtButtonSize.md => (
          const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          AppStyle.rMd
        ),
    };
    final useRadius = widget.borderRadius != 6 ? widget.borderRadius : radius;

    final hovered = _hovered && !disabled;
    final pressed = _pressed && !disabled;

    Color bg;
    Border border;
    List<BoxShadow>? shadow;
    Color ink;

    switch (v) {
      case CtButtonVariant.primary:
        bg = pressed
            ? AppStyle.primaryButtonFillPressed
            : (hovered ? AppStyle.primaryButtonFillHover : AppStyle.primaryButtonFill);
        ink = AppStyle.primaryButtonInk;
        border = Border.all(color: bg, width: modern ? 0 : 2);
        shadow = modern
            ? (pressed || hovered ? AppStyle.e2 : AppStyle.e1)
            : (hovered || pressed
                ? [
                    BoxShadow(
                      color: AppStyle.primaryButtonFill.withAlpha(102),
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    )
                  ]
                : [
                    BoxShadow(
                      color: AppStyle.primaryButtonFill.withAlpha(102),
                      offset: const Offset(3, 4),
                      blurRadius: 0,
                    )
                  ]);
      case CtButtonVariant.secondary:
        bg = pressed
            ? Color.lerp(AppColors.buttonBackground, t.secondaryText, 0.08)!
            : (hovered || selected ? AppStyle.accentSoftBg : AppColors.buttonBackground);
        ink = (hovered || selected) && !pressed ? t.selectedAccent : t.primaryText;
        border = Border.all(
          color: (hovered || selected) ? t.selectedAccent : t.borderLight,
          width: modern ? AppStyle.wHairline : (hovered ? 1.6 : 1.2),
        );
        shadow = modern
            ? (pressed ? AppStyle.e1 : (hovered ? AppStyle.e2 : AppStyle.e1))
            : [
                BoxShadow(
                  color: t.borderLight,
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                )
              ];
      case CtButtonVariant.ghost:
        bg = (hovered || selected) ? AppStyle.accentSoftBg : Colors.transparent;
        ink = selected
            ? t.selectedAccent
            : (hovered ? t.primaryText : t.secondaryText);
        border = Border.all(color: Colors.transparent, width: 0);
        shadow = null;
      case CtButtonVariant.danger:
        bg = pressed
            ? Color.lerp(AppStyle.dangerSoftBg, t.dangerRed, 0.10)!
            : (hovered
                ? Color.lerp(AppStyle.dangerSoftBg, t.dangerRed, 0.06)!
                : AppStyle.dangerSoftBg);
        ink = t.dangerRed;
        border = Border.all(
          color: t.dangerRed.withAlpha(modern ? 77 : 128),
          width: modern ? AppStyle.wHairline : 1.2,
        );
        shadow = modern
            ? (hovered ? AppStyle.e1 : null)
            : [
                BoxShadow(
                  color: t.dangerRed.withAlpha(51),
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                )
              ];
    }

    return _CtButtonVisual(
      bg: bg,
      border: border,
      shadow: shadow,
      radius: useRadius,
      padding: widget.padding ?? pad,
      textStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      icon: IconThemeData(color: ink),
    );
  }

  @override
  Widget build(BuildContext context) {
    // v3.9：语义模式分支
    if (widget.variant != null) {
      final disabled = widget.onTap == null;
      final s = _resolveSemanticStyle();
      Widget button = AnimatedContainer(
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        padding: s.padding,
        decoration: BoxDecoration(
          // primary 极光档叠加顶部微光泽，提升质感
          gradient: (widget.variant == CtButtonVariant.primary &&
                  AppStyle.isModern &&
                  !disabled)
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withAlpha(26),
                    Colors.white.withAlpha(0),
                  ],
                  stops: const [0.0, 0.45],
                )
              : null,
          color: s.bg,
          border: s.border,
          borderRadius: BorderRadius.circular(s.radius),
          boxShadow: disabled ? null : s.shadow,
        ),
        child: DefaultTextStyle(
          style: s.textStyle,
          child: IconTheme(
            data: s.icon,
            child: widget.child,
          ),
        ),
      );
      if (disabled) {
        // 禁用：整体 38% 灰化（底/字同步弱化，视觉差明确）
        button = AnimatedOpacity(
          duration: widget.duration,
          opacity: 0.38,
          child: button,
        );
      }
      return MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: disabled
              ? null
              : (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: button,
        ),
      );
    }

    // ===== 传统模式（历史调用点，行为保持不变） =====
    final modern = AppStyle.isModern;
    final defaultBg = modern && _hovered && !_pressed
        ? AppColors.cardHoverBg
        : AppColors.buttonBackground;
    final bgColor = _pressed
        ? (widget.pressColor ?? widget.hoverColor ?? widget.normalColor ?? defaultBg)
        : (_hovered
            ? (widget.hoverColor ?? defaultBg)
            : (widget.normalColor ?? defaultBg));
    final bColor = _hovered
        ? (widget.hoverBorderColor ??
            widget.borderColor ??
            (modern ? AppColors.border : AppColors.border))
        : (widget.borderColor ??
            (modern ? AppColors.borderLight : AppColors.border));
    final bWidth = modern
        ? AppStyle.wHairline
        : (_hovered ? widget.hoverBorderWidth : widget.borderWidth);
    final shadow = modern
        ? (_pressed ? AppStyle.e1 : (_hovered ? AppStyle.e2 : AppStyle.e1))
        : (_hovered
            ? (widget.hoverShadow ??
                [
                  const BoxShadow(
                      color: Color(0x338B7355),
                      offset: Offset(0, 3),
                      blurRadius: 8)
                ])
            : (widget.normalShadow ??
                [
                  BoxShadow(
                      color: AppColors.border,
                      offset: const Offset(2, 3),
                      blurRadius: 0)
                ]));

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
          padding: widget.padding ??
              const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: bColor, width: bWidth),
            borderRadius: BorderRadius.circular(
                modern ? AppStyle.rMd : widget.borderRadius),
            boxShadow: shadow,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
