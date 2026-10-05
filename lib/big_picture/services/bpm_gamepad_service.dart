import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show calloc;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TraversalDirection;

/// BPM 手柄输入服务 (v3.9) — 多后端轮询 → 语义事件
///
/// 面向移动端/手柄玩家的大屏操作适配 (10-foot UI)。
/// 按键语义采用**主流手柄通行映射**(括号内为 PS / Switch 对应键):
/// - **A (× / B)** → [BpmGamepadCallbacks.onConfirm] (进入区域内部操作 / 激活控件)
/// - **B (○ / A)** → [BpmGamepadCallbacks.onBack] (退回浏览态 / 关面板)
/// - **X (□ / Y)** → [BpmGamepadCallbacks.onContextMenu] (当前项动作菜单)
/// - **Y (△ / X)** → [BpmGamepadCallbacks.onMark] (切换标记/收藏)
/// - **Start (Options / +)** → [BpmGamepadCallbacks.onSystemMenu] (BPM 系统菜单)
/// - **Back (Create / −)** → [BpmGamepadCallbacks.onViewToggle] (视图切换)
/// - **LB/RB (L1/R1)** → [BpmGamepadCallbacks.onPageShift] (页面切换: 主页⇄库)
/// - **LT/RT (L2/R2)** → [BpmGamepadCallbacks.onTriggerShift] (快速翻屏, ±1)
/// - **十字键/左摇杆** → [BpmGamepadCallbacks.onDirection] (焦点移动,
///   带初始 380ms / 重复 130ms 的摇杆节奏)
/// - **右摇杆** → [BpmGamepadCallbacks.onScroll] (内容滚动轴流,幅度线性)
///
/// 设计约束:
/// - 零新增依赖: 后端均经 dart:ffi 直调系统 DLL,与项目 FFI 先例
///   (窗口铺屏/电池) 同套路;
/// - **多后端仲裁**: [backends] 按序尝试,取首个返回帧的后端为活跃后端;
///   活跃后端切换(含热插拔)时**重建基线**,不误触发按钮边缘事件;
/// - **XInput 多槽位**: 不再写死槽 0,自动扫描 4 个槽位并粘住首个可用槽,
///   该槽断开后自动重扫(第二只手柄/槽位漂移不再失效);
/// - 手柄未连接: 连续 [disconnectTicks] 帧读取失败即休眠为「未连接」态,
///   恢复连接时先以首帧建立基线 (不触发事件),避免重连瞬间连发;
/// - **原始输入流**: 除 BPM 语义事件外, 还可注册 [BpmGamepadRawListener]
///   消费未经语义处理的按键边缘 / 原始帧快照, 供注入层等非 BPM 消费者使用;
/// - 可测试: 输入源抽象为 [BpmGamepadBackend],测试注入假帧序列;
///   时间基准用轮询 tick 计数 (不依赖真实时钟),测试缩短
///   [repeatInitialDelay]/[repeatInterval] 即可加速重复节奏。
class BpmGamepadService {
  /// 轮询间隔 (XInput 标准 60fps 采样)
  final Duration pollInterval;

  /// 摇杆/十字键按住后,从首次触发到开始重复的延迟
  final Duration repeatInitialDelay;

  /// 摇杆/十字键重复触发间隔
  final Duration repeatInterval;

  /// 连续多少帧读取失败判定断连
  final int disconnectTicks;

  /// 语义回调 (shell 注入)
  final BpmGamepadCallbacks callbacks;

  /// 扳机 (LT/RT) 越过该模拟量阈值即视为一次「按下」边缘
  static const int triggerThreshold = 128;

  /// 后端列表 (按优先级排序; 空 = 本机无手柄能力, 静默空转)
  final List<BpmGamepadBackend> _backends;

  /// 当前活跃后端下标 (-1 = 尚未确定)
  int _activeBackend = -1;

  /// 当前活跃数据源标识 (换设备/换槽位时变化 → 触发基线重建)
  String? _activeSourceKey;

  /// 原始输入监听者 (注入层等非 BPM 消费者; 与语义回调互不影响)
  final List<BpmGamepadRawListener> _rawListeners = <BpmGamepadRawListener>[];

