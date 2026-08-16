import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';
import 'tag_translator.dart';
import 'bangumi_service.dart';
import 'hikarinagi_service.dart';
import 'kun_service.dart';
import 'touchgal_service.dart';

class VNDBService implements MetadataSourceService {
  late Dio _dio;

  VNDBService({Dio? dio}) {
    // 始终创建带服务专属 headers 的 Dio（Content-Type 对 VNDB POST 请求必需）
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
      },
    ));
    // 继承代理配置：dio 非空时复制其代理回调；为 null（直连平台）时
    // 显式设置 DIRECT，避免 Dart HttpClient 在 Windows 上读取失效的系统代理注册表
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.vndb;

  @override
  String get sourceName => 'VNDB';

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.post(
        'https://api.vndb.org/kana/vn',
        data: {
          'filters': ['search', '=', 'test'],
          'fields': 'id, title',
          'sort': 'searchrank',
        },
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      // P0.2：速率受限请求，自动 429 退避重试
      final response = await executeRateLimited(
          SourceType.vndb,
          () => _dio.post(
                'https://api.vndb.org/kana/vn',
                data: {
                  'filters': ['search', '=', name],
                  // P1.1：增加 image_flagging 用于 NSFW 判定，tags 增加 level 字段
                  // 阶段3.1：增加 votecount 用于热度代理
                  'fields':
                      'id, title, titles{lang, title, latin, official, main}, image{url}, screenshots{url}, description, rating, votecount, released, developers{name}, tags{name, rating, spoiler, lie}',
                  'sort': 'searchrank',
                },
              ));

      if (response.statusCode != 200) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final results = safeList(json, 'results');

      if (results == null || results.isEmpty) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }

      // Phase 2.5: 最佳匹配，避免盲目取 results[0]
      // VNDB 按搜索相关性返回结果，但相关性排序并不总是与用户输入最匹配
      // 例如 "青春フルサイル" 可能匹配到系列作/外传，而非正作
      final result = _pickBestMatch(results, name);
      if (result == null) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }
      return _parseResponse(result);
    } catch (e) {
      fetchLog('[VNDB] 查询失败 [$name]: $e');
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.vndb));
    }
  }

  /// P1.1：按 ID 批量查询（VNDB 支持 100 IDs/批）
  ///
  /// 用 `["id","=",["v1","v2",...]]` 过滤器一次查询多个游戏，
  /// 将 N 次请求降为 ⌈N/100⌉ 次。本方法为未来跨源补全铺路，
  /// 批量导入按名搜索无 ID，暂不消费。
  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final results = <MetadataResult>[];
    for (int i = 0; i < ids.length; i += 100) {
      final batch = ids.sublist(i, (i + 100).clamp(0, ids.length));
      try {
        final response = await executeRateLimited(
              SourceType.vndb,
              () => _dio.post(
                    'https://api.vndb.org/kana/vn',
                    data: {
                      'filters': ['id', '=', batch],
                      'fields':
                          'id, title, titles{lang, title, latin, official, main}, image{url}, screenshots{url}, description, rating, votecount, released, developers{name}, tags{name, rating, spoiler, lie}',
                    },
                  ));
        if (response.statusCode != 200) continue;
        final json =
            response.data is String ? jsonDecode(response.data) : response.data;
        final list = safeList(json, 'results');
        if (list == null) continue;
        for (final item in list) {
          if (item is Map) {
            results.add(_parseResponse(Map<String, dynamic>.from(item)));
          }
        }
      } catch (e) {
        continue;
      }
    }
    return results;
  }

  /// Phase 2.5: 从 VNDB 搜索结果中挑选与查询词最匹配的项
  ///
  /// VNDB 按搜索相关性排序返回结果，但相关性算法基于全文索引，
  /// 可能误将系列作/外传/同名片放在最前。本方法通过名称相似度重新打分。
  ///
  /// 评分规则：
  /// - 精确匹配（去标点小写后相等）+100
  /// - 前缀匹配 +40
  /// - 包含匹配 +20
  /// - 候选名称集合：title + titles 数组中的 latin/main/official 变体
  ///
  /// 当所有候选分数都为 0 时回退到第一条结果（保持原有行为），
  /// 避免过度过滤导致空结果。
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
      final names = _collectCandidateNames(item);
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

    return bestResult;
  }

  /// 收集 VNDB 结果项的所有候选名称（title + titles 数组中的变体）
  List<String> _collectCandidateNames(Map<String, dynamic> item) {
    final names = <String>{};
    final title = safeString(item, 'title');
    if (title != null && title.isNotEmpty) names.add(title);

    final titles = safeList(item, 'titles');
    if (titles != null) {
      for (final t in titles) {
        if (t is! Map) continue;
        final tMap = Map<String, dynamic>.from(t);
        final titleText = safeString(tMap, 'title');
        final latinText = safeString(tMap, 'latin');
        if (titleText != null && titleText.isNotEmpty) names.add(titleText);
        if (latinText != null && latinText.isNotEmpty) names.add(latinText);
      }
    }

    return names.toList();
  }

  MetadataResult _parseResponse(Map<String, dynamic> json) {
    // P1.1：多语言标题偏好链 zh-hans → zh-hant → zh → ja → en
    // 比原 main/zh/ja 逻辑更精准，优先返回简体中文译名
    String name = safeString(json, 'title') ?? '';
    final titles = safeList(json, 'titles');
    if (titles != null && titles.isNotEmpty) {
      const langPriority = ['zh-hans', 'zh-hant', 'zh', 'ja', 'en'];
      final byLang = <String, String>{};
      for (final t in titles) {
        if (t is! Map) continue;
        final titleMap = Map<String, dynamic>.from(t);
        final lang = safeString(titleMap, 'lang') ?? '';
        final titleText = safeString(titleMap, 'title') ?? '';
        final latinText = safeString(titleMap, 'latin') ?? '';
        final value = titleText.isNotEmpty ? titleText : latinText;
        if (lang.isNotEmpty && value.isNotEmpty && !byLang.containsKey(lang)) {
          byLang[lang] = value;
        }
      }
      String? picked;
      for (final lang in langPriority) {
        if (byLang.containsKey(lang)) {
          picked = byLang[lang];
          break;
        }
      }
      // 兜底：匹配任意 zh* 开头的语言
      picked ??= byLang.entries
          .firstWhere(
            (e) => e.key.startsWith('zh'),
            orElse: () => byLang.entries.first,
          )
          .value;
      if (picked != null && picked.isNotEmpty) name = picked;
    }

    String coverUrl = '';
    final image = safeMap(json, 'image');
    if (image != null) {
      coverUrl = safeString(image, 'url') ?? '';
    }

    String company = '';
    final developers = safeList(json, 'developers');
    if (developers != null && developers.isNotEmpty) {
      final devNames = <String>[];
      for (final dev in developers.take(5)) {
        if (dev is Map) {
          final devName = safeString(Map<String, dynamic>.from(dev), 'name');
          if (devName != null && devName.isNotEmpty) {
            devNames.add(devName);
          }
        }
      }
      company = devNames.join(', ');
    }

    // P1.3：统一评分归一化
    final rating = normalizeRating(safeDouble(json, 'rating') ?? 0.0);

    // 阶段3.1：提取投票数（VNDB 的 votecount 字段，作为热度代理）
    final voteCount = safeInt(json, 'votecount');

    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null) {
      final filteredTags = <Map<String, dynamic>>[];
      for (final tag in tagsData) {
        if (tag is! Map) continue;
        final tagMap = Map<String, dynamic>.from(tag);
        final tagRating = safeDouble(tagMap, 'rating') ?? 0.0;
        // P1.1：剔除重度剧透标签（spoiler==2）
        // VNDB kana API 的剧透等级用 spoiler 字段（0/1/2 int），非 level
        final spoilerLevel = safeInt(tagMap, 'spoiler') ?? 0;
        if (tagRating >= 1.5 && spoilerLevel < 2) {
          filteredTags.add(tagMap);
        }
      }

      filteredTags.sort((a, b) {
        final rA = safeDouble(a, 'rating') ?? 0.0;
        final rB = safeDouble(b, 'rating') ?? 0.0;
        return rB.compareTo(rA);
      });

      for (final tag in filteredTags.take(10)) {
        final tagName = safeString(tag, 'name');
        final tagRating = safeDouble(tag, 'rating') ?? 0.0;
        if (tagName != null && tagName.isNotEmpty) {
          // Phase 2.3: 统一标签为中文
          final translatedName =
              TagTranslator.translate(tagName, SourceType.vndb);
          final tagSpoilerLevel = safeInt(tag, 'spoiler') ?? 0;
          tags.add(TagItem(
            name: translatedName,
            source: 'vndb',
            weight: (tagRating / 3.0).clamp(0.1, 10.0),
            isSpoiler: tagSpoilerLevel > 0,
          ));
        }
      }
    }

    return MetadataResult(
      game: Game(
        id: safeString(json, 'id') ?? '',
        name: name,
        coverUrl: coverUrl,
        company: company,
        summary: safeString(json, 'description') ?? '',
        rating: rating,
        voteCount: voteCount,
        releaseDate: safeString(json, 'released') ?? '',
        sourceType: SourceType.vndb,
        sourceId: safeString(json, 'id') ?? '',
        screenshotUrls: _extractScreenshots(json),
      ),
      tags: tags,
    );
  }

  /// 从 VNDB 响应中提取截图 URL 列表，最多6张
  /// VNDB 返回的 URL 格式为 https://t.vndb.org/sf/xx/xxxxx.jpg
  List<String>? _extractScreenshots(Map<String, dynamic> json) {
    final screenshotsData = safeList(json, 'screenshots');
    if (screenshotsData == null || screenshotsData.isEmpty) return null;

    final urls = <String>[];
    for (final s in screenshotsData) {
      if (s is! Map) continue;
      final sMap = Map<String, dynamic>.from(s);
      final url = safeString(sMap, 'url') ?? '';
      if (url.isEmpty) continue;
      urls.add(url);
    }

    if (urls.isEmpty) return null;
    return urls.take(6).toList();
  }
}

