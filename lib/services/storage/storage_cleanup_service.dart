import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';
import '../../core/portable_image_cache_manager.dart';
import '../discover_metadata_service.dart';
import '../metadata_fetcher.dart';
import '../download_core.dart';
import 'cleanup_utils.dart';
import 'log_rotation_service.dart';

/// 存储清理结果。
class StorageCleanupResult {
  /// 各清理单元的释放字节数（key = 单元 id）。
  final Map<String, int> freedBytes;

  /// 各清理单元是否成功。
  final Map<String, bool> success;

  /// 各清理单元的描述信息（成功/失败原因）。
  final Map<String, String> messages;

  const StorageCleanupResult({
    required this.freedBytes,
    required this.success,
    required this.messages,
  });

  /// 总释放字节数。
  int get totalFreed => freedBytes.values.fold(0, (a, b) => a + b);

  /// 是否全部成功。
  bool get allSuccess => success.values.every((v) => v);
}

/// 缓存单元描述（用于 UI 展示）。
class CacheUnitInfo {
  final String id;
  final String label;
  final int sizeBytes;
  final bool regenerable;

  const CacheUnitInfo({
    required this.id,
    required this.label,
    required this.sizeBytes,
    required this.regenerable,
  });
}

/// 存储清理服务。
///
/// 仅清理**可再生缓存**（图片缓存、临时文件、元数据缓存），
/// 保留用户数据（偏好、游戏配置、主题、背景图、游戏本体、下载）。
///
/// 所有缓存路径均位于软件安装目录 `data/` 下（便携化迁移已完成），
/// 清理动作不会触及系统 C 盘。
class StorageCleanupService {
  StorageCleanupService._();
  static final StorageCleanupService instance = StorageCleanupService._();

  // ===== 清理单元 id（与 UI、StorageCleanupResult 对应） =====
  static const String unitImageCache = 'image_cache';
  static const String unitTempFiles = 'temp_files';
  static const String unitDiscoverMetadata = 'discover_metadata';
  static const String unitFetcherMetadata = 'fetcher_metadata';
  static const String unitOldLogs = 'old_logs';
  static const String unitTempLayer = 'temp_layer';
  static const String unitDownloadArchives = 'download_archives';

  /// 探索元数据缓存文件路径（DiscoverMetadataService 使用）。
  static String get _discoverMetadataFile =>
      p.join(PathHelper.dataDir, 'cache', 'discover_metadata.json');

  /// 元数据抓取器缓存文件路径（MetadataFetcher 使用）。
  static String get _fetcherMetadataFile =>
      p.join(PathHelper.dataDir, 'cache', 'metadata_cache.json');

  // ==================== 大小查询 ====================

  /// 获取所有可再生缓存单元的大小信息。
  ///
  /// 在后台 isolate 友好的纯 IO 操作，但为简化依赖直接在主 isolate 执行；
  /// UI 调用方应在 await 后再 setState。
  Future<List<CacheUnitInfo>> getCacheUnits() async {
    final portable = await PathHelper.isPortableWritable();
    final units = <CacheUnitInfo>[];

    // 图片缓存目录
    units.add(CacheUnitInfo(
      id: unitImageCache,
      label: '图片缓存',
      sizeBytes: await _dirSize(Directory(PathHelper.imageCacheDir)),
      regenerable: true,
    ));

    // 临时文件目录（更新包、临时下载等）
    units.add(CacheUnitInfo(
      id: unitTempFiles,
      label: '临时文件',
      sizeBytes: await _dirSize(Directory(PathHelper.portableTmpDir)),
      regenerable: true,
    ));

    // 探索大厅元数据缓存
    units.add(CacheUnitInfo(
      id: unitDiscoverMetadata,
      label: '探索元数据缓存',
      sizeBytes: await _fileSize(File(_discoverMetadataFile)),
      regenerable: true,
    ));

    // 元数据抓取器缓存
    units.add(CacheUnitInfo(
      id: unitFetcherMetadata,
      label: '抓取器元数据缓存',
      sizeBytes: await _fileSize(File(_fetcherMetadataFile)),
      regenerable: true,
    ));

    // 便携化降级提示：安装目录不可写时，缓存仍在系统盘，UI 应提示
    if (!portable) {
      debugPrint('[StorageCleanup] 安装目录不可写，缓存可能位于系统盘');
    }

    // 旧日志文件(logs 目录)
    units.add(CacheUnitInfo(
      id: unitOldLogs,
      label: '运行日志',
      sizeBytes: await _dirSize(Directory(PathHelper.logsDir)),
      regenerable: true,
    ));

    // 解压临时层(Games/._temp_layer_*)
    units.add(CacheUnitInfo(
      id: unitTempLayer,
      label: '解压临时层',
      sizeBytes: await _tempLayerSize(),
      regenerable: true,
    ));

    // 下载残留压缩包(downloads 目录下非 .tmp 的压缩包)
    units.add(CacheUnitInfo(
      id: unitDownloadArchives,
      label: '下载残留压缩包',
      sizeBytes: await _downloadArchivesSize(),
      regenerable: false,
    ));

    return units;
  }

