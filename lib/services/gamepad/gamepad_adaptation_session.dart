/// 游戏手柄适配 —— 会话生命周期 + 映射分发（Phase 2）
///
/// 一场「会话」= 一个前台游戏的一次运行：
/// - **游戏启动成功后**由启动链路创建（Phase 2 接线点，见方案 §8.2）；
/// - 内部组装：后端列表（SDL3 → XInput → DInput）+ `BpmGamepadService` 轮询 +
///   [GamepadMappingDispatcher]（原始按键流 → 按每游戏映射翻译成注入）；
/// - **游戏退出/用户停止**时 [stop]：释放一切按住态 → 停轮询 → 释放后端。
///
/// 设计要点：
/// - **分发与接线分离**：[GamepadMappingDispatcher] 只做「映射表 → 注入」的纯逻辑
///   （注入器/假 sink 均可注入，单测不必碰真手柄）；会话只做组装与生命周期；
/// - **mode 语义**（方案 §5.3，缺一不可）：
///   `tap`（按下即发，固定保持后抬起）/ `hold`（手柄按住=键盘按住，galgame 的
///   Ctrl 快进是按住语义）/ `repeat`（按住时 380ms 后以 130ms 连发）；
/// - **onReset 即安全阀**：手柄断连/换设备/会话停止都必须释放一切按住态，
///   否则映射的 Ctrl 会卡死在按下态（Phase 1 单测锁定的语义）；
/// - `mouse_move` / `mouse_wheel` 的 schema 已就位，但本期**不执行**
///   （Phase 4 实现摇杆模拟鼠标），分发时记 skipped，不抛错。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../big_picture/services/bpm_dinput_backend.dart';
import '../../big_picture/services/bpm_gamepad_service.dart';
import '../../big_picture/services/bpm_sdl3_backend.dart';
import 'gamepad_profile.dart';
import 'input_injector.dart';

/// 把原始按键事件按映射表翻译成注入动作（纯逻辑，可单测）
class GamepadMappingDispatcher {
  GamepadMappingDispatcher({
    required SyntheticInputSink sink,
    required ForegroundChecker foreground,
    required Map<GamepadSource, GamepadMapping> mappings,
    this.hold = const Duration(milliseconds: 50),
    this.repeatInitialDelay = const Duration(milliseconds: 380),
    this.repeatInterval = const Duration(milliseconds: 130),
    Future<void> Function(Duration)? sleep,
    this.onDebug,
  })  : _mappings = mappings,
        _injector = InputInjector(
          sink: sink,
          foreground: foreground,
          hold: hold,
          sleep: sleep,
        ),
        _sleep = sleep ?? Future<void>.delayed;

  /// `tap` 的注入保持时长（默认与 [InputInjector.defaultHold] 一致）
  final Duration hold;
  final Duration repeatInitialDelay;
  final Duration repeatInterval;

  /// 调试输出钩子（诊断面板/测试用）
  final void Function(String message)? onDebug;

  final InputInjector _injector;
  final Map<GamepadSource, GamepadMapping> _mappings;
  final Future<void> Function(Duration) _sleep;

  /// 当前按住中的键（hold 语义）
  final Set<GamepadSource> _heldKeys = {};

  /// 摇杆轴漂移免疫守卫（固件级轴值卡死冻结，见 [AxisStuckGuard]）
  final AxisStuckGuard _axisGuard = AxisStuckGuard();

  /// 当前按住中的鼠标键（hold 语义）
  final Set<GamepadSource> _heldMouseButtons = {};

  /// 连发定时器（repeat 语义）
  final Map<GamepadSource, Timer> _repeatTimers = {};

  int injectedCount = 0;
  int blockedCount = 0;
  int skippedCount = 0;

  /// 🔴 守卫放行但 SendInput 返回 0 的次数（UIPI 权限墙/安全软件拦截证据）
  int rejectedCount = 0;
  bool _rejectedWarned = false;

  /// 服务层实际收到的帧数（诊断「轮询是否在跑」）
  int receivedFrameCount = 0;

  /// 由会话把服务层的每一帧喂进来（帧内含摇杆轴 → 驱动光标移动/滚轮）
  void onFrame(GamepadFrame frame) {
    receivedFrameCount++;
    _handleAxes(frame);
  }

  /// 滚轮累加器（右摇杆：累计到 120 单位 = 一格才发，避免碎片事件）
  double _wheelAccum = 0;

