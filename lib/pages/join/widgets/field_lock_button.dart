import 'dart:io';
import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../join_controller.dart';
import '../../../widgets/interactive_wrapper.dart';

/// 字段锁定按钮组件
/// 显示在输入框右上角，点击切换锁定/解锁状态
/// 锁定后切换抓取平台时不会覆盖该字段的数据
class FieldLockButton extends StatelessWidget {
  final bool isLocked;
  final VoidCallback onToggle;
  final double size;

  const FieldLockButton({
    super.key,
    required this.isLocked,
    required this.onToggle,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return InteractiveWrapper(
      onTap: onToggle,
      hoverScale: 1.15,
      child: Tooltip(
        message: isLocked ? '已锁定：切换平台时保留此数据' : '未锁定：切换平台时会覆盖此数据',
        waitDuration: const Duration(milliseconds: 500),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.all(size * 0.25),
          decoration: BoxDecoration(
            color: isLocked
                ? AppColors.border.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
          child: Icon(
            isLocked ? Icons.lock : Icons.lock_open,
            size: size,
            color: isLocked
                ? AppColors.border
                : AppColors.placeholderText.withOpacity(0.5),
          ),
        ),
      ),
    );
  }
}

/// 带锁定按钮的封面区域
class CoverSectionWithLock extends StatelessWidget {
  final JoinController controller;

  const CoverSectionWithLock({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final hasCover = controller.coverFilePath != null;

    return InteractiveWrapper(
      onTap: () => controller.pickCover(),
      child: Transform.rotate(
        angle: -0.035,
        child: Container(
          width: 120,
          height: 180,
          decoration: BoxDecoration(
            color: const Color(0xFFE9E0D1),
            border: Border.all(
              color: controller.coverLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.coverLocked ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(4, 5),
                  blurRadius: 0)
            ],
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.hardEdge,
          child: Stack(fit: StackFit.expand, children: [
            if (hasCover)
              Transform.rotate(
                  angle: 0.035,
                  child: Image.file(File(controller.coverFilePath!),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover))
            else
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add, size: 32, color: AppColors.border),
                const SizedBox(height: 8),
                Text('添加封面',
                    style: TextStyle(
                        fontFamily: 'ZhiMangXing',
                        fontSize: 16,
                        letterSpacing: 2.0,
                        color: AppColors.border))
              ]),
            // 锁定按钮 - 左上角
            Positioned(
              top: 6,
              left: 6,
              child: Transform.rotate(
                angle: 0.035,
                child: FieldLockButton(
                  isLocked: controller.coverLocked,
                  onToggle: () => controller.toggleCoverLock(),
                  size: 18,
                ),
              ),
            ),
            // 删除按钮 - 右上角（仅在有封面时显示）
            if (hasCover)
              Positioned(
                  top: 6,
                  right: 6,
                  child: Transform.rotate(
                    angle: 0.035,
                    child: InteractiveWrapper(
                        onTap: () => controller.removeCover(),
                        hoverScale: 1.1,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(10)),
                          child: Icon(Icons.close_rounded,
                              size: 14, color: Colors.white),
                        )),
                  )),
          ]),
        ),
      ),
    );
  }
}
