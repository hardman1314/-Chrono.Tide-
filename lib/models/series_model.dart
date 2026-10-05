import '../core/pb_config.dart';

/// 系列关系类型（PB series_entries.relationType 字段的 9 种取值）
///
/// 核心约定：main / sequel = 主线（本篇→续作→续作的脊椎骨），
/// 其余 = 分支（挂在某部作品下的支线）；
/// standalone = 独立作品（不参与主线串联，按分支挂靠渲染）。
enum SeriesRelationType {
  main('本篇', true),
  sequel('续作', true),
  prequel('前传', false),
  sideStory('外传', false),
  spinOff('衍生作', false),
  fanDisc('粉丝盘', false),
  remake('重置版', false),
  standalone('独立', false),
  other('其他', false);

  final String label;
  final bool isMainline;

  const SeriesRelationType(this.label, this.isMainline);

  /// 从 PB select 字段值解析，未知值兜底为 other
  static SeriesRelationType fromValue(String? value) {
    switch (value) {
      case 'main':
        return SeriesRelationType.main;
      case 'sequel':
        return SeriesRelationType.sequel;
      case 'prequel':
        return SeriesRelationType.prequel;
      case 'side_story':
        return SeriesRelationType.sideStory;
      case 'spin_off':
        return SeriesRelationType.spinOff;
      case 'fan_disc':
        return SeriesRelationType.fanDisc;
      case 'remake':
        return SeriesRelationType.remake;
      case 'standalone':
        return SeriesRelationType.standalone;
      default:
        return SeriesRelationType.other;
    }
  }

  /// v2 关系词表（series_relations.relation）→ 展示用关系类型。
  /// 仅用于分支角标：seq/preq 只出现在主轴（由 role 决定），此处照映到同义标签。
  static SeriesRelationType fromV2(String? relation) {
    switch (relation) {
      case 'seq':
        return SeriesRelationType.sequel;
      case 'preq':
        return SeriesRelationType.prequel;
      case 'fan':
        return SeriesRelationType.fanDisc;
      case 'alt':
        return SeriesRelationType.remake;
      case 'altsetting':
        return SeriesRelationType.spinOff;
      case 'side':
        return SeriesRelationType.sideStory;
      default:
        return SeriesRelationType.other;
    }
  }
}

/// 系列模式（PB series.mode 字段）
///
/// - tree：作品间有主线/分支关系，客户端按树渲染（主线编号 + 分支挂靠）
/// - collection：独立合集（如"十二神器"），作品互相独立、平铺展示、不画连接线
enum SeriesMode {
  tree,
  collection;

  static SeriesMode fromValue(String? value) =>
      value == 'collection' ? SeriesMode.collection : SeriesMode.tree;

  /// v2 系列 kind → 渲染模式：anthology 平铺（等价旧 collection），
  /// story_line / worldview 按树渲染（主轴 + 分支）。
  static SeriesMode fromKind(String? kind) =>
      kind == 'anthology' ? SeriesMode.collection : SeriesMode.tree;
}

/// 系列元数据（PB series 集合）
class SeriesModel {
  final String id;
  final String title;
  final String description;
  final String coverUrl; // 完整 URL（拼自 {baseUrl}/api/files/series/{id}/{coverUrl}）
  final SeriesMode mode; // tree（缺省）/ collection

  const SeriesModel({
    required this.id,
    required this.title,
    this.description = '',
    this.coverUrl = '',
    this.mode = SeriesMode.tree,
  });

  factory SeriesModel.fromPBRecord(dynamic record) {
    String coverUrl = '';
    try {
      final file = record.getStringValue('coverUrl');
      if (file.isNotEmpty) {
        coverUrl = '${PBConfig.baseUrl}/api/files/series/${record.id}/$file';
      }
    } catch (_) {}

    return SeriesModel(
      id: record.id,
      title: _safeGetString(record, 'title'),
      description: _safeGetString(record, 'description'),
      coverUrl: coverUrl,
      mode: SeriesMode.fromValue(_safeGetString(record, 'mode')),
    );
  }

  /// v2 系列元数据（series_meta）解析。
  ///
  /// 与旧表的差异：coverUrl 是完整 URL 文本字段（非 PB 文件字段）；
  /// mode 由 kind 推导（anthology → collection）。
  factory SeriesModel.fromV2Record(dynamic record) {
    final cover = _safeGetString(record, 'coverUrl');
    return SeriesModel(
      id: record.id,
      title: _safeGetString(record, 'title'),
      description: _safeGetString(record, 'description'),
      coverUrl: cover.startsWith('http') ? cover : '',
      mode: SeriesMode.fromKind(_safeGetString(record, 'kind')),
    );
  }
}

