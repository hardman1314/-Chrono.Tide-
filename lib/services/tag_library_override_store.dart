import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_helper.dart';
import 'tag_vocabulary_store.dart';

/// 自定义维度条目（用户在标签库内联编辑模式里新增的维度）。
@immutable
class CustomTagDimension {
  const CustomTagDimension({
    required this.id,
    required this.title,
    required this.order,
  });

  /// 稳定标识（`u<ms>_<rand>`），维度改名/标签归属的键。
  final String id;
  final String title;
  final int order;

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'order': order};

  static CustomTagDimension fromJson(Map<String, dynamic> json) =>
      CustomTagDimension(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        order: (json['order'] as num?)?.toInt() ?? 0,
      );
}

/// 分类匣·标签库的**用户覆盖层**（内联编辑模式的数据落盘）。
///
/// 与随包只读词表（`tag_vocabulary.json` / `tag_dimensions.json`）分层：
/// 词表是**系统分发的事实**，本文件是**用户意愿**，两者在展示层合并
/// （覆盖优先，词表兜底），词表升级不会冲掉用户整理结果。
///
/// 四张覆盖表：
/// - `dimension_renames`：asset 维度 id → 新标题（改名只改显示标题，
///   **不改变该维度下概念的筛选行为**——概念归属与过滤语义不变）；
/// - `custom_dimensions`：用户新增维度（系统不做自动归类，用户自行
///   把标签拖进来，语义类似「其他」的延伸）；
/// - `concept_dim_overrides`：概念 id → 维度 id（把概念挪到别的维度，
///   含用户维度；只影响展示分区与该维度的筛选入口，词表本身不变）；
/// - `unclassified_dim_overrides`：未归类标签归一化键 → 维度 id
///   （把「其他」里的原始标签收进某个维度）；
/// - `hidden_tags`：隐藏标签集合（**归一化键**；隐藏是全局的——所有
///   展示点都看不到该标签，标签库中显示斜眼图标可恢复）。
///
/// 键口径：概念用 `id`，未归类/隐藏用 [TagVocabularyStore.normalizeTag] 归一化。
///
/// 纪律与 `CompanyWallStore` 一致（P1-4b/4c）：
/// - 加载失败**不覆写磁盘**（保留人工恢复机会），内存退化为空态；
/// - 写盘串行化 + 唯一 tmp 文件 + 原子 rename。
class TagLibraryOverrideStore extends ChangeNotifier {
  TagLibraryOverrideStore._();

  static final TagLibraryOverrideStore _instance =
      TagLibraryOverrideStore._();
  static TagLibraryOverrideStore get instance => _instance;

