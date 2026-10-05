/// SDL3 手柄后端 (Phase 1) —— 跨厂商输入层（Xbox / PS / Switch / 国产全覆盖）
///
/// 为什么是 SDL3：自带跨厂商映射库（位置化按键 South/East/West/North 天然统一
/// Xbox 与 PS 的面键命名），Windows 下经 XInput / DInput / hidapi 三路枚举设备，
/// 消除了自研 DInput 后端「按键序号因厂商而异」的风险。
/// 注入侧与本后端无关 —— 见 `lib/services/gamepad/input_injector.dart`。
///
/// 设计要点:
/// - **实现 [BpmGamepadBackend]**：直接插入 v3.9 多后端仲裁（`BpmGamepadService`），
///   BPM 语义层 / 原始输入流零改动；
/// - **poll() = 状态快照**：`SDL_PumpEvents()` + 排空事件队列 + 逐键/逐轴查询，
///   与 Timer 16ms 轮询模型契合（不依赖 SDL 事件循环）；
/// - **packet 语义**：SDL 无 packet 计数器，改用「状态哈希不变则 packet 不变」，
///   保住服务层「packet 不变 = 无新数据 → 不触发按钮边缘」的判定；
/// - **轴方向**：SDL 约定「摇杆上推 = Y 负值」，而 [GamepadFrame] 约定「正 = 上」，
///   因此 Y 轴**必须取反**（[stickY]）—— v3.10.2 修过同款方向 bug，此处集中一处并单测锁定；
/// - **单设备**：SDL3 支持多手柄，但 [BpmGamepadService] 是单设备模型，
///   取设备列表首个（与 XInput 后端的槽位策略一致）；
/// - FFI 风格与项目惯例一致：tryCreate + 失败静默降级（符号解析失败永不重试）。
///
/// 🔴 **进程级 SDL 生命周期**（P0 教训，2026-09-27）：
/// BPM 手柄服务与适配会话是**同进程的两个 SDL 用户**（各自持有后端实例）。
/// `SDL_Quit()` 是进程级全局拆除（无视引用计数），任何一方 dispose 都会把
/// 对方的 pads/子系统状态整个拆掉 → 对方下一次 16ms 轮询原生崩溃 →
/// 应用直接退出（用户实测「软件有概率自动关闭」）。
/// 因此：**第一个用户 `SDL_Init`，最后一个用户 `SDL_QuitSubSystem`**（见
/// [_ensureSdl] / [dispose] 的 `_users` 计数），中间的 init/quit 全部省略。
///
/// 🔴 **后台事件 hint**：游戏运行时 Chrono Tide 永远是后台窗口，SDL 默认
/// 后台不派发手柄事件 —— 必须在 init 前设置
/// `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS = "1"`（AntiMicroX 同款处理）。
///
/// 🔴 FFI 关键点：SDL3 的 `SDL_Init` / `SDL_GetGamepadButton` 返回 C `bool`（1 字节），
/// Dart 侧必须用 **Uint8** 接收（读 AL 寄存器）；声明成 Int32 会读到 RAX 高位垃圾。
/// （Phase 0 探针实测确认；FFI 符号名以 DLL 导出表为准 ——
/// `SDL_GetGamepadInstanceName` 在 3.4.16 不存在，用 `SDL_GetGamepadNameForID`。）
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/path_helper.dart';
import '../../services/gamepad/gamepad_log.dart';
import 'bpm_gamepad_service.dart';

/// SDL3 常量（SDL_init.h / SDL_gamepad.h / SDL_hints.h）
abstract final class Sdl3 {
  static const int initGamepad = 0x00000200; // 🔴 非 0x20（那是 SDL_INIT_VIDEO）

  // SDL_GamepadButton（位置化命名，与厂商无关）
  static const int buttonSouth = 0;
  static const int buttonEast = 1;
  static const int buttonWest = 2;
  static const int buttonNorth = 3;
  static const int buttonBack = 4;
  static const int buttonGuide = 5;
  static const int buttonStart = 6;
  static const int buttonLeftStick = 7;
  static const int buttonRightStick = 8;
  static const int buttonLeftShoulder = 9;
  static const int buttonRightShoulder = 10;
  static const int buttonDpadUp = 11;
  static const int buttonDpadDown = 12;
  static const int buttonDpadLeft = 13;
  static const int buttonDpadRight = 14;

  // SDL_GamepadAxis
  static const int axisLeftX = 0;
  static const int axisLeftY = 1;
  static const int axisRightX = 2;
  static const int axisRightY = 3;
  static const int axisLeftTrigger = 4;
  static const int axisRightTrigger = 5;

