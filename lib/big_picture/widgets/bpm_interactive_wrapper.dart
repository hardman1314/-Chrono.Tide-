import 'package:flutter/material.dart';
import '../big_picture_theme.dart';
import 'focus_glow.dart';

/// BPM 焦点感知交互包装器
///
/// 在桌面端 [InteractiveWrapper] (仅支持鼠标 hover) 基础上扩展,
/// 同时支持 **键盘焦点** + **鼠标悬停** + **触屏点击** 三种输入。
///
/// 状态优先级: 焦点态 > 悬停态 > 普通态
///
/// - **焦点态**: 通过 [FocusGlow] 提供高亮边框+辉光,缩放 [focusScale]
/// - **悬停态**: 无焦点边框,轻微缩放 [hoverScale]
/// - **普通态**: 无特效
/// - **禁用态** ([onTap] == null): 不响应任何交互,光标变 basic
///
/// 焦点态时按 Enter/Space 会触发 [onTap],与点击等价。
class BpmInteractiveWrapper extends StatefulWidget {
  /// 子组件
  final Widget child;

  /// 点击回调 (为 null 时视为禁用态)
  final VoidCallback? onTap;

  /// 双击回调 (BPM 游戏卡片双击启动)
  final VoidCallback? onDoubleTap;

  /// 长按回调 (BPM 游戏卡片长按弹出动作表)
  final VoidCallback? onLongPress;

  /// 焦点态缩放 (默认 [BigPictureTheme.cardFocusScale])
  final double focusScale;

  /// 悬停态缩放 (默认 [BigPictureTheme.cardHoverScale])
  final double hoverScale;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 是否自动获取焦点
  final bool autofocus;

  /// 外部传入焦点节点
  final FocusNode? focusNode;

  /// 鼠标光标 (禁用态会被强制为 basic)
  final MouseCursor cursor;

  /// 包含描述 (供读屏器)
  final String? semanticsLabel;

  const BpmInteractiveWrapper({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.focusScale = BigPictureTheme.cardFocusScale,
    this.hoverScale = BigPictureTheme.cardHoverScale,
    this.borderRadius,
    this.autofocus = false,
    this.focusNode,
    this.cursor = SystemMouseCursors.click,
    this.semanticsLabel,
  });

  @override
  State<BpmInteractiveWrapper> createState() => _BpmInteractiveWrapperState();
}

class _BpmInteractiveWrapperState extends State<BpmInteractiveWrapper> {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _isFocused) {
      setState(() => _isFocused = focused);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final effectiveCursor = disabled ? SystemMouseCursors.basic : widget.cursor;

    // 缩放优先级: focused > hovered > 1.0
    final scale = disabled
        ? 1.0
        : (_isFocused
            ? widget.focusScale
            : (_isHovered ? widget.hoverScale : 1.0));

    return MouseRegion(
      cursor: effectiveCursor,
      onEnter: disabled ? null : (_) => setState(() => _isHovered = true),
      onExit: disabled ? null : (_) => setState(() => _isHovered = false),
      child: FocusGlow(
        autofocus: widget.autofocus,
        focusNode: _focusNode,
        borderRadius: widget.borderRadius,
        semanticsLabel: widget.semanticsLabel,
        onSelect: disabled ? null : widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: BigPictureTheme.focusAnimDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: widget.onTap,
            onDoubleTap: widget.onDoubleTap,
            onLongPress: widget.onLongPress,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