class SteamService implements MetadataSourceService {
  late Dio _dio;

  SteamService({Dio? dio}) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
      },
    ));
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.steam;

  @override
  String get sourceName => 'Steam';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get(
        'https://store.steampowered.com/api/storesearch/',
        queryParameters: {'term': 'test', 'l': 'schinese', 'cc': 'CN'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchResults = await _searchByName(keyword);
      if (searchResults.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchResults, keyword);
      if (bestMatch['id'] == null) {
        return _emptyResult();
      }

      return await _fetchByAppID(bestMatch['id'] as int);
    } catch (e) {
      fetchLog('[Steam] 查询失败 [$name]: $e');
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.steam));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    // P0.2：速率受限请求
    final response = await executeRateLimited(
        SourceType.steam,
        () => _dio.get(
              'https://store.steampowered.com/api/storesearch/',
              queryParameters: {
                'term': keyword,
                'l': 'schinese',
                'cc': 'CN',
              },
            ));

    if (response.statusCode != 200) {
      return [];
    }

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    final items = safeList(json, 'items');
    if (items == null || items.isEmpty) {
      return [];
    }

    return items.map((item) {
      if (item is Map) return Map<String, dynamic>.from(item);
      return <String, dynamic>{};
    }).toList();
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};

    final specialChars = RegExp(r'[-_:(\)\[\]"]');
    final queryLower = query.toLowerCase().replaceAll(specialChars, ' ');
    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      final itemId = safeInt(item, 'id') ?? 0;

      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.startsWith(queryLower)) score += 40;
      if (itemName.contains(queryLower)) score += 20;

      if (score > bestScore && itemId > 0) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByAppID(int appID) async {
    // P0.2：速率受限请求
    final response = await executeRateLimited(
        SourceType.steam,
        () => _dio.get(
              'https://store.steampowered.com/api/appdetails',
              queryParameters: {
                'appids': appID,
                'l': 'schinese',
                'cc': 'CN',
              },
            ));

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    final appIDStr = appID.toString();
    final appData = safeMap(json, appIDStr);

    if (appData == null) {
      return _emptyResult();
    }

    final success = safeBool(appData, 'success') ?? false;
    if (!success) {
      return _emptyResult();
    }

    final data = safeMap(appData, 'data');
    if (data == null) {
      return _emptyResult();
    }

    return _parseAppDetails(data, appIDStr);
  }

  MetadataResult _parseAppDetails(Map<String, dynamic> data, String appIDStr) {
    final name = safeString(data, 'name')?.trim() ?? '';
    if (name.isEmpty) {
      return _emptyResult();
    }

    double rating = 0.0;
    final metacritic = safeMap(data, 'metacritic');
    if (metacritic != null) {
      final metaScore = safeInt(metacritic, 'score') ?? 0;
      if (metaScore > 0) {
        // P1.3：统一评分归一化（100 分制 → 10 分制）
        rating = normalizeRating(metaScore.toDouble());
      }
    }

    List<TagItem> tags = [];
    final genres = safeList(data, 'genres');
    if (genres != null) {
      int index = 0;
      for (final genre in genres.take(8)) {
        String genreName = '';
        if (genre is String) {
          genreName = genre;
        } else if (genre is Map) {
          genreName =
              safeString(Map<String, dynamic>.from(genre), 'description') ?? '';
        }
        genreName = genreName.trim();
        if (genreName.isNotEmpty) {
          tags.add(TagItem(
            name: genreName,
            source: 'steam',
            weight: genres.length > 0
                ? (1.0 - index++ / genres.length).clamp(0.3, 1.0)
                : 1.0,
          ));
        }
      }
    }

    final developers = safeList(data, 'developers');
    String company = '';
    if (developers != null && developers.isNotEmpty) {
      final devNames = developers
          .where((d) => d is String)
          .map((d) => d.toString().trim())
          .where((s) => s.isNotEmpty)
          .take(3)
          .toList();
      company = devNames.join(', ');
    }

    String releaseDate = '';
    final releaseData = safeMap(data, 'release_date');
    if (releaseData != null) {
      releaseDate = safeString(releaseData, 'date') ?? '';
      if (releaseDate.isNotEmpty) {
        final dateRegex = RegExp(r'(\d{4})\D+(\d{1,2})\D+(\d{1,2})');
        final match = dateRegex.firstMatch(releaseDate);
        if (match != null) {
          final year = int.tryParse(match.group(1) ?? '') ?? 0;
          final month = int.tryParse(match.group(2) ?? '') ?? 0;
          final day = int.tryParse(match.group(3) ?? '') ?? 0;
          if (year > 0 && month > 0 && day > 0) {
            releaseDate =
                '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          }
        }
      }
    }

    return MetadataResult(
      game: Game(
        id: appIDStr,
        name: name,
        coverUrl: safeString(data, 'header_image')?.trim() ?? '',
        company: company,
        summary: safeString(data, 'short_description')?.trim() ?? '',
        rating: rating.clamp(0.0, 10.0),
        releaseDate: releaseDate,
        sourceType: SourceType.steam,
        sourceId: appIDStr,
        screenshotUrls: _extractSteamScreenshots(data),
      ),
      tags: tags,
    );
  }

  /// 从 Steam appdetails 响应中提取截图 URL 列表，使用 path_full，最多6张
  List<String>? _extractSteamScreenshots(Map<String, dynamic> data) {
    final screenshots = safeList(data, 'screenshots');
    if (screenshots == null || screenshots.isEmpty) return null;

    final urls = <String>[];
    for (final ss in screenshots.take(6)) {
      if (ss is! Map) continue;
      final ssMap = Map<String, dynamic>.from(ss);
      final fullPath = safeString(ssMap, 'path_full') ?? '';
      if (fullPath.isNotEmpty) {
        urls.add(fullPath);
      }
    }
    return urls.isEmpty ? null : urls;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.steam));
  }
}

