import 'package:flutter/material.dart';

import '../big_picture_theme.dart';
import 'bpm_key_cap.dart';

/// 「进详情 / 启动」操作角标 —— 主页 shelf 卡与库页海报卡共用（v3.21）。
///
/// 视觉：深底胶囊 + 樱粉细描边，键帽图标随 [BpmInputModeScope] 自动切换：
/// - 键鼠：左键单击 = 进详情，双击 = 启动；
/// - 手柄：A = 进详情，X = 启动。
///
/// 受 [BpmGuideScope] 总开关控制，关闭时完全不渲染。
/// 淡入淡出（何时浮现）由宿主卡片决定 —— 主页随选中态、库页随焦点/悬停。
class BpmActionHintBadge extends StatelessWidget {
  const BpmActionHintBadge({super.key});

  @override
  Widget build(BuildContext context) {
    // 总开关关闭 → 不渲染
    if (!BpmGuideScope.enabledOf(context)) return const SizedBox.shrink();
    final gamepad = BpmInputModeScope.of(context) == BpmInputMode.gamepad;
    final List<Widget> parts;
    if (gamepad) {
      parts = [
        const BpmKeyCap(BpmKeyCapType.gamepadA, size: 19),
        const Text('进详情', style: kGuideHintStyle),
        const Text('/', style: kGuideHintDividerStyle),
        const BpmKeyCap(BpmKeyCapType.gamepadX, size: 19),
        const Text('启动', style: kGuideHintStyle),
      ];
    } else {
      parts = [
        const BpmKeyCap(BpmKeyCapType.mouseLeft, size: 17),
        const Text('进详情', style: kGuideHintStyle),
        const BpmKeyCap(BpmKeyCapType.mouseLeftDouble, size: 17),
        const Text('启动', style: kGuideHintStyle),
      ];
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xE017111D),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: BpmColors.cherryRose.withOpacity(0.55),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 7),
            parts[i],
          ],
        ],
      ),
    );
  }
}
