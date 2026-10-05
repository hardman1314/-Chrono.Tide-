import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'bpm_gamepad_service.dart';

/// DirectInput 8 后端 (v3.9) — 覆盖 XInput 看不见的手柄
///
/// 为什么需要它: XInput 只认 Xbox 系与"XInput 模式"设备; PS4/PS5
/// (DualShock/DualSense)、Switch Pro、多数国产手柄在 Windows 上以
/// **DirectInput / HID 游戏设备**身份出现, XInput 完全看不到 —— 这类手柄
/// 在 BPM 里表现为"完全无反应"。本后端经 `dinput8.dll` COM 直读补齐这块。
///
/// 实现要点 (均由真机探针实测确认):
/// - `dinput8.dll` **不导出** `c_dfDIJoystick2` (GetProcAddress 实测为 null),
///   因此自建 [DIDATAFORMAT]: 6 轴 + 1 POV + 16 按钮, 状态结构逐 offset 对应;
/// - `GetModuleHandleW` / `GetDesktopWindow` 的返回值**必须按指针宽度声明**
///   (`ffi.IntPtr`), 否则 64 位句柄被截断 → `DirectInput8Create` 返回
///   `E_INVALIDARG`(0x80070057)。这是本后端最易踩的坑;
/// - DirectInput 没有 packet 概念, 由本后端**合成 packet**: 状态变化即自增,
///   供 [BpmGamepadService] 的按钮边缘检测正常工作;
/// - 零新增依赖: 全部经 dart:ffi 直调系统 DLL, 与项目既有 FFI 同套路。
///
/// ⚠️ 按钮序号不确定性: DirectInput **不做**跨厂商标准化, 不同手柄的按钮
/// 序号可能不同。这里默认按标准 Xbox 布局解析, 并提供 [_buttonLayouts]
/// 按产品名覆盖 —— 真机发现错位时登记即可, 无需改映射主干。
class DInputBackend implements BpmGamepadBackend {
  // ── HRESULT / 常量 ──
  static const int _diOk = 0;
  static const int _di8DevClassGameCtrl = 0x04;
  static const int _diedflAttachedOnly = 0x01;
  static const int _dienumContinue = 1;
  static const int _dienumStop = 0;
  static const int _disclBackground = 0x00000008;
  static const int _disclNonExclusive = 0x00000002;
  static const int _didfAbsAxis = 0x00000001;

  static const int _didftAxis = 0x00000003;
  static const int _didftButton = 0x0000000C;
  static const int _didftPov = 0x00000010;
  static const int _didftAnyInstance = 0x00FFFF00;
  static const int _didftOptional = 0x80000000;

  /// DIDEVICEINSTANCEW 里名称缓冲的字符数 (MAX_PATH)
  static const int _nameBufferChars = 260;

  /// 自建状态结构可容纳的按钮数
  static const int buttonCapacity = 16;

  /// 状态结构布局: 6 轴(各 4B) → POV(4B) → 16 按钮(各 1B) = 44B
  static const int _povOffset = 24;
  static const int _buttonOffset = 28;

  /// DirectInput 游戏设备常见的有符号满量程
  static const int _axisMax = 32767;

  /// POV 居中哨兵
  static const int _povCentered = 0xFFFFFFFF;

  // ── vtable 下标 ──
  static const int _di8CreateDevice = 3;
  static const int _di8EnumDevices = 4;
  static const int _iunknownRelease = 2;
  static const int _devAcquire = 7;
  static const int _devUnacquire = 8;
  static const int _devGetDeviceState = 9;
  static const int _devSetDataFormat = 11;
  static const int _devSetCooperativeLevel = 13;
  static const int _devPoll = 23;

  ffi.Pointer<ffi.Void> _directInput = ffi.nullptr;
  ffi.Pointer<ffi.Void> _device = ffi.nullptr;
  ffi.Pointer<_DInputState> _statePtr = ffi.nullptr;

  String _deviceProduct = '';
  int _packet = 0;
  List<int> _lastSnapshot = <int>[];
  bool _hasBaseline = false;

