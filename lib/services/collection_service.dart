import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/path_helper.dart';

/// 收藏夹实体（用户自定义合集）
///
/// 分类本体（名称/颜色/图标/顺序）集中存放在全局 `data/collections.json`，
/// 成员关系存放在各游戏目录的 `game.json` 的 `collection_ids` 字段中，
/// 与项目"每个游戏目录自包含"的存储哲学保持一致。
///
/// 例外：**收藏夹内的成员显示顺序**（[gameOrder]）属"收藏夹维度"属性，
/// 无法分散表达在单个游戏文件里，故与本体的其余字段一并存在
/// `collections.json`；成员关系本身仍在游戏侧的 `collection_ids`。
class GameCollection {
  /// 图标类型常量
  static const String kIconBookmark = 'bookmark';
  static const String kIconGamepad = 'gamepad';
  static const String kIconStar = 'star';

  final String id;
  String name;
  /// ARGB 颜色值（int），取自 [CollectionService.palette] 固定色板
  int colorValue;
  int sortOrder;

  /// 是否置顶：置顶收藏夹永远排在列表最前（在两个预设收藏夹之后按 sortOrder 排列）
  ///
  /// 两个预设收藏夹（准备入手 / 特别关注）恒定置顶，[pinned] 对它们只作为
  /// 持久化冗余标记，[isPinnedTop] 会无条件返回 true，因此即便历史数据里
  /// 该字段缺失或被改写，也不会掉出置顶区。
  bool pinned;

  /// 图标类型：[kIconBookmark]（默认书签）/ [kIconGamepad]（手柄）/ [kIconStar]（星星）
  ///
  /// 影响侧栏条目前缀与卡片右上角书签角标的形状；
  /// 颜色始终跟随 [colorValue]。
  final String iconKind;

  /// 收藏夹内的成员显示顺序（仅本收藏夹维度，与全局手动顺序互不影响）
  ///
  /// 元素为游戏的 `LibraryGame.directoryPath`——与库页全局手动顺序复用同一套键，
  /// 不再引入第二套标识。未登记成员按全局顺序追加在尾部，故历史数据
  /// （缺字段 / 新增成员）**无需迁移**；空列表表示「未自定义」，
  /// 收藏夹内沿用全局游戏顺序。
  List<String> gameOrder;

  GameCollection({
    required this.id,
    required this.name,
    required this.colorValue,
    this.sortOrder = 0,
    this.iconKind = kIconBookmark,
    this.pinned = false,
    this.gameOrder = const [],
  });

  /// 是否属于预设收藏夹（准备入手 / 特别关注）
  bool get isPreset =>
      id == CollectionService.kPresetWishlistId ||
      id == CollectionService.kPresetStarredId;

  /// 是否处于置顶区：预设收藏夹恒为 true，普通收藏夹看 [pinned]
  bool get isPinnedTop => isPreset || pinned;

  /// 图标形状（颜色由调用方取 [colorValue] 渲染）
  IconData get icon {
    switch (iconKind) {
      case kIconGamepad:
        return Icons.sports_esports_rounded;
      case kIconStar:
        return Icons.star_rounded;
      case kIconBookmark:
      default:
        return Icons.bookmark_rounded;
    }
  }

