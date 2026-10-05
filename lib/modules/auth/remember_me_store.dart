import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';

/// 「记住登录」凭证存储（2026-10-03）。
///
/// 用途：token 过期（超过服务端 authDuration，如长期未打开软件）后，
/// [AuthService.checkAutoLogin] 用记住的邮箱+密码静默重登，用户无感；
/// 登录界面提供「快速登录」一键入口。
///
/// 安全设计：
/// - **Windows DPAPI**（advapi32 CryptProtectData）加密，密文绑定当前
///   Windows 用户——data/ 目录拷到别的机器/别的用户账户无法解密；
/// - 附加应用熵 `ChronoTide.Auth.v1`：其他进程即便在同一用户下调用
///   DPAPI，熵不同也解不开（Chrome 存密码同款思路）；
/// - 明文密码**永不写日志**；非 Windows / FFI 失败 / 解密失败 → 静默
///   返回 null，永不抛异常打断登录流程（降级为普通登录路径）。
class RememberMeStore {
  RememberMeStore._();

  /// 凭证文件（DPAPI 密文二进制）。落 data/prefs/，随便携化目录体系。
  static String get _filePath => p.join(PathHelper.prefsDir, 'remember_me.bin');

  /// 应用熵：参与密钥派生，不同应用/版本之间密文不可互解。
  static const String _entropy = 'ChronoTide.Auth.v1';