  /// 需要手动释放的 native 内存
  final List<ffi.Pointer<ffi.Void>> _allocations = <ffi.Pointer<ffi.Void>>[];
  ffi.Pointer<_DIDeviceInstance> _enumResult = ffi.nullptr;
  ffi.NativeCallable<_EnumDevicesCbNative>? _enumCallable;

  /// 设备产品名 (诊断日志用)
  String get deviceProduct => _deviceProduct;

  /// 设备是否已就绪
  bool get isDeviceReady => _device != ffi.nullptr;

  @override
  String get name => 'DirectInput';

  @override
  String get sourceKey => 'dev:$_deviceProduct';

  DInputBackend._();

  /// 尝试创建并打开第一个可用的 DInput 游戏设备。
  ///
  /// 系统缺少 `dinput8.dll` 或当前无 DInput 游戏设备时返回 null
  /// (与 XInput 后端一致: 无手柄环境静默降级为零开销)。
  static DInputBackend? tryCreate() {
    final backend = DInputBackend._();
    try {
      if (!backend._openDirectInput()) {
        backend.dispose();
        return null;
      }
      if (!backend._openFirstDevice()) {
        backend.dispose();
        return null;
      }
      return backend;
    } catch (e) {
      debugPrint('[BPM][Gamepad] DirectInput 初始化异常: $e');
      backend.dispose();
      return null;
    }
  }

  // ═══════════ 初始化 ═══════════

  bool _openDirectInput() {
    final ffi.DynamicLibrary dinput8;
    final ffi.DynamicLibrary kernel32;
    try {
      dinput8 = ffi.DynamicLibrary.open('dinput8.dll');
      kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    } catch (e) {
      debugPrint('[BPM][Gamepad] dinput8.dll 不可用: $e');
      return false;
    }

    final _DirectInput8CreateDart create = dinput8.lookupFunction<
        _DirectInput8CreateNative, _DirectInput8CreateDart>(
        'DirectInput8Create');
    final _GetModuleHandleDart getModuleHandle = kernel32.lookupFunction<
        _GetModuleHandleNative, _GetModuleHandleDart>('GetModuleHandleW');

    final iid = _alloc<_GUID>(ffi.sizeOf<_GUID>());
    _writeGuid(iid.ref, _iidDirectInput8W);
    final out = _alloc<ffi.Pointer<ffi.Void>>(
        ffi.sizeOf<ffi.Pointer<ffi.Void>>());

    // 🔴 GetModuleHandleW 必须按指针宽度取值, 截断会让 DirectInput8Create
    // 直接返回 E_INVALIDARG。
    final hinst = getModuleHandle(ffi.nullptr);
    final hr = create(hinst, 0x0800, iid, out, ffi.nullptr);
    if (hr != _diOk || out.value == ffi.nullptr) {
      debugPrint('[BPM][Gamepad] DirectInput8Create 失败 hr=0x${_hex32(hr)}');
      return false;
    }
    _directInput = out.value;
    return true;
  }

  bool _openFirstDevice() {
    if (_directInput == ffi.nullptr) return false;

    final user32 = ffi.DynamicLibrary.open('user32.dll');
    final _GetDesktopWindowDart getDesktopWindow = user32.lookupFunction<
        _GetDesktopWindowNative, _GetDesktopWindowDart>('GetDesktopWindow');

    _enumResult = _alloc<_DIDeviceInstance>(ffi.sizeOf<_DIDeviceInstance>());
    _enumCallable =
        ffi.NativeCallable<_EnumDevicesCbNative>.isolateLocal(_onEnumDevice,
            exceptionalReturn: _dienumContinue);
    try {
      final enumDevices = _slot<_EnumDevicesNative>(_directInput, _di8EnumDevices).asFunction<_EnumDevicesDart>();
      final hr = enumDevices(
        _directInput,
        _di8DevClassGameCtrl,
        _enumCallable!.nativeFunction,
        ffi.nullptr,
        _diedflAttachedOnly,
      );
      if (hr != _diOk) {
        debugPrint('[BPM][Gamepad] EnumDevices 失败 hr=0x${_hex32(hr)}');
        return false;
      }
      if (_enumResult.ref.dwSize == 0) {
        debugPrint('[BPM][Gamepad] DirectInput 未枚举到任何游戏设备');
        return false;
      }
      // EnumDevices 是同步调用, 回调已执行完毕, 可安全关闭
      _enumCallable!.close();
      _enumCallable = null;
      return _createDevice(getDesktopWindow());
    } finally {
      _enumCallable?.close();
      _enumCallable = null;
    }
  }

