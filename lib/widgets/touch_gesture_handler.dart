import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';

/// 触摸手势处理器（无 UI 的纯状态机，可复用）。
///
/// 在**不改变任何既有鼠标交互**的前提下，为控件叠加触摸专属手势：
///
/// | 触摸操作        | 回调                                        | 典型用途       |
/// |---------------|---------------------------------------------|--------------|
/// | 单指单击       | [onTouchTap]                                 | 弹出详情窗口   |
/// | 单指双击       | [onTouchDoubleTap]                           | 启动游戏      |
/// | 双指点击       | [onTwoFingerTap]（参数为双指中心全局坐标）        | 弹出右键菜单   |
///
/// 鼠标事件一律原样放行（由既有的 GestureDetector / MouseRegion 处理），
/// 老用户的鼠标单击/双击/右键、以及既有的触摸长按拖拽均不受影响。
///
/// 用法：在已有 `Listener` 的回调中转发指针事件，
/// `handlePointerDown` 的返回值表示该事件是否应继续传递给既有处理逻辑
/// （第二根及之后的手指落下时不转发，避免误触长按拖拽计时器）。
///
/// ```dart
/// Listener(
///   onPointerDown: (e) {
///     if (_touch.handlePointerDown(e)) widget.onPointerDown?.call(e);
///   },
///   onPointerMove: _touch.handlePointerMove,
///   onPointerUp: (e) {
///     _touch.handlePointerUp(e);
///     widget.onPointerUp?.call();
///   },
///   onPointerCancel: _touch.handlePointerCancel,
///   child: ...,
/// )
/// ```
///
/// 同时，为了让触摸路径不与既有 GestureDetector 的 tap/doubleTap 回调
/// 重复触发，应在那些回调中先检查 [lastDownWasTouch]：
///
/// ```dart
/// GestureDetector(
///   onTap: () {
///     if (_touch.lastDownWasTouch) return; // 触摸走 TouchGestureHandler
///     widget.onTap?.call();
///   },
///   ...
/// )
/// ```
class TouchGestureHandler {
  TouchGestureHandler({
    this.onTouchTap,
    this.onTouchDoubleTap,
    this.onTwoFingerTap,
    this.onSecondTouchDown,
  });

  /// 单指单击（仅触摸；鼠标单击不受影响）。
  final VoidCallback? onTouchTap;

  /// 单指双击（仅触摸）。
  /// 注册后单击会延迟一个双击窗口（约 300ms）再触发，用于区分双击。
  final VoidCallback? onTouchDoubleTap;

  /// 双指点击（仅触摸），参数为双指中心的**全局坐标**，
  /// 适合直接作为右键菜单的弹出位置。
  final void Function(Offset globalPosition)? onTwoFingerTap;

  /// 第二根手指落下时回调（典型用途：取消长按拖拽计时器）。
  final VoidCallback? onSecondTouchDown;

  /// 与库页长按拖拽延时（300ms）对齐：
  /// 按下超过此时长即视为长按/拖拽语义，不再判定为"轻点"。
  static const Duration _tapMaxDuration = Duration(milliseconds: 280);

