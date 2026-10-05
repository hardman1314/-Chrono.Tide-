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

  /// 磁盘缓存版本：数据源解析逻辑变更时递增，旧缓存整体自动失效
  ///
  /// v3：MIX 与独立平台数据共存（此前 MIX 启用时会抑制底层平台条目）
  /// v4：接入 NextMoe（六源对齐目录）为 MIX 全字段第一优先级
  /// v5：接入 CT 探索库（MIX 第二优先级 + 独立条目）
  static const int _cacheVersion = 5;

  /// 数据源的规范展示顺序（唯一顺序来源）
  ///
  /// 「抓取数据源设定」弹窗的列表、默认启用顺序、以及抓取结果条目的
  /// 排列顺序全部以此为准，避免出现"列表一个顺序 / 结果另一个顺序"。
  ///
  /// 顺序约定（产品需求）：
  /// 1. MIX源（整合源，最顶部）
  /// 2. VNDB
  /// 3. KunGal
  /// 4. Hikarinagi
  /// 5. 月幕GAL
  /// 6. Steam
  /// 7. Bangumi
  /// 8. DLsite
  /// 9. ErogameScape
  /// 10. TouchGal（未列入产品清单，统一排在最末）
  static const List<SourceType> kSourceOrder = [
    SourceType.mix,
    SourceType.nextmoe,
    // CT 探索库（自有平台）：产品需求——优先级 NextMoe 之下、VNDB 之上
    SourceType.ct,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
    SourceType.dlsite,
    SourceType.erogamescape,
    SourceType.touchgal,
  ];

  /// 数据源在规范顺序中的位次（未登记则返回末尾大值，保证不丢源）
  static int _sourceOrderIndexOf(SourceType source) {
    final index = kSourceOrder.indexOf(source);
    return index < 0 ? kSourceOrder.length : index;
  }

  /// 将任意数据源集合按 [kSourceOrder] 规范排序
  ///
  /// 未登记的新数据源按枚举顺序追加在末尾，避免将来新增平台时从列表中丢失。
  static List<SourceType> sortSourcesByDisplayOrder(
      Iterable<SourceType> sources) {
    final list = sources.where((s) => s != SourceType.local).toList();
    list.sort((a, b) {
      final c = _sourceOrderIndexOf(a).compareTo(_sourceOrderIndexOf(b));
      if (c != 0) return c;
      return a.index.compareTo(b.index);
    });
    return list;
  }

  // 用户启用的数据源（默认 MIX + 6 独立源，可通过 setEnabledSources 配置）
  // TouchGal 默认不启用：国内 SNI 阻断需代理，未配代理时开启只会增加超时
  // KunGal：公开 API，详情含 vndb_id 可跨源补全 VNDB 评分/投票数/截图
  // MIX：整合源。整合范围固定为全部 5 底层平台（不随各平台开关变化，
  //      避免关闭部分平台后 MIX 退化为单源数据）；平台开关仅控制
  //      一键抓取列表中的独立条目。批量导入默认直接采用 MIX 整合结果
  // 顺序与 [kSourceOrder] 保持一致（见上）
  static List<SourceType> _enabledSources = [
    SourceType.mix,
    SourceType.nextmoe,
    SourceType.ct,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
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
          // 一次性迁移：MIX 源上线前的老配置不含 mix，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final migrated = prefs.getBool('mix_source_migrated') ?? false;
          if (!migrated) {
            await prefs.setBool('mix_source_migrated', true);
            if (!loaded.contains(SourceType.mix)) {
              loaded.insert(0, SourceType.mix);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：MIX 源已默认开启');
            }
          }
          // 一次性迁移：NextMoe 源上线前的老配置不含 nextmoe，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final nmMigrated = prefs.getBool('nextmoe_source_migrated') ?? false;
          if (!nmMigrated) {
            await prefs.setBool('nextmoe_source_migrated', true);
            if (!loaded.contains(SourceType.nextmoe)) {
              loaded.insert(0, SourceType.nextmoe);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：NextMoe 源已默认开启');
            }
          }
          // 一次性迁移：CT 探索库源上线前的老配置不含 ct，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final ctMigrated = prefs.getBool('ct_source_migrated') ?? false;
          if (!ctMigrated) {
            await prefs.setBool('ct_source_migrated', true);
            if (!loaded.contains(SourceType.ct)) {
              loaded.insert(0, SourceType.ct);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：CT 探索库源已默认开启');
            }
          }
          // 老配置可能是任意顺序（含升级前保存的枚举顺序），
          // 统一规范化为 kSourceOrder，保证弹窗勾选顺序与抓取结果顺序一致
          _enabledSources = sortSourcesByDisplayOrder(loaded);
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
    final ordered = sortSourcesByDisplayOrder(sources);
    _enabledSources = ordered;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enabled_metadata_sources',
      ordered.map((s) => s.name).toList(),
    );
    // 数据源变化后旧缓存失效
    clearCache();
    debugPrint(
        '[MetadataFetcher] ✅ 数据源已更新: ${sources.map((s) => s.displayName).join(", ")}');
  }

  /// 获取当前启用的数据源（供设置页展示）
  static List<SourceType> getEnabledSources() =>
      List.unmodifiable(_enabledSources);

  /// 获取所有可选数据源（除 local 外），按 [kSourceOrder] 规范顺序返回
  ///
  /// 弹窗列表与抓取结果条目共用此顺序。
  static List<SourceType> getAvailableSources() =>
      sortSourcesByDisplayOrder(SourceType.values);

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
        // 版本不匹配 → 旧缓存整体作废并删除（解析逻辑变更后旧结果不可信）
        if (data['_version'] != _cacheVersion) {
          await file.delete();
          debugPrint('[MetadataFetcher] 🗑️ 缓存版本不匹配（v$_cacheVersion），旧缓存已失效');
          _cacheLoaded = true;
          return;
        }
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
      await file
          .writeAsString(jsonEncode({..._cache, '_version': _cacheVersion}));
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
    // MIX 为整合源：路由到 fetchGameMixed（无独立抓取服务）
    if (preferredSource == SourceType.mix) {
      final mixed = await fetchGameMixed(gameName, useCache: useCache);
      return mixed == null ? [] : [mixed];
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
      // 启用的独立数据源（preferredSource 单源模式时仅该源）
      final independent = preferredSource != null
          ? [preferredSource]
          : _enabledSources.where((s) => s != SourceType.mix).toList();
      final mixEnabled = preferredSource == null
          ? _enabledSources.contains(SourceType.mix)
          : preferredSource == SourceType.mix;

      // 实际发起请求的源集合：
      // - 全部已启用的独立源（各自返回独立条目，供用户对比选择）
      // - MIX 启用时补充其**全部**底层平台（MIX 整合范围固定为 5 平台，
      //   不随各平台开关变化；未启用的底层平台仅供电整合取数，
      //   不作为独立条目返回——用户未开启它们）。
      //   已启用的底层平台只请求一次，结果同时用于独立条目与 MIX 整合
      final fetchSet = <SourceType>{...independent};
      if (mixEnabled) {
        fetchSet.addAll(_mixSources);
      }

      // ===== 并发查询所有数据源 =====
      // 每个源独立 try-catch，单源失败不影响其他源
      final perSource = <SourceType, Map<String, dynamic>>{};
      final futures = fetchSet.map((source) async {
        final sw = Stopwatch()..start();
        try {
          final service = _createService(source);
          final result = await service.fetchByName(gameName);
          sw.stop();
          if (result.isValid) {
            final legacy = _convertToLegacyFormat(result);
            perSource[source] = legacy;
            fetchLog(
                '[MetadataFetcher] [$source] ✅ 成功 (${sw.elapsedMilliseconds}ms) name="${result.game.name}" id=${result.game.id}');
            // 仅已启用的独立源返回条目；MIX 专用补充源只供整合
            return independent.contains(source) ? legacy : null;
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

      var results = (await Future.wait(futures))
          .whereType<Map<String, dynamic>>()
          .toList();

      // MIX 整合条目：由本轮已抓取的底层平台结果合成（零额外请求），
      // 置于列表首位（综合推荐项），与其余平台的独立条目共存，
      // 供用户在多平台数据间自行选择
      if (mixEnabled) {
        final mixPerSource = <SourceType, Map<String, dynamic>>{};
        for (final entry in perSource.entries) {
          if (_mixSources.contains(entry.key)) {
            mixPerSource[entry.key] = entry.value;
          }
        }
        if (mixPerSource.isNotEmpty) {
          results.insert(0, _mergeMixResults(mixPerSource));
          fetchLog(
              '[MetadataFetcher] [mix] ✅ 整合条目已加入结果 (${mixPerSource.length}平台命中)');
        } else {
          fetchLog('[MetadataFetcher] [mix] ⚠️ 底层平台均无数据，无 MIX 条目');
        }
      }

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
          '[MetadataFetcher] ✅ 查询完成: $gameName → ${results.length} 条结果 (并发${fetchSet.length}源, MIX=${mixEnabled ? "开" : "关"})');
      return results;
    } catch (e) {
      debugPrint('[MetadataFetcher] ❌ 总体错误: $e');
      return [];
    }
  }

  // ==================== MIX 源（多平台字段级整合）====================

  /// MIX 源整合的底层平台（月幕GAL = ymgal）
  static const List<SourceType> _mixSources = [
    SourceType.nextmoe,
    SourceType.ct,
    SourceType.vndb,
    SourceType.hikarinagi,
    SourceType.kun,
    SourceType.steam,
    SourceType.ymgal,
  ];

  // 仅供单元测试 / 离线探针：只读暴露 MIX 整合配置（勿在业务代码使用）
  @visibleForTesting
  static List<SourceType> get mixSourcesForTest =>
      List.unmodifiable(_mixSources);

  @visibleForTesting
  static Map<String, List<SourceType>> get mixFieldPriorityForTest =>
      _mixFieldPriority;

  /// MIX 源各数据字段抓取优先级（高 → 低）
  ///
  /// NextMoe 为六源对齐目录（VNDB/Bangumi/DLsite/ErogameScape/Ci-en/
  /// Getchu 逐字段裁定的标准答案），作为**所有字段的第一优先级**；
  /// CT 探索库（自有平台，社区共建中文元数据）按产品需求列第二优先级
  /// （NextMoe 之下、VNDB 之上）；其余平台保持原有相对顺序依次降级
  /// （NextMoe/CT 缺失/异常时后退）。
  static const Map<String, List<SourceType>> _mixFieldPriority = {
    // 封面图：NextMoe → CT → VNDB → Hikarinagi → KunGal → Steam → 月幕GAL
    'cover_url': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.vndb,
      SourceType.hikarinagi,
      SourceType.kun,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 副标题（原版标题）：NextMoe → CT → VNDB → KunGal
    'original_title': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.vndb,
      SourceType.kun
    ],
    // ★ 2026-10-04 横幅封面：NextMoe（covers[] 横版）与 KunGal
    // （effective_banner_url）提供横幅；VNDB kana API 无横幅字段。
    // ★ 2026-10-05 修复：接入 Hikarinagi（covers[] 横版，开发者实测该平台
    // 横幅数据最完整）；KunGal 降为链尾——其 effective_banner_url 是论坛帖
    // 头图、无尺寸元数据，曾混入音乐盘图等非横幅内容（下载侧宽高比校验
    // ≥1.15 兜底，见 CoverDownloadService.downloadCover）。
    // 未列出的平台 pick() 自动跳过（其结果里 banner_url 恒为空串）。
    'banner_url': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.hikarinagi,
      SourceType.kun,
    ],
    // 标签：NextMoe → CT → Hikarinagi → KunGal → VNDB → Steam
    'tags': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.hikarinagi,
      SourceType.kun,
      SourceType.vndb,
      SourceType.steam
    ],
    // 会社（开发商）：NextMoe → CT → VNDB → KunGal → Hikarinagi → Steam
    'developer': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.vndb,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.steam
    ],
    // 简介：NextMoe → CT → KunGal → Hikarinagi → VNDB → Steam → 月幕GAL
    'summary': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 截图：NextMoe → CT → KunGal → Hikarinagi → VNDB
    'screenshot_urls': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb
    ],
    // 主标题：中文名优先（NextMoe 六源对齐中文名 → CT 社区中文名 → KunGal → …）
    'game_name': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.kun,
      SourceType.vndb,
      SourceType.hikarinagi,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 评分/投票数/发售日：NextMoe（自带 VNDB 评分）→ CT → VNDB → …
    'rating': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.vndb,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.steam,
      SourceType.ymgal
    ],
  };

  /// MIX 源：并发抓取多平台并按字段优先级整合（批量导入默认源）
  ///
  /// 流程：
  /// 1. 并发抓取 [_mixSources] **全部**底层平台（单源失败/无数据不影响
  ///    其他源，各源结果同时写入独立缓存键 `源:name`）。
  ///    注意：整合范围不随用户对各平台的开关变化——平台开关只控制
  ///    一键抓取列表中的**独立条目**，MIX 作为整合源始终覆盖全平台，
  ///    避免用户关闭部分平台后 MIX 退化为单源数据
  /// 2. 按 [_mixFieldPriority] 逐字段取最高优先级平台的非空值，
  ///    天然实现"优先平台无数据 → 按优先级后退到次级平台"
  /// 3. 整合结果统一标识 `platform = "MIX源"`，并附带
  ///    `source_platforms`（各平台与其 ID 的映射，供排重使用）
  /// 4. 整合结果缓存于 `mix:name`（TTL 同单源缓存），重复抓取零请求
  ///
  /// 所有平台均无数据时返回 null。
  static Future<Map<String, dynamic>?> fetchGameMixed(
    String gameName, {
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) return null;

    // MIX 合并结果缓存
    final mixCacheKey = '${SourceType.mix.name}:$gameName';
    if (useCache && _cache.containsKey(mixCacheKey)) {
      final cached = _cache[mixCacheKey]!;
      final cachedAtStr = cached['_cached_at'] as String?;
      if (cachedAtStr != null &&
          DateTime.now().difference(DateTime.parse(cachedAtStr)) < _cacheTtl) {
        final cachedResult = cached['_results'];
        if (cachedResult is List && cachedResult.isNotEmpty) {
          fetchLog('[MetadataFetcher] 📦 MIX 缓存命中: $gameName');
          return Map<String, dynamic>.from(cachedResult.first);
        }
      }
      _cache.remove(mixCacheKey);
    }

    // 始终整合全部底层平台（不与用户启用源取交集，见方法注释）
    final sources = List.unmodifiable(_mixSources);

    fetchLog('[MetadataFetcher] >>> fetchGameMixed("$gameName") '
        'sources=${sources.map((s) => s.displayName).join(" + ")}');

    // 并发抓取各平台（fetchGame 单源模式，各源独立缓存/超时/异常捕获）
    final perSource = <SourceType, Map<String, dynamic>>{};
    final futures = sources.map((source) async {
      // 单源结果缓存在 `源:name`，MIX 内部复用避免重复请求
      final results = await fetchGame(gameName,
          preferredSource: source, useCache: useCache);
      if (results.isNotEmpty) perSource[source] = results.first;
    });
    await Future.wait(futures);

    if (perSource.isEmpty) {
      fetchLog('[MetadataFetcher] MIX 全源无数据: $gameName');
      return null;
    }

    final merged = _mergeMixResults(perSource);
    // MIX 合并结果缓存
    _cache[mixCacheKey] = {
      '_cached_at': DateTime.now().toIso8601String(),
      '_results': [merged],
    };
    _persistCache();
    return merged;
  }

  /// 按字段优先级合并各平台结果
  ///
  /// 每个字段独立取值：按 [_mixFieldPriority] 顺序找到第一个非空值；
  /// 未配置优先级的字段（rating/vote_count/release_date 等数值类）
  /// 复用 'rating' 的优先级链。`platform` 固定为 "MIX源"，
  /// `platform_id` 取主标题提供平台的 ID，`source_platforms`
  /// 记录全部命中平台与其 ID（供批量导入做源 ID 排重）。
  static Map<String, dynamic> _mergeMixResults(
      Map<SourceType, Map<String, dynamic>> perSource) {
    // 按字段优先级取第一个非空值
    Object? pick(String field) {
      final priority = _mixFieldPriority[field] ?? _mixFieldPriority['rating']!;
      for (final source in priority) {
        final result = perSource[source];
        if (result == null) continue;
        final value = result[field];
        final isEmpty = value == null ||
            (value is String && value.trim().isEmpty) ||
            (value is List && value.isEmpty) ||
            (value is num && value == 0);
        if (!isEmpty) return value;
      }
      return null;
    }

    final merged = <String, dynamic>{};
    // vote_count/release_date 未单独配置优先级，pick() 自动复用
    // 'rating' 的优先级链（VNDB 最权威 → 逐级后退）
    final mixFields = [
      ..._mixFieldPriority.keys,
      'vote_count',
      'release_date',
      // 预计游玩时长：未单独配置优先级，pick() 自动复用
      // 'rating' 的优先级链（VNDB 唯一提供方 → 必命中）
      'length_minutes',
      'length_votes',
    ];
    for (final field in mixFields) {
      final value = pick(field);
      if (value != null) merged[field] = value;
    }

    // tags_meta 跟随 tags 同源（标签元数据与标签名保持一致）
    final tagsPriority = _mixFieldPriority['tags']!;
    for (final source in tagsPriority) {
      final result = perSource[source];
      if (result == null) continue;
      final tags = result['tags'];
      final tagsMeta = result['tags_meta'];
      final tagsEmpty = tags is! List || tags.isEmpty;
      final metaEmpty = tagsMeta is! List || tagsMeta.isEmpty;
      if (!tagsEmpty && !metaEmpty) {
        merged['tags_meta'] = tagsMeta;
        break;
      }
    }

    // 平台标识：统一展示为 MIX源；platform_id 取主标题提供平台
    merged['platform'] = SourceType.mix.displayName;
    final namePriority = _mixFieldPriority['game_name']!;
    for (final source in namePriority) {
      final result = perSource[source];
      if (result == null) continue;
      final id = result['platform_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        merged['platform_id'] = id;
        break;
      }
    }

    // 各命中平台的源 ID 映射（供排重：任一底层平台 ID 冲突即视为重复）
    final sourcePlatforms = <String, String>{};
    for (final entry in perSource.entries) {
      final id = entry.value['platform_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        sourcePlatforms[entry.key.displayName] = id;
      }
    }
    merged['source_platforms'] = sourcePlatforms;

    fetchLog('[MetadataFetcher] ✅ MIX 整合完成: '
        'name="${merged['game_name']}" '
        '来源=${perSource.keys.map((s) => s.displayName).join("+")} '
        '字段提供='
        '${_mixFieldPriority.keys.where((f) => merged.containsKey(f) && f != 'game_name').map((f) => '$f=${_fieldProvider(f, perSource)}').join(", ")}');
    return merged;
  }

  /// 诊断辅助：返回某字段实际由哪个平台提供（仅日志用）
  static String _fieldProvider(
      String field, Map<SourceType, Map<String, dynamic>> perSource) {
    final priority = _mixFieldPriority[field] ?? const <SourceType>[];
    for (final source in priority) {
      final result = perSource[source];
      if (result == null) continue;
      final value = result[field];
      final isEmpty = value == null ||
          (value is String && value.trim().isEmpty) ||
          (value is List && value.isEmpty);
      if (!isEmpty) return source.displayName;
    }
    return '-';
  }

  /// 多平台并发抓取游戏截图（详情页 Priority 3 / 截图补全 backfill 使用）
  ///
  /// 从 [sources] 并发抓取，按 sources 顺序（即优先级）合并各源截图并
  /// 去重，最多 [maxTotal] 张。默认顺序与 MIX 源截图优先级一致
  /// （NextMoe → KunGal → Hikarinagi → VNDB，见
  /// [_mixFieldPriority]['screenshot_urls']）。
  /// 单源失败/无截图不影响其他源；全部无截图时返回空列表。
  ///
  /// 备选标题回退：主标题 [gameName] 无截图时，依次尝试 [altNames]
  /// （如副标题/日文原标题/英文标题）——中文标题在数据源常无收录，
  /// 原版标题往往能命中。任一标题抓到截图即停止回退。
  static Future<List<String>> fetchScreenshots(
    String gameName, {
    List<String> altNames = const [],
    List<SourceType> sources = const [
      SourceType.nextmoe,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb,
    ],
    int maxTotal = 6,
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) return [];

    var urls = await _fetchScreenshotsForName(gameName,
        sources: sources, maxTotal: maxTotal, useCache: useCache);

    // 主标题无截图 → 依次尝试备选标题（跳过空值与重复）
    if (urls.isEmpty) {
      final primary = gameName.trim();
      for (final alt in altNames) {
        final altName = alt.trim();
        if (altName.isEmpty || altName == primary) continue;
        fetchLog('[MetadataFetcher] 🔄 主标题无截图，回退备选标题: '
            '"$primary" → "$altName"');
        urls = await _fetchScreenshotsForName(altName,
            sources: sources, maxTotal: maxTotal, useCache: useCache);
        if (urls.isNotEmpty) break;
      }
    }

    return urls;
  }

  /// 按单个标题并发抓取截图（[fetchScreenshots] 的单标题实现）
  static Future<List<String>> _fetchScreenshotsForName(
    String gameName, {
    required List<SourceType> sources,
    required int maxTotal,
    required bool useCache,
  }) async {
    if (gameName.trim().isEmpty) return [];

    fetchLog('[MetadataFetcher] >>> fetchScreenshots("$gameName") '
        'sources=${sources.map((s) => s.name).join(",")}');

    // 三源并发抓取（单源异常静默降级为空结果）
    final futures = sources.map((source) async {
      try {
        return await fetchGame(gameName,
            preferredSource: source, useCache: useCache);
      } catch (e) {
        fetchLog('[MetadataFetcher] [$source] 截图抓取异常: $e');
        return <Map<String, dynamic>>[];
      }
    });
    final resultsBySource = await Future.wait(futures);

    // 按源优先级合并截图，去重
    final urls = <String>[];
    final seen = <String>{};
    for (final results in resultsBySource) {
      for (final result in results) {
        final shotUrls = result['screenshot_urls'];
        if (shotUrls is! List) continue;
        for (final url in shotUrls) {
          final u = url.toString();
          if (u.isEmpty || seen.contains(u)) continue;
          seen.add(u);
          urls.add(u);
          if (urls.length >= maxTotal) {
            fetchLog('[MetadataFetcher] ✅ 截图抓取完成: $gameName → '
                '${urls.length}张 (达上限，来源优先级截断)');
            return urls;
          }
        }
      }
    }

    fetchLog('[MetadataFetcher] ✅ 截图抓取完成: $gameName → ${urls.length}张');
    return urls;
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
      case SourceType.nextmoe:
        return NextMoeService(dio: _dio);
      case SourceType.ct:
        return CTService(dio: _dio);
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
      // 原版标题（优先日文，来自数据源多语言标题），供上游作为"副标题"使用
      'original_title': game.originalTitle,
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
      // 预计游玩时长（VNDB 多用户平均，分钟；其他源为 null）
      'length_minutes': game.lengthMinutes,
      'length_votes': game.lengthVotes,
      'summary': game.summary ?? '',
      'cover_url': game.coverUrl ?? '',
      // ★ 2026-10-04 横幅封面：NextMoe covers[] 横版 / KunGal banner_url，
      // VNDB 无横幅字段为 null → 转空串（下游按"无横幅"处理）
      'banner_url': game.bannerUrl ?? '',
      'release_date': game.releaseDate ?? '',
      'developer': game.company ?? '',
      'screenshot_urls': game.screenshotUrls ?? [],
    };
  }

  static Future<bool> testConnection(SourceType source) async {
    try {
      // MIX 整合源：底层任一平台连通即视为可用
      if (source == SourceType.mix) {
        final results =
            await Future.wait(_mixSources.map((s) => testConnection(s)));
        return results.contains(true);
      }
      final service = _createService(source);
      return await service.testConnection();
    } catch (e) {
      debugPrint('[MetadataFetcher] 连接测试失败 [$source]: $e');
      return false;
    }
  }

  /// 并发测试所有数据源连接（之前为串行）
  ///
  /// MIX 不单独测试：其底层 5 平台已在本列表中逐个测试，
  /// MIX 可用性 = 任一底层平台连通（见 [testConnection]）
  static Future<Map<SourceType, bool>> testAllConnections() async {
    final sources = SourceType.values
        .where((s) => s != SourceType.local && s != SourceType.mix);
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