  /// EnumDevices 回调: 取首个设备即停止
  int _onEnumDevice(
      ffi.Pointer<_DIDeviceInstance> instance, ffi.Pointer<ffi.Void> _) {
    final result = _enumResult;
    if (result == ffi.nullptr) return _dienumStop;
    final src = instance.ref;
    final dst = result.ref;
    dst.dwSize = src.dwSize == 0 ? ffi.sizeOf<_DIDeviceInstance>() : src.dwSize;
    dst.dwDevType = src.dwDevType;
    dst.wUsagePage = src.wUsagePage;
    dst.wUsage = src.wUsage;
    _copyGuid(dst.guidInstance, src.guidInstance);
    _copyGuid(dst.guidProduct, src.guidProduct);
    _copyGuid(dst.guidFFDriver, src.guidFFDriver);
    _deviceProduct = _utf16(src.tszProductName, _nameBufferChars);
    if (_deviceProduct.isEmpty) {
      _deviceProduct = _utf16(src.tszInstanceName, _nameBufferChars);
    }
    return _dienumStop;
  }

  bool _createDevice(int hwnd) {
    // CreateDevice 需要 guidInstance 的地址。Dart FFI 对 inline struct 字段
    // 不暴露指针, 故单独拷一份到独立缓冲区。
    final guidInstance = _alloc<_GUID>(ffi.sizeOf<_GUID>());
    _copyGuid(guidInstance.ref, _enumResult.ref.guidInstance);

    final outDevice =
        _alloc<ffi.Pointer<ffi.Void>>(ffi.sizeOf<ffi.Pointer<ffi.Void>>());
    final createDevice =
        _slot<_CreateDeviceNative>(_directInput, _di8CreateDevice).asFunction<_CreateDeviceDart>();
    final hr =
        createDevice(_directInput, guidInstance, outDevice, ffi.nullptr);
    if (hr != _diOk || outDevice.value == ffi.nullptr) {
      debugPrint('[BPM][Gamepad] CreateDevice 失败 hr=0x${_hex32(hr)}');
      return false;
    }
    _device = outDevice.value;

    final dataFormat = _buildDataFormat();
    final setFormat =
        _slot<_SetDataFormatNative>(_device, _devSetDataFormat).asFunction<_SetDataFormatDart>();
    final hrFormat = setFormat(_device, dataFormat);
    if (hrFormat != _diOk) {
      debugPrint('[BPM][Gamepad] SetDataFormat 失败 hr=0x${_hex32(hrFormat)}');
      return false;
    }

    final setCoop =
        _slot<_SetCooperativeLevelNative>(_device, _devSetCooperativeLevel).asFunction<_SetCooperativeLevelDart>();
    final hrCoop =
        setCoop(_device, hwnd, _disclBackground | _disclNonExclusive);
    if (hrCoop != _diOk) {
      debugPrint(
          '[BPM][Gamepad] SetCooperativeLevel 失败 hr=0x${_hex32(hrCoop)}');
      return false;
    }

    _statePtr = _alloc<_DInputState>(ffi.sizeOf<_DInputState>());
    if (!_acquire()) return false;
    debugPrint('[BPM][Gamepad] DirectInput 已就绪: "$_deviceProduct"');
    return true;
  }

  bool _acquire() {
    if (_device == ffi.nullptr) return false;
    final acquire = _slot<_Uint32Fn>(_device, _devAcquire).asFunction<_Uint32FnDart>();
    final hr = acquire(_device);
    if (hr != _diOk) {
      debugPrint('[BPM][Gamepad] Acquire 失败 hr=0x${_hex32(hr)}');
      return false;
    }
    _packet = 0;
    _lastSnapshot = <int>[];
    _hasBaseline = false;
    return true;
  }

