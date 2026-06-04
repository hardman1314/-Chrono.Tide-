import 'package:flutter/material.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import '../theme/app_colors.dart';
import '../services/openlist_service.dart';
import '../services/metadata_fetcher.dart';
import '../services/download_core.dart';
import '../services/extract_manager.dart';
import '../services/interrupt_cleanup.dart';
import '../services/process_cleanup_service.dart';
import 'exit_overlay.dart';

class CustomTitleBar extends StatefulWidget {
  final Widget child;

  const CustomTitleBar({super.key, required this.child});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isHoveringMinimize = false;
  bool _isHoveringMaximize = false;
  bool _isHoveringClose = false;
  bool _isExiting = false;

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

      final taskName = extActive ? '解压' : '下载';
      final result = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFFFDFBF7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF8B7355), width: 2),
          ),
          title: Text(
            '正在$taskName',
            style: const TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 22,
              letterSpacing: 1.5,
              color: Color(0xFF8B7355),
            ),
          ),
          content: Text(
            '当前有任务正在进行，退出将取消$taskName\n并删除已产生的临时文件，确定要退出吗？',
            style: const TextStyle(
              fontFamily: 'Mali',
              fontSize: 15,
              color: Color(0xFF6D5B4D),
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                '继续$taskName',
                style: TextStyle(
                  color: Color(0xFF4A72A5),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                '确认退出',
                style: TextStyle(
                  color: Color(0xFFD4183D),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );

      if (result != true) return;
    }

    await _performCleanupAndExit();
  }

  Future<void> _performCleanupAndExit() async {
    ExitOverlay.show(context);

    await Future.delayed(const Duration(milliseconds: 300));

    try {
      await ProcessCleanupService.cleanupAll();
    } catch (e) {
      debugPrint('[EXIT] ProcessCleanupService.cleanupAll error: $e');
    }

    try {
      MetadataFetcher.clearCache();
      debugPrint('[EXIT] ✅ 元数据缓存已清空');
    } catch (e) {
      debugPrint('[EXIT] ⚠️ 清空缓存时出错: $e');
    }

    try {
      await InterruptCleanup.cleanupAll();
    } catch (e) {
      debugPrint('[EXIT] InterruptCleanup.cleanupAll error: $e');
    }

    try {
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[EXIT] windowManager.destroy error: $e');
    }

    await Future.delayed(const Duration(milliseconds: 800));

    exit(0);
  }

  /// 构建标题栏（可独立使用，不依赖 child）
  Widget buildTitleBar() {
    return SizedBox(
      height: 40,
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
                _buildWindowButton(
                  icon: Icons.horizontal_rule_rounded,
                  isHovered: _isHoveringMinimize,
                  onEnter: () => setState(() => _isHoveringMinimize = true),
                  onExit: () => setState(() => _isHoveringMinimize = false),
                  onTap: _onMinimize,
                ),
                _buildWindowButton(
                  icon: _isMaximized
                      ? Icons.copy_outlined
                      : Icons.crop_square_outlined,
                  isHovered: _isHoveringMaximize,
                  onEnter: () => setState(() => _isHoveringMaximize = true),
                  onExit: () => setState(() => _isHoveringMaximize = false),
                  onTap: _onMaximize,
                ),
                _buildWindowButton(
                  icon: Icons.close_rounded,
                  isHovered: _isHoveringClose,
                  onEnter: () => setState(() => _isHoveringClose = true),
                  onExit: () => setState(() => _isHoveringClose = false),
                  onTap: _onClose,
                  isClose: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 内容区域（带顶部留白给标题栏）
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: widget.child,
        ),
        // 标题栏始终在最顶层
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: buildTitleBar(),
        ),
      ],
    );
  }

  Widget _buildWindowButton({
    required IconData icon,
    required bool isHovered,
    required VoidCallback onEnter,
    required VoidCallback onExit,
    required VoidCallback onTap,
    bool isClose = false,
  }) {
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 40,
          alignment: Alignment.center,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26843500),
              color: isHovered
                  ? (isClose
                      ? const Color(0x1AD4183D)
                      : AppColors.buttonBackground.withOpacity(0.5))
                  : Colors.transparent,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 14,
              color: isClose && isHovered
                  ? AppColors.dangerRed
                  : const Color(0xFF666666),
            ),
          ),
        ),
      ),
    );
  }
}