  /// 🔴 摇杆轴响应曲线：死区裁剪 + 归一 + **二次缓动**（轻推慢移、推到底快移）。
  /// 返回 0..1 的有效偏转强度。[axisValue] 为原始轴值（-32767..32767）。
  @visibleForTesting
  static double axisResponse(int axisValue, double deadzone) {
    final mag = (axisValue.abs() / Sdl3.axisMax).clamp(0.0, 1.0);
    if (mag <= deadzone) return 0;
    final t = ((mag - deadzone) / (1 - deadzone)).clamp(0.0, 1.0);
    return t * t;
  }

  /// 满偏转时的光标速度（像素/秒）；轻推按二次曲线衰减。
  /// 2000 = 推满约 1.5s 横穿 1080p 屏（2026-09-27 由 1400 上调，真机轻推略慢）
  static const double _cursorBaseSpeed = 2000;

  /// 单帧（16ms）光标位移。[thumbLY] 已是「正=上」约定（后端取反过），
  /// 鼠标 dy 正=下，故 dy 取负号。
  @visibleForTesting
  static (int, int) cursorDeltaForFrame({
    required int thumbLX,
    required int thumbLY,
    required double deadzone,
    required double sensitivity,
  }) {
    final tl = axisResponse(thumbLX, deadzone);
    final ty = axisResponse(thumbLY, deadzone);
    if (tl == 0 && ty == 0) return (0, 0);
    final dx =
        (thumbLX.sign * tl * _cursorBaseSpeed * sensitivity * 0.016).round();
    final dy =
        -(thumbLY.sign * ty * _cursorBaseSpeed * sensitivity * 0.016).round();
    return (dx, dy);
  }

  /// 帧级轴处理：左摇杆=光标连续移动（死区+二次加速）；右摇杆=滚轮。
  /// 仅当对应源有映射且动作类型匹配时生效；拖拽 = 左键按住（hold）+ 摇杆移动，
  /// 无需特殊处理（鼠标左键保持按下时相对移动即为拖拽）。
  void _handleAxes(GamepadFrame frame) {
    // 🔴 漂移免疫守卫（详见 [AxisStuckGuard]）：固件级轴值卡死
    // （盖世 G8+ 等国产手柄，系统光标功能同样中招）时冻结光标/滚轮轴，
    // 用户反向推杆或摇杆回中立即解锁。
    if (_axisGuard.process(frame.thumbLX, frame.thumbLY)) {
      if (_axisGuard.justEnteredFrozen) {
        onDebug?.call('⚠️ 检测到摇杆轴值卡死（疑似手柄固件残留），已临时冻结'
            '光标轴 —— 反向轻推摇杆或摇杆回中即可恢复');
      }
      return; // 冻结期间不消费轴（按钮映射不受影响）
    }

    final stickLeft = _mappings[GamepadSource.stickLeft];
    if (stickLeft != null && stickLeft.action.type == GamepadActionType.mouseMove) {
      final a = stickLeft.action;
      final (dx, dy) = cursorDeltaForFrame(
        thumbLX: frame.thumbLX,
        thumbLY: frame.thumbLY,
        deadzone: a.deadzone ?? 0.15,
        sensitivity: a.sensitivity ?? 1.0,
      );
      if (dx != 0 || dy != 0) {
        _count(_injector.moveMouseRelative(dx, dy));
      }
    }
    final stickRight = _mappings[GamepadSource.stickRight];
    if (stickRight != null &&
        stickRight.action.type == GamepadActionType.mouseWheel) {
      _handleWheelFrame(frame, stickRight.action);
    }
  }

  /// 右摇杆滚轮：按帧累加，满 120 单位（一格）发一次
  void _handleWheelFrame(GamepadFrame frame, GamepadAction action) {
    final t = axisResponse(frame.thumbRY, action.deadzone ?? 0.15);
    if (t <= 0) {
      _wheelAccum = 0;
      return;
    }
    _wheelAccum += t * 900.0 * (action.sensitivity ?? 1.0) * 0.016;
    var guard = 0;
    while (_wheelAccum.abs() >= 120 && guard < 8) {
      guard++;
      final step = _wheelAccum >= 0 ? 120 : -120;
      _wheelAccum -= step;
      _count(_injector.wheel(step));
    }
  }

  /// 注入前必须绑定目标游戏进程（前台守卫的判定依据）
  void bindTargetPid(int? pid) => _injector.bindTargetPid(pid);

  bool get isForegroundGuardPassing => _injector.isForegroundGuardPassing;

