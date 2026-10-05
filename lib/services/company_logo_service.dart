import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/path_helper.dart';
import 'company_wall_store.dart';
import 'system_proxy_detector.dart';

/// 会社图标抓取结果状态。
enum CompanyLogoFetchStatus {
  /// 成功：已下载并落盘。
  ok,

  /// 平台无此会社（搜索无结果 / 名称对不上）。
  noMatch,

  /// 平台有此会社但无 logo。
  noLogo,

  /// logo 下载失败。
  downloadFailed,

  /// 网络 / 解析异常。
  networkError,
}

/// 会社图标抓取结果。
@immutable
class CompanyLogoFetchResult {
  const CompanyLogoFetchResult({
    required this.status,
    this.fileName,
    this.sourceUrl,
    this.nextMoeCompanyId,
    this.matchedVia = '',
    this.message,
  });

  final CompanyLogoFetchStatus status;

  /// 落盘文件名（相对 [CompanyWallStore.logoDir]，成功时非空）。
  final String? fileName;
  final String? sourceUrl;
  final String? nextMoeCompanyId;

  /// 匹配依据：`vndb`（vndb_id 源锚点精确对齐）或 `name`（唯一名称命中）。
  final String matchedVia;
  final String? message;

  bool get isOk => status == CompanyLogoFetchStatus.ok;
}

/// 全自动补抓的会社描述（由调用方从卡片/存储派生，服务层不依赖 UI 类型）。
@immutable
class CompanyLogoAutoRequest {
  const CompanyLogoAutoRequest({
    required this.storeKey,
    this.vndbId,
    this.nameCandidates = const [],
  });

  /// 存储键（词典会社 = `"<company_id>"`，自定义会社 = 自定义 id）。
  final String storeKey;

  /// VNDB producer id（如 `p98`）；null = 仅按名字匹配。
  final String? vndbId;

  /// 依次尝试的名字。
  final List<String> nameCandidates;
}

/// 分类匣·会社墙：会社图标抓取服务（Phase 0 探针结论落地）。
///
/// **来源**：NextMoe 会社目录（`/v2/catalog`）。
/// 实测（`.workbuddy/probe_company_logo/`，8/8 命中 100%）：
/// 1. 会社检索 `GET /catalog/search?object=company&q=<名>` 返回命中项，
///    其 `sources[]` 含形如 `vndb:p98` 的跨源锚点；
/// 2. **优先用本词典的 `vndb_id` 做精确对齐**（比名字可靠）；
/// 3. 会社详情 `GET /catalog/companies/{id}?include=logo` 返回
///    `logo.url`（250×250 webp，CDN 直链）；
/// 4. 下载并落盘到 [CompanyWallStore.logoDir]，文件名 `<会社键>.<ext>`。
///
/// **纪律**：
/// - 密钥 / 基址复用 [NextMoeService] 的公开常量（不重复硬编码）；
/// - 走 [executeRateLimited] 统一限流（NextMoe free 档 60 次/分）；
/// - 代理优先级：app 配置 > Windows 系统代理 > 环境变量（与 MetadataFetcher 同款）；
/// - **失败静默降级**（返回状态，不抛异常），不阻塞主流程；
/// - 抓取只读远端，不触碰任何游戏数据 —— 仅落盘图标文件 + 由调用方写
///   [CompanyWallStore.setLogo] 记录。
class CompanyLogoService {
  CompanyLogoService._();

  static final CompanyLogoService instance = CompanyLogoService._();

  static const String _ua = 'ChronoTide/1.0 (Metadata Scraper)';

  /// 会社检索端点（`object=company`）。
  static String get _searchUrl => '${NextMoeService.apiBase}/catalog/search';

  static String _companyUrl(String id) =>
      '${NextMoeService.apiBase}/catalog/companies/$id';

  Dio? _dio;

