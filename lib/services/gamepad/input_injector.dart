/// 合成输入注入层 (Phase 1) —— 把按键/鼠标事件经 `user32!SendInput` 送进系统输入栈。
///
/// 为什么是 `SendInput` 而不是 `PostMessage`:
/// 微软官方两次撰文说明 —— `PostMessage` **不更新键盘 shift state**、也不触发
/// `WH_KEYBOARD` 钩子,游戏里 `GetKeyState`/`GetAsyncKeyState` 读到的仍是真实状态;
/// 对全屏 DirectX 游戏发 `WM_KEYDOWN` 基本无效。`SendInput` 合成的是走完整输入栈的
/// 「真实输入」,对「消息循环 / `GetAsyncKeyState` 轮询 / DirectInput」三种读取方式都有效。
/// (Phase 0 已真机实测:`.arc` 引擎与 Leaf 引擎均生效,窗口化与全屏均生效。)
///
/// 设计要点:
/// - **纯 Dart**: 只依赖 `dart:ffi` / `dart:async`,**不引入 `package:flutter`**。
///   既便于单测,也能被独立探针(plain `dart run`)直接驱动做真机验证。
/// - **前台守卫是 P0 必做**: `SendInput` 是**全局**的 —— 目标窗口不在前台时,
///   注入的按键会打到当前前台窗口(可能正是用户的浏览器/编辑器)。每次注入前校验。
/// - **扫描码优先可选**: 部分老引擎走 DirectInput 读键盘,只认扫描码,故提供
///   `KEYEVENTF_SCANCODE` 模式(`MapVirtualKeyW` 做 vk → scan 映射)。
/// - **保持时长**: 老引擎常用 `GetAsyncKeyState` 轮询,瞬时注入会被漏掉;
///   因此按键默认保持 [defaultHold](50ms)。Phase 0 实测 1ms 即可被观测,50ms 有余量。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ─────────────────────────── Win32 常量 ───────────────────────────

/// `INPUT.type`
const int _inputKeyboard = 1;
const int _inputMouse = 0;

/// `KEYBDINPUT.dwFlags`
const int keyEventfExtendedKey = 0x0001;
const int keyEventfKeyUp = 0x0002;
const int keyEventfScanCode = 0x0008;

/// `MOUSEINPUT.dwFlags`
const int mouseEventfMove = 0x0001;
const int mouseEventfLeftDown = 0x0002;
const int mouseEventfLeftUp = 0x0004;
const int mouseEventfRightDown = 0x0008;
const int mouseEventfRightUp = 0x0010;
const int mouseEventfAbsolute = 0x8000;
const int mouseEventfWheel = 0x0800;

/// `MapVirtualKeyW` 的 `uMapType`：虚拟键码 → 扫描码
const int _mapvkVkToVsc = 0;

// ─────────────────────────── FFI 结构体 ───────────────────────────

final class _KeybdInput extends Struct {
  @Uint16()
  external int wVk;

  @Uint16()
  external int wScan;

  @Uint32()
  external int dwFlags;

  @Uint32()
  external int time;

  /// `ULONG_PTR`（x64 为 8 字节）
  @IntPtr()
  external int dwExtraInfo;
}

final class _MouseInput extends Struct {
  @Int32()
  external int dx;

  @Int32()
  external int dy;

  @Uint32()
  external int mouseData;

  @Uint32()
  external int dwFlags;

  @Uint32()
  external int time;

  @IntPtr()
  external int dwExtraInfo;
}

final class _HardwareInput extends Struct {
  @Uint32()
  external int uMsg;

  @Uint16()
  external int wParamL;

  @Uint16()
  external int wParamH;
}

final class _InputUnion extends Union {
  external _KeybdInput ki;
  external _MouseInput mi;
  external _HardwareInput hi;
}

final class _WinInput extends Struct {
  @Uint32()
  external int type;

  external _InputUnion u;
}

// ─────────────────────────── 抽象接口（供测试替身） ───────────────────────────