  /// 原始按键事件入口（由服务层的原始流驱动）
  void onButton(GamepadRawButton button, bool down) {
    final source = GamepadSource.fromRawButton(button);
    if (source == null) return;
    final mapping = _mappings[source];
    if (mapping == null) return; // 未映射：静默忽略（不打扰用户）
    switch (mapping.action.type) {
      case GamepadActionType.key:
        _handleKey(source, mapping, down, mapping.action.vk!);
      case GamepadActionType.mouseButton:
        _handleMouseButton(source, mapping, down, mapping.action.mouseButtonName!);
      case GamepadActionType.mouseMove:
        final dir = mapping.action.direction;
        if (dir == null) {
          // 摇杆连续移动走 onFrame；按钮路径的 mouse_move 仅十字键步进
          skippedCount++;
          return;
        }
        if (!down || mapping.mode != GamepadMappingMode.tap) return;
        final step = mapping.action.stepPixels ?? 24;
        final (dx, dy) = switch (dir) {
          'up' => (0, -step),
          'down' => (0, step),
          'left' => (-step, 0),
          _ => (step, 0),
        };
        _count(_injector.moveMouseRelative(dx, dy));
      case GamepadActionType.mouseWheel:
        // 滚轮走 onFrame（右摇杆连续）；按钮路径不处理
        skippedCount++;
    }
  }

  /// 释放一切按住态并停掉连发（手柄断连/换设备/会话停止时必须调用）
  void reset() {
    for (final source in _heldKeys.toList()) {
      final vk = _vkOf(source);
      if (vk != null) {
        final r = _injector.releaseKey(vk);
        _count(r);
      }
    }
    _heldKeys.clear();
    for (final source in _heldMouseButtons.toList()) {
      final mapping = _mappings[source];
      final name = mapping?.action.mouseButtonName ?? 'left';
      _count(_injector.releaseMouseButton(right: name == 'right'));
    }
    _heldMouseButtons.clear();
    for (final timer in _repeatTimers.values) {
      timer.cancel();
    }
    _repeatTimers.clear();
    _axisGuard.reset(); // 断连/换设备后旧轴状态不再可信
  }

  // ── 键盘 ──

  void _handleKey(GamepadSource source, GamepadMapping mapping, bool down, int vk) {
    switch (mapping.mode) {
      case GamepadMappingMode.tap:
        // 按下即发完整一次 tap；抬起无需处理
        if (down) _tapKey(vk);
      case GamepadMappingMode.hold:
        if (down) {
          if (_heldKeys.contains(source)) return; // 防重入
          _heldKeys.add(source);
          _count(_injector.holdKeyDown(vk));
        } else {
          if (!_heldKeys.contains(source)) return;
          _heldKeys.remove(source);
          _count(_injector.releaseKey(vk));
        }
      case GamepadMappingMode.repeat:
        if (down) {
          if (_repeatTimers.containsKey(source)) return;
          _startRepeat(source, vk);
        } else {
          _stopRepeat(source);
        }
    }
  }

  void _tapKey(int vk) {
    unawaited(_injector.tapKey(vk).then(_count));
  }

  void _startRepeat(GamepadSource source, int vk) {
    _repeatTimers[source] = Timer(repeatInitialDelay, () {
      _tapKey(vk);
      _repeatTimers[source] = Timer.periodic(repeatInterval, (_) => _tapKey(vk));
    });
  }

  void _stopRepeat(GamepadSource source) {
    _repeatTimers.remove(source)?.cancel();
  }

  int? _vkOf(GamepadSource source) {
    final m = _mappings[source];
    return m?.action.type == GamepadActionType.key ? m!.action.vk : null;
  }

  // ── 鼠标键 ──

  void _handleMouseButton(
      GamepadSource source, GamepadMapping mapping, bool down, String name) {
    final right = name == 'right';
    switch (mapping.mode) {
      case GamepadMappingMode.tap:
        if (!down) return;
        _count(_injector.pressMouseButton(right: right));
        unawaited(_sleep(hold).then((_) {
          _count(_injector.releaseMouseButton(right: right));
        }));
      case GamepadMappingMode.hold:
        if (down) {
          if (_heldMouseButtons.contains(source)) return;
          _heldMouseButtons.add(source);
          _count(_injector.pressMouseButton(right: right));
        } else {
          if (!_heldMouseButtons.contains(source)) return;
          _heldMouseButtons.remove(source);
          _count(_injector.releaseMouseButton(right: right));
        }
      case GamepadMappingMode.repeat:
        if (down) {
          if (_repeatTimers.containsKey(source)) return;
          _startMouseRepeat(source, right);
        } else {
          _stopRepeat(source);
        }
    }
  }

