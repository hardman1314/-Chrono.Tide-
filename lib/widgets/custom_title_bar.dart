import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_resolver.dart';
import '../services/metadata_fetcher.dart';
import '../services/download_core.dart';
import '../services/extract_manager.dart';
import '../services/global_install_center.dart';
import '../services/interrupt_cleanup.dart';
import '../services/process_cleanup_service.dart';
import '../services/storage/log_rotation_service.dart';
import '../services/tray_service.dart';
import '../services/local_game_registry.dart';
import '../services/app_state.dart';
import 'exit_overlay.dart';

/// 应用窗口标题栏高度，作为全局布局约束供标题栏、遮罩层偏移等统一引用
const double kTitleBarHeight = 32.0;

class CustomTitleBar extends StatefulWidget {
  final Widget child;

  const CustomTitleBar({super.key, required this.child});

  /// 统一的干净退出方法，可从任何地方调用（更新安装、关闭按钮等）
  static Future<void> performCleanExit(BuildContext context) async {
    ExitOverlay.show(context);

    try {
      // 串行执行：会话清理 + 进程清理 + 元数据缓存清空
      // 先清理游戏会话监控（写入最终时长、停止定时器、★ v3: 写入会话记录到事实表）
      await LocalGameRegistry.instance.disposeAllSessions();

      // 退出时快路径清理:仅当有活动下载/解压任务时,清理已知路径残留(800ms超时)
      // 不做全目录扫描,避免拖慢退出;超时后残留靠下次启动 startupScan 兜底
      if (DownloadCore.hasActiveTask || ExtractManager.hasActiveTask) {
        debugPrint('[EXIT] 检测到活动任务,执行快路径残留清理...');
        try {
          await InterruptCleanup.cleanupActiveTaskResidue(
            downloadedFilePath: GlobalInstallCenter.instance.downloadedFilePath,
            targetGameDir: GlobalInstallCenter.instance.dlCore.extractManager.targetGameDir,
            actualGameDir: GlobalInstallCenter.instance.dlCore.extractManager.actualGameDir,
          ).timeout(const Duration(milliseconds: 800));
        } catch (e) {
          debugPrint('[EXIT] 活动任务残留清理超时/失败: $e');
        }
      }

      await Future.wait([
        ProcessCleanupService.cleanupAll(),
        Future(() {
          debugPrint('[EXIT] ✅ 清理完成');
        }),
      ]);
    } catch (e) {
      debugPrint('[EXIT] 清理异常: $e');
    }

    // 退出时触发日志轮转(带500ms超时,失败不阻塞退出)
    try {
      await LogRotationService.instance
          .rotateAll()
          .timeout(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint('[EXIT] 日志轮转超时/失败: $e');
    }

    // 销毁托盘
    try {
      TrayService.instance.dispose();
    } catch (e) {
      debugPrint('[EXIT] 托盘销毁异常: $e');
    }

    try {
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[EXIT] windowManager.destroy error: $e');
    }

    exit(0);
  }

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initWindow();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initWindow() async {
    await windowManager.setPreventClose(true);
    _isMaximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  void onWindowMaximize() {
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _isMaximized = false);
  }

  Future<void> _onMinimize() async {
    await windowManager.minimize();
  }

  Future<void> _onMaximize() async {
    if (_isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _onClose() async {
    final dlActive = DownloadCore.hasActiveTask;
    final extActive = ExtractManager.hasActiveTask;

    if (dlActive || extActive) {
      final ctx = context;
      if (!ctx.mounted) return;

      final taskName = extActive ? '解压' : '获取';
      final result = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 2),
          ),
          title: Text(
            '正在$taskName',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 22,
              letterSpacing: 1.5,
              color: AppColors.border,
            ),
          ),
          content: Text(
            '当前有任务正在进行，退出将取消$taskName\n并删除已产生的临时文件，确定要退出吗？',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              color: AppColors.primaryText,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                '继续$taskName',
                style: TextStyle(
                  color: AppColors.infoBlue,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                '确认退出',
                style: TextStyle(
                  color: AppColors.dangerRed,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );

      if (result != true) return;
      // 有任务在跑时直接彻底退出
      await _performCleanupAndExit();
      return;
    }

    // 没有任务在跑，弹出"最小化到托盘 / 彻底退出"选择
    final ctx = context;
    if (!ctx.mounted) return;

    // 检查是否已设置"不再提醒"
    final prefs = await SharedPreferences.getInstance();
    final rememberChoice = prefs.getBool('close_remember_choice') ?? false;
    final rememberedAction = prefs.getString('close_remembered_action');

    if (rememberChoice && rememberedAction != null) {
      if (rememberedAction == 'tray') {
        await _minimizeToTray();
      } else {
        await _performCleanupAndExit();
      }
      return;
    }

    // 弹出选择对话框
    final result = await showDialog<String>(
      context: ctx,
      barrierDismissible: true,
      builder: (context) => _CloseChoiceDialog(),
    );

    if (result == null) return; // 用户点了外部关闭，什么都不做
    if (result == 'tray') {
      await _minimizeToTray();
    } else if (result == 'exit') {
      await _performCleanupAndExit();
    }
  }

  Future<void> _minimizeToTray() async {
    await windowManager.hide();
    userRequestedWindow = false;
    await TrayService.instance.hideWindow();
  }

  Future<void> _performCleanupAndExit() async {
    await CustomTitleBar.performCleanExit(context);
  }

  @override
  Widget build(BuildContext context) {
    // 窗口圆角：最大化时归零（与系统行为一致），普通态下 7px 适度圆角
    final borderRadius = _isMaximized ? 0.0 : 7.0;
    return Container(
      // clipBehavior 让内容被裁切到 borderRadius 形状，实现四角圆滑
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // 整体边框：1px 细边，颜色取主题边框色 60% 透明度，和谐不突兀
        border: Border.all(
          color: AppColors.border.withOpacity(0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      // v3.0 P6 修复：背景图层全屏底层，让标题栏/侧边栏的透明度（alpha）生效
      // 之前背景图仅在内容区 Expanded 内，侧边栏/标题栏后面无图，alpha 无效果
      child: AnimatedBuilder(
        animation: AppThemeManager.instance,
        builder: (context, _) {
          final themeData = AppThemeManager.instance.current;
          return Stack(
            children: [
              // 底层：纯色背景（始终存在，为 alpha 颜色提供混合底）
              Positioned.fill(
                child: ColoredBox(color: themeData.background),
              ),
              // 背景图层（仅当有背景图时）
              if (themeData.hasBackgroundImage)
                Positioned.fill(
                  child: BackgroundImageResolver(
                    config: themeData.backgroundImage,
                    overlayColor: themeData.background,
                  ),
                ),
              // 左侧渐变：增强深度感（保留原视觉增强，全屏覆盖）
              if (themeData.hasBackgroundImage)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            themeData.background.withOpacity(0.15),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // 前景：标题栏 + 子内容
              Column(
                children: [
                  SizedBox(
                    height: kTitleBarHeight,
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanStart: (details) {
                              windowManager.startDragging();
                            },
                            onDoubleTap: () async {
                              if (_isMaximized) {
                                await windowManager.unmaximize();
                              } else {
                                await windowManager.maximize();
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppColors.titleBarBackground,
                                border: Border(
                                  bottom: BorderSide(
                                    color: AppColors.borderLight,
                                    width: 1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.titleBarBackground,
                            border: Border(
                              bottom: BorderSide(
                                color: AppColors.borderLight,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _WindowButton(
                                icon: Icons.horizontal_rule_rounded,
                                onTap: _onMinimize,
                                tooltip: '最小化',
                              ),
                              _WindowButton(
                                icon: _isMaximized
                                    ? Icons.copy_outlined
                                    : Icons.crop_square_outlined,
                                onTap: _onMaximize,
                                tooltip: _isMaximized ? '还原' : '最大化',
                              ),
                              _WindowButton(
                                icon: Icons.close_rounded,
                                onTap: _onClose,
                                isClose: true,
                                tooltip: '关闭',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: widget.child),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  // UX-36: 窗口按钮交互逻辑已移至 _WindowButton StatefulWidget
}

/// UX-36: 窗口控制按钮——自管 hover 与 press 状态，按下时提供视觉反馈。
/// UX-25: 纯图标按钮添加 tooltip（hover 显示用途）+ Semantics（屏幕阅读器播报）。
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  /// UX-25: hover 提示与无障碍标签（如"最小化"/"最大化"/"关闭"）
  final String? tooltip;

  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.isClose = false,
    this.tooltip,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.isClose
        ? const Color(0x1AD4183D)
        : AppColors.buttonBackground.withOpacity(0.5);
    // UX-36: 按下时背景更深，提供明确的按压触感
    final bgColor = _pressed
        ? (widget.isClose
            ? const Color(0x33D4183D)
            : AppColors.buttonBackground.withOpacity(0.8))
        : (_hovered ? hoverBg : Colors.transparent);
    final iconColor = widget.isClose && _hovered
        ? AppColors.dangerRed
        : AppColors.secondaryText;

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: 38,
            height: kTitleBarHeight,
            alignment: Alignment.center,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                color: bgColor,
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 12,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
    // UX-25: 纯图标按钮添加 Tooltip + Semantics
    final label = widget.tooltip ?? (widget.isClose ? '关闭' : '');
    if (label.isEmpty) return core;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        label: label,
        child: core,
      ),
    );
  }
}

/// 关闭窗口时的选择对话框：最小化到托盘 / 彻底退出
class _CloseChoiceDialog extends StatefulWidget {
  @override
  State<_CloseChoiceDialog> createState() => _CloseChoiceDialogState();
}

class _CloseChoiceDialogState extends State<_CloseChoiceDialog> {
  bool _rememberChoice = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border, width: 2),
      ),
      title: Text(
        '关闭窗口',
        style: TextStyle(
          fontFamily: 'ZhiMangXing',
          fontSize: 22,
          letterSpacing: 1.5,
          color: AppColors.border,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '你希望怎么做？',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              color: AppColors.primaryText,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          // 最小化到托盘
          _buildChoiceCard(
            icon: Icons.minimize_rounded,
            title: '最小化到托盘',
            subtitle: '后台继续运行，随时可恢复',
            color: AppColors.infoBlue,
            onTap: () => _handleChoice('tray'),
          ),
          const SizedBox(height: 10),
          // 彻底退出
          _buildChoiceCard(
            icon: Icons.power_settings_new_rounded,
            title: '彻底退出',
            subtitle: '完全关闭软件，停止所有服务',
            color: AppColors.dangerRed,
            onTap: () => _handleChoice('exit'),
          ),
          const SizedBox(height: 14),
          // 记住选择
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: _rememberChoice,
                  onChanged: (v) =>
                      setState(() => _rememberChoice = v ?? false),
                  activeColor: AppColors.border,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '记住选择，不再询问',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleChoice(String action) async {
    if (_rememberChoice) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('close_remember_choice', true);
      await prefs.setString('close_remembered_action', action);
    }
    if (mounted) Navigator.of(context).pop(action);
  }

  Widget _buildChoiceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
