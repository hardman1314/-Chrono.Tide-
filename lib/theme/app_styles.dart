import 'package:flutter/material.dart';
import 'app_colors.dart';

/// 字体使用策略（修复 BUG-02）：
/// - [uiFontFamily]（Inter）：用于所有 UI 正文、功能性文字、输入提示、导航激活态等
/// - [zhDecorativeFont]（ZhiMangXing）：书法体，仅限装饰性大标题使用（如页面标题）
/// - [enDecorativeFont]（Mali）：手写体，仅限装饰性英文/数字标题使用（如百分比数字）
/// 禁止将装饰字体用于功能性文字，否则严重影响可读性
class AppStyles {
  AppStyles._();

  /// UI 正文字体，适用于所有功能性文字
  static const String uiFontFamily = 'Inter';

  /// 中文装饰字体（书法体），仅用于装饰性大标题
  static const String zhDecorativeFont = 'ZhiMangXing';

  /// 英文装饰字体（手写体），仅用于装饰性英文/数字标题
  static const String enDecorativeFont = 'Mali';

  // === 向后兼容别名（保留旧调用，避免破坏现有代码） ===
  static const String zhFontFamily = zhDecorativeFont;
  static const String enFontFamily = enDecorativeFont;

  // === 装饰性标题样式（仅用于页面大标题） ===

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

  // === UI 功能性文字样式（使用 Inter 字体，修复 BUG-02） ===
  // 原 navActive/navInactive/inputPlaceholder 使用装饰字体，已修正为 UI 字体

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

  // --- Display 层级（装饰性大标题，使用书法体） ---

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

  // --- Headline 层级（区域标题，使用书法体） ---

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

  // --- Title 层级（功能性标题/导航，使用 UI 字体） ---

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

  // --- Body 层级（正文内容，使用 UI 字体） ---

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

  // --- Label 层级（按钮/标签/辅助信息，使用 UI 字体） ---

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

  // === 便捷别名（UX-02: 覆盖代码中高频使用的中间字号） ===

  /// 对话框/设置页正文（fontSize 15）—— 介于 bodyMedium(14) 和 bodyLarge(16) 之间
  /// 用于替代大量内联 `TextStyle(fontFamily: 'Inter', fontSize: 15)`
  static TextStyle get dialogBody => TextStyle(
        fontFamily: uiFontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 22 / 15,
        color: AppColors.primaryText,
      );

  /// 辅助说明文字（fontSize 13）—— 介于 bodySmall(12) 和 bodyMedium(14) 之间
  /// 用于替代大量内联 `TextStyle(fontFamily: 'Inter', fontSize: 13)`
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

  /// 装饰性数字字体（仅用于百分比、统计数字等装饰场景）
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
