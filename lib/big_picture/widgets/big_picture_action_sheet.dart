import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_dialog.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 底部动作表
///
/// 长按游戏卡片 / 手柄 X 键时弹出。
/// 使用 [showAppDialog] (复用桌面弹窗基础设施,遮罩 Positioned(top: kTitleBarHeight))。
///
/// 🔴 **条目与桌面右键菜单逐条同构**（v3.10.2 重新对齐）：
/// `LibraryContextMenu` = 详情 / 启动管理 / 加入收藏夹 / 存档备份 / 删除，
/// 本表 = 详情 / 加入收藏夹 / 标记切换 / 启动管理 / 存档备份 / 删除。
///
/// ⚠️ **这里刻意没有「启动游戏」**（v3.10.1 曾补过，v3.10.2 移除）：
/// 用户在[启动方式]上要求「**双击 A 启动**」—— 与鼠标**双击卡片**同义
/// （`_ShelfCard` / `_PosterCard` 的 `onDoubleTap`）。桌面右键菜单里没有
/// 启动项，BPM 若单独给一个「X → 启动游戏」捷径，既破坏同构、又会让
/// 「按 X 打开菜单后随手一按 A」直接启动游戏（真机上被当成卡死）。
/// 启动入口收敛为两处：**双击 A**（卡片）+ **操作按钮板块的启动胶囊**。
///
/// 每个按钮 64px 高,BpmInteractiveWrapper 包裹,焦点感知 ——
/// 手柄 A 激活、方向键在条目间移动（由 shell 的模态分支驱动）。
/// 条目变多后整表可滚动（小窗口下底部条目仍可达）。
/// 点击任一按钮后自动关闭动作表。
class BigPictureActionSheet {
  BigPictureActionSheet._();

  /// 显示动作表
  ///
  /// [context] 用于 showAppDialog
  /// [gameTitle] 游戏标题 (显示在动作表顶部)
  /// [onDetails] 打开右侧详情面板
  /// [onToggleMark] 标记切换回调
  /// [onCollection] 加入收藏夹（多选弹窗）
  /// [onLaunchManager] 启动管理回调
  /// [onBackup] 存档备份回调
  /// [onDelete] 删除回调
  static Future<void> show({
    required BuildContext context,
    required String gameTitle,
    required VoidCallback onDetails,
    required VoidCallback onToggleMark,
    required VoidCallback onCollection,
    required VoidCallback onLaunchManager,
    required VoidCallback onBackup,
    required VoidCallback onDelete,
  }) async {
    await showAppDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogContext) => _ActionSheetContent(
        gameTitle: gameTitle,
        onDetails: () {
          Navigator.of(dialogContext).pop();
          onDetails();
        },
        onToggleMark: () {
          Navigator.of(dialogContext).pop();
          onToggleMark();
        },
        onCollection: () {
          Navigator.of(dialogContext).pop();
          onCollection();
        },
        onLaunchManager: () {
          Navigator.of(dialogContext).pop();
          onLaunchManager();
        },
        onBackup: () {
          Navigator.of(dialogContext).pop();
          onBackup();
        },
        onDelete: () {
          Navigator.of(dialogContext).pop();
          onDelete();
        },
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }
}

/// 动作表内容组件
///
/// 底部对齐的圆角面板,含标题 + 4 个按钮 + 取消按钮。
/// 每个按钮使用 [BpmInteractiveWrapper] 提供焦点态与触控反馈。
class _ActionSheetContent extends StatelessWidget {
  final String gameTitle;
  final VoidCallback onDetails;
  final VoidCallback onToggleMark;
  final VoidCallback onCollection;
  final VoidCallback onLaunchManager;
  final VoidCallback onBackup;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _ActionSheetContent({
    required this.gameTitle,
    required this.onDetails,
    required this.onToggleMark,
    required this.onCollection,
    required this.onLaunchManager,
    required this.onBackup,
    required this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        // 条目由 4 个扩到 7 个 → 小窗口下必须可滚, 否则底部条目点不到
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(BigPictureTheme.containerRadius),
          ),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 32,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Padding(
          padding: const EdgeInsets.fromLTRB(
            BigPictureTheme.pagePadding,
            BigPictureTheme.widgetPadding,
            BigPictureTheme.pagePadding,
            BigPictureTheme.pagePadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部拖拽指示器
              Center(
                child: Container(
                  width: 48,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 游戏标题
              Text(
                gameTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: BigPictureTheme.subtitleFontSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: BigPictureTheme.sectionSpacing),
              // 详情按钮 (与桌面右键菜单「详情」同源) —— 也是本表的初始焦点。
              // 🔴 初始焦点刻意落在**只读**动作上: 旧版固定在「启动游戏」,
              // 打开菜单后随手一按 A 就会启动游戏。
              _ActionButton(
                icon: Icons.info_outline_rounded,
                label: '详情',
                color: BpmColors.mistBlue,
                onTap: onDetails,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              // 加入收藏夹按钮 (与桌面右键菜单「加入收藏夹」同源)
              _ActionButton(
                icon: Icons.bookmarks_rounded,
                label: '加入收藏夹',
                color: BpmColors.cherryRose,
                onTap: onCollection,
              ),
              const SizedBox(height: 12),
              // 标记切换按钮
              _ActionButton(
                icon: Icons.star_rounded,
                label: '标记切换',
                color: const Color(0xFFFFC107),
                onTap: onToggleMark,
              ),
              const SizedBox(height: 12),
              // 启动管理按钮
              _ActionButton(
                icon: Icons.tune_rounded,
                label: '启动管理',
                color: AppColors.infoBlue,
                onTap: onLaunchManager,
              ),
              const SizedBox(height: 12),
              // 存档备份按钮 (与桌面右键菜单「存档备份」同源)
              _ActionButton(
                icon: Icons.inventory_2_outlined,
                label: '存档备份',
                color: BpmColors.mistBlueSoft,
                onTap: onBackup,
              ),
              const SizedBox(height: 12),
              // 删除按钮
              _ActionButton(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                color: AppColors.dangerRed,
                onTap: onDelete,
              ),
              const SizedBox(height: 20),
              // 取消按钮
              BpmInteractiveWrapper(
                onTap: onClose,
                semanticsLabel: '取消',
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
                child: Container(
                  height: BigPictureTheme.secondaryButtonHeight,
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    border: Border.all(color: AppColors.border, width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      '取消',
                      style: TextStyle(
                        fontSize: BigPictureTheme.bodyFontSize,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// 动作表单个按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool autofocus;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      autofocus: autofocus,
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        height: BigPictureTheme.launchButtonHeight,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          border: Border.all(color: color.withOpacity(0.4), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(icon, size: 28, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: BigPictureTheme.subtitleFontSize,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 24, color: color.withOpacity(0.6)),
            ],
          ),
        ),
      ),
    );
  }
}
