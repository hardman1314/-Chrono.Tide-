import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pffi;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../utils/network_path.dart';

class PathValidator {
  static const int maxPathLength = 260;

  /// 网络路径（UNC / 映射网络驱动器）长度上限（★ 2026-09-26）
  ///
  /// UNC 形式 `\\host\share\...` 天然比等价的盘符形式长，深层目录很容易
  /// 超过本地 260 上限而被**误判为非法路径**；本地盘的 260 上限保持逐字不变，
  /// 仅对网络路径放宽（超限时仍照实报错，不会静默截断）。
  static const int maxNetworkPathLength = 1024;

  static final _illegalChars = RegExp(r'[<>"|?*]');

  /// 该路径适用的长度上限
  static int _maxLengthFor(String p) =>
      NetworkPath.isNetwork(p) ? maxNetworkPathLength : maxPathLength;

  static ValidationResult validateCustomGameLocation(String? location) {
    if (location == null || location.trim().isEmpty) {
      return ValidationResult(
        isValid: false,
        errorCode: 'EMPTY_PATH',
        message: '安装路径不能为空',
      );
    }

    final trimmedPath = location.trim();

    final fileNamePart = path.basename(trimmedPath);
    if (fileNamePart.contains(_illegalChars)) {
      return ValidationResult(
        isValid: false,
        errorCode: 'ILLEGAL_CHARS',
        message: '路径包含非法字符 (<>"|?*)',
      );
    }

    final lengthLimit = _maxLengthFor(trimmedPath);
    if (trimmedPath.length > lengthLimit) {
      return ValidationResult(
        isValid: false,
        errorCode: 'PATH_TOO_LONG',
        message: '路径过长（超过$lengthLimit字符）',
      );
    }

    if (_isSystemDirectory(trimmedPath)) {
      return ValidationResult(
        isValid: false,
        errorCode: 'SYSTEM_DIR',
        message: '不能使用系统目录作为安装路径',
      );
    }

    try {
      final dir = Directory(trimmedPath);
      bool exists = dir.existsSync();
      bool writable = true;

      if (!exists) {
        try {
          dir.createSync(recursive: true);
          exists = true;
        } catch (e) {
          return ValidationResult(
            isValid: false,
            errorCode: 'CREATE_FAILED',
            message: '无法创建目录: $e',
          );
        }
      }

      if (exists) {
        final testFile = File(
            '$trimmedPath\\.write_test_${DateTime.now().millisecondsSinceEpoch}');
        try {
          testFile.writeAsStringSync('test');
          if (testFile.existsSync()) {
            testFile.deleteSync();
          }
        } catch (e) {
          writable = false;
        }
      }

      if (!writable) {
        return ValidationResult(
          isValid: false,
          errorCode: 'NO_PERMISSION',
          message: '没有写入权限，请选择其他目录',
        );
      }

      return ValidationResult(
        isValid: true,
        errorCode: '',
        message: trimmedPath,
      );
    } catch (e) {
      return ValidationResult(
        isValid: false,
        errorCode: 'UNKNOWN_ERROR',
        message: '路径验证失败: $e',
      );
    }
  }

