import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../widgets/game_detail_dialog.dart';
import '../widgets/play_stats_panel.dart';

class HomePage extends StatefulWidget {
  final ValueChanged<String>? onLaunchGame;
  final VoidCallback? onGoToLibrary;
  final ValueChanged<String>? onToggleMark;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onToggleBigPicture;

  const HomePage({
    super.key,
    this.onLaunchGame,
    this.onGoToLibrary,
    this.onToggleMark,
    this.onDelete,
    this.onToggleBigPicture,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<LibraryGame> _allGames = [];
  List<LibraryGame> _recentGames = [];
  int _selectedIndex = 0;
  PlayStatus? _activeFilter;
  final Map<String, String> _localeModes = {};
  final Map<String, String> _upscalingModes = {};
  // UX-18: 磁盘扫描期间显示加载指示器，避免空白
  bool _isScanning = false;

  // 封面路径缓存，避免每次 build 同步 I/O
  final Map<String, String?> _coverPathCache = {};

  // 平滑滚动控制器
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _refreshFromDisk();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    // UX-34: 区分通知类型——结构性变化需重新加载,游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      _coverPathCache.clear();
      if (mounted) _loadGames();
    } else {
      // playTimeUpdate:游戏对象引用已被原地修改,仅 setState 让 UI 反映新值
      // 避免每 30s 清空封面缓存并触发同步 I/O 扫描磁盘
      if (mounted) setState(() {});
    }
  }

  /// 从磁盘重新扫描并加载数据，确保注册表是最新的
  Future<void> _refreshFromDisk() async {
    // UX-18: 首次扫描（库为空）时显示加载指示器，避免空白等待
    final wasEmpty = _allGames.isEmpty;
    if (wasEmpty) setState(() => _isScanning = true);
    try {
      await LocalGameRegistry.instance.scan();
      _loadGames();
    } finally {
      if (wasEmpty && mounted) setState(() => _isScanning = false);
    }
  }

  void _loadGames() {
    final games = LocalGameRegistry.instance.allGames;
    final recentGames = List<LibraryGame>.from(games);
    recentGames.sort((a, b) {
      final aHas = a.lastOpenedAt.isNotEmpty;
      final bHas = b.lastOpenedAt.isNotEmpty;
      if (aHas && bHas) return b.lastOpenedAt.compareTo(a.lastOpenedAt);
      if (aHas) return -1;
      if (bHas) return 1;
      return b.installedAt.compareTo(a.installedAt);
    });

    setState(() {
      _allGames = games;
      _recentGames = recentGames;
      // UX-14: 选中索引基于筛选列表，加载后重新校验
      _ensureSelectionInFilter();
    });
    _resolveCoverPaths();
    _loadLaunchModes();
  }

  /// UX-34: 异步一次性解析所有封面路径，缓存结果，避免阻塞主线程
  Future<void> _resolveCoverPaths() async {
    for (final game in _allGames) {
      if (_coverPathCache.containsKey(game.title)) continue;
      String? resolved;
      if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
        resolved = game.coverUrl;
      } else {
        try {
          resolved = GameDataFormat.findCoverFile(game.pathForCover)?.path;
        } catch (_) {}
      }
      _coverPathCache[game.title] = resolved;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadLaunchModes() async {
    for (final game in _allGames) {
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
      } catch (_) {}
    }
    // UX-23: 异步加载完成后触发 UI 重建，使 locale/upscaling 模式即时显示
    if (mounted) setState(() {});
  }

  List<LibraryGame> get _filteredGames {
    var result = List<LibraryGame>.from(_recentGames);
    if (_activeFilter != null) {
      result = result.where((g) => g.playStatus == _activeFilter).toList();
    }
    return result;
  }

  // UX-14: 选中索引基于筛选后的列表，确保选中游戏始终在可见列表中
  LibraryGame? get _selectedGame {
    final filtered = _filteredGames;
    return filtered.isNotEmpty && _selectedIndex < filtered.length
        ? filtered[_selectedIndex]
        : null;
  }

  int get _totalPlayTime => _allGames.fold(0, (sum, g) => sum + g.playTime);

