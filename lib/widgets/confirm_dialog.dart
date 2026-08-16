import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import 'interactive_wrapper.dart';

/// UX-06: 统一的危险操作确认对话框
///
/// 用法：
/// ```dart
/// final confirmed = await showConfirmDialog(
///   context: context,
///   title: '确认删除',
///   message: '确定要删除这个游戏吗？',
///   confirmText: '删除',
///   isDanger: true,
/// );
/// if (confirmed) { ... }
/// ```
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmText = '确认',
  String cancelText = '取消',
  String? hint,
  bool isDanger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ConfirmDialog(
      title: title,
      message: message,
      confirmText: confirmText,
      cancelText: cancelText,
      hint: hint,
      isDanger: isDanger,
    ),
  );
  return result ?? false;
}

class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmText;
  final String cancelText;
  final String? hint;
  final bool isDanger;

  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmText,
    required this.cancelText,
    this.hint,
    required this.isDanger,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isDanger ? AppColors.dangerRed : AppColors.infoBlue;

    return AlertDialog(
      backgroundColor: AppColors.sidebarBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border, width: 1.5),
      ),
      title: Text(
        title,
        style: AppStyles.headlineSmall.copyWith(letterSpacing: 1.5),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: AppStyles.dialogBody.copyWith(height: 1.6),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              style: AppStyles.hintRegular.copyWith(
                color: isDanger ? AppColors.dangerRed : null,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            cancelText,
            style: AppStyles.labelLarge.copyWith(color: AppColors.infoBlue),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            confirmText,
            style: AppStyles.labelLarge.copyWith(color: accentColor),
          ),
        ),
      ],
    );
  }
}
