import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/collection_service.dart';
import '../../services/game_data_format.dart';
import '../../services/game_storage_state_controller.dart';
import '../../services/local_game_registry.dart';
import '../../services/company_alias_store.dart'; // ★ 会社归一化（v4）：别名检索
import '../../services/company_wall_store.dart'; // 分类匣·会社墙
import '../../services/library_smart_group_service.dart'; // 分类匣·会社过滤（SmartGroup.matches）
import '../../services/tag_vocabulary_store.dart'; // 分类匣·标签库派生
import '../../services/manifest_service.dart';
import '../../theme/app_styles.dart';
import '../../widgets/library/category_box_sidebar.dart'
    // 分类匣数据模型 + 会社 tint（仅取模型，不引桌面 UI）
    show
        CategoryBoxCompany,
        CategoryBoxTag,
        CategoryBoxTagSection,
        companyTintFor;
import '../../widgets/nsfw/nsfw_image.dart';
import '../../widgets/save_backup_dialog.dart';
import '../big_picture_theme.dart';
import '../focus/bpm_zone_focus_controller.dart';
import '../widgets/bpm_category_box_panel.dart';
import '../widgets/bpm_collection_picker.dart';
import '../widgets/bpm_context_menu.dart';
import '../widgets/bpm_focus_domain.dart';
import '../widgets/bpm_action_hint_badge.dart';
import '../widgets/bpm_trigger_page_hint.dart';
import '../widgets/bpm_focus_zone.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// 我的库 — v3 Cinema 重构 (收藏展示柜 poster wall)
///
/// 借鉴 gal-launcher Cinema 主题「收藏展示柜」:
/// - 顶部工具栏: 搜索 + 排序 + 分类匣入口 (+ 活动筛选 pill)
/// - 分类匣面板 (右侧滑入, 与桌面版三视图一致: 收藏夹/标签库/会社墙)
/// - 海报墙 (竖版封面网格,徽章 + 标题/会社)
/// - 游戏成员管理 (右键菜单 → BpmCollectionPicker)
class BigPictureLibraryPage extends StatefulWidget {
  /// 左键单击 → 右侧滑出详情面板 (gal-launcher Cinema 式)
  final ValueChanged<LibraryGame> onShowDetailPanel;

  /// 启动游戏 (双击海报)
  final ValueChanged<LibraryGame> onGameLaunch;

  /// 长按海报 → 动作表 (触屏入口)
  final ValueChanged<LibraryGame>? onGameLongPress;

  /// 启动管理 (右键菜单项,Shell 实现)
  final ValueChanged<LibraryGame>? onLaunchManager;

  /// 删除游戏 (右键菜单项,Shell 透传 MainContainer)
  final ValueChanged<LibraryGame>? onDeleteGame;

  /// 外部传入搜索焦点 (Shell Ctrl+F)
  final FocusNode? searchFocusNode;

  /// v3.9 手柄: 焦点落到哪张海报时上报 —— shell 据此决定 X(动作菜单)/
  /// Y(标记) 键作用于哪部作品。焦点即作用对象, 避免"按了没反应"。
  final ValueChanged<LibraryGame>? onGameFocused;

  /// 分类匣面板开关（与 shell 共享同一 notifier）：
  /// shell 的手柄 B / LB-RB 分支写 false，本页监听后收面板并回锚焦点。
  final ValueNotifier<bool>? categoryBoxOpen;

  const BigPictureLibraryPage({
    super.key,
    required this.onShowDetailPanel,
    required this.onGameLaunch,
    this.onGameLongPress,
    this.onLaunchManager,
    this.onDeleteGame,
    this.searchFocusNode,
    this.onGameFocused,
    this.categoryBoxOpen,
  });

  @override
  State<BigPictureLibraryPage> createState() => _BigPictureLibraryPageState();
}

enum _SortMode { recentPlay, name, installed }

class _BigPictureLibraryPageState extends State<BigPictureLibraryPage> {
  String _query = '';
  _SortMode _sortMode = _SortMode.recentPlay;

  /// 当前筛选收藏夹 (null = 所有游戏)
  String? _selectedCollectionId;

  /// 分类匣面板是否展开（开关真源 = [widget.categoryBoxOpen] notifier，
  /// 本字段只驱动本页 UI 重建）
  bool _categoryBoxPanelOpen = false;

  /// 分类匣·标签库多选键（`concept:<id>` / `tag:<原文>`；
  /// 过滤口径 = 维度内并集 · 维度间交集，与桌面库页一致）
  final Set<String> _activeTagKeys = <String>{};

  /// 分类匣·会社过滤键（`devId:<id>` / `dev:<名称>`；'' = 未进入）
  String _activeSmartGroupKey = '';

  /// 面板首行焦点（打开时移入面板，保证方向键作用于面板遍历组）
  final FocusNode _panelLeadFocus =
      FocusNode(debugLabel: 'bpmCategoryBoxLead');

  /// 「分类匣」按钮焦点（面板关闭后回锚，防焦点悬空在已收起的面板里）
  final FocusNode _categoryBtnFocus = FocusNode(debugLabel: 'bpmCategoryBtn');

  // ── 分类匣派生缓存（与桌面库页同款 hash 缓存）──
  int _gamesFp = 0; // 游戏列表指纹（_onChanged 时刷新）
  int _tagSectionsHash = 0;
  List<CategoryBoxTagSection> _tagSectionsCache = const [];
  int _companyCardsHash = 0;
  List<CategoryBoxCompany> _companyCardsCache = const [];
  int _smartGroupsHash = 0;
  List<SmartGroup> _smartGroupsCache = const [];

