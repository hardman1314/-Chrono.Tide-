import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import 'interactive_wrapper.dart';

class LibraryContextMenu extends StatelessWidget {
  final Offset position;
  final VoidCallback onDetails;
  final VoidCallback onLaunchManager;
  final VoidCallback onCollection;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const LibraryContextMenu({
    super.key,
    required this.position,
    required this.onDetails,
    required this.onLaunchManager,
    required this.onCollection,
    required this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // UX-19: 边界检测，菜单不溢出屏幕右侧或底部
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 160.0;
    const menuHeight = 200.0; // 4 项 × ~48px + 边框/分割线
    const margin = 8.0;

    final maxLeft = math.max(margin, screenSize.width - menuWidth - margin);
    final left = position.dx.clamp(margin, maxLeft);

    double top;
    if (position.dy + menuHeight > screenSize.height - margin) {
      // 底部放不下时上翻至点击点上方
      top = math.max(margin, position.dy - menuHeight);
    } else {
      top = position.dy;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                // v3.9 Aurora：白卡面 + e3 浮层阴影 + 发丝边 + 大圆角
                border: AppStyle.isModern
                    ? Border.all(
                        color: AppColors.borderLight, width: AppStyle.wHairline)
                    : Border.all(color: AppColors.border, width: 2),
                boxShadow: AppStyle.isModern
                    ? AppStyle.e3
                    : [
                        BoxShadow(
                          color: AppColors.border.withOpacity(0.13),
                          offset: const Offset(4, 5),
                          blurRadius: 0,
                        ),
                      ],
                color: AppStyle.isModern
                    ? AppColors.buttonBackground
                    : AppColors.background,
                borderRadius: AppStyle.isModern
                    ? BorderRadius.circular(AppStyle.rMd)
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuItem(
                    icon: Icons.info_outline_rounded,
                    label: '详 情',
                    labelColor: AppColors.titleBrown,
                    onTap: onDetails,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.tune_rounded,
                    label: '启动管理',
                    labelColor: AppColors.titleBrown,
                    onTap: onLaunchManager,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.collections_bookmark_outlined,
                    label: '加入收藏夹',
                    labelColor: AppColors.titleBrown,
                    onTap: onCollection,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.delete_outline_rounded,
                    label: '删 除',
                    labelColor: AppColors.dangerRed,
                    onTap: onDelete,
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color labelColor,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    return InteractiveWrapper(
      onTap: () {
        onClose();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 71, 13),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(
                  bottom:
                      BorderSide(color: AppColors.placeholderCover, width: 1),
                ),
              )
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppColors.border),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 24 / 16,
                letterSpacing: 1.8,
                color: labelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