class DLsiteService implements MetadataSourceService {
  late Dio _dio;

  DLsiteService({Dio? dio}) {
    // DLsite HTML 爬虫需要浏览器 UA + Cookie（adultchecked=1 跳过年龄验证）
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'ja,en;q=0.8',
        'Cookie': 'adultchecked=1; locale=ja',
      },
    ));
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.dlsite;

  @override
  String get sourceName => 'DLsite';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get('https://www.dlsite.com/maniax/');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchItems = await _searchByName(keyword);
      if (searchItems.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchItems, keyword);
      if (bestMatch['id'] == null || bestMatch['id'].toString().isEmpty) {
        return _emptyResult();
      }

      return await _fetchByID(bestMatch['id'].toString());
    } catch (e) {
      fetchLog('[DLsite] 查询失败 [$name]: $e');
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.dlsite));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    final encodedKeyword = Uri.encodeComponent(keyword).replaceAll('%20', '+');
    final url =
        'https://www.dlsite.com/maniax/fsr/=/language/jp/keyword/$encodedKeyword/';

    // P0.2：速率受限请求
    final response =
        await executeRateLimited(SourceType.dlsite, () => _dio.get(url));

    if (response.statusCode != 200) {
      return [];
    }

    final document = html_parser.parse(response.data);
    final items = <Map<String, dynamic>>[];

    document
        .querySelectorAll('.search_result_img_box_inner')
        .forEach((element) {
      String? id = element.attributes['data-list_item_product_id'];
      if (id == null || id.isEmpty) {
        final link = element.querySelector('a.work_thumb_inner');
        final href = link?.attributes['href'] ?? '';
        final idMatch =
            RegExp(r'(RJ|RE|VJ)\d{4,}', caseSensitive: false).firstMatch(href);
        if (idMatch != null) {
          id = idMatch.group(0)?.toUpperCase();
        }
      }

      if (id == null || id.isEmpty) return;

      final idRegExp = RegExp(r'^[RV][EJ]\d+$', caseSensitive: false);
      if (!idRegExp.hasMatch(id)) return;

      final nameLink = element.querySelector('.work_name a');
      String itemName = nameLink?.attributes['title']?.trim() ?? '';
      if (itemName.isEmpty) {
        itemName = nameLink?.text.trim() ?? '';
      }
      if (itemName.isEmpty) return;

      items.add({
        'id': id.toUpperCase(),
        'name': itemName,
      });
    });

    return items;
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};
    final queryLower = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.contains(queryLower)) score += 20;
      if (score > bestScore) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByID(String id) async {
    final prefix = id.toUpperCase().startsWith('VJ') ? 'pro' : 'maniax';
    final url =
        'https://www.dlsite.com/$prefix/work/=/product_id/${id.toUpperCase()}.html';

    // P0.2：速率受限请求
    final response =
        await executeRateLimited(SourceType.dlsite, () => _dio.get(url));

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final document = html_parser.parse(response.data);

    final titleEl = document.querySelector('#work_name');
    String title = titleEl?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (title.isEmpty) {
      return _emptyResult();
    }

    String coverUrl = '';
    document.querySelectorAll('img, source').forEach((element) {
      if (coverUrl.isNotEmpty) return;

      final candidates = [
        element.attributes['data-src'],
        _extractFirstSrcSet(element.attributes['srcset']),
        element.attributes['src'],
      ];

      for (final candidate in candidates) {
        if (candidate == null || candidate.isEmpty) continue;
        final normalized = _normalizeURL(candidate);
        if (normalized.isEmpty) continue;

        if (normalized.contains('_img_main')) {
          coverUrl = normalized;
          return;
        }
        if (coverUrl.isEmpty && normalized.contains('_img_smp')) {
          coverUrl = normalized;
        }
      }
    });

    String company = '';
    final makerEl = document.querySelector('.maker_name a');
    if (makerEl != null) {
      company = makerEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String summary = '';
    final descEl = document.querySelector('[itemprop="description"]');
    if (descEl != null) {
      summary = descEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String releaseDate = '';
    document.querySelectorAll('th').forEach((th) {
      if (releaseDate.isNotEmpty) return;
      final label = th.text.replaceAll(RegExp(r'\s+'), ' ');
      if (label.contains('販売日') ||
          label.contains('発売日') ||
          label.toLowerCase().contains('release')) {
        final td = th.nextElementSibling;
        if (td != null) {
          releaseDate = _normalizeJapaneseDate(td.text);
        }
      }
    });

    List<TagItem> tags = [];
    document.querySelectorAll('.main_genre a').forEach((a) {
      final tagName = a.text.trim();
      if (tagName.isNotEmpty) {
        // Phase 2.3: 统一日文标签为中文
        final translatedName =
            TagTranslator.translate(tagName, SourceType.dlsite);
        tags.add(TagItem(name: translatedName, source: 'dlsite', weight: 1.0));
      }
    });

    return MetadataResult(
      game: Game(
        id: id,
        name: title,
        coverUrl: coverUrl,
        company: company,
        summary: summary,
        releaseDate: releaseDate,
        sourceType: SourceType.dlsite,
        sourceId: id,
        screenshotUrls: _extractDlsiteScreenshots(document),
      ),
      tags: tags,
    );
  }

  /// 从 DLsite 详情页提取游戏截图 URL 列表，最多6张
  List<String>? _extractDlsiteScreenshots(dynamic document) {
    final urls = <String>[];
    final seen = <String>{};

    // 方式1: 从 .work_slider 区域提取（新版页面结构）
    document.querySelectorAll('.work_slider .slider_item img').forEach((img) {
      final src = img.attributes['data-src'] ?? img.attributes['src'] ?? '';
      if (src.isEmpty) return;
      final normalized = _normalizeURL(src);
      if (normalized.isEmpty || seen.contains(normalized)) return;
      if (normalized.contains('_img_main') || normalized.contains('_img_smp'))
        return;
      seen.add(normalized);
      urls.add(normalized);
    });

    // 方式2: 从 .work_sample 链接区域提取（经典页面结构）
    if (urls.isEmpty) {
      document.querySelectorAll('.work_sample_images a').forEach((link) {
        final href = link.attributes['href'] ?? '';
        if (href.isEmpty) return;
        final normalized = _normalizeURL(href);
        if (normalized.isEmpty || seen.contains(normalized)) return;
        if (normalized.contains('_img_main') || normalized.contains('_img_smp'))
          return;
        seen.add(normalized);
        urls.add(normalized);
      });
    }

    // 方式3: 从所有包含 _sample 或 _smp 的图片链接提取（兜底）
    if (urls.isEmpty) {
      document.querySelectorAll('a').forEach((link) {
        final href = link.attributes['href'] ?? '';
        if (href.isEmpty) return;
        final normalized = _normalizeURL(href);
        if (normalized.isEmpty || seen.contains(normalized)) return;
        if (!normalized.contains('_sample') && !normalized.contains('_smp'))
          return;
        if (normalized.contains('_img_main')) return;
        seen.add(normalized);
        urls.add(normalized);
      });
    }

    if (urls.isEmpty) return null;
    return urls.take(6).toList();
  }

  String? _extractFirstSrcSet(String? srcset) {
    if (srcset == null || srcset.isEmpty) return null;
    final first = srcset.split(',').first.trim();
    if (first.isEmpty) return null;
    return first.split(RegExp(r'\s+')).first;
  }

  String _normalizeURL(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('http://') || value.startsWith('https://'))
      return value;
    if (value.startsWith('/')) return 'https://www.dlsite.com$value';
    return value;
  }

  String _normalizeJapaneseDate(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), '').trim();
    if (text.isEmpty) return '';

    var replaced = text
        .replaceAll('年', '-')
        .replaceAll('月', '-')
        .replaceAll('日', '')
        .replaceAll('.', '-')
        .replaceAll('/', '-');

    final parts = replaced.split('-');
    if (parts.length >= 3) {
      final year = int.tryParse(parts[0].trim()) ?? 0;
      final month = int.tryParse(parts[1].trim()) ?? 0;
      final day = int.tryParse(parts[2].trim()) ?? 0;
      if (year > 1900 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }

    return text;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.dlsite));
  }
}

