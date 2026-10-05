/// Windows DPAPI 加解密助手 —— 云备份凭据的落盘保护（方案 §7 Phase 5）。
///
/// 🔴 背景与红线（Q10 修正后设计）：
/// - LunaBox 的 S3/OneDrive 凭据是**明文 JSON**（反面教材，明确不学）；
///   本项目的 WebDAV/S3 凭据**必须**经 DPAPI 加密后才能落盘。
/// - DPAPI（`crypt32!CryptProtectData`）绑定**当前 Windows 用户**：同一用户
///   无需密钥管理即可解密，其他用户/拷到别的机器解不开 —— 正好匹配
///   「本机应用存本机凭据」的威胁模型，无需自己管密钥。
///
/// 技术路径与 [RecycleBinService] 同款先例：纯 Dart + FFI 直调系统 DLL，
/// **刻意不 import flutter**，dev_probe 可直接加载实测。
///
/// 用法：
/// ```dart
/// final cipher = DpapiHelper.protect(utf8.encode('secret')); // 抛异常即失败
/// final plain  = DpapiHelper.unprotect(cipher);
/// ```
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Win32 常量与结构
// ---------------------------------------------------------------------------

/// CRYPTPROTECT_UI_FORBIDDEN：服务/后台场景必备，禁止弹任何 UI。
const int _cryptprotectUiForbidden = 0x1;

/// CRYPTPROTECT_LOCAL_MACHINE：未用（我们绑定当前用户，默认 per-user）。

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData; // 字节数

  external Pointer<Uint8> pbData; // 数据指针
}

typedef _CryptProtectDataNative = Int32 Function(
    Pointer<_DataBlob> pDataIn,
    Pointer<Uint16> szDataDescr,
    Pointer<Void> pOptionalEntropy,
    Pointer<Void> pvReserved,
    Pointer<Void> pPromptStruct,
    Uint32 dwFlags,
    Pointer<_DataBlob> pDataOut);
typedef _CryptProtectDataDart = int Function(
    Pointer<_DataBlob>,
    Pointer<Uint16>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);

typedef _CryptUnprotectDataNative = Int32 Function(
    Pointer<_DataBlob> pDataIn,
    Pointer<Pointer<Uint16>> ppszDataDescr,
    Pointer<Void> pOptionalEntropy,
    Pointer<Void> pvReserved,
    Pointer<Void> pPromptStruct,
    Uint32 dwFlags,
    Pointer<_DataBlob> pDataOut);
typedef _CryptUnprotectDataDart = int Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Uint16>>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);

final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');

final _CryptProtectDataDart _protect = _crypt32
    .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
        'CryptProtectData');

final _CryptUnprotectDataDart _unprotect = _crypt32
    .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
        'CryptUnprotectData');

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

class DpapiException implements Exception {
  final String message;
  final int? win32Error;
  DpapiException(this.message, [this.win32Error]);

  @override
  String toString() => 'DpapiException: $message'
      '${win32Error != null ? ' (GetLastError=$win32Error)' : ''}';
}

class DpapiHelper {
  DpapiHelper._();

  /// 加密：明文字节 → DPAPI 密文字节。失败抛 [DpapiException]。
  static Uint8List protect(List<int> plain) {
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    final plainPtr = calloc<Uint8>(plain.length);
    try {
      plainPtr.asTypedList(plain.length).setAll(0, plain);
      inBlob.ref.cbData = plain.length;
      inBlob.ref.pbData = plainPtr;

      // 描述串用宽字符「ChronoTide cloud credential」（仅备注用途）
      final descr = ('ChronoTide cloud credential').toNativeUtf16();

      final ret = _protect(inBlob, descr.cast<Uint16>(), nullptr, nullptr,
          nullptr, _cryptprotectUiForbidden, outBlob);
      calloc.free(descr);
      if (ret == 0) {
        throw DpapiException('CryptProtectData 失败', GetLastError());
      }
      return Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
    } finally {
      if (outBlob.ref.pbData != nullptr) LocalFree(outBlob.ref.pbData.cast());
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(plainPtr);
    }
  }

  /// 解密：DPAPI 密文字节 → 明文字节。失败抛 [DpapiException]
  /// （典型：换了 Windows 用户 / 换机器 —— 凭据归属本人，属预期保护）。
  static Uint8List unprotect(List<int> cipher) {
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    final descrOut = calloc<Pointer<Uint16>>();
    final cipherPtr = calloc<Uint8>(cipher.length);
    try {
      cipherPtr.asTypedList(cipher.length).setAll(0, cipher);
      inBlob.ref.cbData = cipher.length;
      inBlob.ref.pbData = cipherPtr;

      final ret = _unprotect(inBlob, descrOut, nullptr, nullptr, nullptr,
          _cryptprotectUiForbidden, outBlob);
      if (ret == 0) {
        throw DpapiException('CryptUnprotectData 失败', GetLastError());
      }
      return Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
    } finally {
      if (descrOut.value != nullptr) LocalFree(descrOut.value.cast());
      if (outBlob.ref.pbData != nullptr) LocalFree(outBlob.ref.pbData.cast());
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(descrOut);
      calloc.free(cipherPtr);
    }
  }

  /// 便捷封装：加密后 base64（直接可落 prefs/JSON）。
  static String protectToBase64(String plain) =>
      base64Encode(protect(utf8.encode(plain)));

  /// 便捷封装：base64 密文 → 明文字符串。
  static String unprotectFromBase64(String cipherB64) =>
      utf8.decode(unprotect(base64Decode(cipherB64)));
}

// GetLastError 在 kernel32 —— 按需惰性查找，避免顶层体积
int GetLastError() {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final f = k32.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError');
  return f();
}

void LocalFree(Pointer<Void> p) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final f =
      k32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void>
          Function(Pointer<Void>)>('LocalFree');
  f(p);
}