/// 底层「合成输入」写入口。
///
/// 生产实现 = [SendInputSink]（`user32!SendInput`）；
/// 测试替身 = 记录调用序列的假实现（**绝不真的注入**，否则会污染用户桌面）。
abstract class SyntheticInputSink {
  /// 平台是否支持注入（非 Windows 或无 user32 时为 false，调用方应静默降级）
  bool get isAvailable;

  /// 合成键盘事件。返回实际被系统接受的输入条数（`SendInput` 返回值）。
  ///
  /// [scanCode] 为 true 时用扫描码模式（`KEYEVENTF_SCANCODE`），
  /// 兼容只认扫描码的 DirectInput 老引擎。
  int sendKey(int vk, {required bool down, bool scanCode = false});

  /// 虚拟键码 → 扫描码；不支持时返回 0
  int scanCodeFor(int vk);

  /// 绝对移动鼠标。[normalizedX]/[normalizedY] 取值 0..65535（覆盖主屏）。
  int sendMouseMoveAbsolute(int normalizedX, int normalizedY);

  /// 按下/抬起鼠标键。[right] 为 true 时用右键。
  int sendMouseButton({required bool down, bool right = false});

  /// 相对移动鼠标（手柄摇杆光标移动用）。[dx]/[dy] 为像素增量。
  /// 默认 no-op（测试 fake 可不实现）；真实 sink 用 MOUSEEVENTF_MOVE。
  int sendMouseRelativeMove(int dx, int dy) => 0;

  /// 滚轮滚动（手柄右摇杆用）。[delta] 为 wheel 单位（120 = 一格）。
  /// 默认 no-op；真实 sink 用 MOUSEEVENTF_WHEEL。
  int sendMouseWheel(int delta) => 0;
}

/// 前台窗口判定。注入前的**安全闸门**。
abstract class ForegroundChecker {
  /// 系统是否支持查询（非 Windows 时 false）
  bool get isAvailable;

  /// 当前前台窗口所属进程 PID；查询失败返回 null
  int? foregroundPid();
}

// ─────────────────────────── 生产实现：SendInput ───────────────────────────

/// `user32!SendInput` 的真实实现。
class SendInputSink implements SyntheticInputSink {
  final _SendInputNative _sendInput;
  final _MapVirtualKeyNative _mapVirtualKey;
  final Pointer<_WinInput> _buffer;

  SendInputSink._(this._sendInput, this._mapVirtualKey)
      : _buffer = calloc<_WinInput>();

  static bool _tried = false;
  static _SendInputNative? _sendInputFn;
  static _MapVirtualKeyNative? _mapVirtualKeyFn;

  /// 尝试创建；非 Windows 或无 `user32.dll` 时返回 null（调用方静默降级）。
  ///
  /// 只缓存**函数指针**（库句柄与符号解析失败后不再重试，与项目既有 FFI 先例一致），
  /// 每次返回**新实例** —— 实例持有自己的 native 缓冲，避免「dispose 后复用已释放实例」
  /// 的 use-after-free。**调用方负责在收尾时 [dispose]。**
  static SendInputSink? tryCreate() {
    if (!_tried) {
      _tried = true;
      if (Platform.isWindows) {
        try {
          final user32 = DynamicLibrary.open('user32.dll');
          _sendInputFn = user32.lookupFunction<
              Uint32 Function(Uint32, Pointer<_WinInput>, Int32),
              int Function(int, Pointer<_WinInput>, int)>('SendInput');
          _mapVirtualKeyFn = user32.lookupFunction<Uint32 Function(Uint32, Uint32),
              int Function(int, int)>('MapVirtualKeyW');
        } catch (_) {
          _sendInputFn = null;
          _mapVirtualKeyFn = null;
        }
      }
    }
    final sendInput = _sendInputFn;
    final mapVirtualKey = _mapVirtualKeyFn;
    if (sendInput == null || mapVirtualKey == null) return null;
    return SendInputSink._(sendInput, mapVirtualKey);
  }

  /// 仅供测试/诊断：`INPUT` 结构体字节数，x64 上应为 **40**
  static int get debugInputStructSize => sizeOf<_WinInput>();

  /// 仅供测试/诊断：键盘联合体成员字节数，x64 上应为 **24**
  static int get debugKeybdInputSize => sizeOf<_KeybdInput>();