  void _startMouseRepeat(GamepadSource source, bool right) {
    _repeatTimers[source] = Timer(repeatInitialDelay, () {
      _count(_injector.pressMouseButton(right: right));
      unawaited(_sleep(hold).then((_) {
        _count(_injector.releaseMouseButton(right: right));
      }));
      _repeatTimers[source] = Timer.periodic(repeatInterval, (_) {
        _count(_injector.pressMouseButton(right: right));
        unawaited(_sleep(hold).then((_) {
          _count(_injector.releaseMouseButton(right: right));
        }));
      });
    });
  }

  // ── 计数 ──

  void _count(InjectionResult r) {
    if (r.isSent) {
      if (r.accepted == 0) {
        // 守卫放行了，但系统拒收 —— UIPI（游戏管理员/软件非管理员）或安全软件
        rejectedCount++;
        if (!_rejectedWarned) {
          _rejectedWarned = true;
          onDebug?.call('🔴 P0：注入被守卫放行但 SendInput 返回 0 —— '
              '游戏可能以管理员权限运行（UIPI 静默丢弃）。'
              '请以管理员身份运行 Chrono Tide 后重试。');
        }
      } else {
        injectedCount++;
      }
    } else {
      blockedCount++;
      if (r.outcome == InjectionOutcome.foregroundMismatch) {
        onDebug?.call('注入被守卫拦截（游戏不在前台）');
      }
    }
  }
}

/// 🔴 摇杆轴**漂移免疫守卫**（2026-09-27 v2：应对国产手柄固件级轴值残留）
///
/// 真机证据：盖世 G8+ 在系统自带的手柄光标功能下同样出现「大幅甩杆后
/// 光标持续单向漂移、断控无法恢复」—— 轴值卡死是**手柄固件/ADC 层**
/// 的通病（大幅操作后残留非零读数，且常带 ±几 LSB 抖动），任何软件层
/// 都无法从源头消除。我们能做的是**让脏输入不毁体验**：
///
/// - **冻结判定**：轴值持续 [triggerFrames] 帧（~0.64s）停在大偏移区
///   （>[stuckBand]）且帧间波动极小（≤[jitterTolerance]）—— 物理摇杆
///   不可能一动不动停在大偏移（静置有抖动），判为卡死；
/// - **解锁条件**（任一满足）：①轴值回到中位带（<[centerBand]）；
///   ②帧间大变化（>[unlockDelta]，即用户**反向推杆** —— 卡死轴不会
///   自己变号，反向一推立刻解锁）；
/// - **冻结期间**：光标/滚轮轴完全停发（按钮映射不受影响），
///   杜绝「放不掉的漂移」污染游戏。
@visibleForTesting
class AxisStuckGuard {
  AxisStuckGuard({
    this.triggerFrames = 30,
    this.stuckBand = 6553, // 0.2 满幅
    this.jitterTolerance = 600, // ~1.8% 满幅
    this.centerBand = 2600, // 0.08 满幅
    this.unlockDelta = 1600, // 5% 满幅
    this.jumpThreshold = 10000, // 30% 满幅/帧 —— 人手不可能，甩杆特征
  });

  final int triggerFrames;
  final int stuckBand;
  final int jitterTolerance;
  final int centerBand;
  final int unlockDelta;

  /// 🔴 突变阈值：单帧轴值跳变超过它 = 甩杆特征（人手推杆 16ms 内不可能
  /// 移动 30% 满幅）。**只有「突变后定格」才冻结** —— 用户按住摇杆匀速
  /// 移光标是渐进入驻大偏移（每帧变化有限），永不误伤。
  final int jumpThreshold;

  int _prevLX = 0;
  int _prevLY = 0;
  int _stuckFrames = 0;
  bool _frozen = false;
  bool _seenFirst = false;

  /// 进入当前定格位置的最后一跳是否为突变（>jumpThreshold）。
  /// 突变 = 甩杆/回弹中断特征（人手推杆 16ms 内不可能跳 30% 满幅）；
  /// 渐进入驻 = 用户按住移光标，永不冻结。
  bool _lastJumpBig = false;

  /// 上一帧 process 是否刚好**进入**冻结（边沿通知，日志用）
  bool get justEnteredFrozen => _justFrozen;
  bool _justFrozen = false;

