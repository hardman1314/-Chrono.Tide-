import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';
import 'tag_translator.dart';

/// NextMoe·未萌 数据源服务
///
/// NextMoe 开放 API v2（https://developer.nextmoe.dev/docs）：
/// 同一部作品在 VNDB/Bangumi/DLsite/ErogameScape/Ci-en/Getchu 六个源
/// 各有一条记录，NextMoe 将其对齐成一条"裁定后"的记录，逐字段标注出处。
/// Galgame 数据经由鲲 Galgame 论坛生态对齐（署名要求见官方文档）。
///
/// **API 端点**（base: `https://api.nextmoe.dev/v2`）：
/// - 搜索：`GET /catalog/search?object=work&q={kw}&nsfw=true`
///   响应即集合本身（无 code/message/data 信封），`items[]` 每项含
///   `id`（十进制字符串）、`display_name`、`localized{lang:{value}}`
/// - 详情：`GET /catalog/works/{id}?nsfw=true&include={blocks}`
///   默认瘦身（仅身份内核），数据块必须在 `include=` 点名：
///   `titles,intros,covers,screenshots,companies,tags,ratings`
///
/// **鉴权**：`Authorization: Bearer nmk_live_…`（应用密钥，scope: catalog:read）。
/// 密钥为源码常量 [apiKey]（桌面应用无服务端，与 TouchGal/Hikarinagi
/// Token 同等处理方式），轮换时直接修改常量即可。
///
/// **限流**：free 档 60 次/分 · 50,000 次/日，超限返回 429 + `Retry-After`
/// （由 [RateLimiter]/[executeRateLimited] 统一处理退避）。
///
/// **响应契约**（v2 conventions）：
/// - 无信封：响应体就是集合/对象本身
/// - id 为十进制字符串（int64 直发 JSON number 会失真）
/// - 翻页只有 `next_cursor`（末页不出现该键）；本服务单页搜索无需翻页
/// - `nsfw=true` 显式开启成人内容可见性（写别的值是 400 而非按默认处理）
///
/// **数据解析要点**：
/// - 主标题：`localized` 按 zh-Hans → zh-Hant → zh → 原文链取中文名
/// - 副标题：`titles[]` 中 lang=ja 的官方标题（无则 display_name）
/// - 简介：`intros[]`（lang + value）按 zh-Hans → zh → ja → en 链取
/// - 评分：`ratings[]` 多源并列（刻度保持源原生），优先 vndb（与既有
///   MIX 评分权威链一致），次 bangumi（10 分制）、erogamescape（100 分制，
///   经 [normalizeRating] 归一）；vote_count 同步取对应源
/// - 会社：`companies[]` 优先 `attribution_role=developer`
/// - 截图：`screenshots[]` 的 `url`（hash 命名的 webp，CDN 直链），取前 6 张
/// - 标签：`tags[]` 剔除 `tier=hidden`/`tag_kind=meta`（Galgame/PC/GAL 等
///   平台元标签）与剧透标签；display_name 多为中文（bangumi 源），
///   英文标签（vndb 源）经 [TagTranslator] 翻译
class NextMoeService implements MetadataSourceService {
  final Dio _dio;

  static const String apiBase = 'https://api.nextmoe.dev/v2';

  /// 应用密钥（nmk_live_ 前缀，scope: catalog:read）
  ///
  /// 密钥只在铸造时显示一次，泄漏/轮换时到
  /// https://developer.nextmoe.dev/dashboard 控制台吊销重铸后替换此常量。
  static const String apiKey = 'nmk_live_GHd4EtmxacE16KJahhjTIi4Sa9A4';

