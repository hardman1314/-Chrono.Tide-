import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_size_text/auto_size_text.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_styles.dart';
import '../theme/app_spacing.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/game_launch_service.dart';
import '../services/game_archive_service.dart'; // 引导解包（§11.1 场景 6）
import '../services/cloud_backup/cloud_backup_service.dart'; // 云备份自动同步（§25）
import '../services/file_size_service.dart'; // 体积格式化（解包确认框）
import '../services/game_storage_state_controller.dart';
import '../services/collection_service.dart';
import '../services/library_smart_group_service.dart';
import '../services/company_alias_store.dart'; // ★ 会社归一化（v4）：别名检索
import '../services/company_alias_pending.dart'; // ★ 会社归一化（Phase 3）：待审漏斗
import '../widgets/library_context_menu.dart';
import '../widgets/game_detail_dialog.dart';
import '../widgets/exe_selector_dialog.dart';
import '../utils/library_order_utils.dart';
import '../services/shortcut_service.dart';
import '../widgets/launch_manager_dialog.dart';
import '../widgets/app_snack_bar.dart';
// UX-13: 拆分至独立组件文件
import '../widgets/library/panel_hover_builder.dart';
import '../widgets/library/library_ghost_card.dart';
import '../widgets/library/library_drag_overlay.dart';
import '../widgets/library/edit_mode_context_menu.dart';
import '../widgets/library/batch_shortcut_dialog.dart';
import '../widgets/library/collection_sidebar.dart';
import '../widgets/library/category_box_sidebar.dart';
import '../widgets/library/category_box_editors.dart';
import '../widgets/library/category_box_company_editor.dart';
import '../widgets/app_dialog.dart';
import '../services/tag_vocabulary_store.dart';
import '../services/tag_library_override_store.dart';
import '../services/company_wall_store.dart';
import '../services/company_logo_service.dart'; // ★ 会社图标全自动补抓
import '../widgets/library/collection_badges.dart';
import '../widgets/library/collection_picker_menu.dart';
import '../widgets/touch_gesture_handler.dart';
import '../widgets/nsfw/nsfw_image.dart';

enum _DragMode { swap, insertBefore, insertAfter }

class LibraryPage extends StatefulWidget {
  final VoidCallback onGoDiscover;
  final ValueChanged<String>? onLaunchGame;
  final ValueChanged<String>? onDelete;
  final void Function(List<String> gameTitles, bool deleteLocalFiles)?
      onDeleteBatch;
  final VoidCallback? onRefresh;

