import 'package:flutter/material.dart';

import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';
import 'bpm_key_cap.dart';

/// v3.20 扳机键翻页引导 —— 侧缘呼吸键帽（用户拍板的轻量方案）。
///
/// - 仅手柄模式显示（键鼠用滚轮，是既有直觉，不打扰）；
/// - 确有上一页/下一页时才出现对应侧的 LT/RT，到尽头自动消失；
/// - 3s 周期极轻呼吸（透明度 0.45↔0.85），竖排「翻页」微字，
///   不弹窗、不占内容区、不破坏沉浸感。
///
/// 用 [NotificationListener] 捕获滚动指标（不需要控制器，对页面零侵入）。
class BpmTriggerPageHint extends StatefulWidget {
  final Widget child;

  const BpmTriggerPageHint({super.key, required this.child});

  @override
  State<BpmTriggerPageHint> createState() => _BpmTriggerPageHintState();
}

class _BpmTriggerPageHintState extends State<BpmTriggerPageHint>
    with SingleTickerProviderStateMixin {
  bool _canBack = false;
  bool _canForward = false;
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
      lowerBound: 0.45,
      upperBound: 0.85,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  void _onMetrics(ScrollMetrics m) {
    final back = m.extentBefore > 40;
    final forward = m.extentAfter > 40;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // v3.21: 操作引导总开关关闭 → 完全不渲染（仅透传子树）
    if (!BpmGuideScope.enabledOf(context)) return widget.child;
    final gamepad = BpmInputModeScope.of(context) == BpmInputMode.gamepad;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _onMetrics(n.metrics);
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          _onMetrics(n.metrics);
          return false;
        },
        child: Stack(
          children: [
            widget.child,
            // 侧缘键帽（渲染顺序在内容之上，IgnorePointer 不吃交互）
            if (gamepad) ...[
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 220),
                    opacity: _canForward ? 1 : 0,
                    child: _breathAnim(const _EdgeHint(trigger: 'RT')),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 220),
                    opacity: _canBack ? 1 : 0,
                    child: _breathAnim(const _EdgeHint(trigger: 'LT')),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _breathAnim(Widget child) => FadeTransition(
        opacity: _breath,
        child: child,
      );
}

class _EdgeHint extends StatelessWidget {
  final String trigger;
  const _EdgeHint({required this.trigger});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0x8E17111D),
          borderRadius: BorderRadius.horizontal(
            right: trigger == 'RT'
                ? const Radius.circular(0)
                : const Radius.circular(10),
            left: trigger == 'RT'
                ? const Radius.circular(10)
                : const Radius.circular(0),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BpmKeyCap(
              trigger == 'RT'
                  ? BpmKeyCapType.triggerRT
                  : BpmKeyCapType.triggerLT,
              size: 15,
            ),
            const SizedBox(height: 8),
            Text(
              '翻页',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 11,
                letterSpacing: 3,
                color: BpmColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
