import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_helper.dart';
import 'company_alias_store.dart';
import 'local_game_registry.dart';

/// 智能归纳分组的类型
///
/// 与"收藏夹"的本质区别：收藏夹是**用户自建**的分类容器（成员关系存
/// `game.json` 的 `collection_ids`），智能归纳是**从游戏数据本身派生**的视图
/// （成员关系永远实时来自 `tags` / `developer`），因此不需要、也不应该持久化成员。
enum SmartGroupKind {
  /// 按标签归纳（一个游戏可属于多个标签组）
  tag,

  /// 按会社归纳（一个游戏只属于一个会社组，含"未填会社"）
  developer,
}

/// 派生出来的一个智能分组（值对象）
@immutable
class SmartGroup {
  const SmartGroup({
    required this.key,
    required this.kind,
    required this.value,
    required this.displayName,
    required this.hidden,
    required this.pinned,
    required this.count,
    this.companyId,
  });

  /// 稳定标识：[tagKey] / [devKey] / [companyDevKey] 生成，未填会社固定为 `dev:`
  final String key;

  final SmartGroupKind kind;

  /// 原始数据值（标签值 / 会社名；"未填会社"为空串）。
  ///
  /// 会社归一化分组（[companyId] != null）里存的是**标准主名**
  /// （`CompanyRecord.standardName`）：拖拽写穿把它设为游戏会社，
  /// 让 developer 逐步收敛到规范写法。
  final String value;

  /// 会社归一化的 company_id（仅会社组且词典命中时非空）。
  ///
  /// 成员判定按它优先：同一会社无论 developer 原文是 sprite / 雪碧社 /
  /// 精灵社，都归入同一个 `devId:<id>` 组；词典未命中的原文才落回
  /// `dev:<原文>` 组（且只收 companyId == null 的游戏，避免双计）。
  final int? companyId;

  /// 展示名：用户重命名覆盖优先，否则用 [value]（未填会社用固定文案）
  final String displayName;

  /// 用户隐藏（不出现在侧栏，但可随时恢复）
  final bool hidden;

  /// 用户置顶（排在归纳区最前）
  final bool pinned;

  /// 当前成员数（派生值，非持久化）
  final int count;

  /// 是否为「未填会社」这个特殊分组
  bool get isUnassignedDeveloper =>
      kind == SmartGroupKind.developer && value.isEmpty;

  /// 某个游戏是否属于本组（**成员关系的唯一判定**，口径须与 [deriveGroups] 一致）
  bool matches(LibraryGame game) {
    switch (kind) {
      case SmartGroupKind.tag:
        // 与派生口径一致：标签比较前 trim（" 纯爱 " 与 "纯爱" 同组）
        return game.tags.any((t) => t.trim() == value);
      case SmartGroupKind.developer:
        if (value.isEmpty) return game.developer.trim().isEmpty;
        // ★ 会社归一化：词典命中的组按 company_id 判定（跨写法归并）；
        //   未命中词典的原文组只收仍未解析的游戏，避免与 devId 组双计。
        if (companyId != null) return game.companyId == companyId;
        return game.companyId == null && game.developer.trim() == value;
    }
  }
}

/// 分组的展示层覆盖项（**只含展示相关字段**，成员永远派生）
@immutable
class SmartGroupOverride {
  const SmartGroupOverride({
    this.displayName,
    this.hidden = false,
    this.pinned = false,
  });

  final String? displayName;
  final bool hidden;
  final bool pinned;

  bool get isEmpty =>
      (displayName == null || displayName!.isEmpty) && !hidden && !pinned;

  Map<String, dynamic> toJson() => {
        if (displayName != null && displayName!.isNotEmpty)
          'display_name': displayName,
        if (hidden) 'hidden': true,
        if (pinned) 'pinned': true,
      };

