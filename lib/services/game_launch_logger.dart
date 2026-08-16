// game_launch_logger.dart
// 游戏启动流程监控日志系统
//
// 记录每款游戏的完整启动流程，包括：
// - 普通启动：游戏名称、启动情况、时长统计功能、游戏结束情况
// - 超分启动：游戏名称、启动情况、Magpie状态、时长统计、游戏结束、Magpie退出
//
// 日志存储在软件目录的 logs 文件夹中，文件名格式：game_launch_YYYY-MM-DD.log

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/path_helper.dart';

/// 游戏启动流程日志记录器
///
/// 使用单例模式，所有游戏启动流程共用同一个日志文件（按日期分割）。
/// 日志格式清晰，便于问题排查。
class GameLaunchLogger {
  static final GameLaunchLogger instance = GameLaunchLogger._();

  GameLaunchLogger._();

  File? _logFile;
  bool _initialized = false;

  /// 初始化日志文件
  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      final logDir = Directory(PathHelper.logsDir);
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      _logFile = File(p.join(logDir.path, 'game_launch_$dateStr.log'));
      _initialized = true;
    } catch (e) {
      debugPrint('[GAME-LAUNCH-LOG] ❌ 初始化失败: $e');
    }
  }

  /// 写入一条日志
  Future<void> _write(String level, String message) async {
    await _ensureInit();
    if (_logFile == null) return;
    try {
      final time = DateTime.now().toString().substring(0, 19);
      final line = '[$time] [$level] $message\n';
      await _logFile!.writeAsString(line, mode: FileMode.append, flush: true);
      debugPrint('[GAME-LAUNCH] $message');
    } catch (e) {
      debugPrint('[GAME-LAUNCH-LOG] ❌ 写入失败: $e');
    }
  }

  /// 记录启动流程开始
  Future<void> logLaunchStart({
    required String gameTitle,
    required String exePath,
    required String launchMode, // 'normal' | 'magpie'
    String? localeMode,
    String? trackingMode,
  }) async {
    await _write('INFO', '═══════════════════════════════════════════════════════');
    await _write('INFO', '🎮 游戏启动流程开始');
    await _write('INFO', '   游戏名称: $gameTitle');
    await _write('INFO', '   启动路径: $exePath');
    await _write('INFO', '   启动模式: $launchMode');
    if (localeMode != null && localeMode != 'none') {
      await _write('INFO', '   转区模式: $localeMode');
    }
    if (trackingMode != null) {
      await _write('INFO', '   时长统计: $trackingMode');
    }
  }

  /// 记录启动步骤
  Future<void> logStep(String step, String status, {String? detail}) async {
    final emoji = status == 'OK'
        ? '✅'
        : status == 'WARN'
            ? '⚠️'
            : status == 'FAIL'
                ? '❌'
                : '⏳';
    final msg = detail != null ? '$emoji [$step] $status - $detail' : '$emoji [$step] $status';
    await _write('INFO', msg);
  }

  /// 记录 Magpie 状态
  Future<void> logMagpieState(String state, {String? detail}) async {
    final msg = detail != null ? '🖥️ [Magpie] $state - $detail' : '🖥️ [Magpie] $state';
    await _write('INFO', msg);
  }

  /// 记录时长统计状态
  Future<void> logTrackingState(String state, {String? detail}) async {
    final msg = detail != null ? '🕐 [时长统计] $state - $detail' : '🕐 [时长统计] $state';
    await _write('INFO', msg);
  }

  /// 记录游戏退出
  Future<void> logGameExit({
    required String gameTitle,
    required int durationSeconds,
    String? exitReason,
  }) async {
    await _write('INFO', '🚪 游戏退出');
    await _write('INFO', '   游戏名称: $gameTitle');
    await _write('INFO', '   本次时长: ${_formatDuration(durationSeconds)}');
    if (exitReason != null) {
      await _write('INFO', '   退出原因: $exitReason');
    }
  }

  /// 记录 Magpie 退出
  Future<void> logMagpieExit({required bool success, String? detail}) async {
    final emoji = success ? '✅' : '❌';
    final msg = detail != null
        ? '$emoji [Magpie退出] ${success ? "成功关闭" : "关闭失败"} - $detail'
        : '$emoji [Magpie退出] ${success ? "成功关闭" : "关闭失败"}';
    await _write('INFO', msg);
  }

  /// 记录启动流程结束
  Future<void> logLaunchEnd({
    required String gameTitle,
    required bool success,
    String? summary,
  }) async {
    final emoji = success ? '✅' : '❌';
    await _write('INFO', '$emoji 启动流程结束: ${success ? "成功" : "失败"}');
    if (summary != null) {
      await _write('INFO', '   总结: $summary');
    }
    await _write('INFO', '═══════════════════════════════════════════════════════\n');
  }

  /// 记录错误
  Future<void> logError(String context, dynamic error, [StackTrace? stack]) async {
    await _write('ERROR', '❌ [$context] $error');
    if (stack != null) {
      await _write('ERROR', '   堆栈: $stack');
    }
  }

  /// 格式化时长
  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h${m}m${s}s';
    if (m > 0) return '${m}m${s}s';
    return '${s}s';
  }
}
