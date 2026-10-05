import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/settings_modal.dart';

/// 设置 → 外观 →「系统主题」三张圆角方卡的排布回归测试。
///
/// 背景（2026-09-19）：卡片用 `Wrap` 横排，但每张卡外层是
/// `InteractiveWrapper`——其内部 `AnimatedContainer` 带 `alignment`
/// （Container 会转成 `Align`），`Align` 在有界约束下会撑满 `maxWidth`，
/// 于是每张卡各占一整行 → 实际渲染成「竖排 + 水平居中」。
/// 修复 = 在 Wrap 子项上先给出定宽槽位 `SizedBox(108×64)`。
///
/// 本测试锁定：三张卡在同一行、从左到右、顺序为 暖阳 → 浅色 → 深色。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeRegistry.resetForTest();
    ThemeRegistry.registerBuiltinThemes();
  });

  testWidgets('系统主题三张卡横向排列且顺序为 暖阳/浅色/深色', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: AppThemeManager.instance,
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SettingsModal(onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 切到「外观」页
    await tester.tap(find.text('外观'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 三张卡的定宽槽位（本页唯一以 108×64 出现的 SizedBox）
    final Finder slots = find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.width == 108 && w.height == 64);
    expect(slots, findsNWidgets(3), reason: '系统主题应有 3 张定宽卡片槽位');

    final List<Rect> rects = <Rect>[
      for (int i = 0; i < 3; i++) tester.getRect(slots.at(i)),
    ];

    // ① 同一行：三张卡的纵向中心重合（竖排时相邻卡 dy 会相差 72）
    expect(rects[1].center.dy, closeTo(rects[0].center.dy, 1.0),
        reason: '第 2 张卡应与第 1 张卡同行');
    expect(rects[2].center.dy, closeTo(rects[0].center.dy, 1.0),
        reason: '第 3 张卡应与第 1 张卡同行');

    // ② 从左到右依次排列，间距 = Wrap.spacing(8)
    expect(rects[0].left + 108 + 8, closeTo(rects[1].left, 1.0),
        reason: '第 2 张卡应紧跟在第 1 张卡右侧');
    expect(rects[1].left + 108 + 8, closeTo(rects[2].left, 1.0),
        reason: '第 3 张卡应紧跟在第 2 张卡右侧');

    // ③ 顺序：暖阳 → 浅色 → 深色
    const List<String> expectedNames = <String>['暖阳', '浅色', '深色'];
    for (int i = 0; i < expectedNames.length; i++) {
      expect(
        find.descendant(
            of: slots.at(i), matching: find.text(expectedNames[i])),
        findsOneWidget,
        reason: '第 ${i + 1} 张卡应为「${expectedNames[i]}」',
      );
    }
  });
}
