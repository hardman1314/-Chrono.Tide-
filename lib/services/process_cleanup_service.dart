import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'openlist_service.dart';
import '../core/path_helper.dart';

class ProcessCleanupService {
  static bool _isInitialized = false;
  static bool _isCleaningUp = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    debugPrint('[PROCESS-CLEANUP] ✅ 初始化进程清理服务');

    try {
      windowManager.addListener(_WindowCleanupListener());
      debugPrint('[PROCESS-CLEANUP] ✅ 已注册窗口事件监听');
    } catch (e) {
      debugPrint('[PROCESS-CLEANUP] ⚠️ 注册窗口监听失败: $e');
    }
  }

  static Future<void> cleanupAll() async {
    if (_isCleaningUp) {
      debugPrint('[PROCESS-CLEANUP] ⚠️ 清理已在进行中，跳过重复调用');
      return;
    }

    _isCleaningUp = true;
    final stopwatch = Stopwatch()..start();

    debugPrint('[PROCESS-CLEANUP] ═══════════ 开始全局进程清理 ═══════════');

    try {
      await OpenListService.dispose();
    } catch (e) {
      debugPrint('[PROCESS-CLEANUP] ❌ OpenList清理异常: $e');
    }

    await _killProcessByName('7z.exe');
    await _killProcessByName('7za.exe');
    await _killProcessByName('LRProc.exe');

    stopwatch.stop();
    debugPrint(
        '[PROCESS-CLEANUP] ═══════════ 全局清理完成 (${stopwatch.elapsedMilliseconds}ms) ═══════════');

    _isCleaningUp = false;
  }

  static Future<void> _killProcessByName(String processName) async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq $processName', '/NH', '/FO', 'CSV'],
      );
      final output = result.stdout.toString().trim();

      if (!output.toLowerCase().contains(processName.toLowerCase())) {
        return;
      }

      debugPrint('[PROCESS-CLEANUP] 🔄 终止 $processName ...');

      for (int i = 1; i <= 2; i++) {
        final killResult = await Process.run(
          'taskkill',
          ['/IM', processName, '/F', '/T'],
        );

        if (killResult.exitCode == 0) {
          debugPrint('[PROCESS-CLEANUP] ✅ $processName 已终止 (尝试$i)');
          break;
        }

        await Future.delayed(Duration(milliseconds: 300 * i));

        if (i == 2) {
          debugPrint(
              '[PROCESS-CLEANUP] ⚠️ $processName 可能未完全终止');
        }
      }
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

class _WindowCleanupListener extends WindowListener {
  @override
  void onWindowClose() async {
    debugPrint('[PROCESS-CLEANUP] 📢 收到窗口关闭事件，执行进程清理...');

    await ProcessCleanupService.cleanupAll();

    windowManager.close();
  }

  @override
  void onWindowFocus() {}

  @override
  void onWindowBlur() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowUnmaximize() {}

  @override
  void onWindowMinimize() {}

  @override
  void onWindowRestore() {}

  @override
  void onWindowEnterFullScreen() {}

  @override
  void onWindowLeaveFullScreen() {}

  @override
  void onWindowResize() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowResized() {}

  @override
  void onWindowMoved() {}
}