  const LibraryPage({
    super.key,
    required this.onGoDiscover,
    this.onLaunchGame,
    this.onDelete,
    this.onDeleteBatch,
    this.onRefresh,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with TickerProviderStateMixin {
  static const String _kGameOrderKey = 'library_game_order';

  OverlayEntry? _contextMenuOverlay;
  OverlayEntry? _dragOverlay;
  int? _originalIndex;
  Offset _dragPosition = Offset.zero;
  int _hoverIndex = -1;

  /// BUG-08: 记录当前 hover 目标的起始时间，用于停留确认（≥200ms 才执行交换）
  DateTime? _hoverStartTime;

  /// BUG-07: 防止全局 Listener 和卡片 Listener 双重调用 _endDrag/_cancelDrag
  bool _isEndingDrag = false;
  List<LibraryGame> _games = [];
  // UX-18: 磁盘扫描期间显示加载指示器，避免空白
  bool _isScanning = false;
  Timer? _longPressTimer;
  static const Duration _dragDelay = Duration(milliseconds: 300);
  Offset _dragAnchor = Offset.zero;
  final GlobalKey _gridKey = GlobalKey();
  Rect? _gridBounds;
  late final AnimationController _liftAnimation;
  final Map<String, String> _localeModes = {};
  final Map<String, String> _upscalingModes = {};

  // --- 新增：双模式拖拽相关字段 ---
  _DragMode _dragMode = _DragMode.swap;
  int _insertIndex = -1;
  /// 卡片 GlobalKey：**按游戏身份**持有（键 = `directoryPath`），不按位置分配。
  ///
  /// 原实现是 `List<GlobalKey>` 按下标分配：显示集合一变（筛选 / 新导入 / 重排），
  /// 同一位置的 key 就落到另一个游戏上，Flutter 因 key 相同而复用 Element/State
  /// → 悬停动画、封面态、NSFW 检测放行标志跟着串台。
  /// 该机制已由 Phase 0 最小 widget 实验复现：
  /// `test/widgets/library_card_key_identity_test.dart`。
  final Map<String, GlobalKey> _cardKeyByGame = {};
  Size? _cachedCardSize;
  Map<int, Rect> _cachedCardRects = {};
  late final AnimationController _insertPreviewAnim;
  late final CurvedAnimation _insertPreviewCurve;
  Map<int, Offset> _insertPreviewOffsets = {};
  Timer? _insertDelayTimer;
  int _pendingInsertIndex = -1;
  _DragMode _pendingInsertMode = _DragMode.swap;
  // ★ P3：搜索持久化防抖定时器（UI 过滤即时，仅磁盘写入延迟 300ms）
  Timer? _searchSaveDebounce;
  // ★ 性能优化：已读取过启动模式（转区/超分）的游戏，避免重复读 game.json
  final Set<String> _launchModesLoaded = {};

  // --- 滚动支持 ---
  final ScrollController _scrollController = ScrollController();
  Timer? _autoScrollTimer;
  double _lastRecacheScrollOffset = 0;

  // --- 编辑模式 ---
  bool _isEditMode = false;
  final Set<String> _selectedGamePaths = {}; // 用 directoryPath 标识选中项
  OverlayEntry? _managementPanel;

  // --- 排序/筛选/布局 ---
  String _activeSort =
      ''; // 空=手动, 'recently_added', 'recently_played', 'play_time', 'play_status', 'marked_first'
  String _activeDeveloperFilter = ''; // 空=全部
  String _searchQuery = '';
  double _cardMaxExtent = 240; // 卡片最大宽度
  static const List<double> _layoutPresets = [160, 240, 340]; // 紧凑/舒适/宽松

  // --- 收藏夹（分级浏览） ---
  /// 当前进入的收藏夹（空 = 库根视图）
  String _activeCollectionId = '';

  // --- 智能归纳（派生分组；联动升级后与收藏夹/标签可叠加筛选） ---
  /// 当前进入的智能分组键（会社墙视图：`dev:<会社>` / `devId:<会社id>`，
  /// 空 = 未进入）
  String _activeSmartGroupKey = '';
  /// 分类匣·标签库：多选标签键集合（`tag:<标签>`，空 = 未选中）
  ///
  /// 过滤语义：标签维度内并集 · 维度间交集；联动升级（2026-10-04）后与
  /// 收藏夹 / 会社视图**叠加**过滤（不再互斥清空）。
  final Set<String> _activeTagKeys = {};
  /// 分类匣·会社墙卡片列表缓存（键 = 会社词典数 + 示例集 + 关注/自定义修订）
  List<CategoryBoxCompany> _companyCardsCache = const [];
  int _companyCardsHash = 0;
  /// 标签库分区缓存（键 = 游戏标识 + 种子分类法 + 覆盖项修订）
  List<CategoryBoxTagSection> _tagSectionsCache = const [];
  int _tagSectionsHash = 0;
  /// 分组派生结果缓存（键为 _gamesIdentity + 覆盖项 revision + 长度）
  List<SmartGroup> _smartGroupsCache = const [];
  int _smartGroupsHash = 0;
  /// 右侧收藏夹栏是否展开
  bool _collectionSidebarOpen = false;
  /// 顶栏搜索框控制器（与管理面板搜索共享同一状态）
  final TextEditingController _topSearchController = TextEditingController();
  /// 拖拽投放悬停的收藏夹条目（null = 无）
  final ValueNotifier<String?> _dropTargetCollectionId =
      ValueNotifier<String?>(null);
  /// 侧栏条目的 GlobalKey，供拖拽投放做全局命中检测
  final Map<String, GlobalKey> _collectionItemKeys = {};

  /// 拖拽投放悬停的智能归纳条目键（null = 无；与收藏夹投放互斥）
  final ValueNotifier<String?> _dropTargetSmartGroupKey =
      ValueNotifier<String?>(null);
  /// 归纳条目的 GlobalKey，供拖拽投放做全局命中检测
  final Map<String, GlobalKey> _smartGroupItemKeys = {};

  // --- UX-34: 封面路径异步预缓存，消除 build/initState 中的同步 I/O ---
  final Map<String, String?> _coverPathCache = {};

  // --- UX-34: 过滤排序结果缓存，避免每次 build 重复计算 O(n)+O(n log n) ---
  List<LibraryGame> _cachedFilteredGames = const [];
  int _filteredGamesHash = 0;

  // --- UX-34: 拖拽期间延迟注册表更新 ---
  bool _pendingRegistryUpdate = false;

  // --- 飞行动画（插入重排时卡片飞到目标位置） ---
  late final AnimationController _flyAnimation;
  Offset _flyFrom = Offset.zero;
  Offset _flyTo = Offset.zero;
  bool _isFlying = false;

  /// ★ H11: UI 层双重启动保护标志
  /// 防止用户快速双击导致多次调用 resolveUserChoice（异步）期间产生重复请求，
  /// 与 GameLaunchService._isLaunching 互为防御纵深：
  /// - UI 层拦截：避免 resolveUserChoice 重复执行 + 避免重复弹 SnackBar
  /// - Service 层拦截：作为最终保险，跨页面/跨模式也生效
  bool _isLaunching = false;

  bool get _isDragging => _originalIndex != null;

  // ===== 拖拽归属层判定（方案 §4.1「渲染列表 = 操作列表」） =====

  /// 拖拽结果应写入哪一层顺序——唯一判定入口
  /// （`lib/utils/library_order_utils.dart` 的 `resolveReorderTarget`）。
  ///
  /// 收藏夹视图 → 写收藏夹内独立顺序（Phase 3 已启用）；
  /// 全局顺序只在「全部游戏视图」下由拖拽改写。
  ReorderTarget get _reorderTarget => resolveReorderTarget(
        manualSort: _activeSort.isEmpty,
        hasSearch: _searchQuery.isNotEmpty,
        hasDeveloperFilter: _activeDeveloperFilter.isNotEmpty,
        inCollection: _activeCollectionId.isNotEmpty,
      );

  /// 当前视图是否允许通过长按拖拽调整顺序
  bool get _canReorderByDrag => _reorderTarget != ReorderTarget.none;

  /// 长按被门控拦下时的一次性提示文案（null = 保持"无响应"的原行为）
  String? get _reorderBlockedHint {
    // 非手动排序：顺序由排序规则决定，原实现即无响应，不新增打扰
    if (_activeSort.isNotEmpty) return null;
    if (_searchQuery.isNotEmpty || _activeDeveloperFilter.isNotEmpty) {
      return '筛选/搜索状态下不可调整顺序，清空筛选后再试';
    }
    return null;
  }

  /// 会话内只提示一次，避免每次长按都弹
  bool _reorderHintShown = false;

  void _notifyReorderBlocked() {
    if (_reorderHintShown || !mounted) return;
    final hint = _reorderBlockedHint;
    if (hint == null) return;
    _reorderHintShown = true;
    AppSnackBar.warning(context, hint);
  }

  List<LibraryGame> get _filteredAndSortedGames {
    // UX-34: 基于输入哈希缓存结果，避免每次 build 重复计算 O(n)+O(n log n)
    final hash = Object.hash(
      _games.length,
      _activeSort,
      _activeDeveloperFilter,
      _searchQuery,
      // 收藏夹视图：进入的收藏夹变化即需重算
      _activeCollectionId,
      // 手动排序模式下，_games 引用变化即需重算
      _activeSort.isEmpty ? _gamesIdentity : 0,
      // 收藏夹内顺序被改写（拖拽/重置）后需重算——长度相同也必须失效
      _collectionOrderRevision,
      // 智能归纳视图：进入的分组变化即需重算
      _activeSmartGroupKey,
      // 标签库多选：并集键序（排序后拼接，避免 Set 迭代序影响 hash）
      _activeTagKeys.isEmpty ? '' : (List.of(_activeTagKeys)..sort()).join('\x00'),
    );
    if (hash != _filteredGamesHash) {
      _filteredGamesHash = hash;
      _cachedFilteredGames = _computeFilteredAndSortedGames();
    }
    return _cachedFilteredGames;
  }

  /// UX-34: _games 列表身份标识（手动排序时用于检测列表变化）
  int _gamesIdentity = 0;

  /// 收藏夹内顺序（`gameOrder`）的修订号：长度不变顺序变了也要让过滤缓存失效
  int _collectionOrderRevision = 0;

  /// 分类匣联动（2026-10-04）：按「排除某维度」的组合过滤游戏集。
  ///
  /// 三个维度（收藏夹 / 会社 / 标签）可叠加；`exclude*` 为 true 的维度不参与
  /// 过滤——**派生计数专用**：排除自身维度防止自反馈（选了标签后标签库瞬间
  /// 清空只剩自己）。搜索与筛选面板的会社过滤不属于分类匣三维度，不参与。
  List<LibraryGame> _contextGames({
    bool excludeCollection = false,
    bool excludeCompany = false,
    bool excludeTags = false,
  }) {
    var result = List<LibraryGame>.from(_games);

    // 收藏夹视图：仅显示属于当前收藏夹的游戏
    if (!excludeCollection && _activeCollectionId.isNotEmpty) {
      result = result
          .where((g) => g.collectionIds.contains(_activeCollectionId))
          .toList();
    }

    // 会社（智能归纳）视图：仅显示属于当前分组的游戏（成员判定统一走 matches，
    // 与侧栏计数口径一致）。
    if (!excludeCompany && _activeSmartGroupKey.isNotEmpty) {
      final group = _activeSmartGroup;
      if (group == null) {
        result = <LibraryGame>[];
      } else {
        result = result.where(group.matches).toList();
      }
    }

    // 分类匣·标签库过滤
    if (!excludeTags && _activeTagKeys.isNotEmpty) {
      result = _applyTagKeyFilter(result);
    }
    return result;
  }

  /// 当前叠加的分类匣维度数（收藏夹 / 会社 / 标签）
  int get _activeContextDimCount =>
      (_activeCollectionId.isNotEmpty ? 1 : 0) +
      (_activeSmartGroupKey.isNotEmpty ? 1 : 0) +
      (_activeTagKeys.isNotEmpty ? 1 : 0);

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

  List<LibraryGame> _computeFilteredAndSortedGames() {
    // 分类匣联动：收藏夹 ∩ 会社 ∩ 标签 组合过滤（2026-10-04 起三维度叠加）
    var result = _contextGames();

    // 搜索过滤（支持主标题、副标题、会社名/别名）
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      // ★ 会社归一化（v4）：会社匹配升级为归一化文本 + 别名展开——
      //   搜「雪碧社」能命中 developer 原文是 sprite 的游戏，反之亦然
      final nq = CompanyAliasStore.normalize(_searchQuery);
      final aliasCompanyIds = _companyIdsForQuery(_searchQuery);
      result = result
          .where((g) =>
              g.title.toLowerCase().contains(q) ||
              g.subtitle.toLowerCase().contains(q) ||
              (nq.isNotEmpty &&
                  CompanyAliasStore.normalize(g.developer).contains(nq)) ||
              (g.companyId != null && aliasCompanyIds.contains(g.companyId)))
          .toList();
    }

    // 会社筛选（v4：词典命中组以 `devId:<id>` 为键、跨写法归并；
    // 未命中词典的原文按原文匹配，且只收未解析的游戏避免双计）
    if (_activeDeveloperFilter.isNotEmpty) {
      if (_activeDeveloperFilter == '__none__') {
        result = result.where((g) => g.developer.isEmpty).toList();
      } else if (_activeDeveloperFilter
          .startsWith(SmartGroupService.kCompanyDevKeyPrefix)) {
        final id = int.tryParse(_activeDeveloperFilter
            .substring(SmartGroupService.kCompanyDevKeyPrefix.length));
        result = id == null
            ? <LibraryGame>[]
            : result.where((g) => g.companyId == id).toList();
      } else {
        result = result
            .where((g) =>
                g.companyId == null && g.developer == _activeDeveloperFilter)
            .toList();
      }
    }

    // 排序
    switch (_activeSort) {
      case 'recently_added':
        result.sort((a, b) => b.installedAt.compareTo(a.installedAt));
        break;
      case 'recently_played':
        // 口径与 BPM 主页 `_sortedByRecency` 保持一致（big_picture_home.dart:102）：
        // 按真实最近启动时间排序。原实现误用 playTime，与「游玩时长」完全同序。
        result.sort((a, b) {
          final aTime = DateTime.tryParse(a.lastOpenedAt);
          final bTime = DateTime.tryParse(b.lastOpenedAt);
          if (aTime != null && bTime != null) return bTime.compareTo(aTime);
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          // 从未启动过：退回按入库时间倒序，保证顺序确定
          return b.installedAt.compareTo(a.installedAt);
        });
        break;
      case 'play_time':
        result.sort((a, b) => b.playTime.compareTo(a.playTime));
        break;
      case 'play_status':
        const order = [
          PlayStatus.inProgress,
          PlayStatus.notStarted,
          PlayStatus.dropped,
          PlayStatus.completed
        ];
        result.sort((a, b) =>
            order.indexOf(a.playStatus).compareTo(order.indexOf(b.playStatus)));
        break;
    }

    // 收藏夹内独立顺序：仅「收藏夹视图 + 手动排序」生效——这正是收藏夹内
    // 拖拽的归属层（与全局手动顺序互不影响，见方案 §4.1）。
    if (_activeCollectionId.isNotEmpty && _activeSort.isEmpty) {
      final order =
          CollectionService.instance.byId(_activeCollectionId)?.gameOrder ??
              const <String>[];
      result = applyCollectionOrder(result, order,
          keyOf: (g) => g.directoryPath);
    }

    return result;
  }

  /// 会社筛选条目（v4）：词典命中（companyId 非空）按 id 归并、展示词典
  /// 中文名或标准主名；未命中词典的按原文各自成条。
  /// 排序沿用旧口径（展示名小写字母序）。空会社（未填）不产生条目，
  /// 「未分类」逻辑与旧实现一致由面板内部处理。
  List<DeveloperFilterEntry> get _developerFilterEntries {
    final store = CompanyAliasStore.instanceOrNull;
    final ids = <int, String>{}; // companyId -> 首见原文（词典缺条目时兜底展示）
    final raws = <String>{};
    for (final g in _games) {
      final dev = g.developer;
      if (dev.isEmpty) continue;
      if (g.companyId != null) {
        ids.putIfAbsent(g.companyId!, () => dev);
      } else {
        raws.add(dev);
      }
    }
    final entries = <DeveloperFilterEntry>[];
    ids.forEach((id, raw) {
      final rec = store?.byId(id);
      entries.add(DeveloperFilterEntry(
        value: '${SmartGroupService.kCompanyDevKeyPrefix}$id',
        label: rec?.displayName ?? raw,
        companyId: id,
      ));
    });
    for (final raw in raws) {
      entries.add(DeveloperFilterEntry(value: raw, label: raw));
    }
    entries.sort((a, b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return entries;
  }

  /// 顶栏搜索经别名词典命中的 company_id 集合
  /// （如「雪碧社」→ sprite 的 id；词典未加载返回空集）
  Set<int> _companyIdsForQuery(String query) {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return const {};
    return store.search(query, limit: 50).map((r) => r.companyId).toSet();
  }

  void _toggleEditMode() {
    setState(() {
      _isEditMode = !_isEditMode;
      if (!_isEditMode) {
        _selectedGamePaths.clear();
        _dismissManagementPanel();
      }
    });
  }

  void _toggleCardSelection(LibraryGame game) {
    setState(() {
      if (_selectedGamePaths.contains(game.directoryPath)) {
        _selectedGamePaths.remove(game.directoryPath);
      } else {
        _selectedGamePaths.add(game.directoryPath);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedGamePaths.clear();
      _selectedGamePaths
          .addAll(_filteredAndSortedGames.map((g) => g.directoryPath));
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedGamePaths.clear();
    });
  }

  /// 视图切换（收藏夹 / 搜索 / 会社筛选）后清空勾选集。
  ///
  /// 原实现勾选集跨视图累积：全选只选"当前可见"，而批量操作却作用于
  /// "全部已勾选"——两个语义分裂，用户会看到"批量删除了看不见的游戏"。
  /// 统一为：**勾选 ∈ 当前可见**，切换视图即清空。
  void _clearSelectionOnViewChange() {
    if (_selectedGamePaths.isEmpty) return;
    _selectedGamePaths.clear();
  }

  void _showManagementPanelAt(RenderBox buttonBox) {
    _dismissManagementPanel();

    final buttonPos = buttonBox.localToGlobal(Offset.zero);
    final buttonSize = buttonBox.size;

    _managementPanel = OverlayEntry(
      builder: (_) => _ManagementPanelWidget(
        position:
            Offset(buttonPos.dx - 260, buttonPos.dy + buttonSize.height + 8),
        activeSort: _activeSort,
        activeDeveloperFilter: _activeDeveloperFilter,
        cardMaxExtent: _cardMaxExtent,
        developers: _developerFilterEntries,
        onSortChanged: (s) {
          final newSort = _activeSort == s ? '' : s;
          setState(() => _activeSort = newSort);
          _savePanelSetting(_kSortKey, newSort);
          _managementPanel?.markNeedsBuild();
        },
        onDeveloperFilterChanged: (d) {
          final newFilter = _activeDeveloperFilter == d ? '' : d;
          setState(() {
            _activeDeveloperFilter = newFilter;
            _clearSelectionOnViewChange(); // 可见集合变了 → 勾选失效
          });
          _savePanelSetting(_kDevFilterKey, newFilter);
          _managementPanel?.markNeedsBuild();
        },
        onLayoutChanged: (v) {
          setState(() => _cardMaxExtent = v);
          _savePanelSetting(_kLayoutKey, v);
          _managementPanel?.markNeedsBuild();
        },
        onClose: _dismissManagementPanel,
      ),
    );
    Overlay.of(context).insert(_managementPanel!);
  }

  void _dismissManagementPanel() {
    _managementPanel?.remove();
    _managementPanel = null;
  }

  void _showEditModeContextMenu(
      BuildContext context, LibraryGame game, Offset position) {
    _dismissContextMenu();

    final hasSelection = _selectedGamePaths.isNotEmpty;
    final selectedGames = _games
        .where((g) => _selectedGamePaths.contains(g.directoryPath))
        .toList();

    _contextMenuOverlay = OverlayEntry(
      builder: (_) => EditModeContextMenu(
        position: position,
        hasSelection: hasSelection,
        onBlur: hasSelection
            ? () {
                _dismissContextMenu();
                for (final g in selectedGames) {
                  GameDataFormat.setBlurred(g.pathForCover, !g.isBlurred);
                  g.isBlurred = !g.isBlurred;
                }
                setState(() {});
              }
            : null,
        onPlayStatus: hasSelection
            ? () {
                _dismissContextMenu();
                _showPlayStatusMenu(context, selectedGames);
              }
            : null,
        onCollection: hasSelection
            ? () {
                _dismissContextMenu();
                _showCollectionPicker(context, selectedGames, position);
              }
            : null,
        onDelete: hasSelection
            ? () {
                _dismissContextMenu();
                _showBatchDeleteConfirm(selectedGames);
              }
            : null,
        onClose: _dismissContextMenu,
      ),
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  void _showBatchDeleteConfirm(List<LibraryGame> games) {
    bool deleteLocalFiles = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 1.5),
          ),
          title: Text(
            '确认删除',
            style: AppStyles.headlineSmall.copyWith(letterSpacing: 1.5),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '确定要将选中的 ${games.length} 个游戏从库中移除吗？',
                style: AppStyles.dialogBody.copyWith(height: 1.6),
              ),
              const SizedBox(height: AppSpacing.xs + 2),
              Text(
                deleteLocalFiles
                    ? '⚠ 已勾选：将同时删除本地所有游戏文件，不可恢复。'
                    : '默认仅从库中移除记录，本地游戏文件保留不变。',
                style: AppStyles.hintRegular.copyWith(
                  color: deleteLocalFiles
                      ? AppColors.dangerRed
                      : AppColors.primaryText,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: AppSpacing.md + 2),
              GestureDetector(
                onTap: () {
                  setDialogState(() {
                    deleteLocalFiles = !deleteLocalFiles;
                  });
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: deleteLocalFiles
                              ? AppColors.dangerRed
                              : AppColors.border,
                          width: 1.5,
                        ),
                        color: deleteLocalFiles
                            ? AppColors.dangerRed
                            : Colors.transparent,
                      ),
                      child: deleteLocalFiles
                          ? const Icon(Icons.check,
                              size: 14, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: AppSpacing.sm + 2),
                    Flexible(
                      child: Text(
                        '同时删除本地游戏文件',
                        style: AppStyles.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                '取消',
                style: AppStyles.labelLarge.copyWith(color: AppColors.infoBlue),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop('confirm');
              },
              child: Text(
                '确认删除',
                style:
                    AppStyles.labelLarge.copyWith(color: AppColors.dangerRed),
              ),
            ),
          ],
        ),
      ),
    ).then((result) async {
      if (result == null || result != 'confirm') return;

      final gameTitles = games.map((g) => g.title).toList();
      widget.onDeleteBatch?.call(gameTitles, deleteLocalFiles);

      _selectedGamePaths.clear();
      setState(() {});
    });
  }

  void _showPlayStatusMenu(BuildContext context, List<LibraryGame> games) {
    final statuses = PlayStatus.values;

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text('设置游玩状态'),
        children: statuses
            .map((s) => SimpleDialogOption(
                  onPressed: () {
                    Navigator.pop(ctx);
                    for (final g in games) {
                      GameDataFormat.setPlayStatus(g.pathForCover, s.jsonKey);
                      g.playStatus = s;
                    }
                    setState(() {});
                    // ★ 响应式修复：广播状态变更，主页/BPM/详情页徽标即时同步
                    LocalGameRegistry.instance.notifyDataChanged();
                  },
                  child: Row(children: [
                    Icon(s.icon, color: s.color, size: 20),
                    SizedBox(width: 12),
                    Text(s.label),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  /// 计算被拖动卡片的中心点（屏幕坐标）
  /// 用作位置判定的定位点，比鼠标位置更精准、更跟手
  Offset _cardCenter() {
    final w = _cachedCardSize?.width ?? 0;
    final h = _cachedCardSize?.height ?? 0;
    return Offset(
      _dragPosition.dx - _dragAnchor.dx + w / 2,
      _dragPosition.dy - _dragAnchor.dy + h / 2,
    );
  }

  @override
  void initState() {
    super.initState();
    _liftAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0.0,
    );
    _insertPreviewAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0.0,
    );
    _insertPreviewCurve = CurvedAnimation(
      parent: _insertPreviewAnim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _flyAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 0.0,
    );
    _flyAnimation.addListener(_onFlyUpdate);
    _loadPanelSettings();
    _refreshFromDisk();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
    _scheduleCloudAutoSync(); // 云备份自动同步（§25，非稳定区软钩子）
    CollectionService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    CollectionService.instance.addListener(_onCollectionsChanged);
    // 智能归纳：覆盖项懒加载（本功能只被库页消费，故不放 main.dart 全局初始化，
    // 也避免触碰稳定区）；加载完成后 setState 让侧栏分组刷新
    if (!SmartGroupService.instance.isLoaded) {
      SmartGroupService.instance.load().then((_) {
        if (mounted) setState(() {});
      });
    }
    SmartGroupService.instance.addListener(_onSmartGroupsChanged);
    // 分类匣：标签受控词表（维度 + 概念 + 别名）+ 会社墙状态（关注/自定义会社）
    TagVocabularyStore.ensureLoaded().then((_) {
      if (!mounted) return;
      _syncSmartGroupItemKeys(); // 概念标签键登记 → 拖拽可命中
      setState(() {});
    });
    if (!CompanyWallStore.instance.isLoaded) {
      CompanyWallStore.instance.load();
    }
    CompanyWallStore.instance.addListener(_onCompanyWallChanged);
    // 分类匣·标签库用户覆盖层（维度改名/新增、标签归属、全局隐藏）——
    // 详情页/大屏等展示点读其内存态做 filterVisibleTags，这里负责加载
    if (!TagLibraryOverrideStore.instance.isLoaded) {
      TagLibraryOverrideStore.instance.load();
    }
    TagLibraryOverrideStore.instance.addListener(_onTagOverridesChanged);
    _topSearchController.addListener(_onTopSearchChanged);
    ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
    _scrollController.addListener(_onScrollChanged);
  }

  /// 云备份自动同步（Phase 5 二期，方案 §25）。
  ///
  /// 触发点刻意放在库页 initState（非稳定区）而非 main.dart/main_container
  /// —— 启动后延迟 12 秒等网络与首帧稳定，到期才真正跑（窗口判断在服务层：
  /// 每天启动 / 24h / 7d）。有上传结果才提示，静默跳过不打扰。
  void _scheduleCloudAutoSync() {
    Future.delayed(const Duration(seconds: 12), () async {
      if (!mounted) return;
      try {
        final r = await CloudBackupService.instance.autoSyncIfDue();
        if (!mounted || !r.ran || r.uploaded == 0) return;
        AppSnackBar.success(context, '云备份自动同步完成：${r.summary}');
      } catch (_) {
        // 自动同步失败静默（不打扰用户），下次窗口自动重试
      }
    });
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isDragging) {
        _cancelDrag();
        return true;
      }
      // Esc 关闭收藏夹侧栏
      if (_collectionSidebarOpen) {
        setState(() => _collectionSidebarOpen = false);
        return true;
      }
    }
    return false;
  }

  /// 智能归纳覆盖项变化（重命名/置顶/隐藏/加载完成）时刷新 UI
  void _onSmartGroupsChanged() {
    if (!mounted) return;
    _syncSmartGroupItemKeys();
    setState(() {});
  }

  /// 会社墙状态变化（关注/取消关注/添加自定义会社/加载完成）时刷新 UI
  void _onCompanyWallChanged() {
    if (!mounted) return;
    _syncSmartGroupItemKeys();
    setState(() {});
  }

  /// 标签库用户覆盖层变化（维度改名/新增/标签归属/隐藏）时刷新 UI。
  /// 全局隐藏等影响其他展示点的由各展示点在 build 时读取内存态生效。
  void _onTagOverridesChanged() {
    if (!mounted) return;
    _syncSmartGroupItemKeys();
    setState(() {});
  }

  /// 收藏夹列表变化（新建/重命名/改色/删除）时刷新 UI
  void _onCollectionsChanged() {
    if (!mounted) return;
    // 当前收藏夹被删除时退回库根视图
    if (_activeCollectionId.isNotEmpty &&
        CollectionService.instance.byId(_activeCollectionId) == null) {
      _activeCollectionId = '';
    }
    _syncCollectionItemKeys();
    _collectionOrderRevision++; // 收藏夹内顺序可能被改写 → 过滤缓存失效
    setState(() {});
  }

  // ==================== 收藏夹：交互逻辑 ====================

  /// 同步侧栏条目的 GlobalKey 映射（供拖拽投放做全局命中检测）
  void _syncCollectionItemKeys() {
    final liveIds = CollectionService.instance.collections
        .map((c) => c.id)
        .toSet();
    _collectionItemKeys.removeWhere((id, _) => !liveIds.contains(id));
    for (final c in CollectionService.instance.collections) {
      _collectionItemKeys.putIfAbsent(c.id, () => GlobalKey());
    }
  }

  /// 同步「分类匣」标签/会社条目的 GlobalKey 映射（拖拽投放用）
  ///
  /// 预登记所有可展示候选键（标签库分区概念 + 未归类标签 + 会社卡）——GlobalKey
  /// 惰性挂载，未挂载的键不参与命中检测，预登记无开销。
  void _syncSmartGroupItemKeys() {
    final liveKeys = <String>{
      // 标签库分区（概念 `concept:<id>` + 未归类 `tag:<原文>`）
      for (final s in _tagSections)
        for (final t in s.tags) t.key,
      // 会社墙卡片
      for (final c in _companyCards) c.key,
    };
    _smartGroupItemKeys.removeWhere((k, _) => !liveKeys.contains(k));
    for (final key in liveKeys) {
      _smartGroupItemKeys.putIfAbsent(key, () => GlobalKey());
    }
  }

  /// 指定收藏夹的游戏数量
  ///
  /// 联动口径（2026-10-04）：排除收藏夹维度本身（会社/标签筛选参与联动），
  /// 选了标签后收藏夹计数只统计该标签下的成员。
  int _gameCountOf(String collectionId) {
    var count = 0;
    for (final g in _contextGames(excludeCollection: true)) {
      if (g.collectionIds.contains(collectionId)) count++;
    }
    return count;
  }

  /// 进入某个收藏夹视图（再次点击当前收藏夹 → 回到库根视图）
  ///
  /// 联动升级（2026-10-04）：不再与标签/会社互斥——三个维度可叠加筛选，
  /// 实际列表 = 收藏夹 ∩ 会社 ∩ 标签组合。
  void _enterCollection(String collectionId) {
    setState(() {
      _activeCollectionId =
          _activeCollectionId == collectionId ? '' : collectionId;
      _clearSelectionOnViewChange();
    });
    // 顺手裁剪顺序表：已移出收藏夹 / 已删除的游戏留下的键不再占位
    if (_activeCollectionId.isNotEmpty) {
      final valid = _games
          .where((g) => g.collectionIds.contains(_activeCollectionId))
          .map((g) => g.directoryPath)
          .toSet();
      CollectionService.instance.pruneGameOrder(_activeCollectionId, valid);
    }
  }

  /// 清空当前收藏夹的自定义顺序 → 回到全局顺序
  Future<void> _resetCollectionOrder(GameCollection collection) async {
    await CollectionService.instance.resetGameOrder(collection.id);
    if (!mounted) return;
    setState(() => _collectionOrderRevision++);
    AppSnackBar.success(context, '已重置「${collection.name}」的排序');
  }

  // ==================== 智能归纳：交互逻辑 ====================

  /// 当前派生分组（缓存：注册表结构变化 / 覆盖项变化 / 数量变化时才重算）
  List<SmartGroup> get _smartGroups {
    final hash = Object.hash(
      _gamesIdentity,
      SmartGroupService.instance.revision,
      _games.length,
    );
    if (hash != _smartGroupsHash) {
      _smartGroupsHash = hash;
      _smartGroupsCache = SmartGroupService.instance.buildGroups(_games);
    }
    return _smartGroupsCache;
  }

  /// 当前进入的智能分组（未进入 / 分组已消失时为 null）
  SmartGroup? get _activeSmartGroup {
    if (_activeSmartGroupKey.isEmpty) return null;
    for (final g in _smartGroups) {
      if (g.key == _activeSmartGroupKey) return g;
    }
    return null;
  }

  /// 进入 / 退出会社视图（再次点击同一会社 → 退出）
  ///
  /// 联动升级（2026-10-04）：不再与收藏夹/标签互斥——叠加筛选。
  void _enterSmartGroup(String key) {
    setState(() {
      final same = _activeSmartGroupKey == key;
      _activeSmartGroupKey = same ? '' : key;
      _clearSelectionOnViewChange();
    });
  }

  /// 切换标签库多选（再次点击取消）
  ///
  /// 联动升级（2026-10-04）：不再清空收藏夹/会社——叠加筛选。
  /// 过滤语义：标签维度内并集 · 维度间交集，再与收藏夹/会社取交集。
  void _toggleTagKey(String key) {
    setState(() {
      if (_activeTagKeys.contains(key)) {
        _activeTagKeys.remove(key);
      } else {
        _activeTagKeys.add(key);
      }
      _clearSelectionOnViewChange();
    });
  }

  /// 当前多选标签的展示名（面包屑 / 空态文案用）
  ///
  /// 概念键取规范名，未归类键去前缀取原文。
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

  /// 编辑智能分组（重命名 / 置顶 / 隐藏 / 恢复默认）
  Future<void> _editSmartGroup(SmartGroup group) async {
    final result = await SmartGroupEditDialog.show(context, group: group);
    if (result == null || !mounted) return;
    final svc = SmartGroupService.instance;
    if (result.reset) {
      await svc.clearOverride(group.key);
    } else {
      await svc.renameGroup(group.key, result.displayName);
      await svc.setPinned(group.key, result.pinned);
      await svc.setHidden(group.key, result.hidden);
    }
    if (!mounted) return;
    // 被隐藏 / 恢复默认后若正停在该组视图：隐藏则退出，避免"停在看不见的组里"
    if (result.hidden && _activeSmartGroupKey == group.key) {
      setState(() => _activeSmartGroupKey = '');
    }
  }

  // ==================== 分类匣：标签库 / 会社墙 ====================

  /// 标签库分区（缓存：游戏/覆盖项/词表/选中态变化时才重算）
  ///
  /// 结构 = **受控词表的维度**（按 order）+ 「其他」分区：
  /// - 只展示**库内确有游戏命中**（计数 > 0）的维度与概念——分类从库数据自动派生，
  ///   而非预置清单；0 成员维度/概念自动隐藏；
  /// - 概念展示名可被 `SmartGroupService` 覆盖项（重命名/隐藏）影响，延续原编辑能力；
  /// - 「其他」= 库内出现但未命中词表的原始标签（计数降序，封顶展示）。
  List<CategoryBoxTagSection> get _tagSections {
    final vocab = TagVocabularyStore.instanceOrNull;
    final overrides = TagLibraryOverrideStore.instance;
    final hash = Object.hash(
      _gamesIdentity,
      _games.length,
      SmartGroupService.instance.revision,
      overrides.revision, // 维度改名/新增/标签归属/隐藏变化 → 缓存失效
      vocab?.concepts.length ?? 0,
      // 联动口径：会社/收藏夹上下文变化 → 标签计数重算（排除标签维度本身）
      _activeSmartGroupKey,
      _activeCollectionId,
      (List.of(_activeTagKeys)..sort()).join('\x00'),
    );
    if (hash != _tagSectionsHash) {
      _tagSectionsHash = hash;
      final derivation = TagVocabularyStore.derive(
        // 联动派生：排除标签维度防自反馈，会社/收藏夹筛选参与联动
        _contextGames(excludeTags: true).map((g) => g.tags),
        vocab,
      );
      final sections = <CategoryBoxTagSection>[];

      // 有效维度清单：asset 维度（标题可被覆盖）+ 用户自定义维度（排最后）。
      // 覆盖层**只改展示分区**，不改词表本身（词表升级不冲掉用户整理）。
      final effDims = <_EffectiveDim>[
        for (final d in (vocab?.dimensions ?? const <TagDimension>[]))
          _EffectiveDim(
            d.id,
            overrides.dimensionTitleOverride(d.id) ?? d.title,
            d.color,
            false,
          ),
        ...overrides.customDimensions.map(
            (d) => _EffectiveDim(d.id, d.title, null, true)),
      ];
      final buckets = <String, List<CategoryBoxTag>>{
        for (final d in effDims) d.id: [],
      };
      Color? dimColorOf(String dimId) =>
          effDims.firstWhere((d) => d.id == dimId,
                  orElse: () => _EffectiveDim(dimId, dimId, null, false))
              .color;

      if (vocab != null) {
        // 概念 → 有效维度分桶（覆盖归属优先）
        for (final c in vocab.concepts) {
          final count = derivation.countOf(c.id);
          // 联动：0 成员不展示，但**已选中的标签保留**（否则组合筛选时选中项凭空消失）
          if (count <= 0 && !_activeTagKeys.contains(c.key)) continue;
          final effDim = overrides.effectiveConceptDim(c.id, c.dimensionId);
          final bucket = buckets[effDim];
          if (bucket == null) continue; // 归属指向已删维度 → 保守跳过
          final sgOv = SmartGroupService.instance
              .overrideOf(SmartGroupService.tagKey(c.name));
          final custom = sgOv?.displayName;
          bucket.add(CategoryBoxTag(
            key: c.key,
            name: (custom != null && custom.isNotEmpty) ? custom : c.name,
            count: count,
            dotColor: dimColorOf(effDim),
            selected: _activeTagKeys.contains(c.key),
            // 新覆盖层隐藏（按规范名归一化）∪ 旧 SmartGroupService 隐藏
            hidden: overrides.isHidden(TagVocabularyStore.normalizeTag(c.name)) ||
                (sgOv?.hidden ?? false),
            writeTarget: c.name,
            isConcept: true,
          ));
        }
        for (final d in effDims) {
          final tags = buckets[d.id]!;
          if (tags.isNotEmpty) {
            tags.sort((a, b) {
              final c = b.count.compareTo(a.count);
              return c != 0 ? c : a.name.compareTo(b.name);
            });
          }
          sections.add(CategoryBoxTagSection(
            title: d.title,
            tags: tags,
            dimId: d.id,
            isUserDim: d.isUser,
          ));
        }
      }
      // 未归类：有归属覆盖的进对应维度分区，其余进「其他」（封顶 80）
      final others = <CategoryBoxTag>[];
      for (final u in derivation.unclassified.take(80)) {
        final norm = TagVocabularyStore.normalizeTag(u.name);
        final dimId = overrides.unclassifiedDimOf(norm);
        final key = SmartGroupService.tagKey(u.name);
        // 已选中的未归类标签即使计数归 0 也保留（联动保留原则）
        if (u.count <= 0 && !_activeTagKeys.contains(key)) continue;
        final tag = CategoryBoxTag(
          key: key,
          name: u.name,
          count: u.count,
          dotColor: dimId != null ? dimColorOf(dimId) : null,
          selected: _activeTagKeys.contains(key),
          hidden: overrides.isHidden(norm),
          writeTarget: u.name,
        );
        if (dimId != null && buckets.containsKey(dimId)) {
          final bucket = buckets[dimId]!;
          bucket.add(tag);
          // 归入维度后重排该分区
          bucket.sort((a, b) {
            final c = b.count.compareTo(a.count);
            return c != 0 ? c : a.name.compareTo(b.name);
          });
        } else {
          others.add(tag);
        }
      }
      if (others.isNotEmpty) {
        sections.add(CategoryBoxTagSection(title: '其他', tags: others));
      }
      _tagSectionsCache = sections;
    }
    return _tagSectionsCache;
  }

  /// 会社墙卡片（缓存）
  ///
  /// **纯派生**（不再有预置清单）：库内有作品的词典会社（数量降序 → 名字升序）→
  /// 自定义会社（创建顺序）。计数永远派生（词典按 company_id，自定义按
  /// developer 原文），关注状态来自 [CompanyWallStore]。
  ///
  /// 联动口径（2026-10-04）：计数基于「收藏夹 ∩ 标签」过滤后的上下文
  /// （排除会社维度本身防自反馈）——选中标签后，会社墙只剩该标签下的会社。
  List<CategoryBoxCompany> get _companyCards {
    final wall = CompanyWallStore.instance;
    final store = CompanyAliasStore.instanceOrNull;
    final hash = Object.hash(
      _gamesIdentity,
      _games.length,
      wall.revision,
      store?.companyCount ?? 0,
      // 联动口径：标签/收藏夹上下文变化 → 会社计数重算
      _activeCollectionId,
      _activeSmartGroupKey,
      (List.of(_activeTagKeys)..sort()).join('\x00'),
    );
    if (hash != _companyCardsHash) {
      _companyCardsHash = hash;
      // 各会社成员计数（一次遍历，联动上下文）
      final contextGames = _contextGames(excludeCompany: true);
      final countByCompanyId = <int, int>{};
      final countByDevName = <String, int>{};
      for (final game in contextGames) {
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
        final name = wall.displayNameOf(storeKey) ??
            (cn.isNotEmpty ? cn : standardName);
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
        final nameCandidates = [
          if (cn.isNotEmpty) cn,
          if (logoJp.isNotEmpty && logoJp != standardName) logoJp,
          standardName,
        ];
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
          vndbId: (rec.vndbId ?? '').trim().isEmpty ? null : rec.vndbId,
          nameCandidates: nameCandidates,
          standardName: standardName,
        );
      }

      // ①②③ 合并生成（作品数降序 → 名字升序），自定义会社仍排最后：
      // ① 词典会社；② companyId 词典缩水兜底「会社#id」（与智能分组
      //    deriveGroups 的兜底文案一致）；③ 词典未命中的 developer 原文
      //    会社（如 imel）——会社墙目标 = 系统整理库内**全部**会社，不能
      //    只收清洗后的数据。③ 的点击键 devKey(原文) 与智能分组一致，
      //    列表筛选链路直接可用。
      final pending =
          <({CategoryBoxCompany card, int count, String sortName})>[];
      final customNames =
          wall.customCompanies.map((c) => c.name).toSet();

      // ① 词典会社 + ② 词典缩水兜底
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
            nameCandidates: [name],
            standardName: name,
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
            vndbId: null,
            nameCandidates: [dev],
            standardName: dev,
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
          nameCandidates: [custom.name],
          standardName: custom.name,
        ));
      }
      _companyCardsCache = cards;
      // 会社图标全自动抓取（2026-10-04）：墙内出现无图标的会社 → 系统后台
      // 自动检索平台元数据并落盘（无需用户点按钮），成功后 store 通知刷新。
      CompanyLogoService.instance.autoFetchMissingLogos([
        for (final c in cards)
          if (c.logoPath == null)
            CompanyLogoAutoRequest(
              storeKey: c.storeKey,
              vndbId: c.isCustom ? null : c.vndbId,
              nameCandidates: c.nameCandidates,
            ),
      ]);
    }
    return _companyCardsCache;
  }

  /// 编辑标签弹窗（重命名/隐藏 = SmartGroupService 展示层覆盖）
  ///
  /// 收录：受控词表中**库内确有命中**（计数 > 0）的概念（按维度顺序）+
  /// 未归类原始标签。覆盖键沿用 `tag:<规范名>`（写穿时写入的正是规范名）。
  // ==================== 标签库内联编辑（2026-10-04 升级） ====================

  /// 统计某标签（归一化匹配）命中的游戏数（确认弹窗展示影响面用）。
  int _affectedGameCount(String writeTarget) {
    final n = TagVocabularyStore.normalizeTag(writeTarget);
    if (n.isEmpty) return 0;
    return _games.where((g) => g.tags.any(
        (t) => TagVocabularyStore.normalizeTag(t) == n)).length;
  }

  /// 重命名标签：弹确认框（输入新名 + 写穿警示）→ 全局写穿 → 覆盖层键迁移。
  Future<void> _onRenameTag(String writeTarget, String displayName) async {
    final affected = _affectedGameCount(writeTarget);
    final newName = await _TagRenameDialog.show(
      context,
      oldName: displayName,
      affected: affected,
    );
    if (newName == null || !mounted) return;
    final okCount = await LocalGameRegistry.instance
        .renameTagEverywhere(writeTarget, newName);
    if (!mounted) return;
    if (okCount > 0) {
      // 覆盖层旧键迁移（隐藏/归属跟着走）
      await TagLibraryOverrideStore.instance.migrateKey(
        TagVocabularyStore.normalizeTag(writeTarget),
        TagVocabularyStore.normalizeTag(newName),
      );
      AppSnackBar.success(context, '已重命名 $okCount 部游戏的标签');
    } else {
      AppSnackBar.warning(context, '没有游戏命中该标签或写入失败');
    }
  }

  /// 从所有游戏删除标签：确认（不可逆警示）→ 全局写穿。
  Future<void> _onRemoveTag(String writeTarget, String displayName) async {
    final affected = _affectedGameCount(writeTarget);
    if (affected == 0) {
      AppSnackBar.info(context, '没有游戏带有标签「$displayName」');
      return;
    }
    final confirmed = await _ConfirmWriteThroughDialog.show(
      context,
      title: '删除标签「$displayName」',
      affected: affected,
      action: '删除',
      body: '将从 $affected 部游戏的标签中移除「$displayName」，'
          '此操作直接修改游戏数据且不可撤销。',
    );
    if (confirmed != true || !mounted) return;
    final okCount = await LocalGameRegistry.instance
        .removeTagEverywhere(writeTarget);
    if (!mounted) return;
    AppSnackBar.success(context, '已从 $okCount 部游戏移除该标签');
  }

  /// 隐藏 / 恢复标签（全局生效；覆盖层按归一化记键）。
  Future<void> _onToggleHideTag(String writeTarget, bool hide) async {
    final store = TagLibraryOverrideStore.instance;
    final norm = TagVocabularyStore.normalizeTag(writeTarget);
    if (hide) {
      await store.hideTag(norm);
    } else {
      await store.showTag(norm);
    }
  }

  /// 标签改挂维度（concept: 前缀 = 概念覆盖；tag: 前缀 = 未归类收编）。
  Future<void> _onMoveTagToDim(String tagKey, String dimId) async {
    final store = TagLibraryOverrideStore.instance;
    if (dimId.isEmpty) return;
    if (tagKey.startsWith(TagVocabularyStore.kConceptKeyPrefix)) {
      final conceptId = tagKey.substring(TagVocabularyStore.kConceptKeyPrefix.length);
      final concept = TagVocabularyStore.instanceOrNull?.conceptById(conceptId);
      if (concept == null) return;
      // 目标维度须为 asset 注册维度或用户维度
      final vocab = TagVocabularyStore.instanceOrNull!;
      final valid = vocab.dimensionById(dimId) != null ||
          store.customDimensions.any((d) => d.id == dimId);
      if (!valid) return;
      await store.setConceptDim(conceptId, dimId);
    } else if (tagKey.startsWith(SmartGroupService.tagKeyPrefix)) {
      final raw = tagKey.substring(SmartGroupService.tagKeyPrefix.length);
      await store.setUnclassifiedDim(
          TagVocabularyStore.normalizeTag(raw), dimId);
    }
  }

  /// 维度改名（asset 维度 = 覆盖标题；用户维度 = 直接改）。
  Future<void> _onRenameDimension(String dimId, String newTitle) async {
    await TagLibraryOverrideStore.instance.renameDimension(dimId, newTitle);
  }

  /// 新增用户维度（重名拒绝）。
  Future<void> _onAddDimension(String title) async {
    final dim = await TagLibraryOverrideStore.instance.addCustomDimension(title);
    if (!mounted) return;
    if (dim == null) {
      AppSnackBar.warning(context, '已存在同名维度');
    } else {
      AppSnackBar.success(context, '已新增维度「${dim.title}」，可将标签拖入');
    }
  }

  /// 添加自定义会社
  Future<void> _addCompany() async {
    final result = await AddCompanyDialog.show(context);
    if (result == null || !mounted) return;
    final added = await CompanyWallStore.instance
        .addCustomCompany(result.name, result.subName);
    if (!mounted) return;
    if (added == null) {
      AppSnackBar.warning(context, '已存在同名会社');
    } else {
      AppSnackBar.success(context, '已添加会社「${added.name}」');
    }
  }

  /// 「编辑会社信息」弹窗（上传/抓取/移除图标 + 显示名覆盖）。
  ///
  /// 改名只写 [CompanyWallStore] 显示名覆盖 —— 会社键、成员计数、筛选行为
  /// 全部不变；一切写入由弹窗直接落 store，库页随 revision 自动刷新。
  Future<void> _editCompany(CategoryBoxCompany company) async {
    await CompanyEditorDialog.show(
      context,
      companyKey: company.storeKey,
      originalName: company.standardName ?? company.name,
      currentDisplayName: company.name,
      currentLogoPath: company.logoPath,
      vndbId: company.vndbId,
      nameCandidates: company.nameCandidates,
      isCustom: company.isCustom,
    );
  }

  /// 关注 / 取消关注会社
  Future<void> _toggleFollowCompany(CategoryBoxCompany company) async {
    final key = company.isCustom
        ? CompanyWallStore.instance.customCompanies
            .firstWhere((c) => SmartGroupService.devKey(c.name) == company.key,
                orElse: () => CustomCompany(
                    id: '', name: '', subName: '', createdAt: ''))
            .id
        : company.key.substring(SmartGroupService.kCompanyDevKeyPrefix.length);
    if (key.isEmpty) return;
    final followed = await CompanyWallStore.instance.toggleFollow(key);
    if (!mounted) return;
    AppSnackBar.success(
      context,
      followed ? '已关注「${company.name}」' : '已取消关注「${company.name}」',
    );
  }

  /// 把「卡片拖到分类匣条目上松手」翻译成对游戏数据的**写穿**。
  ///
  /// - 概念标签（受控词表）→ 给游戏加上该概念的**规范名**；
  /// - 未归类标签 → 给游戏加上该原始标签；
  /// - 会社（词典会社 / 自定义会社卡）→ 把游戏会社设为该组的值；
  ///   拖到「未填会社」= 清空会社；
  /// - 编辑模式下拖的是已勾选卡片 → 对全部勾选项生效（与收藏夹投放行为一致）。
  ///
  /// 分组不保存成员，因此这里改的是**游戏数据本身**，分组随之实时变化。
  Future<void> _applySmartGroupDrop(String groupKey, LibraryGame game) async {
    SmartGroup? group;
    for (final g in _smartGroups) {
      if (g.key == groupKey) {
        group = g;
        break;
      }
    }

    // 兜底：概念标签 / 未归类标签 / 会社卡不在派生分组里，直接还原出写穿目标
    if (group == null) {
      // 概念 chip（受控词表）→ 写入该概念的**规范名**
      if (groupKey.startsWith(TagVocabularyStore.kConceptKeyPrefix)) {
        final id =
            groupKey.substring(TagVocabularyStore.kConceptKeyPrefix.length);
        final concept = TagVocabularyStore.instanceOrNull?.conceptById(id);
        if (concept == null) return;
        final targets0 = _dropTargetsFor(game);
        final registry = LocalGameRegistry.instance;
        for (final g in targets0) {
          await registry.setGameTag(g, concept.name, true);
        }
        if (!mounted) return;
        setState(() {});
        AppSnackBar.success(
          context,
          targets0.length > 1
              ? '已为 ${targets0.length} 部游戏加上标签「${concept.name}」'
              : '已加上标签「${concept.name}」',
        );
        return;
      }
      if (groupKey.startsWith(SmartGroupService.tagKeyPrefix)) {
        final tag = groupKey.substring(SmartGroupService.tagKeyPrefix.length);
        if (tag.isEmpty) return;
        final targets0 = _dropTargetsFor(game);
        final registry = LocalGameRegistry.instance;
        for (final g in targets0) {
          await registry.setGameTag(g, tag, true);
        }
        if (!mounted) return;
        setState(() {});
        AppSnackBar.success(
          context,
          targets0.length > 1
              ? '已为 ${targets0.length} 部游戏加上标签「$tag」'
              : '已加上标签「$tag」',
        );
        return;
      }
      if (groupKey.startsWith(SmartGroupService.kCompanyDevKeyPrefix)) {
        final id =
            int.tryParse(groupKey
                .substring(SmartGroupService.kCompanyDevKeyPrefix.length));
        final rec = id == null ? null : CompanyAliasStore.instanceOrNull?.byId(id);
        final name = rec?.standardName;
        if (name == null || name.isEmpty) return;
        final targets0 = _dropTargetsFor(game);
        final registry = LocalGameRegistry.instance;
        for (final g in targets0) {
          await registry.setGameDeveloper(g, name);
        }
        if (!mounted) return;
        setState(() {});
        AppSnackBar.success(
          context,
          targets0.length > 1
              ? '已将 ${targets0.length} 部游戏的会社设为「$name」'
              : '已将会社设为「$name」',
        );
        return;
      }
      // 自定义会社 / 其他未知键：无写穿语义
      return;
    }

    final targets = _dropTargetsFor(game);

    final registry = LocalGameRegistry.instance;
    if (group.kind == SmartGroupKind.tag) {
      for (final g in targets) {
        await registry.setGameTag(g, group.value, true);
      }
    } else {
      final dev = group.isUnassignedDeveloper ? '' : group.value;
      for (final g in targets) {
        await registry.setGameDeveloper(g, dev);
      }
    }

    if (!mounted) return;
    setState(() {}); // 分组计数 / 视图即时刷新（注册表也会发 structural 通知）
    final label = group.displayName;
    if (group.kind == SmartGroupKind.tag) {
      AppSnackBar.success(
        context,
        targets.length > 1
            ? '已为 ${targets.length} 部游戏加上标签「$label」'
            : '已加上标签「$label」',
      );
    } else if (group.isUnassignedDeveloper) {
      AppSnackBar.success(
        context,
        targets.length > 1
            ? '已清空 ${targets.length} 部游戏的会社'
            : '已清空会社',
      );
    } else {
      AppSnackBar.success(
        context,
        targets.length > 1
            ? '已将 ${targets.length} 部游戏的会社设为「$label」'
            : '已将会社设为「$label」',
      );
    }
  }

  /// 拖拽投放的实际作用目标：编辑模式下拖已勾选卡片 = 全部勾选项，否则单卡
  List<LibraryGame> _dropTargetsFor(LibraryGame game) {
    if (_isEditMode &&
        _selectedGamePaths.contains(game.directoryPath) &&
        _selectedGamePaths.length > 1) {
      return _filteredAndSortedGames
          .where((g) => _selectedGamePaths.contains(g.directoryPath))
          .toList();
    }
    return <LibraryGame>[game];
  }

  /// 面包屑：回到库根视图
  void _backToLibraryRoot() {
    if (_activeCollectionId.isEmpty &&
        _activeSmartGroupKey.isEmpty &&
        _activeTagKeys.isEmpty) {
      return;
    }
    setState(() {
      _activeCollectionId = '';
      _activeSmartGroupKey = '';
      _activeTagKeys.clear();
      _clearSelectionOnViewChange();
    });
  }

  /// 切换右侧收藏夹栏
  void _toggleCollectionSidebar() {
    setState(() => _collectionSidebarOpen = !_collectionSidebarOpen);
    if (_collectionSidebarOpen) {
      _syncCollectionItemKeys();
      _syncSmartGroupItemKeys();
    } else {
      _dropTargetCollectionId.value = null;
      _dropTargetSmartGroupKey.value = null;
    }
  }

  /// 新建收藏夹（弹窗）
  Future<void> _createCollection() async {
    final result = await CollectionEditDialog.show(context);
    if (result == null || result.deleted) return;
    await CollectionService.instance.create(result.name, result.colorValue);
  }

  /// 编辑收藏夹（重命名/改色/删除）
  Future<void> _editCollection(GameCollection collection) async {
    final result =
        await CollectionEditDialog.show(context, existing: collection);
    if (result == null) return;

    if (result.deleted) {
      await CollectionService.instance.delete(collection.id);
      // 清理所有游戏对它的引用（game.json 内的 collection_ids）
      await LocalGameRegistry.instance
          .removeCollectionReferences(collection.id);
      return;
    }
    await CollectionService.instance.rename(collection.id, result.name);
    await CollectionService.instance.recolor(collection.id, result.colorValue);
  }

  /// 弹出「加入收藏夹」选择菜单（右键入口，单游戏 / 批量选中通用）
  void _showCollectionPicker(
      BuildContext context, List<LibraryGame> games, Offset position) {
    _dismissContextMenu();
    if (games.isEmpty) return;
    _contextMenuOverlay = OverlayEntry(
      builder: (_) => CollectionPickerMenu(
        position: position,
        games: games,
        collections: CollectionService.instance.collections,
        onToggle: (c) => _toggleGamesCollection(games, c),
        onCreate: () => _createCollection(),
        onClose: _dismissContextMenu,
      ),
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  /// 切换一组游戏与收藏夹的归属关系
  /// 批量语义：全部是成员 → 全部移出；否则 → 全部加入
  Future<void> _toggleGamesCollection(
      List<LibraryGame> games, GameCollection c) async {
    final allMember = games.every((g) => g.collectionIds.contains(c.id));
    for (final g in games) {
      await LocalGameRegistry.instance
          .setGameCollection(g, c.id, !allMember);
    }
    if (mounted) setState(() {});
  }

  // --- 管理面板设置持久化 ---
  static const String _kSortKey = 'library_panel_sort';
  static const String _kDevFilterKey = 'library_panel_dev_filter';
  static const String _kSearchKey = 'library_panel_search';
  static const String _kLayoutKey = 'library_panel_layout';

  Future<void> _loadPanelSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      final savedSort = prefs.getString(_kSortKey) ?? '';
      // 'marked_first'（标记优先）已随标记功能移除，回退到默认排序
      _activeSort = savedSort == 'marked_first' ? '' : savedSort;
      _activeDeveloperFilter = prefs.getString(_kDevFilterKey) ?? '';
      _searchQuery = prefs.getString(_kSearchKey) ?? '';
      _cardMaxExtent = prefs.getDouble(_kLayoutKey) ?? 240;
    });
    // 顶栏搜索框与持久化的搜索状态同步
    if (_topSearchController.text != _searchQuery) {
      _topSearchController.text = _searchQuery;
    }
  }

  /// 顶栏搜索框输入 → 同步过滤状态（全局搜索唯一入口）
  ///
  /// ★ P3：UI 过滤保持即时（不引入输入延迟）；仅**磁盘持久化**加 300ms 防抖，
  /// 避免每个键击触发一次 SharedPreferences 全量写、且乱序完成导致最终
  /// 持久化值停留在中间态。
  void _onTopSearchChanged() {
    if (_topSearchController.text == _searchQuery) return;
    setState(() {
      _searchQuery = _topSearchController.text;
      _clearSelectionOnViewChange(); // 可见集合变了 → 勾选失效
    });
    _searchSaveDebounce?.cancel();
    _searchSaveDebounce = Timer(const Duration(milliseconds: 300), () {
      _savePanelSetting(_kSearchKey, _topSearchController.text);
    });
  }

  Future<void> _savePanelSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    }
  }

  Future<void> _refreshFromDisk() async {
    // UX-18: 首次扫描（库为空）时显示加载指示器，避免空白
    final wasEmpty = _games.isEmpty;
    if (wasEmpty) setState(() => _isScanning = true);
    try {
      await LocalGameRegistry.instance.scan();
      _loadGames();
    } finally {
      if (wasEmpty && mounted) setState(() => _isScanning = false);
    }
  }

  /// 静默刷新：从磁盘重新读取数据并更新 UI，不重建整个页面
  /// 用于详情页修改后自动同步库页显示（游玩状态、标题、会社等）
  Future<void> _silentRefresh() async {
    await LocalGameRegistry.instance.scan();
    final games = LocalGameRegistry.instance.allGames;
    // UX-34: 静默刷新时清空封面缓存，重新解析（封面可能已变更）
    _coverPathCache.clear();
    await _applyCustomOrder(games);
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ★ 性能优化：不再在此处刷新。原先每次依赖变化（主题切换、
    // MediaQuery 变化、窗口 resize/最大化）都会触发全量重扫库 +
    // 自定义排序读取 + 封面全量解析，大库下拖拽窗口即明显卡顿。
    // 首次加载由 initState 的 _refreshFromDisk 负责；后续数据一致性
    // 由 _onRegistryChanged（结构性变化 → _loadGames）与详情弹窗关闭
    // 后的 _silentRefresh 维护，无需依赖本回调。
  }

  /// 当 LocalGameRegistry 数据变化时（如游玩时长实时更新），刷新UI
  void _onRegistryChanged() {
    if (!mounted) return;
    // UX-34: 拖拽期间延迟注册表更新，避免干扰交互
    if (_isDragging) {
      _pendingRegistryUpdate = true;
      return;
    }
    // UX-34: 区分通知类型——结构性变化需重新加载，游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      // ★ 响应式修复：structural 变更可能伴随封面替换（详情弹窗换封面/
      //   网络下载封面/元数据抓取回填），失效封面路径缓存后由
      //   _applyCustomOrder → _resolveAllCoverPaths 自动重解析
      // （与主页 _onRegistryChanged 的处理对齐）
      _coverPathCache.clear();
      _loadGames();
      _syncSmartGroupItemKeys(); // 归纳组成员/数量可能已变，重置投放命中表
    } else {
      // playTimeUpdate：游戏对象引用已被原地修改，仅需 setState 让 UI 反映新值
      setState(() {});
    }
  }

  /// UX-34: 异步预缓存所有封面路径，消除卡片 build/initState 中的同步 I/O
  Future<void> _resolveAllCoverPaths() async {
    for (final game in _games) {
      if (_coverPathCache.containsKey(game.directoryPath)) continue;
      String? resolved;
      if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
        resolved = game.coverUrl;
      } else {
        try {
          resolved = GameDataFormat.findCoverFile(game.pathForCover)?.path;
        } catch (_) {}
      }
      _coverPathCache[game.directoryPath] = resolved;
    }
    if (mounted) setState(() {});
  }

  /// 注册表 path 快照：用于跳过无意义的重载（见 didUpdateWidget）
  List<String>? _lastRegistryPaths;

  void _loadGames() {
    final games = LocalGameRegistry.instance.allGames;
    _lastRegistryPaths = games.map((g) => g.directoryPath).toList();
    _applyCustomOrder(games);
  }

  /// 上游游戏集合自上次加载后是否发生了变化
  bool _registryPathsChanged() {
    final games = LocalGameRegistry.instance.allGames;
    final last = _lastRegistryPaths;
    if (last == null || last.length != games.length) return true;
    for (var i = 0; i < games.length; i++) {
      if (last[i] != games[i].directoryPath) return true;
    }
    return false;
  }

  Future<void> _loadLaunchModes() async {
    for (final game in _games) {
      // ★ 性能优化：已读取过的游戏不再重复读盘。原实现对全部游戏逐个读取
      // game.json（O(N) 次磁盘读），而 _loadGames / _silentRefresh 每次
      // 结构性刷新都会触发一遍。首次读取后由 launch_manager_dialog 的回调
      // （_localeModes[title] = mode）保持内存值同步。
      if (_launchModesLoaded.contains(game.title)) continue;
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null) {
          if (data.localeMode.isNotEmpty) {
            _localeModes[game.title] = data.localeMode;
          }
          if (data.upscalingMode.isNotEmpty) {
            _upscalingModes[game.title] = data.upscalingMode;
          }
        }
        _launchModesLoaded.add(game.title);
      } catch (_) {}
    }
  }

  Future<void> _applyCustomOrder(List<LibraryGame> games) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrder = prefs.getStringList(_kGameOrderKey);

      if (savedOrder != null && savedOrder.isNotEmpty) {
        final orderMap = <String, int>{};
        for (var i = 0; i < savedOrder.length; i++) {
          orderMap[savedOrder[i]] = i;
        }

        final orderedGames = List<LibraryGame>.from(games);
        orderedGames.sort((a, b) {
          final indexA = orderMap[a.directoryPath] ?? -1;
          final indexB = orderMap[b.directoryPath] ?? -1;
          if (indexA != indexB) return indexA.compareTo(indexB);
          // 未登记进手动顺序的游戏（新导入）= -1 → 按用户拍板恒定**顶置**
          // （见方案 §13 决策记录）；但多个新游之间必须有确定的相对次序，
          // 否则 List.sort 的非稳定性会让它们每次刷新互相换位，
          // 表现为"卡片位置乱跳"。次级键取入库时间倒序（最新的在最前）。
          if (indexA == -1) return b.installedAt.compareTo(a.installedAt);
          return 0;
        });

        setState(() {
          _games = orderedGames;
          _gamesIdentity++; // UX-34: 手动排序缓存失效
          _syncCardKeys();
        });
        debugPrint('[LIBRARY] ✅ 已应用自定义排序 (${orderedGames.length}个)');
        _loadLaunchModes();
        _resolveAllCoverPaths(); // UX-34: 异步预缓存封面路径
      } else {
        setState(() {
          _games = games;
          _gamesIdentity++; // UX-34: 手动排序缓存失效
          _syncCardKeys();
        });
        _loadLaunchModes();
        _resolveAllCoverPaths(); // UX-34: 异步预缓存封面路径
      }
    } catch (e) {
      debugPrint('[LIBRARY] ⚠️ 应用自定义排序失败: $e');
      setState(() {
        _games = games;
        _gamesIdentity++; // UX-34: 手动排序缓存失效
        _syncCardKeys();
      });
    }
  }

  /// 卡片 key 池的键：按游戏唯一身份（game.json 的 game_id，UUID v4）。
  /// ★ 2026-10-03 修复：键此前用 directoryPath，而同一本体目录被重复导入
  /// （手动导入当时无排重）时两条目 directoryPath 相同 → 两张卡片共享
  /// 同一个 GlobalKey → Duplicate GlobalKey 异常，库页丢渲染
  /// （实锤案例：ATRI 重复导入，"共 2 部"只渲染 1 张卡）。
  /// gameId 为空时兜底退回 directoryPath（防御历史脏数据）。
  String _cardKeyOf(LibraryGame game) =>
      game.gameId.isNotEmpty ? game.gameId : game.directoryPath;

  /// 取某游戏的卡片 GlobalKey（首次访问时创建，之后恒定复用）
  GlobalKey _cardKeyFor(LibraryGame game) =>
      _cardKeyByGame.putIfAbsent(_cardKeyOf(game), () => GlobalKey());

  /// 取「渲染列表第 [index] 张卡」的 GlobalKey（索引语义仅供测距与飞行动画使用）
  GlobalKey? _cardKeyAt(int index) {
    final games = _filteredAndSortedGames;
    if (index < 0 || index >= games.length) return null;
    return _cardKeyFor(games[index]);
  }

  /// 供 GridView 在 key 发生位置移动后定位其新下标。
  ///
  /// 懒加载列表（`SliverChildBuilderDelegate`）中带 key 的子树被移动时，
  /// 框架需要这个回调才能"认出"同一个 Element 换了位置；缺失时最坏情况
  /// 会出现元素被重建（State 丢失）甚至重复 GlobalKey 异常。
  int? _indexOfCardKey(Key? key) {
    if (key == null) return null;
    final games = _filteredAndSortedGames;
    for (var i = 0; i < games.length; i++) {
      if (_cardKeyByGame[_cardKeyOf(games[i])] == key) return i;
    }
    return null;
  }

  /// 保持卡片 key 池与当前库内游戏一致（移除已不在库中的游戏，避免无界增长）
  void _syncCardKeys() {
    if (_cardKeyByGame.isEmpty) return;
    final live = _games.map(_cardKeyOf).toSet();
    _cardKeyByGame.removeWhere((key, _) => !live.contains(key));
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isDragging) return;
    // ★ 只在上游游戏集合真的变了才重载：父组件每次重建都会走到这里，
    //   而 _loadGames 会重读 prefs、重排 _games 并 setState ——
    //   无谓的重排是"卡片位置乱跳"的助因之一。
    //   内容级变更（元数据/封面/游玩状态）由 _onRegistryChanged 的 structural
    //   通知负责（features/ui_reactive_sync.md 的 11 个通知点），
    //   因此这里按注册表 path 快照比对不会漏刷新。
    if (!_registryPathsChanged()) return;
    _loadGames();
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    CollectionService.instance.removeListener(_onCollectionsChanged);
    SmartGroupService.instance.removeListener(_onSmartGroupsChanged);
    CompanyWallStore.instance.removeListener(_onCompanyWallChanged);
    TagLibraryOverrideStore.instance.removeListener(_onTagOverridesChanged);
    ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
    _scrollController.removeListener(_onScrollChanged);
    _topSearchController.removeListener(_onTopSearchChanged);
    _searchSaveDebounce?.cancel(); // ★ P3：取消未落盘的搜索持久化防抖
    _topSearchController.dispose();
    _dropTargetCollectionId.dispose();
    _dropTargetSmartGroupKey.dispose();
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _autoScrollTimer?.cancel();
    _contextMenuOverlay?.remove();
    _dragOverlay?.remove();
    _managementPanel?.remove();
    _liftAnimation.dispose();
    _insertPreviewCurve.dispose();
    _insertPreviewAnim.dispose();
    _flyAnimation.removeListener(_onFlyUpdate);
    _flyAnimation.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 打开游戏详情窗口（鼠标左键单击 / 触摸单击 / 右键菜单"详情"共用入口）。
  /// 快捷交互：单击卡片直接弹出详情，免去"先点菜单再点详情"的繁琐流程。
  void _openGameDetail(LibraryGame game) {
    debugPrint('[LIBRARY] 查看详情: ${game.title}');
    GameDetailDialog.show(
      context: context,
      directoryPath: game.pathForCover,
      onLaunchGame: () => _handleDoubleTap(game),
      initialLocaleMode: _localeModes[game.title] ?? 'none',
      initialUpscalingMode: _upscalingModes[game.title] ?? 'none',
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
      },
    ).then((_) => _silentRefresh());
  }

  void _showContextMenu(
      BuildContext context, LibraryGame game, Offset position) {
    _dismissContextMenu();
    _contextMenuOverlay = OverlayEntry(
      builder: (_) => LibraryContextMenu(
        position: position,
        onDetails: () {
          debugPrint('[LIBRARY] 右键查看详情: ${game.title}');
          _dismissContextMenu();
          _openGameDetail(game);
        },
        onLaunchManager: () {
          debugPrint('[LIBRARY] 右键启动管理: ${game.title}');
          _dismissContextMenu();
          _showLaunchManager(game);
        },
        onCollection: () {
          debugPrint('[LIBRARY] 右键加入收藏夹: ${game.title}');
          _dismissContextMenu();
          _showCollectionPicker(context, [game], position);
        },
        onDelete: () {
          _dismissContextMenu();
          widget.onDelete?.call(game.title);
        },
        onClose: _dismissContextMenu,
      ),
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  void _dismissContextMenu() {
    _contextMenuOverlay?.remove();
    _contextMenuOverlay = null;
  }

  void _startDrag(int index, Offset localPos, Offset globalPos) {
    // UX-16: 强制清理上一次未完成的 cancel 动画，避免状态竞态
    // 若 _cancelDrag 的 reverse 动画尚未结束，_dragOverlay 仍存在，
    // 会导致新拖拽无法创建 overlay（_showDragOverlay 会提前 return）。
    if (_dragOverlay != null) {
      _liftAnimation.stop();
      _insertPreviewAnim.stop();
      _removeDragOverlay();
      _originalIndex = null;
      _hoverIndex = -1;
      _hoverStartTime = null;
      _insertIndex = -1;
      _dragMode = _DragMode.swap;
      _gridBounds = null;
      _cachedCardSize = null;
      _cachedCardRects = {};
      _insertPreviewOffsets = {};
      _isEndingDrag = false;
    }

    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _gridBounds = box.paintBounds.shift(box.localToGlobal(Offset.zero));

    // 缓存实际卡片尺寸（不含 padding）
    final dragCardKey = _cardKeyAt(index);
    final dragCardBox =
        dragCardKey?.currentContext?.findRenderObject() as RenderBox?;
    if (dragCardBox != null) {
      _cachedCardSize = dragCardBox.size;
    }

    // 缓存所有卡片位置，向内收缩 8px 排除 padding 缓冲区
    _lastRecacheScrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0;
    _recacheCardRects();

    setState(() {
      _originalIndex = index;
      _hoverIndex = -1;
      _hoverStartTime = null; // BUG-08: 初始化停留时间
      _isEndingDrag = false; // BUG-07: 初始化防重入标志
      _dragAnchor = localPos;
      _dragPosition = globalPos;
      _dragMode = _DragMode.swap;
      _insertIndex = -1;
    });

    _showDragOverlay();
    _liftAnimation.forward(from: 0);
    _startAutoScroll();

    // UX-16: 拖拽开始时显示轻量提示，告知用户可拖回原位或按 ESC 取消
    AppSnackBar.info(
      context,
      '拖回原位取消 · ESC 退出',
      duration: const Duration(seconds: 1, milliseconds: 800),
    );
  }

  void _showDragOverlay() {
    if (_dragOverlay != null) return;
    final visibleGames = _filteredAndSortedGames;
    if (_originalIndex == null || _originalIndex! >= visibleGames.length) {
      return;
    }

    // 注意：网格索引基于过滤后的列表，不能直接用 _games
    final game = visibleGames[_originalIndex!];

    _dragOverlay = OverlayEntry(
      builder: (context) => LibraryDragOverlay(
        game: game,
        dragPosition: _dragPosition,
        dragAnchor: _dragAnchor,
        liftAnimation: _liftAnimation,
        cardSize: _cachedCardSize,
        coverPath: _coverPathCache[game.directoryPath], // UX-34
      ),
    );

    Overlay.of(context).insert(_dragOverlay!);
  }

  void _updateDragOverlay() {
    _dragOverlay?.markNeedsBuild();
  }

  void _removeDragOverlay() {
    _dragOverlay?.remove();
    _dragOverlay = null;
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  /// UX-16: 拖拽插入位置的垂直指示线
  /// 在目标卡片左/右边缘显示一条蓝色高亮线，明确告知用户即将插入到此位置
  Positioned _buildInsertIndicator({required bool isBefore}) {
    return Positioned(
      left: isBefore ? -3 : null,
      right: isBefore ? null : -3,
      top: 0,
      bottom: 0,
      child: Container(
        width: 4,
        decoration: BoxDecoration(
          color: AppColors.selectedAccent,
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(
              color: AppColors.selectedAccent.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }

  /// 滚动位置变化时的回调
  /// 拖拽期间手动滚动（鼠标滚轮）或自动滚动都会触发
  /// 重新缓存卡片位置并更新悬停目标
  void _onScrollChanged() {
    if (!_isDragging) return;
    _recacheCardRects();
    _updateHoverIndex(_cardCenter());
  }

  /// 重新缓存所有卡片的屏幕位置
  /// 可见卡片：从 RenderObject 获取精确位置
  /// 离屏卡片：保留上次位置并按滚动偏移修正，确保插入预览计算不会因原位置不可视而失效
  void _recacheCardRects() {
    final double currentScrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    final double scrollDelta = currentScrollOffset - _lastRecacheScrollOffset;
    _lastRecacheScrollOffset = currentScrollOffset;

    final newRects = <int, Rect>{};
    // 上界取"当前渲染列表长度"（不再是某个按位置维护的 key 列表长度）。
    // 历史修复保留：曾用 _games.length 作上界，进入收藏夹/搜索过滤后
    // filtered < _games，长按会在此处越界抛 RangeError 红屏。
    // _cachedCardRects 的键即"渲染列表索引"，与 _endDrag 的索引语义一致。
    final visibleGames = _filteredAndSortedGames;
    for (int i = 0; i < visibleGames.length; i++) {
      // key 按游戏身份取（Phase 4）：与 _buildGameGrid 中挂在卡片上的是同一个
      final key = _cardKeyFor(visibleGames[i]);
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        // 可见卡片：使用 RenderObject 的精确屏幕位置
        newRects[i] =
            renderBox.paintBounds.shift(renderBox.localToGlobal(Offset.zero));
      } else if (_cachedCardRects.containsKey(i)) {
        // 离屏卡片：按滚动偏移修正上次已知位置
        // GridView 向下滚动时（offset 增大），卡片在屏幕上向上移动
        newRects[i] = _cachedCardRects[i]!.shift(Offset(0, -scrollDelta));
      }
    }
    _cachedCardRects = newRects;
  }

  /// 拖拽期间自动滚动：鼠标靠近 GridView 上下边缘时自动滚动
  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_isDragging || !_scrollController.hasClients) {
        _autoScrollTimer?.cancel();
        return;
      }
      if (_gridBounds == null) return;

      final mouseY = _dragPosition.dy;
      final gridTop = _gridBounds!.top;
      final gridBottom = _gridBounds!.bottom;
      const edgeSize = 60.0; // 边缘触发区域大小
      const maxSpeed = 12.0; // 最大滚动速度（px/50ms）

      double scrollDelta = 0;
      if (mouseY < gridTop + edgeSize && mouseY >= gridTop) {
        // 靠近上边缘，向上滚动
        final factor = 1.0 - (mouseY - gridTop) / edgeSize;
        scrollDelta = -maxSpeed * factor;
      } else if (mouseY > gridBottom - edgeSize && mouseY <= gridBottom) {
        // 靠近下边缘，向下滚动
        final factor = 1.0 - (gridBottom - mouseY) / edgeSize;
        scrollDelta = maxSpeed * factor;
      }

      if (scrollDelta != 0) {
        final newOffset = (_scrollController.offset + scrollDelta)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.jumpTo(newOffset);
        // 滚动监听器 _onScrollChanged 会自动处理缓存更新和悬停检测
      }
    });
  }

  void _updateDrag(Offset globalPos) {
    if (_gridBounds == null || _originalIndex == null) return;

    setState(() {
      _dragPosition = globalPos;
    });
    _updateDragOverlay();

    // 使用卡片中心点作为判定点，而非鼠标位置
    // 这样无论用户从卡片哪个位置按下，判定都跟手
    final center = _cardCenter();

    // 先检测收藏夹侧栏投放目标（悬停高亮 + 松手归类）
    if (_updateDropTargetCollection(center)) {
      // 悬停在侧栏条目上：清除网格重排预览，避免两套目标同时生效
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;
      if (_hoverIndex != -1 || _insertIndex != -1) {
        setState(() {
          _hoverIndex = -1;
          _insertIndex = -1;
          _dragMode = _DragMode.swap;
          _hoverStartTime = null;
        });
        _insertPreviewAnim.reverse();
      }
      return;
    }

    // 再检测智能归纳条目（拖到标签组 = 给游戏加该标签；拖到会社组 = 设该会社）
    if (_updateDropTargetSmartGroup(center)) {
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;
      if (_hoverIndex != -1 || _insertIndex != -1) {
        setState(() {
          _hoverIndex = -1;
          _insertIndex = -1;
          _dragMode = _DragMode.swap;
          _hoverStartTime = null;
        });
        _insertPreviewAnim.reverse();
      }
      return;
    }

    _updateHoverIndex(center);
  }

  /// 拖拽时检测卡片中心是否悬停在侧栏收藏夹条目上
  /// 命中时更新 [_dropTargetCollectionId]（条目高亮），返回是否命中
  bool _updateDropTargetCollection(Offset point) {
    String? hitId;
    if (_collectionSidebarOpen) {
      for (final entry in _collectionItemKeys.entries) {
        final context = entry.value.currentContext;
        if (context == null) continue;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.contains(point)) {
          hitId = entry.key;
          break;
        }
      }
    }
    if (_dropTargetCollectionId.value != hitId) {
      _dropTargetCollectionId.value = hitId;
    }
    // 收藏夹与归纳条目互斥高亮：命中收藏夹时清掉归纳高亮
    if (hitId != null) _dropTargetSmartGroupKey.value = null;
    return hitId != null;
  }

  /// 拖拽时检测卡片中心是否悬停在「智能归纳」条目上
  bool _updateDropTargetSmartGroup(Offset point) {
    String? hitKey;
    if (_collectionSidebarOpen) {
      for (final entry in _smartGroupItemKeys.entries) {
        final context = entry.value.currentContext;
        if (context == null) continue;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.contains(point)) {
          hitKey = entry.key;
          break;
        }
      }
    }
    if (_dropTargetSmartGroupKey.value != hitKey) {
      _dropTargetSmartGroupKey.value = hitKey;
    }
    if (hitKey != null) _dropTargetCollectionId.value = null;
    return hitKey != null;
  }

  /// 使用缓存的卡片位置进行悬停检测
  /// 判定点为被拖动卡片的中心点（由调用方传入）
  /// 基于判定点在目标卡片内的水平位置区分交换/插入模式：
  /// - 左 15% → 插入到该卡片前面（需停留 300ms）
  /// - 右 15% → 插入到该卡片后面（需停留 300ms）
  /// - 中间 70% → 交换（立即触发）
  /// 如果判定点不在任何卡片内，则回退到距离最近的卡片（默认交换模式）
  void _updateHoverIndex(Offset point) {
    if (_originalIndex == null) return;

    int foundIndex = -1;
    _DragMode foundMode = _DragMode.swap;

    // BUG-08: 检测是否拖回原位 → 视为取消操作
    final origRect = _cachedCardRects[_originalIndex!];
    if (origRect != null && origRect.contains(point)) {
      // 拖回原位 → 标记为取消
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;
      if (_hoverIndex != _originalIndex || _dragMode != _DragMode.swap) {
        setState(() {
          _hoverIndex = _originalIndex!;
          _dragMode = _DragMode.swap;
          _insertIndex = -1;
          _hoverStartTime = DateTime.now();
        });
        _insertPreviewAnim.reverse();
      }
      return; // 拖回原位时不继续检测其他卡片
    }

    // 第一轮：检测判定点是否在某张卡片内部
    for (int i = 0; i < _games.length; i++) {
      if (i == _originalIndex) continue;

      final boxRect = _cachedCardRects[i];
      if (boxRect == null) continue;

      if (boxRect.contains(point)) {
        foundIndex = i;

        // 根据判定点在卡片内的水平位置判断模式
        final relativeX = (point.dx - boxRect.left) / boxRect.width;
        if (relativeX < 0.15) {
          foundMode = _DragMode.insertBefore;
        } else if (relativeX > 0.85) {
          foundMode = _DragMode.insertAfter;
        } else {
          foundMode = _DragMode.swap;
        }
        break;
      }
    }

    // 第二轮：判定点不在任何卡片内时，回退到距离最近的卡片
    // 这解决了卡片间距导致的"空隙"问题，确保判定始终精准
    if (foundIndex == -1 &&
        _gridBounds != null &&
        _gridBounds!.contains(point)) {
      double minDist = double.infinity;
      for (int i = 0; i < _games.length; i++) {
        if (i == _originalIndex) continue;

        final boxRect = _cachedCardRects[i];
        if (boxRect == null) continue;

        final dist = (point - boxRect.center).distance;
        if (dist < minDist) {
          minDist = dist;
          foundIndex = i;
          foundMode = _DragMode.swap; // 回退时默认交换模式
        }
      }
    }

    if (foundIndex != -1) {
      if (foundMode == _DragMode.swap) {
        // 交换模式：立即触发，取消插入延迟计时器
        _insertDelayTimer?.cancel();
        _insertDelayTimer = null;
        _pendingInsertIndex = -1;

        final needUpdate =
            _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
        if (needUpdate) {
          setState(() {
            _hoverIndex = foundIndex;
            _dragMode = _DragMode.swap;
            _insertIndex = -1;
            _hoverStartTime = DateTime.now(); // BUG-08: 记录停留起始时间
          });
          _insertPreviewAnim.reverse();
        }
      } else {
        // 插入模式：需要停留 300ms 才触发
        final pendingInsertIdx =
            foundMode == _DragMode.insertBefore ? foundIndex : foundIndex + 1;

        // 如果鼠标在同一张卡片的同一边缘区域移动，保持计时器
        if (_pendingInsertIndex != pendingInsertIdx ||
            _pendingInsertMode != foundMode) {
          // 切换了目标或模式，重新开始计时
          _insertDelayTimer?.cancel();

          // 先切换到交换模式作为过渡（立即反馈）
          final needUpdate =
              _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
          if (needUpdate) {
            setState(() {
              _hoverIndex = foundIndex;
              _dragMode = _DragMode.swap;
              _insertIndex = -1;
              _hoverStartTime = DateTime.now(); // BUG-08: 记录停留起始时间
            });
            _insertPreviewAnim.reverse();
          }

          _pendingInsertIndex = pendingInsertIdx;
          _pendingInsertMode = foundMode;

          _insertDelayTimer = Timer(const Duration(milliseconds: 300), () {
            if (!_isDragging) return;
            // 停留足够时间，激活插入模式
            // 先设置 _insertIndex，再计算偏移（_calculateInsertOffsets 依赖 _insertIndex）
            setState(() {
              _dragMode = foundMode;
              _insertIndex = pendingInsertIdx;
            });
            _insertPreviewOffsets = _calculateInsertOffsets();
            _insertPreviewAnim.forward();
          });
        }
        // 同一区域移动：不做任何变化，等待计时器
      }
    } else {
      // 鼠标不在任何卡片上
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;

      if (_hoverIndex != -1 || _insertIndex != -1) {
        setState(() {
          _hoverIndex = -1;
          _insertIndex = -1;
          _dragMode = _DragMode.swap;
          _hoverStartTime = null; // BUG-08: 重置停留时间
        });
        _insertPreviewAnim.reverse();
      }
    }
  }

  /// 计算插入重排后每个卡片的原始索引 → 预览索引映射
  Map<int, int> _calculatePreviewIndexMap() {
    if (_originalIndex == null || _insertIndex == -1) return {};

    final indexMap = <int, int>{};
    final origIdx = _originalIndex!;
    int targetIndex = _insertIndex;
    if (origIdx < targetIndex) targetIndex--;
    targetIndex = targetIndex.clamp(0, _games.length - 1);

    for (int i = 0; i < _games.length; i++) {
      if (i == origIdx) {
        indexMap[i] = targetIndex;
      } else if (origIdx < targetIndex) {
        // 向后插入：origIdx+1 到 targetIndex 的卡片前移一位
        if (i > origIdx && i <= targetIndex) {
          indexMap[i] = i - 1;
        } else {
          indexMap[i] = i;
        }
      } else {
        // 向前插入：targetIndex 到 origIdx-1 的卡片后移一位
        if (i >= targetIndex && i < origIdx) {
          indexMap[i] = i + 1;
        } else {
          indexMap[i] = i;
        }
      }
    }
    return indexMap;
  }

  /// 计算插入预览时每个卡片需要的像素偏移
  Map<int, Offset> _calculateInsertOffsets() {
    final indexMap = _calculatePreviewIndexMap();
    final offsets = <int, Offset>{};

    for (final entry in indexMap.entries) {
      final origIdx = entry.key;
      final previewIdx = entry.value;
      if (origIdx == previewIdx) continue;

      final fromRect = _cachedCardRects[origIdx];
      final toRect = _cachedCardRects[previewIdx];
      if (fromRect != null && toRect != null) {
        offsets[origIdx] = Offset(
          toRect.left - fromRect.left,
          toRect.top - fromRect.top,
        );
      }
    }
    return offsets;
  }

  void _endDrag() {
    // BUG-07: 防止全局 Listener 和卡片 Listener 双重调用
    if (_isEndingDrag) return;
    _isEndingDrag = true;

    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _autoScrollTimer?.cancel();
    _insertPreviewAnim.reverse();

    // 收藏夹投放：卡片拖到侧栏收藏夹条目上松手 → 归类（不触发网格重排）
    final dropTargetId = _dropTargetCollectionId.value;
    if (dropTargetId != null && _originalIndex != null) {
      final game = _filteredAndSortedGames[_originalIndex!];
      final collection = CollectionService.instance.byId(dropTargetId);
      _dropTargetCollectionId.value = null;
      _cancelDrag();
      if (collection != null) {
        // 批量管理联动：编辑模式下拖动的是选中的卡片 → 所有选中游戏一起归类
        final targets = (_isEditMode &&
                _selectedGamePaths.contains(game.directoryPath) &&
                _selectedGamePaths.length > 1)
            ? _filteredAndSortedGames
                .where((g) => _selectedGamePaths.contains(g.directoryPath))
                .toList()
            : <LibraryGame>[game];

        debugPrint(
            '[LIBRARY] 📥 拖拽归类: ${targets.length} 部 → ${collection.name}');
        Future.wait(targets
                .map((g) => LocalGameRegistry.instance
                    .setGameCollection(g, dropTargetId, true)))
            .then((_) {
          if (!mounted) return;
          setState(() {});
          AppSnackBar.success(
            context,
            targets.length > 1
                ? '已将 ${targets.length} 部游戏加入「${collection.name}」'
                : '已加入「${collection.name}」',
          );
        });
      }
      return;
    }

    // 智能归纳投放：拖到标签组 = 给游戏加上该标签；拖到会社组 = 设该会社
    // （写穿到游戏数据本身，分组随之实时变化；不触发网格重排）
    final dropSmartKey = _dropTargetSmartGroupKey.value;
    if (dropSmartKey != null && _originalIndex != null) {
      final game = _filteredAndSortedGames[_originalIndex!];
      _dropTargetSmartGroupKey.value = null;
      _cancelDrag();
      _applySmartGroupDrop(dropSmartKey, game);
      return;
    }

    // BUG-08-1: 拖回原位或无目标 → 自动取消
    if (_hoverIndex == _originalIndex || _hoverIndex == -1) {
      _cancelDrag();
      return;
    }
    // BUG-08-2: 交换模式停留确认（≥200ms 才执行交换，快速滑过视为取消）
    if (_dragMode == _DragMode.swap) {
      final dwellTime = _hoverStartTime != null
          ? DateTime.now().difference(_hoverStartTime!)
          : Duration.zero;
      if (dwellTime < const Duration(milliseconds: 200)) {
        _cancelDrag();
        return;
      }
    }

    // ★ 归属层守卫（防御纵深）：视图不允许拖拽时一律不动数据。
    //   起拖阶段已由 _canReorderByDrag 拦截，这里兜住"拖到一半切换了筛选/收藏夹"
    //   的竞态——阻止"用可见列表的索引去改全量列表"这一 P0 复发。
    final target = _reorderTarget;
    if (target == ReorderTarget.none) {
      _cancelDrag();
      return;
    }

    // 🔴 渲染列表 = 操作列表：索引取自哪个列表，就在哪个列表上重排。
    //    原实现用 _games（全量）套用筛选后列表的索引，是 P0 的根因。
    final display = _filteredAndSortedGames;

    if (_dragMode == _DragMode.swap &&
        _originalIndex != null &&
        _hoverIndex != -1 &&
        _hoverIndex != _originalIndex) {
      // 模式 A：直接交换
      final swapped = swapDisplayItems(display, _originalIndex!, _hoverIndex);
      _commitReorder(target, swapped);
    } else if ((_dragMode == _DragMode.insertBefore ||
            _dragMode == _DragMode.insertAfter) &&
        _originalIndex != null &&
        _insertIndex != -1) {
      // 模式 B：插入重排
      final moved = display[_originalIndex!];
      final reordered =
          insertDisplayItem(display, _originalIndex!, _insertIndex);
      final targetIndex = reordered.indexOf(moved); // 移除后索引已左移，用查找取值
      _commitReorder(target, reordered);

      // 插入重排：浮动卡片直接飞到目标位置，不回原位
      _animateOverlayToTarget(targetIndex);
      return; // 动画完成后会在回调中清理状态
    }

    // 交换模式或无效操作：浮动卡片回到原位
    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _hoverStartTime = null; // BUG-08: 清理停留时间
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
        _isEndingDrag = false; // BUG-07: 重置防重入标志
      });
      _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
    });
  }

  /// 把「显示列表的新顺序」落成对应层的顺序。
  ///
  /// 🔴 全局顺序只能经 [resolveGlobalOrderAfterDrag] 写入：当目标是
  /// `collectionOrder` / `none` 时该函数**原样返回**全局列表，
  /// 从构造上杜绝"在收藏夹/筛选视图拖拽写乱全局手动顺序"这一 P0。
  void _commitReorder(
      ReorderTarget target, List<LibraryGame> reorderedDisplay) {
    if (target == ReorderTarget.collectionOrder) {
      // 收藏夹内独立顺序：只写本收藏夹的 game_order，**不动**全局顺序，
      // 也不调用 _saveGameOrder()（那是全局手动顺序的落盘入口）。
      final order =
          reorderedDisplay.map((g) => g.directoryPath).toList();
      CollectionService.instance
          .setGameOrder(_activeCollectionId, order)
          .then((_) {
        if (!mounted) return;
        setState(() => _collectionOrderRevision++); // 过滤缓存失效
      });
      return;
    }

    final newGlobal = resolveGlobalOrderAfterDrag(
      globalList: _games,
      reorderedDisplay: reorderedDisplay,
      target: target,
    );
    if (identical(newGlobal, _games)) {
      // 目标非 globalOrder（起拖阶段已拦截，此处为防御）
      setState(() {});
      return;
    }
    setState(() {
      _games = List<LibraryGame>.from(newGlobal);
      _gamesIdentity++; // UX-34: 手动排序缓存失效
      _syncCardKeys();
    });
    _saveGameOrder();
  }

  /// 飞行动画帧更新
  void _onFlyUpdate() {
    if (!_isFlying) return;
    final t = Curves.easeOutCubic.transform(_flyAnimation.value);
    _dragPosition = Offset.lerp(_flyFrom, _flyTo, t)!;
    _dragAnchor = Offset.zero;
    _updateDragOverlay();
  }

  /// 插入重排时：浮动卡片飞到目标位置
  void _animateOverlayToTarget(int targetIndex) {
    // 先 setState 更新网格（卡片已在目标位置），但浮动卡片仍显示
    setState(() {
      _hoverIndex = -1;
      _insertIndex = -1;
      _dragMode = _DragMode.swap;
      _insertPreviewOffsets = {};
    });

    // 等 build 完成后获取目标卡片的位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetKey = _cardKeyAt(targetIndex);
      final renderBox =
          targetKey?.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize && _dragOverlay != null) {
        final targetPos = renderBox.localToGlobal(Offset.zero);

        // 启动飞行动画：从当前位置平滑飞到目标位置
        _flyFrom = _dragPosition - _dragAnchor;
        _flyTo = targetPos;
        _isFlying = true;
        _flyAnimation.forward(from: 0).then((_) {
          _isFlying = false;
          // 飞到目标后，缩小 + 淡出
          _liftAnimation.reverse().then((_) {
            _removeDragOverlay();
            setState(() {
              _originalIndex = null;
              _dragPosition = Offset.zero;
              _dragAnchor = Offset.zero;
              _gridBounds = null;
              _cachedCardSize = null;
              _cachedCardRects = {};
              _isEndingDrag = false; // BUG-07: 重置防重入标志
            });
            _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
          });
        });
      } else {
        // 无法获取目标位置，直接回原位
        _liftAnimation.reverse().then((_) {
          _removeDragOverlay();
          setState(() {
            _originalIndex = null;
            _dragPosition = Offset.zero;
            _dragAnchor = Offset.zero;
            _hoverIndex = -1;
            _hoverStartTime = null; // BUG-08: 清理停留时间
            _insertIndex = -1;
            _dragMode = _DragMode.swap;
            _gridBounds = null;
            _cachedCardSize = null;
            _cachedCardRects = {};
            _insertPreviewOffsets = {};
            _isEndingDrag = false; // BUG-07: 重置防重入标志
          });
          _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
        });
      }
    });
  }

  void _cancelDrag() {
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _autoScrollTimer?.cancel();
    _isFlying = false;
    _flyAnimation.stop();
    _insertPreviewAnim.reverse();
    _dropTargetCollectionId.value = null; // 清理收藏夹投放高亮
    _dropTargetSmartGroupKey.value = null; // 清理智能归纳投放高亮
    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _hoverStartTime = null; // BUG-08: 清理停留时间
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
        _isEndingDrag = false; // BUG-07: 重置防重入标志
      });
      _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
    });
  }

  /// UX-34: 拖拽结束后处理延迟的注册表更新
  void _processPendingRegistryUpdate() {
    if (_pendingRegistryUpdate) {
      _pendingRegistryUpdate = false;
      // 延迟到下一帧，避免与拖拽清理动画冲突
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onRegistryChanged();
      });
    }
  }

  Future<void> _saveGameOrder() async {
    try {
      final order = _games.map((g) => g.directoryPath).toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kGameOrderKey, order);
      debugPrint('[LIBRARY] ✅ 已保存游戏排序 (${order.length}个)');
    } catch (e) {
      debugPrint('[LIBRARY] ⚠️ 保存游戏排序失败: $e');
    }
  }

  void _handleDoubleTap(LibraryGame game) async {
    debugPrint('[LAUNCH] ========== 双击启动: ${game.title} ==========');

    // ★ H11: UI 层双重启动保护
    // resolveUserChoice 是异步操作，快速双击会导致两次 resolveUserChoice 并行执行，
    // 虽然最终都会被 GameLaunchService._isLaunching 拦截，但 UI 层提前拦截
    // 可避免重复执行磁盘 I/O 和重复弹 SnackBar，提升用户体验。
    if (_isLaunching) {
      debugPrint('[LAUNCH] ⏭️ UI 层拦截：上一次启动仍在进行中');
      return;
    }
    _isLaunching = true;
    try {
      // 🔴 方案 §11.1 场景 6（§18.2 遗留落地）：打包态点「打开游戏」→
      //    引导解包（体积/耗时/目标明示 → 确认 → 后台解包）→ 完成后自动启动。
      //    仅接入库页双击主路径；主页/BPM/快捷方式入口见方案 §23 范围说明。
      if (GameStorageState.fromWire(game.storageState) ==
          GameStorageState.packed) {
        final unpacked = await _unpackPackedGame(game);
        if (unpacked != true) return;
        // 解包成功：game.storageState 已回写 normal，继续走既有启动流程。
      }
      final exePath =
          await GameLaunchService.instance.resolveUserChoice(game.title);

      if (exePath != null) {
        await _executeLaunch(game, exePath);
      } else {
        debugPrint('[LAUNCH] 无已保存的启动程序，弹出选择器');
        // ★ P3：await 弹窗关闭。原先未 await，finally 立即复位 _isLaunching，
        // 弹窗打开期间再双击可重复弹出多个选择器。
        await _showExeSelector(game);
      }
    } finally {
      _isLaunching = false;
    }
  }

  /// 打包态双击 → 引导解包（方案 §11.1 场景 6，§18.2 遗留落地）。
  ///
  /// 返回 `true` = 已解包成功（可继续启动）；`false` = 用户取消或失败。
  /// 🔴 解包走 [GameArchiveService.unpack]（目标存在即拒绝、空间预检、
  ///    `7z t` 先行）；状态回写成功后才返回 —— 与 GameDataDialog._unpack 一致。
  Future<bool> _unpackPackedGame(LibraryGame game) async {
    // 1. 定位最新打包归档（listArchives 新→旧排序）
    List<ArchiveRecord> archives;
    try {
      archives = await GameArchiveService.instance.listArchives(game);
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '读取归档库失败：$e');
      return false;
    }
    ArchiveRecord? rec;
    for (final r in archives) {
      if (r.state == 'packed') {
        rec = r;
        break;
      }
    }
    final body = rec?.manifest.body;
    if (rec == null || body == null || body.originalDir.isEmpty) {
      if (mounted) {
        AppSnackBar.error(context,
            '未找到可解包的打包归档，请到详情窗口「备份」→「游戏数据」查看');
      }
      return false;
    }

    // 2. 确认框：目标绝对路径 + 体积 + 预计耗时（吞吐预算 5–20 MB/s，方案 §6）
    final etaFast = _unpackEta(body.unpackedBytes, 20);
    final etaSlow = _unpackEta(body.unpackedBytes, 5);
    // 闭包内不能依赖类型提升（rec 为可空局部变量）—— 提前取好值
    final archiveSizeText = FileSizePrefetchService.formatBytes(rec.bodyBytes);
    final needSizeText = FileSizePrefetchService.formatBytes(body.unpackedBytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border, width: 2),
        ),
        title: Text(
          '已打包',
          style: TextStyle(
              fontSize: 20, letterSpacing: 1.2, color: AppColors.border),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            '「${game.title}」的本体已存入归档库，需先解包才能启动。\n\n'
            '解包目标：\n${body.originalDir}\n\n'
            '归档体积 $archiveSizeText，'
            '需要约 $needSizeText 磁盘空间，'
            '预计 $etaFast ~ $etaSlow（视磁盘速度）。',
            style: TextStyle(
                fontSize: 14, color: AppColors.primaryText, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('解包并启动',
                style: TextStyle(
                    color: AppColors.selectedAccent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;

    // 3. 进度对话框（不可关闭）+ 解包
    final progress = ValueNotifier<int>(0);
    ArchiveOperationResult? result;
    Object? error;
    try {
      final dialogFuture = showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: Dialog(
            backgroundColor: AppColors.background,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppColors.border, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
              child: ValueListenableBuilder<int>(
                valueListenable: progress,
                builder: (_, v, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('正在解包「${game.title}」',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryText)),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: v / 100,
                        minHeight: 6,
                        backgroundColor: AppColors.border.withOpacity(0.25),
                        valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.selectedAccent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('完成后将自动启动 · $v%',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.secondaryText)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      result = await GameArchiveService.instance.unpack(
        record: rec,
        onProgress: (pct) => progress.value = pct,
      );
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialogFuture;
    } catch (e) {
      error = e;
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    progress.dispose();
    if (!mounted) return false;

    if (error != null) {
      AppSnackBar.error(context, '解包失败：$error');
      return false;
    }
    if (result!.cancelled) {
      AppSnackBar.warning(context, '已取消解包');
      return false;
    }
    if (!result.ok) {
      AppSnackBar.error(context, '解包失败：${result.error ?? '未知错误'}');
      return false;
    }

    // 4. 状态回写 normal（unpack 服务层不回写，与 GameDataDialog._unpack 一致）
    await LocalGameRegistry.instance.setStorageState(
      game,
      storageState: 'normal',
      archiveDir: '',
      archiveAt: '',
    );
    if (mounted) setState(() {});
    return true;
  }

  /// 吞吐预算（方案 §6：5–20 MB/s）→ 预计耗时文本。
  static String _unpackEta(int bytes, int mbPerSec) {
    final sec = (bytes / (1024 * 1024) / mbPerSec).ceil();
    if (sec < 60) return '$sec 秒';
    return '${(sec / 60).ceil()} 分钟';
  }

  /// 转发到 [GameLaunchService.executeLaunch] 并处理 UI 反馈
  ///
  /// 保持原桌面模式行为: 启动成功 → setState 刷新卡片;失败 → SnackBar 提示。
  /// 同时同步更新 [_localeModes]/[_upscalingModes] 内存缓存。
  Future<void> _executeLaunch(
    LibraryGame game,
    String exePath,
  ) async {
    final result = await GameLaunchService.instance.executeLaunch(
      game,
      exePath,
    );

    // 同步内存缓存 (供 ExeSelectorDialog 显示初始状态)
    _localeModes[game.title] = result.localeMode;
    _upscalingModes[game.title] = result.upscalingMode;

    if (!mounted) return;
    setState(() {}); // 同步卡片上的游玩状态显示

    if (!result.success) {
      AppSnackBar.error(
        context,
        result.error ?? '无法启动「${game.title}」',
      );
    }
  }

  /// 弹出启动程序选择器
  ///
  /// ★ P3：返回 [ExeSelectorDialog.show] 的 Future（弹窗关闭时完成），
  /// 供调用方 await 以维持双重启动保护标志，防止弹窗期间重复弹出。
  Future<void> _showExeSelector(LibraryGame game) {
    final currentLocale = _localeModes[game.title] ?? 'none';
    final currentUpscaling = _upscalingModes[game.title] ?? 'none';

    return ExeSelectorDialog.show(
      context: context,
      gameDirectory: game.directoryPath,
      initialExePath: null,
      initialLocaleMode: currentLocale,
      initialUpscalingMode: currentUpscaling,
      onSelected: (selectedExe) async {
        await _executeLaunch(game, selectedExe);
      },
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'locale_mode': mode});
        }
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'upscaling_mode': mode});
        }
      },
    );
  }

  void _showLaunchManager(LibraryGame game) async {
    // ★ P0-2：启动路径的唯一事实源是 game.json.launch_path。
    //   旧实现在这里自己拼了一套"先读配置文件、再读 prefs"的顺序，
    //   与真正启动时走的 GameLaunchService 顺序并不一致 ——
    //   同一个游戏在「启动」和「启动管理弹窗」里可能显示不同的 exe。
    //   现在统一走 resolveUserChoice（含历史存储的一次性迁移）。
    final currentPath =
        await GameLaunchService.instance.resolveUserChoice(game.title);
    final String? displayExe = currentPath;

    final currentLocale = _localeModes[game.title] ?? 'none';
    final currentUpscaling = _upscalingModes[game.title] ?? 'none';

    if (!mounted) return;

    await LaunchManagerDialog.show(
      context: context,
      gameTitle: game.title,
      gameDirectory: game.directoryPath,
      metaDataDir: game.metaDataDir,
      initialExePath: displayExe,
      initialLocaleMode: currentLocale,
      initialUpscalingMode: currentUpscaling,
      onExeSelected: (selectedExe) async {
        await GameLaunchService.instance
            .persistUserChoice(game.title, selectedExe);
        if (!mounted) return;
        AppSnackBar.info(
          context,
          '已更新「${game.title}」的启动程序',
          duration: const Duration(seconds: 2),
        );
      },
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'locale_mode': mode});
        }
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'upscaling_mode': mode});
        }
      },
    );

    if (mounted) _silentRefresh();
  }

  void _showBatchShortcutDialog([List<LibraryGame>? presetGames]) async {
    final games = presetGames ?? LocalGameRegistry.instance.allGames;
    final eligibleGames = games.where((g) => g.launchPath.isNotEmpty).toList();

    if (eligibleGames.isEmpty) {
      AppSnackBar.warning(
        context,
        '没有可生成快捷方式的游戏（需要先设置启动程序）',
        duration: Duration(seconds: 2),
      );
      return;
    }

    // 预计算快捷方式状态
    final shortcutStatus = <String, bool>{};
    for (final game in eligibleGames) {
      shortcutStatus[game.title] =
          ShortcutService.instance.hasShortcut(game.title);
    }

    final selectedTitles = <String>{};
    for (final game in eligibleGames) {
      if (!shortcutStatus[game.title]!) {
        selectedTitles.add(game.title);
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => BatchShortcutDialog(
        games: eligibleGames,
        shortcutStatus: shortcutStatus,
        initialSelected: selectedTitles,
      ),
    );

    if (mounted) _silentRefresh();
  }

  @override
  Widget build(BuildContext context) {
    // BUG-07: 全局 Listener 捕获拖拽期间的指针事件
    // 解决拖拽开始后指针离开卡片区域导致事件丢失、拖拽卡死的问题
    return Listener(
      onPointerMove: _isDragging
          ? (event) {
              if (_isEndingDrag) return;
              _updateDrag(event.position);
            }
          : null,
      onPointerUp: _isDragging
          ? (event) {
              if (_isEndingDrag) return;
              _endDrag();
            }
          : null,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: AppColors.pageBackground,
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
        child: Row(
          children: [
            // 网格区域（侧栏展开时被排挤，保持可交互）
            Expanded(
              child: Stack(
                children: [
                  // 网格铺满整个区域，顶部内容从悬浮顶栏下方滚过
                  _buildGameGrid(),
                  // UX-18: 扫描期间显示加载遮罩，否则显示空状态遮罩
                  if (_games.isEmpty)
                    _isScanning
                        ? _buildScanningOverlay()
                        : _buildEmptyOverlay(),
                  // 分类匣联动：筛选无匹配时的轻量提示（多维度叠加时用组合提示）
                  if (_games.isNotEmpty &&
                      _filteredAndSortedGames.isEmpty) ...[
                    if (_activeContextDimCount >= 2)
                      _buildEmptyComboOverlay()
                    else if (_activeCollectionId.isNotEmpty)
                      _buildEmptyCollectionOverlay()
                    else if (_activeTagKeys.isNotEmpty &&
                        _activeSmartGroupKey.isEmpty)
                      _buildEmptyTagSelectionOverlay()
                    else if (_activeSmartGroupKey.isNotEmpty)
                      _buildEmptySmartGroupOverlay(),
                  ],
                  // 编辑模式底部操作栏
                  //
                  // 进入管理模式即常驻（原条件额外要求"至少勾选 1 个"，
                  // 导致底部栏"不选游戏就不出现"，用户找不到批量入口）；
                  // 0 勾选时批量钮由 _editBarBtn 的 enabled 参数置灰。
                  if (_isEditMode)
                    Positioned(
                      bottom: 16,
                      left: 0,
                      right: 0,
                      child: _buildEditModeBar(),
                    ),
                  // 库页顶部栏：悬浮于网格上方（半透明背景，不占布局空间，
                  // 固定不随列表滚动；卡片滚动经过时从顶栏底下透出可见）
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildTopBar(),
                  ),
                ],
              ),
            ),
            // 右侧分类匣（宽度动画滑入；三视图：收藏夹/标签库/会社墙）
            CategoryBoxSidebar(
              open: _collectionSidebarOpen,
              // —— 收藏夹 ——
              collections: CollectionService.instance.collections,
              activeCollectionId: _activeCollectionId,
              gameCountOf: _gameCountOf,
              itemKeys: _collectionItemKeys,
              dropTargetId: _dropTargetCollectionId,
              onEnterCollection: _enterCollection,
              onCreate: _createCollection,
              onEdit: _editCollection,
              // —— 标签库 ——
              tagSections: _tagSections,
              onToggleTag: _toggleTagKey,
              // —— 标签库内联编辑 ——
              onRenameTag: _onRenameTag,
              onRemoveTag: _onRemoveTag,
              onToggleHideTag: _onToggleHideTag,
              onMoveTagToDim: _onMoveTagToDim,
              onRenameDimension: _onRenameDimension,
              onAddDimension: _onAddDimension,
              // —— 会社墙 ——
              companies: _companyCards,
              onEnterCompany: _enterSmartGroup,
              onToggleFollowCompany: _toggleFollowCompany,
              onAddCompany: _addCompany,
              onEditCompany: _editCompany,
              // —— 标签/会社拖拽投放（原智能归纳命中机制复用）——
              smartItemKeys: _smartGroupItemKeys,
              smartDropTargetId: _dropTargetSmartGroupKey,
              onClose: () =>
                  setState(() => _collectionSidebarOpen = false),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 库页顶部栏 ====================

  /// 顶部栏（从右到左）：收藏夹按钮 · 批量管理 · 搜索+统计 · 面包屑
  ///
  /// 悬浮式设计：半透明背景 + 不占布局空间；卡片滚动经过顶栏底下时透出可见。
  /// 背景用 AppColors.background（真实主题底色，跟随主题设计器），
  /// 不能用 pageBackground——带背景图的主题下它是 Colors.transparent，
  /// withOpacity 后会变成黑色半透明。
  Widget _buildTopBar() {
    final activeCollection =
        CollectionService.instance.byId(_activeCollectionId);
    final visibleCount = _games.isEmpty ? 0 : _filteredAndSortedGames.length;

    return Container(
      height: 38,
      decoration: BoxDecoration(
        // 半透明主题底色：滚动经过的卡片可透出，同时保证顶栏文字可读
        color: AppColors.background.withOpacity(0.82),
      ),
      child: Row(
        // 左右留白：让功能区域与页面边缘拉开距离，整体更舒展
        children: [
          const SizedBox(width: 12),
          // 面包屑：游戏库 / 游戏库 > 收藏夹名
          _buildBreadcrumb(activeCollection),
          const Spacer(),
          // 搜索框（原管理面板搜索已迁移至此）
          _buildTopSearchField(),
          const SizedBox(width: 18),
          // 游戏总数统计（跟随当前过滤结果）
          Text(
            '共 $visibleCount 部',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 22),
          // 批量管理按钮（原设计原样迁移：编辑模式含筛选面板入口）
          _buildManageButton(),
          const SizedBox(width: 10),
          // 收藏夹按钮：切换右侧收藏夹栏
          _buildCollectionsButton(),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  /// 面包屑导航：库根显示「游戏库」；叠加筛选时显示组合链
  /// 「游戏库 > [收藏夹] > [会社] > [标签]（+ 总数）」，
  /// 点击任一条件**单独移除**（分类匣联动升级 2026-10-04）。
  Widget _buildBreadcrumb(GameCollection? activeCollection) {
    final smartGroup = _activeSmartGroup;
    final hasCollection = activeCollection != null;
    final hasTags = _activeTagKeys.isNotEmpty;

    // 库根视图（无任何叠加条件）
    if (!hasCollection && smartGroup == null && !hasTags) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videogame_asset_outlined,
              size: 18, color: AppColors.secondaryText),
          const SizedBox(width: 8),
          Text(
            '游戏库',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: AppColors.primaryText,
            ),
          ),
        ],
      );
    }

    // 组合链节点：[图标] 名称，点击移除该条件
    Widget crumb(Widget icon, String label, VoidCallback onRemove) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() {
            onRemove();
            _clearSelectionOnViewChange();
          }),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget separator() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 6),
            Icon(Icons.chevron_right,
                size: 16, color: AppColors.placeholderText),
            const SizedBox(width: 6),
          ],
        );

    final chips = <Widget>[];

    // ① 收藏夹
    if (hasCollection) {
      final color = Color(activeCollection.colorValue);
      chips.add(crumb(
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        activeCollection.name,
        () => _activeCollectionId = '',
      ));
      // 存在自定义顺序时才出现：一键回到全局顺序（否则拖乱了无法回头）
      if (activeCollection.gameOrder.isNotEmpty) {
        chips.add(GestureDetector(
          onTap: () => _resetCollectionOrder(activeCollection),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '重置顺序',
              style:
                  TextStyle(fontSize: 11, color: AppColors.secondaryText),
            ),
          ),
        ));
      }
    }

    // ② 会社（智能归纳分组）
    if (smartGroup != null) {
      chips.add(crumb(
        Icon(
          smartGroup.kind == SmartGroupKind.tag
              ? Icons.local_offer_outlined
              : Icons.business_outlined,
          size: 15,
          color: AppColors.placeholderText,
        ),
        smartGroup.displayName,
        () => _activeSmartGroupKey = '',
      ));
      chips.add(GestureDetector(
        onTap: () => _editSmartGroup(smartGroup),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '编辑分组',
            style: TextStyle(fontSize: 11, color: AppColors.secondaryText),
          ),
        ),
      ));
    }

    // ③ 标签多选
    if (hasTags) {
      chips.add(crumb(
        Icon(Icons.local_offer_outlined,
            size: 15, color: AppColors.placeholderText),
        _activeTagNames.join('、'),
        () => _activeTagKeys.clear(),
      ));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _backToLibraryRoot,
            child: Text(
              '游戏库',
              style:
                  TextStyle(fontSize: 14, color: AppColors.secondaryText),
            ),
          ),
        ),
        for (final chip in chips) ...[
          separator(),
          chip,
        ],
        const SizedBox(width: 8),
        Text(
          '${_filteredAndSortedGames.length} 部',
          style: TextStyle(fontSize: 12, color: AppColors.placeholderText),
        ),
      ],
    );
  }

  /// 顶栏搜索框：全局搜索入口（原管理面板搜索已迁移至此）
  Widget _buildTopSearchField() {
    return Container(
      width: 250,
      height: 30,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.search, size: 16, color: AppColors.placeholderText),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _topSearchController,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                hintText: '搜索游戏…',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.placeholderText),
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isCollapsed: true,
              ),
              cursorColor: AppColors.selectedAccent,
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _topSearchController,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox(width: 10);
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _topSearchController.clear(),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close,
                        size: 14, color: AppColors.placeholderText),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 收藏夹按钮（顶栏最右侧）：切换右侧收藏夹栏
  Widget _buildCollectionsButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggleCollectionSidebar,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _collectionSidebarOpen
                ? AppColors.selectedAccent.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.collections_bookmark_outlined,
            size: 20,
            color: _collectionSidebarOpen
                ? AppColors.selectedAccent
                : AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildGameGrid() {
    if (_games.isEmpty) return const SizedBox.shrink();

    final filteredGames = _filteredAndSortedGames;

    // 卡片 key 按游戏身份持有（Phase 4）：本处不再维护任何"按位置"的 key 列表。
    // key 由 _cardKeyFor(game) 惰性创建，生命周期跟随游戏而非位置。

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          key: _gridKey,
          controller: _scrollController,
          // Phase 4：卡片 key 按游戏身份持有，重排后需让框架定位其新下标
          findChildIndexCallback: _indexOfCardKey,
          cacheExtent: 2000, // 性能优化: 增大预渲染区域，减少快速滑动时的白屏和卡片创建开销
          // 顶部留出悬浮顶栏的空间（38 顶栏 + 12 间隙）；
          // 用 GridView 自身 padding（而非外层 Padding），
          // 滚动时内容才能一直滚到视口顶部、从顶栏底下经过。
          // 底部：编辑模式下操作栏常驻（已不再依赖勾选），预留其高度，
          // 否则最后一行卡片会被压住、点不到。
          padding: EdgeInsets.fromLTRB(8, 50, 8, _isEditMode ? 84 : 4),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: _cardMaxExtent,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.60,
            ),
            itemCount: filteredGames.length,
            itemBuilder: (context, index) {
              final game = filteredGames[index];
              final isOriginalSlot = _isDragging && _originalIndex == index;
              final isSwapTarget = _hoverIndex == index &&
                  _isDragging &&
                  _hoverIndex != _originalIndex &&
                  _dragMode == _DragMode.swap;
              final isInsertMode = _isDragging && _insertIndex != -1;

              // 计算该卡片的预览偏移（平滑动画）
              Offset targetOffset = Offset.zero;
              if (isInsertMode && _insertPreviewOffsets.containsKey(index)) {
                targetOffset = _insertPreviewOffsets[index]!;
              }

              Widget cardWidget;

              if (isOriginalSlot && !isInsertMode) {
                // BUG-08: 拖回原位时显示取消指示
                final isCancelHover = _hoverIndex == _originalIndex;
                cardWidget = Opacity(
                  opacity: isCancelHover ? 0.5 : 0.3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LibraryGhostCard(
                        game: game,
                        coverPath: _coverPathCache[game.directoryPath],
                      ),
                      if (isCancelHover)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: AppColors.dangerRed,
                                width: 2.5,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.dangerRed,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '松手取消',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primaryText,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              } else if (isOriginalSlot && isInsertMode) {
                // 插入模式：拖拽卡片在目标位置显示为半透明+蓝色边框
                cardWidget = Container(
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: AppColors.selectedAccent, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Opacity(
                    opacity: 0.5,
                    child: LibraryGhostCard(
                      game: game,
                      coverPath: _coverPathCache[game.directoryPath],
                    ),
                  ),
                );
              } else if (isSwapTarget) {
                // 交换模式：蓝色高亮边框
                // UX-16: 当 hover 在卡片边缘（pending insert）时，
                // 显示侧边插入指示线替代完整边框，明确两种模式区别
                final pendingBefore = _pendingInsertIndex != -1 &&
                    _pendingInsertMode == _DragMode.insertBefore;
                final pendingAfter = _pendingInsertIndex != -1 &&
                    _pendingInsertMode == _DragMode.insertAfter;
                cardWidget = Stack(
                  children: [
                    LibraryGhostCard(
                      game: game,
                      coverPath: _coverPathCache[game.directoryPath],
                    ),
                    if (!pendingBefore && !pendingAfter)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: AppColors.selectedAccent, width: 2.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    if (pendingBefore) _buildInsertIndicator(isBefore: true),
                    if (pendingAfter) _buildInsertIndicator(isBefore: false),
                  ],
                );
              } else if (isInsertMode) {
                // 插入预览模式：卡片不可交互，但视觉正常
                // UX-16: 在目标卡片边缘显示插入指示线
                final isInsertTarget = _hoverIndex == index;
                final showBefore =
                    isInsertTarget && _dragMode == _DragMode.insertBefore;
                final showAfter =
                    isInsertTarget && _dragMode == _DragMode.insertAfter;
                cardWidget = IgnorePointer(
                  child: Stack(
                    children: [
                      LibraryGhostCard(
                        game: game,
                        coverPath: _coverPathCache[game.directoryPath],
                      ),
                      if (showBefore) _buildInsertIndicator(isBefore: true),
                      if (showAfter) _buildInsertIndicator(isBefore: false),
                    ],
                  ),
                );
              } else {
                // 普通卡片
                final isSelected = _isEditMode &&
                    _selectedGamePaths.contains(game.directoryPath);
                cardWidget = Semantics(
                  label: '游戏: ${game.title}',
                  button: true,
                  child: _LibraryCardWidget(
                    // Phase 4: key 按游戏身份（GuKey 池 _cardKeyByGame），
                    // 不随位置漂移 → 卡片 State 始终跟随游戏
                    key: _cardKeyFor(game),
                    game: game,
                    index: index,
                    isDragging: _isDragging,
                    isSelected: isSelected,
                    isEditMode: _isEditMode,
                    isBlurred: game.isBlurred,
                    playStatus: game.playStatus,
                    coverPath: _coverPathCache[game.directoryPath], // UX-34
                    onDoubleTap:
                        _isEditMode ? null : () => _handleDoubleTap(game),
                    // 左键单击：编辑模式→选中；普通模式→直接弹出详情窗口
                    // （与右键菜单"详情"、触摸单击效果一致）
                    onTap: _isEditMode
                        ? () => _toggleCardSelection(game)
                        : () => _openGameDetail(game),
                    onSecondaryTapDown: (details) => _isEditMode
                        ? _showEditModeContextMenu(
                            context, game, details.globalPosition)
                        : _showContextMenu(
                            context, game, details.globalPosition),
                    // --- 触摸适配（仅触摸指针生效，鼠标交互不受影响）---
                    // 单指单击：编辑模式→选中；普通模式→直接弹出详情窗口
                    onTouchTap: _isEditMode
                        ? () => _toggleCardSelection(game)
                        : () => _openGameDetail(game),
                    // 单指双击：启动游戏（保留既有触摸操作方式）
                    onTouchDoubleTap:
                        _isEditMode ? null : () => _handleDoubleTap(game),
                    // 双指点击：弹出右键小菜单（替代触摸端难用的长按右键）
                    onTwoFingerTap: (position) => _isEditMode
                        ? _showEditModeContextMenu(context, game, position)
                        : _showContextMenu(context, game, position),
                    // 第二根手指落下时取消长按拖拽计时器
                    onCancelLongPress: _cancelLongPress,
                    // BUG-07/08: 拖拽期间禁用其他卡片的 longPress 触发
                    // 门控改用 resolveReorderTarget（唯一判定入口）：仅
                    // 「手动排序 + 无搜索/会社筛选 + 非收藏夹视图」允许起拖。
                    // 被拦下时给一次性提示，而不是让长按毫无反应。
                    onPointerDown: !_isDragging &&
                            (_canReorderByDrag || _reorderBlockedHint != null)
                        ? (event) {
                            _longPressTimer = Timer(_dragDelay, () {
                              if (!mounted) return;
                              if (_canReorderByDrag) {
                                _startDrag(
                                    index, event.localPosition, event.position);
                              } else {
                                _notifyReorderBlocked();
                              }
                            });
                          }
                        : null,
                    // 进行中的拖拽不受门控变化影响（否则拖到一半改筛选会卡住手势）
                    onPointerMove: (_canReorderByDrag || _isDragging)
                        ? (event) {
                            if (_longPressTimer != null && !_isDragging) {
                              final moveDist =
                                  event.delta.dx.abs() + event.delta.dy.abs();
                              if (moveDist > 5) _cancelLongPress();
                            }
                            // BUG-07: 仅在尚未被全局 Listener 处理时更新拖拽
                            if (_isDragging && !_isEndingDrag)
                              _updateDrag(event.position);
                          }
                        : null,
                    onPointerUp: (_canReorderByDrag || _isDragging)
                        ? () {
                            if (!_isDragging) {
                              _cancelLongPress();
                            } else if (!_isEndingDrag) {
                              // BUG-07: 防止与全局 Listener 双重调用
                              _endDrag();
                            }
                          }
                        : null,
                  ),
                );
              }

              // 应用平滑的预览偏移动画
              if (targetOffset != Offset.zero) {
                cardWidget = AnimatedBuilder(
                  animation: _insertPreviewCurve,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(
                        targetOffset.dx * _insertPreviewCurve.value,
                        targetOffset.dy * _insertPreviewCurve.value,
                      ),
                      child: child,
                    );
                  },
                  child: cardWidget,
                );
              }

            // 性能优化: 移除 TweenAnimationBuilder 入场动画
            // 原因: 快速滑动时大量卡片同时进入视口，每个都创建独立的
            // TweenAnimationBuilder 动画控制器，导致动画风暴 + 帧率骤降。
            // 动画过程中卡片半透明+缩放，视觉表现为"闪烁"和"不跟手"。
            // RepaintBoundary 仍保留，隔离每张卡片的重绘。
            return RepaintBoundary(
              child: cardWidget,
            );
          },
        );
      },
    );
  }

  Widget _buildManageButton() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 编辑模式下的面板按钮
        if (_isEditMode)
          Builder(builder: (btnContext) {
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  final box = btnContext.findRenderObject() as RenderBox?;
                  if (box != null) {
                    _showManagementPanelAt(box);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _managementPanel != null
                        ? AppColors.selectedAccent.withOpacity(0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.filter_list,
                    size: 20,
                    color: _managementPanel != null
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText,
                  ),
                ),
              ),
            );
          }),
        // 管理按钮（切换编辑模式）
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _toggleEditMode,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _isEditMode
                    ? AppColors.selectedAccent.withOpacity(0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isEditMode ? Icons.check_circle_outline : Icons.tune,
                    size: 20,
                    color: _isEditMode
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText,
                  ),
                  if (_isEditMode) ...[
                    SizedBox(width: 6),
                    Text(
                      '管理',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.selectedAccent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditModeBar() {
    // 0 勾选时批量钮禁用（仅「全选 / 取消」可用）：底栏在进入管理模式后即常驻，
    // 因此必须让"无事可做"的状态一眼可辨，而不是点了没反应。
    final hasSelection = _selectedGamePaths.isNotEmpty;
    final visibleCount = _filteredAndSortedGames.length;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              // 同时给出"已选"与"本页可见"两个数：批量操作作用域 = 已选，
              // 全选作用域 = 本页可见，两个数摊开显示即消除歧义
              '已选 ${_selectedGamePaths.length} / 本页 $visibleCount',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primaryText),
            ),
            SizedBox(width: 16),
            _editBarBtn(Icons.select_all, '全选', _selectAll,
                enabled: visibleCount > 0),
            _editBarBtn(Icons.deselect, '取消', _deselectAll,
                enabled: hasSelection),
            SizedBox(width: 8),
            _editBarBtn(Icons.blur_on, '模糊', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              if (selectedGames.isEmpty) return;
              // 批量语义修正（用户反馈"批量模糊逻辑有问题"）：
              // 原实现对每张卡**各自取反**——混合状态下会得出"一部分变清晰、
              // 一部分变模糊"的乱结果。改为集合语义：只要还有未模糊的 →
              // 全部模糊；否则 → 全部取消模糊。
              final targetBlurred = selectedGames.any((g) => !g.isBlurred);
              for (final g in selectedGames) {
                if (g.isBlurred == targetBlurred) continue;
                GameDataFormat.setBlurred(g.pathForCover, targetBlurred);
                g.isBlurred = targetBlurred;
              }
              setState(() {});
            }, enabled: hasSelection),
            _editBarBtn(Icons.delete_outline, '删除', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              _showBatchDeleteConfirm(selectedGames);
            }, enabled: hasSelection),
            _editBarBtn(Icons.desktop_windows_outlined, '快捷方式', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              _showBatchShortcutDialog(selectedGames);
            }, enabled: hasSelection),
          ],
        ),
      ),
    );
  }

  Widget _editBarBtn(IconData icon, String label, VoidCallback onTap,
      {bool enabled = true}) {
    // 禁用档：灰化 + 不响应点击 + 光标非手型（项目既有配色令牌，不引入新色）
    final Color iconColor = enabled
        ? AppColors.primaryText
        : AppColors.secondaryText.withOpacity(0.4);
    final Color labelColor = enabled
        ? AppColors.secondaryText
        : AppColors.secondaryText.withOpacity(0.4);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: iconColor),
              Text(label, style: TextStyle(fontSize: 10, color: labelColor)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: AppColors.border.withOpacity(0.4),
        ),
      ),
    );
  }

  /// UX-18: 磁盘扫描期间显示的加载遮罩
  Widget _buildScanningOverlay() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '正在扫描游戏库...',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// 组合筛选（≥2 个分类匣维度叠加）无匹配时的提示
  Widget _buildEmptyComboOverlay() {
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_alt_off_outlined,
                size: 40, color: AppColors.placeholderText),
            const SizedBox(height: 12),
            Text(
              '当前筛选组合没有匹配的作品',
              style: TextStyle(fontSize: 16, color: AppColors.secondaryText),
            ),
            const SizedBox(height: 6),
            Text(
              '点击顶栏面包屑中的任一条件可单独移除',
              style: TextStyle(
                  fontSize: 13, color: AppColors.placeholderText),
            ),
          ],
        ),
      ),
    );
  }

  /// 收藏夹视图内的空状态提示（收藏夹无游戏 / 搜索无匹配）
  Widget _buildEmptyCollectionOverlay() {
    final collection =
        CollectionService.instance.byId(_activeCollectionId);
    final isSearchEmpty = _searchQuery.isNotEmpty;
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border_rounded,
                size: 40, color: AppColors.placeholderText),
            const SizedBox(height: 12),
            Text(
              isSearchEmpty
                  ? '没有匹配的游戏'
                  : '「${collection?.name ?? ''}」还是空的',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.secondaryText,
              ),
            ),
            if (!isSearchEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '右键游戏或拖动卡片到右侧收藏夹，即可归类',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.placeholderText,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 标签库多选视图无成员时的提示
  Widget _buildEmptyTagSelectionOverlay() {
    final names = _activeTagNames;
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_offer_outlined,
                size: 40, color: AppColors.placeholderText),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? '没有匹配的游戏'
                  : '标签「${names.join('、')}」暂无成员',
              style: TextStyle(fontSize: 16, color: AppColors.secondaryText),
            ),
            if (_searchQuery.isEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '在游戏详情里给游戏加上所选标签，它会自动归入',
                style: TextStyle(
                    fontSize: 13, color: AppColors.placeholderText),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 会社视图无成员时的提示（成员全部被移出 / 数据被清空后会出现）
  Widget _buildEmptySmartGroupOverlay() {
    final group = _activeSmartGroup;
    final isTag = group?.kind == SmartGroupKind.tag;
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isTag
                  ? Icons.local_offer_outlined
                  : Icons.business_outlined,
              size: 40,
              color: AppColors.placeholderText,
            ),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? '没有匹配的游戏'
                  : '「${group?.displayName ?? ''}」暂无成员',
              style: TextStyle(fontSize: 16, color: AppColors.secondaryText),
            ),
            if (_searchQuery.isEmpty) ...[
              const SizedBox(height: 6),
              Text(
                isTag
                    ? '在游戏详情里给游戏加上该标签，它会自动归入本组'
                    : '在游戏详情里填写会社，它会自动归入本组',
                style: TextStyle(
                    fontSize: 13, color: AppColors.placeholderText),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyOverlay() {
    return Center(
      child: SizedBox(
        width: 320,
        height: 167,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Text(
                '库中没有游戏哦，快去探索游戏吧！',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  height: 28 / 20,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
            // v3.9：空态「出 发」按钮已删除（2026-09-13 用户指定）——
            // 原为暖阳时代手绘样式且固定定位，视觉突兀；引导路径由侧栏
            // 「探索」与添加页承担。
          ],
        ),
      ),
    );
  }
}