  /// 仅供测试/诊断：鼠标联合体成员字节数，x64 上应为 **32**
  static int get debugMouseInputSize => sizeOf<_MouseInput>();

  @override
  bool get isAvailable => true;

  @override
  int sendKey(int vk, {required bool down, bool scanCode = false}) {
    final input = _buffer.ref;
    input.type = _inputKeyboard;
    final ki = input.u.ki;
    ki.wScan = 0;
    ki.time = 0;
    ki.dwExtraInfo = 0;
    if (scanCode) {
      ki.wVk = 0;
      ki.wScan = scanCodeFor(vk);
      ki.dwFlags = keyEventfScanCode | (down ? 0 : keyEventfKeyUp);
    } else {
      ki.wVk = vk;
      ki.dwFlags = down ? 0 : keyEventfKeyUp;
    }
    return _sendInput(1, _buffer, sizeOf<_WinInput>());
  }

  @override
  int scanCodeFor(int vk) => _mapVirtualKey(vk, _mapvkVkToVsc);

  @override
  int sendMouseMoveAbsolute(int normalizedX, int normalizedY) {
    final input = _buffer.ref;
    input.type = _inputMouse;
    final mi = input.u.mi;
    mi.dx = normalizedX;
    mi.dy = normalizedY;
    mi.mouseData = 0;
    mi.time = 0;
    mi.dwExtraInfo = 0;
    mi.dwFlags = mouseEventfMove | mouseEventfAbsolute;
    return _sendInput(1, _buffer, sizeOf<_WinInput>());
  }

  @override
  int sendMouseRelativeMove(int dx, int dy) {
    final input = _buffer.ref;
    final mi = input.u.mi;
    mi.dx = dx;
    mi.dy = dy;
    mi.mouseData = 0;
    mi.time = 0;
    mi.dwExtraInfo = 0;
    mi.dwFlags = mouseEventfMove; // 无 ABSOLUTE = 相对移动
    return _sendInput(1, _buffer, sizeOf<_WinInput>());
  }

  @override
  int sendMouseWheel(int delta) {
    final input = _buffer.ref;
    final mi = input.u.mi;
    mi.dx = 0;
    mi.dy = 0;
    mi.mouseData = delta;
    mi.time = 0;
    mi.dwExtraInfo = 0;
    mi.dwFlags = mouseEventfWheel;
    return _sendInput(1, _buffer, sizeOf<_WinInput>());
  }

  @override
  int sendMouseButton({required bool down, bool right = false}) {
    final input = _buffer.ref;
    input.type = _inputMouse;
    final mi = input.u.mi;
    mi.dx = 0;
    mi.dy = 0;
    mi.mouseData = 0;
    mi.time = 0;
    mi.dwExtraInfo = 0;
    mi.dwFlags = right
        ? (down ? mouseEventfRightDown : mouseEventfRightUp)
        : (down ? mouseEventfLeftDown : mouseEventfLeftUp);
    return _sendInput(1, _buffer, sizeOf<_WinInput>());
  }

  /// 释放 native 缓冲（应用退出或测试收尾时调用）
  void dispose() => calloc.free(_buffer);
}

/// `user32` 前台窗口查询的真实实现。
class User32ForegroundChecker implements ForegroundChecker {
  final _GetForegroundWindowNative _getForegroundWindow;
  final _GetWindowThreadProcessIdNative _getWindowThreadProcessId;
  final _OpenProcessNative? _openProcess;
  final _QueryFullProcessImageNameNative? _queryFullProcessImageName;
  final _CloseHandleNative? _closeHandle;

  User32ForegroundChecker._(
    this._getForegroundWindow,
    this._getWindowThreadProcessId, {
    _OpenProcessNative? openProcess,
    _QueryFullProcessImageNameNative? queryFullProcessImageName,
    _CloseHandleNative? closeHandle,
  })  : _openProcess = openProcess,
        _queryFullProcessImageName = queryFullProcessImageName,
        _closeHandle = closeHandle;

