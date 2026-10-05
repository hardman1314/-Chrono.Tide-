import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../big_picture_theme.dart';
import '../focus/bpm_zone_focus_controller.dart';

/// BPM 焦点辉光指示器
///
/// 包裹任意需要在 BPM 中显示焦点状态的子组件,提供:
/// - **键盘焦点态**: 高亮边框 + 阴影 (使用 [AppColors.selectedAccent])
/// - **Enter/Space 激活**: 通过 [onSelect] 回调触发,等价于点击
/// - **Enter/Space 连按两次**: 通过 [onDoubleTap] 回调触发,等价于**鼠标双击**
///   (v3.10.2: 手柄「双击 A 启动游戏」就落在这一条上)
/// - **自动聚焦**: 通过 [autofocus] 在首次构建时获取焦点
///
/// 与桌面端 [InteractiveWrapper] 仅支持鼠标 hover 不同,BPM 强调键盘/手柄可达性,
/// 因此本组件是 BPM 焦点系统的基础设施。
///
/// 使用方式:
/// ```dart
/// FocusGlow(
///   autofocus: true,
///   onSelect: () => _handleActivate(),
///   child: MyCard(),
/// )
/// ```
class FocusGlow extends StatefulWidget {
  /// 子组件
  final Widget child;

  /// 圆角,默认使用 [BigPictureTheme.defaultFocusRadius]
  final BorderRadius? borderRadius;

  /// 是否自动获取焦点
  final bool autofocus;

  /// Enter/Space 激活回调 (等价于 tap)
  final VoidCallback? onSelect;

  /// Enter/Space **连按两次**回调 (等价于鼠标双击)。
  ///
  /// 🔴 语义与 `GestureDetector` 同时给 `onTap` + `onDoubleTap` 时**一致**:
  /// 第一次按下不立即触发 [onSelect], 而是等满 [doubleTapWindow]
  /// 确认没有第二次按下才算单击 —— 否则单击会先把双击的机会吃掉
  /// (库页海报墙单击 = 开详情面板, 那是一条**模态**, 一旦立即打开,
  /// 「双击 A 启动」永远不可能发生)。这与鼠标在同一张卡上的体感完全相同。
  ///
  /// 为 null 时行为与改动前**逐位一致**: 立即触发 [onSelect], 零延迟。
  final VoidCallback? onDoubleTap;

  /// 外部传入的焦点节点 (用于父组件控制焦点)
  final FocusNode? focusNode;

  /// 包含描述 (供读屏器朗读)
  final String? semanticsLabel;

  /// v3.5: 是否绘制焦点环。
  ///
  /// shelf 卡片等「选中态自带环」的场景传 false,
  /// 避免焦点环与选中环同时出现造成语义打架。
  final bool showRing;

  /// v3.6-re: 非焦点态是否绘制常驻投影。
  ///
  /// 原实现无论有无焦点都会画一层 `0x33000000 / blur 8` 的矩形投影
  /// (模拟卡片浮起)。侧边栏图标要求「无底板、无背景框」,这一层会在
  /// 每个按钮位置留下与按钮等宽的矩形暗块 (实测 20 级亮度台阶)。
  /// 默认 true 保持 shelf 卡片等既有观感;侧边栏传 false。
  final bool idleShadow;

  /// v3.5: 焦点环线宽 (默认 [BigPictureTheme.cardFocusGlowWidth])。
  /// 侧边栏等强调「去边框」的场景传 2。
  final double ringWidth;

  /// 连按判定窗口。对齐 Flutter 自身的 `kDoubleTapTimeout` (300ms) ——
  /// 手柄连按两次 A 与鼠标双击在同一张卡上应当是同一套手感。
  static const Duration doubleTapWindow = Duration(milliseconds: 300);

  /// v3.22: **手柄合成** Enter/Space（`event.synthesized == true`）是否参与
  /// 连按双击判定。
  ///
  /// - 默认 true（逐位保持既有行为：手柄「双击 A 启动」等依赖连按判定的场景不变）；
  /// - 主页 shelf 卡片传 false —— 手柄 A 保持「单击立即激活」（v3.14 决策），
  ///   而真实键盘 Enter 由 [keyboardDoubleTap]（wrapper 层）控制参与连按。
  final bool synthesizedDoubleTap;

  /// 连按判定的时间源。生产用 [DateTime.now]。
  ///
  /// 测试可替换为受控函数: `tester.pump()` 只推进 FakeAsync 时钟,
  /// **不会**推进 `DateTime.now()`, 不注入就无法确定性地分开验证
  /// 「单击(超窗落地)」与「双击(窗内)」两条分支。
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  const FocusGlow({
    super.key,
    required this.child,
    this.borderRadius,
    this.autofocus = false,
    this.onSelect,
    this.onDoubleTap,
    this.focusNode,
    this.semanticsLabel,
    this.showRing = true,
    this.ringWidth = BigPictureTheme.cardFocusGlowWidth,
    this.idleShadow = true,
    this.synthesizedDoubleTap = true,
  });

  @override
  State<FocusGlow> createState() => _FocusGlowState();
}

class _FocusGlowState extends State<FocusGlow> {
  late final FocusNode _focusNode;
  bool _isFocused = false;

