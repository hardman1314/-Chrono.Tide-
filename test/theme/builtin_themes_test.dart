import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/app_colors.dart';
import 'package:chrono_tide/theme/theme_storage.dart';
import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

/// 系统级「浅色 frost / 深色 obsidian」现代主题预设回归测试。
///
/// 覆盖（方案 docs/DEV/features/modern_light_dark_theme_plan.md §8）：
/// 1. 内置注册数 6 → 8，新 id 可取；
/// 2. 亮度与显示名正确（浅色=light / 深色=dark）；
/// 3. setThemeById 可切换到两套新主题；
/// 4. frost↔obsidian 的 250ms 过渡 lerp 不抛异常、中点后切换元数据；
/// 5. toJson/fromJson 往返 37 个颜色令牌一致（内置主题可被完整序列化）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeRegistry.resetForTest();
    ThemeRegistry.registerBuiltinThemes();
  });

  group('内置主题注册', () {
    test('注册数 8 → 6，且包含 frost / obsidian', () {
      final manager = AppThemeManager.instance;
      // 2026-09-13：暗夜/暮光移除（与浅/深现代主题性质重合）
      expect(manager.allThemeIds.length, 6);
      expect(manager.allThemeIds, containsAll(<String>['frost', 'obsidian']));
      expect(manager.allThemeIds, isNot(contains('darkNight')));
      expect(manager.allThemeIds, isNot(contains('twilight')));
    });

    test('frost：浅色、显示名「浅色」、按 id 可取', () {
      final data = AppThemeManager.instance.themeDataById('frost');
      expect(data, isNotNull);
      expect(data!.brightness, Brightness.light);
      expect(data.name, '浅色');
      expect(data.isFeatured, isFalse);
      expect(data.hasBackgroundImage, isFalse);
    });

    test('obsidian：深色、显示名「深色」、按 id 可取', () {
      final data = AppThemeManager.instance.themeDataById('obsidian');
      expect(data, isNotNull);
      expect(data!.brightness, Brightness.dark);
      expect(data.name, '深色');
      expect(data.isFeatured, isFalse);
      expect(data.hasBackgroundImage, isFalse);
    });

    test('枚举顺序：经典配色成对排列（暖阳·浅色·深色在前）', () {
      final standard = AppThemeManager.standardThemes;
      expect(standard.map((t) => t.name).toList(),
          <String>['warmSun', 'frost', 'obsidian']);
      // 特色主题不受影响
      expect(AppThemeManager.featuredThemes.map((t) => t.name).toList(),
          <String>['mint', 'sakura', 'ocean']);
    });
  });

  group('主题切换', () {
    test('setThemeById 可切换到 frost / obsidian', () async {
      final manager = AppThemeManager.instance;
      await manager.setThemeById('obsidian');
      expect(AppThemeManager.colors.id, 'obsidian');
      expect(AppThemeManager.colors.brightness, Brightness.dark);

      await manager.setThemeById('frost');
      expect(AppThemeManager.colors.id, 'frost');
      expect(AppThemeManager.colors.brightness, Brightness.light);
    });
  });

  group('过渡动画插值', () {
    test('frost↔obsidian lerp 不抛异常，t≥0.5 切换元数据', () {
      final frost = AppThemeManager.instance.themeDataById('frost')!;
      final obsidian = AppThemeManager.instance.themeDataById('obsidian')!;

      final mid = CTThemeData.lerp(frost, obsidian, 0.4);
      expect(mid.id, 'frost');
      expect(mid.background, isNot(frost.background)); // 颜色确在插值

      final after = CTThemeData.lerp(frost, obsidian, 0.6);
      expect(after.id, 'obsidian');

      final end = CTThemeData.lerp(frost, obsidian, 1.0);
      expect(end.background, obsidian.background);
    });
  });

  group('JSON 往返', () {
    void expectRoundTrip(CTThemeData data) {
      final restored = CTThemeData.fromJson(data.toJson());
      expect(restored.id, data.id);
      expect(restored.name, data.name);
      expect(restored.brightness, data.brightness);
      expect(restored.background, data.background);
      expect(restored.sidebarBackground, data.sidebarBackground);
      expect(restored.titleBarBackground, data.titleBarBackground);
      expect(restored.primaryText, data.primaryText);
      expect(restored.secondaryText, data.secondaryText);
      expect(restored.border, data.border);
      expect(restored.borderLight, data.borderLight);
      expect(restored.buttonBackground, data.buttonBackground);
      expect(restored.selectedAccent, data.selectedAccent);
      expect(restored.dangerRed, data.dangerRed);
      expect(restored.placeholderText, data.placeholderText);
      expect(restored.placeholderBg, data.placeholderBg);
      expect(restored.addCoverBg, data.addCoverBg);
      expect(restored.shadowColor, data.shadowColor);
      expect(restored.successGreen, data.successGreen);
      expect(restored.successBg, data.successBg);
      expect(restored.errorBg, data.errorBg);
      expect(restored.hoverCloseBg, data.hoverCloseBg);
      expect(restored.hoverCloseBorder, data.hoverCloseBorder);
      expect(restored.inputHint, data.inputHint);
      expect(restored.cardHoverBg, data.cardHoverBg);
      expect(restored.navActiveBg, data.navActiveBg);
      expect(restored.navActiveBorder, data.navActiveBorder);
      expect(restored.navInactiveBorder, data.navInactiveBorder);
      expect(restored.toggleBg, data.toggleBg);
      expect(restored.toggleBorder, data.toggleBorder);
      expect(restored.toggleIcon, data.toggleIcon);
      expect(restored.placeholderCover, data.placeholderCover);
      expect(restored.titleBrown, data.titleBrown);
      expect(restored.starGold, data.starGold);
      expect(restored.infoBlue, data.infoBlue);
      expect(restored.brandBlue, data.brandBlue);
      expect(restored.infoBg, data.infoBg);
    }

    test('frost 除 seedColor 外 36 令牌往返一致', () {
      expectRoundTrip(AppThemeManager.instance.themeDataById('frost')!);
    });

    test('obsidian 除 seedColor 外 36 令牌往返一致', () {
      expectRoundTrip(AppThemeManager.instance.themeDataById('obsidian')!);
    });

    test('seedColor 往返一致（v3.9 修复后回归锁）', () {
      // 历史 bug：toJson 写顶层 / fromJson 读 colors['seedColor'] → 丢失回退暖棕。
      // v3.9 起双向写入 + 兼容读，此测试锁死修复成果，禁止回退。
      final frost = AppThemeManager.instance.themeDataById('frost')!;
      final restored = CTThemeData.fromJson(frost.toJson());
      expect(restored.seedColor, frost.seedColor);
      // 历史格式兼容：只有顶层 seedColor 的旧 JSON 也能读出
      final legacyJson = frost.toJson()..['colors'].remove('seedColor');
      expect(CTThemeData.fromJson(legacyJson).seedColor, frost.seedColor);
    });

    test('风格档 JSON 兼容：老主题不写 style，新主题写 aurora', () {
      final warmSun = AppThemeManager.instance.themeDataById('warmSun')!;
      expect(warmSun.toJson().containsKey('style'), isFalse);
      expect(warmSun.visualStyle, CTVisualStyle.classicHanddrawn);

      final frost = AppThemeManager.instance.themeDataById('frost')!;
      expect(frost.toJson()['style'], 'aurora');
      // 旧 JSON（无 style 键）读出 classic
      final noStyle = Map<String, dynamic>.from(frost.toJson())..remove('style');
      expect(CTThemeData.fromJson(noStyle).visualStyle,
          CTVisualStyle.classicHanddrawn);
    });

    test('warningAmber：老主题回退 starGold，aurora 主题显式定义', () async {
      // 显式复位到暖阳：AppColors 为全局静态，前组用例可能已切换激活主题
      await AppThemeManager.instance.setThemeById('warmSun');
      final warmSun = AppThemeManager.instance.themeDataById('warmSun')!;
      expect(warmSun.warningAmber, isNull);
      expect(AppColors.warningAmber, warmSun.starGold);

      await AppThemeManager.instance.setThemeById('frost');
      expect(AppThemeManager.instance.themeDataById('frost')!.warningAmber,
          const Color(0xFFB97D10));
      expect(AppColors.warningAmber, const Color(0xFFB97D10));
    });
  });

  group('跟随系统主题（v3.9）', () {
    test('默认关闭；开启后按平台亮度切到系统主题（测试环境 light → frost）',
        () async {
      final manager = AppThemeManager.instance;
      await manager.setThemeById('warmSun');
      expect(manager.followSystemTheme, isFalse);

      await manager.setFollowSystemTheme(true);
      expect(manager.followSystemTheme, isTrue);
      expect(manager.currentThemeId, 'frost');
    });

    test('手动选择非系统对应主题时自动退出跟随', () async {
      final manager = AppThemeManager.instance;
      await manager.setFollowSystemTheme(true);
      expect(manager.followSystemTheme, isTrue);

      await manager.setThemeById('mint'); // 与 light 系统对应的 frost 不同
      expect(manager.followSystemTheme, isFalse);
      expect(manager.currentThemeId, 'mint');
    });

    test('手动点击当前生效的系统主题保持跟随', () async {
      final manager = AppThemeManager.instance;
      await manager.setFollowSystemTheme(true); // light → frost 已激活
      await manager.setThemeById('frost'); // 同 id：保持跟随
      expect(manager.followSystemTheme, isTrue);
    });

    test('关闭跟随不改变当前主题', () async {
      final manager = AppThemeManager.instance;
      await manager.setFollowSystemTheme(true);
      final before = manager.currentThemeId;
      await manager.setFollowSystemTheme(false);
      expect(manager.currentThemeId, before);
      expect(manager.followSystemTheme, isFalse);
    });

    test('loadSavedTheme：跟随开启时忽略持久化 id，按亮度加载', () async {
      final manager = AppThemeManager.instance;
      await manager.setFollowSystemTheme(true);
      // 模拟跟随开启前残留的手动选择（浅色主题）
      await ThemeStorage.saveActiveThemeId('warmSun');
      await manager.loadSavedTheme();
      expect(manager.followSystemTheme, isTrue);
      expect(manager.currentThemeId, 'frost');
    });
  });
}
