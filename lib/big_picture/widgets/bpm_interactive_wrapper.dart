import 'package:flutter/material.dart';
import '../big_picture_theme.dart';
import '../focus/bpm_zone_focus_controller.dart';
import 'focus_glow.dart';

/// BPM 焦点感知交互包装器
///
/// 在桌面端 [InteractiveWrapper] (仅支持鼠标 hover) 基础上扩展,
/// 同时支持 **键盘焦点** + **鼠标悬停** + **触屏点击** 三种输入。
///
/// 状态优先级: 焦点态 > 悬停态 > 普通态
///
/// - **焦点态**: 通过 [FocusGlow] 提供高亮边框+辉光,缩放 [focusScale]
/// - **悬停态**: 无焦点边框,轻微缩放 [hoverScale]
/// - **普通态**: 无特效
/// - **禁用态** ([onTap] == null): 不响应任何交互,光标变 basic
///
/// 焦点态时按 Enter/Space 会触发 [onTap],与点击等价。
class BpmInteractiveWrapper extends StatefulWidget {
  /// 子组件
  final Widget child;

  /// 点击回调 (为 null 时视为禁用态)
  final VoidCallback? onTap;

  /// 双击回调 (BPM 游戏卡片双击启动)
  ///
  /// v3.10.2: 除鼠标双击外,**手柄/键盘连按两次 A(Enter) 也会触发它** ——
  /// 见 [FocusGlow.onDoubleTap]。这是「双击 A 启动游戏」的落点。
  final VoidCallback? onDoubleTap;

  /// 长按回调 (BPM 游戏卡片长按弹出动作表)
  final VoidCallback? onLongPress;

  /// 焦点态缩放 (默认 [BigPictureTheme.cardFocusScale])
  final double focusScale;

  /// 悬停态缩放 (默认 [BigPictureTheme.cardHoverScale])
  final double hoverScale;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 是否自动获取焦点
  final bool autofocus;

  /// 外部传入焦点节点
  final FocusNode? focusNode;

  /// 鼠标光标 (禁用态会被强制为 basic)
  final MouseCursor cursor;

  /// 包含描述 (供读屏器)
  final String? semanticsLabel;

  /// v3.5: 是否绘制焦点环 (透传 [FocusGlow.showRing])
  final bool focusRing;

  /// v3.14: 是否启用「键盘/手柄连按两次 A = onDoubleTap」。
  ///
  /// 默认 true（既有行为）。设 false 时**只保留鼠标双击** —— 用于「单击进详情、
  /// 双击启动」的卡片：手柄 A 单击立即生效（还顺带消掉 300ms 的双击判定延迟），
  /// 且连按两次 A 不会再误触发启动。
  final bool enableKeyDoubleTap;

  /// v3.22: 仅**真实键盘** Enter/Space 连按两次 = onDoubleTap。
  ///
  /// 与 [enableKeyDoubleTap] 的分工：
  /// - [enableKeyDoubleTap] = 手柄**合成** Enter（synthesized）是否参与连按判定；
  /// - 本参数 = 真实键盘事件是否参与连按判定。
  ///
  /// 典型组合（主页 shelf 卡片）：`enableKeyDoubleTap: false` +
  /// `keyboardDoubleTap: true` —— 手柄 A 保持「单击进详情」（v3.14 决策），
  /// 键盘连按两次 Enter 获得与鼠标双击一致的「启动游戏」。
  final bool keyboardDoubleTap;

  /// v3.22: 「先选中、再操作」两段式 —— 指针点击**无焦点**的组件时，
  /// 只把焦点落给它（选中反馈，触发 [onFocusChange]），**不**触发 [onTap]；
  /// 点击已持有焦点的组件才正常触发 [onTap]。
  ///
  /// 对应主页 shelf 卡片交互：第一次点击 = 选中切舞台，再次点击 = 进详情；
  /// 双击 = 启动（双击的第一击同样只落焦点，第二击构成 onDoubleTap）。
  ///
  /// 🔴 焦点落定用 `onTapDown`（即时触发，不等 300ms 双击判定窗口），
  /// 保证选中反馈零延迟；手势被拖动/长按取消时 [onTapCancel] 会清掉
  /// 「跳过下一次 tap」标志，防止标志残留误吞下一次点击。
  final bool focusToActivate;

  /// v3.5: 焦点环线宽 (透传 [FocusGlow.ringWidth])
  final double ringWidth;

  /// v3.6-re: 非焦点态常驻投影开关 (透传 [FocusGlow.idleShadow])
  final bool idleShadow;

  /// v3.5: 焦点变化回调。
  ///
  /// shelf 卡片用它实现「焦点即选中」——键盘/手柄移动焦点即切换舞台游戏,
  /// 使「环在哪 = 舞台显示哪部」成为唯一语义。
  final ValueChanged<bool>? onFocusChange;

  /// v3.20: 鼠标/触屏点击时把焦点落到自身。
  ///
  /// 默认 false（旧行为：`GestureDetector` 点击不移动焦点）。详情页按钮等
  /// 「点完应停在原钮」的场景传 true —— 否则点击后焦点仍留在上一落点
  /// （如「游玩」），高亮被感知为「重置回默认项」。
  final bool requestFocusOnTap;

