import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

/// 「记住登录」勾选框（2026-10-03 记住登录功能）。
///
/// 硬边像素风：16×16 方框，勾选时 accent 填充 + 白色对勾；
/// 未勾选时仅描边。点击整行切换（含文字），带手柄焦点支持。
class RememberMeCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const RememberMeCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InteractiveWrapper(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: value ? AppColors.selectedAccent : AppColors.background,
                  border: Border.all(
                    color: value ? AppColors.selectedAccent : AppColors.border,
                    width: 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border.withOpacity(0.25),
                      offset: const Offset(1, 1),
                      blurRadius: 0,
                    ),
                  ],
                ),
                child: value
                    ? Icon(Icons.check_rounded,
                        size: 12, color: AppColors.primaryText)
                    : null,
              ),
              const SizedBox(width: 7),
              Text(
                '记住登录',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
