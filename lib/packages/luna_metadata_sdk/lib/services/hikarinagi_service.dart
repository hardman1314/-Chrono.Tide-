import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// Hikarinagi 数据源服务（N1）
///
/// 采用 **OIDC OAuth2 client_credentials** 流程认证（参考 LunaBox
/// `metadata_hikarinagi.go`），并非直接内置长期 Bearer Token。
///
/// **认证流程**：
/// 1. 用硬编码的 client_id + client_secret 向 OIDC token 端点换取 access_token：
///    `POST https://id.hikarinagi.org/oidc/token`
///    - HTTP Basic Auth（client_id:client_secret）
///    - body: `grant_type=client_credentials&scope=catalog:read`
///    - Content-Type: `application/x-www-form-urlencoded`
/// 2. access_token 有效期约 1 小时，缓存并在过期前 1 分钟自动刷新；
///    遇 401 时废弃缓存 token 并重试一次。
///
/// **凭据**：硬编码在 [kHikarinagiClientId] / [kHikarinagiClientSecret]，
/// 由开发者从 Hikarinagi 开发者控制台注册应用获得。
///
/// **API 端点**（base: `https://www.hikarinagi.org/api/v3/open`）：
/// - 搜索：`GET /search?q={kw}&types=galgame&page=1&page_size=5`
/// - 详情：`GET /galgames/{id}`
/// - 响应 envelope：`{success, data, message, error, request_id}`
///   - 搜索 data：`{items:[{type, id, title, subtitle, developer, cover}]}`
///   - 详情 data：`{id, origin_title, trans_title, covers[], release_date,
///     origin_intro, trans_intro, nsfw, tags[{name, likes}]}`
class HikarinagiService implements MetadataSourceService {
  final Dio _dio;

  static const String apiBase = 'https://www.hikarinagi.org/api/v3/open';
  static const String _tokenUrl = 'https://id.hikarinagi.org/oidc/token';
  static const String _scope = 'catalog:read';

  /// OAuth2 客户端凭据（硬编码，开发者控制台注册获得）
  ///
  /// 注意：`hks_` 前缀的是 **client_secret**（密钥），`hkn_` 前缀的是
  /// **client_id**（应用标识）。两者配合换取 1 小时有效的 access_token，
  /// 而非直接作为 Bearer Token 使用。
  static const String kHikarinagiClientId = 'hkn_hCWLqY0zJzWwItBl';
  static const String kHikarinagiClientSecret =
      'hks_Z7bj68qCb7YjiEB31hJbcJUWdEmAM185csqqb9WdxEU';