  @override
  void initState() {
    super.initState();
    LocalGameRegistry.instance.addListener(_onChanged);
    CollectionService.instance.addListener(_onChanged);
    CompanyWallStore.instance.addListener(_onChanged);
    SmartGroupService.instance.addListener(_onChanged);
    widget.categoryBoxOpen?.addListener(_onCategoryBoxSync);
    // 收藏夹数据异步加载 (幂等)
    CollectionService.instance.load();
    _refreshGamesFingerprint();
  }

  @override
  void dispose() {
    _dismissContextMenu();
    LocalGameRegistry.instance.removeListener(_onChanged);
    CollectionService.instance.removeListener(_onChanged);
    CompanyWallStore.instance.removeListener(_onChanged);
    SmartGroupService.instance.removeListener(_onChanged);
    widget.categoryBoxOpen?.removeListener(_onCategoryBoxSync);
    // 页面销毁时若面板还开着，复位共享开关（shell 的 B 键分支不再误判）
    if (widget.categoryBoxOpen?.value ?? false) {
      widget.categoryBoxOpen?.value = false;
    }
    _panelLeadFocus.dispose();
    _categoryBtnFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      _refreshGamesFingerprint();
      setState(() {});
    }
  }

  /// 游戏列表指纹：标签/会社派生缓存的失效键（O(n)，仅监听器触发时重算）
  void _refreshGamesFingerprint() {
    final games = LocalGameRegistry.instance.allGames;
    var h = games.length;
    for (final g in games) {
      h = h * 31 + g.title.hashCode + g.tags.length;
    }
    _gamesFp = h;
  }

  /// shell（手柄 B / LB-RB）把共享开关写 false → 同步收面板
  void _onCategoryBoxSync() {
    if (!(widget.categoryBoxOpen?.value ?? false) && _categoryBoxPanelOpen) {
      _closeCategoryBox();
    }
  }

  // ============ 数据派生 ============

  List<GameCollection> get _collections =>
      CollectionService.instance.collections;

  List<LibraryGame> get _allGames => LocalGameRegistry.instance.allGames;

  /// 经别名词典命中的 company_id 集合（BPM 搜索用；词典未加载返回空集）
  ///
  /// 与桌面库页 `_companyIdsForQuery` 同口径：搜「雪碧社」→ sprite 的 id。
  Set<int> _companyIdsForQuery(String query) {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return const {};
    return store.search(query, limit: 50).map((r) => r.companyId).toSet();
  }

  // ==================== 分类匣：派生（收藏夹以外两视图） ====================

  /// 智能分组（会社等；缓存：列表指纹 / 覆盖项 revision 变化才重算）
  List<SmartGroup> get _smartGroups {
    final hash = Object.hash(
      _gamesFp,
      SmartGroupService.instance.revision,
    );
    if (hash != _smartGroupsHash) {
      _smartGroupsHash = hash;
      _smartGroupsCache = SmartGroupService.instance.buildGroups(_allGames);
    }
    return _smartGroupsCache;
  }

  SmartGroup? _smartGroupByKey(String key) {
    for (final g in _smartGroups) {
      if (g.key == key) return g;
    }
    return null;
  }

  /// 标签库分区（结构 = 受控词表维度 + 「其他」；只展示库内有命中的条目，
  /// 与桌面库页 `_tagSections` 同口径）
  ///
  /// 联动口径（2026-10-04）：derive 输入 = 收藏夹 ∩ 会社过滤后集合
  /// （排除标签维度防自反馈）；已选中标签计数归 0 保留显示。
  List<CategoryBoxTagSection> get _tagSections {
    final vocab = TagVocabularyStore.instanceOrNull;
    final hash = Object.hash(
      _gamesFp,
      SmartGroupService.instance.revision,
      vocab?.concepts.length ?? 0,
      // 联动口径：收藏夹/会社上下文变化 → 标签计数重算
      _selectedCollectionId,
      _activeSmartGroupKey,
      (List.of(_activeTagKeys)..sort()).join('\x00'),
    );
    if (hash != _tagSectionsHash) {
      _tagSectionsHash = hash;
      final derivation = TagVocabularyStore.derive(
        _contextGames(excludeTags: true).map((g) => g.tags),
        vocab,
      );
      final sections = <CategoryBoxTagSection>[];
      if (vocab != null) {
        for (final dim in vocab.dimensions) {
          final tags = <CategoryBoxTag>[];
          for (final c in vocab.concepts) {
            if (c.dimensionId != dim.id) continue;
            final count = derivation.countOf(c.id);
            // 联动：0 成员不展示，但已选中的标签保留
            if (count <= 0 && !_activeTagKeys.contains(c.key)) continue;
            final ov = SmartGroupService.instance
                .overrideOf(SmartGroupService.tagKey(c.name));
            if (ov?.hidden ?? false) continue;
            final custom = ov?.displayName;
            tags.add(CategoryBoxTag(
              key: c.key,
              name: (custom != null && custom.isNotEmpty) ? custom : c.name,
              count: count,
              dotColor: dim.color,
              selected: _activeTagKeys.contains(c.key),
            ));
          }
          if (tags.isEmpty) continue; // 维度无成员 → 隐藏
          tags.sort((a, b) {
            final c = b.count.compareTo(a.count);
            return c != 0 ? c : a.name.compareTo(b.name);
          });
          sections.add(CategoryBoxTagSection(title: dim.title, tags: tags));
        }
      }
      // 其他：未命中词表的原始标签（封顶 80 条，避免超长列表）
      final others = <CategoryBoxTag>[
        for (final u in derivation.unclassified.take(80))
          CategoryBoxTag(
            key: SmartGroupService.tagKey(u.name),
            name: u.name,
            count: u.count,
            selected:
                _activeTagKeys.contains(SmartGroupService.tagKey(u.name)),
          ),
      ];
      if (others.isNotEmpty) {
        sections.add(CategoryBoxTagSection(title: '其他', tags: others));
      }
      _tagSectionsCache = sections;
    }
    return _tagSectionsCache;
  }

  /// 会社墙卡片（纯派生：库内有作品的词典会社数量降序 → 自定义会社；
  /// 与桌面库页 `_companyCards` 同口径）
  ///
  /// 联动口径（2026-10-04）：计数 = 收藏夹 ∩ 标签过滤后集合
  /// （排除会社维度防自反馈）。
  List<CategoryBoxCompany> get _companyCards {
    final wall = CompanyWallStore.instance;
    final store = CompanyAliasStore.instanceOrNull;
    final hash = Object.hash(
      _gamesFp,
      wall.revision,
      store?.companyCount ?? 0,
      // 联动口径：标签/收藏夹上下文变化 → 会社计数重算
      _selectedCollectionId,
      (List.of(_activeTagKeys)..sort()).join('\x00'),
    );
    if (hash != _companyCardsHash) {
      _companyCardsHash = hash;
      // 各会社成员计数（一次遍历，联动上下文）
      final countByCompanyId = <int, int>{};
      final countByDevName = <String, int>{};
      for (final game in _contextGames(excludeCompany: true)) {
        final dev = game.developer.trim();
        if (game.companyId != null) {
          countByCompanyId[game.companyId!] =
              (countByCompanyId[game.companyId!] ?? 0) + 1;
        } else if (dev.isNotEmpty) {
          countByDevName[dev] = (countByDevName[dev] ?? 0) + 1;
        }
      }
      CategoryBoxCompany buildCompany(CompanyRecord rec) {
        final storeKey = rec.companyId.toString();
        final key = SmartGroupService.companyDevKey(rec.companyId);
        final cn = (rec.cnName ?? '').trim();
        final standardName = rec.standardName;
        final name =
            wall.displayNameOf(storeKey) ?? (cn.isNotEmpty ? cn : standardName);
        final sub = cn.isNotEmpty
            ? standardName
            : ((rec.jpName?.trim().isNotEmpty ?? false) &&
                    rec.jpName?.trim() != standardName)
                ? rec.jpName!.trim()
                : '';
        final logoJp = rec.jpName?.trim() ?? '';
        final logoText = (logoJp.isNotEmpty &&
                logoJp != standardName &&
                logoJp.length <= 4)
            ? logoJp
            : standardName.split(' ').first;
        final tint = companyTintFor(key);
        return CategoryBoxCompany(
          key: key,
          name: name,
          subName: sub,
          logoText: logoText,
          logoBg: tint.$1,
          logoFg: tint.$2,
          gameCount: countByCompanyId[rec.companyId] ?? 0,
          followed: wall.isFollowed(storeKey),
          logoPath: wall.logoPathOf(storeKey),
        );
      }

      // ①②③ 合并生成（与桌面库页 _companyCards 同口径，2026-10-04）：
      // ① 词典会社；② companyId 词典缩水兜底「会社#id」；③ 词典未命中
      // 的 developer 原文会社（如 imel）——会社墙目标 = 整理库内全部会社。
      final pending =
          <({CategoryBoxCompany card, int count, String sortName})>[];
      final customNames =
          wall.customCompanies.map((c) => c.name).toSet();

      final derived = <CompanyRecord>[];
      for (final id in countByCompanyId.keys) {
        final rec = store?.byId(id);
        if (rec != null) {
          derived.add(rec);
          continue;
        }
        final key = SmartGroupService.companyDevKey(id);
        final tint = companyTintFor(key);
        final name = '会社#$id';
        pending.add((
          card: CategoryBoxCompany(
            key: key,
            name: name,
            subName: '',
            logoText: name,
            logoBg: tint.$1,
            logoFg: tint.$2,
            gameCount: countByCompanyId[id] ?? 0,
            followed: wall.isFollowed(id.toString()),
            logoPath: wall.logoPathOf(id.toString()),
          ),
          count: countByCompanyId[id] ?? 0,
          sortName: name,
        ));
      }
      for (final rec in derived) {
        pending.add((
          card: buildCompany(rec),
          count: countByCompanyId[rec.companyId] ?? 0,
          sortName: rec.standardName,
        ));
      }
      // ③ 词典未命中的原文会社（跳过已被自定义会社占用的名字）
      for (final entry in countByDevName.entries) {
        final dev = entry.key;
        if (customNames.contains(dev)) continue;
        final key = SmartGroupService.devKey(dev);
        final tint = companyTintFor(key);
        pending.add((
          card: CategoryBoxCompany(
            key: key,
            name: dev,
            subName: '',
            logoText: dev.characters.first.toUpperCase(),
            logoBg: tint.$1,
            logoFg: tint.$2,
            gameCount: entry.value,
            followed: false,
            logoPath: wall.logoPathOf(key),
          ),
          count: entry.value,
          sortName: dev,
        ));
      }
      pending.sort((a, b) {
        final c = b.count.compareTo(a.count);
        if (c != 0) return c;
        return a.sortName.compareTo(b.sortName);
      });
      final cards = <CategoryBoxCompany>[
        for (final p in pending) p.card,
      ];
      // ② 自定义会社（按 developer 原文精确匹配计数）
      for (final custom in wall.customCompanies) {
        final key = SmartGroupService.devKey(custom.name);
        final tint = companyTintFor(custom.id);
        cards.add(CategoryBoxCompany(
          key: key,
          name: wall.displayNameOf(custom.id) ?? custom.name,
          subName: custom.subName,
          logoText: custom.name.characters.first.toUpperCase(),
          logoBg: tint.$1,
          logoFg: tint.$2,
          gameCount: countByDevName[custom.name] ?? 0,
          followed: wall.isFollowed(custom.id),
          isCustom: true,
          logoPath: wall.logoPathOf(custom.id),
        ));
      }
      _companyCardsCache = cards;
    }
    return _companyCardsCache;
  }

  /// 分类匣联动（2026-10-04，对齐桌面）：按「排除某维度」组合过滤游戏集。
  ///
  /// 三维度（收藏夹 / 会社 / 标签）叠加；`exclude*` 维度不参与过滤——
  /// **派生计数专用**：排除自身维度防自反馈（选了标签后标签库瞬间清空）。
  /// 搜索不属于分类匣三维度，不参与。
  List<LibraryGame> _contextGames({
    bool excludeCollection = false,
    bool excludeCompany = false,
    bool excludeTags = false,
  }) {
    var games = _allGames;
    if (!excludeCollection && _selectedCollectionId != null) {
      final cid = _selectedCollectionId!;
      games = games.where((g) => g.collectionIds.contains(cid)).toList();
    }
    if (!excludeCompany && _activeSmartGroupKey.isNotEmpty) {
      final group = _smartGroupByKey(_activeSmartGroupKey);
      games =
          group == null ? <LibraryGame>[] : games.where(group.matches).toList();
    }
    if (!excludeTags && _activeTagKeys.isNotEmpty) {
      games = _applyTagKeyFilter(games);
    }
    return games;
  }

  /// 分类匣·标签库过滤（**维度内并集 · 维度间交集**）。
  /// 选中键 = `concept:<概念id>`（维度归属固定）或 `tag:<原始标签>`（未归类）。
  List<LibraryGame> _applyTagKeyFilter(Iterable<LibraryGame> games) {
    final vocab = TagVocabularyStore.instanceOrNull;
    final conceptsByDim = <String, Set<String>>{};
    final unclassifiedNorms = <String>{};
    for (final key in _activeTagKeys) {
      if (key.startsWith(TagVocabularyStore.kConceptKeyPrefix)) {
        final id = key.substring(TagVocabularyStore.kConceptKeyPrefix.length);
        final concept = vocab?.conceptById(id);
        if (concept == null) continue;
        conceptsByDim
            .putIfAbsent(concept.dimensionId, () => <String>{})
            .add(id);
      } else if (key.startsWith(SmartGroupService.tagKeyPrefix)) {
        final raw = key.substring(SmartGroupService.tagKeyPrefix.length);
        final n = TagVocabularyStore.normalizeTag(raw);
        if (n.isNotEmpty) unclassifiedNorms.add(n);
      }
    }
    return games.where((g) {
      final ids = TagVocabularyStore.conceptIdsOfGame(g.tags, vocab);
      if (!TagVocabularyStore.matchesSelection(ids, conceptsByDim)) {
        return false;
      }
      if (unclassifiedNorms.isNotEmpty) {
        final has = g.tags.any((t) =>
            unclassifiedNorms.contains(TagVocabularyStore.normalizeTag(t)));
        if (!has) return false;
      }
      return true;
    }).toList();
  }

  /// 当前筛选 + 搜索 + 排序后的海报墙列表
  List<LibraryGame> get _wallGames {
    // 分类匣联动：收藏夹 ∩ 会社 ∩ 标签 组合过滤（三维度叠加）
    var games = _contextGames();
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      // ★ 会社归一化（v4）：会社匹配 = 归一化文本 + 别名词典命中的 company_id，
      //   与桌面库页同口径——BPM 搜「雪碧社」也能命中 developer 原文是 sprite 的游戏
      final nq = CompanyAliasStore.normalize(_query);
      final aliasCompanyIds = _companyIdsForQuery(_query);
      games = games.where((g) {
        if (g.title.toLowerCase().contains(q)) return true;
        if (g.subtitle.toLowerCase().contains(q)) return true;
        if (nq.isNotEmpty &&
            CompanyAliasStore.normalize(g.developer).contains(nq)) return true;
        if (g.companyId != null && aliasCompanyIds.contains(g.companyId)) {
          return true;
        }
        return g.tags.any((t) => t.toLowerCase().contains(q));
      }).toList();
    }
    switch (_sortMode) {
      case _SortMode.recentPlay:
        games.sort((a, b) {
          final aT = DateTime.tryParse(a.lastOpenedAt);
          final bT = DateTime.tryParse(b.lastOpenedAt);
          if (aT != null && bT != null) return bT.compareTo(aT);
          if (aT != null) return -1;
          if (bT != null) return 1;
          return b.installedAt.compareTo(a.installedAt);
        });
        break;
      case _SortMode.name:
        games.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SortMode.installed:
        games.sort((a, b) => b.installedAt.compareTo(a.installedAt));
        break;
    }
    return games;
  }

  String? _resolveCoverPath(LibraryGame game) {
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return game.coverUrl;
    }
    try {
      return GameDataFormat.findCoverFile(game.pathForCover)?.path;
    } catch (_) {
      return null;
    }
  }

  // ============ 构建 ============

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
      padding: EdgeInsets.fromLTRB(
        BigPictureTheme.pagePadding,
        BigPictureTheme.topBarHeight + 18,
        BigPictureTheme.pagePadding,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── v3.10 二级板块 ①「顶部筛选操作板块」(独立焦点域 + 板块高亮) ──
          BpmFocusZone(
            zone: BpmZoneId.libraryTools,
            expand: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: BpmFocusDomain(
              zone: BpmZoneId.libraryTools,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 工具栏
                  Row(
                    children: [
                      _buildSearchPill(),
                      const SizedBox(width: 14),
                      _buildSortButton(),
                      if (_hasActiveCategoryFilter) ...[
                        const SizedBox(width: 10),
                        _buildActiveFilterPill(),
                      ],
                      const Spacer(),
                      _buildManageCollectionsButton(),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // ── v3.10 二级板块 ②「游戏卡片列表板块」(海报墙, 与操作区物理隔离) ──
          Expanded(
            child: BpmFocusZone(
              zone: BpmZoneId.libraryWall,
              expand: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: BpmFocusDomain(
                zone: BpmZoneId.libraryWall,
                child: _buildPosterWall(),
              ),
            ),
          ),
        ],
      ),
    ),

        // ── 分类匣面板：scrim（点击关闭）+ 右侧滑入面板 ──
        // 常驻挂载（收起 = 宽度动画到 0 + IgnorePointer），保证关面板有退场动画。
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_categoryBoxPanelOpen,
            child: GestureDetector(
              onTap: _closeCategoryBox,
              child: ColoredBox(
                color: BpmColors.scrimStrong
                    .withOpacity(_categoryBoxPanelOpen ? 0.35 : 0),
              ),
            ),
          ),
        ),
        Positioned(
          top: BigPictureTheme.topBarHeight + 18,
          bottom: 20,
          right: BigPictureTheme.pagePadding,
          child: BpmCategoryBoxPanel(
            open: _categoryBoxPanelOpen,
            leadFocusNode: _panelLeadFocus,
            // —— 收藏夹 ——
            collections: _collections,
            activeCollectionId: _selectedCollectionId,
            // 联动口径（2026-10-04）：排除收藏夹维度本身，会社/标签筛选参与联动
            allGamesCount: _contextGames(excludeCollection: true).length,
            gameCountOf: (id) => _contextGames(excludeCollection: true)
                .where((g) => g.collectionIds.contains(id))
                .length,
            onEnterCollection: _selectCollection,
            onCreateCollection: _createCollection,
            onRenameCollection: _renameCollection,
            onDeleteCollection: _deleteCollection,
            onTogglePinCollection: _togglePinCollection,
            // —— 标签库 ——
            tagSections: _tagSections,
            activeTagKeys: _activeTagKeys,
            onToggleTag: _toggleTagKey,
            // —— 会社墙 ——
            companies: _companyCards,
            activeSmartGroupKey: _activeSmartGroupKey,
            onEnterCompany: _enterCompanyKey,
            onToggleFollowCompany: _toggleFollowCompany,
            onClose: _closeCategoryBox,
          ),
        ),
      ],
    );
  }

  Widget _buildSearchPill() {
    return Container(
      width: 340,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: BpmColors.panelGlass,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 22, color: BpmColors.mistBlue),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              focusNode: widget.searchFocusNode,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 15,
                color: BpmColors.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索标题、会社、标签',
                hintStyle: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 15,
                  color: BpmColors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortButton() {
    const labels = {
      _SortMode.recentPlay: '最近游玩',
      _SortMode.name: '按名称',
      _SortMode.installed: '安装时间',
    };
    return PopupMenuButton<_SortMode>(
      tooltip: '排序方式',
      color: BpmColors.deepPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: BpmColors.mistBlueBorder),
      ),
      onSelected: (mode) => setState(() => _sortMode = mode),
      itemBuilder: (_) => _SortMode.values
          .map((m) => PopupMenuItem(
                value: m,
                height: 48,
                child: Text(
                  labels[m]!,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 15,
                    color: m == _sortMode
                        ? BpmColors.cherryRose
                        : BpmColors.textSecondary,
                  ),
                ),
              ))
          .toList(),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: BpmColors.panelGlass,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
        ),
        child: Row(
          children: [
            Icon(Icons.sort_rounded, size: 21, color: BpmColors.cherryRose),
            const SizedBox(width: 10),
            Text(
              labels[_sortMode]!,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 15,
                color: BpmColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildManageCollectionsButton() {
    return BpmInteractiveWrapper(
      onTap: _openCategoryBox,
      focusNode: _categoryBtnFocus,
      semanticsLabel: '打开分类匣',
      borderRadius: BorderRadius.circular(28),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: BpmColors.panelGlass,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
        ),
        child: Row(
          children: [
            Icon(Icons.dashboard_customize_rounded,
                size: 21, color: BpmColors.cherryRose),
            const SizedBox(width: 10),
            Text(
              '分类匣',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 15,
                color: BpmColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 活动筛选指示 pill（面板收起时唯一可见的筛选状态；点 = 清除全部筛选）
  ///
  /// 联动升级（2026-10-04）：多维度可叠加，label 组合显示全部活动条件。
  Widget _buildActiveFilterPill() {
    String collectionLabel() {
      for (final c in _collections) {
        if (c.id == _selectedCollectionId) return c.name;
      }
      return '收藏夹';
    }

    String companyLabel() {
      for (final c in _companyCards) {
        if (c.key == _activeSmartGroupKey) return c.name;
      }
      return '会社';
    }

    final parts = <String>[
      if (_selectedCollectionId != null) collectionLabel(),
      if (_activeSmartGroupKey.isNotEmpty) companyLabel(),
      if (_activeTagKeys.isNotEmpty) _activeTagNames.join(' + '),
    ];
    final label = parts.isEmpty ? '筛选' : parts.join(' + ');
    return BpmInteractiveWrapper(
      onTap: _clearAllFilters,
      semanticsLabel: '清除筛选 $label',
      borderRadius: BorderRadius.circular(28),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: BpmColors.cherryRose.withOpacity(0.14),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_rounded, size: 18, color: BpmColors.cherryRose),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 14,
                color: BpmColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.close_rounded, size: 16, color: BpmColors.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildPosterWall() {
    final games = _wallGames;
    if (games.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty && !_hasActiveCategoryFilter
              ? '本地库还是空的,点左侧「添加游戏」导入'
              : '暂无匹配作品',
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 15,
            color: BpmColors.textMuted,
          ),
        ),
      );
    }

    // v3.20: 侧缘呼吸键帽（LT/RT 翻页引导，仅手柄模式 + 确有下一页）
    return BpmTriggerPageHint(
      child: GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 210,
        mainAxisSpacing: 18,
        crossAxisSpacing: 18,
        childAspectRatio: 0.60,
      ),
      itemCount: games.length,
      itemBuilder: (context, index) {
        final game = games[index];
        return _PosterCard(
          key: ValueKey('wall_${game.title}'),
          game: game,
          coverPath: _resolveCoverPath(game),
          collectionId: _selectedCollectionId,
          // v3.8 手柄: 进库页默认直接落海报墙首卡 (AnimatedSwitcher
          // 重建页面时 autofocus 重放)
          autofocus: index == 0,
          onOpen: () => widget.onShowDetailPanel(game),
          onLaunch: () => widget.onGameLaunch(game),
          onLongPress: widget.onGameLongPress != null
              ? () => widget.onGameLongPress!(game)
              : null,
          onSecondaryTapUp: (details) =>
              _showGameContextMenu(game, details.globalPosition),
          onToggleCollection: () => _showGameCollectionDialog(game),
          // v3.9 手柄: 焦点即作用对象
          onFocusChange: (focused) {
            if (focused) widget.onGameFocused?.call(game);
          },
        );
      },
      ),
    );
  }

  // ============ 右键上下文菜单 (结构对齐桌面 LibraryContextMenu) ============

  OverlayEntry? _contextMenuEntry;

  void _showGameContextMenu(LibraryGame game, Offset position) {
    _dismissContextMenu();
    _contextMenuEntry = BpmContextMenu.show(
      context,
      position: position,
      onDetails: () => widget.onShowDetailPanel(game),
      onLaunchManager: () => widget.onLaunchManager?.call(game),
      onCollection: () => _showGameCollectionDialog(game),
      onBackup: () {
        SaveBackupDialog.show(
          context,
          gameName: game.title,
          installDir: game.directoryPath,
          manifestEntry: ManifestService.instance.lookup(game.title),
        );
      },
      onDelete: () => widget.onDeleteGame?.call(game),
      onClosed: _onContextMenuClosed,
    );
  }

  /// 菜单自行关闭 (点菜单项 / 点遮罩) 后清空引用。
  ///
  /// 🔴 不放这行会出现「右键菜单只能弹一次」: 引用一直指向已被移除的
  /// OverlayEntry, 下一次右键的 _dismissContextMenu 会对它重复 remove()
  /// 并抛异常, 中断在 show() 之前。
  void _onContextMenuClosed() {
    _contextMenuEntry = null;
  }

  void _dismissContextMenu() {
    final entry = _contextMenuEntry;
    _contextMenuEntry = null; // 先置空, 再移除 (防重复 remove)
    entry?.remove();
  }

  // ============ 收藏夹操作 ============

  Future<void> _createCollection() async {
    final name = await _promptText('新建收藏夹', '收藏夹名称');
    if (name == null || name.trim().isEmpty) return;
    await CollectionService.instance
        .create(name.trim(), BpmColors.mistBlue.value);
  }

  // ============ 分类匣面板：开关 / 回锚 / 三视图联动筛选 ============

  void _openCategoryBox() {
    if (_categoryBoxPanelOpen) return;
    // 面板独占焦点（与详情面板同状态机）：方向键由面板自身遍历组隔离，
    // 关闭时恢复打开前的 (level, zone)
    BpmZoneFocusScope.maybeOf(context)?.openPanel();
    setState(() {
      _categoryBoxPanelOpen = true;
      widget.categoryBoxOpen?.value = true;
    });
    // 🔴 v3.22 防悬空同坑：焦点必须移进面板，否则方向键仍作用于面板背后
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _categoryBoxPanelOpen) _panelLeadFocus.requestFocus();
    });
  }

  void _closeCategoryBox() {
    if (!_categoryBoxPanelOpen) return;
    widget.categoryBoxOpen?.value = false; // 同步 shell（其 B 键分支读它）
    BpmZoneFocusScope.maybeOf(context)?.closePanel();
    setState(() => _categoryBoxPanelOpen = false);
    // 焦点回「分类匣」按钮，避免悬空在已收起（0 宽 + IgnorePointer）的面板里
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _categoryBtnFocus.requestFocus();
    });
  }

  /// 是否有任何分类匣筛选处于活动态（工具栏指示 pill 的显示条件）
  bool get _hasActiveCategoryFilter =>
      _selectedCollectionId != null ||
      _activeTagKeys.isNotEmpty ||
      _activeSmartGroupKey.isNotEmpty;

  void _clearAllFilters() {
    setState(() {
      _selectedCollectionId = null;
      _activeTagKeys.clear();
      _activeSmartGroupKey = '';
    });
  }

  /// 进入/退出收藏夹筛选（再点同一个 = 退出）
  ///
  /// 联动升级（2026-10-04）：对齐桌面——不再与标签/会社互斥，三维度叠加。
  void _selectCollection(String? id) {
    setState(() {
      final same = _selectedCollectionId == id;
      _selectedCollectionId = same ? null : id;
    });
  }

  /// 切换标签库多选（再次点击取消；联动升级后与收藏夹/会社叠加）
  void _toggleTagKey(String key) {
    setState(() {
      if (_activeTagKeys.contains(key)) {
        _activeTagKeys.remove(key);
      } else {
        _activeTagKeys.add(key);
      }
    });
  }

  /// 进入/退出会社过滤（联动升级后与收藏夹/标签叠加）
  void _enterCompanyKey(String key) {
    setState(() {
      final same = _activeSmartGroupKey == key;
      _activeSmartGroupKey = same ? '' : key;
    });
  }

  /// 当前多选标签的展示名（筛选 pill 用）
  List<String> get _activeTagNames => [
        for (final key in _activeTagKeys)
          if (key.startsWith(TagVocabularyStore.kConceptKeyPrefix))
            TagVocabularyStore.instanceOrNull
                    ?.conceptById(key
                        .substring(TagVocabularyStore.kConceptKeyPrefix.length))
                    ?.name ??
                key
          else if (key.startsWith(SmartGroupService.tagKeyPrefix))
            key.substring(SmartGroupService.tagKeyPrefix.length),
      ];

  // ============ 收藏夹操作（面板行动作共用） ============

  Future<void> _renameCollection(GameCollection c) async {
    final name =
        await _promptText('重命名收藏夹', '收藏夹名称', initial: c.name);
    if (name == null || name.trim().isEmpty || name.trim() == c.name) return;
    await CollectionService.instance.rename(c.id, name.trim());
  }

  Future<void> _deleteCollection(GameCollection c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: BpmColors.scrimStrong.withOpacity(0.7),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: BpmColors.deepPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: BpmColors.cherryRoseBorder),
        ),
        title: Text(
          '删除收藏夹',
          style: TextStyle(
            fontFamily: AppStyles.zhDecorativeFont,
            fontSize: 20,
            color: BpmColors.textPrimary,
          ),
        ),
        content: Text(
          '确定删除「${c.name}」吗？游戏本体不受影响。',
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 14,
            color: BpmColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('取消',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('删除',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.cherryRose)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_selectedCollectionId == c.id) {
      _selectedCollectionId = null; // 删掉正在看的收藏夹 → 回所有游戏
    }
    await CollectionService.instance.delete(c.id);
  }

  Future<void> _togglePinCollection(GameCollection c) async {
    await CollectionService.instance.setPinned(c.id, !c.pinned);
  }

  /// 关注/取关会社（写 CompanyWallStore；反馈由面板星标即时呈现，
  /// BPM 不弹 snack）
  Future<void> _toggleFollowCompany(CategoryBoxCompany c) async {
    final key = c.storeKey;
    if (key.isEmpty) return;
    await CompanyWallStore.instance.toggleFollow(key);
  }


  /// 单个游戏的收藏夹成员管理（多选弹窗）。
  ///
  /// v3.10.1: 实现抽到 [BpmCollectionPicker]，与手柄 X 动作菜单的
  /// 「加入收藏夹」共用同一份代码 —— 桌面版这一功能由右键菜单提供，
  /// 两处必须行为一致。
  Future<void> _showGameCollectionDialog(LibraryGame game) =>
      BpmCollectionPicker.show(context, game);

  /// 通用文本输入弹窗 (新建/重命名收藏夹)
  Future<String?> _promptText(String title, String hint,
      {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      barrierColor: BpmColors.scrimStrong.withOpacity(0.7),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: BpmColors.deepPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: BpmColors.cherryRoseBorder),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontFamily: AppStyles.zhDecorativeFont,
            fontSize: 20,
            color: BpmColors.textPrimary,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 14,
              color: BpmColors.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 13,
                color: BpmColors.textMuted),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: BpmColors.mistBlueBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  BorderSide(color: BpmColors.cherryRose.withOpacity(0.8)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: Text('确定',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.mistBlue)),
          ),
        ],
      ),
    );
  }
}