  // ═══════════ 轮询 ═══════════

  @override
  GamepadFrame? poll() {
    final state = _statePtr;
    if (_device == ffi.nullptr || state == ffi.nullptr) return null;

    // Poll 对普通手柄返回 DI_NOEFFECT, 无害; 对缓冲/力反馈设备必需
    final pollFn = _slot<_Uint32Fn>(_device, _devPoll).asFunction<_Uint32FnDart>();
    pollFn(_device);

    final getState =
        _slot<_GetDeviceStateNative>(_device, _devGetDeviceState).asFunction<_GetDeviceStateDart>();
    final hr = getState(_device, ffi.sizeOf<_DInputState>(), state);
    if (hr != _diOk) {
      // 设备拔出或失去获取权: 尝试重新 Acquire, 失败即视为未连接
      if (!_acquire()) return null;
      return null;
    }

    final s = state.ref;
    final buttons = <int>[
      for (var i = 0; i < buttonCapacity; i++) s.buttons[i],
    ];
    final snapshot = <int>[
      s.lX, s.lY, s.lZ, s.lRx, s.lRy, s.lRz, s.pov,
      ...buttons,
    ];
    if (!_hasBaseline || !_listEquals(snapshot, _lastSnapshot)) {
      _lastSnapshot = snapshot;
      _hasBaseline = true;
      _packet++; // 状态变化才递增, 对齐 XInput 的 packet 语义
    }

    return mapRaw(
      packetNumber: _packet,
      lx: s.lX,
      ly: s.lY,
      lz: s.lZ,
      lrx: s.lRx,
      lry: s.lRy,
      lrz: s.lRz,
      pov: s.pov,
      buttons: buttons,
      product: _deviceProduct,
    );
  }

  // ═══════════ 原始状态 → 统一帧 (纯函数, 可单测) ═══════════

  /// 把 DirectInput 原始状态映射成与 XInput 同构的 [GamepadFrame]。
  ///
  /// [product] 用于查 [_buttonLayouts]; 缺省走标准 Xbox 布局。
  @visibleForTesting
  static GamepadFrame mapRaw({
    required int packetNumber,
    required int lx,
    required int ly,
    required int lz,
    required int lrx,
    required int lry,
    required int lrz,
    required int pov,
    required List<int> buttons,
    String product = '',
  }) {
    final layout = layoutFor(product);

    bool pressedAt(int slot) {
      if (slot >= layout.length) return false;
      final index = layout[slot];
      return index >= 0 && index < buttons.length && buttons[index] != 0;
    }

    var mask = 0;
    if (pressedAt(0)) mask |= XInputButtons.a;
    if (pressedAt(1)) mask |= XInputButtons.b;
    if (pressedAt(2)) mask |= XInputButtons.x;
    if (pressedAt(3)) mask |= XInputButtons.y;
    if (pressedAt(4)) mask |= XInputButtons.leftShoulder;
    if (pressedAt(5)) mask |= XInputButtons.rightShoulder;
    if (pressedAt(6)) mask |= XInputButtons.back;
    if (pressedAt(7)) mask |= XInputButtons.start;

    // POV (视角帽) 单位为百分之一度; 0xFFFFFFFF = 居中
    if (pov != _povCentered && pov <= 35999) {
      final deg = pov ~/ 100;
      if (deg >= 315 || deg < 45) mask |= XInputButtons.dpadUp;
      if (deg >= 45 && deg < 135) mask |= XInputButtons.dpadRight;
      if (deg >= 135 && deg < 225) mask |= XInputButtons.dpadDown;
      if (deg >= 225 && deg < 315) mask |= XInputButtons.dpadLeft;
    }

    return GamepadFrame(
      packetNumber: packetNumber,
      buttons: mask,
      thumbLX: lx,
      thumbLY: ly,
      thumbRX: lrx,
      thumbRY: lry,
      // DInput 把 L2/R2 放在 Z / Rz 轴 (有符号), 映射到 0..255 扳机量
      leftTrigger: _triggerFromAxis(lz),
      rightTrigger: _triggerFromAxis(lrz),
    );
  }

