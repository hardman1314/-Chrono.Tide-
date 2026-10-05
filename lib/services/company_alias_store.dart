import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 会社归一化别名词典 —— 「标准主名 + 别名列表 → 唯一 company_id」。
///
/// - 词典种子数据：`docs/DEV/datasets/company_aliases.json`
///   （Phase 2 起随包分发为 `assets/data/company_aliases.json`，只读）。
/// - 设计与分阶段计划：`docs/DEV/features/company_alias_normalization.md`。
///
/// 解决的问题：同一会社在不同数据源（VNDB / Bangumi / KUNGAL / NEXTMOE /
/// TouchGal / 手动录入）下写法不一（日文原名 / 英文官方名 / 中文译名 / 圈内
/// 昵称），若以原始字符串为分组键，筛选与智能归纳会分裂成多个组。
///
/// 归一化规则（保守三层，宁可漏匹配进 pending，不可错合并）：
/// ① 去首尾空白，连续空白（含全角空格 U+3000）折叠为单个半角空格；
/// ② 全角 ASCII（U+FF01–U+FF5E）转半角；
/// ③ ASCII 大写折叠为小写（仅匹配层，展示层保留原文）。
/// 明确不做（防误合并）：剥「社」后缀、剥「株式会社」前缀、去标点模糊匹配。
class CompanyAliasStore {
  CompanyAliasStore._(
    this.formatVersion,
    this.companies,
    this._aliasIndex,
    this._vndbIndex,
    this.ambiguousAliases,
  );

  /// 当前支持的词典格式版本。词典未来字段增删改必须升版本；
  /// 解析端遇到更高版本时拒绝加载（启动期暴露，而不是筛选时静默错乱）。
  static const int supportedFormatVersion = 1;

  final int formatVersion;
  final List<CompanyRecord> companies;

  /// 归一化名 → 记录。standard_name / jp_name / cn_name / aliases 全部入索引。
  final Map<String, CompanyRecord> _aliasIndex;

  /// VNDB producer id（如 `p98`，归一化为小写）→ 记录。
  /// 抓取 VNDB 时优先按 id 对齐，文本匹配只做兜底 —— id 是比名字更强的锚点。
  final Map<String, CompanyRecord> _vndbIndex;

  /// 构建期发现的不同会社共用同一别名（重名陷阱预警，正常词典应为空）。
  final List<String> ambiguousAliases;

  int get companyCount => companies.length;

  // ---------------------------------------------------------------------------
  // 内置词典加载（单例）
  // ---------------------------------------------------------------------------

  /// 内置词典的资产路径（pubspec assets 已注册）。
  static const String defaultAssetPath = 'assets/data/company_aliases.json';

  static CompanyAliasStore? _instance;
  static Future<CompanyAliasStore?>? _loadFuture;

  /// 当前已加载的词典实例；未加载 / 加载失败时为 null。
  ///
  /// 调用方必须按「词典缺席」降级（company_id 全部为 null，行为与
  /// Phase 1 之前完全一致），不得因词典缺失而阻塞任何主流程。
  static CompanyAliasStore? get instanceOrNull => _instance;