  /// SDL3 摇杆/轴满幅（SDL3 轴范围为 [-32767, 32767]）
  static const int axisMax = 32767;

  /// 后台事件 hint（SDL_hints.h）：游戏运行时本应用永远在后台，
  /// 不开这个手柄事件会被 SDL 静默吞掉（表现为「整体断连」）。
  static const String hintJoystickAllowBackgroundEvents =
      'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS';
}

// ─────────────── native 函数签名 ───────────────

typedef _InitNative = Uint8 Function(Uint32 flags);
typedef _InitDart = int Function(int flags);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _QuitSubSystemNative = Void Function(Uint32 flags);
typedef _QuitSubSystemDart = void Function(int flags);
typedef _SetHintNative = Uint8 Function(
    Pointer<Utf8> name, Pointer<Utf8> value);
typedef _SetHintDart = int Function(Pointer<Utf8> name, Pointer<Utf8> value);
typedef _GetGamepadsNative = Pointer<Uint32> Function(Pointer<Int32> count);
typedef _GetGamepadsDart = Pointer<Uint32> Function(Pointer<Int32> count);
typedef _OpenGamepadNative = Pointer<Void> Function(Uint32 instanceId);
typedef _OpenGamepadDart = Pointer<Void> Function(int instanceId);
typedef _CloseGamepadNative = Void Function(Pointer<Void> gamepad);
typedef _CloseGamepadDart = void Function(Pointer<Void> gamepad);
typedef _GetButtonNative = Uint8 Function(
    Pointer<Void> gamepad, Int32 button);
typedef _GetButtonDart = int Function(Pointer<Void> gamepad, int button);
typedef _GetAxisNative = Int16 Function(Pointer<Void> gamepad, Int32 axis);
typedef _GetAxisDart = int Function(Pointer<Void> gamepad, int axis);
typedef _NameForIdNative = Pointer<Utf8> Function(Uint32 instanceId);
typedef _NameForIdDart = Pointer<Utf8> Function(int instanceId);
typedef _GetErrorNative = Pointer<Utf8> Function();
typedef _GetErrorDart = Pointer<Utf8> Function();
typedef _PollEventNative = Uint8 Function(Pointer<Uint8> event);
typedef _PollEventDart = int Function(Pointer<Uint8> event);
typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

/// SDL3 导出函数集合（符号解析一次，失败即放弃 —— 与项目 FFI 惯例一致）
class _Sdl3Api {
  _Sdl3Api._(
      this.init,
      this.quitSubSystem,
      this.setHint,
      this.pump,
      this.getGamepads,
      this.openGamepad,
      this.closeGamepad,
      this.getButton,
      this.getAxis,
      this.nameForId,
      this.getError,
      this.pollEvent,
      this.free);

  static _Sdl3Api? tryOpen(DynamicLibrary lib) {
    try {
      return _Sdl3Api._(
        lib.lookupFunction<_InitNative, _InitDart>('SDL_Init'),
        lib.lookupFunction<_QuitSubSystemNative, _QuitSubSystemDart>(
            'SDL_QuitSubSystem'),
        lib.lookupFunction<_SetHintNative, _SetHintDart>('SDL_SetHint'),
        lib.lookupFunction<_VoidNative, _VoidDart>('SDL_PumpEvents'),
        lib.lookupFunction<_GetGamepadsNative, _GetGamepadsDart>(
            'SDL_GetGamepads'),
        lib.lookupFunction<_OpenGamepadNative, _OpenGamepadDart>(
            'SDL_OpenGamepad'),
        lib.lookupFunction<_CloseGamepadNative, _CloseGamepadDart>(
            'SDL_CloseGamepad'),
        lib.lookupFunction<_GetButtonNative, _GetButtonDart>(
            'SDL_GetGamepadButton'),
        lib.lookupFunction<_GetAxisNative, _GetAxisDart>('SDL_GetGamepadAxis'),
        lib.lookupFunction<_NameForIdNative, _NameForIdDart>(
            'SDL_GetGamepadNameForID'),
        lib.lookupFunction<_GetErrorNative, _GetErrorDart>('SDL_GetError'),
        lib.lookupFunction<_PollEventNative, _PollEventDart>('SDL_PollEvent'),
        lib.lookupFunction<_FreeNative, _FreeDart>('SDL_free'),
      );
    } catch (_) {
      return null; // 符号缺失（SDL 版本差异）→ 永不重试
    }
  }