  factory SmartGroupOverride.fromJson(Map<String, dynamic> json) {
    final name = json['display_name'] as String?;
    return SmartGroupOverride(
      displayName: (name == null || name.isEmpty) ? null : name,
      hidden: json['hidden'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
    );
  }
}

/// 智能归纳服务：从库内游戏数据派生「标签 / 会社」分组，并承载展示层覆盖项。
///
/// 设计约束：
/// - **成员关系不落盘**（永远派生自 `tags` / `developer`），避免出现"分组显示与
///   游戏数据脱节"的双份事实；用户增删成员 = 改游戏数据（写穿，见
///   `LocalGameRegistry.setGameTag` / `setGameDeveloper`）；
/// - 只有展示层（重命名 / 置顶 / 隐藏）落盘到 `data/smart_groups.json`；
/// - 读取失败时**不覆写磁盘**（与 `CollectionService` 的 P1-4b 纪律一致），
///   内存退化为"无覆盖项"，不影响库正常运行。
class SmartGroupService extends ChangeNotifier {
  SmartGroupService._();

  static final SmartGroupService _instance = SmartGroupService._();
  static SmartGroupService get instance => _instance;

  /// 「未填会社」分组的固定键
  static const String kUnassignedDevKey = 'dev:';

  /// 标签分组的键前缀（`tag:<标签名>`）
  static const String tagKeyPrefix = 'tag:';

  /// 「未填会社」的展示文案
  static const String kUnassignedDevLabel = '未填会社';

  /// 会社归一化分组的键前缀（词典命中：`devId:<company_id>`，跨写法稳定）
  static const String kCompanyDevKeyPrefix = 'devId:';

  static String tagKey(String tag) => '$tagKeyPrefix$tag';
  static String devKey(String developer) => 'dev:$developer';
  static String companyDevKey(int companyId) => '$kCompanyDevKeyPrefix$companyId';

  static String get _filePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}smart_groups.json';

  Map<String, SmartGroupOverride> _overrides = {};
  bool _loaded = false;
  bool _loadFailed = false;
  int _revision = 0;

  /// 覆盖项修订号：供 UI 侧缓存失效（覆盖项变更时自增）
  int get revision => _revision;

  bool get isLoaded => _loaded;

  /// 最近一次 load() 是否失败（磁盘数据保留，未被覆写）
  bool get loadFailed => _loadFailed;

  SmartGroupOverride? overrideOf(String key) => _overrides[key];

  /// 已设置覆盖项的键集合（供 UI 提示"已自定义"）
  Set<String> get overriddenKeys => _overrides.keys.toSet();

  // ==================== 派生 ====================

