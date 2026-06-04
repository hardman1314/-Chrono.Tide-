import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';
import 'game_data_format.dart';

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
}
