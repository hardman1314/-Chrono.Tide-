import 'dart:convert' show jsonDecode;

import 'package:dio/dio.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// TouchGal 数据源服务
///
/// 参考 LunaBox 的 metadata_touchgal.go 实现：
/// - API 基址：https://developer.touchgal.com/api/v1
/// - 认证方式：Bearer Token（硬编码于 MetadataFetcher.kTouchGalApiToken）
/// - 流程：先调用 /games/search 获取 uniqueId，再调用 /games/{uniqueId} 获取详情
/// - 标签：纯字符串数组，weight=1，无剧透标记
/// - 评分：10 分制，直接使用
///
/// ⚠️ 代理策略：本服务不再自行检测代理。由 [MetadataFetcher._initDio] 统一
/// 处理全局 Dio 的代理配置（优先级：app 配置 > Windows 系统代理 > 环境变量），
/// 传入的 [dio] 已携带正确的代理设置。详见 [SystemProxyDetector]。
class TouchGalService implements MetadataSourceService {
  final Dio _dio;
  final String? _token;

  static const String _apiBaseURL = 'https://developer.touchgal.com/api/v1';
  static const String _searchLimit = '1';
  static const String _allowNsfw = 'true';
  static const int _uniqueIdSize = 8;

  /// 创建 TouchGalService
  ///
  /// [dio] 来自 MetadataFetcher 的全局 Dio（已由 `SystemProxyDetector`
  /// 配置好代理）。本服务始终创建带专属 headers 的 Dio，并从 [dio]
  /// 继承代理配置（httpClientAdapter）。
  TouchGalService({Dio? dio, String? token})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          headers: {
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
            'Accept': 'application/json',
          },
        )),
        _token = token {
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.touchgal;

  @override
  String get sourceName => 'TouchGal';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  /// 校验 Bearer Token 是否可用
  bool get hasToken => _token != null && _token!.trim().isNotEmpty;

  @override
  Future<bool> testConnection() async {
    if (!hasToken) return false;
    try {
      // 用一个合法的 uniqueId 格式探测接口可达性
      // 任意 8 位字母数字组合即可（不存在返回 404，但能证明鉴权通过）
      final response = await _dio.get(
        '$_apiBaseURL/games/aaaaaaaa',
        queryParameters: {'allowNsfw': _allowNsfw},
        options: Options(headers: _buildAuthHeaders()),
      );
      // 200 = 命中真实游戏；404 = 鉴权通过但 ID 不存在；401/403 = token 无效
      return response.statusCode == 200 || response.statusCode == 404;
    } catch (e) {
      final status = _extractStatusCode(e);
      // 404 也代表连接正常（鉴权通过、只是 ID 不存在）
      return status == 404;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    final keyword = name.trim();
    if (keyword.isEmpty || !hasToken) {
      return _emptyResult();
    }

    try {
      // Step 1: 搜索获取 uniqueId
      final uniqueId = await _searchUniqueId(keyword);
      if (uniqueId == null || uniqueId.isEmpty) {
        return _emptyResult();
      }

      // Step 2: 获取详情
      return await _fetchDetail(uniqueId);
    } catch (e) {
      fetchLog('[TouchGal] 查询失败 [$name]: $e');
      return _emptyResult();
    }
  }

  // ==================== 搜索阶段 ====================

  /// 调用 /games/search 接口获取首个匹配项的 uniqueId
  Future<String?> _searchUniqueId(String keyword) async {
    final response = await _dio.get(
      '$_apiBaseURL/games/search',
      queryParameters: {
        'keyword': keyword,
        'page': '1',
        'limit': _searchLimit,
        'allowNsfw': _allowNsfw,
      },
      options: Options(headers: _buildAuthHeaders()),
    );

    if (response.statusCode != 200) {
      return null;
    }

    final json = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final success = safeBool(json, 'success') ?? false;
    if (!success) {
      return null;
    }

    final data = safeMap(json, 'data');
    if (data == null) return null;

    final items = safeList(data, 'items');
    if (items == null || items.isEmpty) return null;

    final first = items.first;
    if (first is! Map) return null;

    final uniqueId = safeString(Map<String, dynamic>.from(first), 'uniqueId');
    if (uniqueId == null || uniqueId.isEmpty) return null;

    // 格式校验：8 位字母数字
    if (!_isValidUniqueId(uniqueId)) return null;
    return uniqueId;
  }

  // ==================== 详情阶段 ====================

  /// 调用 /games/{uniqueId} 获取游戏详情
  Future<MetadataResult> _fetchDetail(String uniqueId) async {
    final response = await _dio.get(
      '$_apiBaseURL/games/$uniqueId',
      queryParameters: {'allowNsfw': _allowNsfw},
      options: Options(headers: _buildAuthHeaders()),
    );

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final json = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final success = safeBool(json, 'success') ?? false;
    if (!success) return _emptyResult();

    final data = safeMap(json, 'data');
    if (data == null) return _emptyResult();

    final id = safeString(data, 'uniqueId');
    if (id == null || id.trim().isEmpty) return _emptyResult();

    return _parseDetail(data);
  }

  /// 将 TouchGal 详情 JSON 转换为 MetadataResult
  ///
  /// 字段映射：
  /// - name → data.name（已为中文，TouchGal 是中文源）
  /// - coverUrl → data.bannerUrl
  /// - company → data.companies[0].name（取首个非空）
  /// - summary → data.introduction
  /// - rating → data.rating.average（10 分制，直接使用）
  /// - releaseDate → data.releaseDate
  /// - tags → data.tags（字符串数组，weight=1，无剧透）
  MetadataResult _parseDetail(Map<String, dynamic> data) {
    final name = (safeString(data, 'name') ?? '').trim();

    String company = '';
    final companies = safeList(data, 'companies');
    if (companies != null) {
      for (final c in companies) {
        if (c is! Map) continue;
        final cName =
            (safeString(Map<String, dynamic>.from(c), 'name') ?? '').trim();
        if (cName.isNotEmpty) {
          company = cName;
          break;
        }
      }
    }

    double rating = 0.0;
    final ratingData = safeMap(data, 'rating');
    if (ratingData != null) {
      final avg = safeDouble(ratingData, 'average');
      if (avg != null) {
        // TouchGal 评分已是 10 分制，直接使用并夹紧范围
        rating = avg.clamp(0.0, 10.0);
      }
    }

    final tags = _extractTags(safeList(data, 'tags'));

    return MetadataResult(
      game: Game(
        id: (safeString(data, 'uniqueId') ?? '').trim(),
        name: name,
        coverUrl:
            _normalizeBannerUrl((safeString(data, 'bannerUrl') ?? '').trim()),
        company: company,
        summary: (safeString(data, 'introduction') ?? '').trim(),
        rating: rating,
        releaseDate: (safeString(data, 'releaseDate') ?? '').trim(),
        sourceType: SourceType.touchgal,
        sourceId: (safeString(data, 'uniqueId') ?? '').trim(),
        screenshotUrls: const [],
      ),
      tags: tags,
    );
  }

  /// 提取 TouchGal 标签列表
  ///
  /// TouchGal 标签是纯字符串数组（无权重、无剧透标记），
  /// 统一赋 weight=1.0，isSpoiler=false。
  /// 去重 + 保留顺序 + 最多 15 个。
  List<TagItem> _extractTags(List<dynamic>? tagsData) {
    if (tagsData == null || tagsData.isEmpty) return [];

    final result = <TagItem>[];
    final seen = <String>{};
    for (final tag in tagsData) {
      if (tag is! String) continue;
      final name = tag.trim();
      if (name.isEmpty || seen.contains(name)) continue;
      seen.add(name);
      result.add(TagItem(
        name: name,
        source: 'touchgal',
        weight: 1.0,
        isSpoiler: false,
      ));
      if (result.length >= 15) break;
    }
    return result;
  }

  // ==================== 工具方法 ====================

  Map<String, String> _buildAuthHeaders() {
    return {
      'Authorization': 'Bearer ${_token!.trim()}',
      'Accept': 'application/json',
    };
  }

  /// 校验 uniqueId 格式：8 位字母数字
  bool _isValidUniqueId(String id) {
    final trimmed = id.trim();
    if (trimmed.length != _uniqueIdSize) return false;
    final regex = RegExp(r'^[a-zA-Z0-9]{$_uniqueIdSize}$');
    return regex.hasMatch(trimmed);
  }

  /// 规范化 bannerUrl
  ///
  /// TouchGal 返回的 URL 通常已是完整 https 链接，
  /// 但偶尔可能返回相对路径或空字符串。
  String? _normalizeBannerUrl(String url) {
    if (url.isEmpty) return null;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return 'https://developer.touchgal.com$url';
    return url;
  }

  /// 从 DioException 中提取 HTTP 状态码
  int? _extractStatusCode(dynamic e) {
    if (e is DioException) {
      return e.response?.statusCode;
    }
    return null;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
      game: Game(id: '', name: '', sourceType: SourceType.touchgal),
    );
  }
}