  /// 喂一帧，返回 true = 本帧应冻结（调用方跳过轴消费）
  bool process(int lx, int ly) {
    _justFrozen = false;
    if (!_seenFirst) {
      _prevLX = lx;
      _prevLY = ly;
      _seenFirst = true;
      return false;
    }
    final movedX = (lx - _prevLX).abs();
    final movedY = (ly - _prevLY).abs();
    _prevLX = lx;
    _prevLY = ly;

    if (_frozen) {
      final backToCenter =
          lx.abs() < centerBand && ly.abs() < centerBand;
      final bigMove = movedX > unlockDelta || movedY > unlockDelta;
      if (backToCenter || bigMove) {
        _frozen = false;
        _stuckFrames = 0;
        _lastJumpBig = false;
      }
      return true; // 解锁帧返回 true（本帧轴值刚恢复，从下帧起正常消费）
    }

    final significant = lx.abs() > stuckBand || ly.abs() > stuckBand;
    final jittery = movedX <= jitterTolerance && movedY <= jitterTolerance;
    if (jittery) {
      // 定格中：进入该定格的最后一跳若为突变 → 卡死候选（甩杆残留）
      if (significant && _lastJumpBig) {
        _stuckFrames++;
        if (_stuckFrames >= triggerFrames) {
          _frozen = true;
          _justFrozen = true;
        }
      } else {
        _stuckFrames = 0;
      }
    } else {
      // 运动帧：记录进入下一个定格的跳变特征
      _stuckFrames = 0;
      _lastJumpBig = movedX > jumpThreshold || movedY > jumpThreshold;
    }
    return _frozen;
  }

  /// 断连/换设备/会话停止时重置（新设备不代表旧卡死状态）
  void reset() {
    _prevLX = 0;
    _prevLY = 0;
    _stuckFrames = 0;
    _frozen = false;
    _seenFirst = false;
    _justFrozen = false;
    _lastJumpBig = false;
  }

  bool get isFrozen => _frozen;
}

/// 一场会话 = 一个前台游戏的一次运行（生命周期 + 组装）
class GamepadAdaptationSession {
  GamepadAdaptationSession._({
    required this.effectiveProfile,
    required this.targetPid,
    required this.activeBackendName,
    required this.deviceName,
    required BpmGamepadService service,
    required GamepadMappingDispatcher dispatcher,
    this.onLog,
    BpmGamepadService? externalService,
    BpmGamepadRawListener? rawListener,
  })  : _service = service,
        _dispatcher = dispatcher,
        _externalService = externalService,
        _rawListener = rawListener;

  /// 生效配置（会话创建时已解析，运行期间不重读文件）
  final GamepadProfile effectiveProfile;
  final int targetPid;
  final String activeBackendName;
  final String? deviceName;
  final void Function(String message)? onLog;

  final BpmGamepadService _service;
  final GamepadMappingDispatcher _dispatcher;
  bool _stopped = false;

  /// 附加模式：非 null = 挂在 BPM shell 的服务上消费 raw 流。
  /// 🔴 native 后端资源归服务所有者（shell）管，本会话**绝不 dispose** ——
  /// 旧实现双实例 + stop 时双重 dispose，导致 XInput 缓冲 double-free
  /// （堆损坏崩溃 0xC0000374）与 SDL `_users` 双减提前退出（BPM 手柄死）。
  final BpmGamepadService? _externalService;
  final BpmGamepadRawListener? _rawListener;

  /// 注入遥测心跳（10s 一条；「会话启动了但按键去哪了」从此可查）
  Timer? _statsTimer;
  int _lastInjected = 0;
  int _lastBlocked = 0;
  int _lastRejected = 0;

  /// SendInput 返回 0 的次数（UIPI/权限墙证据 —— 守卫放行但系统拒收）
  int get rejectedBySystemCount => _dispatcher.rejectedCount;
  int get sentAcceptedCount => _dispatcher.injectedCount;

