import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_dialog.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 底部动作表
///
/// 替代桌面右键菜单,长按游戏卡片时弹出。
/// 使用 [showAppDialog] (复用桌面弹窗基础设施,遮罩 Positioned(top: kTitleBarHeight))。
///
/// 布局: 底部弹出的圆角容器,含 4 个大按钮:
/// - 启动游戏 (绿色)
/// - 标记切换 (黄色)
/// - 启动管理 (蓝色)
/// - 删除 (红色)
///
/// 每个按钮 64px 高,BpmInteractiveWrapper 包裹,焦点感知。
/// 点击任一按钮后自动关闭动作表。
class BigPictureActionSheet {
  BigPictureActionSheet._();

  /// 显示动作表
  ///
  /// [context] 用于 showAppDialog
  /// [gameTitle] 游戏标题 (显示在动作表顶部)
  /// [onLaunch] 启动游戏回调
  /// [onToggleMark] 标记切换回调
  /// [onLaunchManager] 启动管理回调
  /// [onDelete] 删除回调
  static Future<void> show({
    required BuildContext context,
    required String gameTitle,
    required VoidCallback onLaunch,
    required VoidCallback onToggleMark,
    required VoidCallback onLaunchManager,
    required VoidCallback onDelete,
  }) async {
    await showAppDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogContext) => _ActionSheetContent(
        gameTitle: gameTitle,
        onLaunch: () {
          Navigator.of(dialogContext).pop();
          onLaunch();
        },
        onToggleMark: () {
          Navigator.of(dialogContext).pop();
          onToggleMark();
        },
        onLaunchManager: () {
          Navigator.of(dialogContext).pop();
          onLaunchManager();
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
  final VoidCallback onLaunch;
  final VoidCallback onToggleMark;
  final VoidCallback onLaunchManager;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const _ActionSheetContent({
    required this.gameTitle,
    required this.onLaunch,
    required this.onToggleMark,
    required this.onLaunchManager,
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
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.subtitleFontSize,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: BigPictureTheme.sectionSpacing),
              // 启动按钮
              _ActionButton(
                icon: Icons.play_arrow_rounded,
                label: '启动游戏',
                color: AppColors.successGreen,
                onTap: onLaunch,
                autofocus: true,
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
                        fontFamily: 'Inter',
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
                    fontFamily: 'Inter',
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
