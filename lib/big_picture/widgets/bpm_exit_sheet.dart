import 'package:flutter/material.dart';

import '../../services/download_core.dart';
import '../../services/extract_manager.dart';
import '../../theme/app_styles.dart';
import '../../widgets/custom_title_bar.dart';
import '../big_picture_manager.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';
import '../../widgets/app_snack_bar.dart';

/// BPM 退出选择面板 (v3.5)
///
/// 原系统标题栏的最小化 / 关闭按钮能力全部迁移到左侧栏底部按钮:
/// 点该按钮弹出本面板, 三选一:
/// 1. **退出大屏幕模式** —— 回到桌面模式 (软件继续运行)
/// 2. **关闭软件** —— 与标题栏关闭按钮同一条清理链路
///    ([CustomTitleBar.performCleanExit]: 会话收尾 + 进程清理 + 日志轮转 + 托盘销毁)
/// 3. **最小化** —— 最小化窗口
class BpmExitSheet extends StatelessWidget {
  const BpmExitSheet({super.key});

  /// 弹出退出选择面板
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.66),
      builder: (_) => const BpmExitSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: BpmColors.deepPanel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: BpmColors.cardShadow.withOpacity(0.55),
              blurRadius: 56,
              offset: const Offset(0, 22),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '要做什么？',
              style: TextStyle(
                fontFamily: AppStyles.zhDecorativeFont,
                fontSize: 24,
                fontWeight: FontWeight.w400,
                color: BpmColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '大屏幕模式与软件本身是两件事，请分别选择。',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12.5,
                color: BpmColors.textMuted,
              ),
            ),
            const SizedBox(height: 20),
            _ExitOption(
              icon: Icons.desktop_windows_rounded,
              title: '退出大屏幕模式',
              subtitle: '回到桌面模式，软件继续运行',
              accent: BpmColors.mistBlue,
              onTap: () => _exitBpm(context),
            ),
            const SizedBox(height: 10),
            _ExitOption(
              icon: Icons.power_settings_new_rounded,
              title: '关闭软件',
              subtitle: '完全退出 Chrono Tide，停止所有服务',
              accent: BpmColors.dangerAccent,
              onTap: () => _exitApp(context),
            ),
            const SizedBox(height: 10),
            _ExitOption(
              icon: Icons.minimize_rounded,
              title: '最小化',
              subtitle: '窗口最小化，随时可以恢复',
              accent: BpmColors.mistBlueSoft,
              onTap: () => _minimize(context),
            ),
          ],
        ),
      ),
    );
  }

  void _exitBpm(BuildContext context) {
    Navigator.of(context).pop();
    BigPictureManager.instance.exit();
  }

  /// 最小化窗口。
  ///
  /// 🔴 v3.10.3 修复：原实现直接调 `windowManager.minimize()`，而该插件在
  /// 全屏状态下**直接 return**（`window_manager.cpp:344`），BPM 全程全屏 ——
  /// 于是「最小化」是个空操作。改走 [BigPictureManager.minimizeWindow]
  /// （FFI `ShowWindow(SW_MINIMIZE)`，绕开守卫）。
  Future<void> _minimize(BuildContext context) async {
    Navigator.of(context).pop();
    final ok = BigPictureManager.minimizeWindow();
    if (!ok) {
      debugPrint('[BPM] 最小化未下发成功(无法取得系统窗口句柄)');
      AppSnackBar.error(context, '最小化失败：未能取得系统窗口句柄');
    }
  }

  Future<void> _exitApp(BuildContext context) async {
    final navigator = Navigator.of(context);
    // 与桌面标题栏一致：有下载/解压任务在跑时先明确告知，避免静默丢弃临时文件
    final busy = DownloadCore.hasActiveTask || ExtractManager.hasActiveTask;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ExitConfirmDialog(busy: busy),
    );
    if (confirmed != true) return;
    if (!navigator.mounted) return;
    navigator.pop();
    await CustomTitleBar.performCleanExit(context);
  }
}

/// 单个选项卡片
class _ExitOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  const _ExitOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      semanticsLabel: title,
      focusScale: 1.02,
      hoverScale: 1.02,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withOpacity(0.45), width: 1),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: BpmColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 12,
                      color: BpmColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: accent.withOpacity(0.75)),
          ],
        ),
      ),
    );
  }
}

/// 关闭软件二次确认 (与桌面标题栏关闭语义对齐)
class _ExitConfirmDialog extends StatelessWidget {
  final bool busy;

  const _ExitConfirmDialog({required this.busy});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BpmColors.deepPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: BpmColors.dangerAccentSoft),
      ),
      title: Text(
        busy ? '正在下载 / 解压' : '关闭软件',
        style: TextStyle(
          fontFamily: AppStyles.zhDecorativeFont,
          fontSize: 21,
          color: BpmColors.textPrimary,
        ),
      ),
      content: Text(
        busy
            ? '当前有任务正在进行，退出将取消任务并删除已产生的临时文件，确定要退出吗？'
            : '确定要完全关闭 Chrono Tide 吗？',
        style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 13.5,
          height: 1.55,
          color: BpmColors.textSecondary,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            busy ? '继续任务' : '取消',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              color: BpmColors.mistBlue,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            '确认退出',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontWeight: FontWeight.w600,
              color: BpmColors.dangerAccent,
            ),
          ),
        ),
      ],
    );
  }
}
