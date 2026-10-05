import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// CT 探索库数据源服务（Chrono Tide 自建元数据平台）
///
/// 数据来源：自有 PocketBase 的 `games` 集合（http://117.72.115.30:8090，
/// 与探索页/客户端下载同源），由项目管理员与社区分享者共同整理的
/// 中文元数据，目标是社区优秀的中文元数据平台。
///
/// **接入方式**：与外部平台同构（实现 [MetadataSourceService]），
/// 以 Dio 直调 PB REST API（SDK 包不依赖 pocketbase 客户端库）：
/// - 搜索：`GET {base}/api/collections/games/records?filter=(title~'kw')`
/// - 文件：`{base}/api/files/games/{recordId}/{filename}`
///
/// **网络策略**：PB 部署在国内（京东云），强制直连（[applyProxyConfig]
/// 传 null → 显式 DIRECT），避免用户代理把国内流量绕到海外节点导致
/// 失败，与探索页 PocketBase 客户端（不走代理）行为一致。
///
/// **权限**：games 集合对匿名开放只读（探索页匿名浏览同源），无需鉴权。
///
/// **字段映射**（PB 字段 → 元数据字段）：
/// - `title` → 主标题（中文，社区裁定）
/// - `originalTitle` → 副标题（日文原版标题，上游经 CJK 检查填入副标题）
/// - `description` → 简介；`developer`（兼容旧字段 `Developer`）→ 会社
/// - `cover` / `bannerUrl`（file）→ 竖版封面 / 横幅封面
/// - `screenshots`（多 file）→ 截图列表；`tags`（list 或逗号串）→ 标签
///   （社区整理，已是中文，不走 TagTranslator）
/// - `rating`（0-10）/`voteCount`/`releaseDate` → 评分 / 投票数 / 发售日
class CTService implements MetadataSourceService {
  final Dio _dio;

  /// PB 服务地址（与主程序 lib/core/pb_config.dart 的 _baseUrl 保持一致；
  /// SDK 包不依赖主程序代码，故此处独立常量）
  static const String apiBase = 'http://117.72.115.30:8090';