class _LibraryCardWidget extends StatefulWidget {
  final LibraryGame game;
  final int index;
  final bool isDragging;
  final bool isSelected;
  final bool isEditMode;
  final bool isBlurred;
  final PlayStatus playStatus;

  /// UX-34: 预缓存的封面路径，避免 build/initState 中的同步 I/O
  final String? coverPath;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;
  final ValueChanged<PointerEvent>? onPointerDown;
  final ValueChanged<PointerEvent>? onPointerMove;
  final VoidCallback? onPointerUp;

  // --- 触摸适配（TouchGestureHandler）---
  /// 单指单击（触摸专用）：普通模式弹出详情，编辑模式选中
  final VoidCallback? onTouchTap;

  /// 单指双击（触摸专用）：启动游戏
  final VoidCallback? onTouchDoubleTap;

  /// 双指点击（触摸专用）：弹出右键小菜单，参数为双指中心全局坐标
  final void Function(Offset globalPosition)? onTwoFingerTap;

  /// 第二根手指落下（用于取消父级长按拖拽计时器）
  final VoidCallback? onCancelLongPress;

  const _LibraryCardWidget({
    super.key,
    required this.game,
    required this.index,
    required this.isDragging,
    this.isSelected = false,
    this.isEditMode = false,
    this.isBlurred = false,
    this.playStatus = PlayStatus.notStarted,
    this.coverPath,
    this.onDoubleTap,
    this.onTap,
    required this.onSecondaryTapDown,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onTouchTap,
    this.onTouchDoubleTap,
    this.onTwoFingerTap,
    this.onCancelLongPress,
  });