  static String get _filePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}tag_library_overrides.json';

  final Map<String, String> _dimensionRenames = {};
  final List<CustomTagDimension> _customDimensions = [];
  final Map<String, String> _conceptDimOverrides = {};
  final Map<String, String> _unclassifiedDimOverrides = {};
  final Set<String> _hiddenTags = {};

  bool _loaded = false;
  bool _loadFailed = false;
  int _revision = 0;
  int get revision => _revision;

  Future<void> _saveQueue = Future<void>.value();
  int _tmpSeq = 0;

  bool get isLoaded => _loaded;
  bool get loadFailed => _loadFailed;

  // ---------------------------------------------------------------------------
  // 只读视图
  // ---------------------------------------------------------------------------

  /// asset 维度的新标题（无覆盖返回 null）。
  String? dimensionTitleOverride(String dimId) {
    final t = _dimensionRenames[dimId];
    return (t == null || t.isEmpty) ? null : t;
  }

  /// 用户新增维度（创建顺序）。
  List<CustomTagDimension> get customDimensions =>
      List.unmodifiable(_customDimensions);

  /// 概念的有效维度 id（覆盖优先）。
  String effectiveConceptDim(String conceptId, String assetDimId) =>
      _conceptDimOverrides[conceptId] ?? assetDimId;

  /// 未归类标签的有效维度 id（null = 留在「其他」）。
  String? unclassifiedDimOf(String normalizedRaw) =>
      _unclassifiedDimOverrides[normalizedRaw];

  bool isHidden(Object key) => _hiddenTags.contains(key.toString());

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  /// 重命名维度（asset 维度写 rename 覆盖；用户维度直接改其标题）。
  /// 空标题 = 清除 asset 维度覆盖（用户维度忽略空标题）。
  Future<void> renameDimension(String dimId, String? title) async {
    if (dimId.isEmpty) return;
    final t = title?.trim() ?? '';
    final user = _customDimensions.where((d) => d.id == dimId).toList();
    if (user.isNotEmpty) {
      if (t.isEmpty) return;
      final idx = _customDimensions.indexOf(user.first);
      _customDimensions[idx] = CustomTagDimension(
        id: dimId,
        title: t,
        order: user.first.order,
      );
      await _persist();
      return;
    }
    if (t.isEmpty) {
      _dimensionRenames.remove(dimId);
    } else {
      _dimensionRenames[dimId] = t;
    }
    await _persist();
  }

  /// 新增用户维度（返回新维度；标题去重失败返回 null）。
  Future<CustomTagDimension?> addCustomDimension(String title) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final exists = _customDimensions.any(
        (d) => d.title.trim().toLowerCase() == t.toLowerCase());
    if (exists) return null;
    final maxOrder = _customDimensions.isEmpty
        ? 1000
        : _customDimensions.map((d) => d.order).reduce((a, b) => a > b ? a : b);
    final dim = CustomTagDimension(
      id: 'u${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 0xFFFF}',
      title: t,
      order: maxOrder + 1,
    );
    _customDimensions.add(dim);
    await _persist();
    return dim;
  }

  /// 把概念挪到目标维度（调用方须先校验 targetDimId 是 asset 注册维度或
  /// 用户自定义维度；本 store 无词表访问权，不做二次校验）。
  Future<void> setConceptDim(String conceptId, String targetDimId) async {
    if (conceptId.isEmpty || targetDimId.isEmpty) return;
    if (_conceptDimOverrides[conceptId] == targetDimId) return;
    _conceptDimOverrides[conceptId] = targetDimId;
    await _persist();
  }

  /// 把未归类标签收进目标维度（dimId 为空 = 退回「其他」）。
  Future<void> setUnclassifiedDim(String normalizedRaw, String? dimId) async {
    final n = normalizedRaw.trim();
    if (n.isEmpty) return;
    final d = dimId?.trim() ?? '';
    if (d.isEmpty) {
      if (_unclassifiedDimOverrides.remove(n) == null) return;
    } else {
      if (_unclassifiedDimOverrides[n] == d) return;
      _unclassifiedDimOverrides[n] = d;
    }
    await _persist();
  }

  /// 隐藏标签（键 = 归一化标签）。重命名写穿后请同步迁移键（[migrateKey]）。
  Future<void> hideTag(String normalizedKey) async {
    final n = normalizedKey.trim();
    if (n.isEmpty || !_hiddenTags.add(n)) return;
    await _persist();
  }

  /// 取消隐藏。
  Future<void> showTag(String normalizedKey) async {
    if (!_hiddenTags.remove(normalizedKey.trim())) return;
    await _persist();
  }

  /// 标签写穿改名后，把覆盖层里的旧键迁移到新键（隐藏 + 未归类维度归属）。
  Future<void> migrateKey(String oldNorm, String newNorm) async {
    final o = oldNorm.trim();
    final n = newNorm.trim();
    if (o.isEmpty || n.isEmpty || o == n) return;
    var changed = false;
    if (_hiddenTags.remove(o)) {
      _hiddenTags.add(n);
      changed = true;
    }
    final dim = _unclassifiedDimOverrides.remove(o);
    if (dim != null) {
      _unclassifiedDimOverrides[n] = dim;
      changed = true;
    }
    if (changed) await _persist();
  }

  /// 全量覆盖后是否真的有内容（诊断/测试用）。
  bool get isEmpty =>
      _dimensionRenames.isEmpty &&
      _customDimensions.isEmpty &&
      _conceptDimOverrides.isEmpty &&
      _unclassifiedDimOverrides.isEmpty &&
      _hiddenTags.isEmpty;

  // ---------------------------------------------------------------------------
  // 加载 / 保存
  // ---------------------------------------------------------------------------

  /// 幂等加载（不存在视为空态；**所有版本兼容读取**——未知字段忽略）。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final renames = data['dimension_renames'];
        if (renames is Map) {
          _dimensionRenames
            ..clear()
            ..addEntries(renames.entries.map((e) =>
                MapEntry(e.key.toString(), e.value.toString().trim())))
            ..removeWhere((_, v) => v.isEmpty);
        }
        final customs = data['custom_dimensions'];
        if (customs is List) {
          _customDimensions
            ..clear()
            ..addAll(customs
                .whereType<Map>()
                .map((e) =>
                    CustomTagDimension.fromJson(e.cast<String, dynamic>()))
                .where((d) => d.id.isNotEmpty && d.title.isNotEmpty));
        }
        Map<String, String>? normMap(dynamic raw) {
          if (raw is! Map) return null;
          final out = <String, String>{};
          raw.forEach((k, v) {
            final key = k.toString().trim();
            final val = v.toString().trim();
            if (key.isNotEmpty && val.isNotEmpty) out[key] = val;
          });
          return out;
        }

        final conceptDims = normMap(data['concept_dim_overrides']);
        if (conceptDims != null) {
          _conceptDimOverrides..clear()..addAll(conceptDims);
        }
        final unclassifiedDims = normMap(data['unclassified_dim_overrides']);
        if (unclassifiedDims != null) {
          _unclassifiedDimOverrides..clear()..addAll(unclassifiedDims);
        }
        final hidden = data['hidden_tags'];
        if (hidden is List) {
          _hiddenTags
            ..clear()
            ..addAll(hidden.map((e) => e.toString().trim()).where((e) => e.isNotEmpty));
        }
      }
      _loaded = true;
      _loadFailed = false;
      _revision++;
      notifyListeners();
    } catch (e) {
      // ★ 加载失败绝不清空内存、绝不写盘（P1-4b）
      debugPrint('[TAG-OVERRIDE] ⚠️ 加载失败（保留磁盘数据，不覆写）: $e');
      _loadFailed = true;
      _loaded = true;
      _revision++;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    _revision++;
    final previous = _saveQueue;
    final completer = Completer<void>();
    _saveQueue = completer.future;
    await previous;

    try {
      final file = File(_filePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = {
        'format_version': 1,
        'dimension_renames': _dimensionRenames,
        'custom_dimensions': _customDimensions.map((d) => d.toJson()).toList(),
        'concept_dim_overrides': _conceptDimOverrides,
        'unclassified_dim_overrides': _unclassifiedDimOverrides,
        'hidden_tags': _hiddenTags.toList(),
      };
      final content = const JsonEncoder.withIndent('  ').convert(data);
      final tempPath =
          '$_filePath.${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(content, flush: true);
        await tempFile.rename(_filePath);
      } catch (e) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[TAG-OVERRIDE] ⚠️ 保存失败: $e');
    } finally {
      completer.complete();
    }
  }

  /// 测试专用：清空内存态（不触碰磁盘）。
  @visibleForTesting
  void resetForTest() {
    _dimensionRenames.clear();
    _customDimensions.clear();
    _conceptDimOverrides.clear();
    _unclassifiedDimOverrides.clear();
    _hiddenTags.clear();
    _loaded = false;
    _loadFailed = false;
  }

  // ---------------------------------------------------------------------------
  // 全局可见性（所有标签展示点的唯一出口）
  // ---------------------------------------------------------------------------

  /// 过滤掉被隐藏的标签（按归一化匹配，容忍别名变体）。
  ///
  /// 展示点约定：**凡是渲染 `game.tags` 的地方都必须先过这一道**，
  /// 这样「隐藏标签」才是真正的全局隐藏。
  List<String> filterVisibleTags(Iterable<String> tags) {
    if (_hiddenTags.isEmpty) return tags is List<String> ? tags : List.of(tags);
    return [
      for (final t in tags)
        if (!_hiddenTags.contains(TagVocabularyStore.normalizeTag(t))) t,
    ];
  }
}