  /// 上一次激活的时刻 (仅在 [FocusGlow.onDoubleTap] 非空时使用)
  DateTime? _lastActivateAt;

  /// 挂起中的「单击」—— 双击窗口结束后才真正触发 [FocusGlow.onSelect]
  Timer? _pendingSelect;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _pendingSelect?.cancel();
    _pendingSelect = null;
    _focusNode.removeListener(_handleFocusChange);
    // 仅销毁内部创建的节点,外部传入的由外部管理
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    // 🔴 失焦必须丢掉挂起的单击: 否则「在 A 卡上按一下 → 立刻移到 B 卡」
    // 会让 A 卡的单击在 300ms 后落地(库页表现为「打开了上一张卡的详情」)。
    if (!focused) _cancelPendingActivation();
    if (focused != _isFocused) {
      setState(() => _isFocused = focused);
    }
  }

  void _cancelPendingActivation() {
    _pendingSelect?.cancel();
    _pendingSelect = null;
    _lastActivateAt = null;
  }

  /// 处理键盘事件: Enter / Space 激活; 连按两次 ≡ 鼠标双击
  ///
  /// v3.22: 连按参与资格按事件**来源**裁决 ——
  /// - 手柄合成 Enter（synthesized）→ [synthesizedDoubleTap]；
  /// - 真实键盘 Enter/Space → 恒允许参与（onDoubleTap 传入即走窗口）。
  /// 这让「手柄 A 单击立即生效 + 键盘连按两次 Enter = 双击」可以在同一张
  /// 卡片上并存（主页 shelf 卡片 v3.22 交互）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.onSelect == null && widget.onDoubleTap == null) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      _activate(
        allowDoubleTap:
            event.synthesized ? widget.synthesizedDoubleTap : true,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 一次激活 (手柄 A / 键盘 Enter/Space)。
  ///
  /// - [allowDoubleTap] 为 false（如手柄合成事件被 [synthesizedDoubleTap]
  ///   关闭）→ 立即 [FocusGlow.onSelect], 零延迟;
  /// - 无 [FocusGlow.onDoubleTap] → 立即 [FocusGlow.onSelect] (旧行为, 零延迟);
  /// - 有且允许 → 首次按下挂起, 窗口内再按一次则判为**双击**; 窗口未被第二按
  ///   打断才回落成单击。
  void _activate({required bool allowDoubleTap}) {
    final onDoubleTap = widget.onDoubleTap;
    if (onDoubleTap == null || !allowDoubleTap) {
      widget.onSelect?.call();
      return;
    }
    final now = FocusGlow.clock();
    final last = _lastActivateAt;
    if (last != null && now.difference(last) <= FocusGlow.doubleTapWindow) {
      _cancelPendingActivation();
      onDoubleTap();
      return;
    }
    // 走到这里说明上一条挂起的单击已超窗但定时器尚未跑完 (注入时钟的场景)
    // 或根本无挂起项 —— 先把前一次单击落地, 保证「两次慢按 = 两次单击」。
    if (_pendingSelect != null) {
      _pendingSelect!.cancel();
      _pendingSelect = null;
      widget.onSelect?.call();
    }
    _lastActivateAt = now;
    _pendingSelect = Timer(FocusGlow.doubleTapWindow, () {
      _pendingSelect = null;
      _lastActivateAt = null;
      widget.onSelect?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BigPictureTheme.defaultFocusRadius;
    // v3.5: 焦点环色改走 BPM 调色板。原实现读 AppColors.selectedAccent,
    // 会跟随桌面主题(如暖阳的浅蓝),与 Cinema 樱粉强调色打架 ——
    // 这正是「shelf 选中效果与实际体验不符」的根因之一。
    final glowColor = BpmColors.selectedAccent;
    // v3.10: 板块选择模式下只高亮**整个板块容器**, 组件焦点环让位
    // (规范第 6 条)。无 [BpmZoneFocusScope] 时 maybeZoneMode 返回 null,
    // 行为与改动前逐位一致 —— 这是既有 60 例 BPM 测试与桌面模式的零回归保证。
    final zoneMode = BpmZoneFocusScope.maybeZoneMode(context);
    final ringVisible = _isFocused && widget.showRing && zoneMode != true;
    final width = widget.ringWidth;

    Widget core = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKeyEvent,
      child: AnimatedContainer(
        duration: BigPictureTheme.focusAnimDuration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: ringVisible
              ? Border.all(color: glowColor, width: width)
              : Border.all(color: Colors.transparent, width: width),
          boxShadow: ringVisible
              ? [
                  // 浅色主题白底上 45% 亮蓝光圈刺眼,降档到 28%/16
                  BoxShadow(
                    color: glowColor.withOpacity(BpmColors.isDark ? 0.45 : 0.28),
                    blurRadius: BpmColors.isDark ? 24 : 16,
                    spreadRadius: BpmColors.isDark ? 2 : 1,
                  ),
                ]
              : (widget.idleShadow
                  ? const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ]
                  : null),
        ),
        child: widget.child,
      ),
    );

    // 包含描述 (供读屏器朗读) - 通过 Semantics widget 实现
    if (widget.semanticsLabel != null) {
      core = Semantics(
        button: true,
        label: widget.semanticsLabel,
        focused: _isFocused,
        child: core,
      );
    }
    return core;
  }
}