  /// 懒加载 Dio（含代理配置；与 MetadataFetcher 三级代理同款）。
  Future<Dio> _ensureDio() async {
    final existing = _dio;
    if (existing != null) return existing;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Authorization': 'Bearer ${NextMoeService.apiKey}',
        'User-Agent': _ua,
        'Accept': 'application/json',
      },
    ));

    // app 配置代理 > Windows 系统代理 > 环境变量
    String? proxy;
    try {
      final prefs = await SharedPreferences.getInstance();
      final configured = prefs.getString('proxy_url');
      if (configured != null && configured.isNotEmpty) proxy = configured;
    } catch (_) {}
    proxy ??= await SystemProxyDetector.detectProxy();

    final adapter = dio.httpClientAdapter;
    if (adapter is DefaultHttpClientAdapter) {
      final proxyUrl = proxy;
      adapter.onHttpClientCreate = (client) {
        if (proxyUrl != null && proxyUrl.isNotEmpty) {
          client.findProxy = (_) => 'PROXY $proxyUrl';
        } else {
          client.findProxy = HttpClient.findProxyFromEnvironment;
        }
        return client;
      };
    }

    _dio = dio;
    return dio;
  }

  /// 抓取并落盘某会社的图标。
  ///
  /// [companyKey] 存储键（词典会社 = `"<company_id>"`，自定义会社 = 自定义 id）；
  /// [vndbId] 形如 `p98`（词典会社一般都有）；
  /// [nameCandidates] 依次尝试的名字（建议 [cn_name, jp_name, standard_name]）。
  Future<CompanyLogoFetchResult> fetchAndStore({
    required String companyKey,
    String? vndbId,
    required List<String> nameCandidates,
  }) async {
    if (companyKey.isEmpty) {
      return const CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.noMatch,
        message: '会社键为空',
      );
    }

    final Dio dio;
    try {
      dio = await _ensureDio();
    } catch (e) {
      return CompanyLogoFetchResult(
          status: CompanyLogoFetchStatus.networkError, message: '$e');
    }

    // 1) 检索会社，按 vndb 源锚点对齐
    final candidates = <String>[];
    for (final n in nameCandidates) {
      final t = n.trim();
      if (t.isNotEmpty && !candidates.contains(t)) candidates.add(t);
    }

    String? companyId;
    String matchedVia = '';
    String? searchErr;
    final anchor = (vndbId == null || vndbId.trim().isEmpty)
        ? null
        : 'vndb:${vndbId.trim().toLowerCase()}';

    for (final name in candidates) {
      List<Map<String, dynamic>> items;
      try {
        items = await _searchCompanies(dio, name);
      } catch (e) {
        searchErr = '$e';
        continue;
      }
      if (items.isEmpty) continue;

      // ① 精确锚点：sources 含 vndb:<id>
      if (anchor != null) {
        for (final it in items) {
          final srcs = (it['sources'] as List? ?? const [])
              .map((s) => s.toString().toLowerCase())
              .toList();
          if (srcs.contains(anchor)) {
            companyId = it['id']?.toString();
            matchedVia = 'vndb';
            break;
          }
        }
      }
      if (companyId != null) break;

      // ② 唯一命中：接受为名称匹配（保守，避免多义误配）
      if (items.length == 1) {
        companyId = items.first['id']?.toString();
        matchedVia = 'name';
        break;
      }
    }

    if (companyId == null || companyId.isEmpty) {
      return CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.noMatch,
        message: searchErr,
      );
    }

    // 2) 详情取 logo
    String? logoUrl;
    try {
      logoUrl = await _fetchLogoUrl(dio, companyId);
    } catch (e) {
      return CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.networkError,
        nextMoeCompanyId: companyId,
        matchedVia: matchedVia,
        message: '$e',
      );
    }
    if (logoUrl == null || logoUrl.isEmpty) {
      return CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.noLogo,
        nextMoeCompanyId: companyId,
        matchedVia: matchedVia,
      );
    }

    // 3) 下载落盘
    try {
      final fileName = await _downloadLogo(dio, logoUrl, companyKey);
      if (fileName == null) {
        return CompanyLogoFetchResult(
          status: CompanyLogoFetchStatus.downloadFailed,
          sourceUrl: logoUrl,
          nextMoeCompanyId: companyId,
          matchedVia: matchedVia,
        );
      }
      return CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.ok,
        fileName: fileName,
        sourceUrl: logoUrl,
        nextMoeCompanyId: companyId,
        matchedVia: matchedVia,
      );
    } catch (e) {
      return CompanyLogoFetchResult(
        status: CompanyLogoFetchStatus.downloadFailed,
        sourceUrl: logoUrl,
        nextMoeCompanyId: companyId,
        matchedVia: matchedVia,
        message: '$e',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _searchCompanies(Dio dio, String q) async {
    final res = await executeRateLimited(
      SourceType.nextmoe,
      () => dio.get<dynamic>(_searchUrl, queryParameters: {
        'object': 'company',
        'q': q,
      }),
    );
    final data = res.data;
    final map = data is Map ? data : const {};
    final items = map['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<String?> _fetchLogoUrl(Dio dio, String companyId) async {
    final res = await executeRateLimited(
      SourceType.nextmoe,
      () => dio.get<dynamic>(_companyUrl(companyId),
          queryParameters: {'include': 'logo'}),
    );
    final data = res.data;
    final map = data is Map ? data : const {};
    final logo = map['logo'];
    if (logo is! Map) return null;
    final url = logo['url']?.toString().trim();
    return (url == null || url.isEmpty) ? null : url;
  }

  /// 下载 logo 到 [CompanyWallStore.logoDir]，返回文件名（失败 null）。
  Future<String?> _downloadLogo(
      Dio dio, String url, String companyKey) async {
    if (!url.startsWith('http')) return null;
    final ext = extOfUrl(url);
    final safeKey = fileNameKey(companyKey);
    final fileName = '$safeKey.$ext';

    final dir = Directory(CompanyWallStore.logoDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final res = await executeRateLimited(
      SourceType.nextmoe,
      () => dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    final bytes = res.data;
    if (bytes == null || bytes.isEmpty) return null;

    final dest = File('${CompanyWallStore.logoDir}${Platform.pathSeparator}$fileName');
    await dest.writeAsBytes(bytes, flush: true);
    debugPrint('[COMPANY-LOGO] ✅ 已落盘: $fileName (${bytes.length} B)');
    return fileName;
  }

  /// 从 URL 路径推断图片扩展名（默认 webp —— NextMoe CDN 为 webp）。
  static String extOfUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot > 0) {
      final ext = path.substring(dot + 1).toLowerCase();
      if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif']
          .contains(ext)) {
        return ext == 'jpeg' ? 'jpg' : ext;
      }
    }
    return 'webp';
  }

  /// 会社键清洗为文件名安全字符（键本为数字或 `custom_<ms>_<n>`，仅防御；
  /// 清洗后为空或纯下划线 → 兜底 `company`）。
  static String fileNameKey(String key) {
    final cleaned =
        key.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_').trim();
    if (cleaned.isEmpty || RegExp(r'^_+$').hasMatch(cleaned)) return 'company';
    return cleaned;
  }

  /// 测试专用：清空 Dio 缓存。
  @visibleForTesting
  void resetForTest() {
    _dio = null;
  }

  // ===========================================================================
  // 全自动补抓（2026-10-04）：会社墙出现无图标会社 → 后台自动抓取落盘
  //
  // 产品语义：用户**无需点任何按钮**——会社墙派生出会社后系统自动补齐图标
  // （成功即 setLogo 落盘并 notifyListeners，卡片随之刷新）。
  //
  // 纪律：
  // - 会话内去重（in-flight + attempted），避免列表重建反复触发；
  // - 负缓存落盘（`company_logo_attempts.json`，键 → 上次尝试时间戳），
  //   失败 7 天内不重试（不每次启动都打满限流配额）；
  // - 复用 [executeRateLimited] 限流，静默失败不抛异常；
  // - 抓取经 [Timer.run] 脱离 build 相，成功后由 store 通知刷新。
  // ===========================================================================

  final Set<String> _autoInFlight = {};

  /// 会社键 → 上次自动尝试的 epoch ms（成功即移除）。
  final Map<String, int> _autoAttemptedAt = {};
  bool _attemptCacheLoaded = false;
  Future<void> _attemptSaveQueue = Future<void>.value();

  /// 负缓存文件（键 → epoch ms）。
  static String get _attemptFilePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}'
      'company_logo_attempts.json';

  /// 失败重试间隔（负缓存有效期）。
  static const Duration _autoRetryAfter = Duration(days: 7);

  /// 会社墙派生后调用：对缺图标的会社自动补抓（幂等，可重复触发）。
  void autoFetchMissingLogos(List<CompanyLogoAutoRequest> requests) {
    if (requests.isEmpty) return;
    // 脱离 build 相（调用点在派生 getter 内）
    Timer.run(() => _autoFetchAll(requests));
  }

  Future<void> _autoFetchAll(List<CompanyLogoAutoRequest> requests) async {
    await _loadAttemptCache();
    var dirty = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final r in requests) {
      final key = r.storeKey;
      if (key.isEmpty) continue;
      if (_autoInFlight.contains(key)) continue;
      final last = _autoAttemptedAt[key];
      if (last != null && now - last < _autoRetryAfter.inMilliseconds) {
        continue; // 负缓存期内不重试
      }
      if (r.vndbId == null &&
          r.nameCandidates.where((n) => n.trim().isNotEmpty).isEmpty) {
        continue; // 无锚点无名字 → 没法查
      }
      _autoInFlight.add(key);
      _autoAttemptedAt[key] = now;
      dirty = true;
      unawaited(_autoFetchOne(r));
    }
    if (dirty) _scheduleAttemptFlush();
  }

  Future<void> _autoFetchOne(CompanyLogoAutoRequest r) async {
    try {
      final result = await fetchAndStore(
        companyKey: r.storeKey,
        vndbId: r.vndbId,
        nameCandidates: r.nameCandidates,
      );
      if (result.isOk && result.fileName != null) {
        // 成功：写 store → notifyListeners → 卡片自动刷新
        await CompanyWallStore.instance.setLogo(r.storeKey, result.fileName);
        _autoAttemptedAt.remove(r.storeKey);
        _scheduleAttemptFlush();
      }
    } catch (_) {
      // 静默：抓取失败保持无图标回退（字标），负缓存已记录本次尝试
    } finally {
      _autoInFlight.remove(r.storeKey);
    }
  }

  Future<void> _loadAttemptCache() async {
    if (_attemptCacheLoaded) return;
    _attemptCacheLoaded = true;
    try {
      final file = File(_attemptFilePath);
      if (!await file.exists()) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      data.forEach((k, v) {
        final ts = v is int ? v : int.tryParse('$v');
        if (k.isNotEmpty && ts != null) _autoAttemptedAt[k] = ts;
      });
    } catch (e) {
      debugPrint('[COMPANY-LOGO] ⚠️ 负缓存读取失败（忽略）: $e');
    }
  }

  void _scheduleAttemptFlush() {
    final previous = _attemptSaveQueue;
    _attemptSaveQueue = () async {
      await previous;
      try {
        final file = File(_attemptFilePath);
        final dir = file.parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        await file.writeAsString(jsonEncode(_autoAttemptedAt), flush: true);
      } catch (e) {
        debugPrint('[COMPANY-LOGO] ⚠️ 负缓存写入失败（忽略）: $e');
      }
    }();
  }
}