  @override
  State<_LibraryCardWidget> createState() => _LibraryCardWidgetState();
}

class _LibraryCardWidgetState extends State<_LibraryCardWidget>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _hoverController;
  Widget? _cachedCover;

  /// 触摸手势处理器：单击→详情 / 双击→启动 / 双指→右键菜单。
  /// 鼠标事件不被消费，仍由下方 GestureDetector 原样处理。
  late final TouchGestureHandler _touchHandler;

  static BoxShadow _normalShadow = BoxShadow(
    color: AppColors.borderLight,
    offset: Offset(2, 3),
    blurRadius: 5,
  );

  static BoxShadow _hoverShadow = BoxShadow(
    color: AppColors.border.withOpacity(0.2),
    offset: Offset(2, 8),
    blurRadius: 16,
  );

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0.0,
    );
    _cachedCover = _resolveCover();
    _touchHandler = TouchGestureHandler(
      onTouchTap: () => widget.onTouchTap?.call(),
      onTouchDoubleTap: () => widget.onTouchDoubleTap?.call(),
      onTwoFingerTap:
          (globalPosition) => widget.onTwoFingerTap?.call(globalPosition),
      onSecondTouchDown: () => widget.onCancelLongPress?.call(),
    );
  }

  @override
  void didUpdateWidget(_LibraryCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.directoryPath != widget.game.directoryPath ||
        oldWidget.coverPath != widget.coverPath ||
        oldWidget.isBlurred != widget.isBlurred) {
      _cachedCover = _resolveCover();
    }
  }

  @override
  void dispose() {
    _touchHandler.dispose();
    _hoverController.dispose();
    super.dispose();
  }

  /// UX-34: 使用预缓存的 coverPath 构建封面，不再在 build/initState 中做同步 I/O
  /// 性能优化: 添加 cacheWidth/cacheHeight 避免全分辨率解码
  ///   - 封面图可能是 4K 分辨率（~30MB/张），但卡片只需 ~200×300 显示
  ///   - 不指定 cacheWidth/cacheHeight 时 Flutter 会解码全分辨率到内存
  ///   - 指定后 Flutter 只解码到目标尺寸，内存占用降 95%+，解码速度提升 10x+
  /// 性能优化: 简化淡入动画 300ms → 150ms，减少快速滑动时的动画叠加
  Widget _resolveCover() {
    final path = widget.coverPath;
    if (path != null && path.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // 底层占位符，图片加载期间可见
          _buildPlaceholderCover(),
          // NSFW 局部打码（v2）：v2.5 起揭示入口改为右下角角标按钮
          // （不再是整图手势），因此不再与卡片自身的单击/双击/长按冲突，
          // 网格卡片可以正常开启 enableReveal。
          NsfwImage.file(
            path,
            contentKind: NsfwContentKind.cover,
            enableReveal: true,
            fit: BoxFit.cover,
            // 与 child 的 cacheWidth/cacheHeight 一致，让两边 ImageProvider
            // 缓存键相同，同一张图只解码一次
            decodeWidth: 480, // 物理像素: 240px卡片 × 2x DPR = 480
            decodeHeight: 720, // 物理像素: 360px卡片 × 2x DPR = 720
            child: Image.file(
              File(path),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              cacheWidth: 480, // 物理像素: 240px卡片 × 2x DPR = 480
              cacheHeight: 720, // 物理像素: 360px卡片 × 2x DPR = 720
              // 性能优化: 简化淡入动画，减少快速滑动时的动画叠加
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  opacity: frame == null ? 0.0 : 1.0,
                  child: child,
                );
              },
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        ],
      );
    }
    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: AppColors.border.withOpacity(0.4),
        ),
      ),
    );
  }

  void _onHoverEnter() {
    if (widget.isDragging) return;
    setState(() => _hovered = true);
    _hoverController.forward();
  }

  void _onHoverExit() {
    if (_hovered) {
      setState(() => _hovered = false);
      _hoverController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final coverImage = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color:
              widget.isSelected ? AppColors.selectedAccent : AppColors.border,
          width: AppStyle.isModern
              ? (widget.isSelected ? AppStyle.wStrong : AppStyle.wHairline)
              : (widget.isSelected ? 3 : 2),
        ),
        borderRadius: BorderRadius.circular(AppStyle.isModern ? AppStyle.rSm : 4),
        boxShadow: AppStyle.isModern
            ? (_hovered ? AppStyle.e2 : AppStyle.e1)
            : [_hovered ? _hoverShadow : _normalShadow],
        color: AppColors.background,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: widget.isBlurred
                  ? ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: _cachedCover ?? _buildPlaceholderCover(),
                    )
                  : (_cachedCover ?? _buildPlaceholderCover()),
            ),
          ),
          // 游玩状态标识（左下角）
          Positioned(
            bottom: 6,
            left: 6,
            child: _buildPlayStatusBadge(widget.playStatus),
          ),
          // 收藏夹书签角标（右上角，替代原小黄星标记）
          if (widget.game.collectionIds.isNotEmpty)
            Positioned(
              top: 6,
              right: 6,
              child: CollectionBadges(
                collectionIds: widget.game.collectionIds,
              ),
            ),
          // 存储状态角标（左上角，仅封装/打包态显示）。
          // 方案 §7 Phase 4：**读内存字段（game.storageState），零磁盘探测** ——
          // 网格里可能同时渲染上百张卡片，任何磁盘 I/O 都会造成滚动卡顿。
          if (!widget.isEditMode &&
              GameStorageState.fromWire(widget.game.storageState).hasArchive)
            Positioned(
              top: 6,
              left: 6,
              child: _buildStorageStateBadge(),
            ),
          // 编辑模式选中勾选（左上角，覆盖在状态标识位置上）
          if (widget.isEditMode)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? AppColors.selectedAccent
                      : Colors.white.withOpacity(0.7),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.isSelected
                        ? AppColors.selectedAccent
                        : AppColors.border,
                    width: 2,
                  ),
                ),
                child: widget.isSelected
                    ? Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );

    final cardContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: coverImage,
        ),
        const SizedBox(height: 5),
        // 标题 + 开发商：固定高度区域（54），内部内容按实际行数自适应、顶部对齐。
        // 短标题时开发商紧跟标题（无空隙），富余空白落在区域底部（不可见）；
        // 长标题自动换行到第二行并按需缩小字号（最低 11px），完整显示。
        // 标题不设固定行盒（高度不受限），AutoSizeText 会缩放至两行内放得下为止
        SizedBox(
          height: 54,
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: AutoSizeText(
                  widget.game.title.isNotEmpty
                      ? widget.game.title
                      : '未命名游戏',
                  style: AppStyles.gameTitle.copyWith(
                    fontSize: 15,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  minFontSize: 11,
                  stepGranularity: 0.5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.game.developer.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 2, top: 2),
                  child: Text(
                    widget.game.developer,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.secondaryText.withOpacity(0.8),
                      fontStyle: FontStyle.italic,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    // 鼠标交互保持原样；触摸指针由 _touchHandler 处理，
    // 这里通过 lastDownWasTouch 门控避免鼠标/触摸重复触发同一回调
    return GestureDetector(
      onTap: widget.onTap == null
          ? null
          : () {
              if (_touchHandler.lastDownWasTouch) return;
              widget.onTap!();
            },
      onDoubleTap: widget.onDoubleTap == null
          ? null
          : () {
              if (_touchHandler.lastDownWasTouch) return;
              widget.onDoubleTap!();
            },
      onSecondaryTapDown: widget.onSecondaryTapDown,
      // 说明：右键回调不做触摸门控——Windows 触摸长按合成的右键事件
      // 无论以何种指针类型送达，都保持原有行为（老用户操作方式不变）
      child: MouseRegion(
        cursor: widget.isDragging
            ? SystemMouseCursors.grabbing
            : (widget.isEditMode
                ? SystemMouseCursors.click
                : SystemMouseCursors.grab),
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: AnimatedBuilder(
          animation: _hoverController,
          builder: (context, child) {
            final t = _hoverController.value;
            // 结构恒定的 Transform 链（t=0 时为恒等变换），不要在
            // 「有 Transform / 无 Transform」两套 widget 树之间切换：
            // 树结构变化会让整张卡片子树在 hover 进入/退出的首帧被
            // unmount 重建，其中的 NsfwImage 会丢失全部检测状态
            // （放行标志/重试计数都是 State 局部变量）——检测未落定
            // （排队中/失败重试/曾超时放行）的封面会在悬停放大的瞬间
            // 回到「未判定 → 模糊预览」分支，表现为"已清晰的封面
            // 一悬停就又模糊"（v2.1.15 用户实测）。
            // 恒等变换静止时无逐帧开销，仅绘制期一次矩阵保存/恢复。
            return Transform.translate(
              offset: Offset(0, -4 * t),
              child: Transform.scale(
                scale: 1.0 + 0.025 * t,
                alignment: Alignment.center,
                child: child,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(6),
            clipBehavior: Clip.none,
            child: Listener(
              // 触摸手势识别（单击/双击/双指）与既有拖拽逻辑共用此 Listener：
              // - handlePointerDown 返回 false（第二根手指落下）时不转发，
              //   避免误触长按拖拽计时器
              // - 鼠标事件全部照旧转发
              onPointerDown: (event) {
                if (_touchHandler.handlePointerDown(event)) {
                  widget.onPointerDown?.call(event);
                }
              },
              onPointerMove: (event) {
                _touchHandler.handlePointerMove(event);
                widget.onPointerMove?.call(event);
              },
              onPointerUp: (event) {
                _touchHandler.handlePointerUp(event);
                widget.onPointerUp?.call();
              },
              onPointerCancel: _touchHandler.handlePointerCancel,
              child: cardContent,
            ),
          ),
        ),
      ),
    );
  }

  /// 存储状态小胶囊（封装/打包）。样式与游玩状态标识同族的半透明深底白字，
  /// 尺寸克制 —— 卡片是网格里密度最高的元素，角标不能抢封面的视觉。
  Widget _buildStorageStateBadge() {
    final label = GameStorageState.fromWire(widget.game.storageState).label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 10, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              height: 1.0,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.92),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayStatusBadge(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
                color: AppColors.secondaryText.withOpacity(0.6), width: 1.5),
          ),
        );
      case PlayStatus.inProgress:
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 5)
            ],
          ),
        );
      case PlayStatus.dropped:
        return Container(
          padding: EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.9),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.exit_to_app, size: 13, color: Colors.white),
        );
      case PlayStatus.completed:
        return Container(
          padding: EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.starGold,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.emoji_events, size: 15, color: Colors.white),
        );
    }
  }
}