/// 系列条目（PB series_entries 集合，树的边）
class SeriesEntryModel {
  final String id;
  final String seriesId;
  final String gameId;

  /// 父条目 id；null = 系列起点（根节点）
  final String? parentId;
  final SeriesRelationType relationType;
  final int sortOrder;

  // 展开的游戏轻量信息（用于横条/弹层展示，无需完整 GameModel）
  final String gameTitle;
  final String gameCoverUrl;

  /// v2 成员 role 原始值（main_axis / branch / extra）；旧表条目为 ''
  final String v2Role;

  /// v2 关系词原始值（series_relations.relation 十二值词表：seq/preq/fan/
  /// orig/alt/altsetting/side/par/set/same/char/ot）；主轴与旧表条目为 ''
  final String v2Relation;

  /// 发售日期（v2 member.releaseDate 优先，回落 game.releaseDate）；旧表为 ''
  final String releaseDate;

  const SeriesEntryModel({
    required this.id,
    required this.seriesId,
    required this.gameId,
    this.parentId,
    this.relationType = SeriesRelationType.other,
    this.sortOrder = 0,
    this.gameTitle = '',
    this.gameCoverUrl = '',
    this.v2Role = '',
    this.v2Relation = '',
    this.releaseDate = '',
  });

  /// 从 PB record 解析（gameRecord 为 expand 出的游戏记录）
  factory SeriesEntryModel.fromPBRecord(dynamic record, dynamic gameRecord) {
    return SeriesEntryModel(
      id: record.id,
      seriesId: _safeGetString(record, 'series'),
      gameId: gameRecord.id,
      parentId: _safeGetOptString(record, 'parent'),
      relationType:
          SeriesRelationType.fromValue(_safeGetString(record, 'relationType')),
      sortOrder: _safeGetInt(record, 'sortOrder'),
      gameTitle: _safeGetString(gameRecord, 'title'),
      gameCoverUrl: gameCoverUrlFromPB(gameRecord),
    );
  }

  /// v2 成员记录（series_members + expand.game）解析。
  ///
  /// v2 表没有 parent / relationType 字段：parentId 与关系语义由仓库层
  /// 依据 role（主轴串链）与 series_relations 关系边（分支锚定）推导后传入。
  /// [v2Role]/[v2Relation] 保留云端原始定位数据（精确定位系统展示用），
  /// [releaseDate] 供作品信息栏展示。
  factory SeriesEntryModel.fromV2Record(
    dynamic record,
    dynamic gameRecord, {
    String? parentId,
    required SeriesRelationType relationType,
    required int playOrder,
    String v2Role = '',
    String v2Relation = '',
    String releaseDate = '',
  }) {
    return SeriesEntryModel(
      id: record.id,
      seriesId: _safeGetString(record, 'series'),
      gameId: gameRecord.id,
      parentId: parentId,
      relationType: relationType,
      sortOrder: playOrder,
      gameTitle: _safeGetString(gameRecord, 'title'),
      gameCoverUrl: gameCoverUrlFromPB(gameRecord),
      v2Role: v2Role,
      v2Relation: v2Relation,
      releaseDate: releaseDate,
    );
  }

  /// v2 十二值关系词（series_relations.relation）→ 中文定位标签。
  ///
  /// 精确定位系统的核心词表（与整理工具/云端 schema 对齐）；
  /// 未知词返回 ''（调用方回落旧枚举 label）。
  static String v2RelationLabel(String relation) {
    switch (relation) {
      case 'seq':
        return '正统续作';
      case 'preq':
        return '前传';
      case 'fan':
        return 'FD';
      case 'orig':
        return '原作';
      case 'alt':
        return '重制版';
      case 'altsetting':
        return '衍生世界线';
      case 'side':
        return '外传';
      case 'par':
        return '本篇';
      case 'set':
        return '同世界观';
      case 'same':
        return '同系列';
      case 'char':
        return '共通角色';
      case 'ot':
        return '其他';
      default:
        return '';
    }
  }

  /// 精确定位标签：v2 原始关系词标签（十二值全量）优先，回落旧 9 值枚举 label。
  ///
  /// 主轴条目的「本篇/续作N」由 UI 依链内序号生成（[SeriesData.mainlineLabel]），
  /// 分支条目直接使用本标签（外传/FD/重制版/同世界观…）。
  String get preciseLabel {
    if (v2Relation.isNotEmpty) {
      final label = v2RelationLabel(v2Relation);
      if (label.isNotEmpty) return label;
    }
    return relationType.label;
  }
}