  factory GameCollection.fromJson(Map<String, dynamic> json) {
    return GameCollection(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名收藏夹',
      colorValue: (json['color'] as num?)?.toInt() ??
          CollectionService.palette.first,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      iconKind: json['icon'] as String? ?? kIconBookmark,
      pinned: json['pinned'] as bool? ?? false,
      // 缺字段（老数据）读作空列表：表示"未自定义"，无需迁移
      gameOrder: ((json['game_order'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': colorValue,
        'sort_order': sortOrder,
        'icon': iconKind,
        'pinned': pinned,
        'game_order': gameOrder,
      };
}

/// 收藏夹服务：管理全局收藏夹列表（CRUD），单例 + ChangeNotifier
///
/// 成员关系（游戏 ↔ 收藏夹）由 [LocalGameRegistry] 负责，
/// 本服务只维护收藏夹本体。
class CollectionService extends ChangeNotifier {
  CollectionService._();

  static final CollectionService _instance = CollectionService._();
  static CollectionService get instance => _instance;

  /// 预设收藏夹「准备入手」固定 ID（手柄图标 · 墨黑）
  static const String kPresetWishlistId = 'preset_wishlist';
  /// 预设收藏夹「特别关注」固定 ID（星星图标 · 琥珀黄）
  static const String kPresetStarredId = 'preset_starred';

  /// 恒定置顶的预设收藏夹 ID（顺序即置顶区内的展示顺序）
  static const List<String> presetIds = [kPresetWishlistId, kPresetStarredId];

  /// 固定色板：不随主题派生，保证收藏夹色标在任何主题下语义稳定
  static const List<int> palette = [
    0xFFE05252, // 珊瑚红
    0xFFF08C2E, // 落日橙
    0xFFD9A514, // 琥珀黄
    0xFF67A86B, // 抹茶绿
    0xFF3FA7A0, // 青瓷
    0xFF4A90D9, // 晴空蓝
    0xFF7B6CD9, // 紫罗兰
    0xFFC75B9E, // 山茶粉
    0xFF8A7F6B, // 亚麻棕
    0xFF7A8899, // 青灰
    0xFF2F3437, // 墨黑
  ];

  static String get _filePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}collections.json';

  List<GameCollection> _collections = [];
  bool _loaded = false;
  bool _markMigrated = false;

  /// ★ P1-4b：最近一次 load() 是否因读取/解析失败而降级
  ///
  /// 为 true 时磁盘上的 collections.json 未被覆写，数据仍可人工恢复；
  /// 内存中收藏夹列表为空，UI 可据此给出"加载失败"提示而不是静默显示空列表。
  bool _loadFailed = false;

  /// 最近一次 load() 是否失败（磁盘数据保留，未被覆写）
  bool get loadFailed => _loadFailed;

  /// ★ P1-4c：串行化 _save() 的写队列
  ///
  /// create / rename / recolor / delete / _ensurePresetCollections 多个入口
  /// 可并发进入 _save()，共用同一个固定名 tmp 文件会互相截断拼接，
  /// 写坏 JSON 后下次 load() 再走 P1-4b 的失败分支。
  /// 与 GameDataFormat._writeQueues 同款 Future 链式排队写法。
  Future<void> _saveQueue = Future<void>.value();

  /// ★ P1-4c：临时文件自增序号，保证并发写时 tmp 文件名唯一
  int _tmpSeq = 0;

  /// 旧「标记」功能是否已迁移到「特别关注」收藏夹（一次性迁移标记位）
  bool get markMigrated => _markMigrated;

  Future<void> setMarkMigrated() async {
    if (_markMigrated) return;
    _markMigrated = true;
    await _save();
  }

  /// 展示顺序的收藏夹列表
  ///
  /// 排序规则（三级，逐级兜底）：
  /// 1. 分组：预设收藏夹 → 其他置顶收藏夹 → 普通收藏夹
  /// 2. 分组内：准备入手 → 特别关注 → 其他
  /// 3. sortOrder 升序，最后按 id 保证稳定
  ///
  /// 预设收藏夹由分组规则直接锁定前两位，不依赖 sortOrder 的具体取值，
  /// 因此即便历史数据里普通收藏夹占用了 0/1 序号、或序号为负数，
  /// 也不会被挤到下方。
  List<GameCollection> get collections => sortForDisplay(_collections);

  /// 纯函数版排序（供 UI 与单元测试复用，无 IO 依赖）
  static List<GameCollection> sortForDisplay(Iterable<GameCollection> source) {
    final list = List<GameCollection>.from(source);
    list.sort((a, b) {
      // 1) 分组：预设(0) → 置顶(1) → 普通(2)
      final g = _groupRank(a).compareTo(_groupRank(b));
      if (g != 0) return g;
      // 2) 预设内部次序：准备入手(0) → 特别关注(1) → 其他(2)
      final p = _presetRank(a).compareTo(_presetRank(b));
      if (p != 0) return p;
      // 3) sortOrder 升序 + id 兜底（保证排序稳定）
      final c = a.sortOrder.compareTo(b.sortOrder);
      if (c != 0) return c;
      return a.id.compareTo(b.id);
    });
    return list;
  }

  /// 列表分组位次：预设收藏夹(0) → 其他置顶收藏夹(1) → 普通收藏夹(2)
  static int _groupRank(GameCollection c) {
    if (c.isPreset) return 0;
    if (c.pinned) return 1;
    return 2;
  }

  /// 预设收藏夹的内部次序：准备入手(0) → 特别关注(1) → 其他(2)
  static int _presetRank(GameCollection c) {
    if (c.id == kPresetWishlistId) return 0;
    if (c.id == kPresetStarredId) return 1;
    return 2;
  }

  bool get isLoaded => _loaded;

  GameCollection? byId(String id) {
    if (id.isEmpty) return null;
    for (final c in _collections) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 幂等加载：读取 data/collections.json（不存在视为空列表），
  /// 并补建预设收藏夹（固定 ID，被删除后下次启动自动恢复）
  Future<void> load() async {
    if (_loaded) return;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        final list = (data['collections'] as List? ?? [])
            .map((e) => GameCollection.fromJson(e as Map<String, dynamic>))
            .toList();
        _collections = list;
        _markMigrated = data['mark_migrated'] as bool? ?? false;
      }
      _loaded = true;
      _loadFailed = false;
      await _ensurePresetCollections();
      notifyListeners();
    } catch (e) {
      // ★ P1-4b：加载失败时绝不清空内存列表、绝不调用 _ensurePresetCollections()
      // （其内部会立即 _save() 覆写磁盘）。一次瞬时读失败（文件被占用 / 落盘
      // 半途 / 杀软扫描）若触发覆写，用户全部收藏夹会被永久清空且无法恢复。
      // 此处只置降级标志：磁盘数据保持原样，重启或下次读取仍有机会恢复。
      debugPrint('[COLLECTION] ⚠️ 加载收藏夹失败（保留磁盘数据，不覆写）: $e');
      _loadFailed = true;
      _loaded = true;
      notifyListeners();
    }
  }

  /// 补建预设收藏夹：准备入手（手柄·墨黑）/ 特别关注（星星·琥珀黄）
  ///
  /// 两者恒为置顶（pinned=true），且占据 sortOrder 0/1。
  Future<void> _ensurePresetCollections() async {
    var changed = false;
    if (byId(kPresetWishlistId) == null) {
      _collections.add(GameCollection(
        id: kPresetWishlistId,
        name: '准备入手',
        colorValue: 0xFF2F3437, // 墨黑 → 黑色手柄
        sortOrder: 0,
        iconKind: GameCollection.kIconGamepad,
        pinned: true,
      ));
      changed = true;
    }
    if (byId(kPresetStarredId) == null) {
      _collections.add(GameCollection(
        id: kPresetStarredId,
        name: '特别关注',
        colorValue: 0xFFD9A514, // 琥珀黄 → 延续原小黄星语义
        sortOrder: 1,
        iconKind: GameCollection.kIconStar,
        pinned: true,
      ));
      changed = true;
    }
    // 老数据里预设可能缺 pinned 标记、或与普通收藏夹共用 0/1 序号，
    // 这里统一纠正，保证升级后预设仍稳定置顶
    final repaired = _normalizePinnedOrder();
    if (changed || repaired) await _save();
  }

  /// 校正置顶区的排序字段，返回是否发生改动
  ///
  /// 规则：
  /// - 两个预设收藏夹固定 pinned=true、sortOrder 0/1（缺失时同步补齐）
  /// - 其余收藏夹在保留现有相对顺序的前提下，从 2 开始连续重编号
  ///
  /// 这样无论历史数据里序号如何（重复、为 0/1、被删除产生空档），
  /// 预设收藏夹都稳定占据列表前两位。
  bool _normalizePinnedOrder() {
    final presetOrder = <String, int>{
      kPresetWishlistId: 0,
      kPresetStarredId: 1,
    };
    var changed = false;
    for (final c in _collections) {
      final fixed = presetOrder[c.id];
      if (fixed == null) continue;
      if (c.sortOrder != fixed) {
        c.sortOrder = fixed;
        changed = true;
      }
      if (!c.pinned) {
        c.pinned = true;
        changed = true;
      }
    }

    final rest = _collections
        .where((c) => !presetOrder.containsKey(c.id))
        .toList()
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        if (c != 0) return c;
        return a.id.compareTo(b.id);
      });
    var order = presetOrder.length; // 从 2 开始
    for (final c in rest) {
      if (c.sortOrder != order) {
        c.sortOrder = order;
        changed = true;
      }
      order++;
    }
    return changed;
  }

