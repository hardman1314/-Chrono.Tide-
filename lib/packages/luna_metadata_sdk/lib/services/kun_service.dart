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
/// **数据结构特点**（2026-08 站点改版为 v2 格式，同时保留旧格式兼容）：
/// - 名称：v2 为本地化字符串 `name` + 原名 `name_original`；
///   旧版为多语言 Map（zh-cn / ja-jp / en-us / zh-tw），优先 zh-cn
/// - 简介：v2 为 `introduction[]`（lang + HTML intro）或 `intro_text` 纯文本；
///   旧版为多语言 `markdown` Map
/// - v2 新增：`rating`/`rating_count`（站内评分）、`external_ratings[]`
///   （含 VNDB 跨站评分/投票数）、`screenshots[]`（cdn_url）、
///   `official[].roles`（developer/publisher）、`refs.vndb`
/// - `content_limit`（sfw/nsfw）+ `age_limit`（all/r18）双重 NSFW 标记
/// - `vndb_id` 字段跨源补全 VNDB 数据（评分/投票数/截图，见 [_enrichFromVndb]，
///   v2 详情自带上述字段时不再发起 VNDB 请求）
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

      var result = _parseDetail(detailData);

      // 跨源补全：v2 详情已自带 rating/external_ratings/screenshots，
      // 仅当评分/投票数/截图仍缺失时才请求 VNDB（省一次 API 调用与限流配额）
      final vndbId = _extractVndbId(detailData);
      final needsVndb = result.game.rating <= 0 ||
          result.game.voteCount == null ||
          (result.game.screenshotUrls?.isEmpty ?? true);
      if (vndbId != null && needsVndb) {
        result = await _enrichFromVndb(result, vndbId);
      }

      return result;
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

  /// 原版标题提取：优先日文（ja-jp），无日文时为 null（不取英文）
  ///
  /// 供上游作为"副标题"使用；兜底读取顶层 title 字段（若为日文文本）。
  String? _pickOriginalTitle(
      Map<String, dynamic> nameMap, Map<String, dynamic> json) {
    const jaKeys = ['ja-jp', 'ja', 'ja_JP'];
    for (final key in jaKeys) {
      final v = safeString(nameMap, key);
      if (v != null && v.isNotEmpty) return v;
    }
    // 兜底：title 字段含日文假名时视为原版标题
    final title = safeString(json, 'title') ?? '';
    if (title.isNotEmpty && _containsJapanese(title)) return title;
    return null;
  }

  /// 判断文本是否含日文假名（平假名/片假名）
  static final RegExp _jaKanaRegExp = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');

  static bool _containsJapanese(String text) =>
      _jaKanaRegExp.hasMatch(text);

  /// 多语言简介优先级：zh-cn → zh-tw → ja-jp → en-us（旧版 markdown 格式）
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

  /// v2 简介提取：`introduction[]` 按 lang 优先级选取（zh-Hans → zh → ja → en）
  ///
  /// 条目为 `{lang, intro(HTML), machine}`；无匹配语言时取第一个非空 intro。
  /// `introduction` 整体缺失时回退 `intro_text`（中文纯文本）。
  String _pickIntroduction(Map<String, dynamic> json) {
    final introList = safeList(json, 'introduction');
    if (introList != null && introList.isNotEmpty) {
      final entries = introList
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      const priority = ['zh-Hans', 'zh-CN', 'zh', 'ja', 'en'];
      for (final lang in priority) {
        for (final e in entries) {
          if (safeString(e, 'lang') != lang) continue;
          final intro = safeString(e, 'intro');
          if (intro != null && intro.isNotEmpty) return _stripHtml(intro);
        }
      }
      for (final e in entries) {
        final intro = safeString(e, 'intro');
        if (intro != null && intro.isNotEmpty) return _stripHtml(intro);
      }
    }
    final introText = safeString(json, 'intro_text');
    if (introText != null && introText.isNotEmpty) return introText.trim();
    return '';
  }

  /// HTML 片段转纯文本（v2 introduction 的 intro 为 HTML）
  static final RegExp _htmlTagRegExp = RegExp(r'<[^>]*>');

  String _stripHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>\s*'), '\n')
        .replaceAll(_htmlTagRegExp, '');
    // 解码常见 HTML 实体（含数字实体，如 &#34;）
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)));
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// 开发商提取：`official[]`
  ///
  /// v2 条目含 `roles`（developer/publisher），优先取开发商；
  /// 无 roles（旧版）时保持原行为：取前 3 条名称拼接。
  String _extractCompany(Map<String, dynamic> json) {
    final official = safeList(json, 'official');
    if (official == null || official.isEmpty) return '';
    final entries = official
        .whereType<Map>()
        .map((o) => Map<String, dynamic>.from(o))
        .toList();
    final developers = entries.where((o) {
      final roles = safeList(o, 'roles');
      return roles != null && roles.contains('developer');
    }).toList();
    final source = developers.isNotEmpty ? developers : entries;
    final names = <String>[];
    for (final o in source.take(3)) {
      final name = safeString(o, 'name') ?? safeString(o, 'organization');
      if (name != null && name.isNotEmpty) names.add(name);
    }
    return names.join(', ');
  }

  /// v2 截图提取：`screenshots[].cdn_url`，最多 6 张
  List<String>? _extractScreenshots(Map<String, dynamic> json) {
    final shotsData = safeList(json, 'screenshots');
    if (shotsData == null || shotsData.isEmpty) return null;
    final urls = <String>[];
    for (final s in shotsData) {
      if (s is! Map) continue;
      final url = safeString(Map<String, dynamic>.from(s), 'cdn_url') ?? '';
      if (url.isNotEmpty) urls.add(url);
    }
    return urls.isEmpty ? null : urls.take(6).toList();
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
      // 收集候选名称（v2：name/name_original 为字符串；旧版：name 为多语言 Map）
      final names = <String>{};
      final nameField = item['name'];
      if (nameField is Map) {
        for (final v in nameField.values) {
          if (v is String && v.isNotEmpty) names.add(v);
        }
      } else if (nameField is String && nameField.isNotEmpty) {
        names.add(nameField);
      }
      final nameOriginal = safeString(item, 'name_original');
      if (nameOriginal != null && nameOriginal.isNotEmpty) {
        names.add(nameOriginal);
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
    // 名称：v2 为本地化字符串；旧版为多语言 Map（优先 zh-cn）
    final nameField = json['name'];
    Map<String, dynamic>? nameMap;
    String name = '';
    if (nameField is Map) {
      nameMap = Map<String, dynamic>.from(nameField);
      name = _pickName(nameMap);
    } else if (nameField is String) {
      name = nameField;
    }
    if (name.isEmpty) name = safeString(json, 'title') ?? '';

    // 原版标题：v2 name_original 字段优先；旧版从多语言 Map 取日文。
    // 本地化名称与原名相同时置空，避免副标题重复展示
    String? originalTitle = safeString(json, 'name_original');
    if (originalTitle == null && nameMap != null) {
      originalTitle = _pickOriginalTitle(nameMap, json);
    }
    if (originalTitle == name) originalTitle = null;

    // 封面
    String coverUrl = safeString(json, 'effective_banner_url') ??
        safeString(json, 'banner_url') ??
        '';

    // ★ 2026-10-04 横幅封面：kun v2 的 effective_banner_url / banner_url
    //   本就是横版大图（现有代码拿它当封面用），横幅语义直接对齐——
    //   同时保留 coverUrl 原值不动（最小变更，封面链路行为不变）。
    final bannerUrl = safeString(json, 'effective_banner_url') ??
        safeString(json, 'banner_url');

    // 简介：v2 introduction[]（HTML）→ intro_text；旧版 markdown 多语言 Map
    String summary = _pickIntroduction(json);
    if (summary.isEmpty) {
      final mdMap = safeMap(json, 'markdown') ?? safeMap(json, 'content') ?? {};
      summary = _pickMarkdown(mdMap);
    }

    // 开发商：official[]（v2 含 roles，优先 developer 角色）
    String company = _extractCompany(json);

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

    // 评分/投票数：v2 自带站内 rating/rating_count 及 external_ratings[] 跨站评分。
    // 评分优先 KunGal 站内评分，投票数优先 external_ratings 中 VNDB 投票数（热度代理）
    double rating = normalizeRating(safeDouble(json, 'rating') ?? 0.0);
    int? voteCount;
    final externalRatings = safeList(json, 'external_ratings');
    if (externalRatings != null) {
      for (final e in externalRatings) {
        if (e is! Map) continue;
        final item = Map<String, dynamic>.from(e);
        if (safeString(item, 'source') != 'vndb') continue;
        if (rating <= 0) {
          final vndbScore = safeDouble(item, 'score');
          if (vndbScore != null && vndbScore > 0) {
            rating = normalizeRating(vndbScore);
          }
        }
        voteCount = safeInt(item, 'vote_count');
        break;
      }
    }
    voteCount ??= safeInt(json, 'rating_count');

    // 截图：v2 screenshots[]（cdn_url）
    final screenshots = _extractScreenshots(json);

    // 注：vndb_id/refs.vndb 用于跨源补全（见 fetchByName 与 _enrichFromVndb）

    return MetadataResult(
      game: Game(
        id: id,
        name: name,
        originalTitle: originalTitle,
        coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
        bannerUrl: (bannerUrl != null && bannerUrl.isNotEmpty) ? bannerUrl : null,
        company: company,
        summary: summary,
        rating: rating,
        voteCount: voteCount,
        releaseDate: safeString(json, 'release_date')?.trim(),
        sourceType: SourceType.kun,
        sourceId: id,
        screenshotUrls: screenshots,
      ),
      tags: tags,
    );
  }

  /// 提取并规范化 VNDB ID（支持 "v12345" / "12345" / 数字 两种格式）
  ///
  /// 优先顶层 `vndb_id`，缺失时回退 v2 的 `refs.vndb`；
  /// 无法识别时返回 null（不影响主流程）
  String? _extractVndbId(Map<String, dynamic> json) {
    final raw = safeString(json, 'vndb_id') ?? safeString(json, 'vndb');
    if (raw == null) {
      final refs = safeMap(json, 'refs');
      if (refs != null) return _normalizeVndbId(safeString(refs, 'vndb'));
      return null;
    }
    return _normalizeVndbId(raw);
  }

  String? _normalizeVndbId(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (RegExp(r'^v\d+$', caseSensitive: false).hasMatch(trimmed)) {
      return trimmed.toLowerCase();
    }
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      return 'v$trimmed';
    }
    return null;
  }

  /// 用 vndb_id 从 VNDB 补全 KunGal 缺失的元数据
  ///
  /// 补全字段：评分（rating）、投票数（voteCount）、截图（screenshotUrls）、
  /// 发售日（releaseDate，仅当 KunGal 自身为空时兜底）。
  /// 补全请求失败/无结果时静默返回原结果，不影响 KunGal 主数据。
  Future<MetadataResult> _enrichFromVndb(
      MetadataResult result, String vndbId) async {
    try {
      final response = await executeRateLimited(
          SourceType.vndb,
          () => _dio.post(
                'https://api.vndb.org/kana/vn',
                data: {
                  'filters': ['id', '=', vndbId],
                  'fields': 'rating, votecount, released, screenshots{url}',
                },
                options: Options(
                  headers: {'Content-Type': 'application/json'},
                ),
              ));

      if (response.statusCode != 200) return result;

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final results = safeList(json, 'results');
      if (results == null || results.isEmpty) return result;
      final first = results.first;
      if (first is! Map) return result;
      final item = Map<String, dynamic>.from(first);

      // 评分归一化（VNDB rating 为 10-100 区间）
      final rating = normalizeRating(safeDouble(item, 'rating') ?? 0.0);
      final voteCount = safeInt(item, 'votecount');
      final released = safeString(item, 'released')?.trim();
      final screenshots = _extractVndbScreenshots(item);

      final oldGame = result.game;
      final game = oldGame.copyWith(
        // 仅补全缺失字段，不覆盖 KunGal 自身数据（v2 已含站内评分/截图）
        rating: oldGame.rating > 0
            ? oldGame.rating
            : (rating > 0 ? rating : oldGame.rating),
        voteCount: oldGame.voteCount ?? voteCount,
        releaseDate:
            (oldGame.releaseDate == null || oldGame.releaseDate!.isEmpty) &&
                    released != null &&
                    released.isNotEmpty
                ? released
                : oldGame.releaseDate,
        screenshotUrls: oldGame.screenshotUrls ?? screenshots,
      );

      fetchLog('[KunGal] ✅ VNDB 补全成功 [$vndbId]: rating=${game.rating} '
          'votes=${game.voteCount} screenshots=${game.screenshotUrls?.length ?? 0}张');
      return MetadataResult(game: game, tags: result.tags);
    } catch (e) {
      fetchLog('[KunGal] ⚠️ VNDB 补全失败 [$vndbId]: $e');
      return result;
    }
  }

  /// 从 VNDB 补全响应中提取截图 URL 列表，最多6张
  List<String>? _extractVndbScreenshots(Map<String, dynamic> json) {
    final screenshotsData = safeList(json, 'screenshots');
    if (screenshotsData == null || screenshotsData.isEmpty) return null;

    final urls = <String>[];
    for (final s in screenshotsData) {
      if (s is! Map) continue;
      final url = safeString(Map<String, dynamic>.from(s), 'url') ?? '';
      if (url.isNotEmpty) urls.add(url);
    }
    return urls.isEmpty ? null : urls.take(6).toList();
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.kun));
  }
}
