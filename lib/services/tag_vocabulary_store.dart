import 'dart:convert' show JsonDecoder;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;

/// 分类匣·标签受控词表（Controlled Vocabulary）。
///
/// 解决的问题：库内标签是**自由文本**（`game.json` 的 `tags: List<String>`），
/// 既有数据库标准标签（VNDB/DLsite 翻译而来），也有玩家口语标签（同义、别名、
/// 大小写/全半角混杂）。直接平铺会产生「同一含义多个筛选项」与「标签归属混乱」。
///
/// 本服务提供两层能力：
/// 1. **同义归并**：归一化 + 别名倒排索引，把多写法收敛到唯一[规范概念][TagConcept]；
/// 2. **维度归属**：每个概念只属于**唯一维度**（[TagDimension]），维度之间正交，
///    从根上消除「一个大类边界重叠」的歧义；未命中词表的标签进「未归类」桶
///    （不丢数据，可后续把别名补进词表）。
///
/// 数据文件（随包只读分发）：
/// - `assets/data/tag_dimensions.json`：维度注册表（顺序/标题/互斥/主题色）；
/// - `assets/data/tag_vocabulary.json`：规范概念 + 别名。
///
/// 纪律（与 `CompanyAliasStore` 同款）：
/// - 加载失败**不抛异常**，降级为空词表——标签库退化为「全部未归类」，不阻塞主流程；
/// - **保守归并，不做模糊匹配**：宁可漏匹配进未归类，也不错合并两个不同含义
///   （呼应 ADR-007「归属存疑保留」）；
/// - 计数永远从库内游戏派生，不落盘。
class TagVocabularyStore {
  TagVocabularyStore._(
    this.dimensions,
    this.concepts,
    Map<String, TagConcept> conceptById,
    Map<String, String> aliasIndex,
  )   : _conceptById = conceptById,
        _aliasIndex = aliasIndex;

  /// 当前支持的词表格式版本。
  static const int supportedFormatVersion = 1;

  static const String dimensionsAssetPath = 'assets/data/tag_dimensions.json';
  static const String vocabularyAssetPath = 'assets/data/tag_vocabulary.json';

  /// 概念选择键前缀（`concept:<概念id>`），用于侧栏选中态与过滤。
  static const String kConceptKeyPrefix = 'concept:';

  static String conceptKey(String conceptId) => '$kConceptKeyPrefix$conceptId';

  static TagVocabularyStore? _instance;
  static Future<TagVocabularyStore?>? _loadFuture;

  /// 维度（保持文件内 order 顺序）。
  final List<TagDimension> dimensions;

  /// 全部规范概念（保持文件顺序）。
  final List<TagConcept> concepts;

  final Map<String, TagConcept> _conceptById;

  /// 归一化别名 → 概念 id（同义归并的唯一出口）。
  final Map<String, String> _aliasIndex;

  static TagVocabularyStore? get instanceOrNull => _instance;

  TagConcept? conceptById(String id) => _conceptById[id];

  TagDimension? dimensionById(String id) {
    for (final d in dimensions) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 幂等加载（失败返回 null 并允许重试）。
  static Future<TagVocabularyStore?> ensureLoaded() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final future = _loadFromAssets();
    _loadFuture = future;
    return future;
  }