  /// 获取可再生缓存总大小（字节）。
  Future<int> getTotalCacheSize() async {
    final units = await getCacheUnits();
    return units.fold<int>(0, (a, u) => a + u.sizeBytes);
  }

  /// 检查缓存用量是否超过阈值。
  ///
  /// [totalCacheThreshold] 总缓存阈值(默认 1GB)。
  /// [perUnitThreshold] 单元缓存阈值(默认 500MB)。
  /// 返回超阈值的单元列表(空列表表示全部正常)。
  Future<List<CacheThreshold>> checkThresholds({
    int totalCacheThreshold = 1024 * 1024 * 1024, // 1GB
    int perUnitThreshold = 500 * 1024 * 1024, // 500MB
  }) async {
    final units = await getCacheUnits();
    final total = units.fold<int>(0, (a, u) => a + u.sizeBytes);
    final exceeded = <CacheThreshold>[];

    // 总量检查
    if (total > totalCacheThreshold) {
      exceeded.add(CacheThreshold(
        unitId: 'total',
        unitLabel: '总缓存',
        currentBytes: total,
        thresholdBytes: totalCacheThreshold,
      ));
    }

    // 单元检查
    for (final u in units) {
      if (u.sizeBytes > perUnitThreshold) {
        exceeded.add(CacheThreshold(
          unitId: u.id,
          unitLabel: u.label,
          currentBytes: u.sizeBytes,
          thresholdBytes: perUnitThreshold,
        ));
      }
    }

    return exceeded;
  }

  // ==================== 清理 ====================

  /// 清理全部可再生缓存。
  ///
  /// 返回每个单元的清理结果。任一单元失败不阻断其余单元。
  Future<StorageCleanupResult> clearAll() async {
    final freed = <String, int>{};
    final success = <String, bool>{};
    final messages = <String, String>{};

    // 1. 图片缓存
    final r1 = await _clearImageCache();
    freed[unitImageCache] = r1.freed;
    success[unitImageCache] = r1.ok;
    messages[unitImageCache] = r1.message;

    // 2. 临时文件
    final r2 = await _clearTempFiles();
    freed[unitTempFiles] = r2.freed;
    success[unitTempFiles] = r2.ok;
    messages[unitTempFiles] = r2.message;

    // 3. 探索大厅元数据缓存
    final r3 = await _clearDiscoverMetadata();
    freed[unitDiscoverMetadata] = r3.freed;
    success[unitDiscoverMetadata] = r3.ok;
    messages[unitDiscoverMetadata] = r3.message;

    // 4. 元数据抓取器缓存
    final r4 = await _clearFetcherMetadata();
    freed[unitFetcherMetadata] = r4.freed;
    success[unitFetcherMetadata] = r4.ok;
    messages[unitFetcherMetadata] = r4.message;

    // 5. 旧日志文件(委托给 LogRotationService)
    final r5 = await _clearOldLogs();
    freed[unitOldLogs] = r5.freed;
    success[unitOldLogs] = r5.ok;
    messages[unitOldLogs] = r5.message;

    // 6. 解压临时层(Games/._temp_layer_*)
    final r6 = await _clearTempLayer();
    freed[unitTempLayer] = r6.freed;
    success[unitTempLayer] = r6.ok;
    messages[unitTempLayer] = r6.message;

    // 注:unitDownloadArchives 不纳入 clearAll,需用户单独操作(clearDownloadArchives)

    debugPrint(
        '[StorageCleanup] 清理完成：共释放 ${_fmtBytes(freed.values.fold(0, (a, b) => a + b))}');

    return StorageCleanupResult(
      freedBytes: freed,
      success: success,
      messages: messages,
    );
  }

  // ==================== 单元清理实现 ====================