  /// 下一个可用的 sortOrder（取当前最大值 +1，避免与既有收藏夹碰撞）
  ///
  /// 不采用 `_collections.length`：删除收藏夹后长度会回落，
  /// 新建项会与幸存项撞号，最终退化为按 id 字典序排列（不稳定）。
  int _nextSortOrder() {
    var max = 1; // 0/1 由两个预设收藏夹占用
    for (final c in _collections) {
      if (c.sortOrder > max) max = c.sortOrder;
    }
    return max + 1;
  }

  /// 新建收藏夹，返回创建后的实体（普通收藏夹，不置顶，排在置顶区之后）
  Future<GameCollection> create(String name, int colorValue) async {
    final id = _generateId();
    final collection = GameCollection(
      id: id,
      name: name.trim().isEmpty ? '未命名收藏夹' : name.trim(),
      colorValue: palette.contains(colorValue) ? colorValue : palette.first,
      sortOrder: _nextSortOrder(),
      pinned: false,
    );
    _collections.add(collection);
    await _save();
    notifyListeners();
    return collection;
  }

  Future<bool> rename(String id, String newName) async {
    final c = byId(id);
    if (c == null) return false;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == c.name) return trimmed == c.name;
    c.name = trimmed;
    await _save();
    notifyListeners();
    return true;
  }

  Future<bool> recolor(String id, int colorValue) async {
    final c = byId(id);
    if (c == null || c.colorValue == colorValue) return c != null;
    c.colorValue = palette.contains(colorValue) ? colorValue : c.colorValue;
    await _save();
    notifyListeners();
    return true;
  }

  /// 删除收藏夹本体。成员引用清理由调用方通过
  /// LocalGameRegistry.removeCollectionReferences 完成。
  ///
  /// 删除后重排剩余收藏夹的序号，置顶区不受影响。
  Future<void> delete(String id) async {
    _collections.removeWhere((c) => c.id == id);
    await _save();
    notifyListeners();
  }

  /// 设置普通收藏夹的置顶状态
  ///
  /// 预设收藏夹（准备入手 / 特别关注）恒定置顶，拒绝取消置顶，
  /// 返回 false 表示未发生变更。
  Future<bool> setPinned(String id, bool pinned) async {
    final c = byId(id);
    if (c == null) return false;
    if (c.isPreset && !pinned) return false;
    if (c.pinned == pinned) return true;
    c.pinned = pinned;
    await _save();
    notifyListeners();
    return true;
  }

  /// 指定收藏夹是否处于置顶区
  bool isPinnedTop(String id) {
    final c = byId(id);
    return c?.isPinnedTop ?? false;
  }

  // ==================== 收藏夹内成员顺序（game_order） ====================

  /// 写入收藏夹内的成员顺序（元素为游戏 `directoryPath`）。
  ///
  /// 由库页在「收藏夹视图 + 手动排序」下拖拽时调用；空列表表示"未自定义"
  /// （回到全局顺序）。写入走统一 [_save]，与 ADR-003 的置顶规整共存。
  Future<void> setGameOrder(String id, List<String> order) async {
    final c = byId(id);
    if (c == null) return;
    final normalized = _sanitizeOrder(order);
    if (_sameOrder(c.gameOrder, normalized)) return;
    c.gameOrder = normalized;
    await _save();
    notifyListeners();
  }

  /// 清空收藏夹内自定义顺序 → 回到全局游戏顺序
  Future<void> resetGameOrder(String id) async {
    final c = byId(id);
    if (c == null || c.gameOrder.isEmpty) return;
    c.gameOrder = const [];
    await _save();
    notifyListeners();
  }

  /// 用「当前有效成员」裁剪顺序表（移出收藏夹 / 已删除的游戏留下的键会被清掉）。
  ///
  /// 有效集合由调用方提供——本服务刻意不依赖游戏注册表（保持单向依赖）。
  Future<void> pruneGameOrder(String id, Set<String> validPaths) async {
    final c = byId(id);
    if (c == null || c.gameOrder.isEmpty) return;
    final pruned = c.gameOrder.where(validPaths.contains).toList();
    if (pruned.length == c.gameOrder.length) return;
    c.gameOrder = pruned;
    await _save();
    notifyListeners();
  }

  /// 顺序表清洗：去空串、去重（保留首次出现的位置）
  static List<String> _sanitizeOrder(List<String> order) {
    final seen = <String>{};
    final result = <String>[];
    for (final p in order) {
      if (p.isEmpty || !seen.add(p)) continue;
      result.add(p);
    }
    return result;
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 原子写入：先写临时文件再 rename，与 GameDataFormat 的 C3 策略一致
  ///
  /// ★ P1-4c：整个写盘过程串行化，且 tmp 文件名唯一（进程内自增 + 微秒时间戳）。
  /// tmp 必须与目标文件同目录，rename 的原子性依赖同一分区。
  Future<void> _save() async {
    // 排队：保证同一时刻只有一个 _save() 在写盘
    final previous = _saveQueue;
    final completer = Completer<void>();
    _saveQueue = completer.future;
    await previous;

    try {
      // 落盘前统一校正：任何写入路径（新建/重命名/改色/删除/预设补建）
      // 都保证内存与磁盘上存的都是规范顺序，避免脏序号累积导致置顶失效
      _normalizePinnedOrder();
      _collections = sortForDisplay(_collections);
      final file = File(_filePath);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final data = {
        'format_version': 1,
        'mark_migrated': _markMigrated,
        'collections': _collections.map((c) => c.toJson()).toList(),
      };
      final content = JsonEncoder.withIndent('  ').convert(data);
      // 唯一 tmp 名：与 _filePath 同目录（前缀即目标路径），仅追加后缀
      final tempPath =
          '$_filePath.${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(content, flush: true);
        await tempFile.rename(_filePath);
      } catch (e) {
        // 清理残留 tmp，避免堆积与下次误读
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      debugPrint('[COLLECTION] ⚠️ 保存收藏夹失败: $e');
    } finally {
      completer.complete();
    }
  }

  String _generateId() {
    final rng = math.Random();
    final suffix = List<int>.generate(4, (_) => rng.nextInt(0xFFFF))
        .map((b) => b.toRadixString(16).padLeft(4, '0'))
        .join();
    return 'c_${DateTime.now().millisecondsSinceEpoch}_$suffix';
  }
}
