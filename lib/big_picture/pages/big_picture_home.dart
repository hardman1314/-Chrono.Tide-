import 'dart:io';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../big_picture_theme.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 首页 (v1.3 Ubiquity 风格)
///
/// 全屏沉浸式布局,参考 WePlayNight 的 Ubiquity 主题:
/// - Layer 0: 全屏游戏封面 (无模糊,BoxFit.cover)
/// - Layer 1: 顶部到底部的渐变遮罩 (保证文字可读性)
/// - Layer 2: 左中信息层 (标签 + 大标题 + 元数据 + 启动按钮)
/// - Layer 3: 顶部右侧浮动筛选 chips
/// - Layer 4: 底部水平竖版封面轮播 (选中高亮 + 缩放)
///
/// 相比 v1.2 双栏布局的改进:
/// - 去掉 BackdropFilter,避免模糊效果溢出到 NavBar/标题栏
/// - 全屏封面成为视觉主体,而非被遮罩压暗的"背景噪音"
/// - 右侧 480px 文字列表 → 底部水平封面轮播,视觉统一
/// - 标题字号加大,叠加在背景上,冲击力更强
/// - 启动按钮改为半透明胶囊样式,不破坏沉浸感
///
/// 数据源: [LocalGameRegistry.instance] ChangeNotifier, 实时同步库变化。
class BigPictureHome extends StatefulWidget {
  /// 单击游戏卡片回调 (打开详情页)
  final ValueChanged<LibraryGame> onGameTap;

  /// 双击游戏卡片回调 (启动游戏)
  final ValueChanged<LibraryGame> onGameLaunch;

  /// 长按游戏卡片回调 (弹出动作表)
  final ValueChanged<LibraryGame>? onGameLongPress;

  /// "查看全部"按钮回调 (跳转到库页)
  final VoidCallback? onViewAll;

  /// 空状态"前往添加"按钮回调 (跳转到添加页)
  final VoidCallback? onGoToAdd;

  /// 空状态"前往探索"按钮回调 (跳转到探索页)
  final VoidCallback? onGoToDiscover;

  const BigPictureHome({
    super.key,
    required this.onGameTap,
    required this.onGameLaunch,
    this.onGameLongPress,
    this.onViewAll,
    this.onGoToAdd,
    this.onGoToDiscover,
  });

  @override
  State<BigPictureHome> createState() => _BigPictureHomeState();
}

class _BigPictureHomeState extends State<BigPictureHome> {
  List<LibraryGame> _games = [];
  int _currentIndex = 0;
  PlayStatus? _filterStatus;

  /// 首次焦点标志: 仅首次构建时让首项列表 autofocus,避免 setState 重触发
  bool _initialFocusRequested = false;