  /// 组装并启动会话；无法启动（禁用/无映射/无后端/注入层不可用）返回 null。
  ///
  /// **附加模式（生产首选，2026-09-27）**：[externalService] 非空时直接挂到
  /// BPM shell 的手柄服务上消费 raw 流 —— **不再自建第二套
  /// SDL3/XInput/DInput 后端**。旧双实例会互抢 SDL 事件与多后端仲裁
  /// （轴值抖动/断控），且 stop 双重 dispose 后端（XInput 缓冲 double-free
  /// → 堆损坏崩溃；SDL `_users` 双减 → 子系统提前退出 → BPM 手柄永久死亡），
  /// 崩溃转储已三连实锤（0xC0000374）。附加模式 stop 只摘监听。
  ///
  /// **自建模式（桌面无 BPM 服务时回退）**：[backends]/[sink]/[foreground]
  /// 缺省时按生产路径创建；[gameDirectoryPath] 非空时启用目录级前台守卫
  /// （启动器型游戏 launcher→真游戏 pid 必失配，纯 pid 比对会全拦）。
  /// 测试可全部注入假实现。
  static GamepadAdaptationSession? tryStart({
    required int targetPid,
    required GamepadProfile profile,
    String gameDirectoryPath = '',
    BpmGamepadService? externalService,
    List<BpmGamepadBackend>? backends,
    SyntheticInputSink? sink,
    ForegroundChecker? foreground,
    String? sdl3DllPath,
    void Function(String message)? onLog,
  }) {
    void log(String m) => onLog?.call(m);

    if (!profile.enabled) {
      log('[GAMEPAD] 该游戏已禁用手柄适配，不启动');
      return null;
    }
    final mappings = {for (final m in profile.mappings) m.source: m};
    if (mappings.isEmpty) {
      log('[GAMEPAD] 映射表为空，不启动');
      return null;
    }

    final attached = externalService != null;
    final effectiveSink = sink ?? SendInputSink.tryCreate();
    final effectiveForeground = foreground ??
        GamepadForegroundGuard.wrap(
          inner: User32ForegroundChecker.tryCreate(),
          targetPid: targetPid,
          gameDirectoryPath: gameDirectoryPath,
        );
    if (effectiveSink == null || effectiveForeground == null) {
      log('[GAMEPAD] 注入层不可用（非 Windows 或缺少系统 DLL）');
      return null;
    }

    final List<BpmGamepadBackend> resolvedBackends;
    final BpmGamepadService service;
    if (attached) {
      resolvedBackends = const [];
      service = externalService;
    } else {
      resolvedBackends =
          backends ?? _createDefaultBackends(sdl3DllPath: sdl3DllPath);
      if (resolvedBackends.isEmpty) {
        log('[GAMEPAD] 本机没有任何可用手柄后端');
        return null;
      }
      service = BpmGamepadService(
        backends: resolvedBackends,
        callbacks: const BpmGamepadCallbacks(),
      );
    }

    final dispatcher = GamepadMappingDispatcher(
      sink: effectiveSink,
      foreground: effectiveForeground,
      mappings: mappings,
      onDebug: log,
    );
    dispatcher.bindTargetPid(targetPid);

    final listener = BpmGamepadRawListener(
      onButton: dispatcher.onButton,
      onFrame: dispatcher.onFrame,
      onReset: () {
        dispatcher.reset();
        log('[GAMEPAD] 手柄断连/换设备，按住态已释放');
      },
    );
    service.addRawListener(listener);
    if (!attached) service.start();

    final first = attached ? null : resolvedBackends.first;
    final deviceName = first is Sdl3Backend ? first.deviceName : null;
    // 🔴 启动判定链日志（2026-09-27「完全无反应」排障教训：会话启动 ≠
    // 注入成功，守卫/UIPI/游戏引擎读取方式任一环节断了都无感知）
    final fgPid = effectiveForeground.foregroundPid();
    log('[GAMEPAD] 会话已启动: ${attached ? "附加BPM服务" : "后端=${first!.name}"}'
        '${deviceName != null ? " 设备=$deviceName" : ""} pid=$targetPid'
        ' 映射=${mappings.length} 条'
        ' 游戏目录=${gameDirectoryPath.isEmpty ? "(未提供)" : gameDirectoryPath}'
        ' 当前前台pid=$fgPid'
        ' exe查询=${User32ForegroundChecker.exeQueryAvailable ? "可用" : "不可用(退化为纯pid比对)"}');
    if (fgPid != targetPid) {
      log('[GAMEPAD] ⚠️ 启动时前台不是目标进程（游戏可能还在启动器阶段，'
          '等待游戏窗口获得前台后注入会自动生效）');
    }
    _checkUipiElevation(targetPid, log);

    final session = GamepadAdaptationSession._(
      effectiveProfile: profile,
      targetPid: targetPid,
      activeBackendName: attached ? 'BPM(附加)' : first!.name,
      deviceName: deviceName,
      service: service,
      dispatcher: dispatcher,
      onLog: onLog,
      externalService: externalService,
      rawListener: listener,
    );
    // 遥测心跳只挂生产路径（测试注入的假后端会话不挂，避免 pending timer）
    if (backends == null && sink == null && foreground == null) {
      session.startTelemetry();
    }
    return session;
  }

