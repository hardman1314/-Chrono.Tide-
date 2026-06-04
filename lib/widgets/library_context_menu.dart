import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

class LibraryContextMenu extends StatelessWidget {
  final Offset position;
  final VoidCallback onDetails;
  final VoidCallback onMark;
  final VoidCallback onSelectExe;
  final VoidCallback onBackup;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const LibraryContextMenu({
    super.key,
    required this.position,
    required this.onDetails,
    required this.onMark,
    required this.onSelectExe,
    required this.onBackup,
    required this.onDelete,
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
                  _buildMenuItem(
                    icon: Icons.info_outline_rounded,
                    label: '详 情',
                    labelColor: const Color(0xFF5C4A3D),
                    onTap: onDetails,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.play_circle_outline_rounded,
                    label: '启动程序',
                    labelColor: const Color(0xFF5C4A3D),
                    onTap: onSelectExe,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.bookmark_border_rounded,
                    label: '标 记',
                    labelColor: const Color(0xFF5C4A3D),
                    onTap: onMark,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.save_outlined,
                    label: '存档备份',
                    labelColor: const Color(0xFF5C4A3D),
                    onTap: onBackup,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.delete_outline_rounded,
                    label: '删 除',
                    labelColor: const Color(0xFFD4183D),
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
                  bottom: BorderSide(color: const Color(0xFFE9E0D1), width: 1),
                ),
              )
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF8B7355)),
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
    );
  }
}