// ============ 海报墙单卡 ============

/// 收藏展示柜单张海报卡 (Cinema .collection-poster-card)
class _PosterCard extends StatefulWidget {
  final LibraryGame game;
  final String? coverPath;

  /// 当前筛选的收藏夹 (非 null 时提供快速移出)
  final String? collectionId;
  final VoidCallback onOpen;
  final VoidCallback onLaunch;
  final VoidCallback? onLongPress;
  final VoidCallback onToggleCollection;

  /// 鼠标右键 (弹 BPM 上下文菜单)
  final void Function(TapUpDetails)? onSecondaryTapUp;

  /// v3.8 手柄: 海报墙首卡 autofocus
  final bool autofocus;

  /// v3.9 手柄: 焦点变化上报 (透传 BpmInteractiveWrapper.onFocusChange)
  final ValueChanged<bool>? onFocusChange;

  const _PosterCard({
    super.key,
    required this.game,
    required this.coverPath,
    required this.collectionId,
    required this.onOpen,
    required this.onLaunch,
    required this.onToggleCollection,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.autofocus = false,
    this.onFocusChange,
  });

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

/// v3.21: 改 StatefulWidget —— 本地保存焦点/悬停态驱动操作角标浮现。
class _PosterCardState extends State<_PosterCard> {
  bool _focused = false;
  bool _hovered = false;