// --- 管理面板 ---

/// 会社筛选面板的一条条目（会社归一化 v4）。
///
/// [value] 是筛选键：词典命中为 `devId:<id>`（跨写法归并），未命中为原文；
/// [label] 是展示名（词典中文名/标准主名，或原文）。
class DeveloperFilterEntry {
  final String value;
  final String label;
  final int? companyId;

  const DeveloperFilterEntry({
    required this.value,
    required this.label,
    this.companyId,
  });
}

/// 标签库内联编辑的有效维度（asset 维度 + 用户自定义维度统一视图）。
class _EffectiveDim {
  final String id;
  final String title;
  final Color? color;
  final bool isUser;

  const _EffectiveDim(this.id, this.title, this.color, this.isUser);
}

/// 标签重命名对话框（输入新名 + 写穿警示）。
///
/// 返回新名（无变更或取消返回 null）。重命名是**写穿操作**
/// （`renameTagEverywhere` 直接改全部命中游戏的 game.json），故这里
/// 内置影响面警示，开发者要求的「二次确认」在此落地。
class _TagRenameDialog extends StatefulWidget {
  const _TagRenameDialog({
    required this.oldName,
    required this.affected,
  });

  final String oldName;
  final int affected;

  static Future<String?> show(
    BuildContext context, {
    required String oldName,
    required int affected,
  }) {
    return showAppDialog<String>(
      context: context,
      builder: (_) => _TagRenameDialog(oldName: oldName, affected: affected),
    );
  }

