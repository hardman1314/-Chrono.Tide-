import 'dart:io';
import 'package:path/path.dart' as path;

class PathValidator {
  static const int maxPathLength = 260;
  static final _illegalChars = RegExp(r'[<>"|?*]');

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

    if (trimmedPath.length > maxPathLength) {
      return ValidationResult(
        isValid: false,
        errorCode: 'PATH_TOO_LONG',
        message: '路径过长（超过${maxPathLength}字符）',
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

  static Future<DiskSpaceInfo> getDiskSpaceInfo(String targetPath) async {
    try {
      final dir = Directory(targetPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final stat = await dir.stat();
      final parentDir = dir.parent;

      return DiskSpaceInfo(
        targetPath: targetPath,
        isAvailable: true,
        freeSpaceBytes: -1,
        totalSpaceBytes: -1,
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