  /// 是否检测到可用后端 (无手柄/无 DLL 的环境为 false)
  bool get isBackendAvailable => _backends.isNotEmpty;

  /// 当前活跃后端名 (诊断/UI 提示用; 未连接时为 null)
  String? get activeBackendName =>
      (_activeBackend >= 0 && _activeBackend < _backends.length)
          ? _backends[_activeBackend].name
          : null;

  /// 手柄当前是否连接 (供 UI 显示提示,可选消费)
  bool get isConnected => _connected;

  Timer? _timer;
  bool _connected = false;
  int _failedPolls = 0;

  /// 🔴 互斥闸门（返回 true = 本帧跳过语义分发）。
  ///
  /// 游戏会话期间 BPM 必须对语义事件让路：玩家按 A 推进对话会被 BPM 当成
  /// 「确认」，连按两次 A 会触发启动手势重复拉起启动流程。
  /// 由 `big_picture_shell.dart` 绑定为
  /// `GamepadAdaptationCoordinator.instance.hasActiveSession`。
  /// 闸门只停语义分发，基线状态照常更新（闸门打开时不残留旧边缘）。
  bool Function()? dispatchGate;

  // ── 状态机 (edge 检测与重复节奏用) ──
  int _prevButtons = 0;
  int _prevPacket = 0;
  int _prevLeftTrigger = 0;
  int _prevRightTrigger = 0;
  final Map<TraversalDirection, int> _heldSinceTick = {};
  final Map<TraversalDirection, int> _lastFireTick = {};
  int _tick = 0;

  int get _initialTicks =>
      (repeatInitialDelay.inMilliseconds / pollInterval.inMilliseconds)
          .round()
          .clamp(1, 1 << 30);
  int get _repeatTicks =>
      (repeatInterval.inMilliseconds / pollInterval.inMilliseconds)
          .round()
          .clamp(1, 1 << 30);

  BpmGamepadService({
    BpmGamepadBackend? backend,
    List<BpmGamepadBackend>? backends,
    this.pollInterval = const Duration(milliseconds: 16),
    this.repeatInitialDelay = const Duration(milliseconds: 380),
    this.repeatInterval = const Duration(milliseconds: 130),
    this.disconnectTicks = 4,
    required this.callbacks,
  }) : _backends = List<BpmGamepadBackend>.of(
          backends ?? <BpmGamepadBackend>[if (backend != null) backend],
        );