  @override
  State<_TagRenameDialog> createState() => _TagRenameDialogState();
}

class _TagRenameDialogState extends State<_TagRenameDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.oldName);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _c.text.trim();
    if (t.isEmpty || t == widget.oldName) {
      Navigator.of(context).pop(null);
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('重命名标签「${widget.oldName}」',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText)),
              const SizedBox(height: 6),
              Text(
                '将写穿 ${widget.affected} 部游戏的数据：所有游戏中的'
                '「${widget.oldName}」都会被替换为新名称，不可撤销。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.secondaryText, height: 1.5),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _c,
                autofocus: true,
                style:
                    TextStyle(fontSize: 14, color: AppColors.primaryText),
                cursorColor: AppColors.selectedAccent,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: '新名称',
                  hintStyle: TextStyle(
                      fontSize: 13, color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _dialogTextButton('取消', () => Navigator.of(context).pop(null)),
                  const SizedBox(width: 10),
                  _dialogAccentButton('确认重命名', _submit),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 写穿操作确认框（删除标签等不可逆操作）。
class _ConfirmWriteThroughDialog extends StatelessWidget {
  const _ConfirmWriteThroughDialog({
    required this.title,
    required this.affected,
    required this.action,
    required this.body,
  });

  final String title;
  final int affected;
  final String action;
  final String body;

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required int affected,
    required String action,
    required String body,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (_) => _ConfirmWriteThroughDialog(
        title: title,
        affected: affected,
        action: action,
        body: body,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText)),
              const SizedBox(height: 6),
              Text(body,
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.secondaryText,
                      height: 1.5)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _dialogTextButton('取消', () => Navigator.of(context).pop(false)),
                  const SizedBox(width: 10),
                  _dialogAccentButton(action, () => Navigator.of(context).pop(true)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _dialogTextButton(String label, VoidCallback onTap) {
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 13, color: AppColors.secondaryText)),
      ),
    ),
  );
}

