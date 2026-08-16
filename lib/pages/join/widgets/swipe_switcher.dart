import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

enum ImportMode { single, batch, smart }

class SwipeSwitcher extends StatefulWidget {
  final Widget singleModeChild;
  final Widget batchModeChild;
  final Widget? smartModeChild;
  final ImportMode initialMode;
  final ValueChanged<ImportMode>? onModeChanged;
  final bool hasContent;

  const SwipeSwitcher({
    super.key,
    required this.singleModeChild,
    required this.batchModeChild,
    this.smartModeChild,
    this.initialMode = ImportMode.single,
    this.onModeChanged,
    this.hasContent = false,
  });

  @override
  State<SwipeSwitcher> createState() => _SwipeSwitcherState();
}

class _SwipeSwitcherState extends State<SwipeSwitcher>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  ImportMode _currentMode = ImportMode.single;

  double _dragStartX = 0;
  double _dragCurrentX = 0;
  bool _isDragging = false;
  bool _isSwipeModeActive = false;
  double _swipeOffset = 0.0;

  static const double maxSwipeOffset = 100.0;
  static const double dragThreshold = 20.0;

  @override
  void initState() {
    super.initState();
    _currentMode = widget.initialMode;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animation = Tween<double>(begin: 0, end: 1.0).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOutCubic,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    _dragStartX = event.position.dx;
    _dragCurrentX = event.position.dx;
    _isDragging = false;
    _isSwipeModeActive = false;
    _swipeOffset = 0.0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    _dragCurrentX = event.position.dx;
    final delta = (_dragCurrentX - _dragStartX).abs();

    if (delta > dragThreshold) {
      if (!_isDragging) {
        _isDragging = true;
      }
      if (delta > (maxSwipeOffset * 0.3) && !_isSwipeModeActive) {
        _isSwipeModeActive = true;
      }
    }

    if (!_isSwipeModeActive) return;

    double rawDelta = _dragCurrentX - _dragStartX;

    // 根据当前模式决定方向
    if (_currentMode == ImportMode.single) {
      rawDelta = rawDelta.clamp(-maxSwipeOffset, 0);
    } else {
      rawDelta = rawDelta.clamp(0, maxSwipeOffset);
    }

    _swipeOffset = rawDelta;
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isSwipeModeActive) {
      _resetState();
      return;
    }

    final delta = _dragCurrentX - _dragStartX;
    final threshold = maxSwipeOffset * 0.55;

    bool shouldSwitch = false;

    if (_currentMode == ImportMode.single) {
      shouldSwitch = delta < -threshold;
      if (shouldSwitch) {
        // 单文件 → 批量
        _switchToMode(ImportMode.batch);
      }
    } else {
      shouldSwitch = delta > threshold;
      if (shouldSwitch) {
        // 批量 → 单文件
        _switchToMode(ImportMode.single);
      }
    }

    if (!shouldSwitch) {
      _animateReset();
    }
  }

  void _switchToMode(ImportMode mode) {
    _currentMode = mode;
    widget.onModeChanged?.call(_currentMode);

    if (mode == ImportMode.single) {
      _animationController.animateTo(0.0);
    } else {
      _animationController.animateTo(1.0);
    }

    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _swipeOffset = 0.0;
          _isDragging = false;
          _isSwipeModeActive = false;
        });
      }
    });
  }

  void _animateReset() {
    final startOffset = _swipeOffset;
    final animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    animation.addListener(() {
      setState(() {
        _swipeOffset = startOffset * (1 - animation.value);
      });
    });

    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        animation.dispose();
        _isDragging = false;
        _isSwipeModeActive = false;
      }
    });

    animation.forward();
  }

  void _resetState() {
    _swipeOffset = 0.0;
    _isDragging = false;
    _isSwipeModeActive = false;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildModeNavigationBar(),
        const SizedBox(height: 4),
        Expanded(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            child: ClipRect(
              child: Stack(
                children: _buildContentStack(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 根据当前模式构建内容栈
  List<Widget> _buildContentStack() {
    // 智能模式直接显示，不参与滑动动画
    if (_currentMode == ImportMode.smart) {
      return [
        Positioned.fill(
          child: widget.smartModeChild ?? const SizedBox.shrink(),
        ),
      ];
    }

    // 单文件 / 批量模式保持原有滑动动画逻辑
    return [
      Positioned.fill(
        child: Transform.translate(
          offset: Offset(_swipeOffset, 0),
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, _) {
              return Opacity(
                opacity: 1.0 - (_animation.value * 0.7),
                child: widget.singleModeChild,
              );
            },
          ),
        ),
      ),
      Positioned.fill(
        child: IgnorePointer(
          ignoring: _animation.value < 0.9,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, _) {
              return Opacity(
                opacity: _animation.value,
                child: Transform.translate(
                  offset: Offset(
                      (1.0 - _animation.value) * 20 + _swipeOffset * 0.3, 0),
                  child: widget.batchModeChild,
                ),
              );
            },
          ),
        ),
      ),
      if (_isSwipeModeActive && !widget.hasContent)
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.border.withOpacity(0.03),
              border: Border.all(
                color: AppColors.border.withOpacity(0.5),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.swap_horiz_rounded,
                    size: 28,
                    color: AppColors.border.withOpacity(0.5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentMode == ImportMode.single ? '← 向左滑动切换' : '→ 向右滑动切换',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: AppColors.border.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  // 构建模式切换导航栏（三模式）
  Widget _buildModeNavigationBar() {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 1.5),
        borderRadius: BorderRadius.circular(2),
        color: AppColors.background,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeButton(
            icon: Icons.add,
            label: '单个',
            isSelected: _currentMode == ImportMode.single,
            onTap: () {
              if (_currentMode != ImportMode.single) {
                _switchToMode(ImportMode.single);
              }
            },
          ),
          const SizedBox(width: 4),
          _buildModeButton(
            icon: Icons.create_new_folder,
            label: '批量',
            isSelected: _currentMode == ImportMode.batch,
            onTap: () {
              if (_currentMode != ImportMode.batch) {
                _switchToMode(ImportMode.batch);
              }
            },
          ),
          // 智能导入模式按钮（仅当提供了 smartModeChild 时显示）
          if (widget.smartModeChild != null) ...[
            const SizedBox(width: 4),
            _buildModeButton(
              icon: Icons.auto_awesome,
              label: '智能',
              isSelected: _currentMode == ImportMode.smart,
              onTap: () {
                if (_currentMode != ImportMode.smart) {
                  _switchToMode(ImportMode.smart);
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeButton({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final selectedColor = AppColors.border;
    final unselectedColor = AppColors.border.withOpacity(0.6);
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 500),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.border.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
            border: isSelected
                ? Border.all(color: AppColors.border, width: 1)
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected ? selectedColor : unselectedColor,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? selectedColor : unselectedColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
