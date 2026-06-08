import 'dart:async';
import 'package:flutter/material.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
import '../core/backend_config.dart';
import '../services/global_install_center.dart';
import '../services/local_game_registry.dart';
import '../widgets/discover_disclaimer_dialog.dart';

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

enum DiscoverSortOption {
  defaultOrder,
  nameAsc,
  nameDesc,
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

  List<GameModel> _allGames = [];
  List<GameModel> _displayGames = [];
  Set<String> _selectedTags = {};
  bool _isLoading = false;
  bool _isSearching = false;
  bool _hasLoadedOnce = false;
  String? _errorMessage;
  DateTime? _cacheTime;
  bool _isTagPanelExpanded = false;
  DiscoverSortOption _sortOption = DiscoverSortOption.defaultOrder;

  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 300);
  static const Duration _cacheTTL = Duration(minutes: 5);
  static const int _fetchAllPerPage = 100;
  static const int _maxVisibleTags = 15;

  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (!BackendConfig.isBackendAvailable) {
      _searchController.addListener(_onSearchChanged);
      return;
    }
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
    _loadAllGames();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _showDisclaimerIfNeeded());
  }

  void _showDisclaimerIfNeeded() {
    DiscoverDisclaimerDialog.showIfNeeded(
      context: context,
      onAgreed: () {},
    );
  }

  @override
  void dispose() {
    _cachedAllGames = _allGames;
    _cachedSearchText = _searchController.text;
    _cachedSelectedTags = Set.from(_selectedTags);
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      if (mounted) _performFilter();
    });
  }

  bool get _isCacheValid =>
      _cacheTime != null && DateTime.now().difference(_cacheTime!) < _cacheTTL;

  Future<void> _loadAllGames({bool forceRefresh = false}) async {
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
      final allGames = <GameModel>[];
      int page = 1;
      bool hasMore = true;

      while (hasMore) {
        final batch = await GameRepository.getGameList(
            page: page, perPage: _fetchAllPerPage);
        if (batch.isEmpty) {
          hasMore = false;
        } else {
          allGames.addAll(batch);
          hasMore = batch.length >= GameRepository.pageSize;
          page++;
        }
      }

      if (!mounted) return;

      setState(() {
        _allGames = allGames;
        _cacheTime = DateTime.now();
        _hasLoadedOnce = true;
        _isLoading = false;
        _errorMessage = null;
      });

      _performFilter();
    } catch (e) {
      if (!mounted) return;

      final errorMsg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _isLoading = false;
        if (!_hasLoadedOnce) {
          _errorMessage = errorMsg;
        }
      });

      if (_allGames.isNotEmpty) {
        _performFilter();
      }
    }
  }

  void _performFilter() {
    final query = _searchController.text.trim().toLowerCase();

    String nameKeyword = '';
    final List<String> tagKeywords = [];

    if (query.isNotEmpty) {
      final parts =
          query.split(RegExp(r'[,\s，]+')).where((s) => s.isNotEmpty).toList();
      nameKeyword = parts.first;
      if (parts.length > 1) {
        tagKeywords.addAll(parts.skip(1));
      }
    }

    final activeTags = _selectedTags.isNotEmpty ? _selectedTags : <String>{};
    if (tagKeywords.isNotEmpty) {
      activeTags.addAll(tagKeywords.map((t) => t.toLowerCase()));
    }

    List<GameModel> filtered = _allGames;

    if (nameKeyword.isNotEmpty || activeTags.isNotEmpty) {
      filtered = _allGames.where((game) {
        if (nameKeyword.isNotEmpty &&
            !game.title.toLowerCase().contains(nameKeyword)) {
          return false;
        }

        if (activeTags.isNotEmpty) {
          final gameTags = game.tags.map((t) => t.toLowerCase()).toSet();
          if (!activeTags.every((t) => gameTags.any((gt) => gt.contains(t)))) {
            return false;
          }
        }

        return true;
      }).toList();
    } else {
      filtered = List.from(_allGames);
    }

    switch (_sortOption) {
      case DiscoverSortOption.defaultOrder:
        break;
      case DiscoverSortOption.nameAsc:
        filtered.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case DiscoverSortOption.nameDesc:
        filtered.sort(
            (a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()));
        break;
    }

    if (mounted) {
      setState(() {
        _displayGames = filtered;
        _isSearching = false;
      });
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
    });
    _performFilter();
  }

  Set<String> get _allAvailableTags {
    final tags = <String>{};
    for (final game in _allGames) {
      tags.addAll(game.tags);
    }
    return tags;
  }

  bool get _hasActiveFilters =>
      _searchController.text.trim().isNotEmpty || _selectedTags.isNotEmpty;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!BackendConfig.isBackendAvailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 64, color: Colors.grey[400]),
              SizedBox(height: 24),
              Text(
                '在线功能暂不可用',
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryText,
                ),
              ),
              SizedBox(height: 16),
              Text(
                BackendConfig.unavailableMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 14,
                  color: AppColors.secondaryText,
                  height: 1.8,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.pageBackground,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildSearchBar()),
              const SizedBox(width: 12),
              _buildSortButton(),
            ],
          ),
          if (_allAvailableTags.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildTagChips(),
          ],
          const SizedBox(height: 20),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
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
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(
            color: hasText ? AppColors.selectedBlue : AppColors.border,
            width: hasText ? 2 : 1.6),
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

  Widget _buildSortButton() {
    final isActive = _sortOption != DiscoverSortOption.defaultOrder;
    return PopupMenuButton<DiscoverSortOption>(
      offset: const Offset(0, 48),
      initialValue: _sortOption,
      onSelected: (option) {
        setState(() => _sortOption = option);
        _performFilter();
      },
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.border, width: 1.5),
      ),
      color: AppColors.background,
      constraints: const BoxConstraints(minWidth: 160),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: isActive ? AppColors.selectedBlue : AppColors.border,
              width: isActive ? 2 : 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          child: Icon(
            Icons.sort_rounded,
            size: 22,
            color: isActive ? AppColors.primaryText : AppColors.secondaryText,
          ),
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem<DiscoverSortOption>(
          value: DiscoverSortOption.defaultOrder,
          height: 40,
          child: Row(
            children: [
              if (_sortOption == DiscoverSortOption.defaultOrder)
                Icon(Icons.check, size: 16, color: AppColors.primaryText)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(
                '默认排序',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: _sortOption == DiscoverSortOption.defaultOrder
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<DiscoverSortOption>(
          value: DiscoverSortOption.nameAsc,
          height: 40,
          child: Row(
            children: [
              if (_sortOption == DiscoverSortOption.nameAsc)
                Icon(Icons.check, size: 16, color: AppColors.primaryText)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(
                '名称 A-Z',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: _sortOption == DiscoverSortOption.nameAsc
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<DiscoverSortOption>(
          value: DiscoverSortOption.nameDesc,
          height: 40,
          child: Row(
            children: [
              if (_sortOption == DiscoverSortOption.nameDesc)
                Icon(Icons.check, size: 16, color: AppColors.primaryText)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(
                '名称 Z-A',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: _sortOption == DiscoverSortOption.nameDesc
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTagChips() {
    final tags = _allAvailableTags.toList()..sort();
    if (tags.isEmpty) return const SizedBox.shrink();

    final visibleTags = tags.length <= _maxVisibleTags
        ? tags
        : tags.sublist(0, _maxVisibleTags);
    final hasMore = tags.length > _maxVisibleTags;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: visibleTags.length + (_hasActiveFilters ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (_hasActiveFilters && index == 0) {
                      return _buildClearChip();
                    }
                    final tag = _hasActiveFilters
                        ? visibleTags[index - 1]
                        : visibleTags[index];
                    final isSelected = _selectedTags.contains(tag);
                    return _buildTagChip(tag, isSelected);
                  },
                ),
              ),
              if (hasMore) _buildMoreButton(),
            ],
          ),
        ),
        if (_isTagPanelExpanded && hasMore)
          _buildExpandedPanel(tags.sublist(_maxVisibleTags)),
      ],
    );
  }

  Widget _buildMoreButton() {
    final isExpanded = _isTagPanelExpanded;
    return GestureDetector(
      onTap: () {
        setState(() => _isTagPanelExpanded = !_isTagPanelExpanded);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isExpanded
                ? const Color(0xFF4A72A5).withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isExpanded ? const Color(0xFF4A72A5) : AppColors.border,
              width: isExpanded ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.more_horiz,
                size: 14,
                color: isExpanded
                    ? const Color(0xFF4A72A5)
                    : AppColors.secondaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedPanel(List<String> hiddenTags) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border.withOpacity(0.3), width: 0.5),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        alignment: WrapAlignment.start,
        children: hiddenTags.map((tag) {
          final isSelected = _selectedTags.contains(tag);
          return _buildTagChip(tag, isSelected);
        }).toList(),
      ),
    );
  }

  Widget _buildTagChip(String tag, bool isSelected) {
    return GestureDetector(
      onTap: () => _toggleTag(tag),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF4A72A5).withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? const Color(0xFF4A72A5) : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected
                  ? const Color(0xFF4A72A5)
                  : AppColors.secondaryText,
              height: 16 / 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClearChip() {
    return GestureDetector(
      onTap: _clearFilters,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(
                color: AppColors.dangerRed.withOpacity(0.5), width: 1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close_rounded,
                  size: 13, color: AppColors.dangerRed.withOpacity(0.7)),
              const SizedBox(width: 4),
              Text(
                '清除',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.dangerRed.withOpacity(0.7),
                  height: 16 / 12,
                ),
              ),
            ],
          ),
        ),
      ),
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
            childAspectRatio: 0.60,
          ),
          itemCount: 8,
          itemBuilder: (context, index) => ShimmerPlaceholder(),
        );
      },
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
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w700),
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
                          .copyWith(fontSize: 14, fontWeight: FontWeight.w700),
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
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
            childAspectRatio: 0.60,
          ),
          itemCount: _displayGames.length,
          itemBuilder: (context, index) => Semantics(
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
  }

  Widget _buildGameCard(GameCardData game) {
    final isInstalled = LocalGameRegistry.instance.isTitleInstalled(game.title);

    return GestureDetector(
      onTap: () => widget.onGameTap?.call(game),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isInstalled
                          ? const Color(0xFF4A7C59)
                          : AppColors.border,
                      width: isInstalled ? 2.5 : 1.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isInstalled
                            ? const Color(0xFF4A7C59).withOpacity(0.25)
                            : AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildCoverImage(game.coverPath),
                      Container(color: Colors.white.withOpacity(0.33)),
                      if (isInstalled)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4A7C59),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              '已安装',
                              style: TextStyle(
                                fontFamily: 'Mali',
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 28,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: AutoSizeText(
                    game.title.isNotEmpty ? game.title : '未命名游戏',
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
    );
  }

  Widget _buildCoverImage(String coverUrl) {
    if (coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return Container(
        color: const Color(0xFFE9E0D1),
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
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Image.network(
      coverUrl,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      cacheWidth: 400,
      cacheHeight: 600,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.border.withOpacity(0.5)),
            value: loadingProgress.expectedTotalBytes != null
                ? loadingProgress.cumulativeBytesLoaded /
                    loadingProgress.expectedTotalBytes!
                : null,
          ),
        );
      },
      errorBuilder: (_, error, stackTrace) {
        return Container(
          color: const Color(0xFFE9E0D1),
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
                    fontSize: 11,
                    color: AppColors.dangerRed.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
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

  static const BoxShadow _normalShadow = BoxShadow(
    color: Color(0x0D8B7355),
    offset: Offset(2, 3),
    blurRadius: 5,
  );

  static const BoxShadow _hoverShadow = BoxShadow(
    color: Color(0x338B7355),
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
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    _hoverController.dispose();
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    if (mounted) setState(() {});
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
      return Container(
        color: const Color(0xFFE9E0D1),
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
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Image.network(
      coverUrl,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      cacheWidth: 400,
      cacheHeight: 600,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.border.withOpacity(0.5)),
            value: loadingProgress.expectedTotalBytes != null
                ? loadingProgress.cumulativeBytesLoaded /
                    loadingProgress.expectedTotalBytes!
                : null,
          ),
        );
      },
      errorBuilder: (_, error, stackTrace) {
        return Container(
          color: const Color(0xFFE9E0D1),
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
                    fontSize: 11,
                    color: AppColors.dangerRed.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInstalled =
        LocalGameRegistry.instance.isTitleInstalled(widget.game.title);

    final cardContent = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: isInstalled ? const Color(0xFF4A7C59) : AppColors.border,
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
          Container(color: Colors.white.withOpacity(0.33)),
          if (isInstalled)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A7C59),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '已安装',
                  style: TextStyle(
                    fontFamily: 'Mali',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
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
    )..repeat(reverse: true);
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
                  color: Color.lerp(const Color(0xFFE9E0D1),
                      const Color(0xFFF5EDE6), _controller.value)!,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 18,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Color.lerp(const Color(0xFFE9E0D1),
                    const Color(0xFFF5EDE6), _controller.value)!,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        );
      },
    );
  }
}
