import 'package:flutter/material.dart';
import 'app_theme_manager.dart';

class AppColors {
  AppColors._();

  static Color get background => AppThemeManager.colors.background;
  static Color get pageBackground => AppThemeManager.colors.hasBackgroundImage
      ? Colors.transparent
      : AppThemeManager.colors.background;
  static Color get sidebarBackground =>
      AppThemeManager.colors.sidebarBackground;
  static Color get titleBarBackground =>
      AppThemeManager.colors.titleBarBackground;
  static Color get primaryText => AppThemeManager.colors.primaryText;
  static Color get secondaryText => AppThemeManager.colors.secondaryText;
  static Color get border => AppThemeManager.colors.border;
  static Color get borderLight => AppThemeManager.colors.borderLight;
  static Color get buttonBackground => AppThemeManager.colors.buttonBackground;
  static Color get selectedBlue => AppThemeManager.colors.selectedBlue;
  static Color get dangerRed => AppThemeManager.colors.dangerRed;
  static Color get placeholderText => AppThemeManager.colors.placeholderText;
  static Color get placeholderBg => AppThemeManager.colors.placeholderBg;
  static Color get addCoverBg => AppThemeManager.colors.addCoverBg;
  static Color get shadowColor => AppThemeManager.colors.shadowColor;
  static Color get successGreen => AppThemeManager.colors.successGreen;
  static Color get successBg => AppThemeManager.colors.successBg;
  static Color get errorBg => AppThemeManager.colors.errorBg;
  static Color get hoverCloseBg => AppThemeManager.colors.hoverCloseBg;
  static Color get hoverCloseBorder => AppThemeManager.colors.hoverCloseBorder;
  static Color get inputHint => AppThemeManager.colors.inputHint;
  static Color get cardHoverBg => AppThemeManager.colors.cardHoverBg;
  static Color get navActiveBg => AppThemeManager.colors.navActiveBg;
  static Color get navActiveBorder => AppThemeManager.colors.navActiveBorder;
  static Color get navInactiveBorder =>
      AppThemeManager.colors.navInactiveBorder;
  static Color get toggleBg => AppThemeManager.colors.toggleBg;
  static Color get toggleBorder => AppThemeManager.colors.toggleBorder;
  static Color get toggleIcon => AppThemeManager.colors.toggleIcon;
  static Brightness get brightness => AppThemeManager.colors.brightness;
  static bool get isDark => brightness == Brightness.dark;
}
