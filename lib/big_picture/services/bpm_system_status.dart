import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 电池状态快照 (v3.5 BPM 头部栏系统状态区)
class BpmBatteryStatus {
  /// 是否读到有效数据 (非 Windows / 台式机无电池 / 读取失败 → false)
  final bool available;

  /// 电量百分比 0-100 (-1 = 未知)
  final int percent;

  /// 是否已接电源
  final bool pluggedIn;

  const BpmBatteryStatus({
    this.available = false,
    this.percent = -1,
    this.pluggedIn = false,
  });

  static const BpmBatteryStatus unavailable = BpmBatteryStatus();
}

/// BPM 系统状态服务 (v3.5)
///
/// 为头部栏的「系统状态区」提供当前时间与电池状态:
/// - 时间: 每 20s 一跳 (分钟粒度足够,避免秒级重建)
/// - 电池: 调 Win32 `GetSystemPowerStatus` (kernel32),**零新增依赖**
///   (项目 `pubspec.yaml` 已含 `ffi`); 非 Windows/无电池/读取失败一律
///   返回 [BpmBatteryStatus.unavailable],头部栏退化为只显示时间。
///
/// 生命周期: [start] / [stop] 由 `BigPictureShell` 在挂载/卸载时调用,
/// 避免大屏模式不在前台时空跑定时器。
class BpmSystemStatus extends ChangeNotifier {
  BpmSystemStatus._();
  static final BpmSystemStatus instance = BpmSystemStatus._();

  /// 刷新间隔 (时间 + 电池共用一次 tick)
  static const Duration _tick = Duration(seconds: 20);

  Timer? _timer;
  DateTime _now = DateTime.now();
  BpmBatteryStatus _battery = BpmBatteryStatus.unavailable;

  /// 当前时间 (供头部栏格式化)
  DateTime get now => _now;

  /// 当前电池状态
  BpmBatteryStatus get battery => _battery;

  bool get isRunning => _timer != null;

  /// 启动周期刷新 (幂等)
  void start() {
    if (_timer != null) return;
    _now = DateTime.now();
    _battery = _readBattery();
    _timer = Timer.periodic(_tick, (_) => _refresh());
    notifyListeners();
  }

  /// 停止刷新
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 立即刷新一次 (供手动触发)
  void refresh() => _refresh();

  void _refresh() {
    _now = DateTime.now();
    _battery = _readBattery();
    notifyListeners();
  }

  // ============ Win32 电池读取 ============

  static _GetSystemPowerStatusDart? _nativeGet;

  static _GetSystemPowerStatusDart? _resolveNative() {
    if (_nativeGet != null) return _nativeGet;
    if (!Platform.isWindows) return null;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _nativeGet = kernel32
          .lookupFunction<_GetSystemPowerStatusC, _GetSystemPowerStatusDart>(
        'GetSystemPowerStatus',
      );
      return _nativeGet;
    } catch (e) {
      debugPrint('[BPM] GetSystemPowerStatus 解析失败(忽略): $e');
      return null;
    }
  }

  static BpmBatteryStatus _readBattery() {
    final fn = _resolveNative();
    if (fn == null) return BpmBatteryStatus.unavailable;
    Pointer<_SystemPowerStatus>? ptr;
    try {
      ptr = calloc<_SystemPowerStatus>();
      final ok = fn(ptr);
      if (ok == 0) return BpmBatteryStatus.unavailable;
      final s = ptr.ref;
      // BatteryFlag: 128 = 无系统电池, 255 = 未知
      final flag = s.batteryFlag;
      if (flag == 128 || flag == 255) return BpmBatteryStatus.unavailable;
      // BatteryLifePercent: 255 = 未知
      final raw = s.batteryLifePercent;
      final percent = (raw <= 100) ? raw : -1;
      if (percent < 0) return BpmBatteryStatus.unavailable;
      // ACLineStatus: 0 = 未接电源, 1 = 已接电源
      return BpmBatteryStatus(
        available: true,
        percent: percent,
        pluggedIn: s.acLineStatus == 1,
      );
    } catch (e) {
      debugPrint('[BPM] 读取电池状态失败(忽略): $e');
      return BpmBatteryStatus.unavailable;
    } finally {
      if (ptr != null) calloc.free(ptr);
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// Win32 SYSTEM_POWER_STATUS
///
/// ```c
/// typedef struct _SYSTEM_POWER_STATUS {
///   BYTE  ACLineStatus;
///   BYTE  BatteryFlag;
///   BYTE  BatteryLifePercent;
///   BYTE  SystemStatusFlag;
///   DWORD BatteryLifeTime;
///   DWORD BatteryFullLifeTime;
/// } SYSTEM_POWER_STATUS;
/// ```
/// Dart FFI 按目标平台 C ABI 自动补齐对齐, 4×BYTE + 2×DWORD 布局与 C 一致。
final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;

  @Uint8()
  external int batteryFlag;

  @Uint8()
  external int batteryLifePercent;

  @Uint8()
  external int systemStatusFlag;

  @Uint32()
  external int batteryLifeTime;

  @Uint32()
  external int batteryFullLifeTime;
}

typedef _GetSystemPowerStatusC = Int32 Function(
    Pointer<_SystemPowerStatus> status);
typedef _GetSystemPowerStatusDart = int Function(
    Pointer<_SystemPowerStatus> status);
