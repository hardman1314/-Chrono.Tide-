import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/path_helper.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
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

  /// 预计游玩时长（分钟）：VNDB 多用户平均游玩时长（length_minutes）。
  /// null = 数据源未提供（仅 VNDB 提供该字段）。
  final int? estimatedMinutes;
  final DateTime cachedAt;

  /// 是否来自云端（PocketBase games 集合）沉淀的数据
  ///
  /// true = 云端已有、无需再抓取，也无需回传；且不落本地磁盘缓存
  /// （下次启动仍从云端再读一次，避免本地留存过期副本）。
  final bool fromCloud;

  const DiscoverGameMetadata({
    required this.gameId,
    required this.cachedAt,
    this.rating,
    this.voteCount,
    this.releaseDate,
    this.developer,
    this.sourcePlatform,
    this.estimatedMinutes,
    this.fromCloud = false,
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
      (voteCount != null && voteCount! > 0) ||
      (estimatedMinutes != null && estimatedMinutes! > 0);

  DiscoverGameMetadata copyWith({bool? fromCloud}) => DiscoverGameMetadata(
        gameId: gameId,
        rating: rating,
        voteCount: voteCount,
        releaseDate: releaseDate,
        developer: developer,
        sourcePlatform: sourcePlatform,
        estimatedMinutes: estimatedMinutes,
        cachedAt: cachedAt,
        fromCloud: fromCloud ?? this.fromCloud,
      );

  factory DiscoverGameMetadata.fromJson(String gameId, Map<String, dynamic> json) {
    return DiscoverGameMetadata(
      gameId: gameId,
      rating: (json['rating'] as num?)?.toDouble(),
      voteCount: (json['vote_count'] as num?)?.toInt(),
      releaseDate: json['release_date'] as String?,
      developer: json['developer'] as String?,
      sourcePlatform: json['source'] as String?,
      estimatedMinutes: (json['estimated_minutes'] as num?)?.toInt(),
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
        'estimated_minutes': estimatedMinutes,
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
  /// 云端沉淀的数据同样经此返回（见 [registerCloudMetadata]）。
  DiscoverGameMetadata? getMetadata(String gameId) => _cache[gameId];

  // ==================== 云端沉淀数据（v2.1.17）====================
  //
  // 机制与探索页截图一致：云端（PB games 集合）有数据 → 直接用；
  // 没有 → 走既有的抓取流程 → 抓到后回写云端，供其他用户/下次启动复用。
  // 这样探索库不必在每次进入时把全量游戏重跑一遍元数据抓取。

  /// 登记单个游戏的云端元数据（有数据才登记）
  ///
  /// 优先级：**已抓取到的本地结果 > 云端**。本地结果是本轮真实抓取所得，
  /// 不被云端覆盖；云端只负责填补「还没抓过」的空洞。
  void registerCloudMetadata(GameModel game, {bool notify = true}) {
    if (!game.hasCloudMetadata) return;
    final existing = _cache[game.id];
    if (existing != null && !existing.fromCloud) return;

    _cache[game.id] = DiscoverGameMetadata(
      gameId: game.id,
      rating: game.rating,
      voteCount: game.voteCount,
      releaseDate: game.releaseDate.isEmpty ? null : game.releaseDate,
      developer: game.developer.isEmpty ? null : game.developer,
      sourcePlatform: game.metaSource.isEmpty ? null : game.metaSource,
      estimatedMinutes: game.estimatedMinutes,
      cachedAt: DateTime.now(),
      fromCloud: true,
    );
    if (notify) notifyListeners();
  }

  /// 仅供测试：直接写入一条缓存条目（用于验证「本地抓取结果优先」）
  @visibleForTesting
  void putForTest(DiscoverGameMetadata meta) => _cache[meta.gameId] = meta;

  /// 批量登记（探索页/探索库全量加载后调用，只 notify 一次）
  void registerCloudMetadataAll(Iterable<GameModel> games) {
    var added = 0;
    for (final game in games) {
      final before = _cache.length;
      registerCloudMetadata(game, notify: false);
      if (_cache.length > before) added++;
    }
    if (added > 0) {
      debugPrint('[DiscoverMetadata] ☁️ 云端元数据命中 $added 条（免抓取）');
      notifyListeners();
    }
  }

  /// 异步抓取并缓存元数据（卡片进入视口时调用）
  ///
  /// - 如果已缓存且未过期，立即返回
  /// - 如果正在抓取中，返回已有的 Future（合并并发）
  /// - 否则启动新抓取，串行排队（全局并发=1）
  Future<void> ensureMetadata(String gameId, String title) async {
    // 缓存命中；云端沉淀的数据没有 TTL，永不触发重抓
    final existing = _cache[gameId];
    if (existing != null &&
        (existing.fromCloud ||
            DateTime.now().difference(existing.cachedAt) < _cacheTtl)) {
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

  /// 是否需要为「云端条目缺预计时长」补抓（纯判断，便于单测）
  ///
  /// 背景：estimatedMinutes 后于 rating/voteCount 上云（2026-10-04），存量云端
  /// 记录该字段全为默认值 0（模型归一为 null），而 [ensureMetadata] 对
  /// fromCloud 条目永不重抓 → 探索详情页永远看不到预计时长。只补这一个缺口。
  @visibleForTesting
  static bool needsEstimatedMinutesBackfill(DiscoverGameMetadata? existing) =>
      existing != null &&
      existing.fromCloud &&
      existing.estimatedMinutes == null;

  /// 详情页缺口回填：云端沉淀条目缺预计时长时补抓一次
  ///
  /// - 无缓存 → 等价于 [ensureMetadata]（常规抓取路径）；
  /// - 缓存来自云端且缺 estimatedMinutes → 补抓（全局串行锁 + MetadataFetcher
  ///   24h 缓存）。抓到后按「本地抓取 > 云端」覆盖缓存，并经 `_reportToCloud`
  ///   自动回传云端（含 estimatedMinutes），其他用户随后免抓直读；
  /// - 其余情况（本地已抓 / 已有时长）不动。云端无该数据时缓存不更新，
  ///   下次打开详情会再试一次。
  Future<void> ensureEstimatedMinutes(String gameId, String title) async {
    final existing = _cache[gameId];
    if (existing == null) {
      return ensureMetadata(gameId, title);
    }
    if (!needsEstimatedMinutesBackfill(existing)) {
      return;
    }
    // 进行中合并
    if (_inFlight.containsKey(gameId)) {
      return _inFlight[gameId];
    }
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
        estimatedMinutes: (bestResult['length_minutes'] as num?)?.toInt(),
        cachedAt: DateTime.now(),
      );

      // 仅当有可展示数据时缓存
      if (metadata.hasDisplayData) {
        _cache[gameId] = metadata;
        _persistCache();
        notifyListeners();
        debugPrint(
            '[DiscoverMetadata] ✅ 抓取成功: $title | rating=${metadata.rating} | votes=${metadata.voteCount} | year=${metadata.releaseYear} | source=${metadata.sourcePlatform}');
        // 回写云端：此后所有用户都能直接读到，不必再各自抓取
        unawaited(_reportToCloud(gameId, title, metadata));
      } else {
        debugPrint('[DiscoverMetadata] ℹ️ 抓取到空数据: $title');
      }
    } catch (e) {
      debugPrint('[DiscoverMetadata] ❌ 抓取失败 [$title]: $e');
    }
  }

  // ==================== 抓取结果回传云端 ====================

  /// 本轮已回传过的 gameId（避免同一游戏重复 PATCH）
  final Set<String> _uploadedIds = {};

  /// 熔断开关：云端字段缺失/规则收紧时（400/403/404）本次运行不再尝试
  bool _uploadDisabled = false;
  bool _loggedMissingAuth = false;

  /// 把抓取结果回写到云端 games 记录，其他用户可直接读取
  ///
  /// best-effort：任何失败都只记日志，不影响本地展示与缓存。
  Future<void> _reportToCloud(
      String gameId, String title, DiscoverGameMetadata meta) async {
    if (_uploadDisabled) return;
    if (!_uploadedIds.add(gameId)) return;
    if (!GameRepository.canUploadMetadata) {
      if (!_loggedMissingAuth) {
        _loggedMissingAuth = true;
        debugPrint('[DiscoverMetadata] ⏭️ 未登录，抓取结果不回传云端');
      }
      return;
    }

    final status = await GameRepository.updateGameMetadata(
      gameId,
      rating: meta.rating,
      voteCount: meta.voteCount,
      releaseDate: meta.releaseDate,
      metaSource: meta.sourcePlatform,
      estimatedMinutes: meta.estimatedMinutes,
    );

    switch (status) {
      case GameMetadataUploadStatus.ok:
        debugPrint('[DiscoverMetadata] ☁️ 元数据已回传云端: $title');
        break;
      case GameMetadataUploadStatus.rejected:
        // 服务端结构性拒绝：重试无意义，熔断本次运行
        _uploadDisabled = true;
        break;
      default:
        break;
    }
  }

  /// 原子写入磁盘缓存（先写 .tmp 再 rename，避免应用退出时文件截断）
  Future<void> _persistCache() async {
    if (_cacheFilePath == null) return;
    try {
      final file = File(_cacheFilePath!);
      final tmpPath = '$_cacheFilePath.tmp';
      final tmpFile = File(tmpPath);
      // 云端数据不落盘：每次启动重新从云端读，避免本地留存过期副本
      final persistable = <String, dynamic>{
        for (final entry in _cache.entries)
          if (!entry.value.fromCloud) entry.key: entry.value,
      };
      await tmpFile.writeAsString(jsonEncode(persistable));
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
