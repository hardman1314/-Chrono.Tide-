import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';
import 'storage_cleanup_service.dart';

/// 磁盘图片缓存字节配额自动淘汰服务。
///
/// flutter_cache_manager 内置淘汰按「对象个数」(`maxNrOfCacheObjects`) 而非
/// 字节，大图（4K 截图可达 5-10MB/张）场景下磁盘占用可能失控。本服务补上
/// **字节级配额**：
/// - 定期扫描 `data/cache/images` 的真实字节（与设置页口径一致）；
/// - 超过 [quotaBytes] 时，按 `CacheObject.touched`（最后使用，Dart clock
///   毫秒精度）升序淘汰至 [targetBytes]；
/// - 遵守 ADR-008：淘汰排序用 repo 内 `touched`，**不用文件系统时间戳**；
/// - 遵守 ADR-007：仅删应用自有目录（`isInsideAppStorage`）内的可再生图片
///   缓存，绝不动游戏/下载/用户数据。
///
/// 触发点设在 [PortableImageCacheManager] 构造体内（attach），避免触碰
/// main.dart / main_container.dart 稳定区。
class CacheQuotaService {
  CacheQuotaService._();
  static final CacheQuotaService instance = CacheQuotaService._();

  /// 缓存配额上限（字节）。与 [StorageCleanupService.checkThresholds] 的
  /// perUnitThreshold(500MB) 对齐。
  static const int quotaBytes = 500 * 1024 * 1024;

  /// 淘汰后目标值（字节）。
  static const int targetBytes = 400 * 1024 * 1024;

  /// 单轮最多淘汰对象数，防止阻塞 UI。
  static const int maxEvictPerRound = 200;

  /// 首次运行延迟（避开启动期）。
  static const Duration firstRunDelay = Duration(seconds: 60);

  /// 后续周期。
  static const Duration period = Duration(minutes: 30);

  CacheManager? _manager;
  CacheInfoRepository? _repo;
  bool _running = false;

  bool get isAttached => _manager != null;

  /// 挂载管理器与元数据仓库（幂等），并注册定期淘汰定时器。
  /// 注：Timer 由事件循环持有引用，无需字段保存。
  void attach(CacheManager manager, CacheInfoRepository repo) {
    if (_manager != null) return;
    _manager = manager;
    _repo = repo;
    Timer(firstRunDelay, () {
      Timer.periodic(period, (_) {
        runMaintenance();
        checkAndWarnThresholds();
      });
      runMaintenance();
      checkAndWarnThresholds();
    });
  }

  /// 资源监控：复用 [StorageCleanupService.checkThresholds] 做「超阈值预警」。
  ///
  /// 该方法（总量 1GB / 单元 500MB）此前已实现但从未被调用。这里在每轮
  /// 周期槽内追加检查，超阈值仅写日志**报告**，不自动清理（清理走设置页
  /// 显式操作）。不新增 UI / 持久化，纯轻量即时日志。
  Future<void> checkAndWarnThresholds() async {
    try {
      final exceeded = await StorageCleanupService.instance.checkThresholds();
      for (final t in exceeded) {
        debugPrint(
          '[CacheQuota] ⚠️ ${t.unitLabel}超过阈值 '
          '(${_fmtBytes(t.currentBytes)}/${_fmtBytes(t.thresholdBytes)})',
        );
      }
    } catch (e) {
      debugPrint('[CacheQuota] 阈值检查失败: $e');
    }
  }

  static String _fmtBytes(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

  /// 立即执行一轮配额淘汰（测试可直接调用）。
  ///
  /// 仅当缓存总字节超过配额时才动作；淘汰按最后使用时间升序，
  /// 直到释放到目标值或达到单轮上限。
  ///
  /// [quotaBytesOverride] / [targetBytesOverride] 仅供测试覆盖 500MB 阈值
  /// 使用（生产路径不传，保持默认配额）。
  Future<void> runMaintenance({
    int? quotaBytesOverride,
    int? targetBytesOverride,
  }) async {
    if (_running) return;
    _running = true;
    try {
      final quota = quotaBytesOverride ?? quotaBytes;
      final target = targetBytesOverride ?? targetBytes;
      final size = await _dirSize(Directory(PathHelper.imageCacheDir));
      if (size <= quota) return;

      final repo = _repo;
      final manager = _manager;
      if (repo == null || manager == null) return;

      final objects = await repo.getAllObjects();
      // ADR-008：以 repo 内 touched（最后使用）排序，缺失以 epoch0 兜底，
      // 不信任 Windows 文件系统时间戳。
      final epoch0 = DateTime.fromMillisecondsSinceEpoch(0);
      objects.sort(
        (a, b) => (a.touched ?? epoch0).compareTo(b.touched ?? epoch0),
      );

      final needed = size - target;
      var freed = 0;
      var evicted = 0;
      for (final obj in objects) {
        if (evicted >= maxEvictPerRound) break;
        if (freed >= needed) break;

        final absPath = p.join(
          PathHelper.imageCacheDir,
          'libCachedImageData',
          obj.relativePath,
        );
        // ADR-007 护栏：只删应用自有目录内文件。
        if (!PathHelper.isInsideAppStorage(absPath)) continue;

        final file = File(absPath);
        var fileLen = 0;
        try {
          if (await file.exists()) fileLen = await file.length();
        } catch (_) {}

        try {
          // 清 repo 索引 + 内存缓存（其内部按相对路径删文件在便携目录下无效，无害）。
          await manager.removeFile(obj.key);
          // 显式删除落盘文件（关键：removeFile 内部用 io.File(relativePath)
          // 按 CWD 解析，删不到 <imageCacheDir>/libCachedImageData/ 下的文件）。
          if (await file.exists()) {
            await file.delete();
          }
          freed += fileLen;
          evicted++;
        } catch (e) {
          debugPrint('[CacheQuota] 淘汰失败 ${obj.key}: $e');
        }
      }
      if (evicted > 0) {
        debugPrint(
          '[CacheQuota] 淘汰 $evicted 个缓存对象，释放 '
          '${(freed / 1024 / 1024).toStringAsFixed(1)}MB',
        );
      }
    } catch (e) {
      debugPrint('[CacheQuota] 维护失败: $e');
    } finally {
      _running = false;
    }
  }

  Future<int> _dirSize(Directory dir) async {
    try {
      if (!await dir.exists()) return 0;
      var size = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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
}
