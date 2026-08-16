import 'package:flutter/material.dart';
import 'custom_title_bar.dart' show kTitleBarHeight;

/// UX-03: 统一的弹窗进场/退场动画包装器
///
/// 提供 250ms 淡入+缩放进场 和 200ms 淡出退场动画，
/// 替代直接 OverlayEntry 插入/移除时的生硬切换。
///
/// 用法：
/// ```dart
/// _overlayKey = GlobalKey<AnimatedOverlayState>();
/// _overlay = OverlayEntry(
///   builder: (_) => AnimatedOverlay(
///     key: _overlayKey,
///     onDismissed: () { _overlay?.remove(); _overlay = null; },
///     child: MyModal(onClose: () => _overlayKey.currentState?.dismiss()),
///   ),
/// );
/// Overlay.of(context).insert(_overlay!);
/// ```
class AnimatedOverlay extends StatefulWidget {
  final Widget child;

  /// 退场动画播放完毕后回调（此时安全移除 OverlayEntry）
  final VoidCallback onDismissed;

  /// 遮罩层颜色，设为 Colors.transparent 可禁用遮罩
  final Color barrierColor;

  /// 点击遮罩层是否触发关闭
  final bool dismissOnBarrierTap;

  /// 内容对齐方式
  final Alignment alignment;

  /// 是否启用缩放动画（全屏内容可设为 false 仅用淡入淡出）
  final bool enableScale;

  /// 进场动画时长
  final Duration duration;

  /// 退场动画时长
  final Duration reverseDuration;

  const AnimatedOverlay({
    super.key,
    required this.child,
    required this.onDismissed,
    this.barrierColor = const Color(0x66000000),
    this.dismissOnBarrierTap = true,
    this.alignment = Alignment.center,
    this.enableScale = true,
    this.duration = const Duration(milliseconds: 250),
    this.reverseDuration = const Duration(milliseconds: 200),
  });

  @override
  State<AnimatedOverlay> createState() => AnimatedOverlayState();
}

class AnimatedOverlayState extends State<AnimatedOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  /// 触发退场动画，动画完成后回调 onDismissed
  void dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          children: [
            // --- 遮罩层 ---
            // 遮罩从标题栏下方开始，确保标题栏在弹窗打开时仍可交互
            if (widget.barrierColor != Colors.transparent)
              Positioned(
                top: kTitleBarHeight,
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: _controller.status == AnimationStatus.reverse,
                  child: Opacity(
                    opacity: _fadeAnimation.value,
                    child: widget.dismissOnBarrierTap
                        ? GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: dismiss,
                            child: Container(color: widget.barrierColor),
                          )
                        : Container(color: widget.barrierColor),
                  ),
                ),
              )
            else if (widget.dismissOnBarrierTap)
              Positioned(
                top: kTitleBarHeight,
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: _controller.status == AnimationStatus.reverse,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: dismiss,
                  ),
                ),
              ),
            // --- 内容层 ---
            Align(
              alignment: widget.alignment,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: widget.enableScale
                    ? ScaleTransition(
                        scale: _scaleAnimation,
                        child: child,
                      )
                    : child,
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
