import 'package:flutter/material.dart';
import 'app_colors.dart';

/// 字体策略（2026-09-08 三字体分工 → 2026-09-08 v2 改用得意黑）：
/// - F1 [zhDecorativeFont] 得意黑 (Smiley Sans)：中文装饰大标题（24-38px），几何装饰/重笔画
/// - F2 [enDecorativeFont] Outfit：英文/数字装饰，跨字号稳定
/// - F3 [uiFontFamily] Noto Sans SC：UI 功能字体（11-16px 按钮/标签/正文）
/// - 全部经 fonttools 子集化（项目扫描字符 + GB2312 一级常用字表 3755 字，覆盖动态游戏标题避免回退）
/// - pubspec.yaml fonts 段对应声明 SmileySans / Outfit / NotoSansSC
class AppStyles {
  AppStyles._();

  /// F3 · UI 功能字体（Noto Sans SC）
  static const String? uiFontFamily = 'NotoSansSC';

  /// F1 · 中文装饰大标题字体（得意黑 Smiley Sans）
  static const String? zhDecorativeFont = 'SmileySans';

  /// F2 · 英文/数字装饰字体（Outfit）
  static const String? enDecorativeFont = 'Outfit';

  // === 向后兼容别名（保留旧调用，避免破坏现有代码） ===
  static const String? zhFontFamily = zhDecorativeFont;
  static const String? enFontFamily = enDecorativeFont;

  // === 装饰性标题样式（F1 得意黑） ===

  static TextStyle get titleLarge => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 30,
        fontWeight: FontWeight.w400,
        height: 36 / 30,
        letterSpacing: 2.0,
        color: AppColors.primaryText,
      );

  static TextStyle get heading => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 32 / 24,
        letterSpacing: 2.4,
        color: AppColors.primaryText,
      );

  // === UI 功能性文字样式（F3 Noto Sans SC） ===

  static TextStyle get navActive => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 24 / 16,
        letterSpacing: 0.5,
        color: AppColors.primaryText,
      );

  static TextStyle get navInactive => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 24 / 16,
        letterSpacing: 0.5,
        color: AppColors.secondaryText,
      );

  static TextStyle get bodyRegular => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 20 / 14,
        color: AppColors.secondaryText,
      );

  static TextStyle get buttonText => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 22 / 15,
        color: AppColors.primaryText,
      );

  static TextStyle get inputPlaceholder => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 20 / 14,
        color: AppColors.placeholderText,
      );

  static TextStyle get gameTitle => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 20 / 14,
        color: AppColors.primaryText,
      );

  // === 补全 MD3 标准字体排版层级（修复 UX-02） ===
  // 完整覆盖 MD3 五大层级：display / headline / title / body / label

  // --- Display 层级（F1 得意黑） ---

  static TextStyle get displayLarge => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 36,
        fontWeight: FontWeight.w400,
        height: 44 / 36,
        letterSpacing: 1.5,
        color: AppColors.primaryText,
      );

  static TextStyle get displayMedium => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 28,
        fontWeight: FontWeight.w400,
        height: 36 / 28,
        letterSpacing: 1.5,
        color: AppColors.primaryText,
      );

  static TextStyle get displaySmall => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 32 / 24,
        letterSpacing: 1.2,
        color: AppColors.primaryText,
      );

  // --- Headline 层级（F1 得意黑） ---

  static TextStyle get headlineLarge => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 26,
        fontWeight: FontWeight.w400,
        height: 34 / 26,
        letterSpacing: 2.0,
        color: AppColors.primaryText,
      );

  static TextStyle get headlineMedium => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 24,
        fontWeight: FontWeight.w400,
        height: 32 / 24,
        letterSpacing: 2.2,
        color: AppColors.primaryText,
      );

  static TextStyle get headlineSmall => TextStyle(
        fontFamily: zhDecorativeFont,
        fontSize: 22,
        fontWeight: FontWeight.w400,
        height: 28 / 22,
        letterSpacing: 1.8,
        color: AppColors.primaryText,
      );

  // --- Title 层级（F3 Noto Sans SC） ---

  static TextStyle get titleMedium => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 24 / 16,
        letterSpacing: 0.5,
        color: AppColors.primaryText,
      );

  static TextStyle get titleSmall => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 20 / 14,
        letterSpacing: 0.4,
        color: AppColors.primaryText,
      );

  // --- Body 层级（F3 Noto Sans SC） ---

  static TextStyle get bodyLarge => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 24 / 16,
        color: AppColors.primaryText,
      );

  static TextStyle get bodyMedium => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 20 / 14,
        color: AppColors.primaryText,
      );

  static TextStyle get bodySmall => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 16 / 12,
        color: AppColors.secondaryText,
      );

  // --- Label 层级（F3 Noto Sans SC） ---

  static TextStyle get labelLarge => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 20 / 14,
        letterSpacing: 0.5,
        color: AppColors.primaryText,
      );

  static TextStyle get labelMedium => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 16 / 12,
        letterSpacing: 0.4,
        color: AppColors.secondaryText,
      );

  static TextStyle get labelSmall => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 14 / 11,
        letterSpacing: 0.4,
        color: AppColors.secondaryText,
      );

  static TextStyle get caption => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 16 / 12,
        color: AppColors.secondaryText,
      );

  // === 便捷别名（UX-02: 覆盖代码中高频使用的中间字号，F3 Noto Sans SC） ===

  /// 对话框/设置页正文（fontSize 15）—— 介于 bodyMedium(14) 和 bodyLarge(16) 之间
  /// 用于替代大量内联 `TextStyle(fontSize: 15)`
  static TextStyle get dialogBody => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 22 / 15,
        color: AppColors.primaryText,
      );

  /// 辅助说明文字（fontSize 13）—— 介于 bodySmall(12) 和 bodyMedium(14) 之间
  /// 用于替代大量内联 `TextStyle(fontSize: 13)`
  static TextStyle get hintRegular => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 18 / 13,
        color: AppColors.secondaryText,
      );

  /// 超小辅助文字（fontSize 10）—— 用于时间戳、版本号等极小文字
  static TextStyle get microCaption => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 10,
        fontWeight: FontWeight.w400,
        height: 14 / 10,
        color: AppColors.secondaryText,
      );

  /// 装饰性数字字体（F2 Outfit）—— 用于时间统计、版本号、装饰数字
  static TextStyle get decorativeNumber => TextStyle(
        fontFamily: enDecorativeFont,
        fontSize: 20,
        fontWeight: FontWeight.w400,
        height: 28 / 20,
        color: AppColors.primaryText,
      );
}

class AppRadius {
  AppRadius._();
  static const double xs = 2;
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 20;
}
