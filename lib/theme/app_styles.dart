import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppStyles {
  AppStyles._();

  static const String zhFontFamily = 'ZhiMangXing';
  static const String enFontFamily = 'Mali';

  static TextStyle get titleLarge => TextStyle(
        fontFamily: zhFontFamily,
        fontSize: 30,
        height: 36 / 30,
        letterSpacing: 2.0,
        color: AppColors.border,
      );

  static TextStyle get heading => TextStyle(
        fontFamily: zhFontFamily,
        fontSize: 24,
        height: 32 / 24,
        letterSpacing: 2.4,
        color: AppColors.primaryText,
        fontWeight: FontWeight.w700,
      );

  static TextStyle get navActive => TextStyle(
        fontFamily: enFontFamily,
        fontSize: 24,
        height: 32 / 24,
        letterSpacing: 2.4,
        color: AppColors.primaryText,
        fontWeight: FontWeight.w700,
      );

  static TextStyle get navInactive => TextStyle(
        fontFamily: enFontFamily,
        fontSize: 24,
        height: 32 / 24,
        letterSpacing: 2.4,
        color: AppColors.secondaryText,
        fontWeight: FontWeight.w700,
      );

  static TextStyle get bodyRegular => TextStyle(
        fontFamily: enFontFamily,
        fontSize: 20,
        height: 28 / 20,
        color: AppColors.secondaryText,
      );

  static TextStyle get buttonText => TextStyle(
        fontFamily: enFontFamily,
        fontSize: 16,
        height: 24 / 16,
        color: AppColors.primaryText,
        fontWeight: FontWeight.w700,
      );

  static TextStyle get inputPlaceholder => TextStyle(
        fontFamily: zhFontFamily,
        fontSize: 24,
        height: 28 / 24,
        letterSpacing: 2.0,
        color: AppColors.placeholderText,
      );

  static TextStyle get gameTitle => TextStyle(
        fontFamily: enFontFamily,
        fontSize: 14,
        height: 20 / 14,
        color: AppColors.primaryText,
        fontWeight: FontWeight.w600,
      );
}
