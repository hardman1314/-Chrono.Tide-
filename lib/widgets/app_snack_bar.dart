import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';

/// UX-09: 统一的主题适配 SnackBar 工具
///
/// 替代直接调用 `ScaffoldMessenger.of(context).showSnackBar`，
/// 确保所有 SnackBar 都适配当前主题（暗色/亮色）并保持一致的视觉风格。
///
/// 用法：
/// ```dart
/// AppSnackBar.success(context, '操作成功');
/// AppSnackBar.error(context, '操作失败');
/// AppSnackBar.warning(context, '请注意...');
/// AppSnackBar.info(context, '提示信息');
/// ```
class AppSnackBar {
  AppSnackBar._();

  static void success(BuildContext context, String message,
      {Duration? duration}) {
    _show(
      context,
      message: message,
      icon: Icons.check_circle_outline,
      backgroundColor: AppColors.successGreen,
      duration: duration ?? const Duration(seconds: 2, milliseconds: 500),
    );
  }

  static void error(BuildContext context, String message,
      {Duration? duration}) {
    _show(
      context,
      message: message,
      icon: Icons.error_outline,
      backgroundColor: AppColors.dangerRed,
      duration: duration ?? const Duration(seconds: 3),
    );
  }

  static void warning(BuildContext context, String message,
      {Duration? duration}) {
    _show(
      context,
      message: message,
      icon: Icons.warning_amber_outlined,
      backgroundColor: AppColors.starGold,
      duration: duration ?? const Duration(seconds: 3),
    );
  }

  static void info(BuildContext context, String message, {Duration? duration}) {
    _show(
      context,
      message: message,
      icon: Icons.info_outline,
      backgroundColor: AppColors.infoBlue,
      duration: duration ?? const Duration(seconds: 2, milliseconds: 500),
    );
  }

  static void _show(
    BuildContext context, {
    required String message,
    required IconData icon,
    required Color backgroundColor,
    required Duration duration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: AppStyles.bodyMedium.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          duration: duration,
          backgroundColor: backgroundColor,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(16),
          elevation: 6,
        ),
      );
  }
}