  final _InitDart init;
  final _QuitSubSystemDart quitSubSystem;
  final _SetHintDart setHint;
  final _VoidDart pump;
  final _GetGamepadsDart getGamepads;
  final _OpenGamepadDart openGamepad;
  final _CloseGamepadDart closeGamepad;
  final _GetButtonDart getButton;
  final _GetAxisDart getAxis;
  final _NameForIdDart nameForId;
  final _GetErrorDart getError;
  final _PollEventDart pollEvent;
  final _FreeDart free;

  static String errorOf(_GetErrorDart getError) {
    final p = getError();
    return p == nullptr ? '(null)' : p.toDartString();
  }
}

/// SDL3 手柄后端
class Sdl3Backend implements BpmGamepadBackend {
  Sdl3Backend._(this._api, this._dllPath);

  static bool _lookupFailed = false;

  // ── 进程级 SDL 生命周期（🔴 见文件头注释）──
  /// SDL 子系统已由本进程初始化且尚未退出
  static bool _sdlReady = false;

  /// 存活的后端实例数（= SDL 用户数）
  static int _users = 0;

  final _Sdl3Api _api;
  final String _dllPath;

  Pointer<Void> _pad = nullptr;
  int _instanceId = -1;
  String? _deviceName;
  int _packet = 0;
  int _lastStateHash = 0;

  /// 状态哈希最近一次变化的时刻（假活检测用）
  DateTime _lastStateChangeAt = DateTime.now();

  /// 假活已警告标记（避免刷屏）
  bool _fakeAliveWarned = false;

  /// GetGamepads 连续返回空列表的次数（假断连去抖用）
  int _emptyListPolls = 0;

  /// 空列表去抖阈值：连续 ~3 帧（50ms）读不到设备才接受「移除」。
  ///
  /// 🔴 SDL_GetGamepads 偶发返回空列表/顺序抖动（2026-09-27 真机日志
  /// 15:18:50 / 15:19:21 两次「手柄移除/切换」后立刻恢复），立即重开会导致
  /// 服务层重建基线 + 广播 rawReset —— 会话中被映射的按住键（Ctrl 快进/
  /// 左键拖拽）被无辜释放。去抖只针对「消失」，真换设备（firstId 变化）仍即时响应。
  static const int _deviceRemovalDebouncePolls = 3;

  /// 当前设备名（诊断/连接提示用；未连接为 null）
  String? get deviceName => _deviceName;

  /// 实际加载的 SDL3.dll 路径（诊断用）
  String get dllPath => _dllPath;

  @override
  String get name => 'SDL3';

  /// 换设备（instanceId 变化）时必须变化 → 服务层据此重建基线
  @override
  String get sourceKey => sourceKeyFor(_instanceId);

  /// sourceKey 格式（单测锁定，供诊断展示）
  @visibleForTesting
  static String sourceKeyFor(int instanceId) => 'sdl3#$instanceId';