  static bool _tried = false;
  static _GetForegroundWindowNative? _getForegroundWindowFn;
  static _GetWindowThreadProcessIdNative? _getWindowThreadProcessIdFn;
  static _OpenProcessNative? _openProcessFn;
  static _QueryFullProcessImageNameNative? _queryFullProcessImageNameFn;
  static _CloseHandleNative? _closeHandleFn;

  /// 同 [SendInputSink.tryCreate]：只缓存函数指针，每次返回新实例。
  ///
  /// exe 路径查询用的三个符号解析失败**不致命**（只是 [foregroundExePath]
  /// 永远返回 null，守卫退化为纯 pid 比对），故与主符号分开解析。
  static User32ForegroundChecker? tryCreate() {
    if (!_tried) {
      _tried = true;
      if (Platform.isWindows) {
        try {
          final user32 = DynamicLibrary.open('user32.dll');
          _getForegroundWindowFn =
              user32.lookupFunction<IntPtr Function(), int Function()>(
                  'GetForegroundWindow');
          _getWindowThreadProcessIdFn = user32.lookupFunction<
              Uint32 Function(IntPtr, Pointer<Uint32>),
              int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
        } catch (_) {
          _getForegroundWindowFn = null;
          _getWindowThreadProcessIdFn = null;
        }
        try {
          final kernel32 = DynamicLibrary.open('kernel32.dll');
          _openProcessFn = kernel32.lookupFunction<
              IntPtr Function(Uint32, Uint32, IntPtr),
              int Function(int, int, int)>('OpenProcess');
          _queryFullProcessImageNameFn = kernel32.lookupFunction<
              Uint32 Function(IntPtr, Uint32, Pointer<Utf16>,
                  Pointer<Uint32>),
              int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>(
              'QueryFullProcessImageNameW');
          _closeHandleFn = kernel32.lookupFunction<
              IntPtr Function(IntPtr),
              int Function(int)>('CloseHandle');
        } catch (_) {
          _openProcessFn = null;
          _queryFullProcessImageNameFn = null;
          _closeHandleFn = null;
        }
      }
    }
    final getForegroundWindow = _getForegroundWindowFn;
    final getWindowThreadProcessId = _getWindowThreadProcessIdFn;
    if (getForegroundWindow == null || getWindowThreadProcessId == null) {
      return null;
    }
    return User32ForegroundChecker._(
      getForegroundWindow,
      getWindowThreadProcessId,
      openProcess: _openProcessFn,
      queryFullProcessImageName: _queryFullProcessImageNameFn,
      closeHandle: _closeHandleFn,
    );
  }

  @override
  bool get isAvailable => true;

  @override
  int? foregroundPid() {
    final hwnd = _getForegroundWindow();
    if (hwnd == 0) return null;
    final pidPtr = calloc<Uint32>();
    try {
      final tid = _getWindowThreadProcessId(hwnd, pidPtr);
      if (tid == 0) return null;
      return pidPtr.value;
    } finally {
      calloc.free(pidPtr);
    }
  }

  /// 当前前台窗口所属进程的可执行文件完整路径；查询失败返回 null。
  ///
  /// 用于启动器型游戏的前台守卫（启动器 pid ≠ 真游戏 pid，但 exe 同目录）。
  /// `OpenProcess` 需 `PROCESS_QUERY_LIMITED_INFORMATION`（0x1000），
  /// 对绝大多数进程无需提权即可拿到镜像路径。
  ///
  /// 🔴 **per-pid 缓存**：同一 pid 的 exe 路径终身不变，而守卫判定在
  /// dispatchGate（16ms 轮询）与注入路径都会调用 —— 不缓存的话每次
  /// pid 不匹配都要 OpenProcess + 分配 4KB 缓冲，白白发。查询失败
  /// **不缓存**（权限变化/瞬时失败下次还有机会成功）。
  String? foregroundExePath() {
    final openProcess = _openProcess;
    final query = _queryFullProcessImageName;
    final closeHandle = _closeHandle;
    if (openProcess == null || query == null || closeHandle == null) {
      return null;
    }
    final pid = foregroundPid();
    if (pid == null || pid == 0) return null;
    final cached = _exeCache[pid];
    if (cached != null) return cached;
    const processQueryLimitedInformation = 0x1000;
    final handle = openProcess(processQueryLimitedInformation, 0, pid);
    if (handle == 0) return null;
    // Utf16 不是 SizedNativeType，calloc<Utf16> 编译不过 → Uint16 缓冲再 cast
    final sizeBuf = calloc<Uint32>();
    final pathBuf = calloc<Uint16>(1024);
    final pathPtr = pathBuf.cast<Utf16>();
    try {
      sizeBuf.value = 512; // wchar 计数的容量
      final ok = query(handle, 0, pathPtr, sizeBuf);
      if (ok == 0) return null;
      final path = pathPtr.toDartString();
      if (_exeCache.length >= 32) _exeCache.clear(); // 简易防膨胀
      _exeCache[pid] = path;
      return path;
    } catch (_) {
      return null;
    } finally {
      calloc.free(sizeBuf);
      calloc.free(pathBuf);
      closeHandle(handle);
    }
  }