  const BpmInteractiveWrapper({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.focusScale = BigPictureTheme.cardFocusScale,
    this.hoverScale = BigPictureTheme.cardHoverScale,
    this.borderRadius,
    this.autofocus = false,
    this.focusNode,
    this.cursor = SystemMouseCursors.click,
    this.semanticsLabel,
    this.focusRing = true,
    this.onFocusChange,
    this.requestFocusOnTap = false,
    this.ringWidth = BigPictureTheme.cardFocusGlowWidth,
    this.idleShadow = true,
    this.enableKeyDoubleTap = true,
    this.keyboardDoubleTap = true,
    this.focusToActivate = false,
  });

  @override
  State<BpmInteractiveWrapper> createState() => _BpmInteractiveWrapperState();
}

class _BpmInteractiveWrapperState extends State<BpmInteractiveWrapper> {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  bool _isHovered = false;

  /// v3.22 [focusToActivate]：「这次 tap 已被消费为『落焦点选中』」标志。
  ///
  /// 在 [onTapDown]（即时，不等双击判定窗口）里置位，[_handleTap] 里消费清零；
  /// 手势被拖动/长按取消时由 [_handleTapCancel] 清零，防止残留误吞下一次 tap。
  bool _skipNextTap = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _isFocused) {
      setState(() => _isFocused = focused);
      widget.onFocusChange?.call(focused);
    }
  }

  /// 点击（鼠标/触屏）入口：先落焦点再触发回调。
  ///
  /// 手柄/键盘激活（Enter/Space/A）本就发生在持有焦点的节点上，无需处理；
  /// 只有指针点击需要这一步把「高亮」留在被点的按钮上。
  ///
  /// 🔴 `requestFocus` 不是同步生效（FocusManager 以微任务调度
  /// applyFocusChangesIfNeeded），这里必须强制落定 —— 否则同帧内读取
  /// `FocusManager.instance.primaryFocus` 的后续逻辑（如 shell 在「隐藏 UI」
  /// 时记录触发按钮）拿到的仍是**旧焦点**。
  void _handleTap() {
    if (widget.requestFocusOnTap) {
      _focusNode.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    // v3.22 [focusToActivate]: 这次点击已在 onTapDown 消费为「落焦点选中」，
    // 不再触发 onTap —— 该次交互到此为止。
    if (_skipNextTap) {
      _skipNextTap = false;
      return;
    }
    widget.onTap?.call();
  }

  /// v3.22 [focusToActivate]: 指针按下即判定 —— 组件**无焦点**时先把焦点
  /// 落给它（选中反馈零延迟），并标记跳过随后的 tap 回调。
  ///
  /// 🔴 `requestFocus` 不是同步生效（FocusManager 以微任务调度），这里必须
  /// `applyFocusChangesIfNeeded` 强制落定，让 [onFocusChange] 在本次交互内
  /// 触发（选中态立即可见）。
  void _handleTapDown(TapDownDetails details) {
    if (!widget.focusToActivate) return;
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
      _skipNextTap = true;
    }
  }

  /// v3.22 [focusToActivate]: 手势被拖动/长按竞争取消时清掉标志，
  /// 防止残留标志误吞下一次（已聚焦组件的）点击。
  void _handleTapCancel() {
    _skipNextTap = false;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final effectiveCursor = disabled ? SystemMouseCursors.basic : widget.cursor;

    // 缩放优先级: focused > hovered > 1.0
    // v3.10: 板块选择模式下不放大组件 —— 放大是「组件操作模式」的语言,
    // 否则会出现「板块整体高亮 + 单个组件同时抬起」的双焦点观感。
    // 无 scope 时 maybeZoneMode 为 null, 行为与改动前逐字一致。
    final zoneMode = BpmZoneFocusScope.maybeZoneMode(context) == true;
    final scale = disabled
        ? 1.0
        : (_isFocused && !zoneMode
            ? widget.focusScale
            : (_isHovered ? widget.hoverScale : 1.0));

    return MouseRegion(
      cursor: effectiveCursor,
      onEnter: disabled ? null : (_) => setState(() => _isHovered = true),
      onExit: disabled ? null : (_) => setState(() => _isHovered = false),
      child: FocusGlow(
        autofocus: widget.autofocus,
        focusNode: _focusNode,
        borderRadius: widget.borderRadius,
        semanticsLabel: widget.semanticsLabel,
        showRing: widget.focusRing,
        ringWidth: widget.ringWidth,
        idleShadow: widget.idleShadow,
        onSelect: disabled ? null : widget.onTap,
        // v3.22: onDoubleTap 传入条件放宽 —— enableKeyDoubleTap（手柄合成
        // Enter 参与连按）与 keyboardDoubleTap（真实键盘参与连按）任一开启
        // 即传入，由 FocusGlow 内部按事件来源分别裁决。
        onDoubleTap:
            (disabled || (!widget.enableKeyDoubleTap && !widget.keyboardDoubleTap))
                ? null
                : widget.onDoubleTap,
        // 手柄合成 Enter 是否参与连按判定 = 既有 enableKeyDoubleTap 开关。
        synthesizedDoubleTap: widget.enableKeyDoubleTap,
        child: AnimatedScale(
          scale: scale,
          duration: BigPictureTheme.focusAnimDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
        child: GestureDetector(
          onTap: widget.onTap == null ? null : _handleTap,
          onTapDown: widget.focusToActivate ? _handleTapDown : null,
          onTapCancel: widget.focusToActivate ? _handleTapCancel : null,
          onDoubleTap: widget.onDoubleTap,
          onLongPress: widget.onLongPress,
          child: widget.child,
        ),
        ),
      ),
    );
  }
}