  NextMoeService({Dio? dio})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
            'Accept': 'application/json',
          },
        )) {
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.nextmoe;

  @override
  String get sourceName => 'NextMoe';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      // /catalog/stats 匿名可调，不消耗密钥配额
      final response = await executeRateLimited(
          SourceType.nextmoe, () => _dio.get('$apiBase/catalog/stats'));
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
      // 1. 搜索（无信封，items[] 即结果）
      final searchResponse = await executeRateLimited(
          SourceType.nextmoe,
          () => _dio.get('$apiBase/catalog/search', queryParameters: {
                'object': 'work',
                'q': keyword,
                'nsfw': 'true',
              }));
      if (searchResponse.statusCode != 200) return _emptyResult();

      final searchData = searchResponse.data is String
          ? jsonDecode(searchResponse.data)
          : searchResponse.data;
      final searchList = safeList(
          searchData is Map ? Map<String, dynamic>.from(searchData) : {},
          'items');
      if (searchList == null || searchList.isEmpty) return _emptyResult();

      final bestMatch = _pickBestMatch(searchList, keyword);
      if (bestMatch == null) return _emptyResult();
      final id = safeString(bestMatch, 'id') ?? '';
      if (id.isEmpty) return _emptyResult();

      // 2. 详情（数据块需在 include= 点名，默认仅身份内核）
      final detailResponse = await executeRateLimited(
          SourceType.nextmoe,
          () => _dio.get('$apiBase/catalog/works/$id', queryParameters: {
                'nsfw': 'true',
                'include': 'titles,intros,covers,screenshots,companies,tags,ratings',
              }));
      if (detailResponse.statusCode != 200) return _emptyResult();

      final detailData = detailResponse.data is String
          ? jsonDecode(detailResponse.data)
          : detailResponse.data;
      if (detailData is! Map) return _emptyResult();

      return _parseDetail(Map<String, dynamic>.from(detailData));
    } catch (e) {
      fetchLog('[NextMoe] 查询失败 [$name]: $e');
      return _emptyResult();
    }
  }

  /// 从搜索结果中挑选与查询词最匹配的项
  ///
  /// 候选名称集合：display_name + localized 各语言 value，
  /// 打分规则与其他源一致（精确 100 / 前缀 40 / 包含 20）。
  Map<String, dynamic>? _pickBestMatch(List<dynamic> results, String query) {
    final candidates = <Map<String, dynamic>>[];
    for (final r in results) {
      if (r is Map) candidates.add(Map<String, dynamic>.from(r));
    }
    if (candidates.isEmpty) return null;

    final specialChars = RegExp(r'[-_:(\)\[\]"]');
    final queryNorm =
        query.toLowerCase().replaceAll(specialChars, '').replaceAll(' ', '');

    Map<String, dynamic> bestResult = candidates.first;
    int bestScore = -1;

    for (final item in candidates) {
      final names = <String>{};
      final display = safeString(item, 'display_name');
      if (display != null && display.isNotEmpty) names.add(display);
      final localized = safeMap(item, 'localized');
      if (localized != null) {
        for (final entry in localized.values) {
          if (entry is Map) {
            final v = entry['value'];
            if (v is String && v.isNotEmpty) names.add(v);
          }
        }
      }

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
        } else if (nameNorm.contains(queryNorm) || queryNorm.contains(nameNorm)) {
          score = 20;
        }
        if (score > itemBest) itemBest = score;
      }
      if (itemBest > bestScore) {
        bestScore = itemBest;
        bestResult = item;
      }
    }
    return bestResult;
  }

  /// 详情解析（仅供单元测试离线验证，见 test/services/nextmoe_service_test.dart）
  @visibleForTesting
  MetadataResult parseDetailForTesting(Map<String, dynamic> json) =>
      _parseDetail(json);

  MetadataResult _parseDetail(Map<String, dynamic> json) {
    final id = safeString(json, 'id') ?? '';

    // 主标题：localized 中文名优先（zh-Hans → zh-Hant → zh 前缀兜底）
    String name = safeString(json, 'display_name') ?? '';
    final localized = safeMap(json, 'localized');
    if (localized != null) {
      for (final lang in ['zh-Hans', 'zh-Hant']) {
        final entry = localized[lang];
        if (entry is Map) {
          final v = entry['value'];
          if (v is String && v.isNotEmpty) {
            name = v;
            break;
          }
        }
      }
      // 兜底：任意 zh* 语言
      if (!_hasZhName(localized)) {
        for (final entry in localized.entries) {
          if (entry.key.startsWith('zh') && entry.value is Map) {
            final v = (entry.value as Map)['value'];
            if (v is String && v.isNotEmpty) {
              name = v;
              break;
            }
          }
        }
      }
    }
    if (name.isEmpty) return _emptyResult();

    // 副标题：titles[] 中 lang=ja 的官方标题（无则 display_name 原文）
    String? originalTitle;
    final titles = safeList(json, 'titles');
    if (titles != null) {
      for (final t in titles) {
        if (t is! Map) continue;
        final tMap = Map<String, dynamic>.from(t);
        final lang = safeString(tMap, 'lang') ?? '';
        final kind = safeString(tMap, 'title_kind') ?? '';
        if (lang == 'ja' && kind == 'official') {
          final v = safeString(tMap, 'title');
          if (v != null && v.isNotEmpty) {
            originalTitle = v;
            break;
          }
        }
      }
    }
    originalTitle ??= safeString(json, 'display_name');

    // 封面：cover.url（裁定后的最佳封面，含 hash/宽高/来源）
    String coverUrl = '';
    final cover = safeMap(json, 'cover');
    if (cover != null) {
      coverUrl = safeString(cover, 'url') ?? '';
    }

    // ★ 2026-10-04 横幅封面：covers[] 数组（详情 include 已请求 covers 块，
    //   旧代码只读单数 cover 把数组丢掉了）。从中选**横版**（宽>高）图，
    //   多张时取面积最大的一张。没有横版 → null（UI 回退竖向封面）。
    final bannerUrl = _pickLandscapeBanner(json, excludeUrl: coverUrl);

    // 简介：intros[] 按中文 → 日文 → 英文链
    String summary = '';
    final intros = safeList(json, 'intros');
    if (intros != null) {
      const langPriority = ['zh-Hans', 'zh-Hant', 'zh', 'ja', 'en'];
      final byLang = <String, String>{};
      for (final item in intros) {
        if (item is! Map) continue;
        final itemMap = Map<String, dynamic>.from(item);
        final lang = safeString(itemMap, 'lang') ?? '';
        final value = safeString(itemMap, 'value') ?? '';
        if (lang.isNotEmpty && value.isNotEmpty && !byLang.containsKey(lang)) {
          byLang[lang] = value;
        }
      }
      for (final lang in langPriority) {
        final v = byLang[lang];
        if (v != null) {
          summary = v;
          break;
        }
      }
      // 兜底：任意 zh* 语言
      if (summary.isEmpty) {
        summary = byLang.entries
            .firstWhere(
              (e) => e.key.startsWith('zh'),
              orElse: () => byLang.entries.isEmpty
                  ? const MapEntry('', '')
                  : byLang.entries.first,
            )
            .value;
      }
    }

    // 会社：companies[] 优先 developer 角色，其次 publisher
    String company = '';
    final companies = safeList(json, 'companies');
    if (companies != null) {
      String? developer;
      String? publisher;
      for (final c in companies) {
        if (c is! Map) continue;
        final cMap = Map<String, dynamic>.from(c);
        final displayName = safeString(cMap, 'display_name');
        if (displayName == null || displayName.isEmpty) continue;
        final role = safeString(cMap, 'attribution_role') ?? '';
        if (role == 'developer' && developer == null) {
          developer = displayName;
        } else {
          publisher ??= displayName;
        }
      }
      company = developer ?? publisher ?? '';
    }

    // 评分：多源并列，优先 vndb（评分权威链与 MIX 一致），
    // 次 bangumi（10 分制）、erogamescape（100 分制，归一化）
    double rating = 0.0;
    int? voteCount;
    final ratings = safeList(json, 'ratings');
    if (ratings != null) {
      const sourcePriority = ['vndb', 'bangumi', 'erogamescape'];
      final bySource = <String, Map<String, dynamic>>{};
      for (final r in ratings) {
        if (r is! Map) continue;
        final rMap = Map<String, dynamic>.from(r);
        final source = safeString(rMap, 'source') ?? '';
        if (source.isNotEmpty && !bySource.containsKey(source)) {
          bySource[source] = rMap;
        }
      }
      for (final source in sourcePriority) {
        final rMap = bySource[source];
        if (rMap == null) continue;
        final score = safeDouble(rMap, 'score');
        if (score == null || score <= 0) continue;
        rating = normalizeRating(score);
        voteCount = safeInt(rMap, 'vote_count');
        break;
      }
    }

    // 标签：剔除平台元标签（tier=hidden / tag_kind=meta）与剧透标签
    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null) {
      for (final tag in tagsData) {
        if (tag is! Map) continue;
        final tagMap = Map<String, dynamic>.from(tag);
        final tier = safeString(tagMap, 'tier') ?? '';
        final tagKind = safeString(tagMap, 'tag_kind') ?? '';
        final spoiler = safeString(tagMap, 'spoiler') ?? 'none';
        if (tier == 'hidden' || tagKind == 'meta') continue;
        if (spoiler != 'none') continue;
        final tagName = safeString(tagMap, 'display_name');
        if (tagName == null || tagName.isEmpty) continue;
        // 中文标签（bangumi 源）直通，英文标签（vndb 源）翻译
        final translated = TagTranslator.translate(tagName, SourceType.vndb);
        tags.add(TagItem(
          name: translated,
          source: 'nextmoe',
          weight: 1.0,
          isSpoiler: spoiler != 'none',
        ));
        if (tags.length >= 10) break;
      }
    }

    return MetadataResult(
      game: Game(
        id: id,
        name: name,
        originalTitle: originalTitle,
        coverUrl: coverUrl,
        bannerUrl: bannerUrl,
        company: company,
        summary: summary,
        rating: rating,
        voteCount: voteCount,
        releaseDate: safeString(json, 'release_date') ?? '',
        sourceType: SourceType.nextmoe,
        sourceId: id,
        screenshotUrls: _extractScreenshots(json),
      ),
      tags: tags,
    );
  }

  bool _hasZhName(Map<String, dynamic> localized) {
    for (final lang in ['zh-Hans', 'zh-Hant']) {
      final entry = localized[lang];
      if (entry is Map && entry['value'] is String) {
        return true;
      }
    }
    return false;
  }

  /// 从详情响应提取截图 URL（hash 命名的 webp CDN 直链），最多6张
  List<String>? _extractScreenshots(Map<String, dynamic> json) {
    final screenshots = safeList(json, 'screenshots');
    if (screenshots == null || screenshots.isEmpty) return null;

    final urls = <String>[];
    for (final s in screenshots.take(6)) {
      if (s is! Map) continue;
      final url = safeString(Map<String, dynamic>.from(s), 'url') ?? '';
      if (url.isNotEmpty) urls.add(url);
    }
    return urls.isEmpty ? null : urls;
  }

  /// 从 `covers[]` 数组里选横版横幅（仅供单元测试离线验证）
  @visibleForTesting
  String? pickLandscapeBannerForTesting(Map<String, dynamic> json,
          {String? excludeUrl}) =>
      _pickLandscapeBanner(json, excludeUrl: excludeUrl);

  /// 横幅挑选规则（2026-10-05 两轮策略）：
  /// ① 第一轮：只收宽>高且有尺寸的项，取面积最大（清晰度优先）；
  /// ② 第二轮（第一轮无果时）：covers 里可能存在**缺宽高元数据**的真横幅
  ///    （旧逻辑直接跳过导致「部分游戏未抓取到横幅」）→ 取无尺寸且与竖封面
  ///    URL 不同的第一张作为**未验证候选**返回，真伪交给下载侧宽高比校验
  ///    （CoverDownloadService minAspectRatio ≥1.15）裁决——不达标会被拒收。
  /// ③ 与竖封面 URL 相同的项始终跳过（避免"横幅=竖图拉伸"的假横幅）。
  String? _pickLandscapeBanner(Map<String, dynamic> json,
      {String? excludeUrl}) {
    final covers = safeList(json, 'covers');
    if (covers == null || covers.isEmpty) return null;

    String? bestUrl;
    int bestArea = 0;
    String? unknownSizeUrl; // 第二轮候选：无尺寸元数据的项
    for (final c in covers) {
      if (c is! Map) continue;
      final cMap = Map<String, dynamic>.from(c);
      final url = safeString(cMap, 'url') ?? '';
      if (url.isEmpty) continue;
      if (excludeUrl != null && excludeUrl.isNotEmpty && url == excludeUrl) {
        continue;
      }
      final width = safeInt(cMap, 'width') ?? 0;
      final height = safeInt(cMap, 'height') ?? 0;
      if (width <= 0 || height <= 0) {
        // 缺尺寸：仅作第二轮候选（第一份非空 URL）
        unknownSizeUrl ??= url;
        continue;
      }
      if (width <= height) continue; // 只收横版
      final area = width * height;
      if (area > bestArea) {
        bestArea = area;
        bestUrl = url;
      }
    }
    // 第二轮：无已确认横版时回退未验证候选（下载侧校验兜底）
    return bestUrl ?? unknownSizeUrl;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.nextmoe));
  }
}
