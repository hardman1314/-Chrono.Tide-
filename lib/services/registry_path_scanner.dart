import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 注册表旧路径引用只读扫描器（零依赖 FFI 直调 advapi32.dll）。
///
/// 用途：游戏目录迁移完成后，**只读**扫描注册表中仍引用旧路径的字符串值，
/// 向用户报告（不自动改写——注册表误改不可逆，方案 §3.3 用户已拍板）。
///
/// 扫描范围（行业可靠位置范式 + HKCU 全树）：
/// - `HKCU\Software` 全树（包含其下的 Uninstall / App Paths 等子树）
/// - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
/// - `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`
/// - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths`
///
/// 仅匹配 REG_SZ / REG_EXPAND_SZ 值内容（大小写不敏感包含旧路径归一化串）。
/// 防护：深度上限 / 键数上限 / 超时（默认 30s）/ advapi32 加载失败静默降级。
/// 在 isolate 内执行，不阻塞 UI。
class RegistryPathScanner {
  RegistryPathScanner._();

  // ---- Win32 常量 ----
  static const int _kHKCU = 0x80000001;
  static const int _kHKLM = 0x80000002;
  static const int _keyRead = 0x20019;
  static const int _regSz = 1;
  static const int _regExpandSz = 2;
  static const int _errorSuccess = 0;
  static const int _errorNoMoreItems = 259;
  static const int _maxDepth = 10;

  /// 扫描引用了 [oldPath] 的注册表值。
  ///
  /// 返回 [RegistryScanReport]；advapi32 不可用时 available=false 且 hits 为空。
  static Future<RegistryScanReport> scanOldPathReferences({
    required String oldPath,
    Duration timeout = const Duration(seconds: 30),
    int maxKeys = 5000,
  }) async {
    if (oldPath.trim().isEmpty) {
      return const RegistryScanReport(available: false, error: '旧路径为空');
    }
    try {
      return await Isolate.run(() => _scanSync(
            oldPath: oldPath,
            deadline: DateTime.now().add(timeout),
            maxKeys: maxKeys,
          ));
    } catch (e) {
      debugPrint('[REG-SCAN] 扫描异常（降级为空报告）: $e');
      return RegistryScanReport(available: false, error: e.toString());
    }
  }