  bool get _highlight => _focused || _hovered;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    return GestureDetector(
      onSecondaryTapUp: widget.onSecondaryTapUp,
      child: BpmInteractiveWrapper(
        onTap: widget.onOpen,
        onDoubleTap: widget.onLaunch,
        onLongPress: widget.onLongPress,
        autofocus: widget.autofocus,
        onFocusChange: (f) {
          if (f != _focused) setState(() => _focused = f);
          widget.onFocusChange?.call(f);
        },
        focusScale: 1.04,
        hoverScale: 1.02,
        semanticsLabel: widget.game.title,
        borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 海报封面区
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
                boxShadow: [
                  BoxShadow(
                    color: BpmColors.deepBase.withOpacity(0.32),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.coverPath != null && widget.coverPath!.isNotEmpty)
                      NsfwImage.file(
                        widget.coverPath!,
                        contentKind: NsfwContentKind.cover,
                        fit: BoxFit.cover,
                        decodeWidth: 420,
                        child: Image.file(
                          File(widget.coverPath!),
                          fit: BoxFit.cover,
                          cacheWidth: 420,
                          errorBuilder: (_, __, ___) => _buildPlaceholder(),
                        ),
                      )
                    else
                      _buildPlaceholder(),
                    // v3.21 操作引导角标：聚焦/悬停时浮现（共享组件，
                    // 键鼠=单击进详情/双击启动；手柄=A 进详情/X 启动）
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: _highlight ? 1 : 0,
                          child: const BpmActionHintBadge(),
                        ),
                      ),
                    ),
                    // 收藏夹快速按钮 (右上角)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: BpmInteractiveWrapper(
                        onTap: widget.onToggleCollection,
                        semanticsLabel: '管理 ${widget.game.title} 的收藏夹',
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: BpmColors.deepBase.withOpacity(0.6),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Icon(
                            Icons.bookmarks_rounded,
                            size: 15,
                            color: widget.game.collectionIds.isNotEmpty
                                ? BpmColors.cherryRose
                                : BpmColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    // 徽章 (收藏标记)
                    if (widget.game.mark != GameMark.none)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Icon(
                          widget.game.mark == GameMark.favorite
                              ? Icons.favorite_rounded
                              : Icons.star_rounded,
                          size: 18,
                          color: widget.game.mark == GameMark.favorite
                              ? const Color(0xFFFF6B81)
                              : const Color(0xFFFFC107),
                          shadows: const [
                            Shadow(color: Color(0xA6000000), blurRadius: 8)
                          ],
                        ),
                      ),
                    // 存储状态角标（右下角，只读展示）。方案 §7 Phase 4 项目决策：
                    // BPM 只做只读展示、不提供管理操作；读内存字段，零磁盘探测。
                    // ⚠️ Positioned 必须是 Stack 的直接子级，条件判断不能包 Builder。
                    if (GameStorageState.fromWire(widget.game.storageState)
                        .hasArchive)
                      Positioned(
                        bottom: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: BpmColors.deepBase.withOpacity(0.62),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.inventory_2_outlined,
                                  size: 10, color: BpmColors.textSecondary),
                              const SizedBox(width: 3),
                              Text(
                                GameStorageState.fromWire(
                                        widget.game.storageState)
                                    .label,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.0,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withOpacity(0.92),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 标题区 (Cinema .collection-poster-title)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.game.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: BpmColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.game.developer.isNotEmpty
                      ? widget.game.developer
                      : _statusText(widget.game.playStatus),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 11,
                    color: BpmColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  String _statusText(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return '未开始';
      case PlayStatus.inProgress:
        return '进行中';
      case PlayStatus.dropped:
        return '搁置';
      case PlayStatus.completed:
        return '已通关';
    }
  }

  Widget _buildPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF23354A), Color(0xFF0C0F16)],
        ),
      ),
      child: Center(
        child: Icon(Icons.sports_esports_rounded,
            size: 28, color: BpmColors.textMuted),
      ),
    );
  }
}
