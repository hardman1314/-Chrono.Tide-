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
    // ★ IMP-20: 兜底释放回弹动画控制器（页面在动画期间被销毁的场景）
    _resetController?.dispose();
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

  /// 回弹动画控制器（★ IMP-20：复用单个实例，避免泄漏）
  AnimationController? _resetController;
  double _resetStartOffset = 0;

  void _animateReset() {
    _resetStartOffset = _swipeOffset;

    // ★ IMP-20（2026-09-12 导入审查）：旧实现每次回弹 new 一个 AnimationController、
    // 且只在"动画完成"时释放 —— 若页面在这 200ms 内被销毁，控制器永远不被释放
    // （ticker 泄漏，debug 下断言报错）。现改为复用单个实例 + dispose 兜底释放。
    _resetController?.dispose();
    final animation = _resetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    animation.addListener(() {
      if (!mounted) return;
      setState(() {
        _swipeOffset = _resetStartOffset * (1 - animation.value);
      });
    });

    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _isDragging = false;
        _isSwipeModeActive = false;
        if (mounted) setState(() {});
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
        // 连体：原 4px 间隙取消，导航栏底边与置入板块顶边贴合
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
  //
  // ★「连体选项卡」改造（2026-10-02 走查）：
  // 设计稿实测——导航栏 184×28，悬在置入板块顶边线上方 2px，底边线与板块顶边线
  // （y=308）几乎重合，顶部圆角实测 ≈14（= 半圆）。故本实现按「选项卡坐在板块顶边上」：
  //   ① 去掉栏自身底边框 → 底边线改由「置入板块顶边框」充当（两条线合一）；
  //   ② 顶部 20 圆角（栏高 28 时 Skia 会把半径钳位到 14 → 与设计稿半圆一致）；
  //   ③ 与板块之间的 4px 间隙取消，选项卡直接坐落在板块顶边上。
  // 智能模式的内容区是 SingleChildScrollView + 自带边框的卡片（**没有**外框），
  // 若也去掉底边框会出现「开口」选项卡，故智能模式保留底边框。
  Widget _buildModeNavigationBar() {
    // 设计稿「模式切换栏」183×28：栏内边距 8、按钮 52~53.5×24、按钮内边距 7、
    // 文字 11 → 3×(14+3+22+14) + 2×4 + 2×8 ≈ 183，与设计逐像素吻合。
    final bool fuseWithPanel = _currentMode != ImportMode.smart;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border, width: 1),
          left: BorderSide(color: AppColors.border, width: 1),
          right: BorderSide(color: AppColors.border, width: 1),
          bottom: fuseWithPanel
              ? BorderSide.none
              : BorderSide(color: AppColors.border, width: 1),
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            // 设计稿选中态底 #eee7dc ≈ buttonBackground，边框 #a58b6c ≈ border
            color: isSelected ? AppColors.buttonBackground : Colors.transparent,
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
                  // 设计稿 fs=11
                  fontSize: 11,
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
