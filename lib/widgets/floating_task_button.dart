import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../services/global_install_center.dart';
import 'interactive_wrapper.dart';

enum _BtnState { idle, running, success, failed }

class FloatingTaskButton extends StatefulWidget {
  final VoidCallback onTap;

  const FloatingTaskButton({super.key, required this.onTap});

  @override
  State<FloatingTaskButton> createState() => _FloatingTaskButtonState();
}

class _FloatingTaskButtonState extends State<FloatingTaskButton>
    with SingleTickerProviderStateMixin {
  _BtnState _state = _BtnState.idle;
  double _displayPercent = 0.0;
  String _taskLabel = '';
  String _speedText = '';

  bool _isVisible = false;
  late AnimationController _animationController;
  late Animation<double> _slideAnimation;

  Timer? _autoHideTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );

    GlobalInstallCenter.instance
        .addListener(phase: _onPhaseChanged, progress: _onProgressChanged);
    GlobalInstallCenter.instance.addQueueListener(_onQueueChanged);
    _syncInitialState();
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    GlobalInstallCenter.instance.removeListener(
      phase: _onPhaseChanged,
      progress: _onProgressChanged,
    );
    GlobalInstallCenter.instance.removeQueueListener(_onQueueChanged);
    _animationController.dispose();
    super.dispose();
  }

  /// 队列变更：运行中标签需要更新排队数提示
  void _onQueueChanged() {
    if (!mounted) return;
    if (_state == _BtnState.running) {
      setState(() {});
    }
  }

  void _syncInitialState() {
    final center = GlobalInstallCenter.instance;

    if (center.currentTask != null && center.phase != InstallPhase.idle) {
      _displayPercent = center.progress.downloadPercent > 0
          ? center.progress.downloadPercent
          : center.progress.extractPercent;

      switch (center.phase) {
        case InstallPhase.downloading:
          _taskLabel = '获取中';
          _speedText = center.progress.downloadSpeed;
          if (center.isRunning) _transitionTo(_BtnState.running);
          break;
        case InstallPhase.extracting:
          _taskLabel = '解压中';
          _speedText = '';
          if (center.isRunning) _transitionTo(_BtnState.running);
          break;
        case InstallPhase.completed:
          _transitionTo(_BtnState.success);
          break;
        case InstallPhase.failed:
          _transitionTo(_BtnState.failed);
          break;
        default:
          break;
      }
    }
  }

  void _onPhaseChanged(InstallPhase newPhase) {
    if (!mounted) return;

    if (newPhase == InstallPhase.idle ||
        (GlobalInstallCenter.instance.currentTask == null &&
            newPhase == InstallPhase.idle)) {
      if (_state != _BtnState.idle && !_isTerminalState()) {
        _transitionTo(_BtnState.idle);
      }
      return;
    }

    switch (newPhase) {
      case InstallPhase.downloading:
        _taskLabel = '获取中';
        _transitionTo(_BtnState.running);
        break;
      case InstallPhase.extracting:
        _taskLabel = '解压中';
        _transitionTo(_BtnState.running);
        break;
      case InstallPhase.completed:
        _transitionTo(_BtnState.success);
        break;
      case InstallPhase.failed:
        _transitionTo(_BtnState.failed);
        break;
      case InstallPhase.cancelled:
        _transitionTo(_BtnState.failed);
        break;
      default:
        break;
    }
  }

  void _onProgressChanged(InstallProgress newProgress) {
    if (!mounted) return;

    final center = GlobalInstallCenter.instance;

    // 性能优化：仅更新数据，不立即 setState
    // 让 build 方法通过 RepaintBoundary 隔离重绘
    final newPercent = center.phase == InstallPhase.downloading
        ? newProgress.downloadPercent
        : newProgress.extractPercent;

    // 仅当百分比变化 >= 2% 时才触发重建，减少不必要的 UI 刷新
    if ((newPercent - _displayPercent).abs() >= 2.0 ||
        _speedText != newProgress.downloadSpeed) {
      setState(() {
        switch (center.phase) {
          case InstallPhase.downloading:
            _displayPercent = newProgress.downloadPercent;
            _speedText = newProgress.downloadSpeed;
            break;
          case InstallPhase.extracting:
            _displayPercent = newProgress.extractPercent;
            _speedText = '';
            break;
          default:
            _displayPercent = newProgress.downloadPercent > 0
                ? newProgress.downloadPercent
                : newProgress.extractPercent;
            _speedText = newProgress.downloadSpeed;
            break;
        }
      });
    } else {
      // 静默更新数据，下次重建时生效
      _displayPercent = newPercent;
      _speedText = newProgress.downloadSpeed;
    }
  }

  bool _isTerminalState() =>
      _state == _BtnState.success || _state == _BtnState.failed;

  void _transitionTo(_BtnState newState) {
    if (_state == newState && newState != _BtnState.running) return;

    _state = newState;

    if (newState == _BtnState.idle) {
      _cancelAutoHideTimer();
      if (_isVisible) {
        _isVisible = false;
        _animationController.reverse().then((_) {
          if (mounted) setState(() {});
        });
      }
      setState(() {});
      return;
    }

    _cancelAutoHideTimer();

    if (!_isVisible) {
      _isVisible = true;
      _animationController.forward(from: 0);
    }
    setState(() {});

    if (newState == _BtnState.success) {
      _startAutoHideTimer(3);
    } else if (newState == _BtnState.failed) {
      _startAutoHideTimer(5);
    }
  }

  void _startAutoHideTimer(int seconds) {
    _autoHideTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) {
        _transitionTo(_BtnState.idle);
      }
    });
  }

  void _cancelAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  void _handleTap() {
    widget.onTap.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible && _animationController.value == 0) {
      return const SizedBox.shrink();
    }

    // [BugFix 白屏] 移除内层的 Positioned
    // 原因:外层 main_container 的 Stack 已经用 Positioned(left: 16, bottom: 16)
    // 包裹本 Widget,这里再嵌一层 Positioned 会:
    //   1. 找不到有效的 Stack 祖先(它在 AnimatedBuilder.builder 内,每次 rebuild 创建新实例)
    //   2. applyParentData 时报错或被忽略
    //   3. 同时这个失效的 Positioned 会让 AnimatedBuilder 内部 layout 出现意外行为
    // 现在:RepaintBoundary 直接包裹 AnimatedBuilder 提供的 Opacity 动画
    //     + InteractiveWrapper 容器即可,定位交给外层 Positioned
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _slideAnimation,
        builder: (context, child) {
          return Opacity(
            opacity: _slideAnimation.value,
            child: child!,
          );
        },
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    Color borderColor;
    Color iconColor;
    IconData iconData;
    String label;

    switch (_state) {
      case _BtnState.success:
        borderColor = AppColors.successGreen;
        iconColor = AppColors.successGreen;
        iconData = Icons.check_circle_rounded;
        label = '安装完成';
        break;
      case _BtnState.failed:
        borderColor = AppColors.dangerRed;
        iconColor = AppColors.dangerRed;
        iconData = Icons.error_rounded;
        label = '安装失败';
        break;
      case _BtnState.running:
        borderColor = AppColors.infoBlue;
        iconColor = AppColors.infoBlue;
        iconData = Icons.downloading_rounded;
        label = '$_taskLabel ${_displayPercent.toStringAsFixed(0)}%';
        // 队列模式：附带排队数轻量提示
        final queueLength = GlobalInstallCenter.instance.queueLength;
        if (queueLength > 0) {
          label += ' ·$queueLength排队';
        }
        break;
      default:
        borderColor = AppColors.border;
        iconColor = AppColors.secondaryText;
        iconData = Icons.install_desktop_rounded;
        label = '安装中心';
    }

    final showArrow = _state == _BtnState.running;

    // [BugFix 白屏] 不再嵌套 Positioned 和 Opacity/AnimatedBuilder
    // 它们已经在外层 build() 中通过 AnimatedBuilder + Opacity 处理
    // 这里只负责构建按钮本体的视觉内容
    return InteractiveWrapper(
      onTap: _handleTap,
      hoverScale: 1.05,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppStyle.isModern
              ? AppColors.buttonBackground
              : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: AppStyle.isModern
              ? Border.all(
                  color: borderColor.withAlpha(89),
                  width: AppStyle.wHairline)
              : Border.all(color: borderColor, width: 1.5),
          boxShadow: AppStyle.isModern
              ? AppStyle.e2
              : [
                  BoxShadow(
                    color: borderColor.withOpacity(0.15),
                    offset: const Offset(2, 4),
                    blurRadius: 8,
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isTerminalState())
              Icon(iconData, size: 18, color: iconColor)
            else
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                ),
              ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryText,
                    letterSpacing: 0.5,
                  ),
                ),
                if (_state == _BtnState.running && _speedText.isNotEmpty)
                  Text(
                    _speedText,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.secondaryText.withOpacity(0.5),
                    ),
                  ),
              ],
            ),
            if (showArrow) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 12,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
