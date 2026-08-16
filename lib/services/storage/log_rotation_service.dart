import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';
import 'cleanup_utils.dart';

/// 日志轮转统一服务。
///
/// 管理 4 套日志类的轮转策略,避免 logs/ 目录无限增长。
/// 不修改各 Logger 的写入逻辑,仅提供轮转操作供调用。
///
/// 固定默认策略(不暴露 UI):
/// | Logger | 前缀 | 策略 |
/// |---|---|---|
/// | AppLogHelper | CT_*_运行日志.txt | byAge 30天 + bySize 50MB(保留3份) |
/// | ExtractManager | extract_*.txt | byAge 14天 + byCount 20份 |
/// | ScanLogger | scan_*.log | byCount 10份 |
/// | LocaleLogger | locale_emulator_log.txt | bySize 10MB(保留3份) |
/// | CleanupLog | cleanup_log.jsonl | bySize 5MB + byAge 30天 |
class LogRotationService {
  LogRotationService._();
  static final LogRotationService instance = LogRotationService._();

  /// 跳过最近修改的文件(60秒内),避免影响正在写入的日志。
  static const Duration _activeSkipThreshold = Duration(seconds: 60);

  /// 执行所有日志的轮转。启动时和定期触发时调用。
  Future<void> rotateAll() async {
    debugPrint('[LOG-ROTATION] 开始统一日志轮转...');
    int totalCleaned = 0;

    try {
      // AppLogHelper:按时间清理 30 天前的运行日志
      totalCleaned += await rotateByAge(
        PathHelper.logsDir,
        'CT_',
        const Duration(days: 30),
      );

      // ExtractManager:按数量保留 20 份 + 按时间清理 14 天前
      totalCleaned += await rotateByCount(
        PathHelper.logsDir,
        'extract_',
        20,
      );
      totalCleaned += await rotateByAge(
        PathHelper.logsDir,
        'extract_',
        const Duration(days: 14),
      );

      // ScanLogger:按数量保留 10 份
      totalCleaned += await rotateByCount(
        PathHelper.logsDir,
        'scan_',
        10,
      );

      // CleanupLog:轮转
      await CleanupLog.rotate();

      // AppLogHelper 运行日志:按大小切分(50MB)
      await _rotateAppLogBySize();

      // LocaleLogger:按大小切分(10MB)
      await _rotateLocaleLogBySize();
    } catch (e) {
      debugPrint('[LOG-ROTATION] 轮转异常: $e');
    }

    debugPrint('[LOG-ROTATION] 轮转完成,共清理 $totalCleaned 个文件');
  }

