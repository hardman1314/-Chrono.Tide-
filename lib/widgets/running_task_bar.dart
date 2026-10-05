import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/game_data_format.dart';
import '../services/running_tasks_service.dart';
import '../theme/app_colors.dart';
import 'nsfw/nsfw_image.dart';

/// 单条游戏运行任务横幅
///
/// 布局自左向右：游戏缩略封面 → 游戏名称 +（状态提示 / 实时运行时长）→ 操作按钮。
/// 所有颜色取自 [AppColors]，随主题自动切换。
///
/// 外层容器做磨砂半透明圆角（[BackdropFilter]），本身不改变父布局，
/// 由 [RunningTasksBanner] 负责悬浮定位。
class RunningTaskBar extends StatefulWidget {
  final RunningTask task;

  const RunningTaskBar({super.key, required this.task});

  @override
  State<RunningTaskBar> createState() => _RunningTaskBarState();
}

class _RunningTaskBarState extends State<RunningTaskBar> {
  /// 封面文件路径（initState 解析一次并缓存，避免每帧做文件 I/O）
  String? _coverPath;

  @override
  void initState() {
    super.initState();
    _resolveCover();
  }

  void _resolveCover() {
    try {
      _coverPath =
          GameDataFormat.findCoverFile(widget.task.game.pathForCover)?.path;
    } catch (_) {
      _coverPath = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final accent = _accentFor(task.status);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: 420,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.background.withOpacity(0.72),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.border.withOpacity(0.45),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowColor.withOpacity(0.18),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              _buildCover(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildStatusLine(task, accent),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildActions(task),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    final path = _coverPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: path != null && path.isNotEmpty
          // 接入 NsfwImage：此前是全库唯一未接入的封面渲染点，
          // 开启工作模式后会漏出真实封面（v2.1.15 补上）。
          ? NsfwImage.file(
              path,
              contentKind: NsfwContentKind.cover,
              width: 40,
              height: 56,
              fit: BoxFit.cover,
              showBadge: false,
              child: Image.file(
                File(path),
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                // 封面解码失败（文件损坏/被占用）时退化为占位，不让整条横幅崩掉
                errorBuilder: (_, __, ___) => _buildCoverPlaceholder(),
              ),
            )
          : _buildCoverPlaceholder(),
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      width: 40,
      height: 56,
      color: AppColors.placeholderCover,
      child: Icon(
        Icons.videogame_asset_outlined,
        size: 18,
        color: AppColors.placeholderText,
      ),
    );
  }

  Widget _buildStatusLine(RunningTask task, Color accent) {
    final bool showSpinner = task.status == RunningTaskStatus.launching ||
        task.status == RunningTaskStatus.closing;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        showSpinner
            ? SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.4,
                  color: accent,
                ),
              )
            : Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _statusText(task),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: task.status == RunningTaskStatus.failed
                  ? AppColors.dangerRed
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ],
    );
  }

  String _statusText(RunningTask task) {
    switch (task.status) {
      case RunningTaskStatus.launching:
        return '正在启动…';
      case RunningTaskStatus.running:
        return '运行中 · 已运行 ${_formatDuration(task.elapsedSeconds(DateTime.now()))}';
      case RunningTaskStatus.closing:
        return '正在关闭…';
      case RunningTaskStatus.exiting:
        return '已退出 · 本次 ${_formatDuration(task.finalSeconds)}';
      case RunningTaskStatus.failed:
        final err = task.errorMessage;
        return err == null || err.isEmpty ? '启动失败' : '启动失败：$err';
    }
  }

  /// 结束态（已退出/启动失败）只保留一个「关闭提示」按钮，
  /// 此时「解除监控」与「关闭游戏」都已无对象可言
  Widget _buildActions(RunningTask task) {
    final service = RunningTasksService.instance;
    final key = task.metaDataDir;

    if (task.status == RunningTaskStatus.exiting ||
        task.status == RunningTaskStatus.failed) {
      return _BannerIconButton(
        icon: Icons.close,
        tooltip: '关闭提示',
        onTap: () => service.dismiss(key),
      );
    }

    final disabled = task.status == RunningTaskStatus.closing;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BannerIconButton(
          icon: Icons.link_off,
          tooltip: '解除监控（停止计时，游戏继续运行）',
          enabled: !disabled,
          onTap: disabled ? null : () => service.detach(key),
        ),
        const SizedBox(width: 6),
        _BannerIconButton(
          icon: Icons.power_settings_new,
          tooltip: '关闭游戏（终止进程）',
          enabled: !disabled,
          danger: true,
          onTap: disabled ? null : () => service.kill(key),
        ),
      ],
    );
  }

  Color _accentFor(RunningTaskStatus status) {
    switch (status) {
      case RunningTaskStatus.launching:
      case RunningTaskStatus.closing:
        return AppColors.infoBlue;
      case RunningTaskStatus.running:
        return AppColors.successGreen;
      case RunningTaskStatus.exiting:
        return AppColors.secondaryText;
      case RunningTaskStatus.failed:
        return AppColors.dangerRed;
    }
  }

  /// 超过 1 小时才带小时位，避免绝大多数场景下的 "00:12:34" 冗余
  static String _formatDuration(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }
}

/// 横幅内的图标操作按钮
///
/// 克制的 hover 反馈：仅背景色与图标色变化，不做缩放位移。
class _BannerIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;

  const _BannerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
    this.enabled = true,
  });

  @override
  State<_BannerIconButton> createState() => _BannerIconButtonState();
}

class _BannerIconButtonState extends State<_BannerIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null;
    final baseColor =
        widget.danger ? AppColors.dangerRed : AppColors.secondaryText;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: active ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: _hovered && active
                  ? (widget.danger
                      ? AppColors.dangerRed.withOpacity(0.14)
                      : AppColors.cardHoverBg)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: active
                  ? (_hovered
                      ? (widget.danger ? AppColors.dangerRed : AppColors.primaryText)
                      : baseColor)
                  : AppColors.placeholderText.withOpacity(0.5),
            ),
          ),
        ),
      ),
    );
  }
}