Widget _dialogAccentButton(String label, VoidCallback onTap) {
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.selectedAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.selectedAccent)),
      ),
    ),
  );
}

class _ManagementPanelWidget extends StatefulWidget {
  final Offset position;
  final String activeSort;
  final String activeDeveloperFilter;
  final double cardMaxExtent;
  final List<DeveloperFilterEntry> developers;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<String> onDeveloperFilterChanged;
  final ValueChanged<double> onLayoutChanged;
  final VoidCallback onClose;

  const _ManagementPanelWidget({
    required this.position,
    required this.activeSort,
    required this.activeDeveloperFilter,
    required this.cardMaxExtent,
    required this.developers,
    required this.onSortChanged,
    required this.onDeveloperFilterChanged,
    required this.onLayoutChanged,
    required this.onClose,
  });

  @override
  State<_ManagementPanelWidget> createState() => _ManagementPanelWidgetState();
}

class _ManagementPanelWidgetState extends State<_ManagementPanelWidget> {
  late TextEditingController _devSearchController;
  String _devSearchQuery = '';
  bool _devListExpanded = false;
  // ★ 会社归一化（Phase 3）：待审漏斗（未解析会社）审阅区状态
  bool _pendingDevsExpanded = false;
  String? _copiedPendingRaw; // 复制反馈（显示「已复制」，1.2s 后还原）