  /// 启动轮询。后端不可用时为 no-op (桌面无手柄场景零开销)。
  void start() {
    if (_timer != null || _backends.isEmpty) return;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void dispose() {
    // 先通知原始流消费方释放「按住」态, 避免服务销毁时映射的按键卡死在按下态
    _fireRawReset();
    _timer?.cancel();
    _timer = null;
    _heldSinceTick.clear();
    _lastFireTick.clear();
    // 释放各后端持有的 native 资源 (calloc 缓冲 / COM 对象)
    for (final backend in _backends) {
      backend.dispose();
    }
  }

  // ====== 原始输入流 (注入层消费, 不经过 BPM 语义) ======

  /// 注册原始输入监听者
  void addRawListener(BpmGamepadRawListener listener) =>
      _rawListeners.add(listener);

  /// 移除原始输入监听者
  void removeRawListener(BpmGamepadRawListener listener) =>
      _rawListeners.remove(listener);

  /// 广播原始按键边缘事件
  void _fireRawButton(GamepadRawButton button, bool down) {
    for (final listener in _rawListeners) {
      listener.onButton?.call(button, down);
    }
  }

  /// 广播原始帧 (含摇杆/扳机模拟量)
  void _fireRawFrame(GamepadFrame frame) {
    for (final listener in _rawListeners) {
      listener.onFrame?.call(frame);
    }
  }

  /// 通知消费方「重置」: 断连 / 换设备(重建基线) / 服务销毁。
  /// 消费方应释放一切「按住」状态, 否则手柄断开时映射的按键会卡死在按下态。
  void _fireRawReset() {
    for (final listener in _rawListeners) {
      listener.onReset?.call();
    }
  }

  // ============ 轮询与状态机 ============

  /// 依次尝试各后端, 取首个返回帧者为活跃后端。
  ///
  /// 活跃后端变化时(首次接入 / 手柄热插拔 / 前一后端掉线)交由 [_consume]
  /// 走「重建基线」分支 —— 不同设备的 packet 序列不可比,若不重置会把
  /// 「换设备的首帧」误判成按钮边缘事件(表现为接入瞬间乱触发)。
  void _poll() {
    for (var i = 0; i < _backends.length; i++) {
      final backend = _backends[i];
      final frame = backend.poll();
      if (frame == null) continue;
      final key = '${backend.name}#${backend.sourceKey}';
      final switched = _activeSourceKey != key;
      _activeBackend = i;
      _activeSourceKey = key;
      _consume(frame, reestablishBaseline: switched);
      return;
    }
    _activeSourceKey = null;
    _consume(null);
  }

  /// 处理一帧。
  ///
  /// [reestablishBaseline] 为 true 时仅把该帧记录为新基线, 不触发语义事件
  /// (与「重连首帧」同语义)。
  void _consume(GamepadFrame? frame, {bool reestablishBaseline = false}) {
    _tick++;
    if (frame == null) {
      _failedPolls++;
      if (_connected && _failedPolls >= disconnectTicks) {
        _connected = false;
        _resetBaseline();
        _fireRawReset(); // 手柄断开: 消费方释放按住态
        callbacks.onConnectionChanged?.call(false);
      }
      return;
    }
    _failedPolls = 0;
    if (!_connected || reestablishBaseline) {
      final wasConnected = _connected;
      _connected = true;
      _resetBaselineTo(frame);
      if (wasConnected) {
        // 已连接状态下重建基线 = 换设备/换数据源: 消费方释放按住态。
        // 🔴 首次连接不广播 —— 此时不存在任何按住态, 广播只会制造噪音。
        _fireRawReset();
      } else {
        callbacks.onConnectionChanged?.call(true);
      }
      return; // 基线帧只建立基线,不触发事件
    }
    // 🔴 互斥闸门：游戏会话期间 BPM 对**语义事件**让路。
    // 基线状态照常推进 —— 闸门打开时不残留旧的按键边缘。
    // 🔴 2026-09-27 语义收紧：raw 流（按键边缘 + 帧快照）**不再被闸门吞掉**
    // —— 适配会话已改为「附加到本服务」的单实例模式（不再自建第二套后端
    // 抢 SDL 事件/仲裁），游戏前台时 raw 事件必须照常广播给会话分发器，
    // 否则游戏内收不到任何手柄输入。闸门只静音 onConfirm/onBack 等语义回调
    // 与方向/滚动节奏。
    final gateClosed = dispatchGate?.call() ?? false;
    final buttonsChanged = frame.packetNumber != _prevPacket;
    _prevPacket = frame.packetNumber;
    if (buttonsChanged) {
      _fireButtonEdges(frame, suppressSemantic: gateClosed);
      _prevButtons = frame.buttons;
      _prevLeftTrigger = frame.leftTrigger;
      _prevRightTrigger = frame.rightTrigger;
    }
    _fireRawFrame(frame);
    if (gateClosed) return;
    _handleDirections(frame);
    _handleRightStickScroll(frame);
  }

  /// 清空全部基线状态 (断连时调用)
  void _resetBaseline() {
    _prevButtons = 0;
    _prevPacket = 0;
    _prevLeftTrigger = 0;
    _prevRightTrigger = 0;
    _heldSinceTick.clear();
    _lastFireTick.clear();
  }

  /// 以某一帧建立基线
  void _resetBaselineTo(GamepadFrame frame) {
    _prevButtons = frame.buttons;
    _prevPacket = frame.packetNumber;
    _prevLeftTrigger = frame.leftTrigger;
    _prevRightTrigger = frame.rightTrigger;
    _heldSinceTick.clear();
    _lastFireTick.clear();
  }

  /// 按键上升/下降沿 → 语义回调 + 原始流广播
  ///
  /// [suppressSemantic] = 闸门关闭（游戏会话前台）：原始流**照常广播**
  /// （适配会话消费，含 🔴 扳机阈值边缘 —— LT/RT 是扳机模拟量，其 raw
  /// 边缘判定在语义回调之后，必须放在 suppress 之前，否则游戏内 LT/RT
  /// 失灵），语义回调静音。
  void _fireButtonEdges(GamepadFrame frame, {bool suppressSemantic = false}) {
    final pressed = frame.buttons & ~_prevButtons;
    final released = _prevButtons & ~frame.buttons;
    for (final b in GamepadRawButton.values) {
      if (b.mask == 0) continue; // 扳机是模拟量, 单独按阈值判定
      if (pressed & b.mask != 0) _fireRawButton(b, true);
      if (released & b.mask != 0) _fireRawButton(b, false);
    }
    // 🔴 扳机 raw 边缘（阈值判定）—— 必须在 suppressSemantic 之前：
    // 适配会话的 LT(按住快进)/RT(左键) 映射依赖这里的边缘事件。
    final ltDown = frame.leftTrigger >= triggerThreshold;
    final rtDown = frame.rightTrigger >= triggerThreshold;
    if (ltDown && _prevLeftTrigger < triggerThreshold) {
      _fireRawButton(GamepadRawButton.leftTrigger, true);
    } else if (!ltDown && _prevLeftTrigger >= triggerThreshold) {
      _fireRawButton(GamepadRawButton.leftTrigger, false);
    }
    if (rtDown && _prevRightTrigger < triggerThreshold) {
      _fireRawButton(GamepadRawButton.rightTrigger, true);
    } else if (!rtDown && _prevRightTrigger >= triggerThreshold) {
      _fireRawButton(GamepadRawButton.rightTrigger, false);
    }
    if (suppressSemantic) return;
    if (pressed & XInputButtons.a != 0) callbacks.onConfirm?.call();
    if (pressed & XInputButtons.b != 0) callbacks.onBack?.call();
    if (pressed & XInputButtons.x != 0) callbacks.onContextMenu?.call();
    if (pressed & XInputButtons.y != 0) callbacks.onMark?.call();
    if (pressed & XInputButtons.start != 0) callbacks.onSystemMenu?.call();
    if (pressed & XInputButtons.back != 0) callbacks.onViewToggle?.call();
    if (pressed & XInputButtons.rightShoulder != 0) {
      callbacks.onPageShift?.call(1);
    }
    if (pressed & XInputButtons.leftShoulder != 0) {
      callbacks.onPageShift?.call(-1);
    }
    // 扳机语义（翻屏）：阈值判定已在前半段完成（raw 边缘已广播）
    if (ltDown && _prevLeftTrigger < triggerThreshold) {
      callbacks.onTriggerShift?.call(-1);
    }
    if (rtDown && _prevRightTrigger < triggerThreshold) {
      callbacks.onTriggerShift?.call(1);
    }
  }

  /// 十字键/左摇杆 → 方向事件 (首按 + 按住重复)
  void _handleDirections(GamepadFrame frame) {
    final dirs = <TraversalDirection>{
      ...XInputButtons.dpadDirections(frame.buttons),
      ..._thumbDirections(frame.thumbLX, frame.thumbLY),
    };
    // 消失的方向清账
    _heldSinceTick.removeWhere((dir, _) => !dirs.contains(dir));
    _lastFireTick.removeWhere((dir, _) => !dirs.contains(dir));

    // 每 tick 最多 fire 一个方向: 斜推时不连跳两格
    for (final dir in const [
      TraversalDirection.up,
      TraversalDirection.down,
      TraversalDirection.left,
      TraversalDirection.right,
    ]) {
      if (!dirs.contains(dir)) continue;
      final since = _heldSinceTick[dir];
      if (since == null) {
        // 首按
        _heldSinceTick[dir] = _tick;
        _lastFireTick[dir] = _tick;
        callbacks.onDirection?.call(dir);
        return;
      }
      if (_tick - since >= _initialTicks &&
          _tick - _lastFireTick[dir]! >= _repeatTicks) {
        _lastFireTick[dir] = _tick;
        callbacks.onDirection?.call(dir);
        return;
      }
    }
  }

  /// 左摇杆 → 方向集合 (圆形死区,取主轴,避免斜推连发)
  ///
  /// 🔴 **轴向极性约定: 正值 = 上 / 右**（XInput 规范: `sThumbX` / `sThumbY`
  /// 的**正值分别为右、上**）。这个约定是 [GamepadFrame] 的公共语义,
  /// 与 [_handleRightStickScroll] 完全一致 ("摇杆上推 ry>0")。
  ///
  /// v3.10.2 修: 旧实现写成 `ly < 0 ? up : down`, 与同文件右摇杆的约定相反 ——
  /// 真机表现为「向上拉动摇杆 → 界面里却向下走」。任何后端(XInput / DirectInput)
  /// 都必须先把原始轴归一到本约定再填进 [GamepadFrame]。
  static Iterable<TraversalDirection> _thumbDirections(int lx, int ly) sync* {
    const deadzone = 7849; // XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE
    final mag2 = lx * lx + ly * ly;
    if (mag2 < deadzone * deadzone) return;
    if (ly.abs() >= lx.abs()) {
      yield ly > 0 ? TraversalDirection.up : TraversalDirection.down;
    } else {
      yield lx > 0 ? TraversalDirection.right : TraversalDirection.left;
    }
  }

  /// 右摇杆 → 滚动轴流 (幅度线性,每 tick 一次)
  void _handleRightStickScroll(GamepadFrame frame) {
    const deadzone = 8689; // XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE
    double norm(int v) {
      final m = v.abs();
      if (m <= deadzone) return 0;
      return (m - deadzone) / (32767 - deadzone) * (v < 0 ? -1.0 : 1.0);
    }

    final ny = norm(frame.thumbRY);
    final nx = norm(frame.thumbRX);
    if (ny == 0 && nx == 0) return;
    // 摇杆上推 (ry>0) = 视线上移 = 滚动位置减小 (Flutter 坐标系 dy<0)
    final dtMs = pollInterval.inMilliseconds;
    final dy = -ny * scrollSpeedPerSecond * dtMs / 1000;
    final dx = nx * scrollSpeedPerSecond * dtMs / 1000;
    callbacks.onScroll?.call(dx, dy);
  }

  /// 右摇杆满幅时每秒滚动像素
  static const double scrollSpeedPerSecond = 1400;

  /// 测试钩子: 直接喂一帧 (绕过 Timer,供单测驱动状态机)
  @visibleForTesting
  void consumeFrameForTest(GamepadFrame? frame) => _consume(frame);

  /// 测试钩子: 按当前后端列表轮询一次 (多后端仲裁测试用)
  @visibleForTesting
  void pollOnceForTest() => _poll();

  /// 测试钩子: 替换为单后端并轮询一次
  @visibleForTesting
  void pollWithBackendForTest(BpmGamepadBackend backend) {
    _backends
      ..clear()
      ..add(backend);
    _activeBackend = -1;
    _activeSourceKey = null;
    _poll();
  }
}

/// 手柄语义回调集合 (shell 注入实现)
class BpmGamepadCallbacks {
  /// A 键: 进入区域内部操作 / 激活当前控件
  final VoidCallback? onConfirm;