  /// exe 路径缓存（pid → 路径）。进程退出后残留条目无害（pid 复用
  /// 概率极低且重新查询会覆盖）；超上限整体清空。
  static final Map<int, String> _exeCache = <int, String>{};

  /// kernel32 符号是否解析成功（false = 守卫退化为纯 pid 比对，日志可辨）
  static bool get exeQueryAvailable =>
      _openProcessFn != null && _queryFullProcessImageNameFn != null;

  /// 清空 exe 路径缓存（测试用）
  static void debugClearExeCache() => _exeCache.clear();
}

// ─────────────── native 函数签名（FFI 需要显式的 Dart 侧签名） ───────────────

typedef _SendInputNative = int Function(int, Pointer<_WinInput>, int);
typedef _MapVirtualKeyNative = int Function(int, int);
typedef _GetForegroundWindowNative = int Function();
typedef _GetWindowThreadProcessIdNative = int Function(int, Pointer<Uint32>);

// kernel32：前台进程 exe 路径查询（启动器型游戏的前台守卫用）
typedef _OpenProcessNative = int Function(
    int access, int inheritHandle, int pid);
typedef _QueryFullProcessImageNameNative = int Function(
    int handle, int flags, Pointer<Utf16> path, Pointer<Uint32> size);
typedef _CloseHandleNative = int Function(int handle);

// ─────────────────────────── 注入结果 ───────────────────────────

/// 一次注入尝试的结果 —— 用于诊断面板与单测断言。
enum InjectionOutcome {
  /// 已注入
  sent,

  /// 平台不支持（非 Windows / 无 user32）
  unsupported,

  /// 未绑定目标进程 —— 无法判定前台，按安全策略拒绝
  noTarget,

  /// 目标进程不在前台 —— **安全闸门拦截**（P0 行为）
  foregroundMismatch,
}

/// 一次注入的详细结果
class InjectionResult {
  const InjectionResult(this.outcome, {this.accepted = 0});

  final InjectionOutcome outcome;

  /// 被系统接受的输入条数（`SendInput` 返回值；0 表示被 UIPI 等拦下）
  final int accepted;

  bool get isSent => outcome == InjectionOutcome.sent;

  @override
  String toString() => 'InjectionResult($outcome, accepted=$accepted)';
}

// ─────────────────────────── 编排层 ───────────────────────────