  void _selectGame(int index) {
    final filtered = _filteredGames;
    if (index < 0 || index >= filtered.length) return;
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  void _selectGameFromList(LibraryGame game) {
    final idx = _filteredGames.indexOf(game);
    if (idx >= 0 && idx != _selectedIndex) {
      _selectGame(idx);
    }
  }

  void _navigateLeft() {
    if (_selectedIndex > 0) {
      _selectGame(_selectedIndex - 1);
    }
  }

  void _navigateRight() {
    if (_selectedIndex < _filteredGames.length - 1) {
      _selectGame(_selectedIndex + 1);
    }
  }

  /// UX-14: 切换筛选条件后，确保选中索引在筛选列表有效范围内
  void _ensureSelectionInFilter() {
    final filtered = _filteredGames;
    if (_selectedIndex >= filtered.length) {
      _selectedIndex = filtered.isNotEmpty ? 0 : 0;
    }
  }

  void _handleLaunch() {
    final game = _selectedGame;
    if (game == null) return;
    // ★ H11: UI 层双重启动保护
    // 注意：onLaunchGame 是 void 回调（非 Future），无法 await，
    // 真正的并发保护由 GameLaunchService._isLaunching 兜底。
    // 这里通过 MainContainer._onLaunchGame 内部的 scan + resolveUserChoice
    // 异步链路实现启动，重复点击会被 GameLaunchService 拦截并返回失败 SnackBar。
    // 为避免误导，不在此处设置无效的 UI 标志（会因同步返回而立即释放）。
    widget.onLaunchGame?.call(game.title);
  }

  void _handleDetails() {
    final game = _selectedGame;
    if (game == null) return;
    GameDetailDialog.show(
      context: context,
      directoryPath: game.pathForCover,
      onLaunchGame: _handleLaunch,
      initialLocaleMode: _localeModes[game.title] ?? 'none',
      initialUpscalingMode: _upscalingModes[game.title] ?? 'none',
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
      },
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.pageBackground,
      // UX-18: 扫描期间显示加载状态，避免空白
      child: _isScanning && _allGames.isEmpty
          ? _buildLoadingState()
          : _allGames.isEmpty
              ? _buildEmptyState()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildDetailPanel(),
                    ),
                    SizedBox(
                      width: 320,
                      child: _buildGameListPanel(),
                    ),
                  ],
                ),
    );
  }

  // ==================== 空状态 ====================
  Widget _buildLoadingState() {
    // UX-18: 磁盘扫描期间显示加载指示器
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
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videogame_asset_rounded,
            size: 64,
            color: AppColors.border.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '库中没有游戏哦',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 20,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '快去添加或探索游戏吧！',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 左侧详情面板 ====================
  Widget _buildDetailPanel() {
    final game = _selectedGame;
    if (game == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Stack(
        children: [
          // #6: 切换动画 - 用 AnimatedSwitcher 包裹背景+内容
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: child,
              );
            },
            child: _buildDetailContent(game),
          ),
          // 左右切换按钮（不参与动画，始终在最上层）
          // UX-14: 切换按钮可见性基于筛选列表
          if (_filteredGames.length > 1) ...[
            if (_selectedIndex > 0)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _buildNavArrow(isLeft: true),
              ),
            if (_selectedIndex < _filteredGames.length - 1)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _buildNavArrow(isLeft: false),
              ),
          ],
        ],
      ),
    );
  }

  /// 构建左侧详情内容（背景 + 主内容），带 key 供 AnimatedSwitcher 识别切换
  Widget _buildDetailContent(LibraryGame game) {
    return Stack(
      key: ValueKey(game.title),
      children: [
        // #7: 模糊背景 - 改用 BackdropFilter 毛玻璃效果
        Positioned.fill(
          child: _buildBlurredBackground(game),
        ),
        // 主内容
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标签行
            _buildTagRow(game),
            const SizedBox(height: 12),
            // 游戏标题
            _buildGameTitle(game),
            // #4: 开发商信息
            if (game.developer.isNotEmpty) ...[
              const SizedBox(height: 4),
              _buildDeveloper(game),
            ],
            const SizedBox(height: 8),
            // 游戏简介
            _buildGameDescription(game),
            const Spacer(),
            // 底部区域：封面 + 信息 + 按钮
            _buildBottomSection(game),
            // 页面指示器（放在按钮下方，不再重叠）
            // UX-14: 指示器可见性基于筛选列表
            if (_filteredGames.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: _buildPageIndicator(),
              ),
          ],
        ),
        // 游玩状态标签 - 右上角轻量化显示
        Positioned(
          top: 4,
          right: 4,
          child: _buildPlayStatusBadge(game),
        ),
        // 游玩统计面板 - 右下角，与启动按钮保持间距
        Positioned(
          right: 4,
          bottom: 8,
          child: PlayStatsPanel(currentGame: game),
        ),
      ],
    );
  }

  // #7: BackdropFilter 毛玻璃背景
  Widget _buildBlurredBackground(LibraryGame game) {
    final isDark = AppColors.isDark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 放大的封面图（最底层）
          _buildCoverImage(game, fit: BoxFit.cover),
          // BackdropFilter: 模糊下层的封面图，并叠加半透明背景色
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
            child: Container(
              color: AppColors.background.withOpacity(isDark ? 0.55 : 0.18),
            ),
          ),
          // 底部渐变，增强深度感
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppColors.background.withOpacity(isDark ? 0.35 : 0.25),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// UX-34: 使用缓存的封面路径构建图片，路径已在加载时验证，不再 build 中做同步 I/O
  Widget _buildCoverImage(LibraryGame game, {BoxFit fit = BoxFit.cover}) {
    final cachedPath = _coverPathCache[game.title];
    if (cachedPath != null && cachedPath.isNotEmpty) {
      return Image.file(
        File(cachedPath),
        width: double.infinity,
        height: double.infinity,
        fit: fit,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
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
          size: 48,
          color: AppColors.border.withOpacity(0.3),
        ),
      ),
    );
  }

  Widget _buildTagRow(LibraryGame game) {
    if (game.tags.isEmpty) return const SizedBox.shrink();
    final isDark = AppColors.isDark;
    // 限制标签数量，最多显示 5 个
    final displayTags =
        game.tags.length > 5 ? game.tags.sublist(0, 5) : game.tags;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: displayTags.map((tag) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
              color: isDark ? AppColors.border : AppColors.borderLight,
            ),
            color: isDark
                ? AppColors.buttonBackground.withOpacity(0.9)
                : AppColors.background.withOpacity(0.85),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: isDark ? AppColors.primaryText : AppColors.border,
              height: 15 / 10,
            ),
          ),
        );
      }).toList(),
    );
  }

  /// 右上角游玩状态轻量化标签
  Widget _buildPlayStatusBadge(LibraryGame game) {
    final isDark = AppColors.isDark;
    final status = game.playStatus;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (isDark ? AppColors.buttonBackground : AppColors.background)
            .withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: status.color.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 12, color: status.color),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: status.color,
              letterSpacing: 0.5,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameTitle(LibraryGame game) {
    return Text(
      game.title.isNotEmpty ? game.title : '未命名游戏',
      style: TextStyle(
        fontFamily: AppStyles.zhFontFamily,
        fontSize: 38,
        fontWeight: FontWeight.w400,
        height: 38 / 38,
        letterSpacing: 2,
        color: AppColors.primaryText,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  // #4: 开发商信息
  Widget _buildDeveloper(LibraryGame game) {
    return Text(
      game.developer,
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: Colors.teal.withOpacity(0.8),
        height: 16 / 11,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildGameDescription(LibraryGame game) {
    if (game.description.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 39,
      child: Text(
        game.description,
        style: TextStyle(
          fontFamily: AppStyles.enFontFamily,
          fontSize: 12,
          height: 20 / 12,
          letterSpacing: 0,
          color: AppColors.secondaryText,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildBottomSection(LibraryGame game) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // #8: 封面卡片放大 - 从 161 放大到 180
            _buildCoverCard(game),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatChips(game),
                  const SizedBox(height: 16),
                  _buildActionButtons(game),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // #8: 封面卡片放大并优化比例
  Widget _buildCoverCard(LibraryGame game) {
    return Container(
      width: 180,
      height: 180 * 4 / 3, // 240px，4:3 比例
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border, width: 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.15),
            offset: const Offset(2, 3),
            blurRadius: 6,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: game.isBlurred
            ? ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: _buildCoverImage(game),
              )
            : _buildCoverImage(game),
      ),
    );
  }

  Widget _buildStatChips(LibraryGame game) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildStatChip(
          icon: Icons.schedule_outlined,
          value: _formatPlayTime(game.playTime),
          label: '游玩时长',
        ),
        _buildStatChip(
          icon: Icons.access_time,
          value: _formatLastPlayed(game.lastOpenedAt),
          label: '上次游玩',
        ),
      ],
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String value,
    required String label,
  }) {
    final isDark = AppColors.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 2),
        borderRadius: BorderRadius.circular(4),
        color: isDark
            ? AppColors.buttonBackground.withOpacity(0.95)
            : AppColors.background.withOpacity(0.9),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.15),
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 13,
                  color: isDark ? AppColors.primaryText : AppColors.border),
              const SizedBox(width: 6),
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.38,
                  color: AppColors.primaryText,
                  height: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: isDark
                  ? AppColors.secondaryText
                  : AppColors.border.withOpacity(0.7),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(LibraryGame game) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HoverButton(
          onTap: _handleLaunch,
          borderColor: const Color(0xFF5A8FD4),
          shadowColor: const Color(0xFF1A3560),
          backgroundColor: const Color(0xFFB4D4FF),
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 8),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow, size: 14, color: Color(0xFF1A3560)),
              SizedBox(width: 10),
              Text(
                '立即启动',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: Color(0xFF1A3560),
                  height: 24 / 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _HoverButton(
          onTap: _handleDetails,
          borderColor: AppColors.border,
          shadowColor: AppColors.titleBrown,
          backgroundColor: AppColors.buttonBackground,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '详情',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppColors.titleBrown,
                  height: 24 / 16,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: AppColors.titleBrown),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNavArrow({required bool isLeft}) {
    final isDark = AppColors.isDark;
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: isLeft ? _navigateLeft : _navigateRight,
          child: Container(
            width: 36,
            height: 60,
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(isDark ? 0.75 : 0.6),
              borderRadius: BorderRadius.horizontal(
                left: isLeft ? Radius.zero : const Radius.circular(8),
                right: isLeft ? const Radius.circular(8) : Radius.zero,
              ),
              border: Border.all(
                color: AppColors.border.withOpacity(isDark ? 0.6 : 0.3),
                width: 1,
              ),
            ),
            child: Icon(
              isLeft ? Icons.chevron_left : Icons.chevron_right,
              size: 24,
              color: AppColors.primaryText.withOpacity(0.7),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      // UX-14: 指示器点数与筛选列表一致
      children: List.generate(_filteredGames.length, (index) {
        final isActive = index == _selectedIndex;
        return GestureDetector(
          onTap: () => _selectGame(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: isActive ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.selectedAccent
                  : AppColors.secondaryText.withOpacity(0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }

  // ==================== 右侧游戏列表面板 ====================
  Widget _buildGameListPanel() {
    final isDark = AppColors.isDark;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 16, 20, 16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 2),
        borderRadius: BorderRadius.circular(12),
        color: isDark
            ? AppColors.sidebarBackground.withOpacity(0.92)
            : AppColors.background.withOpacity(0.85),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.15),
            offset: const Offset(4, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildListHeader(),
          Expanded(
            child: _buildGameListView(),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    final isDark = AppColors.isDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.videogame_asset_rounded,
                  size: 16,
                  color: isDark ? AppColors.primaryText : AppColors.border),
              const SizedBox(width: 6),
              Text(
                '游戏库',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: isDark ? AppColors.border : AppColors.borderLight),
                  color: isDark
                      ? AppColors.buttonBackground
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${_allGames.length} 款',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.primaryText : AppColors.border,
                    height: 15 / 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: isDark ? AppColors.border : AppColors.borderLight),
                  color: isDark
                      ? AppColors.buttonBackground
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _formatPlayTime(_totalPlayTime),
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.primaryText : AppColors.border,
                    height: 15 / 10,
                  ),
                ),
              ),
              const Spacer(),
              // 大屏模式入口按钮
              if (widget.onToggleBigPicture != null)
                _buildBigPictureButton(isDark),
            ],
          ),
          const SizedBox(height: 12),
          _buildFilterChips(),
        ],
      ),
    );
  }

  /// 大屏模式 (BPM) 入口按钮 - 纯图标小按钮 (v1.2)
  ///
  /// 放在列表头部 Spacer 之后的空白处,纯图标无文字,
  /// 与 header 其他小徽章视觉重量一致,最小化对原 UI 的影响。
  Widget _buildBigPictureButton(bool isDark) {
    return Tooltip(
      message: '大屏模式 (F11)',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onToggleBigPicture?.call(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: isDark ? AppColors.border : AppColors.borderLight,
              ),
              color: isDark ? AppColors.buttonBackground : AppColors.background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.fullscreen_rounded,
              size: 14,
              color: isDark ? AppColors.primaryText : AppColors.border,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final filters = [
      (null, '全部'),
      (PlayStatus.inProgress, '游玩中'),
      (PlayStatus.completed, '已通关'),
      (PlayStatus.notStarted, '未入坑'),
      (PlayStatus.dropped, '已弃坑'),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((item) {
          final (status, label) = item;
          final isActive = _activeFilter == status;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _HoverChip(
              label: label,
              isActive: isActive,
              onTap: () {
                setState(() {
                  _activeFilter = isActive ? null : status;
                  // UX-14: 切换筛选时确保选中游戏在新筛选列表内
                  _ensureSelectionInFilter();
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGameListView() {
    final filtered = _filteredGames;
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没有符合条件的游戏',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            color: AppColors.secondaryText,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      cacheExtent: 2000, // 性能优化: 增大预渲染区域，减少快速滑动时的白屏
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final game = filtered[index];
        final isSelected = _selectedGame == game;
        // UX-34: RepaintBoundary 隔离每行的重绘
        return RepaintBoundary(
          child: _HomeGameRow(
            key: ValueKey(game.title),
            game: game,
            isSelected: isSelected,
            coverPath: _coverPathCache[game.title],
            onTap: () => _selectGameFromList(game),
            onDoubleTap: () => widget.onLaunchGame?.call(game.title),
          ),
        );
      },
    );
  }

  // ==================== 工具方法 ====================
  static String _formatPlayTime(int seconds) {
    if (seconds <= 0) return '0m';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h';
    return '${minutes}m';
  }

  static String _formatLastPlayed(String lastOpenedAt) {
    if (lastOpenedAt.isEmpty) return '从未游玩';
    try {
      final dt = DateTime.parse(lastOpenedAt);
      final diff = DateTime.now().difference(dt);
      // UX-22: 修复判断顺序——先检查分钟/小时粒度，再检查天，
      // 否则 inDays==0 会先命中，导致当天内的"刚刚"/"X分钟前"永远不显示。
      if (diff.inMinutes < 1) return '刚刚';
      if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
      if (diff.inDays == 0) return '今天';
      if (diff.inDays == 1) return '昨天';
      if (diff.inDays < 7) return '${diff.inDays}天前';
      if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}周前';
      if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
      return '${(diff.inDays / 365).floor()}年前';
    } catch (_) {
      return '从未游玩';
    }
  }
}

// ==================== 右侧游戏行组件 ====================
class _HomeGameRow extends StatelessWidget {
  final LibraryGame game;
  final bool isSelected;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _HomeGameRow({
    super.key,
    required this.game,
    required this.isSelected,
    this.coverPath,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    return _HomeGameRowInner(
      game: game,
      isSelected: isSelected,
      coverPath: coverPath,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
    );
  }
}

/// 内部实现，管理 hover 状态
class _HomeGameRowInner extends StatefulWidget {
  final LibraryGame game;
  final bool isSelected;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _HomeGameRowInner({
    required this.game,
    required this.isSelected,
    this.coverPath,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  State<_HomeGameRowInner> createState() => _HomeGameRowInnerState();
}

class _HomeGameRowInnerState extends State<_HomeGameRowInner> {
  bool _hovered = false;

  // #11: 选中状态变化时自动滚动到可见位置
  @override
  void didUpdateWidget(_HomeGameRowInner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当从"未选中"变为"选中"时，滚动到可见位置
    if (widget.isSelected && !oldWidget.isSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5, // 尽量居中显示
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final Color bgColor;
    if (isSelected) {
      bgColor = AppColors.selectedAccent.withOpacity(0.12);
    } else if (_hovered) {
      bgColor = AppColors.cardHoverBg;
    } else {
      bgColor = Colors.transparent;
    }

    // 边框始终存在，避免 null ↔ Border.all 切换导致的闪烁
    final Color borderColor;
    final double borderWidth;
    if (isSelected) {
      borderColor = AppColors.selectedAccent;
      borderWidth = 1.5;
    } else if (_hovered) {
      borderColor = AppColors.borderLight;
      borderWidth = 1;
    } else {
      // 未选中且未 hover 时，使用透明边框占位（保持布局不变）
      borderColor = Colors.transparent;
      borderWidth = 1;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Row(
            children: [
              // 缩略图 - 固定尺寸，不做动画避免布局抖动
              Container(
                width: 40,
                height: 55,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.borderLight, width: 1),
                  color: AppColors.placeholderCover,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: _buildCoverThumb(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _buildStatusDot(widget.game.playStatus),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.game.title.isNotEmpty
                                ? widget.game.title
                                : '未命名游戏',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryText,
                              height: 1.3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          widget.game.playStatus.label,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: widget.game.playStatus.color,
                            height: 1.2,
                          ),
                        ),
                        if (widget.game.playTime > 0) ...[
                          Text(
                            ' · ',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.secondaryText.withOpacity(0.5),
                            ),
                          ),
                          Icon(Icons.schedule,
                              size: 11,
                              color: AppColors.secondaryText.withOpacity(0.6)),
                          const SizedBox(width: 3),
                          Text(
                            _formatPlayTimeShort(widget.game.playTime),
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              color: AppColors.secondaryText,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                _formatRelativeTime(widget.game.lastOpenedAt),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// UX-34: 使用缓存路径，路径已在加载时验证，不再每次 build 做同步 I/O
  /// 性能优化: 添加 cacheWidth/cacheHeight 避免全分辨率解码
  Widget _buildCoverThumb() {
    final path = widget.coverPath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        cacheWidth: 100, // 缩略图物理像素: ~50px × 2x DPR
        cacheHeight: 140,
        errorBuilder: (_, __, ___) => _buildPlaceholderThumb(),
      );
    }
    return _buildPlaceholderThumb();
  }

  Widget _buildPlaceholderThumb() {
    return Container(
      color: AppColors.placeholderCover,
      child: Icon(
        Icons.videogame_asset_rounded,
        size: 16,
        color: AppColors.border.withOpacity(0.3),
      ),
    );
  }

  Widget _buildStatusDot(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.secondaryText.withOpacity(0.5),
              width: 1.5,
            ),
          ),
        );
      case PlayStatus.inProgress:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 3),
            ],
          ),
        );
      case PlayStatus.dropped:
        return Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.orange,
            shape: BoxShape.circle,
          ),
        );
      case PlayStatus.completed:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppColors.starGold,
            shape: BoxShape.circle,
          ),
        );
    }
  }

  static String _formatPlayTimeShort(int seconds) {
    if (seconds <= 0) return '0m';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h';
    return '${minutes}m';
  }

  // 修复：当天显示"今天"，不再显示"0天前"
  static String _formatRelativeTime(String lastOpenedAt) {
    if (lastOpenedAt.isEmpty) return '从未游玩';
    try {
      final dt = DateTime.parse(lastOpenedAt);
      final diff = DateTime.now().difference(dt);
      // 修复：当天显示"今天"
      if (diff.inDays == 0) return '今天';
      if (diff.inDays == 1) return '昨天';
      if (diff.inDays < 7) return '${diff.inDays}天前';
      if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}周前';
      if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
      return '${(diff.inDays / 365).floor()}年前';
    } catch (_) {
      return '从未游玩';
    }
  }
}