  /// 幂等加载内置词典（启动期调用一次即可，之后复用缓存）。
  ///
  /// 失败不抛异常：返回 null 并允许后续再次调用重试（避免一次资产
  /// 读取抖动永久锁死降级态）。
  static Future<CompanyAliasStore?> ensureLoaded() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final future = _loadFromAssets();
    _loadFuture = future;
    return future;
  }

  static Future<CompanyAliasStore?> _loadFromAssets() async {
    try {
      final raw = await rootBundle.loadString(defaultAssetPath);
      final store = CompanyAliasStore.parse(raw);
      _instance = store;
      debugPrint(
          '[COMPANY-ALIAS] ✅ 词典已加载: ${store.companyCount} 家会社'
          '（冲突预警 ${store.ambiguousAliases.length} 条）');
      return store;
    } catch (e) {
      debugPrint('[COMPANY-ALIAS] ⚠️ 词典加载失败（降级为无 company_id 模式）: $e');
      _loadFuture = null; // 允许下次重试
      return null;
    }
  }

  /// 测试 / 工具专用：清空单例缓存。
  @visibleForTesting
  static void resetInstanceForTest() {
    _instance = null;
    _loadFuture = null;
  }

  /// 测试专用：直接注入词典实例（单元测试无法走 rootBundle 资产链路）。
  @visibleForTesting
  static void debugSetInstanceForTest(CompanyAliasStore? store) {
    _instance = store;
    _loadFuture = Future<CompanyAliasStore?>.value(store);
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  /// 从 JSON 字符串解析并构建倒排索引。
  ///
  /// 词典自身不合法（版本超纲 / 字段缺失 / company_id 重复）时抛
  /// [FormatException]，让问题在启动期暴露。
  factory CompanyAliasStore.parse(String jsonString) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException catch (e) {
      throw FormatException('会社词典不是合法 JSON：${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('会社词典顶层必须是 JSON 对象');
    }
    final version = decoded['format_version'];
    if (version is! int) {
      throw const FormatException('会社词典缺少 format_version');
    }
    if (version > supportedFormatVersion) {
      throw FormatException(
        '会社词典 format_version=$version 超出当前支持的 '
        '$supportedFormatVersion，请升级程序后再加载',
      );
    }
    final rawList = decoded['companies'];
    if (rawList is! List) {
      throw const FormatException('会社词典缺少 companies 数组');
    }

    final records = <CompanyRecord>[];
    final seenIds = <int>{};
    final aliasIndex = <String, CompanyRecord>{};
    final vndbIndex = <String, CompanyRecord>{};
    final ambiguous = <String>[];

    for (final item in rawList) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('companies[] 的元素必须是 JSON 对象');
      }
      final id = item['company_id'];
      if (id is! int) {
        throw const FormatException('company_id 必须是整数');
      }
      if (!seenIds.add(id)) {
        throw FormatException('company_id 重复：$id');
      }
      final standard = _requiredText(item['standard_name'], id, 'standard_name');
      final status = (item['status'] as String? ?? '').trim();
      if (status != CompanyRecord.statusActive &&
          status != CompanyRecord.statusDiscontinued) {
        throw FormatException(
          'company_id=$id 的 status 非法："$status"（应为 active / discontinued）',
        );
      }
      final aliases = <String>[];
      final rawAliases = item['aliases'];
      if (rawAliases is List) {
        for (final a in rawAliases) {
          if (a is String && a.trim().isNotEmpty) {
            aliases.add(a.trim());
          }
        }
      }
      final successor = item['successor_company_id'];
      final record = CompanyRecord(
        companyId: id,
        standardName: standard,
        jpName: _optionalText(item['jp_name']),
        cnName: _optionalText(item['cn_name']),
        vndbId: _optionalText(item['vndb_id']),
        status: status,
        successorCompanyId: successor is int ? successor : null,
        comment: _optionalText(item['comment']),
        aliases: aliases,
      );
      records.add(record);

      // 主名字段 + 别名全部并入倒排索引，同 company_id 的重复键忽略。
      final selfNames = <String>[
        record.standardName,
        if (record.jpName != null) record.jpName!,
        if (record.cnName != null) record.cnName!,
        ...record.aliases,
      ];
      for (final text in selfNames) {
        final key = normalize(text);
        if (key.isEmpty) continue;
        final existing = aliasIndex[key];
        if (existing == null || existing.companyId == record.companyId) {
          aliasIndex[key] = record;
        } else {
          final warning =
              '"$text" 同时指向 ${existing.standardName}'
              '(#${existing.companyId}) 与 ${record.standardName}(#$id)';
          if (!ambiguous.contains(warning)) ambiguous.add(warning);
        }
      }

      final vndbId = record.vndbId;
      if (vndbId != null) {
        final vKey = normalize(vndbId);
        if (vKey.isNotEmpty) vndbIndex[vKey] = record;
      }
    }

    return CompanyAliasStore._(
      version,
      List.unmodifiable(records),
      Map.unmodifiable(aliasIndex),
      Map.unmodifiable(vndbIndex),
      List.unmodifiable(ambiguous),
    );
  }

  /// 从磁盘文件加载（Phase 1：直接读仓库内种子；Phase 2 换为 assets）。
  static Future<CompanyAliasStore> loadFromFile(String path) async {
    return CompanyAliasStore.parse(await File(path).readAsString());
  }

  // ---------------------------------------------------------------------------
  // 归一化
  // ---------------------------------------------------------------------------

  /// 归一化一段会社原文（幂等、无副作用）。
  ///
  /// 写入前与匹配前必须统一调用，保证两侧口径一致：
  /// `'  Ｍｉｎｏｒｉ　'`、`'Minori '`、`'minori'` → `'minori'`。
  static String normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // 连续空白（含全角空格 U+3000）折叠为单个半角空格。
    s = s.replaceAll(RegExp(r'[\s\u3000]+'), ' ');
    final out = StringBuffer();
    for (final rune in s.runes) {
      var c = rune;
      if (c >= 0xFF01 && c <= 0xFF5E) {
        c -= 0xFEE0; // 全角 ASCII → 半角
      }
      if (c >= 0x41 && c <= 0x5A) {
        c += 0x20; // A-Z → a-z（仅匹配层，展示层保留原文）
      }
      out.writeCharCode(c);
    }
    return out.toString();
  }

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 解析会社原文 → 唯一会社。未命中返回 null（调用方应把原文送入 pending 队列）。
  CompanyMatch? resolve(String raw) {
    final key = normalize(raw);
    if (key.isEmpty) return null;
    final hit = _aliasIndex[key];
    if (hit == null) return null;
    return CompanyMatch(
      record: hit,
      matchedAlias: raw.trim(),
      matchedKey: key,
    );
  }

  CompanyRecord? byId(int companyId) {
    for (final record in companies) {
      if (record.companyId == companyId) return record;
    }
    return null;
  }

  CompanyRecord? byVndbId(String vndbId) {
    final key = normalize(vndbId);
    if (key.isEmpty) return null;
    return _vndbIndex[key];
  }

  /// 联想搜索：任一可用名（归一化后）包含 [query] 即命中。
  /// 结果按 company_id 升序，稳定可预期；供筛选框 / 会社搜索框联想使用。
  List<CompanyRecord> search(String query, {int limit = 20}) {
    final key = normalize(query);
    if (key.isEmpty) return const [];
    final result = <CompanyRecord>[];
    final seen = <int>{};
    for (final record in companies) {
      final names = <String>[
        record.standardName,
        if (record.jpName != null) record.jpName!,
        if (record.cnName != null) record.cnName!,
        ...record.aliases,
      ];
      final matched = names.any((n) => normalize(n).contains(key));
      if (matched && seen.add(record.companyId)) {
        result.add(record);
        if (result.length >= limit) break;
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  static String? _optionalText(dynamic value) {
    if (value is! String) return null;
    final t = value.trim();
    return t.isEmpty ? null : t;
  }

  static String _requiredText(dynamic value, int id, String field) {
    final t = _optionalText(value);
    if (t == null) {
      throw FormatException('company_id=$id 缺少必填字段 $field');
    }
    return t;
  }
}

/// 词典内的一条会社主数据（对应 `company_aliases.json` 的 companies[] 元素）。
class CompanyRecord {
  static const String statusActive = 'active';
  static const String statusDiscontinued = 'discontinued';

  const CompanyRecord({
    required this.companyId,
    required this.standardName,
    required this.status,
    this.jpName,
    this.cnName,
    this.vndbId,
    this.successorCompanyId,
    this.comment,
    this.aliases = const [],
  });

  /// 稳定数字主键，终身不变；筛选 / 分组 / 统计的唯一业务键。
  final int companyId;

  /// 标准主名（英文官方名，VNDB 风格）。
  final String standardName;

  /// 日文官方原名；无独立日文写法时与 [standardName] 相同。
  final String? jpName;

  /// 中文正式译名（圈内公认通用中文名）；无则为 null，不得编造。
  final String? cnName;

  /// VNDB producer id（如 `p98`），外部主数据锚点。
  final String? vndbId;

  /// [statusActive] / [statusDiscontinued]。
  final String status;

  /// 改名 / 合并后的继任会社 id（预留字段，当前词典均为 null）。
  final int? successorCompanyId;

  final String? comment;

  /// 词典内嵌别名（不含 standard_name / jp_name / cn_name 本身）。
  final List<String> aliases;

  bool get isDiscontinued => status == statusDiscontinued;

  /// UI 友好展示名：中文正式译名优先，其次标准主名。
  String get displayName =>
      (cnName != null && cnName!.isNotEmpty) ? cnName! : standardName;
}

/// 一次成功的解析结果。
class CompanyMatch {
  const CompanyMatch({
    required this.record,
    required this.matchedAlias,
    required this.matchedKey,
  });

  final CompanyRecord record;

  /// 命中所用的原文（trim 后保留，供日志与 pending 对照）。
  final String matchedAlias;

  /// 归一化后的命中键。
  final String matchedKey;
}