  /// 派生分组（纯函数，便于单测；不依赖本服务状态）
  ///
  /// - 标签组：每个非空标签一个组（去首尾空白后归并）
  /// - 会社组：**词典命中（company_id 非空）的游戏按 `devId:<id>` 归并**——
  ///   同一会社无论原文写 sprite / 雪碧社 / 精灵社 都进同一组，展示名取
  ///   词典的中文译名或标准主名；词典未命中的原文各自成 `dev:<原文>` 组
  ///   （只收 companyId == null 的游戏，避免与 devId 组双计）
  /// - 「未填会社」组（`dev:`）语义不变
  /// - 排序：置顶组优先 → 成员数降序 → 展示名
  static List<SmartGroup> deriveGroups(
    Iterable<LibraryGame> games, {
    Map<String, SmartGroupOverride> overrides = const {},
    bool includeUnassignedDeveloper = true,
    CompanyAliasStore? companyAliases,
  }) {
    final tagCounts = <String, int>{};
    final companyIdCounts = <int, int>{};
    final devRawCounts = <String, int>{};
    var unassignedDev = 0;

    for (final game in games) {
      // 先归一化（trim）再按游戏去重：同一游戏在同一标签组里只算一次成员，
      // 且 " 纯爱 " 与 "纯爱" 必须归并到同一组（与 matches 的口径严格一致）
      final normalizedTags = <String>{};
      for (final raw in game.tags) {
        final tag = raw.trim();
        if (tag.isEmpty) continue;
        normalizedTags.add(tag);
      }
      for (final tag in normalizedTags) {
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
      final dev = game.developer.trim();
      if (dev.isEmpty) {
        unassignedDev++;
      } else if (game.companyId != null) {
        companyIdCounts[game.companyId!] =
            (companyIdCounts[game.companyId!] ?? 0) + 1;
      } else {
        devRawCounts[dev] = (devRawCounts[dev] ?? 0) + 1;
      }
    }

    final groups = <SmartGroup>[];

    void add({
      required String key,
      required SmartGroupKind kind,
      required String value,
      required String fallbackLabel,
      required int count,
      int? companyId,
    }) {
      final o = overrides[key];
      final custom = o?.displayName;
      groups.add(SmartGroup(
        key: key,
        kind: kind,
        value: value,
        displayName:
            (custom != null && custom.isNotEmpty) ? custom : fallbackLabel,
        hidden: o?.hidden ?? false,
        pinned: o?.pinned ?? false,
        count: count,
        companyId: companyId,
      ));
    }

    tagCounts.forEach((tag, count) => add(
          key: tagKey(tag),
          kind: SmartGroupKind.tag,
          value: tag,
          fallbackLabel: tag,
          count: count,
        ));
    companyIdCounts.forEach((id, count) {
      // 词典缩水（id 查不到）时兜底展示，成员判定仍按 id，不受影响
      final rec = companyAliases?.byId(id);
      add(
        key: companyDevKey(id),
        kind: SmartGroupKind.developer,
        value: rec?.standardName ?? 'company:$id',
        fallbackLabel: rec?.displayName ?? '会社#$id',
        count: count,
        companyId: id,
      );
    });
    devRawCounts.forEach((dev, count) => add(
          key: devKey(dev),
          kind: SmartGroupKind.developer,
          value: dev,
          fallbackLabel: dev,
          count: count,
        ));
    if (includeUnassignedDeveloper && unassignedDev > 0) {
      add(
        key: kUnassignedDevKey,
        kind: SmartGroupKind.developer,
        value: '',
        fallbackLabel: kUnassignedDevLabel,
        count: unassignedDev,
      );
    }

    groups.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      if (a.count != b.count) return b.count.compareTo(a.count);
      return a.displayName.compareTo(b.displayName);
    });
    return groups;
  }

  /// 用当前覆盖项派生分组（库页调用）
  List<SmartGroup> buildGroups(
    Iterable<LibraryGame> games, {
    bool includeUnassignedDeveloper = true,
  }) =>
      deriveGroups(games,
          overrides: _overrides,
          includeUnassignedDeveloper: includeUnassignedDeveloper,
          companyAliases: CompanyAliasStore.instanceOrNull);

  /// 侧栏可展示的分组（滤掉隐藏项）
  static List<SmartGroup> visibleGroups(Iterable<SmartGroup> groups) =>
      groups.where((g) => !g.hidden).toList();

  // ==================== 持久化 ====================

  /// 幂等加载（不存在视为空覆盖项）
  Future<void> load() async {
    if (_loaded) return;
    // ★ 会社归一化（Phase 2）：旧覆盖项键 `dev:<原文>` → `devId:<id>` 迁移
    //   依赖词典先就位；词典加载失败则跳过迁移（保留旧键，功能零回归）。
    await CompanyAliasStore.ensureLoaded();
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) {
          final map = raw['overrides'];
          if (map is Map) {
            _overrides = map.map((k, v) => MapEntry(
                  k.toString(),
                  SmartGroupOverride.fromJson(
                      (v as Map).cast<String, dynamic>()),
                ))
              ..removeWhere((_, v) => v.isEmpty);
          }
        }
      }
      await _migrateLegacyDevOverrideKeys();
      _loaded = true;
      _loadFailed = false;
    } catch (e) {
      // 读取失败绝不覆写磁盘（保留人工恢复机会），内存退化为无覆盖项
      debugPrint('[SMART-GROUP] ⚠️ 加载失败（保留磁盘数据，不覆写）: $e');
      _loadFailed = true;
      _loaded = true;
    }
  }

  /// 把 `dev:<原文>` 形态的旧覆盖项键迁移到 `devId:<id>`（会社归一化 Phase 2）。
  ///
  /// - 原文能在词典命中的：覆盖项整体搬到新键（重命名/置顶/隐藏全部保留），
  ///   新键已有值时**不覆盖**（putIfAbsent，先到先得）；
  /// - 命中不了的：保留旧键（该组今后只收未解析游戏，覆盖项继续生效）；
  /// - 迁移成功后落盘一次；失败仅留日志（内存已生效，下次 load 再试）。
  Future<void> _migrateLegacyDevOverrideKeys() async {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return;
    final hasLegacy = _overrides.keys.any((k) =>
        k.startsWith(kUnassignedDevKey) && k.length > kUnassignedDevKey.length);
    if (!hasLegacy) return;
    _overrides = migrateLegacyDevOverrideKeys(_overrides, store);
    debugPrint('[SMART-GROUP] 🔁 已把 dev:<原文> 覆盖项键迁移到 devId:<id>');
    await _persist();
  }

  /// 纯函数（便于单测）：把 `dev:<原文>` 形态的旧覆盖项键迁移为
  /// `devId:<id>`。原文能在词典命中的搬到新键（新键已有值时保留先到者），
  /// 命中不了的保留原键（该组今后只收未解析游戏，覆盖项继续生效）。
  @visibleForTesting
  static Map<String, SmartGroupOverride> migrateLegacyDevOverrideKeys(
    Map<String, SmartGroupOverride> overrides,
    CompanyAliasStore? store,
  ) {
    final migrated = <String, SmartGroupOverride>{};
    overrides.forEach((key, value) {
      if (store != null &&
          key.startsWith(kUnassignedDevKey) &&
          key.length > kUnassignedDevKey.length) {
        final match = store.resolve(key.substring(kUnassignedDevKey.length));
        if (match != null) {
          migrated.putIfAbsent(
              companyDevKey(match.record.companyId), () => value);
          return;
        }
      }
      migrated.putIfAbsent(key, () => value);
    });
    return migrated;
  }

  /// 重命名分组（仅改展示名，不动游戏数据）
  Future<void> renameGroup(String key, String? displayName) =>
      _updateOverride(key, (o) {
        final trimmed = displayName?.trim();
        return SmartGroupOverride(
          displayName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
          hidden: o?.hidden ?? false,
          pinned: o?.pinned ?? false,
        );
      });

  /// 置顶 / 取消置顶分组
  Future<void> setPinned(String key, bool pinned) => _updateOverride(
        key,
        (o) => SmartGroupOverride(
          displayName: o?.displayName,
          hidden: o?.hidden ?? false,
          pinned: pinned,
        ),
      );

  /// 隐藏 / 恢复显示分组
  Future<void> setHidden(String key, bool hidden) => _updateOverride(
        key,
        (o) => SmartGroupOverride(
          displayName: o?.displayName,
          hidden: hidden,
          pinned: o?.pinned ?? false,
        ),
      );

  /// 恢复某个分组的默认展示
  Future<void> clearOverride(String key) async {
    if (!_overrides.containsKey(key)) return;
    _overrides.remove(key);
    await _persist();
  }

  Future<void> _updateOverride(
    String key,
    SmartGroupOverride Function(SmartGroupOverride? old) build,
  ) async {
    final next = build(_overrides[key]);
    if (next.isEmpty) {
      _overrides.remove(key);
    } else {
      _overrides[key] = next;
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (_loadFailed) {
      // 磁盘上有无法解析的数据：拒绝覆写，只保留内存态（可人工修复后重启生效）
      debugPrint('[SMART-GROUP] ⛔ 跳过写盘：上次加载失败，避免覆写可恢复数据');
      _revision++;
      notifyListeners();
      return;
    }
    try {
      final file = File(_filePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = {
        'format_version': 1,
        'overrides':
            _overrides.map((k, v) => MapEntry(k, v.toJson())),
      };
      final tempPath =
          '$_filePath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert(data),
            flush: true);
        await tempFile.rename(_filePath);
      } catch (e) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      debugPrint('[SMART-GROUP] ⚠️ 保存失败: $e');
    }
    _revision++;
    notifyListeners();
  }

  /// 测试专用：清空内存态（不触碰磁盘）
  @visibleForTesting
  void resetForTest() {
    _overrides = {};
    _loaded = false;
    _loadFailed = false;
    _revision++;
  }
}
