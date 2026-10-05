import 'dart:async';
import 'package:flutter/material.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_styles.dart';
import '../models/game_model.dart';
import '../models/discover_filter_state.dart';
import '../repositories/game_repository.dart';
import '../core/pb_config.dart';
import '../core/portable_image_cache_manager.dart';
import '../services/global_install_center.dart';
import '../services/local_game_registry.dart';
import '../services/discover_metadata_service.dart';
import '../services/company_alias_store.dart';
import '../services/tag_vocabulary_store.dart';
import '../services/file_size_service.dart';
import '../services/game_resource_service.dart';
import '../widgets/nsfw/nsfw_image.dart';
import '../services/network_status_service.dart';
import '../widgets/discover_disclaimer_dialog.dart';
import '../widgets/game_detail/upload_publish_dialog.dart';
import '../widgets/tags_popup_menu.dart';
import 'game_detail_page.dart' show GameDetailPage;

class GameCardData {
  final String id;
  final String title;
  final String coverPath;
  final List<String> tags;
  final String description;
  final String developer;

  /// 是否存在官方来源（`games.has_official`）—— 卡片「可安装」角标判据（方案 §6.1）
  final bool hasOfficial;

  const GameCardData({
    required this.id,
    required this.title,
    required this.coverPath,
    this.tags = const [],
    this.description = '',
    this.developer = '',
    this.hasOfficial = false,
  });

  factory GameCardData.fromModel(GameModel model) => GameCardData(
        id: model.id,
        title: model.title,
        coverPath: model.coverUrl,
        tags: model.tags,
        description: model.description,
        developer: model.developer,
        hasOfficial: model.hasOfficial,
      );
}

class DiscoverPage extends StatefulWidget {
  final ValueChanged<GameCardData>? onGameTap;

  const DiscoverPage({super.key, this.onGameTap});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  static List<GameModel>? _cachedAllGames;
  static String? _cachedSearchText;
  static Set<String>? _cachedSelectedTags;
  // 顶栏 v2：会社分组选中集合的跨页面缓存
  static Set<String>? _cachedSelectedDevelopers;
  // 顶栏 v3：资源来源筛选的跨页面缓存（空集合 = 不过滤）
  static Set<DiscoverResourceSource>? _cachedResourceSources;
  // 阶段4.4：筛选状态跨页面持久化（静态变量，切回探索页时恢复）
  static DiscoverFilterState? _cachedFilterState;
  // 缓存快照是否为不完整数据（后台全量加载未完成时退出页面），
  // 恢复时据此触发后台补全，避免残缺数据伴随整个会话
  static bool? _cachedHasMoreData;

  List<GameModel> _allGames = [];
  List<GameModel> _displayGames = [];
  Set<String> _selectedTags = {};
  // 顶栏 v2：会社分组选中集合（OR 语义：developer 命中任一选中项即保留）
  Set<String> _selectedDevelopers = {};
  // 顶栏 v3：资源来源筛选（OR 语义：勾选项命中任一即保留；空 = 全部来源）
  Set<DiscoverResourceSource> _selectedResourceSources = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  // 后台全量加载进行中标志（防止与滚动加载/重复触发互相踩踏）
  bool _isLoadingAll = false;
  bool _isSearching = false;
  bool _hasLoadedOnce = false;
  bool _hasMoreData = true;
  String? _errorMessage;
  DateTime? _cacheTime;

  /// ★ 离线模式：记录上次网络状态，用于检测转换。
  bool _wasOnline = true;

  /// 阶段4.1：高级筛选状态（排序/评分/年份/大小/安装状态）
  DiscoverFilterState _filterState = DiscoverFilterState.defaultState;

  /// 阶段4.4：文件大小缓存（gameId → 字节数），仅当大小筛选/排序激活时加载
  /// 来源：FileSizePrefetchService 内存 + 磁盘缓存
  final Map<String, int> _cachedSizes = {};
  bool _isLoadingSizes = false;