  // access_token 缓存
  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  HikarinagiService({Dio? dio})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
            'Accept': 'application/json',
          },
        )) {
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.hikarinagi;

  @override
  String get sourceName => 'Hikarinagi';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  bool get _hasCredentials =>
      kHikarinagiClientId.isNotEmpty && kHikarinagiClientSecret.isNotEmpty;

  @override
  Future<bool> testConnection() async {
    if (!_hasCredentials) return false;
    try {
      final token = await _getAccessToken();
      if (token == null) return false;
      final response = await executeRateLimited(
          SourceType.hikarinagi,
          () => _dio.get(
                '$apiBase/search',
                queryParameters: {
                  'q': 'test',
                  'types': 'galgame',
                  'page': 1,
                  'page_size': 1
                },
                options: Options(headers: {'Authorization': 'Bearer $token'}),
              ));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    if (!_hasCredentials || name.trim().isEmpty) return _emptyResult();

    try {
      final token = await _getAccessToken();
      if (token == null) {
        fetchLog('[Hikarinagi] 获取 access_token 失败 [$name]');
        return _emptyResult();
      }

      // 搜索：GET /search?q={kw}&types=galgame&page=1&page_size=5
      final searchResponse = await _doAuthorizedGet(token, '$apiBase/search', {
        'q': name,
        'types': 'galgame',
        'page': 1,
        'page_size': 5,
      });

      final searchEnvelopeRaw = searchResponse.data is String
          ? jsonDecode(searchResponse.data)
          : searchResponse.data;
      if (searchEnvelopeRaw is! Map) return _emptyResult();
      final searchEnvelope = Map<String, dynamic>.from(searchEnvelopeRaw);
      if (safeBool(searchEnvelope, 'success') != true) {
        fetchLog('[Hikarinagi] 搜索失败 [$name]: '
            '${safeString(searchEnvelope, 'message') ?? safeString(searchEnvelope, 'error')}');
        return _emptyResult();
      }

      final searchData = safeMap(searchEnvelope, 'data');
      final items = searchData == null ? null : safeList(searchData, 'items');
      if (items == null || items.isEmpty) return _emptyResult();

      // 取第一个 type=galgame 的命中项
      int? gameId;
      for (final it in items) {
        if (it is! Map) continue;
        final m = Map<String, dynamic>.from(it);
        if (safeString(m, 'type') == 'galgame') {
          final id = safeInt(m, 'id');
          if (id != null && id > 0) {
            gameId = id;
            break;
          }
        }
      }
      if (gameId == null) return _emptyResult();

      // 详情：GET /galgames/{id}
      final detailResponse =
          await _doAuthorizedGet(token, '$apiBase/galgames/$gameId', null);

      final detailEnvelopeRaw = detailResponse.data is String
          ? jsonDecode(detailResponse.data)
          : detailResponse.data;
      if (detailEnvelopeRaw is! Map) return _emptyResult();
      final detailEnvelope = Map<String, dynamic>.from(detailEnvelopeRaw);
      if (safeBool(detailEnvelope, 'success') != true) return _emptyResult();

      final gameData = safeMap(detailEnvelope, 'data');
      if (gameData == null) return _emptyResult();

      return _parseDetail(gameData, gameId);
    } catch (e) {
      fetchLog('[Hikarinagi] 抓取失败 [$name]: $e');
      return _emptyResult();
    }
  }

  /// 用 client_credentials 流式换取 access_token
  Future<String?> _getAccessToken() async {
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken;
    }

    try {
      final basic = base64Encode(
          utf8.encode('$kHikarinagiClientId:$kHikarinagiClientSecret'));
      final response = await executeRateLimited(
          SourceType.hikarinagi,
          () => _dio.post(
                _tokenUrl,
                data: 'grant_type=client_credentials&scope=$_scope',
                options: Options(
                  headers: {
                    'Authorization': 'Basic $basic',
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'Accept': 'application/json',
                  },
                  // 凭据错误时返回 4xx，不要抛异常以便记录具体原因
                  validateStatus: (s) => s != null && s < 500,
                ),
              ));

      if (response.statusCode != 200) {
        fetchLog('[Hikarinagi] token 请求失败 status=${response.statusCode} '
            'body=${response.data}');
        return null;
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final accessToken = safeString(json, 'access_token');
      final expiresIn = safeInt(json, 'expires_in') ?? 3600;

      if (accessToken == null || accessToken.isEmpty) {
        fetchLog('[Hikarinagi] token 响应无 access_token: $json');
        return null;
      }

      _cachedToken = accessToken;
      // 提前 1 分钟刷新，避免边界过期
      _tokenExpiresAt = DateTime.now()
          .add(Duration(seconds: expiresIn))
          .subtract(const Duration(seconds: 60));
      return accessToken;
    } catch (e) {
      fetchLog('[Hikarinagi] token 获取异常: $e');
      return null;
    }
  }

  void _invalidateToken() {
    _cachedToken = null;
    _tokenExpiresAt = null;
  }

  /// 带 access_token 的 GET；遇 401 时废弃 token 并刷新重试一次（对齐 LunaBox）
  Future<Response<dynamic>> _doAuthorizedGet(
      String token, String url, Map<String, dynamic>? query) async {
    var accessToken = token;
    for (int attempt = 0; attempt < 2; attempt++) {
      final response = await executeRateLimited(
          SourceType.hikarinagi,
          () => _dio.get(
                url,
                queryParameters: query,
                options: Options(
                  headers: {'Authorization': 'Bearer $accessToken'},
                  // 允许 401 返回以便触发 token 刷新，而非直接抛异常
                  validateStatus: (s) => s != null && s < 500,
                ),
              ));
      if (response.statusCode == 401 && attempt == 0) {
        _invalidateToken();
        final refreshed = await _getAccessToken();
        if (refreshed == null) return response;
        accessToken = refreshed;
        continue;
      }
      return response;
    }
    return _dio.get(url,
        queryParameters: query,
        options: Options(
          headers: {'Authorization': 'Bearer $accessToken'},
          validateStatus: (s) => s != null && s < 500,
        ));
  }

  MetadataResult _parseDetail(Map<String, dynamic> json, int id) {
    // 名称：优先中文 trans_title，兜底 origin_title
    String name = safeString(json, 'trans_title') ?? '';
    if (name.isEmpty) name = safeString(json, 'origin_title') ?? '';

    // 封面：从 covers[] 中按 votes 选最佳
    String coverUrl = '';
    final covers = safeList(json, 'covers');
    if (covers != null && covers.isNotEmpty) {
      Map<String, dynamic>? best;
      int bestVotes = -1;
      for (final c in covers) {
        if (c is! Map) continue;
        final cMap = Map<String, dynamic>.from(c);
        final votes = safeInt(cMap, 'votes') ?? 0;
        if (votes > bestVotes) {
          bestVotes = votes;
          best = cMap;
        }
      }
      if (best != null) {
        coverUrl = safeString(best, 'url') ?? '';
      }
    }

    // ★ 2026-10-05 横幅封面：covers[] 里可能含横版大图（开发者实测该平台
    //   横幅数据最完整）。挑选规则与 NextMoe 同口径：
    //   ① 有尺寸且宽>高的项里取面积最大；② 无果时取无尺寸候选，
    //   真伪交下载侧宽高比校验（≥1.15）裁决；③ 与竖封面同 URL 跳过。
    String? bannerUrl;
    if (covers != null && covers.isNotEmpty) {
      String? bestBannerUrl;
      int bestArea = 0;
      String? unknownSizeUrl;
      for (final c in covers) {
        if (c is! Map) continue;
        final cMap = Map<String, dynamic>.from(c);
        final url = safeString(cMap, 'url') ?? '';
        if (url.isEmpty) continue;
        if (url == coverUrl) continue; // 与竖封面同图 → 假横幅
        final width = safeInt(cMap, 'width') ?? 0;
        final height = safeInt(cMap, 'height') ?? 0;
        if (width <= 0 || height <= 0) {
          unknownSizeUrl ??= url;
          continue;
        }
        if (width <= height) continue; // 只收横版
        final area = width * height;
        if (area > bestArea) {
          bestArea = area;
          bestBannerUrl = url;
        }
      }
      bannerUrl = bestBannerUrl ?? unknownSizeUrl;
    }

    // 简介：优先中文 trans_intro，兜底 origin_intro
    String summary = safeString(json, 'trans_intro') ?? '';
    if (summary.isEmpty) summary = safeString(json, 'origin_intro') ?? '';

    // 标签：name + likes，weight = likes / max(likes)
    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null && tagsData.isNotEmpty) {
      final tagList = <Map<String, dynamic>>[];
      for (final t in tagsData) {
        if (t is! Map) continue;
        tagList.add(Map<String, dynamic>.from(t));
      }
      final maxLikes = tagList.fold<int>(0, (m, t) {
        final v = safeInt(t, 'likes') ?? 0;
        return v > m ? v : m;
      });
      tagList.sort((a, b) =>
          (safeInt(b, 'likes') ?? 0).compareTo(safeInt(a, 'likes') ?? 0));
      for (final tag in tagList.take(10)) {
        final tagName = safeString(tag, 'name');
        if (tagName != null && tagName.isNotEmpty) {
          final likes = safeInt(tag, 'likes') ?? 0;
          final weight = maxLikes > 0 ? (likes / maxLikes) : 1.0;
          tags.add(TagItem(
            name: tagName,
            source: 'hikarinagi',
            weight: weight.clamp(0.1, 1.0),
          ));
        }
      }
    }

    return MetadataResult(
      game: Game(
        id: id.toString(),
        name: name,
        coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
        bannerUrl: bannerUrl,
        summary: summary,
        rating: 0.0, // Hikarinagi 无评分字段
        releaseDate: safeString(json, 'release_date')?.trim(),
        sourceType: SourceType.hikarinagi,
        sourceId: id.toString(),
        screenshotUrls: _extractScreenshots(json),
      ),
      tags: tags,
    );
  }

  /// 从详情响应中提取截图 URL 列表，最多6张
  ///
  /// 尝试常见字段名（screenshots / images / gallery），兼容字符串
  /// 与 {url|path|src} 对象两种元素格式；字段不存在时返回 null 安全降级。
  List<String>? _extractScreenshots(Map<String, dynamic> json) {
    for (final field in ['screenshots', 'images', 'gallery']) {
      final list = safeList(json, field);
      if (list == null || list.isEmpty) continue;

      final urls = <String>[];
      for (final item in list.take(6)) {
        if (item is String && item.isNotEmpty) {
          urls.add(item);
        } else if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final url = safeString(m, 'url') ??
              safeString(m, 'path') ??
              safeString(m, 'src') ??
              '';
          if (url.isNotEmpty) urls.add(url);
        }
      }
      if (urls.isNotEmpty) return urls;
    }
    return null;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.hikarinagi));
  }
}
