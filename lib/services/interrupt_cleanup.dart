import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';
import 'game_data_format.dart';
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
              await entity.delete(recursive: true);
              deletedDirs++;
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
                await entity.delete();
                deletedDirs++;
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
                  await entity.delete(recursive: true);
                  deletedDirs++;
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
                await entity.delete(recursive: true);
                totalCleaned++;
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
                  await entity.delete(recursive: true);
                  totalCleaned++;
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
    if (actualGameDir != null && actualGameDir.isNotEmpty) {
      tasks.add(() async {
        final dir = Directory(actualGameDir);
        if (await dir.exists()) {
          // 安全检查:仅当不含游戏数据文件时才删除
          try {
            final entities = await dir.list().toList();
            bool hasGameData = false;
            for (final e in entities) {
              if (e is File) {
                final fname = e.path.toLowerCase();
                if (fname.endsWith('.exe') ||
                    fname.endsWith('.ctgame') ||
                    fname.endsWith('.xp3') ||
                    fname.endsWith('.ks')) {
                  hasGameData = true;
                  break;
                }
              }
            }
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
}