class ErogameScapeService implements MetadataSourceService {
  late Dio _dio;
  static const String _baseURL =
      'https://erogamescape.org/~ap2/ero/toukei_kaiseki';

  ErogameScapeService({Dio? dio}) {
    // ErogameScape HTML 爬虫需要浏览器 UA + Referer
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'ja,en;q=0.8',
        'Referer': _baseURL,
      },
    ));
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.erogamescape;

  @override
  String get sourceName => 'ErogameScape';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get(_baseURL);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchItems = await _searchByName(keyword);
      if (searchItems.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchItems, keyword);
      if (bestMatch['id'] == null || bestMatch['id'].toString().isEmpty) {
        return _emptyResult();
      }

      return await _fetchByID(bestMatch['id'].toString());
    } catch (e) {
      fetchLog('[ErogameScape] 查询失败 [$name]: $e');
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.erogamescape));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    // P0.2：速率受限请求
    final response = await executeRateLimited(
        SourceType.erogamescape,
        () => _dio.get(
              '$_baseURL/kensaku.php',
              queryParameters: {
                'category': 'game',
                'word_category': 'name',
                'mode': 'normal',
                'word': keyword,
              },
            ));

    if (response.statusCode != 200) {
      return [];
    }

    final document = html_parser.parse(response.data);
    final items = <Map<String, dynamic>>[];

    int nameCol = 0;
    document.querySelectorAll('#result tr').asMap().forEach((index, row) {
      if (index == 0) {
        row.querySelectorAll('th').asMap().forEach((colIdx, cell) {
          final text = cell.text.trim();
          if (text == 'ゲーム名') nameCol = colIdx;
        });
        return;
      }

      final cells = row.querySelectorAll('td');
      if (cells.length <= nameCol) return;

      final nameCell = cells[nameCol];
      final link = nameCell.querySelector('a');
      if (link == null) return;

      final href = link.attributes['href'] ?? '';
      final idMatch = RegExp(r'[?&#/]game=(\d+)').firstMatch(href);
      if (idMatch == null) return;

      final id = idMatch.group(1)?.replaceFirst(RegExp(r'^0+'), '');
      final gameName =
          '${link.text.trim()} ${nameCell.querySelector('span')?.text.trim() ?? ''}'
              .trim();

      if (id != null && id.isNotEmpty && gameName.isNotEmpty) {
        items.add({'id': id, 'name': gameName});
      }
    });

    return items;
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};
    final queryLower = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.contains(queryLower)) score += 20;
      if (score > bestScore) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByID(String id) async {
    // P0.2：速率受限请求
    final response = await executeRateLimited(
        SourceType.erogamescape,
        () => _dio.get(
              '$_baseURL/game.php',
              queryParameters: {'game': id},
            ));

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final document = html_parser.parse(response.data);

    String title = '';
    final titleEl = document.querySelector('#soft-title span.bold');
    if (titleEl != null) {
      title = titleEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (title.isEmpty) {
      final fallbackTitle = document.querySelector('#soft-title .bold');
      if (fallbackTitle != null) {
        title = fallbackTitle.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }
    if (title.isEmpty) {
      return _emptyResult();
    }

    String coverUrl = '';
    final imgEl = document.querySelector('#main_image img');
    if (imgEl != null) {
      final src = imgEl.attributes['src'] ?? '';
      if (src.isNotEmpty) {
        coverUrl = src.startsWith('http')
            ? src
            : '$_baseURL${src.startsWith('/') ? '' : '/'}$src';
      }
    }

    String company = '';
    final brandEl = document.querySelector('#brand td');
    if (brandEl != null) {
      company = brandEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String releaseDate = '';
    final dateEl = document.querySelector('#sellday td');
    if (dateEl != null) {
      releaseDate = _normalizeJapaneseDate(dateEl.text);
    }

    double rating = 0.0;
    for (final selector in ['#median td', '#average td']) {
      final el = document.querySelector(selector);
      if (el != null) {
        final ratingText = el.text.trim();
        final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(ratingText);
        if (match != null) {
          // P1.3：统一评分归一化
          rating =
              normalizeRating(double.tryParse(match.group(1) ?? '') ?? 0.0);
          break;
        }
      }
    }

    List<TagItem> tags = [];

    final erogameCell = document.querySelector('#erogame td');
    if (erogameCell != null) {
      final erogameText = erogameCell.text;
      for (final token in ['18禁', '非18禁', '抜きゲー', '非抜きゲー', '和姦もの', '陵辱もの']) {
        if (erogameText.contains(token)) {
          // Phase 2.3: 统一日文标签为中文
          final translatedToken =
              TagTranslator.translate(token, SourceType.erogamescape);
          tags.add(TagItem(
              name: translatedToken, source: 'erogamescape', weight: 1.0));
        }
      }
    }

    final allowedHeaders = {
      '公式ジャンル': true,
      'ジャンル': true,
      'タグ': true,
      'シチュエーション': true,
      'エロシーン': true,
    };

    document.querySelectorAll('#att_pov_table tr').forEach((row) {
      final header = row.querySelector('th');
      if (header == null) return;
      final labelText = header.text.trim();
      if (!allowedHeaders.containsKey(labelText)) return;

      row.querySelectorAll('td a').forEach((a) {
        final tagName = a.text.trim();
        if (tagName.isNotEmpty) {
          // Phase 2.3: 统一日文标签为中文
          final translatedName =
              TagTranslator.translate(tagName, SourceType.erogamescape);
          tags.add(TagItem(
              name: translatedName, source: 'erogamescape', weight: 1.0));
        }
      });
    });

    // 提取简介（ErogameScape 之前完全缺失，Phase 2.2 修复）
    // ErogameScape 的简介通常在 #comment 或 .review 元素中
    String summary = '';
    for (final selector in ['#comment', '.review', '#intro', '#content_text']) {
      final summaryEl = document.querySelector(selector);
      if (summaryEl != null) {
        summary = summaryEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (summary.isNotEmpty) break;
      }
    }

    return MetadataResult(
      game: Game(
        id: id,
        name: title,
        coverUrl: coverUrl,
        company: company,
        summary: summary,
        releaseDate: releaseDate,
        rating: rating.clamp(0.0, 10.0),
        sourceType: SourceType.erogamescape,
        sourceId: id,
        screenshotUrls: _extractErogameScreenshots(document),
      ),
      tags: tags,
    );
  }

  /// 从 ErogameScape 详情页提取游戏截图 URL 列表，最多6张
  List<String>? _extractErogameScreenshots(dynamic document) {
    final urls = <String>[];
    final seen = <String>{};

    document.querySelectorAll('#game_images a').forEach((link) {
      final href = link.attributes['href'] ?? '';
      if (href.isEmpty) return;
      final normalized = _normalizeErogameUrl(href);
      if (normalized.isEmpty || seen.contains(normalized)) return;
      if (!normalized.contains('.jpg') &&
          !normalized.contains('.jpeg') &&
          !normalized.contains('.png') &&
          !normalized.contains('.gif')) return;
      seen.add(normalized);
      urls.add(normalized);
    });

    if (urls.isEmpty) {
      document.querySelectorAll('table a img').forEach((img) {
        final parentLink = img.parent;
        if (parentLink == null) return;
        final href = parentLink.attributes['href'] ?? '';
        if (href.isEmpty) return;
        final normalized = _normalizeErogameUrl(href);
        if (normalized.isEmpty || seen.contains(normalized)) return;
        if (!normalized.contains('.jpg') &&
            !normalized.contains('.jpeg') &&
            !normalized.contains('.png')) return;
        if (normalized.contains('main_image')) return;
        seen.add(normalized);
        urls.add(normalized);
      });
    }

    if (urls.isEmpty) return null;
    return urls.take(6).toList();
  }

  String _normalizeErogameUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://'))
      return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return '$_baseURL$value';
    return '$_baseURL/$value';
  }

  String _normalizeJapaneseDate(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), '').trim();
    if (text.isEmpty) return '';

    var replaced = text
        .replaceAll('年', '-')
        .replaceAll('月', '-')
        .replaceAll('日', '')
        .replaceAll('.', '-')
        .replaceAll('/', '-');

    final parts = replaced.split('-');
    if (parts.length >= 3) {
      final year = int.tryParse(parts[0].trim()) ?? 0;
      final month = int.tryParse(parts[1].trim()) ?? 0;
      final day = int.tryParse(parts[2].trim()) ?? 0;
      if (year > 1900 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }

    return text;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.erogamescape));
  }
}