  static int _triggerFromAxis(int value) {
    if (value <= 0) return 0;
    return (value / _axisMax * 255).round().clamp(0, 255);
  }

  /// 产品名 → 按钮布局; 命中 [_buttonLayouts] 用覆盖值, 否则标准 Xbox 布局。
  static List<int> layoutFor(String product) {
    final lower = product.toLowerCase();
    for (final entry in _buttonLayouts.entries) {
      if (lower.contains(entry.key.toLowerCase())) return entry.value;
    }
    return _defaultLayout;
  }

  /// 标准 Xbox 布局: A/B/X/Y/LB/RB/Back/Start 对应的 DInput 按钮序号
  static const List<int> _defaultLayout = <int>[0, 1, 2, 3, 4, 5, 6, 7];

  /// 布局覆盖表: 产品名关键字 → 上表同序的按钮序号。
  ///
  /// ⚠️ 真机若发现某款手柄键位错位(典型: 部分 PS 手柄的 □△ 与 ×○ 顺序),
  /// 在此登记其产品名关键字与正确序号即可, 不必改映射主干。
  static const Map<String, List<int>> _buttonLayouts = <String, List<int>>{};

  // ═══════════ 数据格式 ═══════════

  /// 构建 DIDATAFORMAT (6 轴 + 1 POV + 16 按钮)
  ffi.Pointer<_DIDataFormat> _buildDataFormat() {
    const objectCount = 6 + 1 + buttonCapacity;
    final objects = _alloc<_DIObjectDataFormat>(
        ffi.sizeOf<_DIObjectDataFormat>() * objectCount);

    final axisSpecs = <_GuidSpec>[
      _guidAxisX,
      _guidAxisY,
      _guidAxisZ,
      _guidAxisRx,
      _guidAxisRy,
      _guidAxisRz,
    ];
    for (var i = 0; i < axisSpecs.length; i++) {
      final guid = _alloc<_GUID>(ffi.sizeOf<_GUID>());
      _writeGuid(guid.ref, axisSpecs[i]);
      // 🔴 必须用 (ptr + i).ref 写回 native 内存;
      // Pointer<Struct> 的 operator[] 返回的是**值**, 级联赋值不会落盘。
      (objects + i).ref
        ..pguid = guid
        ..dwOfs = i * 4
        ..dwType = _didftAxis | _didftAnyInstance | _didftOptional
        ..dwFlags = 0;
    }

    final povGuid = _alloc<_GUID>(ffi.sizeOf<_GUID>());
    _writeGuid(povGuid.ref, _guidPov);
    (objects + 6).ref
      ..pguid = povGuid
      ..dwOfs = _povOffset
      ..dwType = _didftPov | _didftAnyInstance | _didftOptional
      ..dwFlags = 0;

    for (var i = 0; i < buttonCapacity; i++) {
      (objects + 7 + i).ref
        ..pguid = ffi.nullptr
        ..dwOfs = _buttonOffset + i
        ..dwType = _didftButton | _didftAnyInstance | _didftOptional
        ..dwFlags = 0;
    }

    final format = _alloc<_DIDataFormat>(ffi.sizeOf<_DIDataFormat>());
    format.ref
      ..dwSize = ffi.sizeOf<_DIDataFormat>()
      ..dwObjSize = ffi.sizeOf<_DIObjectDataFormat>()
      ..dwFlags = _didfAbsAxis
      ..dwDataSize = ffi.sizeOf<_DInputState>()
      ..dwNumObjs = objectCount
      ..rgodf = objects;
    return format;
  }

  // ═══════════ 释放 ═══════════

  @override
  void dispose() {
    if (_device != ffi.nullptr) {
      final unacquire = _slot<_Uint32Fn>(_device, _devUnacquire).asFunction<_Uint32FnDart>();
      unacquire(_device);
      final release = _slot<_Uint32Fn>(_device, _iunknownRelease).asFunction<_Uint32FnDart>();
      release(_device);
      _device = ffi.nullptr;
    }
    if (_directInput != ffi.nullptr) {
      final release = _slot<_Uint32Fn>(_directInput, _iunknownRelease).asFunction<_Uint32FnDart>();
      release(_directInput);
      _directInput = ffi.nullptr;
    }
    _enumCallable?.close();
    _enumCallable = null;
    for (final p in _allocations) {
      calloc.free(p);
    }
    _allocations.clear();
    _enumResult = ffi.nullptr;
    _statePtr = ffi.nullptr;
  }

