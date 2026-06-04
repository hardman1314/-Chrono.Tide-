import 'dart:io';
import 'package:flutter/foundation.dart';

class GameLauncherDetector {
  static const List<String> _localizationKeywords = [
    'chs',
    'cn',
    '汉化',
    'patch',
    'patched',
    '_cn',
    '_chs',
    '启动汉化',
    '汉化版',
  ];

  static const int _minValidExeSize = 1024 * 1024;

  static Future<LauncherDetectionResult> detect(String gameDirectory) async {
    debugPrint('');
    debugPrint('[LAUNCHER-DETECTOR] ═══════════════════════════════');
    debugPrint('[LAUNCHER-DETECTOR] 开始扫描游戏目录: $gameDirectory');
    debugPrint('[LAUNCHER-DETECTOR] ═══════════════════════════════');

    final dir = Directory(gameDirectory);
    if (!await dir.exists()) {
      debugPrint('[LAUNCHER-DETECTOR] ❌ 目录不存在');
      return LauncherDetectionResult(success: false);
    }

    final allExes = <_ExeInfo>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
        try {
          final stat = await entity.stat();
          final size = stat.size;
          final modified = stat.modified;

          allExes.add(_ExeInfo(
            path: entity.path,
            fileName: entity.uri.pathSegments.last,
            size: size,
            modified: modified,
          ));
        } catch (e) {
          debugPrint('[LAUNCHER-DETECTOR] ⚠️ 无法读取文件信息: ${entity.path} | $e');
        }
      }
    }

    debugPrint('[LAUNCHER-DETECTOR] 发现 ${allExes.length} 个 EXE 文件');

    if (allExes.isEmpty) {
      debugPrint('[LAUNCHER-DETECTOR] ❌ 未找到任何 EXE 文件');
      return LauncherDetectionResult(success: false);
    }

    for (final exe in allExes) {
      debugPrint(
          '[LAUNCHER-DETECTOR]   - ${exe.fileName} (${_formatSize(exe.size)})');
    }

    final result = await _applyPriorityRules(allExes, gameDirectory);

    debugPrint('[LAUNCHER-DETECTOR] ═══════════════════════════════');
    debugPrint('[LAUNCHER-DETECTOR] ✅ 识别完成');
    debugPrint('[LAUNCHER-DETECTOR]   优先级: ${result.priority}');
    debugPrint('[LAUNCHER-DETECTOR]   选中文件: ${result.exeFileName}');
    debugPrint('[LAUNCHER-DETECTOR]   文件体积: ${_formatSize(result.exeSize)}');
    debugPrint('[LAUNCHER-DETECTOR]   绝对路径: ${result.launcherPath}');
    debugPrint('[LAUNCHER-DETECTOR] ═══════════════════════════════');
    debugPrint('');

    return result;
  }

  static Future<LauncherDetectionResult> _applyPriorityRules(
      List<_ExeInfo> allExes, String gameDirectory) async {
    final dirName = Directory(gameDirectory).uri.pathSegments.last;

    final priority1Matches = <_ExeInfo>[];
    for (final exe in allExes) {
      final fileNameLower = exe.fileName.toLowerCase();
      for (final keyword in _localizationKeywords) {
        if (fileNameLower.contains(keyword.toLowerCase())) {
          priority1Matches.add(exe);
          debugPrint(
              '[LAUNCHER-DETECTOR] 🎯 [第一优先级] 匹配关键词 "$keyword": ${exe.fileName}');
          break;
        }
      }
    }

    if (priority1Matches.isNotEmpty) {
      priority1Matches.sort((a, b) => b.size.compareTo(a.size));
      final selected = priority1Matches.first;

      return LauncherDetectionResult(
        success: true,
        priority: 1,
        launcherPath: selected.path,
        exeFileName: selected.fileName,
        exeSize: selected.size,
        reason: '匹配汉化/补丁关键词，选体积最大',
      );
    }

    debugPrint('[LAUNCHER-DETECTOR] ℹ️ [第一优先级] 无汉化/补丁关键词匹配');

    final validExes =
        allExes.where((exe) => exe.size >= _minValidExeSize).toList();

    if (validExes.isEmpty) {
      debugPrint('[LAUNCHER-DETECTOR] ⚠️ [第二优先级] 所有EXE均小于1MB，跳过体积过滤');
    } else {
      validExes.sort((a, b) => b.size.compareTo(a.size));
      final selected = validExes.first;

      return LauncherDetectionResult(
        success: true,
        priority: 2,
        launcherPath: selected.path,
        exeFileName: selected.fileName,
        exeSize: selected.size,
        reason: '体积最大（过滤<1MB的小工具）',
      );
    }

    debugPrint('[LAUNCHER-DETECTOR] ℹ️ [第二优先级] 无有效体积候选');

    _ExeInfo? sameNameExe;
    for (final exe in allExes) {
      final nameWithoutExt =
          exe.fileName.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
      if (nameWithoutExt.toLowerCase() == dirName.toLowerCase()) {
        sameNameExe = exe;
        break;
      }
    }

    if (sameNameExe != null) {
      return LauncherDetectionResult(
        success: true,
        priority: 3,
        launcherPath: sameNameExe.path,
        exeFileName: sameNameExe.fileName,
        exeSize: sameNameExe.size,
        reason: '与文件夹同名',
      );
    }

    allExes.sort((a, b) => b.modified.compareTo(a.modified));
    final selected = allExes.first;

    return LauncherDetectionResult(
      success: true,
      priority: 3,
      launcherPath: selected.path,
      exeFileName: selected.fileName,
      exeSize: selected.size,
      reason: '修改时间最新（最终兜底）',
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class LauncherDetectionResult {
  final bool success;
  final int priority;
  final String? launcherPath;
  final String? exeFileName;
  final int exeSize;
  final String? reason;

  const LauncherDetectionResult({
    required this.success,
    this.priority = 0,
    this.launcherPath,
    this.exeFileName,
    this.exeSize = 0,
    this.reason,
  });
}

class _ExeInfo {
  final String path;
  final String fileName;
  final int size;
  final DateTime modified;

  _ExeInfo({
    required this.path,
    required this.fileName,
    required this.size,
    required this.modified,
  });
}
