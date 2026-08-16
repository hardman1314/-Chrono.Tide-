import 'dart:io';
import 'package:flutter/foundation.dart';
import 'openlist_service.dart';
import 'magpie_service.dart';

class ProcessCleanupService {
  static bool _isInitialized = false;
  static bool _isCleaningUp = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    debugPrint('[PROCESS-CLEANUP] ✅ 初始化进程清理服务');
    // 不再注册 _WindowCleanupListener
    // 窗口关闭事件已由 CustomTitleBar 通过 setPreventClose(true) 统一处理
  }

  static Future<void> cleanupAll() async {
    if (_isCleaningUp) {
      debugPrint('[PROCESS-CLEANUP] ⚠️ 清理已在进行中，跳过重复调用');
      return;
    }

    _isCleaningUp = true;
    final stopwatch = Stopwatch()..start();

    debugPrint('[PROCESS-CLEANUP] ═══════════ 开始全局进程清理 ═══════════');

    // 并行执行所有清理任务，大幅缩短退出时间
    await Future.wait([
      (() async {
        try {
          await OpenListService.dispose();
        } catch (e) {
          debugPrint('[PROCESS-CLEANUP] ❌ OpenList清理异常: $e');
        }
      })(),
      (() async {
        try {
          await MagpieService.instance.shutdown();
        } catch (e) {
          debugPrint('[PROCESS-CLEANUP] ❌ Magpie清理异常: $e');
        }
      })(),
      _killProcessByName('7z.exe'),
      _killProcessByName('7za.exe'),
      _killProcessByName('LRProc.exe'),
    ]);

    stopwatch.stop();
    debugPrint(
        '[PROCESS-CLEANUP] ═══════════ 全局清理完成 (${stopwatch.elapsedMilliseconds}ms) ═══════════');

    _isCleaningUp = false;
  }

  static Future<void> _killProcessByName(String processName) async {
    try {
      // 直接用 taskkill 强制终止，不再先用 tasklist 检查
      // taskkill 在进程不存在时会返回非零退出码，不会报错
      final result = await Process.run(
        'taskkill',
        ['/IM', processName, '/F', '/T'],
      );

      if (result.exitCode == 0) {
        debugPrint('[PROCESS-CLEANUP] ✅ $processName 已终止');
      }
      // 进程不存在时静默跳过，无需额外处理
    } catch (e) {
      debugPrint('[PROCESS-CLEANUP] ⚠️ 终止 $processName 异常: $e');
    }
  }

  static Future<bool> hasZombieProcesses() async {
    final processesToCheck = ['openlist.exe', '7z.exe', '7za.exe', 'LRProc.exe'];

    for (final proc in processesToCheck) {
      try {
        final result = await Process.run(
          'tasklist',
          ['/FI', 'IMAGENAME eq $proc', '/NH', '/FO', 'CSV'],
        );

        if (result.stdout.toString().trim().toLowerCase().contains(proc)) {
          return true;
        }
      } catch (_) {}
    }

    return false;
  }

  static Future<Map<String, int>> getZombieProcesses() async {
    final result = <String, int>{};
    final processesToCheck = ['openlist.exe', '7z.exe', '7za.exe', 'LRProc.exe'];

    for (final proc in processesToCheck) {
      try {
        final procResult = await Process.run(
          'tasklist',
          ['/FI', 'IMAGENAME eq $proc', '/NH', '/FO', 'CSV'],
        );

        final output = procResult.stdout.toString().trim();
        if (output.toLowerCase().contains(proc)) {
          final lines = output.split('\n');
          result[proc] = lines.length > 0 ? lines.length - 1 : 1;
        }
      } catch (_) {}
    }

    return result;
  }
}
