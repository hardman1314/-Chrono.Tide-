import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/app_colors.dart';
import 'package:chrono_tide/theme/app_style.dart';
import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/interactive_wrapper.dart';

/// HoverButton 语义变体（v3.9 按钮体系）widget 测试。
///
/// 验证四变体底色令牌、禁用灰化、文字色继承与点击回调。
/// ⚠️ 树外层必须包 AnimatedBuilder(AppThemeManager)：HoverButton 静态读
/// AppStyle，若树不随主题通知重建，250ms 过渡的首帧插值（t≈0 时仍为
/// warmSun 手绘档）会定格在组件上（真实应用由全局 AnimatedBuilder 覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeRegistry.resetForTest();
    ThemeRegistry.registerBuiltinThemes();
  });

  /// pump 语义按钮并返回其 BoxDecoration（取第一个带 color 的容器）
  Future<BoxDecoration?> pumpButton(
    WidgetTester tester, {
    required CtButtonVariant variant,
    VoidCallback? onTap,
    Widget? child,
  }) async {
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: AppThemeManager.instance,
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: HoverButton(
                variant: variant,
                onTap: onTap,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final w in tester.widgetList<AnimatedContainer>(
        find.byWidgetPredicate((w) => w is AnimatedContainer))) {
      final d = w.decoration;
      if (d is BoxDecoration && d.color != null) return d;
    }
    return null;
  }

  /// 包主题监听的通用壳
  Widget shell(Widget child) => AnimatedBuilder(
        animation: AppThemeManager.instance,
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: Center(child: child),
          ),
        ),
      );

  testWidgets('aurora 档 primary：强调色底', (tester) async {
    await AppThemeManager.instance.setThemeById('frost');
    final d = await pumpButton(tester,
        variant: CtButtonVariant.primary, onTap: () {});
    expect(d!.color, AppColors.selectedAccent);
  });

  testWidgets('aurora 档 primary：onTap=null 时禁用灰化 0.38', (tester) async {
    await AppThemeManager.instance.setThemeById('frost');
    await tester.pumpWidget(
      shell(
        HoverButton(
          variant: CtButtonVariant.primary,
          onTap: null,
          child: const Text('确定入库'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final opacity =
        tester.widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity)).last;
    expect(opacity.opacity, 0.38);
  });

  testWidgets('aurora 档 secondary：白卡底；ghost：透明底；danger：危险软底',
      (tester) async {
    await AppThemeManager.instance.setThemeById('frost');

    final secondary = await pumpButton(tester,
        variant: CtButtonVariant.secondary, onTap: () {});
    expect(secondary!.color, AppColors.buttonBackground);

    final ghost = await pumpButton(tester,
        variant: CtButtonVariant.ghost, onTap: () {});
    expect(ghost!.color, Colors.transparent);

    final danger = await pumpButton(tester,
        variant: CtButtonVariant.danger, onTap: () {});
    expect(danger!.color, AppStyle.dangerSoftBg);
  });

  testWidgets('语义模式文字色经 DefaultTextStyle 继承（primary=白字 aurora）',
      (tester) async {
    await AppThemeManager.instance.setThemeById('frost');
    await tester.pumpWidget(
      shell(
        HoverButton(
          variant: CtButtonVariant.primary,
          onTap: () {},
          child: const Text('确认入库'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('确认入库'));
    // Text 未显式指定 color → 继承 DefaultTextStyle（primary ink = 白）
    expect(text.style?.color, isNull);
  });

  testWidgets('点击回调正常触发', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      shell(
        HoverButton(
          variant: CtButtonVariant.primary,
          onTap: () => tapped = true,
          child: const Text('go'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets('classic 档（暖阳）primary：border 棕底 + 文字继承 ink',
      (tester) async {
    await AppThemeManager.instance.setThemeById('warmSun');
    final d = await pumpButton(tester,
        variant: CtButtonVariant.primary,
        onTap: () {},
        child: const Text('确认入库'));
    expect(d!.color, AppColors.border);
    final text = tester.widget<Text>(find.text('确认入库'));
    expect(text.style?.color, isNull); // 继承 ink = background 色
  });
}
