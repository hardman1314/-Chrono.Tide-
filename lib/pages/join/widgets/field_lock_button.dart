import 'dart:io';
import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../join_controller.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/nsfw/nsfw_image.dart';

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
    // v3.9 按钮体系：ghost 语义变体——锁定=选中态（强调色软底+强调图标，
    // 修复 border@15% 底在浅色主题下几乎不可见）
    return HoverButton(
      variant: CtButtonVariant.ghost,
      selected: isLocked,
      onTap: onToggle,
      padding: EdgeInsets.all(size * 0.25),
      child: Tooltip(
        message: isLocked ? '已锁定：切换平台时保留此数据' : '未锁定：切换平台时会覆盖此数据',
        waitDuration: const Duration(milliseconds: 500),
        child: Icon(
          isLocked ? Icons.lock : Icons.lock_open,
          size: size,
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
          // 封面宽沿用设计稿 150；高度改为与四个输入框整体高度**精确对齐**：
          // 名称 62 + 5 + 副标题 37 + 5 + 标签 47 + 5 + 会社 47 = 208
          // ⇒ 左栏首行 Row 高度由「封面 224」收敛为「字段列 208」，省下 16px 给简介
          width: 150,
          height: 208,
          decoration: BoxDecoration(
            color: const Color(0xFFE9E0D1),
            border: Border.all(
              color: controller.coverLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              // 设计稿字段/封面边框统一 1.36~1.5，锁定态按 1.6 倍强调
              width: controller.coverLocked ? 2.4 : 1.5,
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
                  child: NsfwImage.file(
                      controller.coverFilePath!,
                      contentKind: NsfwContentKind.cover,
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      child: Image.file(File(controller.coverFilePath!),
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          // ★ 性能优化：小尺寸封面缩略图限宽解码
                          cacheWidth: 240)))
            else
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add, size: 32, color: AppColors.border),
                const SizedBox(height: 8),
                Text('添加封面',
                    style: TextStyle(
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
                          // 设计稿「Button - 移除封面」27.8×27.8 全圆
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(14)),
                          child: Icon(Icons.close_rounded,
                              size: 15, color: Colors.white),
                        )),
                  )),
          ]),
        ),
      ),
    );
  }
}
