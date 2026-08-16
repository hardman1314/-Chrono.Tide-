import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// KunGal 数据源服务（N2）
///
/// 移植自 ReinaManager `api/kun.ts`，采用公开 API（无认证）。
///
/// **API 端点**（base: `https://www.kungal.com/api`）：
/// - 搜索：`GET /search?keywords={kw}&type=galgame&page=1&limit=10`
/// - 详情：`GET /galgame/{id}?galgame_id={id}`
///
/// **数据结构特点**：
/// - 多语言标题（zh-cn / ja-jp / en-us / zh-tw），优先 zh-cn
/// - 多语言简介（markdown 字段）
/// - `content_limit`（sfw/nsfw）+ `age_limit`（all/r18）双重 NSFW 标记
/// - `vndb_id` 字段可跨源补全 VNDB 数据（本次仅记录，不实现补全）
/// - `official[]` 开发商、`tag[]{name,galgame_count}` 标签
class KunService implements MetadataSourceService {
  final Dio _dio;

  static const String apiBase = 'https://www.kungal.com/api';

  KunService({Dio? dio})
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
  SourceType get sourceType => SourceType.kun;

  @override
  String get sourceName => 'KunGal';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await executeRateLimited(SourceType.kun,
          () => _dio.get('$apiBase/search', queryParameters: {
                'keywords': 'test',
                'type': 'galgame',
                'page': 1,
                'limit': 1,
              }));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    final keyword = name.trim();
    if (keyword.isEmpty) return _emptyResult();

