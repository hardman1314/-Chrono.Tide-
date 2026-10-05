import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';
import 'game_data_format.dart';
import 'game_move_service.dart';
import 'process_cleanup_service.dart';
import 'storage/cleanup_utils.dart';

class InterruptCleanup {
  static final String _downloadsDir = PathHelper.downloadsDir;
  static final String _gamesDir = PathHelper.gamesDir;

  static Future<void> cleanupAll() async {
    debugPrint('[INFO] [INTERRUPT-CLEANUP] ========== 开始中断清理 ==========');
    await cleanupDownloads();
    await cleanupExtraction();
    debugPrint('[INFO] [INTERRUPT-CLEANUP] ========== 中断清理完成 ==========');
  }

  static Future<void> cleanupDownloads() async {
    debugPrint('[INFO] [INTERRUPT-CLEANUP] 扫描下载临时文件...');

    try {
      final dir = Directory(_downloadsDir);
      if (!await dir.exists()) {
        debugPrint('[INFO] [INTERRUPT-CLEANUP] downloads目录不存在，跳过');
        return;
      }

      int deletedCount = 0;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.contains('.chunk_') && name.endsWith('.tmp') ||
              name.contains('.part_') && name.endsWith('.tmp')) {
            try {
              await entity.delete();
              deletedCount++;
              debugPrint('[INFO] [INTERRUPT-CLEANUP] 已删除下载分片: ${entity.path}');
            } catch (e) {
              debugPrint(
                  '[WARN] [INTERRUPT-CLEANUP] 删除失败: ${entity.path} | $e');
            }
          }
        }
      }

      if (deletedCount > 0) {
        debugPrint('[INFO] 中断清理：已删除 $deletedCount 个下载临时文件');
      }

      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.tmp') || name.contains('.merge')) {
            try {
              await entity.delete();
              deletedCount++;
              debugPrint(
                  '[INFO] [INTERRUPT-CLEANUP] 已删除合并临时文件: ${entity.path}');
            } catch (e) {
              debugPrint(
                  '[WARN] [INTERRUPT-CLEANUP] 删除失败: ${entity.path} | $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[ERROR] [INTERRUPT-CLEANUP] 清理下载目录异常: $e');
    }
  }

  static Future<void> cleanupExtraction() async {
    debugPrint('[INFO] [INTERRUPT-CLEANUP] 扫描解压临时文件...');

    try {
      final gamesDir = Directory(_gamesDir);
      if (!await gamesDir.exists()) {
        debugPrint('[INFO] [INTERRUPT-CLEANUP] Games目录不存在，跳过');
        return;
      }

      int deletedDirs = 0;

      await for (final entity in gamesDir.list(followLinks: false)) {
        if (entity is Directory) {
          final dirName = entity.path.split('/').last.split('\\').last;

          if (dirName.contains('_temp_layer_')) {
            try {
              // ★ IMP-07: 统一经 CleanupUtils，落审计日志 data/cleanup_log.jsonl
              final ok = await CleanupUtils.deleteWithRetry(entity,
                  retries: 1, reason: 'interrupt_cleanup_temp_layer');
              if (ok) deletedDirs++;
              debugPrint('[INFO] [INTERRUPT-CLEANUP] 已删除解压临时层: ${entity.path}');
            } catch (e) {
              debugPrint(
                  '[WARN] [INTERRUPT-CLEANUP] 删除临时层失败: ${entity.path} | $e');
            }
            continue;
          }

          final ctgameFile =
              File('${entity.path}/${GameDataFormat.ctgameFileName}');
          final gameJsonFile =
              File('${entity.path}/${GameDataFormat.gameJsonFileName}');
          if (!await ctgameFile.exists() && !await gameJsonFile.exists()) {
            try {
              final entities = await entity.list().toList();
              if (entities.isEmpty) {
                // ★ IMP-07: 落审计日志
                final ok = await CleanupUtils.deleteWithRetry(entity,
                    retries: 1, reason: 'interrupt_cleanup_empty_game_dir');
                if (ok) deletedDirs++;
                debugPrint(
                    '[INFO] [INTERRUPT-CLEANUP] 已删除空游戏目录: ${entity.path}');
              } else {
                bool hasSubstantiveFiles = false;
                for (final sub in entities) {
                  if (sub is File) {
                    final fname = sub.path.toLowerCase();
                    if (!fname.endsWith('.tmp') &&
                        !fname.contains('temp') &&
                        !fname.contains('partial')) {
                      hasSubstantiveFiles = true;
                      break;
                    }
                  } else if (sub is Directory) {
                    hasSubstantiveFiles = true;
                    break;
                  }
                }
                if (!hasSubstantiveFiles) {
                  // ★ IMP-07: 落审计日志
                  final ok = await CleanupUtils.deleteWithRetry(entity,
                      retries: 1, reason: 'interrupt_cleanup_incomplete_game_dir');
                  if (ok) deletedDirs++;
                  debugPrint(
                      '[INFO] [INTERRUPT-CLEANUP] 已删除不完整游戏目录(无.ctgame/game.json): ${entity.path}');
                } else {
                  debugPrint(
                      '[WARN] [INTERRUPT-CLEANUP] 保留含实质文件的游戏目录(无.ctgame/game.json): ${entity.path}');
                }
              }
            } catch (e) {
              debugPrint(
                  '[WARN] [INTERRUPT-CLEANUP] 检查游戏目录失败: ${entity.path} | $e');
            }
          }
        }
      }

      if (deletedDirs > 0) {
        debugPrint('[INFO] 中断清理：已删除 $deletedDirs 个不完整游戏目录/临时文件夹');
      }
    } catch (e) {
      debugPrint('[ERROR] [INTERRUPT-CLEANUP] 清理解压目录异常: $e');
    }
  }

  static Future<void> startupScan() async {
    debugPrint('[INFO] [INTERRUPT-CLEANUP] ========== 启动时扫描残留文件 ==========');
    int totalCleaned = 0;

    // ★ IMP-07（2026-09-12 导入审查）：先做一次"应用目录内残留解压进程"的定向清理。
    // 强制关闭软件时 7z/bz/UnRAR 等子进程会变成孤儿并继续往目标目录写盘；此处
    // fire-and-forget 不阻塞启动，失败仅记日志。按可执行文件路径过滤，
    // 只杀 runtime 目录下的副本，不会误伤用户自己安装的解压工具。
    unawaited(ProcessCleanupService.killResidueFromAppDir());

    try {
      final dlDir = Directory(_downloadsDir);
      if (await dlDir.exists()) {
        await for (final entity
            in dlDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            if ((name.contains('.chunk_') && name.endsWith('.tmp')) ||
                name.endsWith('.tmp') ||
                name.contains('.merge')) {
              try {
                await entity.delete();
                totalCleaned++;
                debugPrint('[INFO] [STARTUP-SCAN] 已清理下载残留: ${entity.path}');
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    try {
      final gamesDir = Directory(_gamesDir);
      if (await gamesDir.exists()) {
        await for (final entity in gamesDir.list(followLinks: false)) {
          if (entity is Directory) {
            final dirName = entity.path.split('/').last.split('\\').last;
            if (dirName.contains('_temp_layer_')) {
              try {
                // ★ IMP-07: 落审计日志
                final ok = await CleanupUtils.deleteWithRetry(entity,
                    retries: 1, reason: 'startup_scan_temp_layer');
                if (ok) totalCleaned++;
                debugPrint('[INFO] [STARTUP-SCAN] 已清理解压残留临时层: ${entity.path}');
              } catch (_) {}
              continue;
            }

            final ctgameFile =
                File('${entity.path}/${GameDataFormat.ctgameFileName}');
            final gameJsonFile =
                File('${entity.path}/${GameDataFormat.gameJsonFileName}');
            if (!await ctgameFile.exists() && !await gameJsonFile.exists()) {
              try {
                final subs = await entity.list().toList();
                if (subs.isEmpty ||
                    subs.every((s) =>
                        s is File &&
                        (s.path.toLowerCase().endsWith('.tmp') ||
                            s.path.toLowerCase().contains('temp')))) {
                  // ★ IMP-07: 落审计日志
                  final ok = await CleanupUtils.deleteWithRetry(entity,
                      retries: 1, reason: 'startup_scan_incomplete_game_dir');
                  if (ok) totalCleaned++;
                  debugPrint(
                      '[INFO] [STARTUP-SCAN] 已清理不完整游戏目录: ${entity.path}');
                }
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    if (totalCleaned > 0) {
      debugPrint('[INFO] 中断清理：启动扫描完成，共清理 $totalCleaned 个残留文件/目录');
    } else {
      debugPrint('[INFO] [STARTUP-SCAN] 无残留文件，环境干净');
    }

    // ★ 迁移事务检测（09-12 真迁移功能）：读取 move_in_progress.json，
    // 检测上次迁移中断的半成品目标目录。只记录 + 审计，**不自动删除任何文件**
    //（详情弹窗打开时经 GameMoveService.takeStartupPendingMove 提示用户）。
    try {
      await GameMoveService.instance.checkPendingMoveOnStartup();
    } catch (e) {
      debugPrint('[WARN] [STARTUP-SCAN] 迁移登记检测异常: $e');
    }

    debugPrint('[INFO] [INTERRUPT-CLEANUP] ========== 启动扫描结束 ==========');
  }

  /// 快路径:仅清理已知活动任务的残留,带超时。
  ///
  /// 不做全目录扫描,只删具体路径,典型 < 100ms。
  /// 用于软件退出时,仅当有正在进行的下载/解压任务时调用。
  /// 超时后放弃(残留靠下次启动 startupScan 兜底)。
  static Future<void> cleanupActiveTaskResidue({
    String? downloadedFilePath,
    String? targetGameDir,
    String? actualGameDir,
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    debugPrint('[INTERRUPT-CLEANUP] ========== 开始活动任务残留清理(快路径) ==========');

    try {
      // 用 Future.any + 超时控制,避免拖慢退出
      await _doCleanupActiveTaskResidue(
        downloadedFilePath: downloadedFilePath,
        targetGameDir: targetGameDir,
        actualGameDir: actualGameDir,
      ).timeout(timeout);
    } on TimeoutException {
      debugPrint('[INTERRUPT-CLEANUP] ⚠️ 活动任务清理超时(${timeout.inMilliseconds}ms),残留靠下次启动扫描兜底');
    } catch (e) {
      debugPrint('[INTERRUPT-CLEANUP] ⚠️ 活动任务清理异常: $e');
    }

    debugPrint('[INTERRUPT-CLEANUP] ========== 活动任务残留清理结束 ==========');
  }

  static Future<void> _doCleanupActiveTaskResidue({
    String? downloadedFilePath,
    String? targetGameDir,
    String? actualGameDir,
  }) async {
    final tasks = <Future<void>>[];

    // 1. 删除已下载的文件(可能是压缩包或未合并的分片)
    if (downloadedFilePath != null && downloadedFilePath.isNotEmpty) {
      tasks.add(() async {
        final ok = await CleanupUtils.deleteWithRetry(
          File(downloadedFilePath),
          retries: 1,
          reason: 'exit_cleanup_downloaded',
        );
        debugPrint('[INTERRUPT-CLEANUP]   下载文件: ${ok ? "已删除" : "跳过"}');
      }());
    }

    // 2. 删除实际解压目录(用户自定义路径,优先于元数据目录)
    // ★ IMP-02 数据安全护栏(2026-09-12 导入审查):
    // ① 仅允许删除**应用自有目录内**的路径——actualGameDir 可能是用户在"安装位置"
    //    里挑选的任意目录,越界递归删除即用户数据丢失;
    // ② 游戏数据判定改为**递归**——旧实现只看顶层 4 种扩展名,
    //    "启动程序在 bin/ 等子目录"的常见 GAL 目录会被误判为"无游戏数据"而被整目录删除。
    if (actualGameDir != null && actualGameDir.isNotEmpty) {
      tasks.add(() async {
        if (!PathHelper.isInsideAppStorage(actualGameDir)) {
          debugPrint(
              '[INTERRUPT-CLEANUP]   ⛔ 跳过删除实际解压目录(位于应用自有目录之外): $actualGameDir');
          return;
        }
        final dir = Directory(actualGameDir);
        if (await dir.exists()) {
          try {
            final hasGameData = await hasGameDataRecursively(dir);
            if (!hasGameData) {
              await CleanupUtils.deleteWithRetry(
                dir, retries: 1, reason: 'exit_cleanup_actual_dir',
              );
              debugPrint('[INTERRUPT-CLEANUP]   实际解压目录: 已删除');
            } else {
              debugPrint('[INTERRUPT-CLEANUP]   实际解压目录: 含游戏数据,保留');
            }
          } catch (e) {
            debugPrint('[INTERRUPT-CLEANUP]   实际解压目录: 检查异常 $e');
          }
        }
      }());
    }

    // 3. 删除元数据目录(若与实际解压目录不同)
    if (targetGameDir != null &&
        targetGameDir.isNotEmpty &&
        targetGameDir != actualGameDir) {
      tasks.add(() async {
        // ★ IMP-02: 元数据目录同样只允许在应用自有目录内删除
        if (!PathHelper.isInsideAppStorage(targetGameDir)) {
          debugPrint(
              '[INTERRUPT-CLEANUP]   ⛔ 跳过删除元数据目录(位于应用自有目录之外): $targetGameDir');
          return;
        }
        final dir = Directory(targetGameDir);
        if (await dir.exists()) {
          await CleanupUtils.deleteWithRetry(
            dir, retries: 1, reason: 'exit_cleanup_target_dir',
          );
          debugPrint('[INTERRUPT-CLEANUP]   元数据目录: 已删除');
        }
      }());
    }

    // 4. 删除 _temp_layer_* 临时目录(Games 目录下)
    tasks.add(() async {
      final gamesDir = Directory(_gamesDir);
      if (await gamesDir.exists()) {
        int deleted = 0;
        await for (final entity in gamesDir.list(followLinks: false)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last.split('\\').last;
            if (name.contains('_temp_layer_')) {
              final ok = await CleanupUtils.deleteWithRetry(
                entity, retries: 0, reason: 'exit_cleanup_temp_layer',
              );
              if (ok) deleted++;
            }
          }
        }
        if (deleted > 0) {
          debugPrint('[INTERRUPT-CLEANUP]   临时层: 已删除 $deleted 个');
        }
      }
    }());

    // 并行执行所有清理任务
    await Future.wait(tasks);
  }

  /// 判定"游戏数据文件"的扩展名白名单（IMP-02）
  static const List<String> _gameDataExtensions = [
    '.exe', '.ctgame', '.xp3', '.ks', '.tjs', // 主程序 / 引擎脚本
    '.rpa', '.arc', '.dat', '.nsa', '.npa', // 数据包
    '.pfs', '.ypf', '.ald', '.scn', // 其他常见打包/剧本格式
  ];

  /// 递归判定目录内是否含游戏数据文件（IMP-02）
  ///
  /// 旧实现只看顶层 4 种扩展名（exe/ctgame/xp3/ks），对"启动程序位于 bin/ 等
  /// 子目录"的常见 GAL 目录会误判为"无游戏数据"→ 触发整目录递归删除。
  /// 现改为递归扫描 + 更完整的白名单；**宁可保留也不误删**。
  /// 扫描异常时同样按"含游戏数据"处理（保守方向）。
  ///
  /// 公开供其它删除点复用（如 GlobalInstallCenter 失败回滚，IMP-21），
  /// 避免各处重复实现导致规则漂移。
  static Future<bool> hasGameDataRecursively(Directory dir) async {
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.toLowerCase();
        for (final ext in _gameDataExtensions) {
          if (name.endsWith(ext)) return true;
        }
      }
    } catch (e) {
      debugPrint('[INTERRUPT-CLEANUP]   游戏数据判定异常(保守保留): $e');
      return true;
    }
    return false;
  }
}
