import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import '../core/path_helper.dart';
import 'system_proxy_detector.dart';

/// 元数据抓取统一调度器
///
/// 职责：
/// 1. 并发查询多个数据源（Future.wait，4源并行将最坏耗时从200秒降至~15秒）
/// 2. 磁盘持久化缓存（24h TTL，应用重启不丢失）
/// 3. 数据源可配置（用户可在设置页勾选启用源）
/// 4. 字段格式转换（_convertToLegacyFormat，保留 rating/tags权重 等元数据）
class MetadataFetcher {
  /// TouchGal API Bearer Token（硬编码预留位）
  ///
  /// **填写方式**：用户从 https://developer.touchgal.com 申请到 Token 后，
  /// 将其粘贴到此处字符串中即可启用 TouchGal 数据源。
  /// - 留空（默认）：TouchGal 不生效，[SourceType.touchgal] 不会被启用。
  /// - 非空：自动通过 [touchGalToken] getter 暴露给 [TouchGalService]。
  ///
  /// 注：LunaBox 项目通过 GitHub Actions secrets 在编译时 ldflags 注入，
  /// 本项目改为源码常量以简化构建流程；Token 不会随应用启动加载/保存到
  /// SharedPreferences，用户无需在 UI 中填写。
  static const String kTouchGalApiToken =
      'tgal_live_nmnc-ZLyGctzGYQS7160Ruzff7UvaTcKen47wU8phkw';

  static String? _proxyUrl;
  static String? _resolvedProxyUrl; // 三级解析后的最终代理 URL（app配置 > 系统代理）
  static Dio? _dio;

  // 服务实例缓存（P0.3）
  // 避免每次 _createService 创建新实例，导致服务内的 Token 缓存
  // （如 YmgalService._cachedToken）随实例销毁而失效。
  // 代理变更时通过 _clearServiceCache 清空重建。
  static final Map<SourceType, MetadataSourceService> _serviceCache = {};

  // 内存缓存（热数据，启动时从磁盘加载）
  static final Map<String, Map<String, dynamic>> _cache = {};
  static const Duration _cacheTtl = Duration(hours: 24);

  // 磁盘缓存文件路径（延迟初始化）
  static String? _cacheFilePath;
  static bool _cacheLoaded = false;

  // 用户启用的数据源（默认4源，可通过 setEnabledSources 配置）
  // TouchGal 默认不启用：国内 SNI 阻断需代理，未配代理时开启只会增加超时
  static List<SourceType> _enabledSources = [
    SourceType.vndb,
    SourceType.bangumi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.hikarinagi,
  ];

  /// 初始化：加载代理设置 + 数据源配置 + 磁盘缓存
  ///
  /// TouchGal Token 不再从磁盘加载，改为源码常量 [kTouchGalApiToken]。
  static Future<void> init() async {
    // 设置抓取日志路径（release 模式下诊断各平台抓取失败原因）
    setFetchLogPath(p.join(PathHelper.dataDir, 'metadata_fetch.log'));
    fetchLog('[MetadataFetcher] ===== init() 开始 =====');
    await _loadProxySettings();
    await _loadEnabledSources();
    await _initDio();
    fetchLog(
        '[MetadataFetcher] 启用数据源: ${_enabledSources.map((s) => s.displayName).join(", ")}');
    fetchLog('[MetadataFetcher] 已解析代理: ${_resolvedProxyUrl ?? "无（直连）"}');
    // 加载 VNDB 大数据翻译资源（~2990 条标签），失败时静默降级
    await TagTranslator.initialize();
    await _loadDiskCache();
    fetchLog('[MetadataFetcher] ===== init() 完成 =====');
  }

  // ==================== 代理设置 ====================

