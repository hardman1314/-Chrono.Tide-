import 'package:flutter/material.dart';

import '../big_picture_theme.dart';
import 'bpm_key_cap.dart';

/// v3.21 手柄切页引导 —— LB/RB（L1/R1）在主页⇄库页间切换。
///
/// - 仅**手柄模式**渲染（键鼠点左侧 rail 切页，是既有直觉，不打扰）；
/// - 受 `BpmGuideScope` 总开关控制，关闭时完全不显示；
/// - 轻量半透明胶囊，IgnorePointer 不吃交互，常驻在内容区角落。
///
/// 手柄语义来源：shell `_handleGamepadPageShift`（LB/RB = 页面切换，
/// 主页⇄库循环）。之所以需要引导：LB/RB 是纯快捷键、界面上没有任何
/// 可见入口对应它，手柄新手几乎不可能自行发现。
class BpmPageSwitchHint extends StatelessWidget {
  const BpmPageSwitchHint({super.key});

  @override
  Widget build(BuildContext context) {
    // 总开关关闭 → 不渲染
    if (!BpmGuideScope.enabledOf(context)) return const SizedBox.shrink();
    // 仅手柄模式渲染
    if (BpmInputModeScope.of(context) != BpmInputMode.gamepad) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xE017111D),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: BpmColors.cherryRose.withOpacity(0.40),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BpmKeyCap(BpmKeyCapType.gamepadLB, size: 15),
            const SizedBox(width: 4),
            Text('主页', style: kGuideHintStyle),
            const SizedBox(width: 3),
            Text('/', style: kGuideHintDividerStyle),
            const SizedBox(width: 3),
            const BpmKeyCap(BpmKeyCapType.gamepadRB, size: 15),
            const SizedBox(width: 4),
            Text('库页', style: kGuideHintStyle),
          ],
        ),
      ),
    );
  }
}