/// 从游戏 PB record 提取封面完整 URL（coverUrl / cover 文件字段兼容）。
String gameCoverUrlFromPB(dynamic gameRecord) {
  for (final field in ['coverUrl', 'cover']) {
    try {
      final file = gameRecord.getStringValue(field);
      if (file.isNotEmpty) {
        return '${PBConfig.baseUrl}/api/files/games/${gameRecord.id}/$file';
      }
    } catch (_) {}
  }
  return '';
}

/// 树节点：一个条目 + 挂在它下面的分支子树
class SeriesTreeNode {
  final SeriesEntryModel entry;
  final List<SeriesTreeNode> branches;

  const SeriesTreeNode({required this.entry, this.branches = const []});
}

/// 「系列相关」展示条目：作品 + 相对当前作品的定位角标 + 是否当前作品
class RelatedPick {
  final SeriesEntryModel entry;
  final String badge;
  final bool isCurrent;

  const RelatedPick(this.entry, this.badge, this.isCurrent);
}

/// 系列完整数据（系列元数据 + 条目 + 构建好的主线/分支树）
class SeriesData {
  final SeriesModel series;
  final List<SeriesEntryModel> entries;

  /// 平行主线链（tree 模式：parent=null 的每个根各成一条链，按根 sortOrder 排序；
  /// collection 模式：全部条目按 sortOrder 平铺为单条链）
  final List<List<SeriesTreeNode>> mainlines;

  const SeriesData({
    required this.series,
    required this.entries,
    required this.mainlines,
  });

  /// 合集模式：作品相互独立，无主线/分支语义
  bool get isCollectionMode => series.mode == SeriesMode.collection;

  /// 是否存在平行主线（多条根链）。
  ///
  /// 守卫：至少两条链**各含 ≥2 部主线作品**才算真平行主线——
  /// 单节点链多为数据异常或独立作品，此时提示"可任选一条开始"反而误导
  /// （例：甜蜜女友 2/3/SS 被误录成独立根，各自成链）。
  bool get hasParallelMainlines {
    if (isCollectionMode || mainlines.length < 2) return false;
    return mainlines.where((chain) => chain.length >= 2).length >= 2;
  }

  /// 扁平主线（兼容遍历：各链依序拼接）
  List<SeriesTreeNode> get mainline =>
      [for (final chain in mainlines) ...chain];

  /// 至少 2 部有效作品才有展示价值（"系列里只有自己"不显示）
  bool get hasMultipleEntries => entries.length > 1;

  /// 查某个游戏在系列中的条目
  SeriesEntryModel? entryForGame(String gameId) {
    for (final e in entries) {
      if (e.gameId == gameId) return e;
    }
    return null;
  }

  /// 当前游戏所在的主线链；不在任何链上返回 null
  List<SeriesTreeNode>? chainOf(String gameId) {
    for (final chain in mainlines) {
      for (final node in chain) {
        if (node.entry.gameId == gameId) return chain;
      }
    }
    return null;
  }

  /// 主线定位：当前游戏在其所在链中的下标（链内序号，平行主线互不干扰）；
  /// 不在任何链上返回 -1
  int mainlineIndexOf(String gameId) {
    for (final chain in mainlines) {
      for (var i = 0; i < chain.length; i++) {
        if (chain[i].entry.gameId == gameId) return i;
      }
    }
    return -1;
  }

  /// 主线锚点：当前游戏自身在主线则返回其节点；
  /// 在分支上则沿 parent 上溯最近的主线节点；找不到返回 null
  SeriesTreeNode? mainlineAnchorFor(String gameId) {
    if (chainOf(gameId) != null) {
      final idx = mainlineIndexOf(gameId);
      final chain = chainOf(gameId)!;
      return chain[idx];
    }
    final byId = {for (final e in entries) e.id: e};
    var cur = entryForGame(gameId);
    while (cur?.parentId != null) {
      final parent = byId[cur!.parentId!];
      if (parent == null) return null;
      final chain = chainOf(parent.gameId);
      if (chain != null) {
        final idx = mainlineIndexOf(parent.gameId);
        return chain[idx];
      }
      cur = parent;
    }
    return null;
  }