  /// 按时间清理:删除修改时间超过 [maxAge] 的匹配文件。
  ///
  /// [dir] 日志目录,[prefix] 文件名前缀(如 'extract_'),[maxAge] 最大保留时长。
  /// 跳过最近 60 秒内修改的文件(可能是正在写入的活动日志)。
  Future<int> rotateByAge(
    String dir,
    String prefix,
    Duration maxAge,
  ) async {
    final logDir = Directory(dir);
    if (!await logDir.exists()) return 0;

    int deleted = 0;
    final now = DateTime.now();

    try {
      await for (final entity in logDir.list(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (!name.startsWith(prefix)) continue;

          try {
            final stat = await entity.stat();
            // 跳过最近修改的文件(正在写入)
            if (now.difference(stat.modified) < _activeSkipThreshold) continue;
            // 删除超过 maxAge 的文件
            if (now.difference(stat.modified) > maxAge) {
              await entity.delete();
              deleted++;
              debugPrint('[LOG-ROTATION] 🗑️ 按时间删除: ${entity.path}');
            }
          } catch (e) {
            debugPrint('[LOG-ROTATION] ⚠️ 检查/删除失败: ${entity.path} | $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[LOG-ROTATION] rotateByAge 异常($dir/$prefix): $e');
    }

    return deleted;
  }

  /// 按数量清理:保留最近 [maxFiles] 份匹配文件,删除多余的。
  ///
  /// [dir] 日志目录,[prefix] 文件名前缀,[maxFiles] 最大保留份数。
  /// 跳过最近 60 秒内修改的文件。
  Future<int> rotateByCount(
    String dir,
    String prefix,
    int maxFiles,
  ) async {
    final logDir = Directory(dir);
    if (!await logDir.exists()) return 0;

    try {
      final files = <File>[];
      await for (final entity in logDir.list(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.startsWith(prefix)) {
            files.add(entity);
          }
        }
      }

      if (files.length <= maxFiles) return 0;

      // 按修改时间降序排列(最新在前)
      files.sort((a, b) {
        try {
          return b.statSync().modified.compareTo(a.statSync().modified);
        } catch (_) {
          return 0;
        }
      });

      int deleted = 0;
      final now = DateTime.now();
      // 跳过前 maxFiles 个(保留),删除剩余的
      for (final file in files.skip(maxFiles)) {
        try {
          // 跳过最近修改的文件(正在写入)
          final stat = await file.stat();
          if (now.difference(stat.modified) < _activeSkipThreshold) continue;
          await file.delete();
          deleted++;
          debugPrint('[LOG-ROTATION] 🗑️ 按数量删除: ${file.path}');
        } catch (e) {
          debugPrint('[LOG-ROTATION] ⚠️ 删除失败: ${file.path} | $e');
        }
      }
      return deleted;
    } catch (e) {
      debugPrint('[LOG-ROTATION] rotateByCount 异常($dir/$prefix): $e');
      return 0;
    }
  }

  /// 按大小切分:当文件超过 [maxBytes] 时,滚动为 `.1` `.2` ... `.N`。
  ///
  /// [filePath] 日志文件完整路径,[maxBytes] 单文件最大字节数,[keep] 保留份数。
  /// 使用 File.rename(原子操作),写入端下次 FileMode.append 会自动重建新文件。
  Future<void> rotateBySize(
    String filePath,
    int maxBytes, {
    int keep = 3,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return;

    final size = await file.length();
    if (size <= maxBytes) return;

    try {
      // 删除最旧的一份
      final oldest = File('$filePath.$keep');
      if (await oldest.exists()) {
        await oldest.delete();
      }
      // 依次重命名: .2 -> .3, .1 -> .2, current -> .1
      for (int i = keep - 1; i >= 1; i--) {
        final src = File('$filePath.$i');
        final dst = File('$filePath.${i + 1}');
        if (await src.exists()) {
          await src.rename(dst.path);
        }
      }
      await file.rename('$filePath.1');
      debugPrint('[LOG-ROTATION] 📦 按大小切分: $filePath (${size ~/ 1024}KB)');
    } catch (e) {
      debugPrint('[LOG-ROTATION] rotateBySize 异常($filePath): $e');
    }
  }

  /// AppLogHelper 运行日志按大小切分(50MB)。
  Future<void> _rotateAppLogBySize() async {
    try {
      final logDir = Directory(PathHelper.logsDir);
      if (!await logDir.exists()) return;

      await for (final entity in logDir.list(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          // 匹配 CT_YYYY-MM-DD_运行日志.txt
          if (name.startsWith('CT_') && name.endsWith('运行日志.txt')) {
            await rotateBySize(
              entity.path,
              50 * 1024 * 1024, // 50MB
              keep: 3,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[LOG-ROTATION] _rotateAppLogBySize 异常: $e');
    }
  }

  /// LocaleLogger 日志按大小切分(10MB)。
  Future<void> _rotateLocaleLogBySize() async {
    try {
      final logFile = File(p.join(PathHelper.logsDir, 'locale_emulator_log.txt'));
      if (await logFile.exists()) {
        await rotateBySize(
          logFile.path,
          10 * 1024 * 1024, // 10MB
          keep: 3,
        );
      }
    } catch (e) {
      debugPrint('[LOG-ROTATION] _rotateLocaleLogBySize 异常: $e');
    }
  }

  /// 定时轮转:每 [interval] 触发一次 rotateAll。
  /// 在 main.dart 启动时调用,返回 Timer 供取消。
  Timer startPeriodicRotation({
    Duration interval = const Duration(hours: 6),
  }) {
    return Timer.periodic(interval, (_) {
      rotateAll();
    });
  }
}
