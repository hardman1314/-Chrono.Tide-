import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/app_colors.dart';
import 'package:chrono_tide/theme/app_style.dart';
import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

/// AppStyle 风格档回归测试（v3.9 Aurora，方案 §12）。
///
/// 核心保证：classicHanddrawn 档全部取值 == 组件历史硬编码值（逐值锁定，
/// 任何漂移测试即红 → 6 套老主题观感零影响）；aurora 档取值符合方案 §7。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeRegistry.resetForTest();
    ThemeRegistry.registerBuiltinThemes();
  });

  group('classic 档锁定（老主题观感保真）', () {
    setUp(() async {
      // AppColors/AppStyle 为全局静态：显式复位到暖阳，防跨组污染
      await AppThemeManager.instance.setThemeById('warmSun');
    });

    test('默认主题为 warmSun 且非 aurora', () {
      expect(AppThemeManager.instance.currentThemeId, 'warmSun');
      expect(AppStyle.style, CTVisualStyle.classicHanddrawn);
      expect(AppStyle.isModern, isFalse);
    });

    test('线宽档案 = 历史硬编码值', () {
      expect(AppStyle.wStrong, 2.0);
      expect(AppStyle.wNormal, 1.6);
      expect(AppStyle.wHairline, 1.0);
    });

    test('圆角档案 = 历史硬编码值', () {
      expect(AppStyle.rSm, 6.0);
      expect(AppStyle.rMd, 8.0);
      expect(AppStyle.rLg, 10.0);
      expect(AppStyle.rXl, 12.0);
      expect(AppStyle.rNavItem, 14.0);
    });

    test('海拔阴影 = 硬贴纸影 offset(2,2) blur 0', () {
      for (final shadow in <List<BoxShadow>>[AppStyle.e1, AppStyle.e2, AppStyle.e3]) {
        expect(shadow.length, 1);
        expect(shadow.first.offset, const Offset(2, 2));
        expect(shadow.first.blurRadius, 0);
      }
    });

    test('辉光环 = 空（手绘档无辉光）', () {
      expect(AppStyle.focusGlow(Colors.blue), isEmpty);
    });

    test('侧栏大导航项：边框/阴影 = 现行硬编码行为', () {
      // 静息：border 1.6，无阴影
      final rest = AppStyle.navHeroBorder(active: false, hovered: false);
      expect(rest.top.color, AppColors.border);
      expect(rest.top.width, 1.6);
      expect(AppStyle.navHeroShadow(active: false, hovered: false), isNull);
      // 激活：border 2.0 + 硬影 offset(2,3) blur 0
      final active = AppStyle.navHeroBorder(active: true, hovered: false);
      expect(active.top.width, 2.0);
      final activeShadow = AppStyle.navHeroShadow(active: true, hovered: false)!;
      expect(activeShadow.single.color, AppColors.border);
      expect(activeShadow.single.offset, const Offset(2, 3));
      expect(activeShadow.single.blurRadius, 0);
      // 悬停：hover 高亮投影 (0,3) blur 10
      final hoverShadow = AppStyle.navHeroShadow(active: false, hovered: true)!;
      expect(hoverShadow.single.color, AppColors.borderLight);
      expect(hoverShadow.single.offset, const Offset(0, 3));
      expect(hoverShadow.single.blurRadius, 10);
    });

    test('侧栏胶囊：边框/阴影/图标 = 现行硬编码行为', () {
      // 静息：navInactiveBorder@50%，无阴影
      final rest = AppStyle.navPillBorder(active: false, hovered: false);
      expect(rest.top.color, AppColors.navInactiveBorder.withAlpha(128));
      expect(rest.top.width, 1.0);
      expect(AppStyle.navPillShadow(active: false), isNull);
      // 激活：navActiveBorder + (0,1,6)@10% 阴影
      final active = AppStyle.navPillBorder(active: true, hovered: false);
      expect(active.top.color, AppColors.navActiveBorder);
      final activeShadow = AppStyle.navPillShadow(active: true)!;
      expect(activeShadow.single.color, AppColors.shadowColor.withAlpha(26));
      expect(activeShadow.single.offset, const Offset(0, 1));
      expect(activeShadow.single.blurRadius, 6);
      // 图标：激活 navActiveBorder / 悬停 border / 静息 navInactiveBorder
      expect(AppStyle.navIconColor(active: true, hovered: false),
          AppColors.navActiveBorder);
      expect(AppStyle.navIconColor(active: false, hovered: true), AppColors.border);
      expect(AppStyle.navIconColor(active: false, hovered: false),
          AppColors.navInactiveBorder);
    });

    test('warningAmber 回退 starGold（SnackBar 警告档历史行为）', () {
      expect(AppColors.warningAmber, AppColors.starGold);
    });
  });

  group('aurora 档（frost/obsidian）', () {
    test('frost 启用 aurora：线宽/圆角符合方案 §7', () {
      AppThemeManager.instance.setThemeById('frost');
      expect(AppStyle.isModern, isTrue);
      expect(AppStyle.wStrong, 1.0);
      expect(AppStyle.wNormal, 0.8);
      expect(AppStyle.wHairline, 0.5);
      expect(AppStyle.rSm, 6.0);
      expect(AppStyle.rMd, 10.0);
      expect(AppStyle.rLg, 14.0);
      expect(AppStyle.rXl, 18.0);
      expect(AppStyle.rNavItem, 12.0);
    });

    test('frost 海拔阴影为柔和体系 + 辉光环可用', () {
      AppThemeManager.instance.setThemeById('frost');
      expect(AppStyle.e1.single.offset, const Offset(0, 1));
      expect(AppStyle.e1.single.blurRadius, 3);
      expect(AppStyle.e2.single.offset, const Offset(0, 2));
      expect(AppStyle.e2.single.blurRadius, 8);
      expect(AppStyle.e3.single.offset, const Offset(0, 8));
      expect(AppStyle.e3.single.blurRadius, 24);
      final glow = AppStyle.focusGlow(AppColors.selectedAccent);
      expect(glow, isNotEmpty);
      expect(glow.first.blurRadius, 6);
    });

    test('obsidian 深色阴影重于浅色（海拔辅助层级规则）', () {
      AppThemeManager.instance.setThemeById('obsidian');
      final darkE2 = AppStyle.e2.single.color;
      AppThemeManager.instance.setThemeById('frost');
      final lightE2 = AppStyle.e2.single.color;
      expect(darkE2.alpha, greaterThan(lightE2.alpha));
    });

    test('侧栏导航：极光档静息白卡+发丝描边、激活带辉光', () {
      AppThemeManager.instance.setThemeById('frost');
      // 静息：可见发丝描边（borderLight）+ e1 阴影（石英白画布上不可隐形）
      final rest = AppStyle.navHeroBorder(active: false, hovered: false);
      expect(rest.top.color, AppColors.borderLight);
      final restShadow = AppStyle.navHeroShadow(active: false, hovered: false)!;
      expect(restShadow, AppStyle.e1);
      // 悬停：抬升 e2；激活：e2 + 强调辉光
      expect(AppStyle.navHeroShadow(active: false, hovered: true), AppStyle.e2);
      final activeShadow = AppStyle.navHeroShadow(active: true, hovered: false)!;
      expect(activeShadow.length, 2); // e2 + 强调辉光
      expect(AppStyle.navPillBorder(active: false, hovered: false).top.color,
          Colors.transparent);
      expect(AppStyle.navPillShadow(active: true)!.length, 2);
    });

    test('派生色：hover/pressed 与主色不同，软底为半透明强调色', () {
      AppThemeManager.instance.setThemeById('frost');
      expect(AppStyle.accentHover, isNot(AppColors.selectedAccent));
      expect(AppStyle.accentPressed, isNot(AppStyle.accentHover));
      expect(AppStyle.accentSoftBg.alpha, lessThan(255));
      expect(AppStyle.ringColor.alpha, lessThan(255));
    });

    test('语义按钮派生色 classic 档：primary=border 底/background 字（暖阳原味锁）',
        () {
      AppThemeManager.instance.setThemeById('warmSun');
      expect(AppStyle.primaryButtonFill, AppColors.border);
      expect(AppStyle.primaryButtonInk, AppColors.background);
      expect(AppStyle.dangerSoftBg, AppColors.errorBg);
    });

    test('语义按钮派生色 aurora 档：primary=强调色底白字，hover/pressed 递进',
        () {
      AppThemeManager.instance.setThemeById('frost');
      expect(AppStyle.primaryButtonFill, AppColors.selectedAccent);
      expect(AppStyle.primaryButtonInk, Colors.white);
      expect(AppStyle.primaryButtonFillHover,
          isNot(AppStyle.primaryButtonFill));
      expect(AppStyle.primaryButtonFillPressed,
          isNot(AppStyle.primaryButtonFillHover));
      expect(AppStyle.dangerSoftBg.alpha, lessThan(255));
    });

    test('lerp 过渡中点切换风格档（无中途混合态）', () {
      final frost = AppThemeManager.instance.themeDataById('frost')!;
      final warmSun = AppThemeManager.instance.themeDataById('warmSun')!;
      expect(CTThemeData.lerp(frost, warmSun, 0.4).visualStyle,
          CTVisualStyle.aurora);
      expect(CTThemeData.lerp(frost, warmSun, 0.6).visualStyle,
          CTVisualStyle.classicHanddrawn);
    });
  });
}