  static Future<TagVocabularyStore?> _loadFromAssets() async {
    try {
      final dimRaw = await rootBundle.loadString(dimensionsAssetPath);
      final vocabRaw = await rootBundle.loadString(vocabularyAssetPath);
      final store = TagVocabularyStore.parse(
        dimensionsJson: dimRaw,
        vocabularyJson: vocabRaw,
      );
      _instance = store;
      debugPrint(
          '[TAG-VOCAB] ✅ 受控词表已加载: ${store.dimensions.length} 维度 / '
          '${store.concepts.length} 概念 / ${store._aliasIndex.length} 别名键');
      return store;
    } catch (e) {
      debugPrint('[TAG-VOCAB] ⚠️ 受控词表加载失败（降级为全部未归类）: $e');
      _loadFuture = null; // 允许下次重试
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 解析
  // ---------------------------------------------------------------------------

  /// 原始标签 → 规范概念（未命中返回 null）。
  TagConcept? resolve(String rawTag) {
    final n = normalizeTag(rawTag);
    if (n.isEmpty) return null;
    final id = _aliasIndex[n];
    if (id == null) return null;
    return _conceptById[id];
  }

  /// 某原始标签是否命中受控词表。
  bool containsTag(String rawTag) => resolve(rawTag) != null;

  // ---------------------------------------------------------------------------
  // 归一化（与生成器 / 词表构建口径严格一致）
  // ---------------------------------------------------------------------------

  /// 全角 ASCII → 半角区间起点
  static const int _fwStart = 0xFF01;
  static const int _fwEnd = 0xFF5E;
  static const int _fwOffset = 0xFEE0;

  /// 归一化时应丢弃的噪声字符（半角/全角标点、空白）。全角已在转换阶段折叠。
  static const Set<int> _noiseRunes = {
    0x20, 0x09, 0x0A, 0x0D, // 空白
    0x3000, // 全角空格
    0xB7, 0x30FB, // · ・
    0x2C, // ,  (全角已折叠)
    0x3001, 0x3002, // 、。
    0x2E, // .
    0x21, 0x3F, // ! ?
    0x7E, // ~
    0x2D, 0x2010, 0x2013, 0x2014, 0x2015, // - 各种连字符/破折号
    0x5F, // _
    0x28, 0x29, 0x3014, 0x3015, 0x3010, 0x3011, // ()〔〕【】
    0x5B, 0x5D, 0x7B, 0x7D, // [] {}
    0x300C, 0x300D, 0x300E, 0x300F, // 「」『』
    0x22, 0x27, // " '
    0x3A, 0x3B, // : ;
    0x2A, 0x23, 0x40, 0x26, 0x2F, 0x5C, 0x7C, // *#@&/\|
  };

  /// 归一化：trim → 全角转半角 → 小写 → 去噪声字符。
  static String normalizeTag(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final sb = StringBuffer();
    for (final rune in trimmed.runes) {
      var c = rune;
      if (c >= _fwStart && c <= _fwEnd) c -= _fwOffset; // 全角 → 半角
      if (_noiseRunes.contains(c)) continue;
      if (c >= 0x41 && c <= 0x5A) c += 0x20; // A-Z → a-z
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // 派生（纯函数，便于单测）
  // ---------------------------------------------------------------------------

  /// 从库内游戏的标签列派生：概念计数 + 未归类标签计数。
  ///
  /// - 同一游戏在同一概念 / 同一未归类标签上只计一次；
  /// - 计数口径与侧栏展示一致（trim + 归一化归并）。
  static TagDerivation derive(
    Iterable<List<String>> gamesTags,
    TagVocabularyStore? vocab,
  ) {
    final conceptCounts = <String, int>{};
    final unclassifiedByNorm = <String, int>{};
    final unclassifiedDisplay = <String, String>{};

    for (final tags in gamesTags) {
      final seenConcepts = <String>{};
      final seenUnclassified = <String>{};
      for (final raw in tags) {
        final t = raw.trim();
        if (t.isEmpty) continue;
        final concept = vocab?.resolve(t);
        if (concept != null) {
          seenConcepts.add(concept.id);
          continue;
        }
        final n = normalizeTag(t);
        if (n.isEmpty) continue;
        unclassifiedDisplay.putIfAbsent(n, () => t);
        seenUnclassified.add(n);
      }
      for (final id in seenConcepts) {
        conceptCounts[id] = (conceptCounts[id] ?? 0) + 1;
      }
      for (final n in seenUnclassified) {
        unclassifiedByNorm[n] = (unclassifiedByNorm[n] ?? 0) + 1;
      }
    }

    final unclassified = <UnclassifiedTag>[
      for (final e in unclassifiedByNorm.entries)
        UnclassifiedTag(name: unclassifiedDisplay[e.key] ?? e.key, count: e.value),
    ]..sort((a, b) {
        final c = b.count.compareTo(a.count);
        return c != 0 ? c : a.name.compareTo(b.name);
      });

    return TagDerivation(
      conceptCounts: conceptCounts,
      unclassified: unclassified,
    );
  }

  /// 某游戏的标签集合解析出的概念 id 集合（过滤用，口径与 [derive] 一致）。
  static Set<String> conceptIdsOfGame(
    Iterable<String> tags,
    TagVocabularyStore? vocab,
  ) {
    final out = <String>{};
    if (vocab == null) return out;
    for (final raw in tags) {
      final concept = vocab.resolve(raw);
      if (concept != null) out.add(concept.id);
    }
    return out;
  }

  /// 过滤判定：**维度内并集 · 维度间交集**。
  ///
  /// [selectedByDim]：维度 id → 该维度下选中的概念 id 集合。
  /// 规则：对每个被选中的维度，游戏的概念集需与该维度选中集**有交集**；
  /// 所有被选中维度都满足才算命中（维度间取交集，实现「组合偏好」的收窄检索）。
  static bool matchesSelection(
    Set<String> gameConceptIds,
    Map<String, Set<String>> selectedByDim,
  ) {
    if (selectedByDim.isEmpty) return true;
    for (final entry in selectedByDim.entries) {
      if (entry.value.isEmpty) continue;
      var hit = false;
      for (final id in entry.value) {
        if (gameConceptIds.contains(id)) {
          hit = true;
          break;
        }
      }
      if (!hit) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  /// 从两份 JSON 字符串构建；结构不合法时抛 [FormatException]。
  factory TagVocabularyStore.parse({
    required String dimensionsJson,
    required String vocabularyJson,
  }) {
    final dims = _parseDimensions(dimensionsJson);
    final dimIds = {for (final d in dims) d.id};
    final concepts = <TagConcept>[];
    final conceptById = <String, TagConcept>{};
    final aliasIndex = <String, String>{};

    final decoded = _decodeObject(vocabularyJson, '标签词表');
    final version = (decoded['format_version'] as num?)?.toInt() ?? 0;
    if (version > supportedFormatVersion) {
      throw FormatException('标签词表版本超纲: $version > $supportedFormatVersion');
    }
    final rawConcepts = decoded['concepts'];
    if (rawConcepts is! List) {
      throw const FormatException('标签词表缺少 concepts 数组');
    }
    for (final raw in rawConcepts) {
      if (raw is! Map<String, dynamic>) continue;
      final id = (raw['id'] as String? ?? '').trim();
      final name = (raw['name'] as String? ?? '').trim();
      final dim = (raw['dim'] as String? ?? '').trim();
      if (id.isEmpty || name.isEmpty || dim.isEmpty) continue;
      if (!dimIds.contains(dim)) continue; // 维度未注册 → 跳过（防脏数据）
      if (conceptById.containsKey(id)) continue;
      final aliases = <String>[];
      for (final a in (raw['aliases'] as List? ?? const [])) {
        final s = a.toString().trim();
        if (s.isNotEmpty) aliases.add(s);
      }
      final concept =
          TagConcept(id: id, name: name, dimensionId: dim, aliases: aliases);
      conceptById[id] = concept;
      concepts.add(concept);
      // 倒排：规范名 + 别名（先到先得，防跨概念抢注）
      for (final a in <String>[name, ...aliases]) {
        final n = normalizeTag(a);
        if (n.isEmpty) continue;
        aliasIndex.putIfAbsent(n, () => id);
      }
    }

    return TagVocabularyStore._(dims, concepts, conceptById, aliasIndex);
  }

  static List<TagDimension> _parseDimensions(String jsonString) {
    final decoded = _decodeObject(jsonString, '维度注册表');
    final version = (decoded['format_version'] as num?)?.toInt() ?? 0;
    if (version > supportedFormatVersion) {
      throw FormatException('维度注册表版本超纲: $version > $supportedFormatVersion');
    }
    final rawDims = decoded['dimensions'];
    if (rawDims is! List) {
      throw const FormatException('维度注册表缺少 dimensions 数组');
    }
    final dims = <TagDimension>[];
    for (final raw in rawDims) {
      if (raw is! Map<String, dynamic>) continue;
      final id = (raw['id'] as String? ?? '').trim();
      final title = (raw['title'] as String? ?? '').trim();
      if (id.isEmpty || title.isEmpty) continue;
      Color? color;
      final hex = raw['color'] as String?;
      if (hex != null && hex.length == 7 && hex.startsWith('#')) {
        color = Color(int.parse('FF${hex.substring(1)}', radix: 16));
      }
      dims.add(TagDimension(
        id: id,
        title: title,
        order: (raw['order'] as num?)?.toInt() ?? dims.length,
        exclusive: raw['exclusive'] as bool? ?? false,
        color: color,
        desc: (raw['desc'] as String? ?? '').trim(),
      ));
    }
    dims.sort((a, b) => a.order.compareTo(b.order));
    return dims;
  }

  static Map<String, dynamic> _decodeObject(String jsonString, String label) {
    final dynamic decoded;
    try {
      decoded = const JsonDecoder().convert(jsonString);
    } on FormatException catch (e) {
      throw FormatException('$label 不是合法 JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$label 顶层必须是对象');
    }
    return decoded;
  }

  /// 测试 / 工具专用：清空单例缓存。
  @visibleForTesting
  static void resetInstanceForTest() {
    _instance = null;
    _loadFuture = null;
  }

  /// 测试专用：直接注入实例。
  @visibleForTesting
  static void debugSetInstanceForTest(TagVocabularyStore? store) {
    _instance = store;
    _loadFuture = Future<TagVocabularyStore?>.value(store);
  }
}

/// 一个维度（大分类）。
@immutable
class TagDimension {
  const TagDimension({
    required this.id,
    required this.title,
    required this.order,
    required this.exclusive,
    required this.desc,
    this.color,
  });

  final String id;
  final String title;
  final int order;

  /// 是否同维度内单选语义（如「年龄分级」全年龄 / R18 天然互斥）。
  final bool exclusive;
  final String desc;

  /// 维度主题色（UI 圆点/标题用）。
  final Color? color;
}

/// 一个规范概念（受控词表的唯一出口）。
@immutable
class TagConcept {
  const TagConcept({
    required this.id,
    required this.name,
    required this.dimensionId,
    required this.aliases,
  });

  final String id;

  /// 规范名（写穿时写入游戏的标签值）。
  final String name;
  final String dimensionId;

  /// 同义别名（不含规范名本身）。
  final List<String> aliases;

  /// 侧栏选择键。
  String get key => TagVocabularyStore.conceptKey(id);
}

/// 未归类标签（未命中受控词表的原始标签）。
@immutable
class UnclassifiedTag {
  const UnclassifiedTag({required this.name, required this.count});

  final String name;
  final int count;
}

/// [TagVocabularyStore.derive] 的派生结果。
@immutable
class TagDerivation {
  const TagDerivation({
    required this.conceptCounts,
    required this.unclassified,
  });

  /// 概念 id → 成员游戏数。
  final Map<String, int> conceptCounts;

  /// 未归类标签（计数降序）。
  final List<UnclassifiedTag> unclassified;

  int countOf(String conceptId) => conceptCounts[conceptId] ?? 0;
}
