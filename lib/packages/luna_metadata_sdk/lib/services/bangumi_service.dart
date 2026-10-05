import 'dart:convert' as convert;

import 'package:dio/dio.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'bangumi_oauth.dart';
import 'metadata_base.dart';

/// Bangumi 数据源服务
///
/// 直接使用原站 `api.bgm.tv`。访问策略：个人访问令牌优先
/// （用户在设置弹窗填入，更高速率限额）+ 匿名兜底（未填入时匿名访问）。
/// 国内访问原站需代理，代理由全局 Dio（[MetadataFetcher] 三级代理
/// 优先级）统一处理。
///
/// 特点：
/// 1. 直接使用原站 `api.bgm.tv`，废弃镜像站
/// 2. 个人访问令牌优先，401 时降级匿名访问
/// 3. 智能最佳匹配 [_pickBestMatch]，避免盲目取首个结果
/// 4. 速率受限（[executeRateLimited]），防 429
///
/// 注：类名保留 `BangumiMirrorService` 以维持向后兼容（历史命名）。
class BangumiMirrorService implements MetadataSourceService {
  final Dio _dio;

  /// 原站 API 基址
  static const String _baseURL = 'https://api.bgm.tv';

  BangumiMirrorService({Dio? dio})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': 'application/json',
          },
        )) {
    // 继承代理配置：dio 非空时复制其代理回调；为 null 时显式 DIRECT
    applyProxyConfig(dio, _dio);
  }

  @override
  String get sourceName => 'Bangumi';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  SourceType get sourceType => SourceType.bangumi;

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.head(_baseURL);
      return response.statusCode == 200 ||
          response.statusCode == 404 ||
          response.statusCode == 405;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    if (name.isEmpty) {
      return _emptyResult();
    }

    try {
      // 加载用户配置的个人访问令牌
      final token = await BangumiTokenStore.loadToken();

      // 有令牌时优先使用，401 时降级匿名
      if (token != null && token.isNotEmpty) {
        try {
          return await _search(name, token);
        } on _UnauthorizedException {
          fetchLog('[Bangumi] Token 无效或已过期，降级匿名访问');
        }
      }

      // 匿名访问
      return await _search(name, null);
    } catch (e) {
      fetchLog('[Bangumi] 查询失败: $e');
      return _emptyResult();
    }
  }

  /// 发起搜索请求
  ///
  /// [token] 非空时带 Bearer 认证（授权用户），为 null 时匿名访问。
  /// 返回 401 时抛 [_UnauthorizedException] 供上层降级匿名重试。
  Future<MetadataResult> _search(String keyword, String? token) async {
    final url = '$_baseURL/v0/search/subjects?limit=10&offset=0';

    try {
      final response = await executeRateLimited(
          SourceType.bangumi,
          () => _dio.post(
                url,
                data: {
                  'keyword': keyword,
                  'sort': 'rank',
                  'filter': {
                    'type': [4], // 只搜索游戏类型
                    'nsfw': true,
                  },
                },
                options: token != null
                    ? Options(headers: {'Authorization': 'Bearer $token'})
                    : null,
              ));

      if (response.statusCode == 401) {
        throw _UnauthorizedException();
      }
      if (response.statusCode != 200) {
        return _emptyResult();
      }

      final data = response.data is String
          ? convert.jsonDecode(response.data)
          : response.data;
      final results = data['data'] as List<dynamic>? ?? [];

      if (results.isEmpty) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.bangumi));
      }

      // Phase 2.5: 最佳匹配，避免盲目取 results.first
      final bestMatch = _pickBestMatch(results, keyword);
      return _parseGameResponse(bestMatch ?? {});
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw _UnauthorizedException();
      }
      fetchLog('[Bangumi] 搜索网络错误: ${e.message}');
      return _emptyResult();
    }
  }

  /// Phase 2.5: 从 Bangumi 搜索结果中挑选与查询词最匹配的项
  ///
  /// Bangumi 搜索按 rank 排序，但同名作品可能存在多个载体
  /// （PC游戏、主机版、合集、OVA等），rank 最高者未必是用户想要的版本。
  /// 本方法通过名称相似度重新打分，优先选择标题精确匹配的 PC 游戏版本。
  ///
  /// 评分规则：
  /// - 精确匹配（去标点小写后相等）+100
  /// - 前缀匹配 +40
  /// - 包含匹配 +20
  /// - 候选名称集合：name_cn + name（原文名）
  ///
  /// 当所有候选分数都 < 20 时返回 null（放弃匹配），避免返回错误游戏。
  Map<String, dynamic>? _pickBestMatch(List<dynamic> results, String query) {
    final candidates = <Map<String, dynamic>>[];
    for (final r in results) {
      if (r is Map) candidates.add(Map<String, dynamic>.from(r));
    }
    if (candidates.isEmpty) return null;

    final specialChars = RegExp(r'[-_:(\)\[\]"]');
    final queryNorm =
        query.toLowerCase().replaceAll(specialChars, '').replaceAll(' ', '');

    Map<String, dynamic>? bestResult;
    int bestScore = 0;

    for (final item in candidates) {
      final names = <String>{};
      final nameCn = safeString(item, 'name_cn');
      final name = safeString(item, 'name');
      if (nameCn != null && nameCn.isNotEmpty) names.add(nameCn);
      if (name != null && name.isNotEmpty) names.add(name);

      int itemBest = 0;
      for (final n in names) {
        final nameNorm =
            n.toLowerCase().replaceAll(specialChars, '').replaceAll(' ', '');
        if (nameNorm.isEmpty) continue;

        int score = 0;
        if (nameNorm == queryNorm) {
          score = 100;
        } else if (nameNorm.startsWith(queryNorm)) {
          score = 40;
        } else if (nameNorm.contains(queryNorm) ||
            queryNorm.contains(nameNorm)) {
          score = 20;
        }
        if (score > itemBest) itemBest = score;
      }

      if (itemBest > bestScore) {
        bestScore = itemBest;
        bestResult = item;
      }
    }

    // 最低匹配阈值：至少包含匹配（score >= 20），否则放弃
    if (bestScore < 20) return null;
    return bestResult;
  }

  MetadataResult _parseGameResponse(Map<String, dynamic> json) {
    // 检查是否为游戏类型（type=4）
    final type = safeInt(json, 'type') ?? 0;
    if (type != 4) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.bangumi));
    }

    // 提取图片（P1.2：不再替换为 bangumi.one，原站 lain.bgm.tv 直接可用）
    final images = safeMap(json, 'images') ?? {};
    String coverUrl = _normalizeImageUrl(safeString(images, 'large') ?? '');
    if (coverUrl.isEmpty) {
      coverUrl = _normalizeImageUrl(safeString(images, 'common') ?? '');
    }

    // 提取名称（优先中文名）
    String name = safeString(json, 'name_cn') ?? '';
    if (name.isEmpty) name = safeString(json, 'name') ?? '';

    // 原版标题（日文）：主名称为中文译名时，name 字段即原版标题
    // 仅在含 CJK 字符时采用（排除纯英文标题）
    String? originalTitle;
    final nameCn = safeString(json, 'name_cn') ?? '';
    final rawName = safeString(json, 'name') ?? '';
    if (nameCn.isNotEmpty &&
        rawName.isNotEmpty &&
        rawName != nameCn &&
        _containsCjk(rawName)) {
      originalTitle = rawName;
    }

    // 提取评分
    final ratingData = safeMap(json, 'rating') ?? {};
    final rating = normalizeRating(safeDouble(ratingData, 'score') ?? 0.0);

    // 提取标签
    final tags = _extractTags(safeList(json, 'tags'));

    return MetadataResult(
      game: Game(
        id: safeString(json, 'id') ?? '',
        name: name,
        originalTitle: originalTitle,
        coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
        company: _extractCompany(safeList(json, 'infobox')),
        summary: safeString(json, 'summary'),
        rating: rating,
        releaseDate: safeString(json, 'date')?.trim(),
        sourceType: SourceType.bangumi,
        sourceId: safeString(json, 'id') ?? '',
      ),
      tags: tags,
    );
  }

  /// 判断文本是否含 CJK 字符（用于过滤纯英文标题）
  static final RegExp _cjkRegExp =
      RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');

  static bool _containsCjk(String text) => _cjkRegExp.hasMatch(text);

  String? _extractCompany(dynamic infobox) {
    if (infobox is! List) return null;

    for (final item in infobox) {
      if (item is! Map) continue;

      final itemMap = Map<String, dynamic>.from(item);
      final key = safeString(itemMap, 'key') ?? '';
      if (key.contains('开发商') || key.contains('开发')) {
        final value = itemMap['value'];

        if (value is String) return value;
        if (value is List && value.isNotEmpty) {
          final first = value.first;
          if (first is String) return first;
          if (first is Map) {
            return safeString(Map<String, dynamic>.from(first), 'v');
          }
        }
      }
    }

    return null;
  }

  List<TagItem> _extractTags(dynamic tagsData) {
    if (tagsData is! List) return [];

    final rawTags = <Map<String, dynamic>>[];

    for (final tag in tagsData) {
      if (tag is! Map) continue;
      final tagMap = Map<String, dynamic>.from(tag);
      final count = safeInt(tagMap, 'count') ?? 0;
      if (count >= 3) {
        rawTags.add(tagMap);
      }
    }

    // 按 count 降序排序
    rawTags.sort((a, b) {
      final countA = safeInt(a, 'count') ?? 0;
      final countB = safeInt(b, 'count') ?? 0;
      return countB.compareTo(countA);
    });

    // 取前10个标签
    final limitedTags = rawTags.take(10).toList();
    if (limitedTags.isEmpty) return [];

    final maxCount = safeInt(limitedTags.first, 'count') ?? 1;

    return limitedTags.map((tag) {
      final count = safeInt(tag, 'count') ?? 0;
      final weight = maxCount > 0 ? count / maxCount : 1.0;

      return TagItem(
        name: safeString(tag, 'name') ?? '',
        source: 'bangumi',
        weight: weight,
        isSpoiler: false,
      );
    }).toList();
  }

  /// 修复图片 URL（P1.2：不再替换 bgm.tv→bangumi.one）
  ///
  /// 原站 lain.bgm.tv 图片在代理环境下直接可访问，
  /// 仅处理协议相对 URL 和相对路径。
  String _normalizeImageUrl(String url) {
    if (url.isEmpty) return '';

    var result = url;

    // 处理协议相对 URL（// 开头）
    if (result.startsWith('//')) {
      return 'https:$result';
    }

    // 处理相对路径（/ 开头）
    if (result.startsWith('/') && !result.startsWith('//')) {
      return 'https://lain.bgm.tv$result';
    }

    return result;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.bangumi));
  }
}

/// 内部异常：Bangumi API 返回 401 Unauthorized
///
/// 由 [BangumiMirrorService._search] 方法在 HTTP 401 时抛出，
/// [BangumiMirrorService.fetchByName] 捕获后刷新 OAuth Token 并重试一次，
/// 刷新失败则降级匿名访问。
class _UnauthorizedException implements Exception {
  final String? message;
  _UnauthorizedException([this.message]);
  @override
  String toString() => message != null
      ? '_UnauthorizedException: $message'
      : '_UnauthorizedException';
}
