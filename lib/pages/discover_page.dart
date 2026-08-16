import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../models/game_model.dart';
import '../models/discover_filter_state.dart';
import '../repositories/game_repository.dart';
import '../core/pb_config.dart';
import '../services/global_install_center.dart';
import '../services/local_game_registry.dart';
import '../services/discover_metadata_service.dart';
import '../services/file_size_service.dart';
import '../services/network_status_service.dart';
import '../widgets/discover_disclaimer_dialog.dart';
import '../widgets/discover_filter_dialog.dart';
import '../widgets/tags_popup_menu.dart';

class GameCardData {
  final String id;
  final String title;
  final String coverPath;
  final List<String> tags;
  final String description;
  final String developer;

  const GameCardData({
    required this.id,
    required this.title,
    required this.coverPath,
    this.tags = const [],
    this.description = '',
    this.developer = '',
  });

  factory GameCardData.fromModel(GameModel model) => GameCardData(
        id: model.id,
        title: model.title,
        coverPath: model.coverUrl,
        tags: model.tags,
        description: model.description,
        developer: model.developer,
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
  // 阶段4.4：筛选状态跨页面持久化（静态变量，切回探索页时恢复）
  static DiscoverFilterState? _cachedFilterState;

  List<GameModel> _allGames = [];
  List<GameModel> _displayGames = [];
  Set<String> _selectedTags = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSearching = false;
  bool _hasLoadedOnce = false;
  bool _hasMoreData = true;
  int _currentPage = 1;
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

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // 标签栏横向滚动控制器：桌面端鼠标滚轮默认只产生垂直滚动量，
  // 水平 ListView 不会响应，需通过 Listener(onPointerSignal) 转换。
  final ScrollController _tagScrollController = ScrollController();
  // 「全部标签」按钮的 GlobalKey，用于定位弹出菜单的锚点位置
  final GlobalKey _allTagsButtonKey = GlobalKey();
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
    // ★ 离线模式：监听网络状态，恢复时自动刷新，断网时切离线视图
    _wasOnline = NetworkStatusService.instance.isOnline;
    NetworkStatusService.instance.addListener(_onNetworkStatusChanged);
    if (_cachedAllGames != null && _cachedAllGames!.isNotEmpty) {
      _allGames = _cachedAllGames!;
      _hasLoadedOnce = true;
      _cacheTime = DateTime.now();
      if (_cachedSearchText != null && _cachedSearchText!.isNotEmpty) {
        _searchController.text = _cachedSearchText!;
      }
      if (_cachedSelectedTags != null && _cachedSelectedTags!.isNotEmpty) {
        _selectedTags = Set.from(_cachedSelectedTags!);
      }
      _searchController.addListener(_onSearchChanged);
      LocalGameRegistry.instance.refreshStaleEntries();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performFilter();
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
    _cachedFilterState = _filterState;
    _debounceTimer?.cancel();
    _metaRefreshTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    _tagScrollController.dispose();
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
      // 恢复在线：后台刷新游戏列表（有缓存时不显示 loading）
      _loadAllGames(forceRefresh: true);
    } else {
      // 转为离线：重建 UI 显示离线视图
      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });
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
        _currentPage = 1;
        _hasMoreData = firstBatch.length >= _initialPageSize;
        _cacheTime = DateTime.now();
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorMessage = null;
      });

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

  /// 后台加载全部数据（与原始逻辑一致，确保所有游戏都能加载）
  Future<void> _loadAllGamesInBackground() async {
    final allGames = <GameModel>[];
    int page = 1;
    bool hasMore = true;

    while (hasMore) {
      try {
        final batch = await GameRepository.getGameList(
            page: page, perPage: _fetchAllPerPage);
        if (batch.isEmpty) {
          hasMore = false;
        } else {
          allGames.addAll(batch);
          hasMore = batch.length >= _fetchAllPerPage;
          page++;
        }
      } catch (e) {
        debugPrint('[DISCOVER] 后台加载第$page页失败: $e');
        // 加载失败时使用已获取的数据
        break;
      }
    }

    if (!mounted) return;

    // 仅在获取到数据时替换（避免后台加载失败时清空已有数据）
    if (allGames.isNotEmpty) {
      setState(() {
        _allGames = allGames;
        _hasMoreData = false;
        _currentPage = page;
      });
      _performFilter();
    }
  }

  /// 滚动到底部时加载更多（备用，正常情况下后台加载会完成）
  Future<void> _loadMoreGames() async {
    if (_isLoadingMore || !_hasMoreData || _isLoading) return;

    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      final batch = await GameRepository.getGameList(
          page: nextPage, perPage: _fetchAllPerPage);

      if (!mounted) return;

      // 修复重复加载：基于 ID 去重，避免服务端分页重叠导致重复条目
      final existingIds = _allGames.map((g) => g.id).toSet();
      final newGames = batch.where((g) => !existingIds.contains(g.id)).toList();

      setState(() {
        _allGames.addAll(newGames);
        _currentPage = nextPage;
        // 如果返回为空或全部重复，说明没有更多新数据
        _hasMoreData =
            newGames.isNotEmpty && batch.length >= GameRepository.pageSize;
        _isLoadingMore = false;
      });
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

    // 阶段4.4：从 DiscoverFilterState 读取高级筛选条件
    final filter = _filterState;
    final hasRatingFilter = filter.minRating > 0;
    final hasYearFilter = filter.yearFrom != null || filter.yearTo != null;
    final hasSizeFilter = filter.sizeBuckets.isNotEmpty;
    final hasInstallFilter = filter.installStatus != DiscoverInstallStatus.any;
    final needsMeta = filter.needsMetadata;
    final needsSize = filter.needsFileSize;

    List<GameModel> filtered = _allGames.where((game) {
      // 文本搜索：标题 / 标签 / 会社（每个关键词都需匹配至少一个字段，AND 关系）
      if (keywords.isNotEmpty) {
        for (final q in keywords) {
          final titleMatch = game.title.toLowerCase().contains(q);
          final tagMatch = game.tags.any((t) => t.toLowerCase().contains(q));
          final devMatch = game.developer.toLowerCase().contains(q);
          if (!titleMatch && !tagMatch && !devMatch) {
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

      // 安装状态筛选（始终可用，基于 LocalGameRegistry）
      if (hasInstallFilter) {
        final isInstalled =
            LocalGameRegistry.instance.isTitleInstalled(game.title);
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

  void _toggleTag(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
    });
    _performFilter();
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _selectedTags.clear();
      _filterState = DiscoverFilterState.defaultState;
    });
    _performFilter();
  }

  /// 阶段4.4：打开高级筛选弹窗
  Future<void> _openFilterDialog() async {
    final result = await DiscoverFilterDialog.show(
      context: context,
      initial: _filterState,
    );
    if (result != null && mounted) {
      setState(() => _filterState = result);
      _performFilter();
    }
  }

  /// 打开全部标签弹出菜单（Overlay 方式，类似库页右键菜单）
  Future<void> _openAllTagsDialog() async {
    final allTags = _allAvailableTags.toList()..sort();
    final result = await TagsPopupMenu.show(
      context: context,
      anchorKey: _allTagsButtonKey,
      allTags: allTags,
      selectedTags: Set.from(_selectedTags),
    );
    if (result != null && mounted) {
      setState(() => _selectedTags = result);
      _performFilter();
    }
  }

  Set<String> get _allAvailableTags {
    final tags = <String>{};
    for (final game in _allGames) {
      tags.addAll(game.tags);
    }
    return tags;
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
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        children: [
          // 阶段4.4：紧凑工具栏第一行——搜索框 + 筛选按钮
          Row(
            children: [
              Expanded(child: _buildSearchBar()),
              const SizedBox(width: 10),
              _buildFilterButton(),
            ],
          ),
          if (_allAvailableTags.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildTagBar(),
          ],
          const SizedBox(height: 16),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // ★ 离线模式：显示离线视图（有缓存则 banner+网格，无缓存则提示）
    if (!NetworkStatusService.instance.isOnline) {
      return _buildOfflineView();
    }
    if (_isLoading && !_hasLoadedOnce) {
      return _buildLoadingGrid();
    }

    if (_errorMessage != null && _allGames.isEmpty) {
      return _buildErrorView();
    }

    if (!_isLoading && _displayGames.isEmpty && _hasLoadedOnce) {
      return _buildEmptyView();
    }

    return _buildGameGrid();
  }

  Widget _buildSearchBar() {
    final hasText = _searchController.text.trim().isNotEmpty;

    return Container(
      // 阶段4.4：压缩搜索框高度（48→40），节省工具栏纵向空间
      height: 40,
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  size: 18, color: AppColors.secondaryText.withOpacity(0.5)),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: AppStyles.bodyRegular
                  .copyWith(fontSize: 15, color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: '搜 索 游 戏...',
                hintStyle: AppStyles.bodyRegular.copyWith(
                  color: AppColors.primaryText.withOpacity(0.45),
                  fontSize: 15,
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
                      size: 18,
                      color: AppColors.secondaryText.withOpacity(0.5)),
                ),
              ),
            )
          else
            SvgPicture.asset(
              'assets/images/search_icon.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                AppColors.secondaryText.withOpacity(0.6),
                BlendMode.srcIn,
              ),
            ),
        ],
      ),
    );
  }

  /// 阶段4.4：高级筛选按钮（带激活徽标）
  /// 点击打开 DiscoverFilterDialog，有激活筛选时显示蓝色圆点
  Widget _buildFilterButton() {
    final hasFilter = _filterState.hasActiveFilters;
    return GestureDetector(
      onTap: _openFilterDialog,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 40,
          width: 40,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: hasFilter ? AppColors.selectedAccent : AppColors.border,
              width: hasFilter ? 2 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.tune_rounded,
                size: 20,
                color:
                    hasFilter ? AppColors.primaryText : AppColors.secondaryText,
              ),
              if (hasFilter)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.selectedAccent,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: AppColors.background, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签栏——「全部标签」固定按钮 + 横向滚动标签
  /// 布局：[全部标签↓] | [tag1] [tag2] ... ←横滑→
  /// 「全部标签」按钮固定在左侧，不随标签滚动；点击弹出标签菜单
  /// 桌面端鼠标滚轮通过 Listener 转换为横向滚动（标签栏是游戏网格的兄弟节点，非祖先，安全）
  Widget _buildTagBar() {
    final tags = _allAvailableTags.toList()..sort();
    if (tags.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 32,
      child: Row(
        children: [
          // 固定「全部标签」按钮——不随右侧标签滚动
          _buildAllTagsButton(),
          const SizedBox(width: 8),
          // 可横滑的标签列表
          Expanded(
            child: Listener(
              // 桌面端：将垂直滚轮转换为水平滚动
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent &&
                    _tagScrollController.hasClients) {
                  final pos = _tagScrollController.position;
                  final target = (pos.pixels + signal.scrollDelta.dy)
                      .clamp(0.0, pos.maxScrollExtent);
                  _tagScrollController.jumpTo(target);
                }
              },
              child: ListView.separated(
                controller: _tagScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: tags.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final tag = tags[index];
                  final isSelected = _selectedTags.contains(tag);
                  return _buildTagChip(tag, isSelected);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部标签」入口按钮——固定在标签栏左侧，点击弹出标签菜单
  Widget _buildAllTagsButton() {
    return GestureDetector(
      key: _allTagsButtonKey,
      onTap: _openAllTagsDialog,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            border: Border.all(
              color: AppColors.border,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.label_outline_rounded,
                size: 13,
                color: AppColors.secondaryText.withOpacity(0.7),
              ),
              const SizedBox(width: 3),
              Text(
                '全部标签',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                  height: 16 / 12,
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
        ),
      ),
    );
  }

  Widget _buildTagChip(String tag, bool isSelected) {
    // UX-35: 改用独立 StatefulWidget 承载点击弹性缩放动画
    return _TagChip(
      tag: tag,
      isSelected: isSelected,
      onTap: () => _toggleTag(tag),
    );
  }

  Widget _buildLoadingGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
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
                    border: Border.all(color: AppColors.border, width: 2),
                    boxShadow: [
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
              fontFamily: 'Inter',
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

  Widget _buildGameGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          key: const PageStorageKey<String>('discover_game_grid'),
          controller: _scrollController,
          cacheExtent: 4000, // 性能优化: 增大预渲染区域，减少快速滑动时的白屏
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
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

  const _DiscoverCardWidget({
    super.key,
    required this.game,
    required this.onTap,
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
    _isInstalled =
        LocalGameRegistry.instance.isTitleInstalled(widget.game.title);
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
    final newInstalled =
        LocalGameRegistry.instance.isTitleInstalled(widget.game.title);
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

    return CachedNetworkImage(
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
          fontFamily: 'Inter',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
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
              fontFamily: 'Inter',
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
          width: isInstalled ? 2.5 : 2,
        ),
        boxShadow: [_hovered ? _hoverShadow : _normalShadow],
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
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
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
            if (t == 0) return child!;
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
            padding: const EdgeInsets.all(8),
            clipBehavior: Clip.none,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cardContent),
                const SizedBox(height: 8),
                SizedBox(
                  height: 28,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: AutoSizeText(
                      widget.game.title.isNotEmpty
                          ? widget.game.title
                          : '未命名游戏',
                      style: AppStyles.gameTitle.copyWith(fontSize: 24),
                      maxLines: 1,
                      minFontSize: 11,
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

/// UX-35: 标签芯片——点击时播放弹性缩放动画（1.0 → 0.92 → 1.05 → 1.0）
class _TagChip extends StatefulWidget {
  final String tag;
  final bool isSelected;
  final VoidCallback onTap;

  const _TagChip({
    required this.tag,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<_TagChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    // 弹性缩放序列：按下回弹 → 轻微过冲 → 回归
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.92)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.92, end: 1.05)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.05, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    _controller.forward(from: 0.0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // child 缓存于 AnimatedBuilder，每帧仅重建 Transform，避免重复创建芯片内容
    return GestureDetector(
      onTap: _handleTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedBuilder(
          animation: _scale,
          builder: (context, child) =>
              Transform.scale(scale: _scale.value, child: child),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppColors.infoBlue.withOpacity(0.12)
                  : AppColors.buttonBackground,
              border: Border.all(
                color:
                    widget.isSelected ? AppColors.infoBlue : AppColors.border,
                width: widget.isSelected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Text(
              widget.tag,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight:
                    widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                color: widget.isSelected
                    ? AppColors.infoBlue
                    : AppColors.secondaryText,
                height: 16 / 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
