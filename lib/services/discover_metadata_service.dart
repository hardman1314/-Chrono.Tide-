import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/path_helper.dart';
import 'metadata_fetcher.dart';

/// 探索页游戏元数据（仅用于探索页/详情页展示，不写入游戏库）
///
/// 数据来源：MetadataFetcher（VNDB/Bangumi/Steam 等）
/// 缓存策略：内存 + 磁盘双缓存（7 天 TTL），原子写入避免应用退出时文件截断
class DiscoverGameMetadata {
  final String gameId;
  final double? rating; // 0-10
  final int? voteCount; // VNDB 投票数，作为热度代理
  final String? releaseDate; // ISO 格式 YYYY-MM-DD
  final String? developer;
  final String? sourcePlatform; // 数据来源（VNDB/Bangumi/...）
  final DateTime cachedAt;

  const DiscoverGameMetadata({
    required this.gameId,
    required this.cachedAt,
    this.rating,
    this.voteCount,
    this.releaseDate,
    this.developer,
    this.sourcePlatform,
  });

  /// 提取发售年份（用于卡片角标显示）
  int? get releaseYear {
    if (releaseDate == null || releaseDate!.isEmpty) return null;
    return int.tryParse(releaseDate!.substring(0, 4));
  }

  /// 是否有任何可展示的数据
  bool get hasDisplayData =>
      (rating != null && rating! > 0) ||
      releaseYear != null ||
      (voteCount != null && voteCount! > 0);

