import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// UX-38: 焦点高亮边框容器。
///
/// 包裹任意可聚焦的子组件（如 TextField），当子组件获得焦点时，
/// 容器边框自动变为主题强调色并加粗，让用户明确当前活跃字段。
///
/// 基于 `Focus` 组件自动检测后代焦点，无需手动管理 FocusNode 生命周期；
/// 作为 StatefulWidget，焦点状态在父级 rebuild 时持久保留。
///
/// 注意：`normalColor`/`focusColor` 不能在编译期取默认值（AppColors 为运行时
/// getter，随主题切换动态变化），故用 nullable + build 内 fallback 的方式实现。
class FocusBorder extends StatefulWidget {
  final Widget child;

  /// 失焦时的边框颜色，默认 AppColors.border
  final Color? normalColor;

  /// 聚焦时的边框颜色，默认 AppColors.selectedAccent
  final Color? focusColor;

  final double normalWidth;
  final double focusWidth;

  final Color? bgColor;
  final List<BoxShadow>? boxShadow;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const FocusBorder({
    super.key,
    required this.child,
    this.normalColor,
    this.focusColor,
    this.normalWidth = 1.6,
    this.focusWidth = 2,
    this.bgColor,
    this.boxShadow,
    this.width,
    this.height,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  State<FocusBorder> createState() => _FocusBorderState();
}

class _FocusBorderState extends State<FocusBorder> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    final normalColor = widget.normalColor ?? AppColors.border;
    final focusColor = widget.focusColor ?? AppColors.selectedAccent;
    return Focus(
      canRequestFocus: false,
      onFocusChange: (focused) => setState(() => _hasFocus = focused),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: widget.bgColor,
          borderRadius: widget.borderRadius,
          border: Border.all(
            color: _hasFocus ? focusColor : normalColor,
            width: _hasFocus ? widget.focusWidth : widget.normalWidth,
          ),
          boxShadow: widget.boxShadow,
        ),
        child: widget.child,
      ),
    );
  }
}
