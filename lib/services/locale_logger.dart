import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_pkg;
import 'locale_service.dart';

class LocaleLogger {
  static const String _logFileName = 'locale_emulator_log.txt';
  static bool _autoExportEnabled = true;
  static String? _logDirectory;

  static set logDirectory(String? dir) {
    _logDirectory = dir;
  }

  static set autoExport(bool enabled) {
    _autoExportEnabled = enabled;
  }

  static Future<String?> get _logFilePath async {
    if (_logDirectory != null) {
      return path_pkg.join(_logDirectory!, _logFileName);
    }

    final directory = await _getDefaultLogDirectory();
    return directory != null ? path_pkg.join(directory, _logFileName) : null;
  }

  static Future<String?> _getDefaultLogDirectory() async {
    try {
      final appDir = Directory.current.path;
      final logsDir = path_pkg.join(appDir, 'logs');

      final dir = Directory(logsDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      return logsDir;
    } catch (e) {
      debugPrint('[LocaleLogger] 无法获取日志目录: $e');
      return null;
    }
  }

  static Future<void> exportCurrentLogs() async {
    if (!_autoExportEnabled) return;

    try {
      final logPath = await _logFilePath;
      if (logPath == null) {
        debugPrint('[LocaleLogger] 无法确定日志文件路径');
        return;
      }

      final logs = LocaleService.getLogs();
      if (logs.isEmpty) {
        debugPrint('[LocaleLogger] 没有日志需要导出');
        return;
      }

      final file = File(logPath);
      final header = '''========================================
 Locale Emulator 运行日志
 生成时间: ${DateTime.now().toIso8601String()}
 日志条数: ${logs.length}
========================================

''';

      final content = header + logs.join('\n');
      await file.writeAsString(content);

      debugPrint('[LocaleLogger] ✅ 日志已导出到: $logPath');
    } catch (e) {
      debugPrint('[LocaleLogger] ❌ 日志导出失败: $e');
    }
  }

  static Future<List<String>> readLogHistory() async {
    try {
      final logPath = await _logFilePath;
      if (logPath == null || !File(logPath).existsSync()) {
        return [];
      }

      final file = File(logPath);
      final content = await file.readAsString();
      return content.split('\n').where((line) => line.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[LocaleLogger] 读取历史日志失败: $e');
      return [];
    }
  }

  static Future<void> clearLogHistory() async {
    try {
      final logPath = await _logFilePath;
      if (logPath != null && File(logPath).existsSync()) {
        await File(logPath).delete();
        debugPrint('[LocaleLogger] 历史日志已清除');
      }
    } catch (e) {
      debugPrint('[LocaleLogger] 清除历史日志失败: $e');
    }
  }

  static Future<Map<String, dynamic>> getDiagnosticInfo() async {
    final leAvailable = await LocaleService.isLocaleAvailable();
    final currentLogs = LocaleService.getLogs(limit: 50);
    final historyLogs = await readLogHistory();

    return {
      'timestamp': DateTime.now().toIso8601String(),
      'leAvailable': leAvailable,
      'currentLogCount': currentLogs.length,
      'historyLogCount': historyLogs.length,
      'recentLogs': currentLogs,
      'logFilePath': await _logFilePath,
    };
  }

  static String generateReport(Map<String, dynamic> diagnosticInfo) {
    final buffer = StringBuffer();
    buffer.writeln('╔══════════════════════════════════════╗');
    buffer.writeln('║   Locale Emulator 诊断报告           ║');
    buffer.writeln('╚══════════════════════════════════════╝');
    buffer.writeln('');
    buffer.writeln('📊 基本信息:');
    buffer.writeln('  时间: ${diagnosticInfo['timestamp']}');
    buffer.writeln('  LE 可用性: ${diagnosticInfo['leAvailable'] ? '✅ 正常' : '❌ 不可用'}');
    buffer.writeln('  当前日志条数: ${diagnosticInfo['currentLogCount']}');
    buffer.writeln('  历史日志条数: ${diagnosticInfo['historyLogCount']}');
    buffer.writeln('  日志文件路径: ${diagnosticInfo['logFilePath']}');
    buffer.writeln('');
    buffer.writeln('📝 最近日志:');
    final recentLogs = diagnosticInfo['recentLogs'] as List<String>;
    for (final log in recentLogs.take(20)) {
      buffer.writeln('  $log');
    }

    if (recentLogs.length > 20) {
      buffer.writeln('  ... 还有 ${recentLogs.length - 20} 条日志');
    }

    buffer.writeln('');
    buffer.writeln('═══════════════════════════════════════');

    return buffer.toString();
  }
}