  /// 启动 10s 遥测心跳（tryStart 成功后由生产路径调用；测试注入路径可不启）
  void startTelemetry() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final injected = _dispatcher.injectedCount;
      final blocked = _dispatcher.blockedCount;
      final frames = _dispatcher.receivedFrameCount;
      onLog?.call('[GAMEPAD] 心跳: 帧=$frames 注入=$injected(Δ${injected - _lastInjected})'
          ' 守卫拦截=$blocked(Δ${blocked - _lastBlocked})'
          ' 系统拒收=$rejectedBySystemCount(Δ${rejectedBySystemCount - _lastRejected})');
      _lastInjected = injected;
      _lastBlocked = blocked;
      _lastRejected = rejectedBySystemCount;
    });
  }

  /// 🔴 UIPI 权限对比（2026-09-27 新增）：若游戏进程以管理员运行而本应用
  /// 不是，Windows 会**静默丢弃** SendInput（返回 0），症状就是「手柄按了
  /// 游戏完全没反应」。此处只检测并打日志，不弹 UAC（由用户决定是否
  /// 以管理员重启软件）。
  static void _checkUipiElevation(int targetPid, void Function(String) log) {
    if (!Platform.isWindows) return;
    if (_uipiCheckedPids.contains(targetPid)) return;
    _uipiCheckedPids.add(targetPid);
    if (_uipiCheckedPids.length > 16) _uipiCheckedPids.clear();
    try {
      final selfElevated = _selfIsElevated();
      final targetElevated = _targetIsElevated(targetPid);
      if (targetElevated == true && selfElevated == false) {
        log('[GAMEPAD] 🔴 P0：游戏进程以管理员权限运行，而本软件不是 —— '
            'Windows UIPI 会静默丢弃全部注入按键！'
            '请右键 Chrono Tide.exe →「以管理员身份运行」后重试。');
      }
    } catch (_) {
      // 检测失败不影响会话
    }
  }

  static final Set<int> _uipiCheckedPids = <int>{};

  static bool? _selfIsElevated() {
    final advapi32 = DynamicLibrary.open('advapi32.dll');
    final openProcessToken = advapi32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
        int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
    final getTokenInformation = advapi32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>(
        'GetTokenInformation');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final closeHandle = kernel32.lookupFunction<IntPtr Function(IntPtr),
        int Function(int)>('CloseHandle');
    final getCurrentProcess = kernel32.lookupFunction<IntPtr Function(),
        int Function()>('GetCurrentProcess');
    final token = calloc<IntPtr>();
    final elevated = calloc<Uint32>();
    final retLen = calloc<Uint32>();
    try {
      // TOKEN_QUERY = 0x0008；TokenElevation = 20
      if (openProcessToken(getCurrentProcess(), 0x0008, token) == 0) {
        return null;
      }
      if (getTokenInformation(token.value, 20, elevated.cast<Void>(), 4, retLen) == 0) {
        return null;
      }
      return elevated.value != 0;
    } finally {
      if (token.value != 0) closeHandle(token.value);
      calloc.free(token);
      calloc.free(elevated);
      calloc.free(retLen);
    }
  }

  static bool? _targetIsElevated(int pid) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel32.lookupFunction<
        IntPtr Function(Uint32, Uint32, IntPtr),
        int Function(int, int, int)>('OpenProcess');
    final advapi32 = DynamicLibrary.open('advapi32.dll');
    final openProcessToken = advapi32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
        int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
    final getTokenInformation = advapi32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>(
        'GetTokenInformation');
    final closeHandle = kernel32.lookupFunction<IntPtr Function(IntPtr),
        int Function(int)>('CloseHandle');
    const processQueryLimitedInformation = 0x1000;
    final proc = openProcess(processQueryLimitedInformation, 0, pid);
    if (proc == 0) return null; // 无权限打开（可能就是管理员进程，但不作为判定依据）
    final token = calloc<IntPtr>();
    final elevated = calloc<Uint32>();
    final retLen = calloc<Uint32>();
    try {
      if (openProcessToken(proc, 0x0008, token) == 0) return null;
      if (getTokenInformation(token.value, 20, elevated.cast<Void>(), 4, retLen) == 0) {
        return null;
      }
      return elevated.value != 0;
    } finally {
      if (token.value != 0) closeHandle(token.value);
      closeHandle(proc);
      calloc.free(token);
      calloc.free(elevated);
      calloc.free(retLen);
    }
  }

  /// 生产后端列表：SDL3（跨厂商全覆盖）→ XInput → DInput（与 BPM shell 一致）
  static List<BpmGamepadBackend> _createDefaultBackends({String? sdl3DllPath}) {
    final list = <BpmGamepadBackend>[];
    final sdl3 = Sdl3Backend.tryCreate(dllPath: sdl3DllPath);
    if (sdl3 != null) list.add(sdl3);
    final xinput = XInputBackend.tryCreate();
    if (xinput != null) list.add(xinput);
    final dinput = DInputBackend.tryCreate();
    if (dinput != null) list.add(dinput);
    return list;
  }

  bool get isRunning => !_stopped;

  /// 诊断统计（Phase 4 诊断面板消费）
  int get injectedCount => _dispatcher.injectedCount;
  int get blockedCount => _dispatcher.blockedCount;
  int get skippedCount => _dispatcher.skippedCount;
  int get receivedFrameCount => _dispatcher.receivedFrameCount;

  /// 停止会话：先释放一切按住态（安全阀）。
  ///
  /// 🔴 **附加模式**：只摘 raw 监听 + 释放按住态 —— BPM 服务的后端/轮询归
  /// shell 所有，绝不在会话侧 dispose（double-free 崩溃根因）。
  /// **自建模式**：`service.dispose()` 内部已遍历释放全部后端，
  /// **不得**再对自己的 `_backends` 循环 dispose（同一批指针 free 两次 =
  /// 0xC0000374 堆损坏；SDL `_users` 双减 → 子系统提前退出 → BPM 手柄死）。
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    _dispatcher.reset();
    if (_externalService != null) {
      final listener = _rawListener;
      if (listener != null) _service.removeRawListener(listener);
    } else {
      _service.dispose();
    }
    onLog?.call('[GAMEPAD] 会话已停止');
  }
}

