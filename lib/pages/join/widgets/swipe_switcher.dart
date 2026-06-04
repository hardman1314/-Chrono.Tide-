import 'package:flutter/material.dart';
import '../../../widgets/interactive_wrapper.dart';

enum ImportMode { single, batch }

class SwipeSwitcher extends StatefulWidget {
  final Widget singleModeChild;
  final Widget batchModeChild;
  final ImportMode initialMode;
  final ValueChanged<ImportMode>? onModeChanged;
  final bool hasContent;

  const SwipeSwitcher({
    super.key,
    required this.singleModeChild,
    required this.batchModeChild,
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
  bool _isSwipeModeActive = false; // 是否真正进入了滑动切换模式
  double _swipeOffset = 0.0;

  static const double maxSwipeOffset = 100.0; // 最大滑动距离
  static const double dragThreshold = 20.0; // 最小拖拽距离（防止误触）
  static const longPressDuration = Duration(milliseconds: 600); // 长按时间

  @override
  void initState() {
    super.initState();
    _currentMode = widget.initialMode;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animation = Tween<double>(
      begin: 0,
      end: 1.0,
    ).animate(CurvedAnimation(
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

    // 不再使用延迟长按检测，改为基于实际拖拽距离判断
  }

  void _onPointerMove(PointerMoveEvent event) {
    _dragCurrentX = event.position.dx;

    final delta = (_dragCurrentX - _dragStartX).abs();

    // 必须超过最小拖拽距离才认为是有效拖拽
    if (delta > dragThreshold) {
      if (!_isDragging) {
        _isDragging = true;
        debugPrint('[SWIPE] 检测到有效拖拽，距离: ${delta.toStringAsFixed(1)}px');
      }

      // 进一步检查：只有明显的水平拖拽才激活滑动切换模式
      // 要求拖拽距离至少达到最大滑动距离的30%
      if (delta > (maxSwipeOffset * 0.3) && !_isSwipeModeActive) {
        _isSwipeModeActive = true;
        debugPrint('[SWIPE] ✓ 进入滑动切换模式');
      }
    }

    // 只在滑动模式下更新偏移
    if (!_isSwipeModeActive) return;

    // 计算滑动偏移（限制在合理范围内）
    double rawDelta = _dragCurrentX - _dragStartX;

    // 根据当前模式决定方向和限制
    if (_currentMode == ImportMode.single) {
      // 单文件模式：只能向左滑（负值）
      rawDelta = rawDelta.clamp(-maxSwipeOffset, 0);
    } else {
      // 批量模式：只能向右滑（正值）
      rawDelta = rawDelta.clamp(0, maxSwipeOffset);
    }

    _swipeOffset = rawDelta;
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent event) {
    // 如果没有进入滑动模式，直接重置（普通点击）
    if (!_isSwipeModeActive) {
      _resetState();
      return;
    }

    final delta = _dragCurrentX - _dragStartX;
    final threshold = maxSwipeOffset * 0.55; // 55%的滑动距离触发切换

    bool shouldSwitch = false;

    if (_currentMode == ImportMode.single) {
      // 向左滑（负值）超过阈值 → 切换到批量
      shouldSwitch = delta < -threshold;
    } else {
      // 向右滑（正值）超过阈值 → 切换单文件
      shouldSwitch = delta > threshold;
    }

    debugPrint(
        '[SWIPE] 释放 - 总距离: ${delta.toStringAsFixed(1)}px, 阈值: ${threshold.toStringAsFixed(1)}px, 切换: $shouldSwitch');

    if (shouldSwitch) {
      // 执行切换动画
      if (_currentMode == ImportMode.single) {
        _switchToBatch();
      } else {
        _switchToSingle();
      }
    } else {
      // 不够距离，弹回原位
      debugPrint('[SWIPE] 距离不足，弹回');
      _animateReset();
    }
  }

  void _switchToSingle() {
    _currentMode = ImportMode.single;
    widget.onModeChanged?.call(_currentMode);

    // 从当前位置动画回到0
    _animationController.animateTo(0.0);

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

  void _switchToBatch() {
    _currentMode = ImportMode.batch;
    widget.onModeChanged?.call(_currentMode);

    // 动画过渡到批量模式
    _animationController.animateTo(1.0);

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
    // 使用动画平滑复位
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
        // 顶部导航栏
        _buildModeNavigationBar(),
        const SizedBox(height: 4),
        // 主内容区域
        Expanded(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            child: ClipRect(
              // 关键：裁剪溢出内容
              child: Stack(
                children: [
                  // 当前模式的视图（跟随手指微动）
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
                  // 目标模式视图（淡入显示）
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
                                  (1.0 - _animation.value) * 20 +
                                      _swipeOffset * 0.3,
                                  0),
                              child: widget.batchModeChild,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // 滑动提示层（仅在进入滑动模式且没有内容时显示）
                  if (_isSwipeModeActive && !widget.hasContent)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B7355).withOpacity(0.03),
                          border: Border.all(
                            color: const Color(0xFF8B7355).withOpacity(0.5),
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
                                color: const Color(0xFF8B7355).withOpacity(0.5),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _currentMode == ImportMode.single
                                    ? '← 向左滑动切换'
                                    : '→ 向右滑动切换',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.0,
                                  color:
                                      const Color(0xFF8B7355).withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 构建模式切换导航栏
  Widget _buildModeNavigationBar() {
    final isSingle = _currentMode == ImportMode.single;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF8B7355), width: 1.5),
        borderRadius: BorderRadius.circular(2),
        color: const Color(0xFFFDFBF7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 单文件模式按钮
          _buildModeButton(
            icon: Icons.add,
            isSelected: isSingle,
            onTap: () {
              if (!isSingle) {
                _switchToSingle();
              }
            },
          ),
          const SizedBox(width: 4),
          // 批量模式按钮
          _buildModeButton(
            icon: Icons.create_new_folder,
            isSelected: !isSingle,
            onTap: () {
              if (isSingle) {
                _switchToBatch();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF8B7355).withOpacity(0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(2),
          border: isSelected
              ? Border.all(color: const Color(0xFF8B7355), width: 1)
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 16,
          color: isSelected
              ? const Color(0xFF8B7355)
              : const Color(0xFF8B7355).withOpacity(0.6),
        ),
      ),
    );
  }
}