class YmgalService implements MetadataSourceService {
  late Dio _dio;
  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  YmgalService({Dio? dio}) {
    // Ymgal API 需要 version 和 Accept 头，否则返回 HTML 而非 JSON
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
        'version': '1',
        'Accept': 'application/json;charset=utf-8',
      },
    ));
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.ymgal;

  @override
  String get sourceName => '月幕GAL';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final token = await _getToken();
      return token != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final token = await _getToken();
      if (token == null) {
        return _emptyResult();
      }

      // P0.2：速率受限请求
      // 对齐 LunaBox：月幕GAL 搜索请求必须携带 `version: 1` 头，
      // 否则 API 返回 {"success":false,"code":404,"msg":"Not found or incorrect version."}
      final response = await executeRateLimited(
          SourceType.ymgal,
          () => _dio.get(
                'https://www.ymgal.games/open/archive/search-game',
                queryParameters: {
                  'mode': 'accurate',
                  'keyword': keyword,
                  'similarity': '70',
                },
                options: Options(headers: {
                  'Authorization': 'Bearer $token',
                  'version': '1',
                  'Accept': 'application/json;charset=utf-8',
                }),
              ));

      if (response.statusCode != 200) {
        return _emptyResult();
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final success = safeBool(json, 'success');
      if (success != true) {
        return _emptyResult();
      }

      final data = safeMap(json, 'data');
      if (data == null) {
        return _emptyResult();
      }

      final game = safeMap(data, 'game');
      if (game == null) {
        return _emptyResult();
      }

      return _parseYmgalResponse(game);
    } catch (e) {
      fetchLog('[Ymgal] 查询失败 [$name]: $e');
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.ymgal));
    }
  }

  Future<String?> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken;
    }

    try {
      // P0.2：速率受限请求（Token 端点同样受限）
      final response = await executeRateLimited(
          SourceType.ymgal,
          () => _dio.get(
                'https://www.ymgal.games/oauth/token',
                queryParameters: {
                  'grant_type': 'client_credentials',
                  'client_id': 'ymgal',
                  'client_secret': 'luna0327',
                  'scope': 'public',
                },
              ));

      if (response.statusCode != 200) {
        return null;
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final accessToken = safeString(json, 'access_token');
      final expiresIn = safeInt(json, 'expires_in') ?? 3600;

      if (accessToken != null && accessToken.isNotEmpty) {
        _cachedToken = accessToken;
        _tokenExpiresAt = DateTime.now()
            .add(Duration(seconds: expiresIn))
            .subtract(const Duration(seconds: 60));
        return accessToken;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  MetadataResult _parseYmgalResponse(Map<String, dynamic> json) {
    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null) {
      for (final tag in tagsData.take(10)) {
        String? tagName;
        if (tag is String) {
          tagName = tag;
        } else if (tag is Map) {
          tagName = safeString(Map<String, dynamic>.from(tag), 'name');
        }
        if (tagName != null && tagName.isNotEmpty) {
          tags.add(TagItem(name: tagName, source: 'ymgal', weight: 1.0));
        }
      }
    }

    String name = safeString(json, 'chineseName') ?? '';
    if (name.isEmpty) name = safeString(json, 'name') ?? '';

    double rating = 0.0;
    final scoreRaw = json['score'];
    if (scoreRaw is num) {
      rating = scoreRaw.toDouble();
    } else if (scoreRaw is String) {
      rating = double.tryParse(scoreRaw) ?? 0.0;
    }
    // P1.3：统一评分归一化
    rating = normalizeRating(rating);

    return MetadataResult(
      game: Game(
        id: (safeInt(json, 'gid') ?? safeString(json, 'id')).toString(),
        name: name,
        coverUrl: safeString(json, 'mainImg') ??
            safeString(json, 'cover_url') ??
            safeString(json, 'image') ??
            '',
        company: safeString(json, 'brand_name') ??
            safeString(json, 'company') ??
            safeString(json, 'developer_name'),
        summary: safeString(json, 'introduction') ??
            safeString(json, 'summary') ??
            '',
        rating: rating,
        releaseDate: safeString(json, 'release_date') ??
            safeString(json, 'publish_date') ??
            '',
        sourceType: SourceType.ymgal,
        sourceId: (safeInt(json, 'gid') ?? safeString(json, 'id')).toString(),
        screenshotUrls: _extractYmgalScreenshots(json),
      ),
      tags: tags,
    );
  }

  /// 从月幕GAL API 响应中提取截图 URL 列表，兼容多种字段名，最多6张
  List<String>? _extractYmgalScreenshots(Map<String, dynamic> json) {
    final screenshotsData = safeList(json, 'screenshots') ??
        safeList(json, 'imgs') ??
        safeList(json, 'images') ??
        safeList(json, 'gallery');

    if (screenshotsData == null || screenshotsData.isEmpty) return null;

    final urls = <String>[];
    for (final item in screenshotsData.take(6)) {
      if (item is String && item.isNotEmpty) {
        urls.add(item);
      } else if (item is Map) {
        final itemMap = Map<String, dynamic>.from(item);
        final url = safeString(itemMap, 'url') ??
            safeString(itemMap, 'path') ??
            safeString(itemMap, 'src') ??
            safeString(itemMap, 'img') ??
            '';
        if (url.isNotEmpty) urls.add(url);
      }
    }
    return urls.isEmpty ? null : urls;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.ymgal));
  }
}

class MetadataServiceFactory {
  /// 创建数据源服务实例
  ///
  /// [dio] 传入时，各服务会从其继承代理配置（httpClientAdapter）。
  /// 不传时各服务使用自建的无代理 Dio（仅用于独立测试场景）。
  static MetadataSourceService getService(SourceType sourceType, {Dio? dio}) {
    if (sourceType == SourceType.bangumi) {
      return BangumiMirrorService(dio: dio);
    } else if (sourceType == SourceType.vndb) {
      return VNDBService(dio: dio);
    } else if (sourceType == SourceType.steam) {
      return SteamService(dio: dio);
    } else if (sourceType == SourceType.dlsite) {
      return DLsiteService(dio: dio);
    } else if (sourceType == SourceType.erogamescape) {
      return ErogameScapeService(dio: dio);
    } else if (sourceType == SourceType.ymgal) {
      return YmgalService(dio: dio);
    } else if (sourceType == SourceType.touchgal) {
      return TouchGalService(dio: dio);
    } else if (sourceType == SourceType.hikarinagi) {
      return HikarinagiService(dio: dio);
    } else if (sourceType == SourceType.kun) {
      return KunService(dio: dio);
    } else {
      throw ArgumentError('Unsupported source type: $sourceType');
    }
  }
}
