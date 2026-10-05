import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 游戏卡片右键菜单 (v3.2)
///
/// 菜单结构与桌面模式【库】右键菜单 ([LibraryContextMenu]) 完全一致:
/// 详 情 / 启动管理 / 加入收藏夹 / 存档备份 / 删 除,
/// 仅视觉适配 Cinema 主题 (玻璃深底 + 樱粉描边 + 雾蓝图标)。
///
/// 以 Overlay 弹出,含屏幕边界检测 (右侧/底部自动收拢),点遮罩关闭。
class BpmContextMenu extends StatelessWidget {
  /// 全局坐标 (右键点击位置)
  final Offset position;

  final VoidCallback onDetails;
  final VoidCallback onLaunchManager;
  final VoidCallback onBackup;
  final VoidCallback onCollection;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  /// v3.5: 菜单已移除后的通知 (调用方借此清空自身持有的 OverlayEntry 引用)。
  ///
  /// 🔴 修复根因: 原实现调用方只在「打开菜单」时清理引用,而菜单被点击/
  /// 点遮罩关闭时引用仍指向已被移除的 entry —— 第二次右键会对同一 entry
  /// 再次 remove() 抛异常,导致 show() 永不执行、菜单再也弹不出来。
  final VoidCallback? onClosed;

  const BpmContextMenu({
    super.key,
    required this.position,
    required this.onDetails,
    required this.onLaunchManager,
    required this.onBackup,
    required this.onCollection,
    required this.onDelete,
    required this.onClose,
    this.onClosed,
  });

  /// 便捷弹出: 插入 root Overlay 并返回关闭函数
  ///
  /// 调用方需持有返回的 remover,在路由/页面变化时清理。
  static OverlayEntry? show(
    BuildContext context, {
    required Offset position,
    required VoidCallback onDetails,
    required VoidCallback onLaunchManager,
    required VoidCallback onBackup,
    required VoidCallback onCollection,
    required VoidCallback onDelete,
    VoidCallback? onClosed,
  }) {
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => BpmContextMenu(
        position: position,
        onDetails: onDetails,
        onLaunchManager: onLaunchManager,
        onBackup: onBackup,
        onCollection: onCollection,
        onDelete: onDelete,
        onClose: () {
          entry.remove();
          onClosed?.call();
        },
        onClosed: onClosed,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return entry;
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 180.0;
    const menuHeight = 300.0; // 5 项 × 56 + 内边距
    const margin = 8.0;

    final maxLeft = math.max(margin, screenSize.width - menuWidth - margin);
    final left = position.dx.clamp(margin, maxLeft);

    double top;
    if (position.dy + menuHeight > screenSize.height - margin) {
      top = math.max(margin, position.dy - menuHeight);
    } else {
      top = position.dy;
    }

    return Stack(
      children: [
        // 全屏遮罩: 点击关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
            onSecondaryTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: menuWidth,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xF2101620), // deepPanel 95%
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: BpmColors.deepBase.withOpacity(0.6),
                    blurRadius: 32,
                    offset: const Offset(0, 14),
                  ),
                  BoxShadow(
                    color: BpmColors.cherryRose.withOpacity(0.10),
                    blurRadius: 18,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _menuItem(
                    icon: Icons.info_outline_rounded,
                    label: '详 情',
                    onTap: onDetails,
                  ),
                  _menuItem(
                    icon: Icons.tune_rounded,
                    label: '启动管理',
                    onTap: onLaunchManager,
                  ),
                  _menuItem(
                    icon: Icons.collections_bookmark_outlined,
                    label: '加入收藏夹',
                    onTap: onCollection,
                  ),
                  _menuItem(
                    icon: Icons.save_outlined,
                    label: '存档备份',
                    onTap: onBackup,
                  ),
                  _menuItem(
                    icon: Icons.delete_outline_rounded,
                    label: '删 除',
                    danger: true,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? const Color(0xFFFF7B8A) : BpmColors.textSecondary;
    return BpmInteractiveWrapper(
      onTap: () {
        onClose();
        onTap();
      },
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: danger
                  ? const Color(0xFFFF7B8A)
                  : BpmColors.mistBlue.withOpacity(0.9),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 2,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
