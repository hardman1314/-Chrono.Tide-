import 'package:flutter/material.dart';

import '../big_picture_theme.dart';
import '../focus/bpm_zone_focus_controller.dart';

/// BPM 板块高亮容器（规范第 6 条：**板块选择模式高亮整个板块容器**）
///
/// 与「组件操作模式高亮单个 UI 组件」（`FocusGlow` 的焦点环 + 缩放）在
/// 视觉语言上刻意区分：
/// - **板块**：樱粉 `cherryRose` 2px 圆角边框 + 外辉光 + 5% 底色，包住整个板块；
/// - **组件**：雾蓝 `selectedAccent` 焦点环 + `focusScale` 放大，只包单个控件。
///
/// 实现要点（🔴 勿改）：
/// - 高亮层是 `Positioned` + `IgnorePointer`，**不参与布局、不拦截命中测试** ——
///   鼠标操作与既有交互一行未动；
/// - 外层 `Stack` 必须 `clipBehavior: Clip.none`：边框靠负 `Positioned` 外扩到
///   内容之外（`Padding` 不允许负值），`Clip.hardEdge` 会把外扩部分削掉；
/// - `expand` 用负偏移换算，因此**不会**影响子组件尺寸与位置。
///
/// 未处于 BPM 子树（`BpmZoneFocusScope.maybeOf == null`）时直接返回 `child`，
/// 保证非 BPM 场景零影响。
class BpmFocusZone extends StatelessWidget {
  /// 本容器代表的板块
  final BpmZoneId zone;

  /// 板块内容
  final Widget child;

  /// 高亮框相对内容的外扩量（四边可不同；贴屏幕边缘的板块把该边设为 0）
  final EdgeInsets expand;

  /// 高亮框圆角（null = [BigPictureTheme.zoneFocusRadius]）
  final double? radius;

  const BpmFocusZone({
    super.key,
    required this.zone,
    required this.child,
    this.expand = const EdgeInsets.all(BigPictureTheme.zoneFocusExpand),
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final controller = BpmZoneFocusScope.maybeOf(context);
    if (controller == null) return child;

    final active = controller.isZoneMode && controller.zone == zone;
    final borderRadius =
        BorderRadius.circular(radius ?? BigPictureTheme.zoneFocusRadius);

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned(
          left: -expand.left,
          top: -expand.top,
          right: -expand.right,
          bottom: -expand.bottom,
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: BigPictureTheme.zoneFocusAnimDuration,
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: Border.all(
                  color: active ? BpmColors.cherryRose : Colors.transparent,
                  width: BigPictureTheme.zoneFocusBorderWidth,
                ),
                color: active
                    ? BpmColors.cherryRose.withOpacity(0.05)
                    : Colors.transparent,
                boxShadow: active
                    ? <BoxShadow>[
                        BoxShadow(
                          color: BpmColors.cherryRose.withOpacity(0.30),
                          blurRadius: 34,
                          spreadRadius: 1,
                        ),
                        BoxShadow(
                          color: BpmColors.deepBase.withOpacity(0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