  factory DiscoverGameMetadata.fromJson(String gameId, Map<String, dynamic> json) {
    return DiscoverGameMetadata(
      gameId: gameId,
      rating: (json['rating'] as num?)?.toDouble(),
      voteCount: (json['vote_count'] as num?)?.toInt(),
      releaseDate: json['release_date'] as String?,
      developer: json['developer'] as String?,
      sourcePlatform: json['source'] as String?,
      cachedAt: json['_cached_at'] != null
          ? DateTime.parse(json['_cached_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'rating': rating,
        'vote_count': voteCount,
        'release_date': releaseDate,
        'developer': developer,
        'source': sourcePlatform,
        '_cached_at': cachedAt.toIso8601String(),
      };
}

/// 探索页元数据懒加载服务
///
/// 设计目标：
/// - 视口懒加载：仅在卡片进入视口时触发抓取，避免一次性拉取 250 个游戏
/// - 单游戏并发合并：同一 gameId 的并发请求合并为一个 Future
/// - 全局并发=1：一次只抓一个游戏（MetadataFetcher 内部已 5 源并发）
/// - 7 天磁盘缓存：二次访问瞬时显示
/// - 原子写入：先写 .tmp 再 rename，避免应用退出时文件截断
class DiscoverMetadataService extends ChangeNotifier {
  static final DiscoverMetadataService _instance =
      DiscoverMetadataService._internal();
  static DiscoverMetadataService get instance => _instance;

  DiscoverMetadataService._internal();

  /// 缓存 TTL：7 天（比 MetadataFetcher 的 24h 长，因为只存派生显示数据）
  static const Duration _cacheTtl = Duration(days: 7);

  /// 内存缓存：gameId → 元数据
  final Map<String, DiscoverGameMetadata> _cache = {};

  /// 进行中的抓取：gameId → Future（避免并发重复抓取）
  final Map<String, Future<void>> _inFlight = {};

  /// 全局抓取队列锁：保证一次只抓一个游戏
  Completer<void>? _globalLock;

  /// 磁盘缓存文件路径
  String? _cacheFilePath;
  bool _cacheLoaded = false;

  /// 初始化：加载磁盘缓存（应在应用启动时调用）
  Future<void> init() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final cacheDir = Directory(p.join(PathHelper.dataDir, 'cache'));
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      _cacheFilePath = p.join(cacheDir.path, 'discover_metadata.json');
      final file = File(_cacheFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        final now = DateTime.now();
        for (final entry in data.entries) {
          if (entry.value is Map) {
            final cached = Map<String, dynamic>.from(entry.value as Map);
            final cachedAtStr = cached['_cached_at'] as String?;
            if (cachedAtStr != null) {
              final cachedAt = DateTime.parse(cachedAtStr);
              if (now.difference(cachedAt) < _cacheTtl) {
                _cache[entry.key] =
                    DiscoverGameMetadata.fromJson(entry.key, cached);
              }
            }
          }
        }
        debugPrint(
            '[DiscoverMetadata] 📦 已加载磁盘缓存: ${_cache.length} 条');
      }
    } catch (e) {
      debugPrint('[DiscoverMetadata] ⚠️ 加载磁盘缓存失败: $e');
    }
  }

  /// 同步获取已缓存的元数据（卡片 build 时调用）
  ///
  /// 返回 null 表示未抓取或抓取失败，卡片应不显示元数据角标。
  DiscoverGameMetadata? getMetadata(String gameId) => _cache[gameId];

  /// 异步抓取并缓存元数据（卡片进入视口时调用）
  ///
  /// - 如果已缓存且未过期，立即返回
  /// - 如果正在抓取中，返回已有的 Future（合并并发）
  /// - 否则启动新抓取，串行排队（全局并发=1）
  Future<void> ensureMetadata(String gameId, String title) async {
    // 缓存命中
    final existing = _cache[gameId];
    if (existing != null &&
        DateTime.now().difference(existing.cachedAt) < _cacheTtl) {
      return;
    }

    // 进行中合并
    if (_inFlight.containsKey(gameId)) {
      return _inFlight[gameId];
    }

    // 启动新抓取
    final future = _fetchWithGlobalLock(gameId, title);
    _inFlight[gameId] = future;
    return future;
  }

  /// 全局串行锁：保证一次只抓一个游戏
  Future<void> _fetchWithGlobalLock(String gameId, String title) async {
    // 等待前一个抓取完成
    while (_globalLock != null) {
      try {
        await _globalLock!.future;
      } catch (_) {
        // 前一个失败不影响当前
      }
    }

    final completer = Completer<void>();
    _globalLock = completer;

    try {
      await _doFetch(gameId, title);
    } finally {
      _inFlight.remove(gameId);
      _globalLock = null;
      completer.complete();
    }
  }

  /// 实际抓取逻辑
  Future<void> _doFetch(String gameId, String title) async {
    try {
      // 调用 MetadataFetcher（内部已有 24h 缓存 + 5 源并发）
      final results = await MetadataFetcher.fetchGame(title, useCache: true);

      if (results.isEmpty) {
        debugPrint('[DiscoverMetadata] ℹ️ 无元数据: $title');
        return;
      }

      // 挑选最佳结果：优先有 rating 且非零的 VNDB 结果
      Map<String, dynamic>? bestResult;
      for (final result in results) {
        final platform = result['platform'] as String? ?? '';
        final rating = (result['rating'] as num?)?.toDouble() ?? 0.0;
        final voteCount = (result['vote_count'] as num?)?.toInt();

        // 优先 VNDB（有 vote_count）
        if (platform == 'VNDB' && (rating > 0 || voteCount != null)) {
          bestResult = result;
          break;
        }
        // 其次任何有 rating 的结果
        if (bestResult == null && rating > 0) {
          bestResult = result;
        }
      }
      // 兜底：取第一条
      bestResult ??= results.first;

      final metadata = DiscoverGameMetadata(
        gameId: gameId,
        rating: (bestResult['rating'] as num?)?.toDouble(),
        voteCount: (bestResult['vote_count'] as num?)?.toInt(),
        releaseDate: bestResult['release_date'] as String?,
        developer: bestResult['developer'] as String?,
        sourcePlatform: bestResult['platform'] as String?,
        cachedAt: DateTime.now(),
      );

      // 仅当有可展示数据时缓存
      if (metadata.hasDisplayData) {
        _cache[gameId] = metadata;
        _persistCache();
        notifyListeners();
        debugPrint(
            '[DiscoverMetadata] ✅ 抓取成功: $title | rating=${metadata.rating} | votes=${metadata.voteCount} | year=${metadata.releaseYear} | source=${metadata.sourcePlatform}');
      } else {
        debugPrint('[DiscoverMetadata] ℹ️ 抓取到空数据: $title');
      }
    } catch (e) {
      debugPrint('[DiscoverMetadata] ❌ 抓取失败 [$title]: $e');
    }
  }

  /// 原子写入磁盘缓存（先写 .tmp 再 rename，避免应用退出时文件截断）
  Future<void> _persistCache() async {
    if (_cacheFilePath == null) return;
    try {
      final file = File(_cacheFilePath!);
      final tmpPath = '$_cacheFilePath.tmp';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsString(jsonEncode(_cache));
      // Windows 上 rename 会覆盖目标文件
      await tmpFile.rename(_cacheFilePath!);
    } catch (e) {
      debugPrint('[DiscoverMetadata] ⚠️ 持久化缓存失败: $e');
    }
  }

  /// 清空缓存（设置页可调用）
  Future<void> clearCache() async {
    _cache.clear();
    _inFlight.clear();
    if (_cacheFilePath != null) {
      try {
        final file = File(_cacheFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[DiscoverMetadata] ⚠️ 删除磁盘缓存失败: $e');
      }
    }
    notifyListeners();
    debugPrint('[DiscoverMetadata] 🗑️ 缓存已清空');
  }
}