  static RegistryScanReport _scanSync({
    required String oldPath,
    required DateTime deadline,
    required int maxKeys,
  }) {
    final hits = <RegistryPathHit>[];
    int scannedKeys = 0;
    bool truncated = false;
    String? error;

    DynamicLibrary? advapi32;
    try {
      advapi32 = DynamicLibrary.open('advapi32.dll');
    } catch (e) {
      return RegistryScanReport(available: false, error: 'advapi32.dll 加载失败: $e');
    }

    final regOpenKeyExW = advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Uint32, Int32, Pointer<IntPtr>),
        int Function(int, Pointer<Uint16>, int, int, Pointer<IntPtr>)>(
        'RegOpenKeyExW');
    final regEnumKeyW = advapi32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Uint16>, Pointer<Uint32>),
        int Function(int, int, Pointer<Uint16>, Pointer<Uint32>)>(
        'RegEnumKeyW');
    final regCloseKey = advapi32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

    final needle = _normalize(oldPath);
    final roots = <(String, int, String)>[
      ('HKCU', _kHKCU, r'Software'),
      ('HKLM', _kHKLM, r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'),
      (
        'HKLM',
        _kHKLM,
        r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
      ),
      ('HKLM', _kHKLM, r'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'),
    ];

    void scanRecursive(String hiveLabel, int hive, String subKey, int depth) {
      if (truncated) return;
      if (DateTime.now().isAfter(deadline)) {
        truncated = true;
        return;
      }
      if (scannedKeys >= maxKeys) {
        truncated = true;
        return;
      }

      final phKey = calloc<IntPtr>();
      final subKeyPtr = subKey.toNativeUtf16();
      int hKey = 0;
      try {
        if (regOpenKeyExW(hive, subKeyPtr.cast(), 0, _keyRead, phKey) !=
            _errorSuccess) {
          return; // 打不开（权限/不存在）→ 静默跳过
        }
        hKey = phKey.value;
        scannedKeys++;

        // 枚举当前键的值，匹配字符串内容
        _scanValues(hKey, hiveLabel, subKey, needle, hits);

        // 递归子键
        if (depth < _maxDepth) {
          var index = 0;
          while (true) {
            if (truncated) return;
            final nameBuf = calloc<Uint16>(256);
            final nameLen = calloc<Uint32>()..value = 256;
            try {
              final rc = regEnumKeyW(hKey, index, nameBuf.cast(), nameLen);
              if (rc == _errorNoMoreItems) break;
              if (rc != _errorSuccess) break;
              final child = String.fromCharCodes(
                  nameBuf.asTypedList(nameLen.value).where((b) => b != 0));
              scanRecursive(
                  hiveLabel, hive, subKey.isEmpty ? child : '$subKey\\$child',
                  depth + 1);
              index++;
            } finally {
              calloc.free(nameBuf);
              calloc.free(nameLen);
            }
          }
        }
      } finally {
        if (hKey != 0) regCloseKey(hKey);
        calloc.free(phKey);
        calloc.free(subKeyPtr);
      }
    }

    try {
      for (final (label, hive, sub) in roots) {
        scanRecursive(label, hive, sub, 0);
        if (truncated) break;
      }
    } catch (e) {
      error = e.toString();
    }

    return RegistryScanReport(
      available: true,
      hits: hits,
      scannedKeys: scannedKeys,
      truncated: truncated,
      error: error,
    );
  }

  /// 枚举 [hKey] 下的 REG_SZ / REG_EXPAND_SZ 值，内容含 [needle] 即记录
  static void _scanValues(int hKey, String hiveLabel, String keyPath,
      String needle, List<RegistryPathHit> hits) {
    final regEnumValueW = DynamicLibrary.open('advapi32.dll').lookupFunction<
        Int32 Function(
            IntPtr,
            Uint32,
            Pointer<Uint16>,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint8>,
            Pointer<Uint32>),
        int Function(int, int, Pointer<Uint16>, Pointer<Uint32>, Pointer<Uint32>,
            Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)>('RegEnumValueW');

    var index = 0;
    while (true) {
      final vName = calloc<Uint16>(512);
      final vNameLen = calloc<Uint32>()..value = 512;
      final vType = calloc<Uint32>();
      final vSize = calloc<Uint32>()..value = 4096;
      final vBuf = calloc<Uint8>(4096);
      try {
        final rc = regEnumValueW(hKey, index, vName, vNameLen, nullptr, vType,
            vBuf, vSize);
        if (rc == _errorNoMoreItems) break;
        if (rc != _errorSuccess) break;
        final type = vType.value;
        if (type == _regSz || type == _regExpandSz) {
          final name = String.fromCharCodes(
              vName.asTypedList(vNameLen.value).where((b) => b != 0));
          final data = String.fromCharCodes(
                  vBuf.asTypedList(vSize.value).where((b) => b != 0))
              .replaceAll('\x00', '');
          if (data.isNotEmpty && _normalize(data).contains(needle)) {
            hits.add(RegistryPathHit(
              hiveLabel: hiveLabel,
              keyPath: keyPath,
              valueName: name,
              valueData: data,
            ));
          }
        }
        index++;
      } finally {
        calloc.free(vName);
        calloc.free(vNameLen);
        calloc.free(vType);
        calloc.free(vSize);
        calloc.free(vBuf);
      }
    }
  }

  static String _normalize(String s) {
    var n = s.replaceAll('/', '\\').toLowerCase();
    while (n.endsWith('\\')) {
      n = n.substring(0, n.length - 1);
    }
    return n;
  }
}

/// 一条命中记录（只读报告，不自动改写）
class RegistryPathHit {
  final String hiveLabel;
  final String keyPath;
  final String valueName;
  final String valueData;

  const RegistryPathHit({
    required this.hiveLabel,
    required this.keyPath,
    required this.valueName,
    required this.valueData,
  });

  String get displayPath => '$hiveLabel\\$keyPath';
}

/// 扫描报告
class RegistryScanReport {
  /// advapi32 是否可用（false 时 hits 恒为空）
  final bool available;
  final List<RegistryPathHit> hits;
  final int scannedKeys;

  /// true = 达到超时/数量上限提前截断（结果不完整）
  final bool truncated;
  final String? error;

  const RegistryScanReport({
    required this.available,
    this.hits = const [],
    this.scannedKeys = 0,
    this.truncated = false,
    this.error,
  });
}