// ==================== 悬浮按钮组件 ====================
class _HoverButton extends StatefulWidget {
  final VoidCallback onTap;
  final Color borderColor;
  final Color shadowColor;
  final Color backgroundColor;
  final EdgeInsets padding;
  final Widget child;

  const _HoverButton({
    required this.onTap,
    required this.borderColor,
    required this.shadowColor,
    required this.backgroundColor,
    required this.padding,
    required this.child,
  });

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final offset = _pressed
        ? Offset.zero
        : _hovered
            ? const Offset(1, 1)
            : const Offset(2, 3);
    final blur = _hovered ? 4.0 : 0.0;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            border: Border.all(color: widget.borderColor, width: 2),
            borderRadius: BorderRadius.circular(6),
            color: widget.backgroundColor,
            boxShadow: [
              BoxShadow(
                color: widget.shadowColor.withOpacity(0.5),
                offset: offset,
                blurRadius: blur,
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// ==================== 筛选标签组件 ====================
class _HoverChip extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _HoverChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_HoverChip> createState() => _HoverChipState();
}

class _HoverChipState extends State<_HoverChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.selectedAccent.withOpacity(0.15)
                : _hovered
                    ? AppColors.cardHoverBg
                    : Colors.transparent,
            border: Border.all(
              color: widget.isActive
                  ? AppColors.selectedAccent
                  : _hovered
                      ? AppColors.border
                      : AppColors.borderLight,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w500,
              color: widget.isActive
                  ? AppColors.selectedAccent
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
