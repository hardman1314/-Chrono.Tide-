import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';

/// 清理操作通用工具:提供带重试的删除、目录清空、匹配删除等能力。
///
/// 所有清理操作应优先使用此工具,以确保:
/// 1. 删除失败时有有限次数重试(应对文件占用、锁等瞬态错误)
/// 2. 清理结果写入 [CleanupLog] 便于排查
class CleanupUtils {
  CleanupUtils._();

  /// 删除文件或目录,带重试。
  ///
  /// [retries] 重试次数(0=不重试,默认 2)。
  /// [delay] 首次重试前等待(默认 200ms,第二次重试前 500ms)。
  /// [reason] 清理原因,写入 CleanupLog。
  /// 返回是否最终删除成功(或文件本来就不存在)。
  static Future<bool> deleteWithRetry(
    FileSystemEntity entity, {
    int retries = 2,
    Duration delay = const Duration(milliseconds: 200),
    String? reason,
  }) async {
    final path = entity.path;
    int attempts = 0;
    int maxAttempts = 1 + retries;

    while (attempts < maxAttempts) {
      attempts++;
      try {
        if (entity is File) {
          if (!await entity.exists()) return true;
          final size = await entity.length();
          await entity.delete();
          await CleanupLog.append({
            'op': 'delete_file',
            'target': path,
            'result': 'ok',
            'bytes': size,
            'retry': attempts - 1,
            'reason': reason,
          });
          return true;
        } else if (entity is Directory) {
          if (!await entity.exists()) return true;
          await entity.delete(recursive: true);
          await CleanupLog.append({
            'op': 'delete_dir',
            'target': path,
            'result': 'ok',
            'retry': attempts - 1,
            'reason': reason,
          });
          return true;
        }
        return false;
      } catch (e) {
        if (attempts >= maxAttempts) {
          await CleanupLog.append({
            'op': entity is File ? 'delete_file' : 'delete_dir',
            'target': path,
            'result': 'fail',
            'error': e.toString(),
            'retry': attempts - 1,
            'reason': reason,
          });
          debugPrint('[CLEANUP] 删除失败($path): $e (尝试 $attempts/$maxAttempts)');
          return false;
        }
        // 等待后重试:首次 200ms,第二次 500ms
        final waitMs = attempts == 1 ? delay.inMilliseconds : 500;
        await Future.delayed(Duration(milliseconds: waitMs));
      }
    }
    return false;
  }

  /// 递归删除目录内容(保留目录本身)。
  ///
  /// 返回删除的条目数。
  static Future<int> clearDirectoryContents(
    Directory dir, {
    int retries = 2,
  }) async {
    if (!await dir.exists()) return 0;
    int deleted = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final ok = await deleteWithRetry(entity, retries: retries);
        if (ok) deleted++;
      }
    } catch (e) {
      debugPrint('[CLEANUP] clearDirectoryContents 异常(${dir.path}): $e');
    }
    return deleted;
  }

  /// 扫描目录并删除匹配 [matcher] 的文件。
  ///
  /// [retries] 传给 deleteWithRetry(默认 0,因为是批量快速清理)。
  /// 返回删除的文件数。
  static Future<int> deleteMatchingFiles(
    Directory dir,
    bool Function(String filename) matcher, {
    int retries = 0,
  }) async {
    if (!await dir.exists()) return 0;
    int deleted = 0;
    try {
      await for (final entity in dir.list(recursive: false, followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (matcher(name)) {
            final ok = await deleteWithRetry(entity, retries: retries);
            if (ok) deleted++;
          }
        }
      }
    } catch (e) {
      debugPrint('[CLEANUP] deleteMatchingFiles 异常(${dir.path}): $e');
    }
    return deleted;
  }
}

/// 清理操作持久化日志(JSONL 格式)。
///
/// 每行一条 JSON:{"ts":"...","op":"delete_file","target":"...","result":"ok","bytes":N,"retry":N}
/// 位置:`PathHelper.dataDir/cleanup_log.jsonl`
/// 轮转:> 5MB 时滚动为 `.1.jsonl`,保留 3 份(由 LogRotationService 管理)。
class CleanupLog {
  CleanupLog._();

  static File? _logFile;
  static bool _appendInProgress = false;

  static File get _file {
    _logFile ??= File(p.join(PathHelper.dataDir, 'cleanup_log.jsonl'));
    return _logFile!;
  }

  /// 异步追加一条清理日志。失败静默(避免清理日志自身拖垮主流程)。
  static Future<void> append(Map<String, dynamic> entry) async {
    // 防止并发写入堆积:如果已有写入在进行,简单跳过(清理日志允许丢失少量条目)
    if (_appendInProgress) return;
    _appendInProgress = true;
    try {
      final entryWithTs = {
        'ts': DateTime.now().toIso8601String(),
        ...entry,
      };
      final line = jsonEncode(entryWithTs) + '\n';
      final dir = _file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      // 静默失败,仅控制台输出
      debugPrint('[CLEANUP-LOG] 写入失败: $e');
    } finally {
      _appendInProgress = false;
    }
  }

  /// 轮转日志文件:当 > [maxBytes] 时滚动。
  /// 保留 [keep] 份历史(`.1.jsonl` `.2.jsonl` `.3.jsonl`)。
  static Future<void> rotate({
    int maxBytes = 5 * 1024 * 1024,
    int keep = 3,
  }) async {
    try {
      if (!await _file.exists()) return;
      final size = await _file.length();
      if (size <= maxBytes) return;

      // 删除最旧的一份
      final oldest = File('${_file.path}.$keep');
      if (await oldest.exists()) {
        await oldest.delete();
      }
      // 依次重命名 .2 -> .3, .1 -> .2, current -> .1
      for (int i = keep - 1; i >= 1; i--) {
        final src = File('${_file.path}.$i');
        final dst = File('${_file.path}.${i + 1}');
        if (await src.exists()) {
          await src.rename(dst.path);
        }
      }
      await _file.rename('${_file.path}.1');

      debugPrint('[CLEANUP-LOG] 已轮转,保留 $keep 份历史');
    } catch (e) {
      debugPrint('[CLEANUP-LOG] 轮转失败: $e');
    }
  }
}