  /// 尝试创建；非 Windows / DLL 缺失 / 符号缺失 / 初始化失败 → null（静默降级）
  ///
  /// [dllPath] 缺省用 `PathHelper.sdl3DllPath`（runtime/sdl3/SDL3.dll）；
  /// 单测可显式传入仓库内路径。
  static Sdl3Backend? tryCreate({String? dllPath}) {
    if (!Platform.isWindows || _lookupFailed) return null;
    final path = dllPath ?? _defaultDllPath();
    if (path == null || !File(path).existsSync()) return null;
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(path);
    } catch (_) {
      return null;
    }
    final api = _Sdl3Api.tryOpen(lib);
    if (api == null) {
      _lookupFailed = true;
      GamepadLog.log('SDL3 符号解析失败（版本差异），永不重试: $path');
      return null;
    }
    if (!_ensureSdl(api)) return null;
    _users++;
    return Sdl3Backend._(api, path);
  }

  /// 进程级初始化（仅第一个用户真正 SDL_Init；见文件头「进程级 SDL 生命周期」）
  static bool _ensureSdl(_Sdl3Api api) {
    if (_sdlReady) return true;
    // 🔴 后台事件：游戏运行时 Chrono Tide 永远是后台窗口，
    // 不开这个 hint，SDL 会在后台静默吞掉手柄事件（「整体断连」）。
    final name = Sdl3.hintJoystickAllowBackgroundEvents.toNativeUtf8();
    final value = '1'.toNativeUtf8();
    try {
      api.setHint(name, value);
    } finally {
      calloc.free(name);
      calloc.free(value);
    }
    if (api.init(Sdl3.initGamepad) != 1) {
      GamepadLog.log('SDL_Init 失败: ${_Sdl3Api.errorOf(api.getError)}');
      return false;
    }
    _sdlReady = true;
    GamepadLog.log('SDL 已初始化（GAMEPAD 子系统；后台事件 hint 已设置）');
    return true;
  }

  static String? _defaultDllPath() {
    try {
      return PathHelper.sdl3DllPath;
    } catch (_) {
      return null;
    }
  }

  String _lastError() => _Sdl3Api.errorOf(_api.getError);

  // ══════════ 纯函数（单测锁定，映射逻辑集中于此） ══════════

  /// SDL 位置化按键 → [XInputButtons] 位掩码；未映射键（GUIDE/摇杆键/触摸板等）返回 0
  @visibleForTesting
  static int sdlButtonToXInput(int sdlButton) => switch (sdlButton) {
        Sdl3.buttonSouth => XInputButtons.a,
        Sdl3.buttonEast => XInputButtons.b,
        Sdl3.buttonWest => XInputButtons.x,
        Sdl3.buttonNorth => XInputButtons.y,
        Sdl3.buttonBack => XInputButtons.back,
        Sdl3.buttonStart => XInputButtons.start,
        Sdl3.buttonLeftShoulder => XInputButtons.leftShoulder,
        Sdl3.buttonRightShoulder => XInputButtons.rightShoulder,
        Sdl3.buttonDpadUp => XInputButtons.dpadUp,
        Sdl3.buttonDpadDown => XInputButtons.dpadDown,
        Sdl3.buttonDpadLeft => XInputButtons.dpadLeft,
        Sdl3.buttonDpadRight => XInputButtons.dpadRight,
        _ => 0,
      };

  /// 把「SDL 按键是否按下」的查询函数折算成 [GamepadFrame.buttons] 位掩码
  @visibleForTesting
  static int composeButtonsMask(bool Function(int sdlButton) isDown) {
    var mask = 0;
    for (var b = 0; b <= Sdl3.buttonDpadRight; b++) {
      if (isDown(b)) mask |= sdlButtonToXInput(b);
    }
    return mask;
  }

  /// 扳机归一量（0..32767）→ [GamepadFrame] 的 0..255
  @visibleForTesting
  static int triggerToByte(int sdlAxisValue) =>
      (sdlAxisValue.clamp(0, Sdl3.axisMax) * 255 ~/ Sdl3.axisMax);

  /// 🔴 摇杆 Y 轴取反：SDL 约定「上推 = 负值」，[GamepadFrame] 约定「正 = 上」。
  /// X 轴同为「右 = 正」，无需处理。
  @visibleForTesting
  static int stickY(int sdlAxisValue) => -sdlAxisValue;

  // ══════════ 轮询 ══════════

  @override
  GamepadFrame? poll() {
    if (!_sdlReady) return null;
    _api.pump();
    _drainEvents();
    _refreshDevice();
    final pad = _pad;
    if (pad == nullptr) return null;

    final mask = composeButtonsMask((b) => _api.getButton(pad, b) != 0);
    final lx = _api.getAxis(pad, Sdl3.axisLeftX);
    final ly = stickY(_api.getAxis(pad, Sdl3.axisLeftY));
    final rx = _api.getAxis(pad, Sdl3.axisRightX);
    final ry = stickY(_api.getAxis(pad, Sdl3.axisRightY));
    final lt = triggerToByte(_api.getAxis(pad, Sdl3.axisLeftTrigger));
    final rt = triggerToByte(_api.getAxis(pad, Sdl3.axisRightTrigger));

    // SDL 无 packet 计数器：状态哈希不变 → packet 不变（保住边缘检测语义）
    final hash = Object.hash(mask, lx, ly, rx, ry, lt, rt);
    if (hash != _lastStateHash) {
      _packet++;
      _lastStateHash = hash;
      _lastStateChangeAt = DateTime.now();
      _fakeAliveWarned = false;
    } else {
      _checkFakeAlive();
    }

    return GamepadFrame(
      packetNumber: _packet,
      buttons: mask,
      thumbLX: lx,
      thumbLY: ly,
      thumbRX: rx,
      thumbRY: ry,
      leftTrigger: lt,
      rightTrigger: rt,
    );
  }

  /// 排空 SDL 事件队列（缓冲故意放大且不读取内容；不排空会积压 65535 条上限）
  void _drainEvents() {
    final scratch = calloc<Uint8>(512);
    while (_api.pollEvent(scratch) != 0) {}
    calloc.free(scratch);
  }

  // ══════════ 假活检测与自愈（2026-09-27 G8+ 真机） ══════════

  /// 独立 XInput 探测器（交叉验证数据源；与仲裁后端互不相干）
  static XInputBackend? _xinputProbe;

  /// SDL 状态 3s 冻结 → 用独立 XInput 读数交叉验证：
  /// **XInput 看到手柄活动而 SDL 状态纹丝不动 = SDL 假活**（真机日志
  /// `SDL_OpenGamepad 失败: Couldn't setup USB mode` 后设备假活——帧有、
  /// 状态死，BPM 语义与游戏注入全灭）。此时强制关闭并重开设备自愈；
  /// 下一帧 `_refreshDevice` 重新打开。用户没碰手柄（XInput 也静默）→ 不触发。
  void _checkFakeAlive() {
    if (DateTime.now().difference(_lastStateChangeAt) <
        const Duration(seconds: 3)) {
      return;
    }
    if (_pad == nullptr) return; // 未开设备由 _refreshDevice 管
    final probe = _xinputProbe ??= XInputBackend.tryCreate();
    if (probe == null) return; // 无 XInput 能力（非 XInput 协议手柄跳过检测）
    final frame = probe.poll();
    if (frame == null) return; // 探测器也读不到 → 无法交叉验证
    final activity = frame.buttons != 0 ||
        frame.leftTrigger > 30 ||
        frame.rightTrigger > 30 ||
        frame.thumbLX.abs() > 7849 ||
        frame.thumbLY.abs() > 7849 ||
        frame.thumbRX.abs() > 7849 ||
        frame.thumbRY.abs() > 7849;
    if (!activity) return; // 用户确实没碰手柄
    if (_fakeAliveWarned) return; // 每轮假活只自愈+警告一次
    _fakeAliveWarned = true;
    GamepadLog.log('[SDL] ⚠️ 状态 3s 冻结但 XInput 检测到手柄活动 —— 判定 SDL '
        '假活（USB 模式异常），强制重开设备');
    if (_pad != nullptr) {
      _api.closeGamepad(_pad);
      _pad = nullptr;
    }
    _instanceId = -1; // 强制 _refreshDevice 下帧重开
    _lastStateChangeAt = DateTime.now(); // 重置窗口，给重开后的设备 3s 观察期
  }

  /// 设备刷新：列表首项变化（接入 / 拔出 / 换设备）时重开手柄。
  /// instanceId 变化会带动 [sourceKey] 变化 → 服务层重建基线（复用既有安全机制）。
  void _refreshDevice() {
    final countBuf = calloc<Int32>();
    final pads = _api.getGamepads(countBuf);
    final count = countBuf.value;
    final firstId = count > 0 ? pads[0] : -1;
    if (count > 0) _api.free(pads.cast());
    calloc.free(countBuf);

    // 🔴 假断连去抖：设备「消失」必须连续多帧确认（见 _deviceRemovalDebouncePolls）
    if (firstId < 0) {
      _emptyListPolls++;
      if (_emptyListPolls < _deviceRemovalDebouncePolls && _pad != nullptr) {
        return; // 疑似抖动：沿用当前打开的手柄，不重开
      }
    } else {
      _emptyListPolls = 0;
    }
    if (firstId == _instanceId) return;

    if (_instanceId >= 0) {
      GamepadLog.log(
          'SDL 手柄移除/切换: instanceId=$_instanceId -> firstId=$firstId');
    }
    if (_pad != nullptr) {
      _api.closeGamepad(_pad);
      _pad = nullptr;
    }
    _deviceName = null;
    _instanceId = firstId;
    if (firstId >= 0) {
      _pad = _api.openGamepad(firstId);
      if (_pad != nullptr) {
        final namePtr = _api.nameForId(firstId);
        _deviceName =
            namePtr == nullptr ? '(未命名设备)' : namePtr.toDartString();
        GamepadLog.log(
            'SDL 手柄已打开: instanceId=$firstId name=$_deviceName (用户数 $_users)');
      } else {
        GamepadLog.log('SDL_OpenGamepad 失败: ${_lastError()}');
      }
    }
  }

  @override
  void dispose() {
    if (_pad != nullptr) {
      _api.closeGamepad(_pad);
      _pad = nullptr;
    }
    _users--;
    // 🔴 只有最后一个用户才退出 SDL（见文件头「进程级 SDL 生命周期」）；
    // 绝不能调 SDL_Quit —— 那是进程级全局拆除，会拆掉其它用户的状态。
    if (_users <= 0 && _sdlReady) {
      _api.quitSubSystem(Sdl3.initGamepad);
      _sdlReady = false;
      GamepadLog.log('SDL 已退出（最后一个用户销毁）');
    }
  }
}