  static Future<void> _loadProxySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _proxyUrl = prefs.getString('proxy_url');
      if (_proxyUrl != null && _proxyUrl!.isNotEmpty) {
        debugPrint('[MetadataFetcher] ✅ 已加载代理: $_proxyUrl');
      }
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载代理设置失败: $e');
    }
  }

  /// 初始化全局 Dio，配置代理
  ///
  /// 代理优先级（参考 LunaBox 的 `ResolveProxy`，保证与浏览器行为一致）：
  /// 1. **app 配置** (`_proxyUrl`)：用户在设置页手动填写的代理，优先级最高
  /// 2. **Windows 系统代理**：读取注册表 IE 代理设置（Clash/V2Ray "系统代理"
  ///    模式写入的值），让本软件能像浏览器一样自动使用系统代理
  /// 3. **环境变量** (`HTTP_PROXY`/`HTTPS_PROXY`)：Dart 原生
  ///    `HttpClient.findProxyFromEnvironment` 的回退
  ///
  /// 背景：原实现仅在 `_proxyUrl` 非空时配代理，不读系统代理设置，
  /// 导致用户已在 Windows 配置好可访问 TouchGal/DLsite 等平台的环境，
  /// 本软件仍走直连而失败（浏览器却能正常打开）。
  static Future<void> _initDio() async {
    _dio = Dio(BaseOptions(
      // P0.1：缩短超时，单源最坏从 30s 降至 15s，配合并发降低总耗时
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
      },
    ));

    // 代理优先级：app配置 > Windows系统代理 > 环境变量
    String? effectiveProxy = _proxyUrl;
    String proxySource = 'app配置';
    if (effectiveProxy == null || effectiveProxy.isEmpty) {
      effectiveProxy = await SystemProxyDetector.detectProxy();
      if (effectiveProxy != null) {
        proxySource = 'Windows系统代理';
      }
    }
    if (effectiveProxy != null) {
      debugPrint(
          '[MetadataFetcher] 🌐 检测到代理 ($proxySource): $effectiveProxy，正在验证...');
    } else {
      debugPrint('[MetadataFetcher] ℹ️ 无显式代理，回退环境变量检测');
    }

    _resolvedProxyUrl = effectiveProxy;
    final proxy = await _validateProxy(effectiveProxy);
    if (proxy != null) {
      debugPrint('[MetadataFetcher] ✅ 代理已启用: $proxy');
    } else if (effectiveProxy != null) {
      debugPrint('[MetadataFetcher] ⚠️ 代理验证失败或不可用，需代理平台将走直连（可能失败）');
    }
    (_dio!.httpClientAdapter as DefaultHttpClientAdapter).onHttpClientCreate =
        (client) {
      if (proxy != null && proxy.isNotEmpty) {
        client.findProxy = (uri) => 'PROXY $proxy';
      } else {
        // 无显式代理时，让 Dart HttpClient 自动检测环境变量代理
        client.findProxy = HttpClient.findProxyFromEnvironment;
      }
      return client;
    };
  }

  /// 验证代理服务器是否可连接
  ///
  /// 从 Windows 注册表检测到的系统代理可能已失效（用户关闭了 Clash/V2Ray
  /// 但注册表未清理）。本方法通过 TCP 连接测试代理是否存活：
  /// - 连接成功 → 返回代理 URL，正常使用
  /// - 连接失败 → 返回 null（放弃代理，直连），并记录警告
  /// - 代理为 null → 直接返回 null
  ///
  /// 超时设为 2 秒，不影响启动速度。
  static Future<String?> _validateProxy(String? proxyUrl) async {
    if (proxyUrl == null || proxyUrl.isEmpty) return null;

    // 解析 host:port（支持 http://host:port / host:port / socks5://host:port）
    String host;
    int port;
    try {
      Uri uri;
      if (proxyUrl.startsWith('http://') || proxyUrl.startsWith('https://')) {
        uri = Uri.parse(proxyUrl);
        host = uri.host;
        port = uri.port;
      } else if (proxyUrl.startsWith('socks')) {
        uri = Uri.parse(proxyUrl);
        host = uri.host;
        port = uri.port;
      } else {
        // 纯 host:port 格式
        final parts = proxyUrl.split(':');
        host = parts[0];
        port = int.parse(parts[1]);
      }
      if (host.isEmpty || port <= 0) return null;
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 代理 URL 解析失败: $proxyUrl → 直连');
      return null;
    }

    // TCP 连接测试（2秒超时）
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      socket.destroy();
      debugPrint('[MetadataFetcher] ✅ 代理验证通过: $host:$port');
      return proxyUrl;
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 代理 $host:$port 不可连接（可能已关闭），放弃代理走直连');
      return null;
    }
  }

  static Future<void> updateProxy(String? proxyUrl) async {
    _proxyUrl = proxyUrl;

    final prefs = await SharedPreferences.getInstance();
    if (proxyUrl != null && proxyUrl.isNotEmpty) {
      await prefs.setString('proxy_url', proxyUrl);
      debugPrint('[MetadataFetcher] ✅ 代理已保存: $proxyUrl');
    } else {
      await prefs.remove('proxy_url');
      debugPrint('[MetadataFetcher] ✅ 代理已清除');
    }

    // P0.3：代理变更后旧服务实例的 Dio 配置已失效，需清空重建
    _clearServiceCache();
    await _initDio();
  }

  /// 清空服务实例缓存（P0.3）
  ///
  /// 在代理变更、或需要强制重建服务（如清空缓存）时调用。
  static void _clearServiceCache() {
    _serviceCache.clear();
    debugPrint('[MetadataFetcher] 🧹 服务实例缓存已清空');
  }

  // ==================== TouchGal Token ====================

  /// 获取当前 TouchGal Token
  ///
  /// 直接返回源码硬编码常量 [kTouchGalApiToken]（非空时启用 TouchGal 数据源）。
  /// 注：原 SharedPreferences 持久化已废弃，请直接修改源码常量。
  static String? get touchGalToken =>
      kTouchGalApiToken.isEmpty ? null : kTouchGalApiToken;

  // ==================== 数据源配置 ====================

  static Future<void> _loadEnabledSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('enabled_metadata_sources');
      if (saved != null && saved.isNotEmpty) {
        final loaded = <SourceType>[];
        for (final name in saved) {
          final match = SourceType.values.where((e) => e.name == name);
          if (match.isNotEmpty && match.first != SourceType.local) {
            loaded.add(match.first);
          }
        }
        if (loaded.isNotEmpty) {
          _enabledSources = loaded;
        }
      }
      debugPrint(
          '[MetadataFetcher] ✅ 启用数据源: ${_enabledSources.map((s) => s.displayName).join(", ")}');
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载数据源配置失败: $e');
    }
  }

  /// 设置启用的数据源（用户在设置页修改后调用）
  ///
  /// 会清空缓存（数据源变化后旧缓存失效）
  static Future<void> setEnabledSources(List<SourceType> sources) async {
    if (sources.isEmpty) {
      debugPrint('[MetadataFetcher] ⚠️ 数据源列表为空，忽略');
      return;
    }
    _enabledSources = sources;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enabled_metadata_sources',
      sources.map((s) => s.name).toList(),
    );
    // 数据源变化后旧缓存失效
    clearCache();
    debugPrint(
        '[MetadataFetcher] ✅ 数据源已更新: ${sources.map((s) => s.displayName).join(", ")}');
  }

  /// 获取当前启用的数据源（供设置页展示）
  static List<SourceType> getEnabledSources() =>
      List.unmodifiable(_enabledSources);

  /// 获取所有可选数据源（除 local 外）
  static List<SourceType> getAvailableSources() =>
      SourceType.values.where((s) => s != SourceType.local).toList();

  // ==================== 磁盘缓存持久化 ====================

  static String get _cacheDirPath => p.join(PathHelper.dataDir, 'cache');

  static Future<void> _loadDiskCache() async {
    if (_cacheLoaded) return;
    try {
      _cacheFilePath = p.join(_cacheDirPath, 'metadata_cache.json');
      final file = File(_cacheFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        // 清理过期缓存
        final now = DateTime.now();
        for (final entry in data.entries) {
          if (entry.value is Map) {
            final cached = Map<String, dynamic>.from(entry.value);
            final cachedAtStr = cached['_cached_at'] as String?;
            if (cachedAtStr != null) {
              final cachedAt = DateTime.parse(cachedAtStr);
              if (now.difference(cachedAt) < _cacheTtl) {
                _cache[entry.key] = cached;
              }
            }
          }
        }
        debugPrint('[MetadataFetcher] 📦 已加载磁盘缓存: ${_cache.length} 条');
      }
      _cacheLoaded = true;
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载磁盘缓存失败: $e');
      _cacheLoaded = true;
    }
  }

  static Future<void> _persistCache() async {
    if (_cacheFilePath == null) return;
    try {
      final file = File(_cacheFilePath!);
      final dir = Directory(p.dirname(_cacheFilePath!));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(_cache));
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 持久化缓存失败: $e');
    }
  }

  // ==================== 核心抓取（并发）====================

  /// 抓取游戏元数据
  ///
  /// 性能优化：并发查询所有启用数据源（Future.wait），
  /// 最坏耗时从串行 200秒 降至单源最慢决定（约15秒）。
  ///
  /// - [gameName] 游戏名称
  /// - [preferredSource] 指定单源查询（为 null 时使用 _enabledSources）
  /// - [useCache] 是否使用缓存
  static Future<List<Map<String, dynamic>>> fetchGame(
    String gameName, {
    SourceType? preferredSource,
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) {
      return [];
    }
    fetchLog(
        '[MetadataFetcher] >>> fetchGame("$gameName") sources=${preferredSource?.name ?? "all enabled"} useCache=$useCache');

    final cacheKey = '${preferredSource?.name ?? "all"}:$gameName';

    // 缓存命中检查
    if (useCache && _cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      final cachedAtStr = cached['_cached_at'] as String?;
      if (cachedAtStr != null) {
        final cachedAt = DateTime.parse(cachedAtStr);
        if (DateTime.now().difference(cachedAt) < _cacheTtl) {
          debugPrint('[MetadataFetcher] 📦 使用缓存: $gameName');
          // 缓存可能存储多个结果（_results 字段）
          final cachedResults = cached['_results'];
          if (cachedResults is List) {
            return cachedResults
                .map((r) => r is Map
                    ? Map<String, dynamic>.from(r)
                    : <String, dynamic>{})
                .where((r) => r.isNotEmpty)
                .toList();
          }
          // 兼容旧格式（单个结果）
          return [Map<String, dynamic>.from(cached)..remove('_cached_at')];
        }
      }
      _cache.remove(cacheKey);
    }

    try {
      final sources =
          preferredSource != null ? [preferredSource] : _enabledSources;

      // ===== 并发查询所有数据源 =====
      // 每个源独立 try-catch，单源失败不影响其他源
      final futures = sources.map((source) async {
        final sw = Stopwatch()..start();
        try {
          final service = _createService(source);
          final result = await service.fetchByName(gameName);
          sw.stop();
          if (result.isValid) {
            fetchLog(
                '[MetadataFetcher] [$source] ✅ 成功 (${sw.elapsedMilliseconds}ms) name="${result.game.name}" id=${result.game.id}');
            return _convertToLegacyFormat(result);
          }
          fetchLog(
              '[MetadataFetcher] [$source] ⚠️ 无效结果 (${sw.elapsedMilliseconds}ms) name="${result.game.name}" id="${result.game.id}"');
          return null;
        } catch (e) {
          sw.stop();
          fetchLog(
              '[MetadataFetcher] [$source] ❌ 异常 (${sw.elapsedMilliseconds}ms): $e');
          return null;
        }
      });

      final results = (await Future.wait(futures))
          .whereType<Map<String, dynamic>>()
          .toList();

      // 缓存写入（持久化到磁盘）
      if (results.isNotEmpty) {
        _cache[cacheKey] = {
          '_cached_at': DateTime.now().toIso8601String(),
          '_results': results,
        };
        // 异步持久化，不阻塞返回
        _persistCache();
      }

      debugPrint(
          '[MetadataFetcher] ✅ 查询完成: $gameName → ${results.length} 条结果 (并发${sources.length}源)');
      return results;
    } catch (e) {
      debugPrint('[MetadataFetcher] ❌ 总体错误: $e');
      return [];
    }
  }

  /// 获取/创建数据源服务（P0.3：带实例缓存）
  ///
  /// 命中缓存直接返回，否则创建并缓存。关键收益：服务内的 Token 缓存
  /// （如 YmgalService._cachedToken）跨多次 fetchGame 复用，避免每个游戏
  /// 都重新获取 Token。代理变更时通过 [_clearServiceCache] 清空重建。
  static MetadataSourceService _createService(SourceType sourceType) {
    final cached = _serviceCache[sourceType];
    if (cached != null) return cached;

    final service = _instantiateService(sourceType);
    _serviceCache[sourceType] = service;
    return service;
  }

  static MetadataSourceService _instantiateService(SourceType sourceType) {
    // ===== 对齐 LunaBox：所有平台统一继承全局智能代理配置 =====
    // 全局 _dio 已通过三级检测（app配置 > Windows系统代理 > 环境变量）
    // + TCP 存活验证确定最终代理：可用代理→走代理；死代理/无代理→直连。
    // 每个服务创建自己的 Dio（含专属 headers），通过 applyProxyConfig
    // 复制全局 onHttpClientCreate 回调（独立 adapter，非共享）。
    //
    // 这样无论用户网络环境如何都能正确访问：
    // - 开启代理：所有平台走可用代理（含国内可直连平台，代理也能转发）
    // - 关闭代理但残留注册表：_validateProxy 排除死代理 → 直连
    // - 完全无代理：findProxyFromEnvironment → 直连（VNDB 等国内可直连平台正常）
    switch (sourceType) {
      case SourceType.vndb:
        return VNDBService(dio: _dio);
      case SourceType.steam:
        return SteamService(dio: _dio);
      case SourceType.ymgal:
        return YmgalService(dio: _dio);
      case SourceType.kun:
        return KunService(dio: _dio);
      case SourceType.hikarinagi:
        return HikarinagiService(dio: _dio);
      case SourceType.bangumi:
        return BangumiMirrorService(dio: _dio);
      case SourceType.dlsite:
        return DLsiteService(dio: _dio);
      case SourceType.erogamescape:
        return ErogameScapeService(dio: _dio);
      case SourceType.touchgal:
        return TouchGalService(dio: _dio, token: kTouchGalApiToken);
      default:
        throw ArgumentError('不支持的数据源: $sourceType');
    }
  }

  /// 字段格式转换
  ///
  /// 数据质量修复（Phase 2.1）：
  /// - 补回 rating 字段（之前完全丢失）
  /// - 保留 tags 权重/剧透/来源元数据（tags_meta 字段）
  /// - platform 使用 displayName（如"VNDB"而非"vndb"）
  /// 阶段3.1：补回 vote_count 字段（VNDB 投票数，作为热度代理）
  static Map<String, dynamic> _convertToLegacyFormat(MetadataResult result) {
    final game = result.game;

    return {
      'game_name': game.name,
      'platform': game.sourceType.displayName,
      'platform_id': game.sourceId ?? game.id,
      // 标签名称列表（向后兼容）
      'tags': result.tags.map((tag) => tag.name).toList(),
      // 标签元数据列表（保留权重/剧透/来源，供UI排序和过滤使用）
      'tags_meta': result.tags
          .map((tag) => {
                'name': tag.name,
                'weight': tag.weight,
                'is_spoiler': tag.isSpoiler,
                'source': tag.source,
              })
          .toList(),
      // 补回评分字段（之前完全丢失）
      'rating': game.rating,
      // 补回投票数字段（热度代理，VNDB 提供，其他源为 null）
      'vote_count': game.voteCount,
      'summary': game.summary ?? '',
      'cover_url': game.coverUrl ?? '',
      'release_date': game.releaseDate ?? '',
      'developer': game.company ?? '',
      'screenshot_urls': game.screenshotUrls ?? [],
    };
  }

  static Future<bool> testConnection(SourceType source) async {
    try {
      final service = _createService(source);
      return await service.testConnection();
    } catch (e) {
      debugPrint('[MetadataFetcher] 连接测试失败 [$source]: $e');
      return false;
    }
  }

  /// 并发测试所有数据源连接（之前为串行）
  static Future<Map<SourceType, bool>> testAllConnections() async {
    final sources = SourceType.values.where((s) => s != SourceType.local);
    final futures = sources.map((source) async {
      return MapEntry(source, await testConnection(source));
    });

    final entries = await Future.wait(futures);
    return Map.fromEntries(entries);
  }

  /// 清空缓存（内存 + 磁盘）
  ///
  /// 注意：返回 Future<void>，调用方应 await（或在异步上下文中 fire-and-forget）
  static Future<void> clearCache() async {
    _cache.clear();
    if (_cacheFilePath != null) {
      try {
        final file = File(_cacheFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[MetadataFetcher] ⚠️ 删除磁盘缓存失败: $e');
      }
    }
    debugPrint('[MetadataFetcher] 🗑️ 缓存已清空（内存+磁盘）');
  }

  static String? get currentProxy => _proxyUrl;
}
