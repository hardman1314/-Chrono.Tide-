import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// UX-13: 从 library_page.dart 抽取的编辑模式右键菜单。
///
/// 用于库页编辑模式下的批量操作菜单（标记/模糊/游玩状态/删除）。
/// 当未选中任何游戏时显示提示文本。
class EditModeContextMenu extends StatelessWidget {
  final Offset position;
  final bool hasSelection;
  final VoidCallback? onMark;
  final VoidCallback? onBlur;
  final VoidCallback? onPlayStatus;
  final VoidCallback? onDelete;
  final VoidCallback onClose;

  const EditModeContextMenu({
    super.key,
    required this.position,
    required this.hasSelection,
    this.onMark,
    this.onBlur,
    this.onPlayStatus,
    this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: position.dx,
          top: position.dy,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0x218B7355),
                    offset: const Offset(4, 5),
                    blurRadius: 0,
                  ),
                ],
                color: AppColors.background,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onMark != null)
                    _buildMenuItem(
                      icon: Icons.bookmark_border_rounded,
                      label: '标 记',
                      labelColor: AppColors.titleBrown,
                      onTap: onMark!,
                      showDivider: true,
                    ),
                  if (onBlur != null)
                    _buildMenuItem(
                      icon: Icons.blur_on,
                      label: '模 糊',
                      labelColor: AppColors.titleBrown,
                      onTap: onBlur!,
                      showDivider: true,
                    ),
                  if (onPlayStatus != null)
                    _buildMenuItem(
                      icon: Icons.sports_esports,
                      label: '游玩状态',
                      labelColor: AppColors.titleBrown,
                      onTap: onPlayStatus!,
                      showDivider: true,
                    ),
                  if (onDelete != null)
                    _buildMenuItem(
                      icon: Icons.delete_outline_rounded,
                      label: '删 除',
                      labelColor: AppColors.dangerRed,
                      onTap: onDelete!,
                      showDivider: false,
                    ),
                  if (!hasSelection)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '请先选中游戏',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          color: AppColors.secondaryText,
                        ),
                      ),
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
    return GestureDetector(
      onTap: () {
        onClose();
        onTap();
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
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
                  fontFamily: 'Inter',
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
      ),
    );
  }
}