  /// 卡片「用户分享」角标数据（gameId → 已发布用户分享数），方案 §6.1
  ///
  /// ⚠️ **不读 `games.community_count`**：该冗余字段全库恒为 0（未维护，见方案 §9 风险 #8），
  /// 改为按当前列表分批现算（`GameResourceService.communityCountBatch`）。
  /// 只在有分享时才写入 map，避免为 300 个 gameId 铺满零值。
  final Map<String, int> _communityCounts = {};
  /// 已查询过的 gameId（终身缓存，避免滚动/筛选反复请求）
  final Set<String> _queriedCommunityIds = {};
  Timer? _communityCountTimer;
  bool _isLoadingCommunityCounts = false;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // 全量加载失败/不完整时的自愈重试（在线时 15s 延迟、最多 3 次）
  Timer? _selfHealTimer;
  int _selfHealRetries = 0;
  static const int _maxAllGamesRetries = 3;
  static const Duration _allGamesRetryDelay = Duration(seconds: 15);
  // 「全部标签」按钮的 GlobalKey，用于定位弹出菜单的锚点位置
  final GlobalKey _allTagsButtonKey = GlobalKey();
  // 顶栏 v2：会社组「全部」按钮锚点
  final GlobalKey _allDevButtonKey = GlobalKey();
  // 顶栏 v3：内联筛选控件锚点（来源/评分/发售日期/排序弹出面板定位）
  final GlobalKey _resourceSourceButtonKey = GlobalKey();
  final GlobalKey _ratingButtonKey = GlobalKey();
  final GlobalKey _yearButtonKey = GlobalKey();
  final GlobalKey _sortButtonKey = GlobalKey();
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 300);
  static const Duration _cacheTTL = Duration(minutes: 30);
  static const int _initialPageSize = 20;
  static const int _fetchAllPerPage = 100;

  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 阶段4.4：恢复跨页面持久化的筛选状态
    if (_cachedFilterState != null) {
      _filterState = _cachedFilterState!;
    }
    // 阶段4.4：监听元数据/安装状态变化，当相关筛选激活时去抖刷新列表
    DiscoverMetadataService.instance.addListener(_onPageMetadataChanged);
    LocalGameRegistry.instance.addListener(_onPageRegistryChanged);
    // 顶栏 v2：会社词典为异步加载——若首帧时未就绪，加载完成后刷新会社分组
    CompanyAliasStore.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    // 顶栏 v3：标签受控词表为异步加载——就绪后刷新（标签面板按维度分组）
    TagVocabularyStore.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    // ★ 离线模式：监听网络状态，恢复时自动刷新，断网时切离线视图
    _wasOnline = NetworkStatusService.instance.isOnline;
    NetworkStatusService.instance.addListener(_onNetworkStatusChanged);
    if (_cachedAllGames != null && _cachedAllGames!.isNotEmpty) {
      _allGames = _cachedAllGames!;
      _hasLoadedOnce = true;
      _cacheTime = DateTime.now();
      // 恢复缓存快照的完整性标记；若上次会话在全量加载完成前退出，
      // 此处 _hasMoreData 为 true，postFrame 中触发后台补全自愈
      _hasMoreData = _cachedHasMoreData ?? false;
      if (_cachedSearchText != null && _cachedSearchText!.isNotEmpty) {
        _searchController.text = _cachedSearchText!;
      }
      if (_cachedSelectedTags != null && _cachedSelectedTags!.isNotEmpty) {
        _selectedTags = Set.from(_cachedSelectedTags!);
      }
      if (_cachedSelectedDevelopers != null &&
          _cachedSelectedDevelopers!.isNotEmpty) {
        _selectedDevelopers = Set.from(_cachedSelectedDevelopers!);
      }
      if (_cachedResourceSources != null &&
          _cachedResourceSources!.isNotEmpty) {
        _selectedResourceSources = Set.from(_cachedResourceSources!);
      }
      _searchController.addListener(_onSearchChanged);
      LocalGameRegistry.instance.refreshStaleEntries();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performFilter();
        // 自愈：缓存数据不完整时，后台补全（搜索/标签依赖完整数据集）
        if (mounted && _hasMoreData) _loadAllGamesInBackground();
        _showDisclaimerIfNeeded();
      });
      return;
    }
    _searchController.addListener(_onSearchChanged);
    LocalGameRegistry.instance.refreshStaleEntries();
    _loadInitialGames();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _showDisclaimerIfNeeded());
  }

  @override
  void dispose() {
    _cachedAllGames = _allGames;
    _cachedSearchText = _searchController.text;
    _cachedSelectedTags = Set.from(_selectedTags);
    _cachedSelectedDevelopers = Set.from(_selectedDevelopers);
    _cachedResourceSources = Set.from(_selectedResourceSources);
    _cachedFilterState = _filterState;
    _cachedHasMoreData = _hasMoreData;
    _debounceTimer?.cancel();
    _metaRefreshTimer?.cancel();
    _selfHealTimer?.cancel();
    _communityCountTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    _searchFocus.dispose();
    DiscoverMetadataService.instance.removeListener(_onPageMetadataChanged);
    LocalGameRegistry.instance.removeListener(_onPageRegistryChanged);
    NetworkStatusService.instance.removeListener(_onNetworkStatusChanged);
    super.dispose();
  }

  /// ★ 网络状态变化处理：离线→在线触发刷新；在线→离线重建为离线视图。
  void _onNetworkStatusChanged() {
    if (!mounted) return;
    final online = NetworkStatusService.instance.isOnline;
    if (online == _wasOnline) return;
    _wasOnline = online;
    if (online) {
      // 恢复在线：已有数据时直接后台全量加载（原子替换完整数据，
      // 不闪回 20 条首屏）；无数据时维持原首屏加载逻辑
      // 用户分享数缓存同样作废（离线期间服务端可能新增了分享）
      _queriedCommunityIds.clear();
      _communityCounts.clear();
      if (_allGames.isNotEmpty) {
        _loadAllGamesInBackground();
      } else {
        _loadAllGames(forceRefresh: true);
      }
    } else {
      // 转为离线：重建 UI 显示离线视图
      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });
    }
  }

  /// 批量现算「用户分享」数量（卡片角标用，方案 §6.1）
  ///
  /// 去抖 + 终身缓存：列表每次变化都会触发，但只对**尚未查询过**的 gameId 发请求。
  /// 离线时不请求（角标缺失优于报错）。
  void _scheduleCommunityCountRefresh() {
    if (!NetworkStatusService.instance.isOnline) return;
    _communityCountTimer?.cancel();
    _communityCountTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _refreshCommunityCounts();
    });
  }

  /// 顶栏 v3：「个人分享」来源筛选激活时，分享计数需覆盖全量游戏
  /// （默认只查当前展示列表——未查询的游戏会被误判为无分享）。
  bool get _needsFullCommunityCounts =>
      _selectedResourceSources.contains(DiscoverResourceSource.community);

  Future<void> _refreshCommunityCounts() async {
    if (_isLoadingCommunityCounts) return;
    // 顶栏 v3：来源筛选激活时查全量（_allGames），否则只查当前展示列表
    final pool = _needsFullCommunityCounts ? _allGames : _displayGames;
    final ids = pool
        .map((g) => g.id)
        .where((id) => id.isNotEmpty && !_queriedCommunityIds.contains(id))
        .toList();
    if (ids.isEmpty) return;

    _isLoadingCommunityCounts = true;
    try {
      // 服务层内部分批（每批 30 id）且逐批 try/catch，失败返回空 map 而非抛异常
      final counts = await GameResourceService.communityCountBatch(ids);
      if (!mounted) return;
      _queriedCommunityIds.addAll(ids);
      if (counts.isEmpty) return; // 全 0：无角标可画，连 setState 都省掉
      setState(() {
        counts.forEach((gameId, n) {
          if (n > 0) _communityCounts[gameId] = n;
        });
      });
      // 顶栏 v3：分享数据落库后重跑筛选，「个人分享」结果渐进收敛
      if (_needsFullCommunityCounts) _performFilter();
    } finally {
      _isLoadingCommunityCounts = false;
    }
  }

  /// 阶段4.4：元数据抓取完成时，若评分/年份/热度筛选激活则去抖刷新列表
  /// 避免每次 notifyListeners 都全量 filter（250 条游戏会触发 250 次通知）
  Timer? _metaRefreshTimer;
  void _onPageMetadataChanged() {
    if (!mounted) return;
    if (!_filterState.needsMetadata) return;
    _metaRefreshTimer?.cancel();
    _metaRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _performFilter();
    });
  }

  /// 阶段4.4：安装状态变化时，若安装筛选激活则刷新列表
  void _onPageRegistryChanged() {
    if (!mounted) return;
    // 忽略游玩时长周期更新
    if (LocalGameRegistry.instance.lastChangeReason ==
        RegistryChangeReason.playTimeUpdate) {
      return;
    }
    if (_filterState.installStatus == DiscoverInstallStatus.any) return;
    _metaRefreshTimer?.cancel();
    _metaRefreshTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _performFilter();
    });
  }

  void _onScroll() {
    // 修复重复加载：增加 _isLoadingMore 前置防护 + 缩小触发阈值
    // 原 200px 阈值在快速滚动时会多次触发 _loadMoreGames
    if (_isLoadingMore || !_hasMoreData || _isLoading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 50) {
      _loadMoreGames();
    }
  }

  void _showDisclaimerIfNeeded() {
    DiscoverDisclaimerDialog.showIfNeeded(
      context: context,
      onAgreed: () {},
    );
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      if (mounted) _performFilter();
    });
  }

  bool get _isCacheValid =>
      _cacheTime != null && DateTime.now().difference(_cacheTime!) < _cacheTTL;

  /// 加载全部游戏数据（首屏快速展示 + 后台补全）
  Future<void> _loadInitialGames({bool forceRefresh = false}) async {
    // ★ 离线闸门：离线时不尝试网络加载，直接显示离线视图（_buildContent 处理）
    if (!NetworkStatusService.instance.isOnline) {
      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });
      return;
    }
    if (_isLoading) return;
    if (!forceRefresh && _isCacheValid && _allGames.isNotEmpty) {
      _performFilter();
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 第一步：快速加载第一页，立即展示
      final firstBatch =
          await GameRepository.getGameList(page: 1, perPage: _initialPageSize);

      if (!mounted) return;

      setState(() {
        _allGames = firstBatch;
        _hasMoreData = firstBatch.length >= _initialPageSize;
        _cacheTime = DateTime.now();
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorMessage = null;
      });

      // v2.1.17：云端已沉淀的评分/发售日直接入缓存，免去重复元数据抓取
      DiscoverMetadataService.instance
          .registerCloudMetadataAll(firstBatch);

      _performFilter();

      // 第二步：后台加载全部数据（确保完整性）
      if (_hasMoreData) {
        _loadAllGamesInBackground();
      }
    } catch (e) {
      if (!mounted) return;

      final errorMsg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _isLoading = false;
        if (!_hasLoadedOnce) {
          _errorMessage = errorMsg;
        }
      });
    }
  }

  /// 后台加载全部数据（搜索/标签筛选的完整数据集）
  ///
  /// 翻页由服务端返回的 totalPages 驱动（分页并发 + id 去重），
  /// 免疫 perPage 被服务端钳制导致的提前截断。
  /// 完成后标签栏立即补全、搜索可命中全部游戏。
  ///
  /// 失败/不完整时在线自愈：15s 延迟重试，最多 3 次（成功清零）。
  Future<void> _loadAllGamesInBackground() async {
    if (_isLoadingAll) return; // 防重入（自愈/网络恢复/首屏可能同时触发）
    _isLoadingAll = true;

    try {
      final result = await GameRepository.getAllGames(perPage: _fetchAllPerPage)
          .timeout(const Duration(seconds: 60));

      if (!mounted) return;

      // 仅在获取到数据时替换（避免加载失败时清空已有数据）
      if (result.games.isNotEmpty) {
        setState(() {
          _allGames = result.games;
          // 个别页抓取失败时保留滚动加载兜底，下次进入页面也会自愈补全
          _hasMoreData = !result.isComplete;
        });
        // v2.1.17：全量数据的云端元数据登记（覆盖首屏未加载到的游戏）
        DiscoverMetadataService.instance
            .registerCloudMetadataAll(result.games);
        _performFilter();
        debugPrint('[DISCOVER] ✅ 后台全量加载完成: '
            '${result.games.length}/${result.totalItems}条, '
            '标签${_allAvailableTags.length}个');
        _selfHealRetries = 0; // 成功清零
        if (!result.isComplete) _scheduleAllGamesSelfHeal();
      } else {
        // 空结果（网络抖动下的失败形态）：同样走自愈重试
        _scheduleAllGamesSelfHeal();
      }
    } catch (e) {
      debugPrint('[DISCOVER] 后台全量加载失败: $e');
      // 失败时保留首屏数据，滚动加载兜底仍可用；在线时安排自愈重试
      _scheduleAllGamesSelfHeal();
    } finally {
      _isLoadingAll = false;
    }
  }

  /// 全量加载失败/不完整时的在线自愈重试（15s 延迟、最多 3 次）
  void _scheduleAllGamesSelfHeal() {
    if (!mounted) return;
    // 离线时不自愈，网络恢复时由 _onNetworkStatusChanged 直接触发
    if (!NetworkStatusService.instance.isOnline) return;
    if (_selfHealRetries >= _maxAllGamesRetries) return;
    _selfHealTimer?.cancel();
    _selfHealTimer = Timer(_allGamesRetryDelay, () {
      _selfHealRetries++;
      if (mounted) _loadAllGamesInBackground();
    });
  }

  /// 滚动到底部时加载更多（备用，正常情况下后台加载会完成）
  Future<void> _loadMoreGames() async {
    // 全量加载进行中时让路，避免分页错乱与重复请求
    if (_isLoadingMore || !_hasMoreData || _isLoading || _isLoadingAll) {
      return;
    }

    setState(() => _isLoadingMore = true);

    try {
      // 页码按已加载条数推算：修复后台部分加载后 _currentPage+1 跳页造成的断档
      // （如已有 20 条时按 perPage=100 应请求第 1 页补齐 21-100 条）
      final nextPage = (_allGames.length ~/ _fetchAllPerPage) + 1;
      final batch = await GameRepository.getGameList(
              page: nextPage, perPage: _fetchAllPerPage)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      // 修复重复加载：基于 ID 去重，避免服务端分页重叠导致重复条目
      final existingIds = _allGames.map((g) => g.id).toSet();
      final newGames = batch.where((g) => !existingIds.contains(g.id)).toList();

      setState(() {
        _allGames.addAll(newGames);
        // 如果返回为空或全部重复，说明没有更多新数据
        _hasMoreData =
            newGames.isNotEmpty && batch.length >= GameRepository.pageSize;
        _isLoadingMore = false;
      });
      DiscoverMetadataService.instance.registerCloudMetadataAll(newGames);
      _performFilter();
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// 强制刷新
  Future<void> _loadAllGames({bool forceRefresh = false}) =>
      _loadInitialGames(forceRefresh: forceRefresh);

  void _performFilter() {
    final query = _searchController.text.trim();

    // 搜索关键词（逗号/空格分隔，AND 关系）：每个关键词同时匹配标题/标签/会社
    final keywords = query.isEmpty
        ? <String>[]
        : query
            .split(RegExp(r'[,\s，]+'))
            .where((s) => s.isNotEmpty)
            .map((s) => s.toLowerCase())
            .toList();

    // 标签筛选（来自标签栏点击；统一小写以避免大小写不匹配）
    final activeTags = _selectedTags.isNotEmpty
        ? _selectedTags.map((t) => t.toLowerCase()).toSet()
        : <String>{};

    // 会社别名搜索文本（developer 原文 → 「标准名/日文名/中文名/别名」拼接，小写）。
    // 大搜索栏支持按会社昵称命中（如「精灵社」「雪碧社」→ sprite）；
    // 同一会社被多个游戏复用，按 developer 原文缓存避免每关键词重复解析。
    final aliasStore = CompanyAliasStore.instanceOrNull;
    final devHaystackCache = <String, String>{};
    String devHaystack(GameModel game) {
      final raw = game.developer;
      final cached = devHaystackCache[raw];
      if (cached != null) return cached;
      final match = aliasStore?.resolve(raw);
      if (match == null) {
        return devHaystackCache[raw] = raw.toLowerCase();
      }
      final r = match.record;
      final parts = <String>[
        r.standardName,
        if (r.jpName != null) r.jpName!,
        if (r.cnName != null) r.cnName!,
        ...r.aliases,
      ];
      return devHaystackCache[raw] =
          parts.map((p) => p.toLowerCase()).join('\n');
    }

    // 阶段4.4：从 DiscoverFilterState 读取高级筛选条件
    final filter = _filterState;
    final hasRatingFilter = filter.minRating > 0;
    final hasYearFilter = filter.yearFrom != null || filter.yearTo != null;
    final hasSizeFilter = filter.sizeBuckets.isNotEmpty;
    final hasInstallFilter = filter.installStatus != DiscoverInstallStatus.any;
    final needsMeta = filter.needsMetadata;
    final needsSize = filter.needsFileSize;

    List<GameModel> filtered = _allGames.where((game) {
      // 文本搜索：标题 / 日语原标题 / 英语标题 / 标签 / 会社
      // （每个关键词都需匹配至少一个字段，AND 关系，支持多语言标题搜索）
      if (keywords.isNotEmpty) {
        for (final q in keywords) {
          final titleMatch = game.title.toLowerCase().contains(q);
          final originalTitleMatch =
              game.originalTitle.toLowerCase().contains(q);
          final englishTitleMatch = game.englishTitle.toLowerCase().contains(q);
          final tagMatch = game.tags.any((t) => t.toLowerCase().contains(q));
          final devMatch = game.developer.toLowerCase().contains(q) ||
              devHaystack(game).contains(q);
          if (!titleMatch &&
              !originalTitleMatch &&
              !englishTitleMatch &&
              !tagMatch &&
              !devMatch) {
            return false;
          }
        }
      }

      // 标签筛选（统一小写匹配，修复大小写不匹配导致的新增标签筛选失效）
      if (activeTags.isNotEmpty) {
        final gameTags = game.tags.map((t) => t.toLowerCase()).toSet();
        if (!activeTags.every((t) => gameTags.any((gt) => gt.contains(t)))) {
          return false;
        }
      }

      // 顶栏 v2：会社筛选（OR 语义——单个游戏通常只归属一个会社，
      // 任一选中会社命中即保留）。两侧都先过 CompanyAliasStore 归一化，
      // 使「雪碧社」选中后能命中原文 sprite（与详情页写入同口径）。
      if (_selectedDevelopers.isNotEmpty) {
        final match = aliasStore?.resolve(game.developer);
        final gameDev =
            (match?.record.standardName ?? game.developer).toLowerCase();
        if (!_selectedDevelopers
            .any((d) => gameDev.contains(d.toLowerCase()))) {
          return false;
        }
      }

      // 顶栏 v3：资源来源筛选（OR 语义——勾选项命中任一即保留；空 = 全部）。
      // 官方下载 = games.has_official（官方直链一键安装判据）；
      // 个人分享 = 该作品存在已发布用户分享（_communityCounts 只写非零值）。
      if (_selectedResourceSources.isNotEmpty) {
        final hasShare = _communityCounts.containsKey(game.id);
        final officialOk = _selectedResourceSources
                .contains(DiscoverResourceSource.official) &&
            game.hasOfficial;
        final communityOk = _selectedResourceSources
                .contains(DiscoverResourceSource.community) &&
            hasShare;
        if (!officialOk && !communityOk) return false;
      }

      // 安装状态筛选（始终可用，基于 LocalGameRegistry）
      if (hasInstallFilter) {
        // ★ 2026-09-26 P1-4：优先按云端主键判定
        final isInstalled = LocalGameRegistry.instance
            .isCloudGameInstalled(game.id, game.title);
        if (filter.installStatus == DiscoverInstallStatus.installed &&
            !isInstalled) {
          return false;
        }
        if (filter.installStatus == DiscoverInstallStatus.notInstalled &&
            isInstalled) {
          return false;
        }
      }

      // 评分筛选（需要元数据；未抓取到的游戏被排除，后台会触发抓取）
      if (hasRatingFilter) {
        final meta = DiscoverMetadataService.instance.getMetadata(game.id);
        final rating = meta?.rating ?? 0.0;
        if (rating < filter.minRating) return false;
      }

      // 年份筛选（需要元数据）
      if (hasYearFilter) {
        final meta = DiscoverMetadataService.instance.getMetadata(game.id);
        final year = meta?.releaseYear;
        if (year == null) return false;
        if (filter.yearFrom != null && year < filter.yearFrom!) return false;
        if (filter.yearTo != null && year > filter.yearTo!) return false;
      }

      // 大小筛选（需要文件大小缓存；未缓存的游戏被排除）
      if (hasSizeFilter) {
        final size = _cachedSizes[game.id];
        if (size == null) return false;
        if (!filter.sizeBuckets.any((b) => b.contains(size))) return false;
      }

      return true;
    }).toList();

    // 排序
    switch (filter.sortOption) {
      case DiscoverSortOption.defaultOrder:
        break;
      case DiscoverSortOption.newestRelease:
        // 按 PB created 降序（始终可用）
        filtered.sort((a, b) => b.created.compareTo(a.created));
        break;
      case DiscoverSortOption.nameAsc:
        filtered.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case DiscoverSortOption.rating:
        // 按元数据评分降序，无元数据的排到尾部
        filtered.sort((a, b) {
          final ra =
              DiscoverMetadataService.instance.getMetadata(a.id)?.rating ?? 0.0;
          final rb =
              DiscoverMetadataService.instance.getMetadata(b.id)?.rating ?? 0.0;
          return rb.compareTo(ra);
        });
        break;
      case DiscoverSortOption.popularity:
        // 按投票数降序，无元数据的排到尾部
        filtered.sort((a, b) {
          final va =
              DiscoverMetadataService.instance.getMetadata(a.id)?.voteCount ??
                  0;
          final vb =
              DiscoverMetadataService.instance.getMetadata(b.id)?.voteCount ??
                  0;
          return vb.compareTo(va);
        });
        break;
      case DiscoverSortOption.fileSize:
        // 按文件大小降序，无缓存的排到尾部
        filtered.sort((a, b) {
          final sa = _cachedSizes[a.id] ?? 0;
          final sb = _cachedSizes[b.id] ?? 0;
          return sb.compareTo(sa);
        });
        break;
    }

    if (mounted) {
      setState(() {
        _displayGames = filtered;
        _isSearching = false;
      });
    }

    // 阶段4.4：当筛选需要元数据/大小时，后台触发全量抓取（不阻塞 UI）
    if (needsMeta) _triggerMetadataForAllGames();
    if (needsSize) _triggerSizeLoading();

    // 方案 §6.1：卡片「用户分享」角标——去抖批量现算（只查未查过的 gameId）
    _scheduleCommunityCountRefresh();
  }

  /// 阶段4.4：后台触发所有游戏元数据抓取（全局串行，不压垮用户电脑）
  void _triggerMetadataForAllGames() {
    for (final game in _allGames) {
      DiscoverMetadataService.instance.ensureMetadata(game.id, game.title);
    }
  }

  /// 阶段4.4：加载所有游戏的缓存文件大小，并在后台补抓缺失项
  Future<void> _triggerSizeLoading() async {
    if (_isLoadingSizes) return;
    _isLoadingSizes = true;
    try {
      // 第一步：同步读取所有已缓存的大小（内存 + 磁盘）
      for (final game in _allGames) {
        final size =
            await FileSizePrefetchService.instance.getCachedSizeOnly(game.id);
        if (size != null && size > 0) {
          _cachedSizes[game.id] = size;
        }
      }
      if (mounted) _performFilter();

      // 第二步：后台补抓缺失的大小（串行，避免并发请求压垮网络）
      for (final game in _allGames) {
        if (_cachedSizes.containsKey(game.id)) continue;
        if (game.downloadUrl.isEmpty) continue;
        try {
          final info = await FileSizePrefetchService.instance
              .prefetchSize(game.id, game.downloadUrl);
          if (info != null && info.sizeBytes > 0) {
            _cachedSizes[game.id] = info.sizeBytes;
            // 每抓到一个就刷新列表，让用户看到渐进式更新
            if (mounted) _performFilter();
          }
        } catch (_) {
          // 单个失败不影响整体
        }
      }
    } finally {
      _isLoadingSizes = false;
    }
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _selectedTags.clear();
      _selectedDevelopers.clear();
      _selectedResourceSources.clear();
      _filterState = DiscoverFilterState.defaultState;
    });
    _performFilter();
  }

  /// 打开全部标签弹出菜单（Overlay 方式，类似库页右键菜单）。
  /// 顶栏 v3：传入按受控词表维度分组的展示数据（未命中词表的标签进「其他」），
  /// 无搜索词时按组展示；选中集合仍是**原文标签**（筛选逻辑基于原文 contains，不变）。
  Future<void> _openAllTagsDialog() async {
    final allTags = _allAvailableTags.toList()..sort();
    final result = await TagsPopupMenu.show(
      context: context,
      anchorKey: _allTagsButtonKey,
      allTags: allTags,
      selectedTags: Set.from(_selectedTags),
      groups: _buildTagMenuGroups(),
    );
    if (result != null && mounted) {
      setState(() => _selectedTags = result);
      _performFilter();
    }
  }

  /// 顶栏 v3：把探索页全部原文标签按受控词表维度分组。
  /// - 命中词表：按概念所属维度归组，组内同概念（同义标签）相邻、再按显示名排序；
  /// - 未命中：进「其他」组放最后（不丢数据，词表后续补录即可归位）；
  /// - 词表未加载/为空：返回 null（面板自动退回平铺，不阻塞）。
  List<TagMenuGroup>? _buildTagMenuGroups() {
    final vocab = TagVocabularyStore.instanceOrNull;
    if (vocab == null || vocab.dimensions.isEmpty) return null;

    final byDim = <String, List<String>>{}; // dimensionId → 原文标签
    final sortKeys = <String, String>{}; // 原文标签 → 组内排序键（概念id+显示名）
    final unclassified = <String>[];
    for (final tag in _allAvailableTags) {
      final concept = vocab.resolve(tag);
      if (concept == null) {
        unclassified.add(tag);
        continue;
      }
      byDim.putIfAbsent(concept.dimensionId, () => []).add(tag);
      sortKeys[tag] = '${concept.id}\n${tag.toLowerCase()}';
    }
    unclassified.sort();

    final groups = <TagMenuGroup>[];
    for (final dim in vocab.dimensions) {
      final tags = byDim.remove(dim.id);
      if (tags == null || tags.isEmpty) continue;
      tags.sort((a, b) =>
          (sortKeys[a] ?? a).compareTo(sortKeys[b] ?? b));
      groups.add(TagMenuGroup(
        title: dim.title,
        tags: tags,
        color: dim.color,
      ));
    }
    if (unclassified.isNotEmpty) {
      // UI 显示名「其他」（数据层术语为 unclassified，即「未命中受控词表」）
      groups.add(TagMenuGroup(title: '其他', tags: unclassified));
    }
    return groups.isEmpty ? null : groups;
  }

  /// 顶栏 v2：打开会社弹出菜单（复用 TagsPopupMenu，锚点为会社组「全部」按钮）
  Future<void> _openAllDevsDialog() async {
    final allDevs = _allAvailableDevelopers.toList()..sort();
    final result = await TagsPopupMenu.show(
      context: context,
      anchorKey: _allDevButtonKey,
      allTags: allDevs,
      selectedTags: Set.from(_selectedDevelopers),
      // 菜单内搜索支持会社别名（如「精灵社」「雪碧社」→ sprite）
      searchAliases: _devSearchAliases(),
      hintText: '搜索会社...',
    );
    if (result != null && mounted) {
      setState(() => _selectedDevelopers = result);
      _performFilter();
    }
  }
  /// 会社显示名（standardName）→ 全部可用名（标准名/日文名/中文名/别名）。
  /// 供会社弹出菜单的搜索框做别名联想；词典未加载时返回空（退化为仅按显示名搜）。
  Map<String, List<String>> _devSearchAliases() {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return const {};
    final map = <String, List<String>>{};
    for (final game in _allGames) {
      final match = store.resolve(game.developer);
      if (match == null) continue;
      final std = match.record.standardName;
      if (map.containsKey(std)) continue;
      final r = match.record;
      map[std] = <String>[
        r.standardName,
        if (r.jpName != null) r.jpName!,
        if (r.cnName != null) r.cnName!,
        ...r.aliases,
      ];
    }
    return map;
  }

  Set<String> get _allAvailableTags {
    final tags = <String>{};
    for (final game in _allGames) {
      tags.addAll(game.tags);
    }
    return tags;
  }

  /// 顶栏 v2：会社分组数据源——全部游戏的 developer 归一化后去重（排除空值）。
  /// 归一化走 CompanyAliasStore（别名/昵称收敛到 standardName，与详情页写入
  /// setGameDeveloper 同口径）；词典未命中或未加载完成时保留原文。
  Set<String> get _allAvailableDevelopers {
    final store = CompanyAliasStore.instanceOrNull;
    final devs = <String>{};
    for (final game in _allGames) {
      final d = game.developer.trim();
      if (d.isEmpty) continue;
      final standard = store?.resolve(d)?.record.standardName ?? d;
      devs.add(standard);
    }
    return devs;
  }

  bool get _hasActiveFilters =>
      _searchController.text.trim().isNotEmpty ||
      _selectedTags.isNotEmpty ||
      _filterState.hasActiveFilters;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.pageBackground,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Stack(
        children: [
          // 内容层铺满整个区域：网格视口一直延伸到页面顶端，
          // 卡片滚动/悬停放大时从半透明顶栏底下透出可见
          Positioned.fill(child: _buildContent()),
          // 悬浮式顶部栏：搜索 + 筛选 + 标签，半透明背景，
          // 不占布局空间，固定不随列表滚动（与库页悬浮顶栏同款交互）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildFloatingTopBar(),
          ),
        ],
      ),
    );
  }

  /// 悬浮顶栏总高度（顶栏 v3，恒两行）：
  /// 20 顶部留白 + 36 第一行（搜索/来源/发布上传） + 8 间隙 + 34 第二行（筛选按钮行）。
  /// 网格顶部 padding 依赖此值在顶栏下方让出空间。
  static const double _topBarTopPadding = 20;
  static const double _topBarRowHeight = 36;
  static const double _topBarFilterRowHeight = 34;
  static const double _topBarRowGap = 8;
  double get _topBarHeight =>
      _topBarTopPadding + _topBarRowHeight + _topBarRowGap + _topBarFilterRowHeight;

  /// 悬浮式顶部栏（顶栏 v3：两行布局）
  ///
  /// 第一行：搜索框 + 资源来源筛选 + 发布上传；
  /// 第二行：标签 / 会社 / 评分 / 发售日期 / 排序（统一内联按钮风格，
  /// 点按弹下拉/面板选择——不再显示横向 chip 横幅）。
  ///
  /// 半透明背景 + 不占布局空间（Stack 覆盖在内容层上方）；
  /// 卡片滚动经过顶栏底下时透出可见。
  /// 背景用 AppColors.background（真实主题底色，跟随主题设计器），
  /// 不能用 pageBackground——带背景图的主题下它是 Colors.transparent，
  /// withOpacity 后会变成黑色半透明。
  Widget _buildFloatingTopBar() {
    return Container(
      padding: const EdgeInsets.only(top: _topBarTopPadding),
      decoration: BoxDecoration(
        // 半透明主题底色：滚动经过的卡片可透出，同时保证顶栏控件可读
        color: AppColors.background.withOpacity(0.82),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：搜索框 + 资源来源 + 发布上传
          Row(
            children: [
              Expanded(child: _buildSearchBar()),
              const SizedBox(width: _topBarRowGap),
              _buildInlineResourceSourceButton(),
              const SizedBox(width: 8),
              _buildTopBarActionButton(
                icon: Icons.rocket_launch_rounded,
                label: '发布上传',
                onTap: _openUploadPublish,
              ),
            ],
          ),
          const SizedBox(height: _topBarRowGap),
          // 第二行：标签 / 会社 / 评分 / 发售日期 / 排序。
          // 宽度充足时五等分 Expanded 填满整行（内容居中、间距 10）；
          // 窄窗口（<620）退回 shrink-wrap 横向滚动，不产生溢出异常。
          SizedBox(
            height: _topBarFilterRowHeight,
            child: LayoutBuilder(builder: (context, constraints) {
              final buttons = <Widget>[
                _buildInlineGroupButton(
                  anchorKey: _allTagsButtonKey,
                  title: '标签',
                  selectedCount: _selectedTags.length,
                  enabled: _allAvailableTags.isNotEmpty,
                  onTap: _openAllTagsDialog,
                ),
                _buildInlineGroupButton(
                  anchorKey: _allDevButtonKey,
                  title: '会社',
                  selectedCount: _selectedDevelopers.length,
                  enabled: _allAvailableDevelopers.isNotEmpty,
                  onTap: _openAllDevsDialog,
                ),
                _buildInlineRatingButton(),
                _buildInlineYearButton(),
                _buildInlineSortButton(),
              ];
              const gap = 10.0;
              const expandedThreshold = 620.0;
              if (constraints.maxWidth >= expandedThreshold) {
                return Row(
                  children: [
                    for (var i = 0; i < buttons.length; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      Expanded(child: buttons[i]),
                    ],
                  ],
                );
              }
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                child: Row(
                  children: [
                    for (var i = 0; i < buttons.length; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      buttons[i],
                    ],
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // ★ 离线模式：显示离线视图（有缓存则 banner+网格，无缓存则提示）
    if (!NetworkStatusService.instance.isOnline) {
      return Padding(
        padding: EdgeInsets.only(top: _topBarHeight + 16),
        child: _buildOfflineView(),
      );
    }
    if (_isLoading && !_hasLoadedOnce) {
      return _buildLoadingGrid();
    }

    if (_errorMessage != null && _allGames.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: _topBarHeight + 16),
        child: _buildErrorView(),
      );
    }

    if (!_isLoading && _displayGames.isEmpty && _hasLoadedOnce) {
      return Padding(
        padding: EdgeInsets.only(top: _topBarHeight + 16),
        child: _buildEmptyView(),
      );
    }

    return _buildGameGrid(topPadding: _topBarHeight + 16);
  }

  Widget _buildSearchBar() {
    final hasText = _searchController.text.trim().isNotEmpty;

    return Container(
      // 顶栏 v3：压缩搜索框高度（40→36），与第一行内联按钮同高
      height: _topBarRowHeight,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: hasText ? AppColors.selectedAccent : AppColors.border,
            width: hasText ? 2 : 1.4),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.2),
            offset: const Offset(2, 3),
            blurRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          // UX-21: 搜索语法提示图标，hover 显示完整语法说明
          Tooltip(
            message: '搜索语法：\n• 第一个词作为游戏名关键词\n• 空格或逗号分隔的后续词作为标签筛选\n例：东方 幻想',
            waitDuration: const Duration(milliseconds: 300),
            showDuration: const Duration(seconds: 4),
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(Icons.help_outline_rounded,
                  size: 17, color: AppColors.secondaryText.withOpacity(0.5)),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: AppStyles.bodyRegular
                  .copyWith(fontSize: 14, color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: '搜 索 游 戏...',
                hintStyle: AppStyles.bodyRegular.copyWith(
                  color: AppColors.primaryText.withOpacity(0.45),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
              onSubmitted: (_) => _performFilter(),
            ),
          ),
          if (hasText)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                _performFilter();
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.close_rounded,
                      size: 17,
                      color: AppColors.secondaryText.withOpacity(0.5)),
                ),
              ),
            )
          else
            SvgPicture.asset(
              'assets/images/search_icon.svg',
              width: 18,
              height: 18,
              colorFilter: ColorFilter.mode(
                AppColors.secondaryText.withOpacity(0.6),
                BlendMode.srcIn,
              ),
            ),
        ],
      ),
    );
  }

  // ==================== 顶栏：发布 / 上传双通道入口 ====================

  /// 顶栏「发布」「上传」共用入口：打开「上传 / 发布」选择器
  /// （先判重 → 命中跳详情页自动弹上传；未命中转入发布流程）。
  /// 命中跳转复用一次性信号 pendingAutoUploadGameId（零稳定区改动）。
  void _openUploadPublish() {
    UploadPublishDialog.show(context, onSelectGame: (g) {
      GameDetailPage.pendingAutoUploadGameId = g.id;
      widget.onGameTap?.call(GameCardData.fromModel(g));
    });
  }

  /// 顶栏动作按钮：与内联筛选控件同款容器（高 36 / 同圆角 / 同硬阴影），
  /// 但带 accent 前缀图标以区别于筛选语义。
  Widget _buildTopBarActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: _topBarRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border, width: 1.4),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: AppColors.selectedAccent),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 顶栏 v2：内联筛选控件（评分/年份/排序） ====================

  /// 内联控件公共容器（与搜索框同排同风格：同圆角/边框/硬阴影；
  /// 激活态边框加粗并高亮，与搜索框 hasText 分支一致。
  /// 顶栏 v3：第一行高 36，第二行筛选按钮高 34——整体比 v2.1 收紧一档。
  /// alignment center：Expanded 填满整行时内容居中；unbounded 时 shrink-wrap 不受影响）
  Widget _buildInlineControl({
    required GlobalKey anchorKey,
    required bool active,
    required VoidCallback onTap,
    required Widget child,
    double? height,
  }) {
    return GestureDetector(
      key: anchorKey,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: height ?? _topBarRowHeight,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: active ? AppColors.selectedAccent : AppColors.border,
              width: active ? 2 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  /// 顶栏 v3：资源来源内联控件（第一行）——来源 当前值 ▾（多选下拉面板）。
  /// 值显示：全部 / 官方 / 分享 / 官方+分享；未勾选任何项 = 不过滤（全部）。
  Widget _buildInlineResourceSourceButton() {
    final sel = _selectedResourceSources;
    final active = sel.isNotEmpty;
    final valueText = !active
        ? '全部'
        : (sel.length == 2
            ? '官方+分享'
            : (sel.contains(DiscoverResourceSource.official) ? '官方' : '分享'));
    return _buildInlineControl(
      anchorKey: _resourceSourceButtonKey,
      active: active,
      onTap: _openResourceSourcePanel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '来源',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            valueText,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: active ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: AppColors.secondaryText.withOpacity(0.5),
          ),
        ],
      ),
    );
  }

  /// 资源来源多选面板（点击即切换生效，面板保持打开；底部「完成」关闭）。
  /// 多选 OR 语义：勾选项命中任一即保留；全不勾 = 全部来源。
  void _openResourceSourcePanel() {
    _showAnchorPanel<void>(
      anchorKey: _resourceSourceButtonKey,
      panelWidth: 168,
      builder: (close) {
        return StatefulBuilder(
          builder: (context, setPanelState) {
            void toggle(DiscoverResourceSource source) {
              if (mounted) {
                setState(() {
                  if (_selectedResourceSources.contains(source)) {
                    _selectedResourceSources.remove(source);
                  } else {
                    _selectedResourceSources.add(source);
                  }
                });
                _performFilter();
              }
              setPanelState(() {});
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildResourceSourceItem(
                  source: DiscoverResourceSource.official,
                  label: '官方下载',
                  onTap: () => toggle(DiscoverResourceSource.official),
                ),
                _buildResourceSourceItem(
                  source: DiscoverResourceSource.community,
                  label: '个人分享',
                  onTap: () => toggle(DiscoverResourceSource.community),
                ),
                Divider(height: 1, thickness: 1, color: AppColors.border.withOpacity(0.4)),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => close(null),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    child: Text(
                      '完 成',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 资源来源面板单个选项（勾选态样式对齐排序菜单：check 区 + 标签）
  Widget _buildResourceSourceItem({
    required DiscoverResourceSource source,
    required String label,
    required VoidCallback onTap,
  }) {
    final isSelected = _selectedResourceSources.contains(source);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: isSelected
                  ? Icon(Icons.check_rounded,
                      size: 14, color: AppColors.infoBlue)
                  : null,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppColors.infoBlue : AppColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏 v3：第二行标签/会社分组按钮——「组名 + 当前值 ▾」内联按钮，
  /// 点击弹出该组完整多选菜单（TagsPopupMenu）；不再显示横向 chip 横幅。
  /// 组内无候选（数据未就绪/空库）时降为不可点（文字弱化）。
  Widget _buildInlineGroupButton({
    required GlobalKey anchorKey,
    required String title,
    required int selectedCount,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final active = enabled && selectedCount > 0;
    return _buildInlineControl(
      anchorKey: anchorKey,
      active: active,
      height: _topBarFilterRowHeight,
      onTap: enabled ? onTap : () {},
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: enabled
                  ? AppColors.secondaryText
                  : AppColors.secondaryText.withOpacity(0.4),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            selectedCount > 0 ? '$selectedCount 项' : '全部',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: active
                  ? AppColors.primaryText
                  : AppColors.secondaryText.withOpacity(
                      enabled ? 1 : 0.4,
                    ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: AppColors.secondaryText
                .withOpacity(enabled ? 0.5 : 0.25),
          ),
        ],
      ),
    );
  }

  /// 评分内联控件（第二行）：评分 ★ 当前值（不限 / ≥X 分）
  Widget _buildInlineRatingButton() {
    final hasRating = _filterState.minRating > 0;
    return _buildInlineControl(
      anchorKey: _ratingButtonKey,
      active: hasRating,
      height: _topBarFilterRowHeight,
      onTap: _openRatingPanel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '评分',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.star_rounded,
            size: 15,
            color: hasRating
                ? AppColors.starGold
                : AppColors.secondaryText.withOpacity(0.7),
          ),
          const SizedBox(width: 2),
          Text(
            hasRating
                ? '≥ ${_filterState.minRating.toStringAsFixed(1)}'
                : '不限',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color:
                  hasRating ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
        ],
      ),
    );
  }

  /// 发售日期内联控件（第二行，v3 由「年份」更名）：当前范围（不限 / from—to）
  Widget _buildInlineYearButton() {
    final from = _filterState.yearFrom;
    final to = _filterState.yearTo;
    final hasYear = from != null || to != null;
    return _buildInlineControl(
      anchorKey: _yearButtonKey,
      active: hasYear,
      height: _topBarFilterRowHeight,
      onTap: _openYearPanel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '发售日期',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              hasYear ? '${from ?? '…'}—${to ?? '…'}' : '不限',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color:
                    hasYear ? AppColors.primaryText : AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 排序内联控件（第二行）：排序 当前值 ▾（下拉单选菜单）
  Widget _buildInlineSortButton() {
    final active = _filterState.sortOption != DiscoverSortOption.defaultOrder;
    return _buildInlineControl(
      anchorKey: _sortButtonKey,
      active: active,
      height: _topBarFilterRowHeight,
      onTap: _openSortMenu,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '排序',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            _sortOptionLabel(_filterState.sortOption),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: active ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 14,
            color: AppColors.secondaryText.withOpacity(0.5),
          ),
        ],
      ),
    );
  }

  /// 排序方式显示名（菜单顺序对齐设计图：默认顺序 + 最新发布/评分/名称 A-Z/文件大小/热度）
  static String _sortOptionLabel(DiscoverSortOption option) {
    switch (option) {
      case DiscoverSortOption.defaultOrder:
        return '默认';
      case DiscoverSortOption.newestRelease:
        return '最新发布';
      case DiscoverSortOption.rating:
        return '评分';
      case DiscoverSortOption.nameAsc:
        return '名称 A-Z';
      case DiscoverSortOption.fileSize:
        return '文件大小';
      case DiscoverSortOption.popularity:
        return '热度';
    }
  }

  /// 排序下拉菜单（Overlay 单选列表，当前项打勾——对齐设计图展开态）
  void _openSortMenu() {
    _showAnchorPanel<DiscoverSortOption>(
      anchorKey: _sortButtonKey,
      panelWidth: 150,
      builder: (close) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in DiscoverSortOption.values)
            _buildSortMenuItem(option, close),
        ],
      ),
    ).then((option) {
      if (option != null && mounted && option != _filterState.sortOption) {
        setState(
            () => _filterState = _filterState.copyWith(sortOption: option));
        _performFilter();
      }
    });
  }

  Widget _buildSortMenuItem(
      DiscoverSortOption option, void Function(DiscoverSortOption?) close) {
    final isSelected = _filterState.sortOption == option;
    return InkWell(
      onTap: () => close(option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: isSelected
                  ? Icon(Icons.check_rounded,
                      size: 14, color: AppColors.infoBlue)
                  : null,
            ),
            const SizedBox(width: 4),
            Text(
              _sortOptionLabel(option),
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppColors.infoBlue : AppColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 评分弹出面板（滑块拖动实时预览，松手提交筛选）
  void _openRatingPanel() {
    _showAnchorPanel<double>(
      anchorKey: _ratingButtonKey,
      panelWidth: 240,
      builder: (close) {
        double value = _filterState.minRating;
        return StatefulBuilder(
          builder: (context, setPanelState) {
            return Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.star_rounded,
                          size: 14, color: AppColors.starGold),
                      const SizedBox(width: 4),
                      Text(
                        '最低评分',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        value <= 0 ? '不限' : '≥ ${value.toStringAsFixed(1)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.infoBlue,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 13),
                    ),
                    child: Slider(
                      value: value,
                      min: 0,
                      max: 10,
                      divisions: 20,
                      label: value <= 0 ? '不限' : value.toStringAsFixed(1),
                      activeColor: AppColors.starGold,
                      onChanged: (v) => setPanelState(() => value = v),
                      onChangeEnd: (v) {
                        if (mounted) {
                          setState(() => _filterState =
                              _filterState.copyWith(minRating: v));
                          _performFilter();
                        }
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => close(null),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      child: Text(
                        '完 成',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 年份弹出面板（RangeSlider 1990—当前年；滑块贴端视为不限，与高级筛选弹窗语义一致）
  void _openYearPanel() {
    _showAnchorPanel<int>(
      anchorKey: _yearButtonKey,
      panelWidth: 260,
      builder: (close) {
        const minYear = 1990;
        final maxYear = DateTime.now().year;
        RangeValues value = RangeValues(
          (_filterState.yearFrom ?? minYear)
              .toDouble()
              .clamp(minYear.toDouble(), maxYear.toDouble()),
          (_filterState.yearTo ?? maxYear)
              .toDouble()
              .clamp(minYear.toDouble(), maxYear.toDouble()),
        );
        String rangeLabel(RangeValues v) {
          final from = v.start.round() <= minYear ? null : v.start.round();
          final to = v.end.round() >= maxYear ? null : v.end.round();
          if (from == null && to == null) return '不限';
          return '${from ?? '…'}—${to ?? '…'}';
        }

        return StatefulBuilder(
          builder: (context, setPanelState) {
            return Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.calendar_month_rounded,
                          size: 14, color: AppColors.secondaryText),
                      const SizedBox(width: 4),
                      Text(
                        '发售日期范围',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        rangeLabel(value),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.infoBlue,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      rangeThumbShape: const RoundRangeSliderThumbShape(
                          enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 13),
                    ),
                    child: RangeSlider(
                      values: value,
                      min: minYear.toDouble(),
                      max: maxYear.toDouble(),
                      divisions: maxYear - minYear,
                      labels: RangeLabels(
                        '${value.start.round()}',
                        '${value.end.round()}',
                      ),
                      activeColor: AppColors.infoBlue,
                      onChanged: (v) => setPanelState(() => value = v),
                      onChangeEnd: (v) {
                        if (!mounted) return;
                        final from =
                            v.start.round() <= minYear ? null : v.start.round();
                        final to =
                            v.end.round() >= maxYear ? null : v.end.round();
                        setState(() {
                          _filterState = _filterState.copyWith(
                            yearFrom: from,
                            yearTo: to,
                            clearYearFrom: from == null,
                            clearYearTo: to == null,
                          );
                        });
                        _performFilter();
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => close(null),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      child: Text(
                        '完 成',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 顶栏 v2：通用锚点弹出面板（Overlay，点击遮罩关闭；选择值经 Completer 回传）
  /// 定位：锚点下方 6px、水平随锚点左对齐并防右溢出；纵向放不下时上翻。
  /// 面板样式与顶栏控件同族：实底背景 + 发丝边 + 硬投影。
  Future<T?> _showAnchorPanel<T>({
    required GlobalKey anchorKey,
    required double panelWidth,
    // close 接受 T?：null 表示「关闭但不改变选择」（评分/年份面板的「完成」按钮）
    required Widget Function(void Function(T? value) close) builder,
  }) {
    final renderBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return Future.value(null);

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final anchorRect = offset & size;

    final completer = Completer<T?>();
    late OverlayEntry entry;
    void close(T? value) {
      entry.remove();
      if (!completer.isCompleted) completer.complete(value);
    }

    entry = OverlayEntry(
      builder: (ctx) {
        final screenSize = MediaQuery.sizeOf(ctx);
        const margin = 8.0;
        final maxLeft = (screenSize.width - panelWidth - margin)
            .clamp(margin, 1 << 20)
            .toDouble();
        final left = anchorRect.left.clamp(margin, maxLeft).toDouble();

        // 面板高度随内容：先按下方放置，纵向余量不足时上翻（按估算高 220）
        double top = anchorRect.bottom + 6;
        if (top + 220 > screenSize.height - margin) {
          top = (anchorRect.top - 220).clamp(margin, 1 << 20).toDouble();
        }

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => close(null),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: panelWidth,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(color: AppColors.border, width: 1.4),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.border.withOpacity(0.25),
                        offset: const Offset(4, 5),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: builder(close),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(entry);
    return completer.future;
  }

  Widget _buildLoadingGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          // 与正式网格相同的让位规则（悬浮顶栏高度 + 间隙）
          padding: EdgeInsets.only(top: _topBarHeight + 16, bottom: 8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2 / 3,
          ),
          itemCount: 8,
          itemBuilder: (context, index) => ShimmerPlaceholder(),
        );
      },
    );
  }

  /// ★ 离线视图：有缓存则 banner + 缓存网格；无缓存则离线提示。
  Widget _buildOfflineView() {
    final hasCache = _allGames.isNotEmpty;
    return Column(
      children: [
        // 离线 banner（始终显示）
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.starGold.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: AppColors.starGold.withOpacity(0.5), width: 1),
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded,
                  size: 18, color: AppColors.starGold),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasCache
                      ? '离线状态 — 显示上次缓存的内容，部分信息可能不是最新'
                      : '离线状态 — 无法加载在线内容，请检查网络连接',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 13,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: hasCache ? _buildGameGrid() : _buildOfflineEmptyView(),
        ),
      ],
    );
  }

  /// 离线无缓存时的纯提示视图。
  Widget _buildOfflineEmptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded,
              size: 56, color: AppColors.secondaryText.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('离线模式', style: AppStyles.gameTitle.copyWith(fontSize: 18)),
          const SizedBox(height: 8),
          Text('探索页需要联网加载游戏列表',
              style: AppStyles.bodyRegular
                  .copyWith(color: AppColors.secondaryText)),
          const SizedBox(height: 8),
          Text('您可以继续使用游戏库、启动游戏、添加和导入游戏',
              style: AppStyles.bodyRegular.copyWith(
                  fontSize: 12,
                  color: AppColors.secondaryText.withOpacity(0.7))),
          const SizedBox(height: 20),
          Semantics(
            label: '重试连接',
            button: true,
            child: GestureDetector(
              onTap: () => NetworkStatusService.instance.checkNow(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    border: AppStyle.isModern
                        ? Border.all(
                            color: AppColors.borderLight,
                            width: AppStyle.wHairline)
                        : Border.all(color: AppColors.border, width: 2),
                    borderRadius:
                        BorderRadius.circular(AppStyle.isModern ? AppStyle.rMd : 6),
                    boxShadow: AppStyle.isModern
                        ? AppStyle.e1
                        : [
                            BoxShadow(
                                color: AppColors.border,
                                offset: const Offset(2, 3),
                                blurRadius: 0),
                          ],
                  ),
                  child: Text('重试连接',
                      style: AppStyles.bodyRegular
                          .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _errorMessage ?? '加载失败',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 20),
          Semantics(
            label: '重新加载',
            button: true,
            child: GestureDetector(
              onTap: () => _loadAllGames(forceRefresh: true),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    border: Border.all(color: AppColors.border, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: Text(
                    '重新加载',
                    style: AppStyles.bodyRegular
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded,
              size: 48, color: AppColors.secondaryText.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            _hasActiveFilters ? '未找到相关游戏' : '还没有游戏哦~',
            style: AppStyles.gameTitle.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            _hasActiveFilters ? '试试其他关键词或标签' : '管理员还在努力添加中...',
            style:
                AppStyles.bodyRegular.copyWith(color: AppColors.secondaryText),
          ),
          if (_hasActiveFilters) ...[
            const SizedBox(height: 16),
            Semantics(
              label: '查看全部游戏',
              button: true,
              child: GestureDetector(
                onTap: _clearFilters,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.buttonBackground,
                      border: Border.all(color: AppColors.border, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.border,
                          offset: const Offset(2, 3),
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Text(
                      '查看全部游戏',
                      style: AppStyles.bodyRegular
                          .copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// [topPadding] 网格顶部留白：主网格传悬浮顶栏高度 + 间隙，
  /// 让首行卡片显示在顶栏下方；离线视图的网格上方有 banner，用默认小间距即可
  Widget _buildGameGrid({double topPadding = 16}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          key: const PageStorageKey<String>('discover_game_grid'),
          controller: _scrollController,
          cacheExtent: 1200, // v2.1.16: 4000 会把视口外几十张封面提前塞进
          // 下载队列（cache_manager 10 并发槽被占满），可见卡片的封面反而
          // 排队变慢；1200≈上下各 1.5 行，快速滚动空档由占位底色渐入兜底
          // 顶部/底部留白必须放在 GridView 自身 padding（视口内）而非外层：
          // 1. 首行卡片显示在悬浮顶栏下方，滚动时内容从顶栏底下经过、
          //    透过半透明背景可见；
          // 2. hover 放大（-4px 上移 + 2.5% 缩放）会向格子外溢出，
          //    只有视口内的空间才能承接溢出，避免封面被视口边缘裁剪
          padding: EdgeInsets.only(top: topPadding, bottom: 8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2 / 3,
          ),
          itemCount: _displayGames.length + (_isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _displayGames.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            // UX-34: RepaintBoundary 隔离每张卡片的重绘
            return RepaintBoundary(
              child: Semantics(
                label: '游戏: ${_displayGames[index].title}',
                button: true,
                child: _DiscoverCardWidget(
                  key: ValueKey('discover_card_${_displayGames[index].id}'),
                  game: GameCardData.fromModel(_displayGames[index]),
                  // 方案 §6.1：用户分享数（批量现算，未查询到视为 0 → 不渲染角标）
                  communityCount:
                      _communityCounts[_displayGames[index].id] ?? 0,
                  onTap: () => widget.onGameTap
                      ?.call(GameCardData.fromModel(_displayGames[index])),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DiscoverCardWidget extends StatefulWidget {
  final GameCardData game;
  final VoidCallback onTap;

  /// 该作品的已发布用户分享数（方案 §6.1 角标；0 = 无用户分享）
  final int communityCount;

  const _DiscoverCardWidget({
    super.key,
    required this.game,
    required this.onTap,
    this.communityCount = 0,
  });

  @override
  State<_DiscoverCardWidget> createState() => _DiscoverCardWidgetState();
}

class _DiscoverCardWidgetState extends State<_DiscoverCardWidget>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _hoverController;

  /// 缓存"已安装"状态，避免 build 中重复查询 LocalGameRegistry
  /// （registry 内部数据由异步 scan 填充，build 中查询会产生 race condition
  /// 导致徽章在 hover/click 后消失）
  bool _isInstalled = false;

  /// 卡片对应的元数据（评分/发售年/热度），由 DiscoverMetadataService 懒加载
  DiscoverGameMetadata? _metadata;

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
    _isInstalled = LocalGameRegistry.instance
        .isCloudGameInstalled(widget.game.id, widget.game.title);
    LocalGameRegistry.instance.addListener(_onRegistryChanged);

    // 阶段3.3：懒加载元数据（视口内卡片触发抓取）
    _metadata = DiscoverMetadataService.instance.getMetadata(widget.game.id);
    DiscoverMetadataService.instance.addListener(_onMetadataChanged);
    // 后台触发抓取（不阻塞 build）
    DiscoverMetadataService.instance
        .ensureMetadata(widget.game.id, widget.game.title);

    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0.0,
    );
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    DiscoverMetadataService.instance.removeListener(_onMetadataChanged);
    _hoverController.dispose();
    super.dispose();
  }

  /// 监听 LocalGameRegistry 变化，仅在结构性变更时刷新徽章。
  /// 忽略 playTimeUpdate（30s 周期触发），避免游戏运行时全量卡片重建。
  void _onRegistryChanged() {
    if (!mounted) return;
    // 过滤游玩时长周期更新，避免不必要的 rebuild
    if (LocalGameRegistry.instance.lastChangeReason ==
        RegistryChangeReason.playTimeUpdate) {
      return;
    }
    final newInstalled = LocalGameRegistry.instance
        .isCloudGameInstalled(widget.game.id, widget.game.title);
    if (newInstalled != _isInstalled) {
      setState(() => _isInstalled = newInstalled);
    }
  }

  /// 监听元数据服务变化，仅当本卡片的元数据更新时重建
  void _onMetadataChanged() {
    if (!mounted) return;
    final newMeta =
        DiscoverMetadataService.instance.getMetadata(widget.game.id);
    if (newMeta != _metadata) {
      setState(() => _metadata = newMeta);
    }
  }

  void _onHoverEnter() {
    setState(() => _hovered = true);
    _hoverController.forward();
  }

  void _onHoverExit() {
    if (_hovered) {
      setState(() => _hovered = false);
      _hoverController.reverse();
    }
  }

  Widget _buildCoverImage(String coverUrl) {
    if (coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return _buildCoverPlaceholder();
    }

    // NSFW 局部打码（v2）：v2.5 起揭示入口是右下角角标按钮，不抢卡片的
    // 「点击进入详情」语义，故可以开 enableReveal。
    // 发现页封面只走网络 URL（PB/元数据平台），全量扫描覆盖不到，
    // 必须开按需检测；child 缓存须走 PortableImageCacheManager（检测
    // 靠它查落盘文件），漏传会回退系统盘 DefaultCacheManager 导致检测永不触发。
    return NsfwImage.network(
      coverUrl,
      contentKind: NsfwContentKind.cover,
      fit: BoxFit.cover,
      enableReveal: true,
      detectOnDemand: true,
      // 与 child 的 memCacheWidth / maxWidthDiskCache 对齐，
      // 让两边 ImageProvider 缓存键相同，同一张图只解码一次
      decodeWidth: 480,
      diskCacheWidth: 800,
      child: CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: coverUrl,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        // 性能优化: 仅限制宽度，高度按原图比例缩放。
        // 修复: 之前同时指定 memCacheWidth+memCacheHeight 会导致 Flutter 解码时
        // 强制拉伸到固定尺寸（不保持宽高比），造成"左右弯折"变形。
        // 详情页未设置这些参数显示正常，此处改为单维度限制以保持一致。
        memCacheWidth: 480,
        maxWidthDiskCache: 800,
        // 性能优化: 取消淡入动画，避免快速滚动时图片"跳变"
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => _buildCoverLoading(),
        errorWidget: (context, url, error) => _buildCoverError(),
      ),
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined,
                size: 40, color: AppColors.secondaryText.withOpacity(0.5)),
            const SizedBox(height: 8),
            Text(
              '暂无封面',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.secondaryText.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverLoading() {
    // 性能优化: 滚动时多张卡片同时加载会产生 N 个旋转动画控制器，
    // 是滚动卡顿的主因之一。改为静态占位，无动画。
    return Container(color: AppColors.placeholderCover);
  }

  Widget _buildCoverError() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 36, color: AppColors.dangerRed.withOpacity(0.4)),
            const SizedBox(height: 8),
            Text(
              '加载失败',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.dangerRed.withOpacity(0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段3.3：发售年份角标（封面左下角）
  /// 半透明深色背景 + 白色小字，不喧宾夺主
  Widget _buildYearBadge(int year) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$year',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  /// 方案 §6.1：资源来源角标（封面右上角）
  ///
  /// - 有官方来源          → `可安装`
  /// - 仅用户分享          → `用户分享`
  /// - 两者都有            → `可安装 · N 分享`
  ///
  /// 位置与左上角「已安装」徽章错角：后者是**本地**状态，本角标是**云端来源**，
  /// 两者可同时成立，挤在同一角会互相遮挡。
  /// 样式沿用年份/评分角标的半透明深色药丸（信息级，不喧宾夺主）；
  /// 图标取新设计语言的主色：青蓝=获取/可安装，紫=分享/上传。
  Widget _buildSourceBadge({
    required bool hasOfficial,
    required int communityCount,
  }) {
    final bool hasCommunity = communityCount > 0;
    if (!hasOfficial && !hasCommunity) return const SizedBox.shrink();

    final String label;
    if (hasOfficial && hasCommunity) {
      label = '可安装 · $communityCount 分享';
    } else if (hasOfficial) {
      label = '可安装';
    } else {
      label = '用户分享';
    }
    final Color tint =
        hasOfficial ? AppColors.accentCyan : AppColors.accentViolet;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasOfficial ? Icons.download_rounded : Icons.people_alt_rounded,
            size: 10,
            color: tint,
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  /// 阶段3.3：评分角标（封面右下角）
  /// 星标 + 分数，半透明深色背景，金色星标
  Widget _buildRatingBadge(double rating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 10, color: AppColors.starGold),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 使用 initState 中缓存的 _isInstalled，避免 build 中重复查询
    final isInstalled = _isInstalled;

    final cardContent = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: isInstalled ? AppColors.successGreen : AppColors.border,
          width: AppStyle.isModern
              ? (isInstalled ? 1.6 : AppStyle.wHairline)
              : (isInstalled ? 2.5 : 2),
        ),
        // 圆角卡片：配合 clipBehavior 将封面裁成圆角，柔化整体观感。
        // 探索页卡片较大（宽至 240），6px 与库页小卡片（宽 ~160）的 4px 视觉等比
        borderRadius: BorderRadius.circular(AppStyle.isModern ? AppStyle.rMd : 6),
        boxShadow: AppStyle.isModern
            ? (_hovered ? AppStyle.e2 : AppStyle.e1)
            : [_hovered ? _hoverShadow : _normalShadow],
        color: AppColors.background,
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildCoverImage(widget.game.coverPath),
          Container(color: AppColors.background.withOpacity(0.33)),
          if (isInstalled)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.successGreen,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '已安装',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          // 方案 §6.1：资源来源角标（右上角，与「已安装」错角）
          if (widget.game.hasOfficial || widget.communityCount > 0)
            Positioned(
              top: 6,
              right: 6,
              child: _buildSourceBadge(
                hasOfficial: widget.game.hasOfficial,
                communityCount: widget.communityCount,
              ),
            ),
          // 阶段3.3：元数据角标（融洽不喧宾夺主）
          // 左下角：发售年份
          if (_metadata?.releaseYear != null)
            Positioned(
              bottom: 6,
              left: 6,
              child: _buildYearBadge(_metadata!.releaseYear!),
            ),
          // 右下角：评分
          if (_metadata?.rating != null && _metadata!.rating! > 0)
            Positioned(
              bottom: 6,
              right: 6,
              child: _buildRatingBadge(_metadata!.rating!),
            ),
        ],
      ),
    );

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: AnimatedBuilder(
          animation: _hoverController,
          builder: (context, child) {
            final t = _hoverController.value;
            // 结构恒定的 Transform 链（t=0 时为恒等变换），不要在
            // 「有 Transform / 无 Transform」两套 widget 树之间切换：
            // 树结构变化会让整张卡片子树在 hover 进入/退出的首帧被
            // unmount 重建，其中的 NsfwImage.network 会丢失全部检测状态
            // （按需检测尝试计数/放行标志都是 State 局部变量）——判定
            // 未落定（图片尚未落盘/判定排队/曾超时放行）的封面会在
            // 悬停放大的瞬间回到「未判定 → 模糊预览」分支，表现为
            // "已清晰的封面一悬停就又模糊"（v2.1.15 用户实测，探索页
            // 为网络图、重试窗口仅 2 次，gaveUp 放行的比例更高，故
            // 该现象在探索页格外明显）。
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cardContent),
                const SizedBox(height: 8),
                // 标题区：固定高度 38。短标题字号 ~20px 与旧单行版一致，
                // 长标题换行到第二行并按需缩小（两行最高 ~15px），完整显示；
                // 富余空白落在区域底部（卡片底缘，不可见）
                SizedBox(
                  height: 38,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: AutoSizeText(
                      widget.game.title.isNotEmpty
                          ? widget.game.title
                          : '未命名游戏',
                      style: AppStyles.gameTitle.copyWith(
                        fontSize: 20,
                        height: 1.25,
                      ),
                      maxLines: 2,
                      minFontSize: 12,
                      stepGranularity: 0.5,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ShimmerPlaceholder extends StatefulWidget {
  const ShimmerPlaceholder({super.key});

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward(); // 性能优化: 一次性入场动画，避免 repeat 持续运行导致滚动时分心
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Color.lerp(AppColors.placeholderCover,
                      AppColors.cardHoverBg, _controller.value)!,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 18,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Color.lerp(AppColors.placeholderCover,
                    AppColors.cardHoverBg, _controller.value)!,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        );
      },
    );
  }
}
