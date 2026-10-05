import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/running_tasks_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import 'running_task_bar.dart';

/// 窗口内顶部悬浮常驻的【游戏运行任务状态横幅】
///
/// 特性：
/// - **悬浮叠加**：作为 Stack 的 positioned child（外层 `Center` 包裹），覆盖在
///   页面内容之上，不参与下方布局流，因此不会挤压游戏列表页面。
/// - **多任务堆叠**：多条任务自上而下排列，各自独立计时、独立管控。
/// - **空态零占位**：无任务时返回 [SizedBox.shrink]，不残留任何高度与命中区域；
///   且自动恢复为展开默认态。
/// - **收起 / 展开**：默认完整展示；用户可点底部把手条收起，释放顶部空间。
///   收起后由一条居中胶囊（含运行数量与未读红点）提供重新展开入口，
///   平滑过渡（高度 + 淡入淡出），避免界面元素突兀跳动。
/// - **收起态轻量提示**：收起期间若发生重要状态变化（运行中 / 游戏退出 / 启动失败），
///   胶囊显示未读红点，展开即清除。
/// - **跟随主题**：外层监听 [AppThemeManager]，切换主题时自动重绘。
///
/// 挂载位置见 `lib/main_container.dart` 的 `_buildDesktopShell`。
/// BPM 大屏模式（全屏沉浸 UI）不挂载本组件。
class RunningTasksBanner extends StatefulWidget {
  const RunningTasksBanner({super.key});

  /// 相邻横幅的间距
  static const double _gap = 8.0;

  @override
  State<RunningTasksBanner> createState() => _RunningTasksBannerState();
}

class _RunningTasksBannerState extends State<RunningTasksBanner> {
  /// 是否处于收起态（默认展开）
  bool _collapsed = false;

  /// 收起态「已读到」的事件计数；当服务侧的 [RunningTasksService.bannerEventEpoch]
  /// 超过本值时，说明收起期间发生了未关注的重要变化，需显示红点。
  int _lastSeenEpoch = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppThemeManager.instance,
      builder: (context, _) {
        return AnimatedBuilder(
          animation: RunningTasksService.instance,
          builder: (context, _) {
            final service = RunningTasksService.instance;
            final tasks = service.tasks;

            // 无任务：零占位，并自动回到展开默认态（同时把已读计数追平当前，
            // 避免下次出现任务后、用户收起时因历史计数而误报红点）。
            if (tasks.isEmpty) {
              if (_collapsed) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _collapsed = false);
                });
              }
              _lastSeenEpoch = service.bannerEventEpoch;
              return const SizedBox.shrink();
            }

            final collapsed = _collapsed;
            return AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: collapsed
                  ? _buildCollapsedPill(service, tasks)
                  : _buildExpanded(service, tasks),
            );
          },
        );
      },
    );
  }

  /// 展开态：堆叠的任务横幅 + 底部「收起把手条」
  Widget _buildExpanded(
      RunningTasksService service, List<RunningTask> tasks) {
    return Column(
      key: const ValueKey<String>('expanded'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.only(bottom: RunningTasksBanner._gap),
            child: _TaskTransition(
              key: ValueKey<String>(task.metaDataDir),
              fading: task.fading,
              child: RunningTaskBar(task: task),
            ),
          ),
        _CollapseHandle(
          onTap: () => setState(() => _collapsed = true),
        ),
      ],
    );
  }

  /// 收起态：居中胶囊入口（数量 + 未读红点），点击展开并清除未读
  Widget _buildCollapsedPill(
      RunningTasksService service, List<RunningTask> tasks) {
    final unread = service.bannerEventEpoch > _lastSeenEpoch;
    final activeCount = tasks.where((t) =>
        t.status == RunningTaskStatus.launching ||
        t.status == RunningTaskStatus.running).length;
    final label =
        activeCount > 0 ? '$activeCount 款游戏运行中' : '游戏任务提醒';
    return _CollapsedPill(
      key: const ValueKey<String>('collapsed'),
      label: label,
      unread: unread,
      onTap: () {
        _lastSeenEpoch = service.bannerEventEpoch;
        setState(() => _collapsed = false);
      },
    );
  }
}

/// 展开态底部「收起把手条」
///
/// 一条细磨砂小条，居中于横幅下方，常驻可见且不遮挡内容。
/// 点击收起整组横幅，释放顶部空间。克制的 hover 反馈（背景 + 图标变色）。
class _CollapseHandle extends StatefulWidget {
  final VoidCallback onTap;

  const _CollapseHandle({required this.onTap});

  @override
  State<_CollapseHandle> createState() => _CollapseHandleState();
}

class _CollapseHandleState extends State<_CollapseHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 64,
          height: 18,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.cardHoverBg
                : AppColors.background.withOpacity(0.4),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: AppColors.border.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: Center(
            child: Icon(
              Icons.keyboard_arrow_up,
              size: 14,
              color: _hovered
                  ? AppColors.primaryText
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}

/// 收起态的「重新展开入口」——居中胶囊
///
/// 游戏手柄图标 + 运行数量文案 +（可选）未读红点。点击展开横幅并清除未读。
/// 磨砂半透明圆角，与展开态横幅风格一致。
class _CollapsedPill extends StatelessWidget {
  final String label;
  final bool unread;
  final VoidCallback onTap;

  const _CollapsedPill({
    super.key,
    required this.label,
    required this.unread,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(0.72),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.border.withOpacity(0.45),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor.withOpacity(0.18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.sports_esports,
                  size: 15,
                  color: AppColors.infoBlue,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primaryText,
                  ),
                ),
                if (unread) ...[
                  const SizedBox(width: 7),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.dangerRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单条横幅的进出场过渡
///
/// 入场：首次构建后的下一帧从上方轻微下滑 + 淡入。
/// 退场：[fading] 置 true 时淡出并上移，动画时长与服务的
/// [RunningTasksService.fadeOutDuration] 对齐，动画播完服务才真正移除任务。
class _TaskTransition extends StatefulWidget {
  final bool fading;
  final Widget child;

  const _TaskTransition({
    super.key,
    required this.fading,
    required this.child,
  });

  @override
  State<_TaskTransition> createState() => _TaskTransitionState();
}

class _TaskTransitionState extends State<_TaskTransition> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    // 延到下一帧再置 true，让 Animated* 有一个从初始态到目标态的过渡过程；
    // 若在 initState 内直接置 true，首帧就是目标态，动画不会播放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _entered && !widget.fading;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: RunningTasksService.fadeOutDuration,
      curve: Curves.easeOutCubic,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, -0.35),
        duration: RunningTasksService.fadeOutDuration,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