  /// B 键: 退回浏览态 / 关闭面板
  final VoidCallback? onBack;

  /// X 键: 弹出当前焦点项的动作菜单 (等价卡片长按)
  final VoidCallback? onContextMenu;

  /// Y 键: 切换当前焦点项的标记/收藏
  final VoidCallback? onMark;

  /// Start: 打开 BPM 系统菜单 (退出大屏/关闭软件/最小化)
  final VoidCallback? onSystemMenu;

  /// Back(Select): 切换视图 (主页 ⇄ 我的库)
  final VoidCallback? onViewToggle;

  /// LB/RB: 页面切换 (-1 = 上一个, +1 = 下一个)
  final ValueChanged<int>? onPageShift;

  /// LT/RT: 快速翻屏 (-1 = 上/左, +1 = 下/右)
  final ValueChanged<int>? onTriggerShift;

  /// 十字键/左摇杆: 焦点方向移动
  final ValueChanged<TraversalDirection>? onDirection;

  /// 右摇杆: 内容滚动 (dx/dy 为本帧位移增量)
  final void Function(double dx, double dy)? onScroll;

  /// 连接状态变化 (可选,UI 提示用)
  final ValueChanged<bool>? onConnectionChanged;

  const BpmGamepadCallbacks({
    this.onConfirm,
    this.onBack,
    this.onContextMenu,
    this.onMark,
    this.onSystemMenu,
    this.onViewToggle,
    this.onPageShift,
    this.onTriggerShift,
    this.onDirection,
    this.onScroll,
    this.onConnectionChanged,
  });
}

/// 原始按键标识 (注入层/映射层消费; 与 BPM 语义解耦)
///
/// [mask] 为 XInput 位掩码; 扳机是模拟量, mask 为 0, 由
/// [BpmGamepadService.triggerThreshold] 判定按下/抬起。
enum GamepadRawButton {
  dpadUp(XInputButtons.dpadUp),
  dpadDown(XInputButtons.dpadDown),
  dpadLeft(XInputButtons.dpadLeft),
  dpadRight(XInputButtons.dpadRight),
  start(XInputButtons.start),
  back(XInputButtons.back),
  leftShoulder(XInputButtons.leftShoulder),
  rightShoulder(XInputButtons.rightShoulder),
  a(XInputButtons.a),
  b(XInputButtons.b),
  x(XInputButtons.x),
  y(XInputButtons.y),
  leftStick(XInputButtons.leftStick),
  rightStick(XInputButtons.rightStick),
  leftTrigger(0),
  rightTrigger(0);