  /// 主线序号标签：链内第 0 部=本篇，之后=续作一 / 续作二…（链内编号）
  static String mainlineLabel(int index) =>
      index <= 0 ? '本篇' : '续作${_cnNumeral(index)}';

  /// 简易中文数字（系列长度不会太长，20 以上兜底阿拉伯数字）
  static String _cnNumeral(int n) {
    const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    if (n < 10) return digits[n];
    if (n < 20) return n % 10 == 0 ? '十' : '十${digits[n % 10]}';
    return '$n';
  }

  /// 扁平化展示顺序（建议游玩顺序）：
  /// 各链依次排列，每个主线节点之后紧跟其分支（含子分支）
  List<SeriesEntryModel> get displayOrder {
    final result = <SeriesEntryModel>[];
    void walkBranches(List<SeriesTreeNode> nodes) {
      for (final n in nodes) {
        result.add(n.entry);
        walkBranches(n.branches);
      }
    }

    for (final node in mainline) {
      result.add(node.entry);
      walkBranches(node.branches);
    }
    return result;
  }

  /// 详情页「系列相关」条目选取（纯函数，探针可测；UI 层 series_strip 消费）。
  ///
  /// 设计目标：只展示与当前作品定位**最密切**的作品，避免本篇页铺满全系列：
  /// - collection 模式：作品相互独立无「密切」概念 → 全部平铺（无角标）
  /// - tree 模式：以焦点节点（当前作品所在主轴节点；分支作品取其主线锚点）
  ///   为中心——紧邻前作 1 部 → 焦点 → 紧邻续作 1 部 → 焦点直接分支；
  ///   合计不足 3 部时放宽补足（先补后续方向、再补前作方向）
  List<RelatedPick> relatedSelection(String currentGameId) {
    final current = entryForGame(currentGameId);
    if (current == null) return const [];

    // 合集模式：平铺展示，无关系语义
    if (isCollectionMode) {
      final sorted = [...entries]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return [
        for (final e in sorted)
          RelatedPick(e, '', e.gameId == currentGameId)
      ];
    }

    final result = <RelatedPick>[];
    final seen = <String>{};
    void add(SeriesEntryModel e, String badge, bool isCur) {
      if (e.gameId.isEmpty || seen.contains(e.gameId)) return;
      seen.add(e.gameId);
      result.add(RelatedPick(e, badge, isCur));
    }

    // 以 chain[focusIdx] 为焦点收紧选取；currentInChain=焦点即当前作品
    void addChainFocus(
        List<SeriesTreeNode> chain, int focusIdx, bool currentInChain) {
      final preds = <SeriesEntryModel>[
        for (var i = focusIdx - 1; i >= 0; i--) chain[i].entry,
      ];
      final succs = <SeriesEntryModel>[
        for (var i = focusIdx + 1; i < chain.length; i++) chain[i].entry,
      ];
      // 紧邻前作（链内第 0 部显示「本篇」）
      if (preds.isNotEmpty) {
        add(preds.first, focusIdx - 1 == 0 ? '本篇' : '前作', false);
      }
      // 焦点节点：当前作品在主线上即当前作品本身（isCurrent）；
      // 在分支上即其主线锚点（最相关的作品，必须展示）
      add(chain[focusIdx].entry, mainlineLabel(focusIdx), currentInChain);
      // 紧邻续作
      if (succs.isNotEmpty) {
        add(succs.first, mainlineLabel(focusIdx + 1), false);
      }
      // 焦点直接分支（外传/FD/重制…精确定位标签）
      for (final b in chain[focusIdx].branches) {
        add(b.entry, b.entry.preciseLabel, b.entry.gameId == currentGameId);
      }
      // 补足到 3 部（先后续、再前作方向），避免本篇页只见孤零零 1-2 个
      var si = 1, pi = 1;
      while (result.length < 3) {
        if (si < succs.length) {
          add(succs[si], mainlineLabel(focusIdx + 1 + si), false);
          si++;
        } else if (pi < preds.length) {
          final pIdx = focusIdx - 1 - pi;
          add(preds[pi], pIdx == 0 ? '本篇' : '前作', false);
          pi++;
        } else {
          break;
        }
      }
    }

    final curChain = chainOf(currentGameId);
    if (curChain != null) {
      addChainFocus(curChain, mainlineIndexOf(currentGameId), true);
    } else {
      final anchor = mainlineAnchorFor(currentGameId);
      if (anchor != null) {
        final aChain = chainOf(anchor.entry.gameId);
        if (aChain != null) {
          addChainFocus(aChain, mainlineIndexOf(anchor.entry.gameId), false);
        } else {
          add(current, current.preciseLabel, true);
        }
      } else {
        // 数据异常兜底：只显示当前作品
        add(current, current.preciseLabel, true);
      }
    }
    return result;
  }