  // ═══════════ 工具 ═══════════

  /// 分配并登记 (统一在 dispose 释放)
  ffi.Pointer<T> _alloc<T extends ffi.NativeType>(int size) {
    final p = calloc<ffi.Uint8>(size);
    _allocations.add(p.cast<ffi.Void>());
    return p.cast<T>();
  }

  static ffi.Pointer<ffi.NativeFunction<N>> _slot<N extends Function>(
    ffi.Pointer<ffi.Void> instance,
    int index,
  ) {
    // COM 实例首字段 = vtable 指针; vtable 为函数指针数组。
    // 🔴 调用点必须 .asFunction<DartFn>() —— Dart 侧不能直接调用
    // Pointer<NativeFunction<T>>, 且 asFunction 的类型参数要求编译期常量,
    // 所以不能把 asFunction 收进泛型 helper 里。
    final vtablePtr = instance.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value;
    final slot = (vtablePtr + index).value;
    return slot.cast<ffi.NativeFunction<N>>();
  }

  static void _writeGuid(_GUID ref, _GuidSpec spec) {
    ref.data1 = spec.d1;
    ref.data2 = spec.d2;
    ref.data3 = spec.d3;
    for (var i = 0; i < 8; i++) {
      ref.data4[i] = spec.d4[i];
    }
  }

  static void _copyGuid(_GUID dst, _GUID src) {
    dst.data1 = src.data1;
    dst.data2 = src.data2;
    dst.data3 = src.data3;
    for (var i = 0; i < 8; i++) {
      dst.data4[i] = src.data4[i];
    }
  }