  const GamepadRawButton(this.mask);

  /// XInput 位掩码 (扳机为 0 = 模拟量, 不走位掩码)
  final int mask;
}

/// 原始手柄事件监听 (不经过 BPM 语义, 供注入层等非 BPM 消费者使用)
///
/// 与 [BpmGamepadCallbacks] 的关系: 语义回调面向 BPM shell (带重复节奏/死区/
/// 轴向约定), 原始流面向「把手柄翻译成别的输入」的场景 —— 两者互不影响, 可同时消费。
class BpmGamepadRawListener {
  /// 按键边缘事件 (true = 按下, false = 抬起)
  final void Function(GamepadRawButton button, bool down)? onButton;

  /// 每帧原始快照 (含摇杆/扳机模拟量; 基线帧不广播)
  final void Function(GamepadFrame frame)? onFrame;

  /// 重置通知: 断连 / 换设备(重建基线) / 服务销毁时调用。
  /// 消费方**必须**释放一切「按住」状态, 否则映射的按键会卡死在按下态。
  final VoidCallback? onReset;

  const BpmGamepadRawListener({this.onButton, this.onFrame, this.onReset});
}

/// 一帧手柄输入快照 (后端无关,测试可直接构造)
class GamepadFrame {
  final int packetNumber;
  final int buttons;
  final int thumbLX;
  final int thumbLY;
  final int thumbRX;
  final int thumbRY;
  final int leftTrigger;
  final int rightTrigger;