  // 缓存 DPAPI 函数指针（进程内只查找一次）
  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final _CryptProtectDataDart _protect = _advapi32.lookupFunction<
      Int32 Function(Pointer<_Blob>, Pointer<Uint16>, Pointer<_Blob>,
          Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>),
      int Function(Pointer<_Blob>, Pointer<Uint16>, Pointer<_Blob>,
          Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>)>(
      'CryptProtectData');
  static final _CryptUnprotectDataDart _unprotect = _advapi32.lookupFunction<
      Int32 Function(Pointer<_Blob>, Pointer<Pointer<Uint16>>,
          Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>),
      int Function(Pointer<_Blob>, Pointer<Pointer<Uint16>>, Pointer<_Blob>,
          Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>)>(
      'CryptUnprotectData');
  static final _LocalFreeDart _localFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  static const int _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  /// 是否已有记住的凭证（文件存在即视为有；解密失败由 [load] 兜底）。
  static bool has() {
    try {
      return File(_filePath).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 保存凭证（DPAPI 加密后落盘）。成功 true；失败 false（静默降级）。
  static Future<bool> save(String email, String password) async {
    if (!Platform.isWindows || email.isEmpty || password.isEmpty) {
      return false;
    }
    Pointer<_Blob>? inBlob;
    Pointer<Uint8>? inData;
    Pointer<_Blob>? entropyBlob;
    Pointer<Utf16>? entropy;
    Pointer<_Blob>? outBlob;
    try {
      final payload = jsonEncode({
        'email': email,
        'pwd': password,
        't': DateTime.now().millisecondsSinceEpoch,
      });
      final plain = Uint8List.fromList(utf8.encode(payload));

      inData = malloc<Uint8>(plain.length);
      inData.asTypedList(plain.length).setAll(0, plain);
      inBlob = malloc<_Blob>();
      inBlob.ref.cbData = plain.length;
      inBlob.ref.pbData = inData;

      final ent = _entropy.toNativeUtf16();
      entropy = ent;
      entropyBlob = malloc<_Blob>();
      entropyBlob.ref.cbData = _entropy.length * 2; // utf16 字节数
      entropyBlob.ref.pbData = ent.cast<Uint8>();

      outBlob = malloc<_Blob>();
      outBlob.ref.cbData = 0;
      outBlob.ref.pbData = nullptr;

      final ok = _protect(inBlob, nullptr, entropyBlob, nullptr, nullptr,
          _uiForbidden, outBlob);
      if (ok == 0 || outBlob.ref.pbData == nullptr) {
        debugPrint('[REMEMBER] ⚠️ DPAPI 加密失败 (exit=$ok)');
        return false;
      }
      final encrypted =
          Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      _localFree(outBlob.ref.pbData.cast());
      outBlob.ref.pbData = nullptr;

      final dir = Directory(PathHelper.prefsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(_filePath).writeAsBytesSync(encrypted, flush: true);
      debugPrint(
          '[REMEMBER] ✅ 凭证已加密保存 | email=${_maskEmail(email)} (${encrypted.length}B)');
      return true;
    } catch (e) {
      debugPrint('[REMEMBER] ⚠️ 保存凭证异常: $e');
      return false;
    } finally {
      _freeAll(inBlob: inBlob, inData: inData, entropyBlob: entropyBlob,
          entropy: entropy, outBlob: outBlob);
    }
  }

  /// 读取凭证。解密失败/损坏/非本机 → null（调用方走普通登录）。
  static Future<RememberedCredentials?> load() async {
    if (!Platform.isWindows) return null;
    Pointer<_Blob>? inBlob;
    Pointer<Uint8>? inData;
    Pointer<_Blob>? entropyBlob;
    Pointer<Utf16>? entropy;
    Pointer<_Blob>? outBlob;
    try {
      final f = File(_filePath);
      if (!f.existsSync()) return null;
      final encrypted = f.readAsBytesSync();
      if (encrypted.isEmpty) return null;

      inData = malloc<Uint8>(encrypted.length);
      inData.asTypedList(encrypted.length).setAll(0, encrypted);
      inBlob = malloc<_Blob>();
      inBlob.ref.cbData = encrypted.length;
      inBlob.ref.pbData = inData;

      final ent = _entropy.toNativeUtf16();
      entropy = ent;
      entropyBlob = malloc<_Blob>();
      entropyBlob.ref.cbData = _entropy.length * 2;
      entropyBlob.ref.pbData = ent.cast<Uint8>();

      outBlob = malloc<_Blob>();
      outBlob.ref.cbData = 0;
      outBlob.ref.pbData = nullptr;

      final ok = _unprotect(inBlob, nullptr, entropyBlob, nullptr, nullptr,
          _uiForbidden, outBlob);
      if (ok == 0 || outBlob.ref.pbData == nullptr) {
        debugPrint('[REMEMBER] ⚠️ DPAPI 解密失败 (exit=$ok)——非本机或已损坏');
        return null;
      }
      final plain = utf8.decode(
          Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData)),
          allowMalformed: true);
      _localFree(outBlob.ref.pbData.cast());
      outBlob.ref.pbData = nullptr;

      final json = jsonDecode(plain) as Map<String, dynamic>;
      final email = (json['email'] ?? '').toString();
      final pwd = (json['pwd'] ?? '').toString();
      if (email.isEmpty || pwd.isEmpty) return null;
      debugPrint('[REMEMBER] ✅ 凭证读取成功 | email=${_maskEmail(email)}');
      return RememberedCredentials(email: email, password: pwd);
    } catch (e) {
      debugPrint('[REMEMBER] ⚠️ 读取凭证异常: $e');
      return null;
    } finally {
      _freeAll(inBlob: inBlob, inData: inData, entropyBlob: entropyBlob,
          entropy: entropy, outBlob: outBlob);
    }
  }

  /// 清除记住的凭证（登出 / 凭证失效时）。
  static Future<void> clear() async {
    try {
      final f = File(_filePath);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 统一释放所有可能已分配的原生内存（finally 双保险，防泄漏）。
  static void _freeAll({
    Pointer<_Blob>? inBlob,
    Pointer<Uint8>? inData,
    Pointer<_Blob>? entropyBlob,
    Pointer<Utf16>? entropy,
    Pointer<_Blob>? outBlob,
  }) {
    try {
      if (outBlob != null && outBlob.ref.pbData != nullptr) {
        _localFree(outBlob.ref.pbData.cast());
      }
    } catch (_) {}
    try {
      if (inData != null) malloc.free(inData);
      if (inBlob != null) malloc.free(inBlob);
      if (entropyBlob != null) malloc.free(entropyBlob);
      if (entropy != null) malloc.free(entropy);
      if (outBlob != null) malloc.free(outBlob);
    } catch (_) {}
  }

  /// 日志脱敏：a***@qq.com
  static String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 0) return '***';
    return '${email.substring(0, 1)}***${email.substring(at)}';
  }
}

/// 记住的凭证（内存态，仅存在于解密瞬间之后）。
class RememberedCredentials {
  final String email;
  final String password;
  const RememberedCredentials({required this.email, required this.password});
}

/// DATA_BLOB（Win32）：{ DWORD cbData; BYTE* pbData; }
/// 64 位下 4+4(padding)+8=16 字节，与 C ABI 布局一致。
final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataDart = int Function(
    Pointer<_Blob> pDataIn,
    Pointer<Uint16> szDataDescr,
    Pointer<_Blob> pOptionalEntropy,
    Pointer<Void> pvReserved,
    Pointer<Void> pPromptStruct,
    int dwFlags,
    Pointer<_Blob> pDataOut);

typedef _CryptUnprotectDataDart = int Function(
    Pointer<_Blob> pDataIn,
    Pointer<Pointer<Uint16>> ppszDataDescr,
    Pointer<_Blob> pOptionalEntropy,
    Pointer<Void> pvReserved,
    Pointer<Void> pPromptStruct,
    int dwFlags,
    Pointer<_Blob> pDataOut);

typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> hMem);