  /// 由平铺条目列表构建系列树
  ///
  /// **collection 模式**：不建树，全部条目按 sortOrder 平铺为单条链。
  ///
  /// **tree 模式**：
  /// - parent = null 的条目为根节点，多个根 = 平行主线（每个根独立成链）
  /// - 每条链：从根出发沿 main/sequel 子节点串联
  /// - 其余子节点为分支，挂在父节点下（按 sortOrder 排序）
  /// - 防御：环引用（visited 剪枝）、悬空 parent（视作根）、
  ///   不可达条目（各自成单节点链追加，保证不丢数据）
  static SeriesData build(SeriesModel series, List<SeriesEntryModel> entries) {
    // 合集模式：平铺，不建树
    if (series.mode == SeriesMode.collection) {
      final sorted = [...entries]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return SeriesData(
        series: series,
        entries: entries,
        mainlines: [
          [for (final e in sorted) SeriesTreeNode(entry: e)]
        ],
      );
    }

    // 按父节点分组
    final childrenOf = <String?, List<SeriesEntryModel>>{};
    for (final e in entries) {
      childrenOf.putIfAbsent(e.parentId, () => []).add(e);
    }
    for (final list in childrenOf.values) {
      list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }

    // 悬空 parent（指向不存在的条目）视作根
    final entryIds = entries.map((e) => e.id).toSet();
    final roots = <SeriesEntryModel>[
      ...?childrenOf[null],
      ...childrenOf.entries
          .where((kv) => kv.key != null && !entryIds.contains(kv.key))
          .expand((kv) => kv.value),
    ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (roots.isEmpty && entries.isNotEmpty) {
      // 全部条目互相成环等极端情况：按 sortOrder 全部视作根
      roots.addAll(entries..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)));
    }

    final visited = <String>{};

    // 递归收集以 entry 为根的分支子树（跳过主线后继）
    List<SeriesTreeNode> collectBranches(SeriesEntryModel parent) {
      final branches = <SeriesTreeNode>[];
      final children = childrenOf[parent.id] ?? const [];
      for (final child in children) {
        if (visited.contains(child.id)) continue;
        if (child.relationType.isMainline) continue; // 主线后继由脊椎负责
        visited.add(child.id);
        branches.add(SeriesTreeNode(
          entry: child,
          branches: collectBranches(child),
        ));
      }
      return branches;
    }

    // 平行主线：每个根独立走一条链（根 → 沿 main/sequel 子节点串联）
    final mainlines = <List<SeriesTreeNode>>[];
    for (final root in roots) {
      if (visited.contains(root.id)) continue;
      final chain = <SeriesTreeNode>[];
      SeriesEntryModel? current = root;
      while (current != null) {
        if (visited.contains(current.id)) break; // 环防御
        visited.add(current.id);
        chain.add(SeriesTreeNode(
          entry: current,
          branches: collectBranches(current),
        ));

        // 找下一个主线后继：当前节点的 main/sequel 子节点（按 sortOrder 取第一个）
        SeriesEntryModel? next;
        for (final child in childrenOf[current.id] ?? const []) {
          if (visited.contains(child.id)) continue;
          if (child.relationType.isMainline) {
            next = child;
            break;
          }
        }
        current = next;
      }
      if (chain.isNotEmpty) mainlines.add(chain);
    }

    // 不可达条目（数据异常）：各自成单节点链追加，保证不丢
    if (visited.length < entries.length) {
      final remaining = entries
          .where((e) => !visited.contains(e.id))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      for (final e in remaining) {
        visited.add(e.id);
        mainlines.add([
          SeriesTreeNode(entry: e, branches: collectBranches(e)),
        ]);
      }
    }

    return SeriesData(series: series, entries: entries, mainlines: mainlines);
  }
}

// --- PB record 安全读取工具 ---

String _safeGetString(dynamic record, String field) {
  try {
    return record.getStringValue(field);
  } catch (_) {
    return '';
  }
}

String? _safeGetOptString(dynamic record, String field) {
  final v = _safeGetString(record, field);
  return v.isEmpty ? null : v;
}

int _safeGetInt(dynamic record, String field) {
  try {
    final value = record.data[field];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  } catch (_) {
    return 0;
  }
}