  const GamepadFrame({
    required this.packetNumber,
    required this.buttons,
    this.thumbLX = 0,
    this.thumbLY = 0,
    this.thumbRX = 0,
    this.thumbRY = 0,
    this.leftTrigger = 0,
    this.rightTrigger = 0,
  });
}

/// XInput 按钮位掩码 (XInput.h)
abstract final class XInputButtons {
  static const int dpadUp = 0x0001;
  static const int dpadDown = 0x0002;
  static const int dpadLeft = 0x0004;
  static const int dpadRight = 0x0008;
  static const int start = 0x0010;
  static const int back = 0x0020;
  static const int leftStick = 0x0040; // ★ 手柄适配: 摇杆按下 LSB
  static const int rightStick = 0x0080; // ★ 手柄适配: 摇杆按下 RSB
  static const int leftShoulder = 0x0100;
  static const int rightShoulder = 0x0200;
  static const int a = 0x1000;
  static const int b = 0x2000;
  static const int x = 0x4000;
  static const int y = 0x8000;

  /// 十字键位掩码 → 方向集合
  static Iterable<TraversalDirection> dpadDirections(int buttons) sync* {
    if (buttons & dpadUp != 0) yield TraversalDirection.up;
    if (buttons & dpadDown != 0) yield TraversalDirection.down;
    if (buttons & dpadLeft != 0) yield TraversalDirection.left;
    if (buttons & dpadRight != 0) yield TraversalDirection.right;
  }
}

/// 输入源抽象 (生产 = XInput / DirectInput FFI,测试 = 假帧队列)
abstract class BpmGamepadBackend {
  /// 后端名称 (诊断日志与 UI 提示用,如 `XInput` / `DirectInput`)
  String get name;