  /// 双击窗口，与 Flutter [kDoubleTapTimeout] 一致。
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);

  /// 双击两次落点允许的最大间距。
  static const double _doubleTapSlop = 60.0;

  /// 判定为"点击"的单指最大位移（略放宽于系统 kTouchSlop，容噪）。
  static const double _tapSlop = 24.0;

  /// 双指点击允许的最大持续时长。
  static const Duration _twoFingerMaxDuration = Duration(milliseconds: 400);

  /// 最近一次 pointer down 是否来自触摸屏。
  /// 供既有 GestureDetector 回调做触摸门控，避免鼠标/触摸重复触发。
  bool get lastDownWasTouch => _lastDownWasTouch;
  bool _lastDownWasTouch = false;

  final Map<int, _TouchTracker> _touches = {};

  /// 双指点击候选状态：两指同落、位移小、快速全抬起才成立。
  bool _twoFingerCandidate = false;
  DateTime _twoFingerStartTime = DateTime.now();
  Offset _twoFingerFirstUpPos = Offset.zero;
  bool _twoFingerFirstUpCollected = false;

  /// 本次触摸序列中出现过并发多指（≥2 指同落）。
  /// 多指序列要么判定为双指点击，要么不产生任何轻点回调，
  /// 避免双指按压中单指微移超限后误触发单击。
  bool _sawMultiTouch = false;

  /// 上一次单指轻点的抬起时间/位置（本实例内做双击判定）。
  DateTime? _lastTapUpAt;
  Offset _lastTapUpPos = Offset.zero;

  /// 跨实例共享的单击延迟计时器：
  /// 快速连点不同卡片时，只有最后一次轻点会触发单击回调，
  /// 避免叠开多个详情窗口。
  static Timer? _sharedTapTimer;

  /// 是否触摸指针。
  static bool isTouchPointer(PointerEvent event) =>
      event.kind == PointerDeviceKind.touch;

  /// 处理指针按下。
  ///
  /// 返回 true 表示应继续传递给既有逻辑（长按拖拽计时器等）；
  /// 第二根及之后的手指落下时返回 false 并触发 [onSecondTouchDown]。
  bool handlePointerDown(PointerEvent event) {
    _lastDownWasTouch = isTouchPointer(event);
    if (!_lastDownWasTouch) {
      // 鼠标介入：复位触摸追踪，避免残留状态污染后续判定
      _touches.clear();
      _twoFingerCandidate = false;
      return true;
    }

    if (_touches.containsKey(event.pointer)) return true;

    final now = DateTime.now();
    _touches[event.pointer] = _TouchTracker(
      downTime: now,
      lastPos: event.position,
    );

    if (_touches.length == 2) {
      _twoFingerCandidate = true;
      _sawMultiTouch = true;
      _twoFingerStartTime = now;
      _twoFingerFirstUpCollected = false;
      // 双指落下即取消挂起的单击回调（单击→双指菜单的快速衔接场景）
      _sharedTapTimer?.cancel();
      _sharedTapTimer = null;
      _lastTapUpAt = null;
      onSecondTouchDown?.call();
      return false;
    }
    if (_touches.length > 2) {
      // 三指及以上（如手掌误触）不判定为双指点击
      _twoFingerCandidate = false;
      return false;
    }
    return true;
  }

  /// 处理指针移动：累计位移，超限则作废双指点击候选。
  void handlePointerMove(PointerEvent event) {
    final tracker = _touches[event.pointer];
    if (tracker == null) return;
    tracker.totalMove += (event.position - tracker.lastPos).distance;
    tracker.lastPos = event.position;
    if (_twoFingerCandidate && tracker.totalMove > _tapSlop) {
      _twoFingerCandidate = false;
    }
  }

  /// 处理指针抬起。始终返回 true（既有逻辑需自行处理拖拽收尾）。
  bool handlePointerUp(PointerEvent event) {
    if (!isTouchPointer(event)) return true;
    final tracker = _touches.remove(event.pointer);
    if (tracker == null) return true;

    // 收集双指中第一根手指的抬起位置，稍后与第二根取中点
    if (_twoFingerCandidate && !_twoFingerFirstUpCollected) {
      _twoFingerFirstUpPos = event.position;
      _twoFingerFirstUpCollected = true;
    }

    if (_touches.isEmpty) {
      _finishTouchSequence(tracker, event.position);
    }
    return true;
  }

  /// 处理指针取消（系统打断，如手掌误触）。
  void handlePointerCancel(PointerEvent event) {
    _touches.remove(event.pointer);
    if (_touches.isEmpty) {
      _twoFingerCandidate = false;
      _sawMultiTouch = false;
      _lastTapUpAt = null;
    }
  }

  /// 所有触摸手指已抬起，判定最终手势。
  void _finishTouchSequence(_TouchTracker lastFinger, Offset upPos) {
    final wasCandidate = _twoFingerCandidate;
    final sawMultiTouch = _sawMultiTouch;
    _twoFingerCandidate = false;
    _sawMultiTouch = false;

    final now = DateTime.now();

    // ---- 双指点击 ----
    if (wasCandidate) {
      final duration = now.difference(_twoFingerStartTime);
      final center = Offset(
        (_twoFingerFirstUpPos.dx + upPos.dx) / 2,
        (_twoFingerFirstUpPos.dy + upPos.dy) / 2,
      );
      if (duration <= _twoFingerMaxDuration) {
        _lastTapUpAt = null;
        onTwoFingerTap?.call(center);
        return;
      }
      // 超时的双指按压视为长按手势，不回落到单击判定
      _lastTapUpAt = null;
      return;
    }

    // ---- 多指但未成双指点击（位移超限等）：不产生轻点回调 ----
    if (sawMultiTouch) {
      _lastTapUpAt = null;
      return;
    }

    // ---- 单指：先验证这是一次有效"轻点" ----
    final isQuickTap =
        now.difference(lastFinger.downTime) < _tapMaxDuration &&
            lastFinger.totalMove <= _tapSlop;
    if (!isQuickTap) {
      // 长按/拖拽/慢按：重置双击追踪，不触发任何轻点回调
      _lastTapUpAt = null;
      return;
    }

    // ---- 双击判定（同一实例 = 同一张卡片内）----
    final lastUp = _lastTapUpAt;
    if (onTouchDoubleTap != null &&
        lastUp != null &&
        now.difference(lastUp) <= _doubleTapWindow &&
        (upPos - _lastTapUpPos).distance <= _doubleTapSlop) {
      _lastTapUpAt = null;
      _sharedTapTimer?.cancel();
      _sharedTapTimer = null;
      onTouchDoubleTap!();
      return;
    }

    _lastTapUpAt = now;
    _lastTapUpPos = upPos;

    // ---- 单击 ----
    if (onTouchTap == null) return;
    if (onTouchDoubleTap == null) {
      // 无双击语义（如编辑模式）→ 立即响应，零延迟
      onTouchTap!();
      return;
    }
    // 有双击语义 → 延迟一个双击窗口再触发单击，
    // 期间若发生双击/双指/其他卡片轻点则被取消
    _sharedTapTimer?.cancel();
    _sharedTapTimer = Timer(_doubleTapWindow, () {
      _sharedTapTimer = null;
      onTouchTap!();
    });
  }

  /// 宿主销毁时清理（取消挂起的单击计时器）。
  void dispose() {
    _touches.clear();
    _twoFingerCandidate = false;
    if (_sharedTapTimer != null) {
      _sharedTapTimer?.cancel();
      _sharedTapTimer = null;
    }
  }
}

/// 单根触摸手指的追踪数据。
class _TouchTracker {
  _TouchTracker({required this.downTime, required this.lastPos});

  final DateTime downTime;

  /// 最近一次位置（全局坐标）。
  Offset lastPos;

  /// 累计位移（用于区分点击与拖动）。
  double totalMove = 0;
}