/// 启动器兼容的**目录级前台守卫**（包装 [ForegroundChecker]，改写 pid 判定）。
///
/// 背景（2026-09-27 真机）：白色相簿2 经启动器拉起真游戏进程，
/// 启动链路捕获的 `bestPid` 是第一个进程；真游戏成为前台后
/// `foregroundPid() == bestPid` 永远不成立 → [InputInjector] 的安全闸门把
/// 18 条映射**全部拦截**（表现：「进游戏后手柄完全无法操作」）。
///
/// 放行规则（两级，任一通过即视为「目标在前台」）：
/// 1. 前台 pid == 绑定 pid（原语义，精确匹配）；
/// 2. 前台窗口进程的 exe 位于游戏安装目录内（覆盖 launcher→真游戏、
///    逃逸到游戏目录的子进程；exe 路径查询失败则退化为纯 pid 比对）。
///
/// 实现方式：不改 [InputInjector]（其守卫逻辑被大量单测锁定），而是在
/// `foregroundPid()` 上做**归一** —— 判定通过时返回 targetPid 让上层比对
/// 恒真，不通过时返回真实 pid 让比对恒假。
class GamepadForegroundGuard implements ForegroundChecker {
  GamepadForegroundGuard._(this._inner, this._targetPid, this._gameDir);

  final ForegroundChecker _inner;
  final int _targetPid;
  final String _gameDir;

  /// 包装生产 checker；[inner] 为 null（非 Windows）或 [gameDirectoryPath]
  /// 为空时原样返回 inner（退化为纯 pid 比对），绝不放大注入面。
  static ForegroundChecker? wrap({
    required ForegroundChecker? inner,
    required int targetPid,
    required String gameDirectoryPath,
  }) {
    if (inner == null) return null;
    if (gameDirectoryPath.isEmpty) return inner;
    return GamepadForegroundGuard._(inner, targetPid, gameDirectoryPath);
  }

  @override
  bool get isAvailable => _inner.isAvailable;

  @override
  int? foregroundPid() {
    final real = _inner.foregroundPid();
    if (real == _targetPid) return real; // 精确匹配：原语义放行
    if (!_isForegroundProcessInGameDir()) return real; // 不在游戏目录：照实返回（拦截）
    return _targetPid; // 目录级放行
  }

  /// 前台窗口进程的 exe 是否位于游戏安装目录内（大小写/分隔符不敏感，
  /// 前缀比较带分隔符边界，避免 `Games\Foo` 误匹配 `Games\FooBar`）。
  bool _isForegroundProcessInGameDir() {
    if (_gameDir.isEmpty) return false;
    final exe = _inner is User32ForegroundChecker
        ? _inner.foregroundExePath()
        : null;
    if (exe == null || exe.isEmpty) return false;
    return exePathInsideGameDir(exe, _gameDir);
  }

  /// 目录归属判定（纯函数，单测锁定）
  @visibleForTesting
  static bool exePathInsideGameDir(String exePath, String gameDir) {
    String norm(String p) => p.replaceAll('/', '\\').trim().toLowerCase();
    var dirN = norm(gameDir);
    if (dirN.endsWith('\\')) dirN = dirN.substring(0, dirN.length - 1);
    if (dirN.isEmpty) return false;
    return norm(exePath).startsWith('$dirN\\');
  }
}