  /// 当前数据源的稳定标识。
  ///
  /// 同一后端内部切换设备时(如 XInput 换槽位、DInput 换设备)该值必须变化,
  /// [BpmGamepadService] 依赖它判断「是否换了一台设备」并重建基线 ——
  /// 否则新设备的 packet 序列会被拿去和旧设备比较,造成乱触发。
  /// 默认等同 [name] (单设备后端无需覆盖)。
  String get sourceKey => name;

  /// 读取一帧; 未连接/读取失败返回 null
  GamepadFrame? poll();

  /// 释放后端持有的 native 资源。
  ///
  /// XInput 的 calloc 缓冲区、DirectInput 的 COM 对象与自建数据格式
  /// 都必须显式释放; 无资源的后端无需覆盖。
  void dispose() {}
}

/// XInput FFI 后端 (xinput1_4.dll → xinput9_1_0.dll 回退)
///
/// v3.9: 由「写死槽 0」改为**自动扫描 4 个槽位**并粘住首个可用槽 ——
/// 手柄落在 1/2/3 号槽(双手柄、虚拟设备占位、驱动槽位漂移)时不再失效;
/// 粘住的槽掉线后自动重扫。粘住槽空闲时会顺带探测其它槽,**谁有实际输入
/// 谁生效**,避免被"占位但不报按键"的虚拟设备长期挡住。
class XInputBackend implements BpmGamepadBackend {
  /// XInput 规范支持的槽位上限
  static const int slotCount = 4;

  /// 判为"有实际输入"的摇杆阈值 (与左摇杆死区同源)
  static const int activityThumbThreshold = 7849;

  /// 判为"有实际输入"的扳机阈值
  static const int activityTriggerThreshold = 30;

  final int Function(int, ffi.Pointer<_XInputState>) _getState;
  final List<ffi.Pointer<_XInputState>> _states;

  /// 当前粘住的槽位 (null = 需要重新扫描)
  int? _activeSlot;

  /// 当前使用的槽位 (诊断用)
  int? get activeSlot => _activeSlot;

  @override
  String get name => 'XInput';

  /// 换槽位时标识必须变化, 服务据此重建基线
  @override
  String get sourceKey => 'slot${_activeSlot ?? -1}';

  XInputBackend._(this._getState)
      : _states = List<ffi.Pointer<_XInputState>>.generate(
          slotCount,
          (_) => calloc<_XInputState>(),
        );

  /// 尝试创建; 系统无 XInput 时返回 null (无手柄环境静默降级)
  static XInputBackend? tryCreate() {
    for (final dll in const ['xinput1_4.dll', 'xinput9_1_0.dll']) {
      try {
        final lib = ffi.DynamicLibrary.open(dll);
        final getState = lib.lookupFunction<
            ffi.Int32 Function(ffi.Uint32, ffi.Pointer<_XInputState>),
            int Function(int, ffi.Pointer<_XInputState>)>('XInputGetState');
        return XInputBackend._(getState);
      } catch (_) {
        // 该 dll 不存在,尝试下一个
      }
    }
    return null;
  }

  @override
  GamepadFrame? poll() {
    final picked = selectSlot(_readSlot, _activeSlot);
    _activeSlot = picked.activeSlot;
    return picked.frame;
  }