  /// 校验已存在的游戏目录（用于"更换游戏目录"场景）。
  ///
  /// 与 [validateCustomGameLocation] 的关键差异：
  /// - **不创建目录**：要求目录已存在（用户已在资源管理器里手动挪过去）
  /// - **不做写入权限测试**：relink 只改软件引用，不写该目录
  /// - 其余校验（空/非法字符/长度/系统目录）保持一致
  static ValidationResult validateExistingGameLocation(String? location) {
    if (location == null || location.trim().isEmpty) {
      return ValidationResult(
        isValid: false,
        errorCode: 'EMPTY_PATH',
        message: '安装路径不能为空',
      );
    }

    final trimmedPath = location.trim();

    final fileNamePart = path.basename(trimmedPath);
    if (fileNamePart.contains(_illegalChars)) {
      return ValidationResult(
        isValid: false,
        errorCode: 'ILLEGAL_CHARS',
        message: '路径包含非法字符 (<>"|?*)',
      );
    }

    final lengthLimit = _maxLengthFor(trimmedPath);
    if (trimmedPath.length > lengthLimit) {
      return ValidationResult(
        isValid: false,
        errorCode: 'PATH_TOO_LONG',
        message: '路径过长（超过$lengthLimit字符）',
      );
    }

    if (_isSystemDirectory(trimmedPath)) {
      return ValidationResult(
        isValid: false,
        errorCode: 'SYSTEM_DIR',
        message: '不能使用系统目录作为游戏路径',
      );
    }

    try {
      final dir = Directory(trimmedPath);
      if (!dir.existsSync()) {
        return ValidationResult(
          isValid: false,
          errorCode: 'NOT_EXISTS',
          message: '目录不存在，请确认游戏文件夹已移动到该位置',
        );
      }

      return ValidationResult(
        isValid: true,
        errorCode: '',
        message: trimmedPath,
      );
    } catch (e) {
      return ValidationResult(
        isValid: false,
        errorCode: 'UNKNOWN_ERROR',
        message: '路径验证失败: $e',
      );
    }
  }

  static bool _isSystemDirectory(String pathStr) {
    final lowerPath = pathStr.toLowerCase();
    final systemDirs = [
      'c:\\windows',
      'c:\\program files',
      'c:\\program files (x86)',
      'c:\\programdata',
    ];

    for (final sysDir in systemDirs) {
      if (lowerPath.startsWith(sysDir)) {
        return true;
      }
    }

    return false;
  }

  /// kernel32.dll 句柄（Windows 桌面应用，flutter_tester 同为 Windows 进程，
  /// 单测环境可用）。加载失败（非 Windows/被安全策略拦截）时优雅降级。
  static final ffi.DynamicLibrary? _kernel32 = () {
    try {
      return ffi.DynamicLibrary.open('kernel32.dll');
    } catch (_) {
      return null;
    }
  }();

  /// ★ 2026-09-26 安装审计 P1-1：旧实现是**空桩**——恒返回
  /// `freeSpaceBytes: -1`，真实磁盘从未被查询；而 [DiskSpaceInfo.hasEnoughSpace]
  /// 对 -1 一律放行，安装/移动的空间校验因此形同虚设。
  /// 现经 Win32 `GetDiskFreeSpaceExW` 查询目标路径所在卷的真实剩余/总空间；
  /// 查询失败（无法解析卷根 / FFI 不可用）时维持「可用但未知」语义（-1），
  /// 调用方按未知放行，与旧行为兼容。
  ///
  /// ★ 2026-09-26 NAS 映射网络驱动器适配：
  /// ① **不再为目标目录做 `create(recursive: true)`** —— 查询空间是只读语义，
  ///    在只读 SMB 共享上盲建目录会失败并把整个查询拖成「不可用」，
  ///    也会往用户的 NAS 上留下垃圾目录。目录创建由
  ///    [validateCustomGameLocation] 等显式入口负责。
  /// ② 网络卷不可达（未映射 / 已断连 / 无权限）时返回 `isAvailable:false` +
  ///    可读原因，而**不是**静默降级成 `-1`（`hasEnoughSpace` 对 -1 一律放行，
  ///    会让安装一路走到下载结束才失败）。
  /// ③ 本地盘行为逐字不变（仍是「查不到 → 未知放行」）。
  static Future<DiskSpaceInfo> getDiskSpaceInfo(String targetPath) async {
    try {
      final root = _resolveVolumeRoot(targetPath);
      if (root == null) {
        debugPrint('[PATH-VALIDATOR] ⚠️ 无法解析卷根，按未知放行: $targetPath');
        return DiskSpaceInfo(
          targetPath: targetPath,
          isAvailable: true,
          freeSpaceBytes: -1,
          totalSpaceBytes: -1,
        );
      }

      if (NetworkPath.isNetwork(targetPath) &&
          !await NetworkPath.isVolumeReachableAsync(targetPath)) {
        debugPrint('[PATH-VALIDATOR] ⚠️ 网络卷不可达: $root（$targetPath）');
        return DiskSpaceInfo(
          targetPath: targetPath,
          isAvailable: false,
          freeSpaceBytes: -1,
          totalSpaceBytes: -1,
          error: '网络位置不可访问（未映射 / 已断连 / 无权限）: $root',
        );
      }

      final sizes = _queryDiskSpace(root);
      if (sizes == null) {
        debugPrint(
            '[PATH-VALIDATOR] ⚠️ 磁盘空间查询不可用（root=$root），按未知放行');
        return DiskSpaceInfo(
          targetPath: targetPath,
          isAvailable: true,
          freeSpaceBytes: -1,
          totalSpaceBytes: -1,
        );
      }

      return DiskSpaceInfo(
        targetPath: targetPath,
        isAvailable: true,
        freeSpaceBytes: sizes.$1,
        totalSpaceBytes: sizes.$2,
      );
    } catch (e) {
      return DiskSpaceInfo(
        targetPath: targetPath,
        isAvailable: false,
        freeSpaceBytes: 0,
        totalSpaceBytes: 0,
        error: e.toString(),
      );
    }
  }