  @override
  void initState() {
    super.initState();
    _loadGames();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    // UX-34: 区分通知类型——结构性变化需重新加载,游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      if (mounted) _loadGames();
    } else {
      // playTimeUpdate:游戏对象引用已被原地修改,仅 setState 让 UI 反映新值
      if (mounted) setState(() {});
    }
  }

  void _loadGames() {
    _games = LocalGameRegistry.instance.allGames;
    if (_games.isEmpty) {
      _currentIndex = 0;
    } else if (_currentIndex >= _games.length) {
      _currentIndex = 0;
    }
    if (mounted) setState(() {});
  }

  /// 应用筛选后的游戏列表
  List<LibraryGame> get _filteredGames {
    if (_filterStatus == null) return _games;
    return _games.where((g) => g.playStatus == _filterStatus).toList();
  }

  /// 当前详情面板展示的游戏
  LibraryGame? get _currentGame {
    final list = _filteredGames;
    if (list.isEmpty || _currentIndex >= list.length) return null;
    return list[_currentIndex];
  }

  /// 当前游戏的封面路径 (优先 coverUrl, 回退到 GameDataFormat 搜索)
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

  void _selectGame(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    if (_games.isEmpty) {
      return Container(
        color: AppColors.pageBackground,
        child: _buildEmptyState(),
      );
    }

    final game = _currentGame;
    if (game == null) {
      // 筛选下无游戏
      return Container(
        color: AppColors.pageBackground,
        child: _buildEmptyFilterState(),
      );
    }

    final coverPath = _resolveCoverPath(game);

    return Container(
      color: AppColors.pageBackground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 全屏封面背景 (无 BackdropFilter,直接铺满)
          _buildFullscreenBackground(coverPath),
          // 2. 顶部到底部的渐变遮罩 (保证文字可读)
          _buildScrimOverlay(),
          // 3. 顶部右侧浮动筛选 chips
          Positioned(
            top: BigPictureTheme.pagePadding,
            right: BigPictureTheme.pagePadding,
            child: _buildFilterChips(),
          ),
          // 4. 左中信息层 (标题 + 元数据 + 启动按钮)
          Positioned(
            left: BigPictureTheme.pagePadding,
            top: 0,
            bottom: BigPictureTheme.posterCarouselHeight,
            child: _buildHeroInfo(game, coverPath),
          ),
          // 5. 底部水平封面轮播
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: BigPictureTheme.posterCarouselHeight,
            child: _buildPosterCarousel(),
          ),
        ],
      ),
    );
  }

  // ============ Layer 0: 全屏封面背景 ============

  Widget _buildFullscreenBackground(String? coverPath) {
    if (coverPath == null || coverPath.isEmpty) {
      // 无封面时用渐变占位
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.sidebarBackground,
              AppColors.background,
            ],
          ),
        ),
      );
    }
    return Positioned.fill(
      child: Image.file(
        File(coverPath),
        fit: BoxFit.cover,
        alignment: Alignment.center,
        errorBuilder: (_, __, ___) => Container(
          color: AppColors.sidebarBackground,
        ),
      ),
    );
  }

  // ============ Layer 1: 渐变遮罩 ============

  /// 三段式渐变: 顶部轻遮罩 (信息层可读) + 中部最透明 (展示封面) + 底部深遮罩 (轮播可读)
  Widget _buildScrimOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.35, 0.65, 1.0],
              colors: [
                Colors.black.withOpacity(0.55),
                Colors.black.withOpacity(0.15),
                Colors.black.withOpacity(0.45),
                Colors.black.withOpacity(BigPictureTheme.scrimBottomOpacity),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============ Layer 2: 左中信息层 ============

  Widget _buildHeroInfo(LibraryGame game, String? coverPath) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: BigPictureTheme.heroInfoMaxWidth,
      ),
      padding: const EdgeInsets.symmetric(
        vertical: BigPictureTheme.pagePadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标签行
          _buildTagRow(game),
          const SizedBox(height: 20),
          // 游戏标题 (加阴影确保可读)
          _buildHeroTitle(game),
          const SizedBox(height: 12),
          // 元数据行: 开发商 · 状态徽章 · 游玩时长
          _buildMetaRow(game),
          const SizedBox(height: 20),
          // 简介 (限制行数)
          if (game.description.isNotEmpty) _buildHeroDescription(game),
          const SizedBox(height: 28),
          // 操作按钮组
          _buildHeroActions(game),
        ],
      ),
    );
  }

  Widget _buildTagRow(LibraryGame game) {
    if (game.tags.isEmpty) return const SizedBox.shrink();
    final visibleTags = game.tags.take(5).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: visibleTags.map((tag) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.35),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Colors.white.withOpacity(0.25),
              width: 1,
            ),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.labelFontSize,
              color: Colors.white.withOpacity(0.92),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHeroTitle(LibraryGame game) {
    return Text(
      game.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'ZhiMangXing',
        fontSize: BigPictureTheme.displayFontSize + 12, // v1.3: 加大至 48
        height: 1.15,
        color: Colors.white,
        shadows: const [
          Shadow(
            color: Colors.black54,
            offset: Offset(2, 2),
            blurRadius: 8,
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(LibraryGame game) {
    final (statusLabel, statusColor) = _playStatusStyle(game.playStatus);
    final playTimeText = _formatPlayTime(game.playTime);

    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // 状态徽章
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.25),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: statusColor.withOpacity(0.7), width: 1.2),
          ),
          child: Text(
            statusLabel,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.labelFontSize,
              fontWeight: FontWeight.w700,
              color: statusColor,
            ),
          ),
        ),
        if (game.developer.isNotEmpty) _metaText(game.developer),
        if (playTimeText != null) ...[
          _metaDivider(),
          _metaText(playTimeText),
        ],
        if (game.mark != GameMark.none) ...[
          _metaDivider(),
          Icon(
            game.mark == GameMark.favorite
                ? Icons.favorite_rounded
                : Icons.star_rounded,
            size: 16,
            color: game.mark == GameMark.favorite
                ? Colors.redAccent
                : const Color(0xFFFFC107),
          ),
        ],
      ],
    );
  }

  Widget _metaText(String text) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: BigPictureTheme.bodyFontSize,
        color: Colors.white.withOpacity(0.85),
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _metaDivider() {
    return Container(
      width: 4,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.5),
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildHeroDescription(LibraryGame game) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Text(
        game.description,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: BigPictureTheme.bodyFontSize,
          height: 1.6,
          color: Colors.white.withOpacity(0.78),
          shadows: const [
            Shadow(
              color: Colors.black54,
              offset: Offset(1, 1),
              blurRadius: 4,
            ),
          ],
        ),
      ),
    );
  }

  /// 半透明胶囊启动按钮 + 详情按钮 (v1.3 Ubiquity 风格)
  ///
  /// autofocus 策略: 启动按钮不抢焦点,首项轮播卡片 (_PosterCard) 负责 autofocus,
  /// 让用户用方向键浏览游戏 → 选定后按回车启动 (Ubiquity 交互)。
  Widget _buildHeroActions(LibraryGame game) {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        // 启动按钮: 半透明胶囊
        BpmInteractiveWrapper(
          onTap: () => widget.onGameLaunch(game),
          semanticsLabel: '启动 ${game.title}',
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          child: Container(
            height: BigPictureTheme.launchButtonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 32),
            decoration: BoxDecoration(
              color: AppColors.selectedAccent,
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              boxShadow: [
                BoxShadow(
                  color: AppColors.selectedAccent.withOpacity(0.5),
                  offset: const Offset(0, 4),
                  blurRadius: 16,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 32),
                const SizedBox(width: 10),
                Text(
                  '启动游戏',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.subtitleFontSize,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 详情按钮: 玻璃拟态
        BpmInteractiveWrapper(
          onTap: () => widget.onGameTap(game),
          semanticsLabel: '查看详情',
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          child: Container(
            height: BigPictureTheme.launchButtonHeight,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              color:
                  Colors.white.withOpacity(BigPictureTheme.glassButtonOpacity),
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              border: Border.all(
                color: Colors.white.withOpacity(0.4),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: Colors.white.withOpacity(0.95), size: 26),
                const SizedBox(width: 10),
                Text(
                  '查看详情',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ============ Layer 3: 顶部右侧筛选 chips ============

  Widget _buildFilterChips() {
    final filters = [
      (null, '全部'),
      (PlayStatus.inProgress, '游玩中'),
      (PlayStatus.completed, '已通关'),
      (PlayStatus.notStarted, '未入坑'),
      (PlayStatus.dropped, '已弃坑'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withOpacity(0.18),
          width: 1,
        ),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: filters.map((item) {
          final (status, label) = item;
          final active = _filterStatus == status;
          return BpmInteractiveWrapper(
            onTap: () {
              setState(() {
                _filterStatus = status;
                _currentIndex = 0;
                _initialFocusRequested = false;
              });
            },
            semanticsLabel: '筛选: $label',
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? AppColors.selectedAccent.withOpacity(0.85)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: active
                      ? AppColors.selectedAccent
                      : Colors.white.withOpacity(0.25),
                  width: 1.2,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.labelFontSize,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Colors.white : Colors.white.withOpacity(0.75),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ============ Layer 4: 底部水平封面轮播 ============

  Widget _buildPosterCarousel() {
    final list = _filteredGames;
    if (list.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withOpacity(0.55),
          ],
        ),
      ),
      child: FocusTraversalGroup(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: BigPictureTheme.pagePadding,
            vertical: 20,
          ),
          itemCount: list.length,
          separatorBuilder: (_, __) =>
              const SizedBox(width: BigPictureTheme.posterCardSpacing),
          itemBuilder: (context, index) {
            final game = list[index];
            final isSelected = index == _currentIndex;
            final shouldAutofocus =
                isSelected && index == 0 && !_initialFocusRequested;
            if (shouldAutofocus) _initialFocusRequested = true;
            return _PosterCard(
              game: game,
              isSelected: isSelected,
              coverPath: _resolveCoverPath(game),
              onTap: () => _selectGame(index),
              onDoubleTap: () => widget.onGameLaunch(game),
              onLongPress: widget.onGameLongPress != null
                  ? () => widget.onGameLongPress!(game)
                  : null,
              autofocus: shouldAutofocus,
            );
          },
        ),
      ),
    );
  }

  // ============ 空状态 ============

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sports_esports_rounded,
            size: 120,
            color: AppColors.secondaryText.withOpacity(0.3),
          ),
          const SizedBox(height: 24),
          Text(
            '还没有游戏',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: BigPictureTheme.titleFontSize,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '前往"添加"页面导入游戏,或前往"探索"页发现更多',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.bodyFontSize,
              color: AppColors.placeholderText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (widget.onGoToAdd != null || widget.onGoToDiscover != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onGoToAdd != null)
                  BpmInteractiveWrapper(
                    onTap: widget.onGoToAdd,
                    autofocus: true,
                    semanticsLabel: '前往添加',
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    child: Container(
                      height: BigPictureTheme.secondaryButtonHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: AppColors.selectedAccent,
                        borderRadius:
                            BorderRadius.circular(BigPictureTheme.buttonRadius),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.selectedAccent.withOpacity(0.4),
                            offset: const Offset(0, 4),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.add_rounded,
                              color: Colors.white, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            '前往添加',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.bodyFontSize,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (widget.onGoToAdd != null && widget.onGoToDiscover != null)
                  const SizedBox(width: 16),
                if (widget.onGoToDiscover != null)
                  BpmInteractiveWrapper(
                    onTap: widget.onGoToDiscover,
                    semanticsLabel: '前往探索',
                    borderRadius:
                        BorderRadius.circular(BigPictureTheme.buttonRadius),
                    child: Container(
                      height: BigPictureTheme.secondaryButtonHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: AppColors.buttonBackground,
                        borderRadius:
                            BorderRadius.circular(BigPictureTheme.buttonRadius),
                        border: Border.all(color: AppColors.border, width: 1.5),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.explore_rounded,
                              color: AppColors.secondaryText, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            '前往探索',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.bodyFontSize,
                              fontWeight: FontWeight.w600,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 筛选下无游戏 (但库不为空)
  Widget _buildEmptyFilterState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.filter_alt_off_rounded,
            size: 96,
            color: AppColors.secondaryText.withOpacity(0.3),
          ),
          const SizedBox(height: 20),
          Text(
            '当前筛选下无游戏',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.subtitleFontSize,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 12),
          BpmInteractiveWrapper(
            onTap: () {
              setState(() {
                _filterStatus = null;
                _currentIndex = 0;
                _initialFocusRequested = false;
              });
            },
            autofocus: true,
            semanticsLabel: '清除筛选',
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            child: Container(
              height: BigPictureTheme.secondaryButtonHeight,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
                border: Border.all(color: AppColors.border, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.clear_rounded,
                      color: AppColors.secondaryText, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    '清除筛选',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: BigPictureTheme.bodyFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============ 工具方法 ============

  (String, Color) _playStatusStyle(PlayStatus status) {
    return switch (status) {
      PlayStatus.notStarted => ('未开始', AppColors.secondaryText),
      PlayStatus.inProgress => ('游玩中', AppColors.infoBlue),
      PlayStatus.completed => ('已通关', AppColors.successGreen),
      PlayStatus.dropped => ('已弃坑', AppColors.dangerRed),
    };
  }

  String? _formatPlayTime(int seconds) {
    if (seconds <= 0) return null;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) return '已游玩 $hours 小时${minutes > 0 ? ' $minutes 分钟' : ''}';
    return '已游玩 $minutes 分钟';
  }
}

/// 底部轮播的竖版封面卡片
///
/// v1.3 设计:
/// - 140×200 竖版比例 (接近 GAL 标准封面)
/// - 选中卡片: 高亮边框 + 缩放 1.08
/// - 未选中卡片: 半透明 + 边框暗化
/// - 单击选中、双击启动、长按动作表
/// - 焦点变化时联动横向滚动
class _PosterCard extends StatelessWidget {
  final LibraryGame game;
  final bool isSelected;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback? onLongPress;
  final bool autofocus;

  const _PosterCard({
    required this.game,
    required this.isSelected,
    required this.coverPath,
    required this.onTap,
    required this.onDoubleTap,
    this.onLongPress,
    required this.autofocus,
  });

  @override
  Widget build(BuildContext context) {
    // 局部变量确保类型提升生效 (字段 coverPath 不会被自动提升)
    final path = coverPath;
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: true,
      onFocusChange: (focused) {
        if (focused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final renderObj = context.findRenderObject();
            if (renderObj != null) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
              );
            }
          });
        }
      },
      child: BpmInteractiveWrapper(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onLongPress: onLongPress,
        autofocus: autofocus,
        semanticsLabel: game.title,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: BigPictureTheme.posterCardWidth,
          height: BigPictureTheme.posterCardHeight,
          transform: isSelected
              ? (Matrix4.identity()..scale(BigPictureTheme.posterFocusScale))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? AppColors.selectedAccent
                  : Colors.white.withOpacity(0.15),
              width: isSelected ? 3 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.selectedAccent.withOpacity(0.5),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 封面图 / 占位
                if (path != null && path.isNotEmpty)
                  Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildPlaceholder(),
                  )
                else
                  _buildPlaceholder(),
                // 未选中时的暗化遮罩
                if (!isSelected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withOpacity(0.45),
                      ),
                    ),
                  ),
                // 底部渐变 + 标题
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.85),
                        ],
                      ),
                    ),
                    child: Text(
                      game.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        shadows: const [
                          Shadow(
                            color: Colors.black87,
                            offset: Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 选中标记 (右上角)
                if (isSelected)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: AppColors.selectedAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.selectedAccent,
                            offset: const Offset(0, 0),
                            blurRadius: 6,
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
    );
  }

  Widget _buildPlaceholder() {
    final initial = game.title.isNotEmpty ? game.title.characters.first : '?';
    return Container(
      color: AppColors.placeholderCover,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: 'ZhiMangXing',
          fontSize: 56,
          color: AppColors.secondaryText.withOpacity(0.4),
        ),
      ),
    );
  }
}
