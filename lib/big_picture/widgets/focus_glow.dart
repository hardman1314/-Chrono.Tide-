import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_colors.dart';
import '../big_picture_theme.dart';

/// BPM 焦点辉光指示器
///
/// 包裹任意需要在 BPM 中显示焦点状态的子组件,提供:
/// - **键盘焦点态**: 高亮边框 + 阴影 (使用 [AppColors.selectedAccent])
/// - **Enter/Space 激活**: 通过 [onSelect] 回调触发,等价于点击
/// - **自动聚焦**: 通过 [autofocus] 在首次构建时获取焦点
///
/// 与桌面端 [InteractiveWrapper] 仅支持鼠标 hover 不同,BPM 强调键盘/手柄可达性,
/// 因此本组件是 BPM 焦点系统的基础设施。
///
/// 使用方式:
/// ```dart
/// FocusGlow(
///   autofocus: true,
///   onSelect: () => _handleActivate(),
///   child: MyCard(),
/// )
/// ```
class FocusGlow extends StatefulWidget {
  /// 子组件
  final Widget child;

  /// 圆角,默认使用 [BigPictureTheme.defaultFocusRadius]
  final BorderRadius? borderRadius;

  /// 是否自动获取焦点
  final bool autofocus;

  /// Enter/Space 激活回调 (等价于 tap)
  final VoidCallback? onSelect;

  /// 外部传入的焦点节点 (用于父组件控制焦点)
  final FocusNode? focusNode;

  /// 包含描述 (供读屏器朗读)
  final String? semanticsLabel;

  const FocusGlow({
    super.key,
    required this.child,
    this.borderRadius,
    this.autofocus = false,
    this.onSelect,
    this.focusNode,
    this.semanticsLabel,
  });

  @override
  State<FocusGlow> createState() => _FocusGlowState();
}

class _FocusGlowState extends State<FocusGlow> {
  late final FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    // 仅销毁内部创建的节点,外部传入的由外部管理
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _isFocused) {
      setState(() => _isFocused = focused);
    }
  }

  /// 处理键盘事件: Enter / Space 触发 onSelect
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.onSelect == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      widget.onSelect!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BigPictureTheme.defaultFocusRadius;
    final glowColor = AppColors.selectedAccent;

    Widget core = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKeyEvent,
      child: AnimatedContainer(
        duration: BigPictureTheme.focusAnimDuration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: _isFocused
              ? Border.all(
                  color: glowColor,
                  width: BigPictureTheme.cardFocusGlowWidth,
                )
              : Border.all(
                  color: Colors.transparent,
                  width: BigPictureTheme.cardFocusGlowWidth),
          boxShadow: _isFocused
              ? [
                  BoxShadow(
                    color: glowColor.withOpacity(0.45),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
        ),
        child: widget.child,
      ),
    );

    // 包含描述 (供读屏器朗读) - 通过 Semantics widget 实现
    if (widget.semanticsLabel != null) {
      core = Semantics(
        button: true,
        label: widget.semanticsLabel,
        focused: _isFocused,
        child: core,
      );
    }
    return core;
  }
}