/// 把「手柄语义」翻译成「合成键鼠事件」的注入器。
///
/// 只做三件事：**前台守卫 → 合成事件 → 保持时长**。
/// 按键映射、连发、摇杆→鼠标等策略属于上层（Phase 2/4），不在此处。
class InputInjector {
  InputInjector({
    required this.sink,
    required this.foreground,
    this.hold = defaultHold,
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  /// 默认按键保持时长。Phase 0 实测 1ms 即可被 `GetAsyncKeyState` 观测到，
  /// 50ms 为保守值，兼顾老引擎轮询。
  static const Duration defaultHold = Duration(milliseconds: 50);

  final SyntheticInputSink sink;
  final ForegroundChecker foreground;
  final Duration hold;
  final Future<void> Function(Duration) _sleep;

  int? _targetPid;

  /// 绑定目标游戏进程。绑定前所有注入都会被 [InjectionOutcome.noTarget] 拒绝
  /// —— 这是刻意的：宁可不动，也不要把按键漏到用户当前窗口。
  void bindTargetPid(int? pid) => _targetPid = pid;

  /// 当前绑定的目标进程 PID
  int? get targetPid => _targetPid;

  /// 注入是否可用（平台/句柄层面）
  bool get isAvailable => sink.isAvailable && foreground.isAvailable;

  /// 前台守卫是否通过（目标已绑定、且目标进程确为当前前台）
  bool get isForegroundGuardPassing {
    final target = _targetPid;
    if (target == null) return false;
    return foreground.foregroundPid() == target;
  }

  /// 敲一次键：按下 → 保持 [hold] → 抬起
  Future<InjectionResult> tapKey(int vk, {bool scanCode = false}) =>
      _guarded(() async {
        var accepted = sink.sendKey(vk, down: true, scanCode: scanCode);
        await _sleep(hold);
        accepted += sink.sendKey(vk, down: false, scanCode: scanCode);
        return accepted;
      });

  /// 按住不放（用于 galgame 的 `Ctrl` 快进这类「按住语义」）
  InjectionResult holdKeyDown(int vk, {bool scanCode = false}) =>
      _guardedSync(() => sink.sendKey(vk, down: true, scanCode: scanCode));

  /// 释放此前按住的键
  InjectionResult releaseKey(int vk, {bool scanCode = false}) =>
      _guardedSync(() => sink.sendKey(vk, down: false, scanCode: scanCode));

  /// 按下/抬起鼠标键（不移动指针；用于「手柄键 → 鼠标键」映射的 hold 语义）
  InjectionResult pressMouseButton({bool right = false}) =>
      _guardedSync(() => sink.sendMouseButton(down: true, right: right));

  /// 释放此前按下的鼠标键
  InjectionResult releaseMouseButton({bool right = false}) =>
      _guardedSync(() => sink.sendMouseButton(down: false, right: right));

  /// 相对移动鼠标（手柄摇杆光标移动用）。[dx]/[dy] 为像素增量。
  InjectionResult moveMouseRelative(int dx, int dy) =>
      _guardedSync(() => sink.sendMouseRelativeMove(dx, dy));

  /// 滚轮滚动（[delta]：120 = 一格，负值向下）。
  InjectionResult wheel(int delta) =>
      _guardedSync(() => sink.sendMouseWheel(delta));

  /// 在归一化坐标处点击（[nx]/[ny] 为 0..1 的屏幕比例）
  Future<InjectionResult> clickAt(double nx, double ny,
      {bool right = false, bool doubleClick = false}) {
    return _guarded(() async {
      final x = (nx.clamp(0.0, 1.0) * 65535).round();
      final y = (ny.clamp(0.0, 1.0) * 65535).round();
      var accepted = sink.sendMouseMoveAbsolute(x, y);
      final times = doubleClick ? 2 : 1;
      for (var i = 0; i < times; i++) {
        accepted += sink.sendMouseButton(down: true, right: right);
        await _sleep(hold);
        accepted += sink.sendMouseButton(down: false, right: right);
        if (i + 1 < times) await _sleep(hold);
      }
      return accepted;
    });
  }

  // ── 守卫封装 ──

  InjectionOutcome? _checkGuard() {
    if (!isAvailable) return InjectionOutcome.unsupported;
    if (_targetPid == null) return InjectionOutcome.noTarget;
    if (!isForegroundGuardPassing) return InjectionOutcome.foregroundMismatch;
    return null;
  }

  Future<InjectionResult> _guarded(Future<int> Function() body) async {
    final block = _checkGuard();
    if (block != null) return InjectionResult(block);
    return InjectionResult(InjectionOutcome.sent, accepted: await body());
  }

  InjectionResult _guardedSync(int Function() body) {
    final block = _checkGuard();
    if (block != null) return InjectionResult(block);
    return InjectionResult(InjectionOutcome.sent, accepted: body());
  }
}