  static String _utf16(ffi.Array<ffi.Uint16> chars, int length) {
    final sb = StringBuffer();
    for (var i = 0; i < length; i++) {
      final c = chars[i];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex32(int v) =>
      (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();
}

// ═══════════════ 常量: GUID ═══════════════

class _GuidSpec {
  final int d1;
  final int d2;
  final int d3;
  final List<int> d4;

  const _GuidSpec(this.d1, this.d2, this.d3, this.d4);
}

const _GuidSpec _iidDirectInput8W = _GuidSpec(0xBF798031, 0x483A, 0x4DA2,
    <int>[0xAA, 0x99, 0x5D, 0x64, 0xED, 0x36, 0x97, 0x00]);

/// 轴/POV GUID 公共后缀 {…-C9F3-11CF-BFC7-444553540000}
const List<int> _axisSuffix = <int>[
  0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00,
];

const _GuidSpec _guidAxisX = _GuidSpec(0xA36D02E0, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidAxisY = _GuidSpec(0xA36D02E1, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidAxisZ = _GuidSpec(0xA36D02E2, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidAxisRx = _GuidSpec(0xA36D02F4, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidAxisRy = _GuidSpec(0xA36D02F5, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidAxisRz = _GuidSpec(0xA36D02E3, 0xC9F3, 0x11CF, _axisSuffix);
const _GuidSpec _guidPov = _GuidSpec(0xA36D02F2, 0xC9F3, 0x11CF, _axisSuffix);

// ═══════════════ Win32 结构体 ═══════════════

/// Windows GUID (16 字节)
final class _GUID extends ffi.Struct {
  @ffi.Uint32()
  external int data1;

  @ffi.Uint16()
  external int data2;

  @ffi.Uint16()
  external int data3;

  @ffi.Array(8)
  external ffi.Array<ffi.Uint8> data4;
}

/// DIDEVICEINSTANCEW
final class _DIDeviceInstance extends ffi.Struct {
  @ffi.Uint32()
  external int dwSize;

  external _GUID guidInstance;

  external _GUID guidProduct;

  @ffi.Uint32()
  external int dwDevType;

  @ffi.Array(260)
  external ffi.Array<ffi.Uint16> tszInstanceName;

  @ffi.Array(260)
  external ffi.Array<ffi.Uint16> tszProductName;

  external _GUID guidFFDriver;

  @ffi.Uint16()
  external int wUsagePage;

  @ffi.Uint16()
  external int wUsage;
}

/// DIOBJECTDATAFORMAT
final class _DIObjectDataFormat extends ffi.Struct {
  external ffi.Pointer<_GUID> pguid;

  @ffi.Uint32()
  external int dwOfs;

  @ffi.Uint32()
  external int dwType;

  @ffi.Uint32()
  external int dwFlags;
}

/// DIDATAFORMAT
final class _DIDataFormat extends ffi.Struct {
  @ffi.Uint32()
  external int dwSize;

  @ffi.Uint32()
  external int dwObjSize;

  @ffi.Uint32()
  external int dwFlags;

  @ffi.Uint32()
  external int dwDataSize;

  @ffi.Uint32()
  external int dwNumObjs;

  external ffi.Pointer<_DIObjectDataFormat> rgodf;
}

/// 自建手柄状态 (偏移须与 [_buildDataFormat] 一致): 44 字节
final class _DInputState extends ffi.Struct {
  @ffi.Int32()
  external int lX;

  @ffi.Int32()
  external int lY;

  @ffi.Int32()
  external int lZ;

  @ffi.Int32()
  external int lRx;

  @ffi.Int32()
  external int lRy;

  @ffi.Int32()
  external int lRz;

  @ffi.Uint32()
  external int pov;

  @ffi.Array(16)
  external ffi.Array<ffi.Uint8> buttons;
}

// ═══════════════ FFI 函数签名 ═══════════════

typedef _DirectInput8CreateNative = ffi.Int32 Function(
    ffi.IntPtr,
    ffi.Uint32,
    ffi.Pointer<_GUID>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>,
    ffi.Pointer<ffi.Void>);
typedef _DirectInput8CreateDart = int Function(int, int, ffi.Pointer<_GUID>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>, ffi.Pointer<ffi.Void>);

typedef _GetModuleHandleNative = ffi.IntPtr Function(ffi.Pointer<ffi.Uint16>);
typedef _GetModuleHandleDart = int Function(ffi.Pointer<ffi.Uint16>);

typedef _GetDesktopWindowNative = ffi.IntPtr Function();
typedef _GetDesktopWindowDart = int Function();

typedef _EnumDevicesCbNative = ffi.Int32 Function(
    ffi.Pointer<_DIDeviceInstance>, ffi.Pointer<ffi.Void>);

typedef _EnumDevicesNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Uint32,
    ffi.Pointer<ffi.NativeFunction<_EnumDevicesCbNative>>,
    ffi.Pointer<ffi.Void>,
    ffi.Uint32);

typedef _CreateDeviceNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<_GUID>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>,
    ffi.Pointer<ffi.Void>);

typedef _SetDataFormatNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<_DIDataFormat>);

typedef _SetCooperativeLevelNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.IntPtr, ffi.Uint32);

typedef _GetDeviceStateNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<_DInputState>);

/// 无参单指针的 HRESULT 方法 (Acquire / Unacquire / Poll) 及
/// IUnknown::Release (返回 ULONG, 参数形状相同)
typedef _Uint32Fn = ffi.Uint32 Function(ffi.Pointer<ffi.Void>);

// ═══════════════ Dart 侧函数类型 (经 asFunction 转换后调用) ═══════════════

typedef _EnumDevicesDart = int Function(
    ffi.Pointer<ffi.Void>,
    int,
    ffi.Pointer<ffi.NativeFunction<_EnumDevicesCbNative>>,
    ffi.Pointer<ffi.Void>,
    int);

typedef _CreateDeviceDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<_GUID>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>,
    ffi.Pointer<ffi.Void>);

typedef _SetDataFormatDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<_DIDataFormat>);

typedef _SetCooperativeLevelDart = int Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _GetDeviceStateDart = int Function(
    ffi.Pointer<ffi.Void>, int, ffi.Pointer<_DInputState>);

typedef _Uint32FnDart = int Function(ffi.Pointer<ffi.Void>);