    try {
      // 搜索
      final searchResponse = await executeRateLimited(
          SourceType.kun,
          () => _dio.get(
                '$apiBase/search',
                queryParameters: {
                  'keywords': keyword,
                  'type': 'galgame',
                  'page': 1,
                  'limit': 10,
                },
              ));

      if (searchResponse.statusCode != 200) return _emptyResult();

      final searchData = searchResponse.data is String
          ? jsonDecode(searchResponse.data)
          : searchResponse.data;
      // KunGal 返回 {"code":0,"data":{"items":[...]}}，data 是 Map（含 items 列表）
      // 兼容 data 直接为 List 的其他格式
      final dataField = searchData is Map ? searchData['data'] : null;
      List<dynamic>? searchList;
      if (dataField is List) {
        searchList = dataField;
      } else if (dataField is Map) {
        searchList = safeList(Map<String, dynamic>.from(dataField), 'items');
      }
      searchList ??= safeList(searchData, 'results') ??
          safeList(searchData, 'galgames');
      if (searchList == null || searchList.isEmpty) return _emptyResult();

      final bestMatch = _pickBestMatch(searchList, keyword);
      final id = safeString(bestMatch, 'id') ??
          safeInt(bestMatch, 'galgame_id')?.toString() ??
          '';
      if (id.isEmpty) return _emptyResult();

      // 详情
      final detailResponse = await executeRateLimited(
          SourceType.kun,
          () => _dio.get(
                '$apiBase/galgame/$id',
                queryParameters: {'galgame_id': id},
              ));

      if (detailResponse.statusCode != 200) return _emptyResult();
      final detailEnvelope = detailResponse.data is String
          ? jsonDecode(detailResponse.data)
          : detailResponse.data;
      if (detailEnvelope is! Map) return _emptyResult();
      // KunGal 详情响应是 {code, message, data:{...}} envelope，
      // 必须提取内层 data 字段，否则 _parseDetail 在顶层找不到 name/id 等字段
      final detailData =
          safeMap(Map<String, dynamic>.from(detailEnvelope), 'data');
      if (detailData == null) return _emptyResult();

      return _parseDetail(detailData);
    } catch (e) {
      fetchLog('[KunGal] 抓取失败 [$name]: $e');
      return _emptyResult();
    }
  }

  /// 多语言标题优先级：zh-cn → zh-tw → ja-jp → en-us
  String _pickName(Map<String, dynamic> nameMap) {
    const priority = ['zh-cn', 'zh-tw', 'ja-jp', 'en-us'];
    for (final lang in priority) {
      final v = safeString(nameMap, lang);
      if (v != null && v.isNotEmpty) return v;
    }
    // 兜底：任意 zh* 或第一个值
    for (final key in nameMap.keys) {
      if (key.startsWith('zh')) {
        final v = safeString(nameMap, key);
        if (v != null && v.isNotEmpty) return v;
      }
    }
    for (final v in nameMap.values) {
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  /// 多语言简介优先级：zh-cn → zh-tw → ja-jp → en-us
  String _pickMarkdown(Map<String, dynamic> mdMap) {
    const priority = ['zh-cn', 'zh-tw', 'ja-jp', 'en-us'];
    for (final lang in priority) {
      final v = safeString(mdMap, lang);
      if (v != null && v.isNotEmpty) return v;
    }
    for (final v in mdMap.values) {
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  Map<String, dynamic> _pickBestMatch(List<dynamic> results, String query) {
    final specialChars = RegExp(r'[-_:(\)\[\]"]');
    final queryNorm =
        query.toLowerCase().replaceAll(specialChars, '').replaceAll(' ', '');

    Map<String, dynamic> best = results.first is Map
        ? Map<String, dynamic>.from(results.first as Map)
        : <String, dynamic>{};
    int bestScore = -1;

    for (final r in results) {
      if (r is! Map) continue;
      final item = Map<String, dynamic>.from(r);
      // 收集候选名称
      final names = <String>{};
      final nameField = safeMap(item, 'name');
      if (nameField != null) {
        for (final v in nameField.values) {
          if (v is String && v.isNotEmpty) names.add(v);
        }
      }
      final titleField = safeString(item, 'title');
      if (titleField != null && titleField.isNotEmpty) names.add(titleField);

      int itemBest = 0;
      for (final n in names) {
        final norm =
            n.toLowerCase().replaceAll(specialChars, '').replaceAll(' ', '');
        if (norm.isEmpty) continue;
        int score = 0;
        if (norm == queryNorm) {
          score = 100;
        } else if (norm.startsWith(queryNorm)) {
          score = 40;
        } else if (norm.contains(queryNorm) || queryNorm.contains(norm)) {
          score = 20;
        }
        if (score > itemBest) itemBest = score;
      }
      if (itemBest > bestScore) {
        bestScore = itemBest;
        best = item;
      }
    }
    return best;
  }

  MetadataResult _parseDetail(Map<String, dynamic> json) {
    // 名称（多语言）
    final nameMap = safeMap(json, 'name') ?? {};
    String name = _pickName(nameMap);
    if (name.isEmpty) name = safeString(json, 'title') ?? '';

    // 封面
    String coverUrl = safeString(json, 'effective_banner_url') ??
        safeString(json, 'banner_url') ??
        '';

    // 简介（多语言 markdown）
    final mdMap = safeMap(json, 'markdown') ?? safeMap(json, 'content') ?? {};
    String summary = _pickMarkdown(mdMap);

    // 开发商：official[]
    String company = '';
    final official = safeList(json, 'official');
    if (official != null && official.isNotEmpty) {
      final devs = <String>[];
      for (final o in official.take(3)) {
        if (o is String) {
          devs.add(o);
        } else if (o is Map) {
          final name = safeString(Map<String, dynamic>.from(o), 'name') ??
              safeString(Map<String, dynamic>.from(o), 'organization');
          if (name != null && name.isNotEmpty) devs.add(name);
        }
      }
      company = devs.join(', ');
    }

    // 标签：name + galgame_count
    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tag') ?? safeList(json, 'tags');
    if (tagsData != null && tagsData.isNotEmpty) {
      final tagList = <Map<String, dynamic>>[];
      for (final t in tagsData) {
        if (t is! Map) continue;
        tagList.add(Map<String, dynamic>.from(t));
      }
      final maxCount = tagList.fold<int>(0, (m, t) {
        final v = safeInt(t, 'galgame_count') ?? 0;
        return v > m ? v : m;
      });
      tagList.sort((a, b) => (safeInt(b, 'galgame_count') ?? 0)
          .compareTo(safeInt(a, 'galgame_count') ?? 0));
      for (final tag in tagList.take(10)) {
        final tagName = safeString(tag, 'name');
        if (tagName != null && tagName.isNotEmpty) {
          final count = safeInt(tag, 'galgame_count') ?? 0;
          final weight = maxCount > 0 ? (count / maxCount) : 1.0;
          tags.add(TagItem(
            name: tagName,
            source: 'kun',
            weight: weight.clamp(0.1, 1.0),
          ));
        }
      }
    }

    final id = safeString(json, 'id') ?? safeInt(json, 'galgame_id')?.toString() ?? '';
    // 注：Kun 返回 vndb_id 字段，可供未来跨源补全使用（本次不实现补全）

    return MetadataResult(
      game: Game(
        id: id,
        name: name,
        coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
        company: company,
        summary: summary,
        rating: 0.0, // Kun 无评分字段
        releaseDate: safeString(json, 'release_date')?.trim(),
        sourceType: SourceType.kun,
        sourceId: id,
      ),
      tags: tags,
    );
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.kun));
  }
}