  /// 图片缓存：先记录大小，再调用 CacheManager.emptyCache() 清空索引+文件，
  /// 最后兜底删除残留文件。
  Future<_UnitCleanup> _clearImageCache() async {
    try {
      final dir = Directory(PathHelper.imageCacheDir);
      final sizeBefore = await _dirSize(dir);

      // 1. 调用 flutter_cache_manager 的 emptyCache：清空内存索引 + 删除缓存文件
      await PortableImageCacheManager().emptyCache();

      // 2. 兜底：删除目录下残留文件（emptyCache 偶发遗漏 .json 元数据等）
      final sizeAfter = await _dirSize(dir);
      if (sizeAfter > 0) {
        await _clearDirectoryContents(dir);
      }

      final freed = sizeBefore - await _dirSize(dir);
      return _UnitCleanup(
        freed: freed,
        ok: true,
        message: '已清空 ${_fmtBytes(freed)}',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 临时文件：清空 data/tmp/ 目录内容（保留目录本身）。
  Future<_UnitCleanup> _clearTempFiles() async {
    try {
      final dir = Directory(PathHelper.portableTmpDir);
      final sizeBefore = await _dirSize(dir);
      await _clearDirectoryContents(dir);
      final freed = sizeBefore;
      return _UnitCleanup(
        freed: freed,
        ok: true,
        message: '已清空 ${_fmtBytes(freed)}',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 探索大厅元数据缓存：调用 DiscoverMetadataService.clearCache()
  /// （清空内存缓存 + 删除磁盘 JSON 文件）。
  Future<_UnitCleanup> _clearDiscoverMetadata() async {
    try {
      final file = File(_discoverMetadataFile);
      final sizeBefore = await _fileSize(file);
      await DiscoverMetadataService.instance.clearCache();
      return _UnitCleanup(
        freed: sizeBefore,
        ok: true,
        message: sizeBefore > 0 ? '已清空 ${_fmtBytes(sizeBefore)}' : '已是空缓存',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 元数据抓取器缓存：调用 MetadataFetcher.clearCache()
  /// （清空内存缓存 + 删除磁盘 JSON 文件）。
  Future<_UnitCleanup> _clearFetcherMetadata() async {
    try {
      final file = File(_fetcherMetadataFile);
      final sizeBefore = await _fileSize(file);
      await MetadataFetcher.clearCache();
      return _UnitCleanup(
        freed: sizeBefore,
        ok: true,
        message: sizeBefore > 0 ? '已清空 ${_fmtBytes(sizeBefore)}' : '已是空缓存',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 旧日志文件:委托给 LogRotationService 执行严格轮转(按时间+按数量)。
  /// 不删除正在写入的活动日志文件。
  Future<_UnitCleanup> _clearOldLogs() async {
    try {
      final logsDir = Directory(PathHelper.logsDir);
      final sizeBefore = await _dirSize(logsDir);
      // 执行严格轮转:清理所有超过 1 天的日志 + 每类只保留 5 份
      await LogRotationService.instance.rotateByAge(
        PathHelper.logsDir, 'CT_', const Duration(days: 1),
      );
      await LogRotationService.instance.rotateByAge(
        PathHelper.logsDir, 'extract_', const Duration(days: 1),
      );
      await LogRotationService.instance.rotateByCount(
        PathHelper.logsDir, 'scan_', 5,
      );
      await LogRotationService.instance.rotateByCount(
        PathHelper.logsDir, 'extract_', 5,
      );
      await LogRotationService.instance.rotateByCount(
        PathHelper.logsDir, 'CT_', 3,
      );
      final sizeAfter = await _dirSize(logsDir);
      final freed = sizeBefore - sizeAfter;
      return _UnitCleanup(
        freed: freed,
        ok: true,
        message: '已清理 ${_fmtBytes(freed)} 旧日志',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 解压临时层:清理 Games/._temp_layer_* 目录。
  Future<_UnitCleanup> _clearTempLayer() async {
    try {
      final gamesDir = Directory(PathHelper.gamesDir);
      int freed = 0;
      int deleted = 0;
      if (await gamesDir.exists()) {
        await for (final entity in gamesDir.list(followLinks: false)) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (name.contains('_temp_layer_')) {
              final size = await _dirSize(entity);
              final ok = await CleanupUtils.deleteWithRetry(
                entity, retries: 1, reason: 'clearTempLayer',
              );
              if (ok) {
                freed += size;
                deleted++;
              }
            }
          }
        }
      }
      return _UnitCleanup(
        freed: freed,
        ok: true,
        message: deleted > 0
            ? '已清理 $deleted 个临时层 (${_fmtBytes(freed)})'
            : '无临时层残留',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  /// 下载残留压缩包:清理 downloads/ 下的 .zip/.rar/.7z/.tar 文件。
  /// 不清理 .tmp 分片文件(由下载流程管理)。
  /// 此方法不纳入 clearAll,需用户在 UI 单独触发(带二次确认)。
  Future<_UnitCleanup> clearDownloadArchives() async {
    try {
      final dlDir = Directory(PathHelper.downloadsDir);
      int freed = 0;
      int deleted = 0;
      if (await dlDir.exists()) {
        await for (final entity in dlDir.list(followLinks: false)) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            final isArchive = name.endsWith('.zip') ||
                name.endsWith('.rar') ||
                name.endsWith('.7z') ||
                name.endsWith('.tar');
            // ★ 2026-09-26 安装审计 P2-2：分片断点残留（.part_*.tmp）此前
            // 完全无人管理——原注释「由下载流程管理」只覆盖正常取消路径，
            // 强杀/断电后永久占空间且用户不可见。仅当**无活跃下载**时纳入
            // 清理：有任务在跑时 .tmp 正被写入，动了就是竞态。
            final isPartChunk =
                name.contains('.part_') && name.endsWith('.tmp');
            final canCleanChunk = isPartChunk && !DownloadCore.hasActiveTask;
            if (!isArchive && !canCleanChunk) continue;
            final size = await entity.length();
            final ok = await CleanupUtils.deleteWithRetry(
              entity, retries: 1, reason: 'clearDownloadArchives',
            );
            if (ok) {
              freed += size;
              deleted++;
            }
          }
        }
      }
      return _UnitCleanup(
        freed: freed,
        ok: true,
        message: deleted > 0
            ? '已删除 $deleted 个压缩包 (${_fmtBytes(freed)})'
            : '无下载残留',
      );
    } catch (e) {
      return _UnitCleanup(freed: 0, ok: false, message: '清理失败: $e');
    }
  }

  // ==================== 大小查询(新单元) ====================

  Future<int> _tempLayerSize() async {
    try {
      final gamesDir = Directory(PathHelper.gamesDir);
      if (!await gamesDir.exists()) return 0;
      int size = 0;
      await for (final entity in gamesDir.list(followLinks: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (name.contains('_temp_layer_')) {
            size += await _dirSize(entity);
          }
        }
      }
      return size;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _downloadArchivesSize() async {
    try {
      final dlDir = Directory(PathHelper.downloadsDir);
      if (!await dlDir.exists()) return 0;
      int size = 0;
      await for (final entity in dlDir.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          final isArchive = name.endsWith('.zip') ||
              name.endsWith('.rar') ||
              name.endsWith('.7z') ||
              name.endsWith('.tar');
          // ★ 2026-09-26 P2-2：统计口径与清理一致（无活跃下载时才计入分片残留）
          final isPartChunk =
              name.contains('.part_') && name.endsWith('.tmp');
          if (isArchive || (isPartChunk && !DownloadCore.hasActiveTask)) {
            try {
              size += await entity.length();
            } catch (_) {}
          }
        }
      }
      return size;
    } catch (_) {
      return 0;
    }
  }

  // ==================== 文件系统辅助 ====================

  Future<int> _dirSize(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      int size = 0;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            size += await entity.length();
          } catch (_) {}
        }
      }
      return size;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _fileSize(File file) async {
    try {
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _clearDirectoryContents(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      try {
        if (entity is File) {
          await entity.delete();
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 供 UI 复用的字节格式化。
  static String formatBytes(int bytes) => _fmtBytes(bytes);
}

/// 单元清理内部结果。
class _UnitCleanup {
  final int freed;
  final bool ok;
  final String message;
  const _UnitCleanup({
    required this.freed,
    required this.ok,
    required this.message,
  });
}

/// 缓存阈值检查结果。
class CacheThreshold {
  final String unitId;
  final String unitLabel;
  final int currentBytes;
  final int thresholdBytes;

  const CacheThreshold({
    required this.unitId,
    required this.unitLabel,
    required this.currentBytes,
    required this.thresholdBytes,
  });

  bool get exceeded => currentBytes > thresholdBytes;
  double get usagePercent => currentBytes / thresholdBytes;
  String get warningMessage =>
      '$unitLabel 已超过阈值 (${StorageCleanupService.formatBytes(currentBytes)} / ${StorageCleanupService.formatBytes(thresholdBytes)})';
}