  CTService({Dio? dio})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
            'Accept': 'application/json',
          },
        )) {
    // 自建国内服务器：强制直连（不走用户代理，理由见类注释）
    applyProxyConfig(null, _dio);
  }

  @override
  SourceType get sourceType => SourceType.ct;

  @override
  String get sourceName => 'CT';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await executeRateLimited(
        SourceType.ct,
        () => _dio.get('$apiBase/api/collections/games/records',
            queryParameters: {'perPage': '1'}),
      );
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
      // 多字段 OR：主标题 / 日文原名 / 英文名 / 繁中别名（2026-10-05）
      // 实测：仅 title 过滤时搜日文原名「美少女万華鏡」0 命中，
      // 多字段后 7 命中——别名检索是 CT 源可用的前提。
      var items = await _searchRecords(keyword);

      // 0 命中时全角→半角折叠重试（PB 的 ~ 是 SQLite LIKE，不做全半角
      // 归一；用户用全角输入「ＢＩＳＨＯＪＯ　ＭＡＮＧＥＫＹＯＵ」时
      // 原文 LIKE 不命中，折叠字形后即可命中半角标题）
      if (items != null && items.isEmpty) {
        final folded = _foldFullWidth(keyword);
        if (folded != keyword) {
          items = await _searchRecords(folded);
        }
      }

      if (items == null || items.isEmpty) return _emptyResult();

      final bestMatch = _pickBestMatch(items, keyword);
      if (bestMatch == null) return _emptyResult();
      return _parseRecord(bestMatch);
    } catch (e) {
      fetchLog('[CT] 查询失败 [$name]: $e');
      return _emptyResult();
    }
  }

  /// 按关键词执行一次多字段搜索，返回 items 列表。
  /// 返回 null = 请求失败/无有效输入；空 List = 正常无命中。
  Future<List<dynamic>?> _searchRecords(String keyword) async {
    final filter = _nameSearchFilter(keyword);
    if (filter == null) return null;

    final response = await executeRateLimited(
      SourceType.ct,
      () => _dio.get('$apiBase/api/collections/games/records',
          queryParameters: {
            'page': '1',
            // 多字段命中面大于单 title，扩大候选窗口避免漏掉最佳匹配
            'perPage': '60',
            'sort': '-created',
            'filter': filter,
          }),
    );
    if (response.statusCode != 200) return null;

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    return safeList(
        json is Map ? Map<String, dynamic>.from(json) : {}, 'items');
  }

  /// 全角 ASCII（0xFF01-0xFF5E）与全角空格 → 半角（保留分隔符，
  /// 供服务端 LIKE 二次查询；与 [normalizeForSearch] 共用字形折叠）
  static String _foldFullWidth(String input) {
    final buf = StringBuffer();
    for (final ch in input.runes) {
      if (ch == 0x3000) {
        buf.write(' ');
      } else if (ch >= 0xFF01 && ch <= 0xFF5E) {
        buf.writeCharCode(ch - 0xFEE0);
      } else {
        buf.writeCharCode(ch);
      }
    }
    return buf.toString();
  }

  /// PB filter 字符串字面量转义（与主程序 lib/utils/pb_filter.dart 同规则：
  /// 控制字符折叠 → 截断 64 → 先反斜杠后单引号，顺序不可颠倒）。
  /// SDK 包不依赖主程序代码，故内联实现。返回 null = 无有效输入，不加过滤。
  String? _escapePbLiteral(String keyword) {
    if (keyword.isEmpty) return null;
    var safe = keyword.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    if (safe.isEmpty) return null;
    if (safe.length > 64) {
      safe = safe.substring(0, 64);
      // 避免截断代理对（emoji 等）产生半个字符
      final lastUnit = safe.codeUnitAt(safe.length - 1);
      if (safe.length > 1 && lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
        safe = safe.substring(0, safe.length - 1);
      }
      safe = safe.trimRight();
    }
    if (safe.isEmpty) return null;
    // ★ 顺序不可颠倒：先反斜杠，再单引号
    return safe.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  }

  /// 名称搜索 filter：主标题 / 日文原名 / 英文名 / 繁中别名 四字段 OR
  ///
  /// （2026-10-05 实测：仅 title 过滤时搜日文原名「美少女万華鏡」0 命中、
  /// 英文名「Mangekyou」0 命中；多字段 OR 均 7 命中。别名检索是 CT 源
  /// 在一键抓取里可用的前提——用户输入的往往是别名或部分名称。）
  String? _nameSearchFilter(String keyword) {
    final safe = _escapePbLiteral(keyword);
    if (safe == null) return null;
    return "(title ~ '$safe' || originalTitle ~ '$safe' || "
        "englishTitle ~ '$safe' || traditionalChineseTitle ~ '$safe')";
  }

  /// 搜索文本归一化（public static，供 CT 探索库弹窗本地搜索共用）：
  /// 小写化 → 全角 ASCII/全角空格转半角 → 去除空白与中英文常见标点。
  ///
  /// 目的：用户输入「美少女万華鏡１」「Bishoujo Mangekyou - Norowareshi…」
  /// 等大小写/全半角/标点变体时仍能命中同一部作品（对齐 VNDB/Nextcloud
  /// 的宽松索引体验）。
  static String normalizeForSearch(String input) {
    var s = _foldFullWidth(input).toLowerCase();
    // 去空白与常见标点（raw 三引号内含单个引号合法；注意不能出现三连引号）
    return s.replaceAll(_searchNoise, '');
  }

  static final RegExp _searchNoise = RegExp(
      r"""[\s\-_~·・:：;；,，.。!！?？()（）\[\]【】「」『』"'“”‘’，、]""");

  /// 仅供单元测试离线验证 filter 生成（不发起网络请求）
  @visibleForTesting
  String? nameSearchFilterForTesting(String keyword) =>
      _nameSearchFilter(keyword);

  /// 从搜索结果中挑选与查询词最匹配的项
  ///
  /// 候选名称集合：title + originalTitle + englishTitle +
  /// traditionalChineseTitle（全部别名参与匹配），打分规则与其他源一致
  /// （精确 100 / 前缀 40 / 包含 20），全零时回退第一条。
  /// 匹配统一走 [normalizeForSearch]（全半角/标点/大小写归一）。
  Map<String, dynamic>? _pickBestMatch(List<dynamic> results, String query) {
    final candidates = <Map<String, dynamic>>[];
    for (final r in results) {
      if (r is Map) candidates.add(Map<String, dynamic>.from(r));
    }
    if (candidates.isEmpty) return null;

    final queryNorm = normalizeForSearch(query);

    Map<String, dynamic> bestResult = candidates.first;
    int bestScore = -1;

    for (final item in candidates) {
      final names = <String>{
        for (final key in ['title', 'originalTitle', 'englishTitle', 'traditionalChineseTitle'])
          if ((safeString(item, key) ?? '').isNotEmpty) safeString(item, key)!,
      };

      int itemBest = 0;
      for (final n in names) {
        final nameNorm = normalizeForSearch(n);
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

  /// 仅供单元测试离线验证（对齐 NextMoeService.parseDetailForTesting）
  @visibleForTesting
  MetadataResult parseRecordForTesting(Map<String, dynamic> json) =>
      _parseRecord(json);

  MetadataResult _parseRecord(Map<String, dynamic> json) {
    final id = safeString(json, 'id') ?? '';
    final name = safeString(json, 'title') ?? '';
    if (id.isEmpty || name.isEmpty) return _emptyResult();

    // 副标题：日文原版标题（上游 selectScrapeResult 经 CJK 检查后填入）
    final originalTitle = _nonEmpty(safeString(json, 'originalTitle'));

    final coverUrl = _fileUrl(id, safeString(json, 'cover')) ??
        _fileUrl(id, safeString(json, 'coverUrl')) ??
        '';
    final bannerUrl = _fileUrl(id, safeString(json, 'bannerUrl')) ?? '';

    // 会社：兼容 PB 字段命名变更（developer → Developer，与 GameModel 同策略）
    final developer =
        _nonEmpty(safeString(json, 'developer') ?? safeString(json, 'Developer'));

    // 评分：云端沉淀值约定 0-10 分制（normalizeRating 对 <=10 原样放行，
    // 仅对异常 100 分制兜底归一）
    final rating = normalizeRating(safeDouble(json, 'rating') ?? 0.0);

    return MetadataResult(
      game: Game(
        id: id,
        name: name,
        originalTitle: originalTitle,
        coverUrl: coverUrl,
        bannerUrl: bannerUrl,
        company: developer,
        summary: safeString(json, 'description') ?? '',
        rating: rating,
        voteCount: safeInt(json, 'voteCount'),
        releaseDate: safeString(json, 'releaseDate') ?? '',
        sourceType: SourceType.ct,
        sourceId: id,
        screenshotUrls: _extractScreenshots(id, json),
      ),
      tags: [
        // 社区整理的中文标签，直通不走 TagTranslator
        for (final tagName in _parseTagNames(json))
          TagItem(name: tagName, source: 'ct', weight: 1.0),
      ],
    );
  }

  /// tags 字段解析：PB select 多选返回 List；旧数据可能是逗号分隔字符串
  static List<String> _parseTagNames(Map<String, dynamic> json) {
    final raw = json['tags'];
    if (raw is List) {
      return raw.map((t) => t.toString().trim()).where((t) => t.isNotEmpty).toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// PB 文件字段 → 完整 URL（file 字段存文件名，裸值为空串 = 无文件）
  static String? _fileUrl(String recordId, String? filename) {
    if (filename == null || filename.isEmpty) return null;
    return '$apiBase/api/files/games/$recordId/$filename';
  }

  /// screenshots 多文件字段 → URL 列表（保留云端整理的全部截图，不设上限）
  static List<String>? _extractScreenshots(String recordId, Map<String, dynamic> json) {
    final raw = json['screenshots'];
    if (raw is! List || raw.isEmpty) return null;
    final urls = <String>[];
    for (final item in raw) {
      final url = _fileUrl(recordId, item?.toString());
      if (url != null) urls.add(url);
    }
    return urls.isEmpty ? null : urls;
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  MetadataResult _emptyResult() {
    return MetadataResult(game: Game(id: '', name: '', sourceType: SourceType.ct));
  }
}
