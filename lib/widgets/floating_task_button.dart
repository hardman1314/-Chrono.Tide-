import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
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
    _animationController.dispose();
    super.dispose();
  }

  void _syncInitialState() {
    final center = GlobalInstallCenter.instance;

    if (center.currentTask != null && center.phase != InstallPhase.idle) {
      _displayPercent = center.progress.downloadPercent > 0
          ? center.progress.downloadPercent
          : center.progress.extractPercent;

      switch (center.phase) {
        case InstallPhase.downloading:
          _taskLabel = '下载中';
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
        debugPrint('[FLOAT-BTN] 全局无任务 → 回到idle');
        _transitionTo(_BtnState.idle);
      }
      return;
    }

    switch (newPhase) {
      case InstallPhase.downloading:
        _taskLabel = '下载中';
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
  }

  bool _isTerminalState() =>
      _state == _BtnState.success || _state == _BtnState.failed;

  void _transitionTo(_BtnState newState) {
    if (_state == newState && newState != _BtnState.running) return;

    final oldState = _state;
    _state = newState;
    debugPrint('[FLOAT-BTN] 状态更新: $oldState → $newState');

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
      _startAutoHideTimer(3, '安装完成');
    } else if (newState == _BtnState.failed) {
      _startAutoHideTimer(5, '安装失败');
    }
  }

  void _startAutoHideTimer(int seconds, String reason) {
    debugPrint('[FLOAT-BTN] 启动$seconds秒自动隐藏定时器 | $reason');

    _autoHideTimer = Timer(Duration(seconds: seconds), () {
      debugPrint('[FLOAT-BTN] ⏰ 定时器触发 → 淡出隐藏');
      if (mounted) {
        _transitionTo(_BtnState.idle);
      }
    });
  }

  void _cancelAutoHideTimer() {
    if (_autoHideTimer != null) {
      debugPrint('[FLOAT-BTN] 取消自动隐藏定时器');
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
    }
  }

  void _handleTap() {
    final center = GlobalInstallCenter.instance;
    debugPrint(
        '[FLOAT-BTN] 👆 点击触发 | 当前状态: $_state | 任务: ${center.currentTask?.title}');
    widget.onTap.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible && _animationController.value == 0) {
      return const SizedBox.shrink();
    }

    Color borderColor;
    Color iconColor;
    IconData iconData;
    String label;

    switch (_state) {
      case _BtnState.success:
        borderColor = const Color(0xFF4A7C59);
        iconColor = const Color(0xFF4A7C59);
        iconData = Icons.check_circle_rounded;
        label = '安装完成';
        break;
      case _BtnState.failed:
        borderColor = const Color(0xFFD4183D);
        iconColor = const Color(0xFFD4183D);
        iconData = Icons.error_rounded;
        label = '安装失败';
        break;
      case _BtnState.running:
        borderColor = const Color(0xFF4A72A5);
        iconColor = const Color(0xFF4A72A5);
        iconData = Icons.downloading_rounded;
        label = '$_taskLabel ${_displayPercent.toStringAsFixed(0)}%';
        break;
      default:
        borderColor = AppColors.border;
        iconColor = AppColors.secondaryText;
        iconData = Icons.install_desktop_rounded;
        label = '安装中心';
    }

    final showArrow = _state == _BtnState.running;

    return AnimatedBuilder(
      animation: _slideAnimation,
      builder: (context, child) {
        return Positioned(
          left: 16,
          bottom: 16,
          child: Opacity(
            opacity: _slideAnimation.value,
            child: child!,
          ),
        );
      },
      child: InteractiveWrapper(
        onTap: _handleTap,
        hoverScale: 1.05,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFDFBF7),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor, width: 1.5),
            boxShadow: [
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
                    style: const TextStyle(
                      fontFamily: 'Mali',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF6D5B4D),
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (_state == _BtnState.running && _speedText.isNotEmpty)
                    Text(
                      _speedText,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
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
      ),
    );
  }
}