  /// 多槽位仲裁 (纯函数, 可单测)。
  ///
  /// 规则: 粘住槽有实际输入 → 用它; 否则扫描其它槽, 谁有输入谁生效;
  /// 都没有则回落到粘住槽的空闲帧 (表达「已连接但空闲」)。这样既不会被
  /// 「占位却不报按键」的虚拟设备永久挡住, 也不至于因多手柄抢焦而乱跳。
  @visibleForTesting
  static ({int? activeSlot, GamepadFrame? frame}) selectSlot(
    GamepadFrame? Function(int slot) read,
    int? activeSlot, {
    int count = slotCount,
  }) {
    GamepadFrame? activeFrame;
    var current = activeSlot;
    if (current != null) {
      activeFrame = read(current);
      if (activeFrame == null) {
        current = null; // 原槽掉线 → 回到扫描模式
      } else if (_hasActivity(activeFrame)) {
        return (activeSlot: current, frame: activeFrame);
      }
    }
    // 粘住槽空闲 (或无粘住槽) → 找「真正有输入」的槽
    ({int slot, GamepadFrame frame})? idle;
    for (var slot = 0; slot < count; slot++) {
      if (slot == current) continue;
      final frame = read(slot);
      if (frame == null) continue;
      if (_hasActivity(frame)) return (activeSlot: slot, frame: frame);
      idle ??= (slot: slot, frame: frame);
    }
    // 完全没有输入 → 回落到「已连接但空闲」的槽, 好让 UI 能显示连接态
    return (
      activeSlot: current ?? idle?.slot,
      frame: activeFrame ?? idle?.frame,
    );
  }

  /// 测试钩子: 该帧是否含实际用户输入
  @visibleForTesting
  static bool frameHasActivity(GamepadFrame frame) => _hasActivity(frame);

  /// 读单个槽位; 未连接返回 null
  GamepadFrame? _readSlot(int slot) {
    final state = _states[slot];
    if (_getState(slot, state) != 0) return null; // ERROR_SUCCESS == 0
    final s = state.ref;
    final g = s.gamepad;
    return GamepadFrame(
      packetNumber: s.packetNumber,
      buttons: g.wButtons,
      thumbLX: g.sThumbLX,
      thumbLY: g.sThumbLY,
      thumbRX: g.sThumbRX,
      thumbRY: g.sThumbRY,
      leftTrigger: g.bLeftTrigger,
      rightTrigger: g.bRightTrigger,
    );
  }

  /// 该帧是否含"实际的用户输入"(按键/越死区摇杆/越过阈值的扳机)
  static bool _hasActivity(GamepadFrame f) {
    if (f.buttons != 0) return true;
    if (f.leftTrigger >= activityTriggerThreshold ||
        f.rightTrigger >= activityTriggerThreshold) {
      return true;
    }
    int sq(int v) => v * v;
    return sq(f.thumbLX) + sq(f.thumbLY) >
            activityThumbThreshold * activityThumbThreshold ||
        sq(f.thumbRX) + sq(f.thumbRY) >
            activityThumbThreshold * activityThumbThreshold;
  }

  @override
  void dispose() {
    for (final state in _states) {
      calloc.free(state);
    }
  }
}

/// XINPUT_STATE (XInput.h 布局: DWORD packetNumber + XINPUT_GAMEPAD)
final class _XInputState extends ffi.Struct {
  @ffi.Uint32()
  external int packetNumber;

  external _XInputGamepad gamepad;
}

/// XINPUT_GAMEPAD (WORD + 2×BYTE + 4×SHORT)
final class _XInputGamepad extends ffi.Struct {
  @ffi.Uint16()
  external int wButtons;
  @ffi.Uint8()
  external int bLeftTrigger;
  @ffi.Uint8()
  external int bRightTrigger;
  @ffi.Int16()
  external int sThumbLX;
  @ffi.Int16()
  external int sThumbLY;
  @ffi.Int16()
  external int sThumbRX;
  @ffi.Int16()
  external int sThumbRY;
}