  @override
  void initState() {
    super.initState();
    _devSearchController = TextEditingController();
  }

  @override
  void dispose() {
    _devSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 点击外部关闭
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            behavior: HitTestBehavior.translucent,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 面板主体
        Positioned(
          left: widget.position.dx,
          top: widget.position.dy,
          child: Container(
            width: 280,
            constraints: BoxConstraints(maxHeight: 480),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 16,
                    offset: Offset(0, 4)),
              ],
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 排序
                  Text('排序',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText)),
                  SizedBox(height: 6),
                  _sortOption('recently_added', '最近添加', Icons.schedule),
                  _sortOption(
                      'recently_played', '最近游玩', Icons.play_circle_outline),
                  _sortOption('play_time', '游玩时长', Icons.timer_outlined),
                  _sortOption('play_status', '游玩状态', Icons.sports_esports),
                  SizedBox(height: 14),

                  // 会社筛选
                  _buildDevFilterSection(),
                  SizedBox(height: 14),

                  // 卡片布局
                  Text('卡片布局',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      _layoutBtn('紧凑', 160),
                      SizedBox(width: 8),
                      _layoutBtn('舒适', 240),
                      SizedBox(width: 8),
                      _layoutBtn('宽松', 340),
                    ],
                  ),
                  SizedBox(height: 8),
                  Slider(
                    value: widget.cardMaxExtent.clamp(140, 400),
                    min: 140,
                    max: 400,
                    divisions: 26,
                    activeColor: AppColors.selectedAccent,
                    inactiveColor: AppColors.borderLight,
                    onChanged: widget.onLayoutChanged,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDevFilterSection() {
    final allDevs = widget.developers;
    // ★ 会社归一化（v4）：面板内搜索 = 「展示名 + 该会社全部别名」的
    //   归一化包含匹配——搜「雪碧」也能找到 label 是 sprite 的条目
    bool matchesQuery(DeveloperFilterEntry e) {
      if (_devSearchQuery.isEmpty) return true;
      final nq = CompanyAliasStore.normalize(_devSearchQuery);
      if (nq.isEmpty) return true;
      if (CompanyAliasStore.normalize(e.label).contains(nq)) return true;
      final id = e.companyId;
      if (id == null) return false;
      final rec = CompanyAliasStore.instanceOrNull?.byId(id);
      if (rec == null) return false;
      return [
        rec.standardName,
        if (rec.jpName != null) rec.jpName!,
        if (rec.cnName != null) rec.cnName!,
        ...rec.aliases,
      ].any((n) => CompanyAliasStore.normalize(n).contains(nq));
    }

    final filteredDevs = allDevs.where(matchesQuery).toList();
    final hasMoreDevs = allDevs.length > 5;
    final showDevs = _devListExpanded || _devSearchQuery.isNotEmpty
        ? filteredDevs
        : filteredDevs.take(5).toList();
    final canExpand =
        hasMoreDevs && !_devListExpanded && _devSearchQuery.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（可点击展开/收起）
        GestureDetector(
          onTap: hasMoreDevs
              ? () => setState(() => _devListExpanded = !_devListExpanded)
              : null,
          child: MouseRegion(
            cursor: hasMoreDevs
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text('会社筛选',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.secondaryText)),
                  Spacer(),
                  if (hasMoreDevs)
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 200),
                      turns: _devListExpanded ? 0.5 : 0,
                      child: Icon(Icons.expand_more,
                          size: 16, color: AppColors.secondaryText),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: 6),
        // 会社搜索框（展开后或会社多时显示）
        if (hasMoreDevs)
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: TextField(
              controller: _devSearchController,
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: '搜索会社...',
                hintStyle:
                    TextStyle(color: AppColors.placeholderText, fontSize: 12),
                prefixIcon: Icon(Icons.search,
                    size: 14, color: AppColors.secondaryText),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      BorderSide(color: AppColors.selectedAccent, width: 1.5),
                ),
                filled: true,
                fillColor: AppColors.background,
              ),
              onChanged: (v) => setState(() => _devSearchQuery = v),
            ),
          ),
        // 会社列表（收起时只显示前5个）
        if (_devListExpanded ||
            allDevs.length <= 5 ||
            _devSearchQuery.isNotEmpty) ...[
          _devFilterOption('', '全部'),
          if (allDevs.any((d) => d.label.isEmpty))
            _devFilterOption('__none__', '未分类'),
          ...showDevs.map((d) => _devFilterOption(d.value, d.label)),
        ] else ...[
          _devFilterOption('', '全部'),
          if (allDevs.any((d) => d.label.isEmpty))
            _devFilterOption('__none__', '未分类'),
          ...allDevs.take(5).map((d) => _devFilterOption(d.value, d.label)),
        ],
        // 展开/收起按钮
        if (canExpand)
          GestureDetector(
            onTap: () => setState(() => _devListExpanded = true),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '展开全部 (${allDevs.length})',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.selectedAccent,
                  ),
                ),
              ),
            ),
          ),
        // ★ 会社归一化（Phase 3）：未解析会社审阅区（pending 漏斗）
        _buildPendingDevSection(),
      ],
    );
  }

  /// 未解析会社审阅区：展示 pending 漏斗里词典未命中的会社原文
  /// （计数降序），供人工查证后补进词典（复制名称）或判定无效（忽略）。
  ///
  /// 只在会社筛选展开态显示（与会社列表同区域，避免面板常驻膨胀）。
  Widget _buildPendingDevSection() {
    if (!_devListExpanded) return const SizedBox.shrink();
    final items = CompanyAliasPendingStore.instance.snapshot();
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 12, thickness: 0.5, color: AppColors.border),
        // 标题行（可点击展开/收起）
        GestureDetector(
          onTap: () =>
              setState(() => _pendingDevsExpanded = !_pendingDevsExpanded),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text('未解析会社 (${items.length})',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.secondaryText)),
                  Spacer(),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    turns: _pendingDevsExpanded ? 0.5 : 0,
                    child: Icon(Icons.expand_more,
                        size: 16, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_pendingDevsExpanded)
          ...items.map((item) => _pendingDevTile(item)),
      ],
    );
  }

  Widget _pendingDevTile(Map<String, dynamic> item) {
    final raw = item['raw']?.toString() ?? '';
    if (raw.isEmpty) return const SizedBox.shrink();
    final count = (item['count'] as num?)?.toInt() ?? 0;
    final copied = _copiedPendingRaw == raw;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$raw ×$count',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.primaryText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 复制名称（供人工到 VNDB 查证后补词典）
          GestureDetector(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: raw));
              if (!mounted) return;
              setState(() => _copiedPendingRaw = raw);
              Future.delayed(const Duration(milliseconds: 1200), () {
                if (!mounted) return;
                if (_copiedPendingRaw == raw) {
                  setState(() => _copiedPendingRaw = null);
                }
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  copied ? '已复制' : '复制',
                  style: TextStyle(
                    fontSize: 11,
                    color: copied
                        ? AppColors.successGreen
                        : AppColors.selectedAccent,
                  ),
                ),
              ),
            ),
          ),
          // 忽略（判定无效，从漏斗移除；命中时漏斗也会自动清理）
          GestureDetector(
            onTap: () async {
              await CompanyAliasPendingStore.instance.remove(raw);
              if (!mounted) return;
              setState(() {});
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('忽略',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.secondaryText,
                    )),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sortOption(String key, String label, IconData icon) {
    final isActive = widget.activeSort == key;
    return PanelHoverBuilder(builder: (isHovered) {
      final showHighlight = isActive || isHovered;
      return GestureDetector(
        onTap: () => widget.onSortChanged(key),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.selectedAccent.withOpacity(0.12)
                  : isHovered
                      ? AppColors.selectedAccent.withOpacity(0.06)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.primaryText
                            : AppColors.secondaryText),
                SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                      fontSize: 13,
                      color: isActive
                          ? AppColors.selectedAccent
                          : AppColors.primaryText,
                      fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                    )),
                Spacer(),
                if (isActive)
                  Icon(Icons.check, size: 16, color: AppColors.selectedAccent),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _devFilterOption(String key, String label) {
    final isActive = widget.activeDeveloperFilter == key;
    return PanelHoverBuilder(builder: (isHovered) {
      return GestureDetector(
        onTap: () => widget.onDeveloperFilterChanged(key),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(vertical: 5, horizontal: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.selectedAccent.withOpacity(0.12)
                  : isHovered
                      ? AppColors.selectedAccent.withOpacity(0.06)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: isActive
                      ? AppColors.selectedAccent
                      : isHovered
                          ? AppColors.primaryText
                          : AppColors.secondaryText,
                ),
                SizedBox(width: 6),
                Expanded(
                    child: Text(label,
                        style: TextStyle(
                          fontSize: 12,
                          color: isActive
                              ? AppColors.selectedAccent
                              : AppColors.primaryText,
                          fontWeight:
                              isActive ? FontWeight.w500 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _layoutBtn(String label, double value) {
    final isActive = (widget.cardMaxExtent - value).abs() < 20;
    return Expanded(
      child: PanelHoverBuilder(builder: (isHovered) {
        return GestureDetector(
          onTap: () => widget.onLayoutChanged(value),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              padding: EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.selectedAccent.withOpacity(0.15)
                    : isHovered
                        ? AppColors.selectedAccent.withOpacity(0.06)
                        : Colors.transparent,
                border: Border.all(
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.selectedAccent.withOpacity(0.4)
                            : AppColors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.primaryText
                            : AppColors.secondaryText,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                  )),
            ),
          ),
        );
      }),
    );
  }
}