  static String formatFileSize(int bytes) {
    if (bytes < 0) return '未知';

    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int unitIndex = 0;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return '${size.toStringAsFixed(unitIndex == 0 ? 0 : 1)} ${units[unitIndex]}';
  }

  /// 解析路径所属卷的根：盘符 `D:\xxx` → `D:\`；UNC `\\host\share\...` →
  /// `\\host\share`。解析失败返回 null（相对路径/裸盘符等）。
  ///
  /// ★ 2026-09-26：统一走 [NetworkPath.volumeRoot]，额外支持
  /// `\\?\Z:\...`、`\\?\UNC\host\share\...` 两种长路径前缀形态。
  static String? _resolveVolumeRoot(String targetPath) =>
      NetworkPath.volumeRoot(targetPath);

  /// Win32 `GetDiskFreeSpaceExW`：返回 (剩余字节, 总字节)；失败返回 null。
  static (int, int)? _queryDiskSpace(String volumeRoot) {
    final k32 = _kernel32;
    if (k32 == null) return null;
    try {
      final getDiskFreeSpaceExW = k32.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>),
          int Function(
              ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>)>('GetDiskFreeSpaceExW');
      final rootPtr = volumeRoot.toNativeUtf16();
      final freeCaller = pffi.malloc<ffi.Uint64>();
      final total = pffi.malloc<ffi.Uint64>();
      final freeTotal = pffi.malloc<ffi.Uint64>();
      try {
        final ok = getDiskFreeSpaceExW(rootPtr, freeCaller, total, freeTotal);
        if (ok == 0) return null;
        return (freeCaller.value, total.value);
      } finally {
        pffi.malloc.free(rootPtr);
        pffi.malloc.free(freeCaller);
        pffi.malloc.free(total);
        pffi.malloc.free(freeTotal);
      }
    } catch (e) {
      debugPrint('[PATH-VALIDATOR] ⚠️ GetDiskFreeSpaceExW 调用失败: $e');
      return null;
    }
  }
}

class ValidationResult {
  final bool isValid;
  final String errorCode;
  final String message;

  const ValidationResult({
    required this.isValid,
    required this.errorCode,
    required this.message,
  });
}


class DiskSpaceInfo {
  final String targetPath;
  final bool isAvailable;
  final int freeSpaceBytes;
  final int totalSpaceBytes;
  final String? error;

  const DiskSpaceInfo({
    required this.targetPath,
    required this.isAvailable,
    required this.freeSpaceBytes,
    required this.totalSpaceBytes,
    this.error,
  });

  String get freeSpaceFormatted => PathValidator.formatFileSize(freeSpaceBytes);
  String get totalSpaceFormatted =>
      PathValidator.formatFileSize(totalSpaceBytes);

  bool hasEnoughSpace(int requiredBytes) {
    return freeSpaceBytes < 0 || freeSpaceBytes >= requiredBytes;
  }
}
