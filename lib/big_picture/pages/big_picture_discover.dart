import 'package:flutter/material.dart';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/portable_image_cache_manager.dart';
import '../../theme/app_colors.dart';
import '../../models/game_model.dart';
import '../../repositories/game_repository.dart';
import '../../services/global_install_center.dart';
import '../../services/local_game_registry.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_snack_bar.dart';
import '../big_picture_theme.dart';
import '../focus/focus_grid_policy.dart';
import '../widgets/bpm_interactive_wrapper.dart';

/// BPM 发现页
///
/// 展示可下载游戏列表,适配大屏触控操作。
/// 数据源: [GameRepository.getGameList] (与桌面 DiscoverPage 一致)。
///
/// 简化策略 (相对桌面模式):
/// - 仅展示游戏封面网格 + 标题/开发者
/// - 单击卡片弹出详情对话框 (showAppDialog),含下载按钮
/// - 不显示完整元数据编辑,下载流程通过 [GlobalInstallCenter] 触发
/// - 下载进度通过桌面模式 [InstallCenterPage] 查看 (用户可切回桌面)
class BigPictureDiscover extends StatefulWidget {
  /// 游戏卡片点击回调 (可选,若不提供则使用内置详情对话框)
  final ValueChanged<GameModel>? onGameTap;

  const BigPictureDiscover({super.key, this.onGameTap});

  @override
  State<BigPictureDiscover> createState() => _BigPictureDiscoverState();
}

class _BigPictureDiscoverState extends State<BigPictureDiscover> {
  List<GameModel> _games = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMoreData = true;
  int _currentPage = 1;
  int _totalCount = -1; // -1 = 加载中, 0+ = 实际总数
  String? _errorMessage;
  final ScrollController _scrollController = ScrollController();

  /// v1.2: 首次焦点标志,仅首次构建时让首卡 autofocus
  bool _initialFocusRequested = false;

  static const int _perPage = 20;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitialGames();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // v1.2: 加 hasClients 守卫,避免 controller 未附加时访问 position 抛异常
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        !_isLoading &&
        _hasMoreData) {
      _loadMoreGames();
    }
  }

  Future<void> _loadInitialGames() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _totalCount = -1;
    });
    try {
      // 并发获取总数 + 第一页数据, 避免显示延迟
      final results = await Future.wait([
        GameRepository.getGameCount(),
        GameRepository.getGameList(page: 1, perPage: _perPage),
      ]);
      if (!mounted) return;
      final totalCount = results[0] as int;
      final games = results[1] as List<GameModel>;
      setState(() {
        _games = games;
        _totalCount = totalCount;
        _isLoading = false;
        _currentPage = 1;
        _hasMoreData = games.length >= _perPage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '加载失败: $e';
      });
    }
  }

  Future<void> _loadMoreGames() async {
    if (_isLoadingMore || !_hasMoreData) return;
    setState(() => _isLoadingMore = true);
    try {
      final nextPage = _currentPage + 1;
      final moreGames =
          await GameRepository.getGameList(page: nextPage, perPage: _perPage);
      if (!mounted) return;
      setState(() {
        _games.addAll(moreGames);
        _currentPage = nextPage;
        _hasMoreData = moreGames.length >= _perPage;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      // v1.2: 失败时不永久关闭分页,仅退出 _isLoadingMore,允许用户重试
      setState(() {
        _isLoadingMore = false;
      });
      if (mounted) AppSnackBar.warning(context, '加载更多失败,可继续滚动重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.pageBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部标题区
          Padding(
            padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
            child: Row(
              children: [
                Text(
                  '探索',
                  style: TextStyle(
                    fontFamily: 'ZhiMangXing',
                    fontSize: BigPictureTheme.displayFontSize,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  _totalCount >= 0 ? '$_totalCount 个游戏' : '加载中...',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    color: AppColors.secondaryText,
                  ),
                ),
                const Spacer(),
                // 刷新按钮
                BpmInteractiveWrapper(
                  onTap: _loadInitialGames,
                  semanticsLabel: '刷新',
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.buttonRadius),
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius:
                          BorderRadius.circular(BigPictureTheme.buttonRadius),
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded,
                            size: 22, color: AppColors.secondaryText),
                        const SizedBox(width: 8),
                        Text(
                          '刷新',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 内容区
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '加载中...',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 96, color: AppColors.secondaryText.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                color: AppColors.placeholderText,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            BpmInteractiveWrapper(
              onTap: _loadInitialGames,
              semanticsLabel: '重试',
              borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.selectedAccent,
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.buttonRadius),
                ),
                child: const Text(
                  '重试',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_games.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_off_rounded,
                size: 96, color: AppColors.secondaryText.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              '暂无可发现的游戏',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.bodyFontSize,
                color: AppColors.placeholderText,
              ),
            ),
          ],
        ),
      );
    }

    // 用 FocusTraversalGroup + FocusGridPolicy 包裹 GridView
    // 解决方向键被默认 policy 消费导致 GridView 不滚动的问题
    // FocusGridPolicy 在焦点变化时联动 Scrollable.ensureVisible 让卡片可见
    return FocusTraversalGroup(
      policy: FocusGridPolicy(),
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          BigPictureTheme.pagePadding,
          0,
          BigPictureTheme.pagePadding,
          BigPictureTheme.pagePadding,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent:
              BigPictureTheme.cardWidth + BigPictureTheme.cardSpacing,
          crossAxisSpacing: BigPictureTheme.cardSpacing,
          mainAxisSpacing: BigPictureTheme.cardSpacing,
          childAspectRatio:
              BigPictureTheme.cardWidth / BigPictureTheme.cardHeight,
        ),
        itemCount: _games.length + (_isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _games.length) {
            // 加载更多指示器
            return Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
                ),
              ),
            );
          }
          final game = _games[index];
          final isInstalled =
              LocalGameRegistry.instance.isTitleInstalled(game.title);
          // v1.2: 仅首项首次 autofocus
          final shouldAutofocus = index == 0 && !_initialFocusRequested;
          if (shouldAutofocus) _initialFocusRequested = true;
          // v1.2: 外层加 RepaintBoundary 隔离重绘
          return RepaintBoundary(
            child: _DiscoverCard(
              game: game,
              isInstalled: isInstalled,
              autofocus: shouldAutofocus,
              onTap: () => _handleGameTap(game),
            ),
          );
        },
      ),
    );
  }

  void _handleGameTap(GameModel game) {
    if (widget.onGameTap != null) {
      widget.onGameTap!.call(game);
      return;
    }
    // 默认: 弹出详情对话框
    showAppDialog(
      context: context,
      builder: (context) => _DiscoverDetailDialog(game: game),
    );
  }
}

/// 发现页游戏卡片
///
/// 与 [BigPictureGameCard] 不同,此卡片展示的是 [GameModel] (可下载游戏),
/// 封面使用 [CachedNetworkImage] (网络图片),右下角显示"已入库"徽章 (如已安装)。
///
/// v1.2 优化:
/// - 修复双重 Focus 节点: 外层 Focus 设 canRequestFocus: false, descendantsAreFocusable: true
/// - 移除显式 width/height,让 gridDelegate 紧约束生效
/// - 字号统一到 BPM 规范 (16 → bodyFontSize, 11 → labelFontSize, 10 → labelFontSize)
/// - 接收外部 autofocus 参数
class _DiscoverCard extends StatelessWidget {
  final GameModel game;
  final bool isInstalled;
  final VoidCallback onTap;
  final bool autofocus;

  const _DiscoverCard({
    required this.game,
    required this.isInstalled,
    required this.onTap,
    required this.autofocus,
  });

  @override
  Widget build(BuildContext context) {
    // v1.2: 外层 Focus 设 canRequestFocus: false, descendantsAreFocusable: true
    // 仅作为 onFocusChange 监听容器,不参与焦点导航 (避免与 BpmInteractiveWrapper 内部 Focus 冲突)
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
        autofocus: autofocus,
        semanticsLabel: game.title,
        borderRadius: BorderRadius.circular(BigPictureTheme.cardRadius),
        child: Container(
          // v1.2: 移除显式 width/height,让 gridDelegate 紧约束生效
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BigPictureTheme.cardRadius),
            color: AppColors.buttonBackground,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 封面层
              _buildCover(),
              // 底部渐变 + 标题层
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.85),
                        Colors.black.withOpacity(0.4),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: BigPictureTheme.bodyFontSize,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      if (game.developer.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            game.developer,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.labelFontSize,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 已入库徽章 (右上角)
              if (isInstalled)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.successGreen.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '已入库',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: BigPictureTheme.labelFontSize,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    if (game.hasCover && game.coverUrl.isNotEmpty) {
      return CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: game.coverUrl,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: AppColors.placeholderCover,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
              ),
            ),
          ),
        ),
        errorWidget: (context, url, error) => _buildPlaceholderCover(),
      );
    }
    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    final initial = game.title.isNotEmpty ? game.title.characters.first : '?';
    return Container(
      color: AppColors.buttonBackground,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: 'ZhiMangXing',
          fontSize: 72,
          color: AppColors.secondaryText.withOpacity(0.4),
        ),
      ),
    );
  }
}

/// 发现页游戏详情对话框
///
/// 展示游戏完整信息 (封面/标题/描述/标签) + 下载按钮。
/// 下载通过 [GlobalInstallCenter.submitTask] 触发,提交后关闭对话框。
class _DiscoverDetailDialog extends StatefulWidget {
  final GameModel game;

  const _DiscoverDetailDialog({required this.game});

  @override
  State<_DiscoverDetailDialog> createState() => _DiscoverDetailDialogState();
}

class _DiscoverDetailDialogState extends State<_DiscoverDetailDialog> {
  bool _isDownloading = false;

  Future<void> _startDownload() async {
    if (_isDownloading) return;
    if (GlobalInstallCenter.instance.isBusy) {
      if (mounted) {
        AppSnackBar.warning(context, '当前已有获取任务进行中,请等待完成');
      }
      return;
    }

    setState(() => _isDownloading = true);

    try {
      final task = InstallTask(
        gameId: widget.game.id,
        title: widget.game.title,
        description: widget.game.description,
        coverUrl: widget.game.coverUrl,
        tags: widget.game.tags,
        downloadUrl: widget.game.downloadUrl,
        developer: widget.game.developer,
        screenshotUrls: widget.game.screenshotUrls.isNotEmpty
            ? widget.game.screenshotUrls
            : null,
      );

      // [BugFix 白屏] 同 game_detail_page 修复,改用 fire-and-forget
      // 旧实现 await submitTask 会等 download + extract + completed 全部跑完,
      // 期间 _isDownloading=true 阻塞 UI,叠加 listener 泄漏/高频 setState
      // 会导致 BigPicture 模式下的详情对话框也出现"白屏卡死"。
      // 现在:不 await 整个 install 流程,让 UI 立即恢复,进度交给 FloatingTaskButton
      unawaited(GlobalInstallCenter.instance.submitTask(task).then((success) {
        if (!mounted) return;
        if (success) {
          AppSnackBar.success(context,
              '已开始获取「${widget.game.title}」,可在安装中心查看进度');
          Navigator.of(context).pop();
        } else {
          AppSnackBar.error(context, '获取任务提交失败');
          setState(() => _isDownloading = false);
        }
      }));
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.error(context, '获取失败: $e');
      setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final isInstalled = LocalGameRegistry.instance.isTitleInstalled(game.title);

    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        // v1.2: 宽度容错,用 ConstrainedBox 限制最大宽度
        constraints: const BoxConstraints(maxWidth: 880),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height - 200, // 留出顶部标题栏和底部边距
          ),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius:
                BorderRadius.circular(BigPictureTheme.containerRadius),
            border: Border.all(color: AppColors.border, width: 1.5),
          ),
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(BigPictureTheme.containerRadius),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部封面区
                if (game.hasCover && game.coverUrl.isNotEmpty)
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          cacheManager: PortableImageCacheManager(),
                          imageUrl: game.coverUrl,
                          fit: BoxFit.cover,
                          errorWidget: (context, url, error) =>
                              Container(color: AppColors.placeholderCover),
                        ),
                        // 底部渐变遮罩
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 80,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  AppColors.background,
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // v1.2: 内容区用 SingleChildScrollView 包裹,防 720p 屏溢出
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(BigPictureTheme.pagePadding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 标题
                        Text(
                          game.title,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: BigPictureTheme.titleFontSize,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primaryText,
                          ),
                        ),
                        if (game.developer.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            game.developer,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.subtitleFontSize,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ],
                        // 标签
                        if (game.tags.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: game.tags.take(8).map((tag) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.buttonBackground,
                                  borderRadius: BorderRadius.circular(
                                      BigPictureTheme.buttonRadius),
                                  border: Border.all(
                                      color: AppColors.border, width: 1),
                                ),
                                child: Text(
                                  tag,
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: BigPictureTheme.labelFontSize,
                                    color: AppColors.secondaryText,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                        // 描述
                        if (game.description.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            '游戏简介',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.subtitleFontSize,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primaryText,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            game.description,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: BigPictureTheme.bodyFontSize,
                              color: AppColors.primaryText,
                              height: 1.6,
                            ),
                            maxLines: 12,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 24),
                        // 按钮组 (v1.2: 用 Wrap 容错)
                        Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          children: [
                            if (isInstalled)
                              SizedBox(
                                width: 280,
                                child: Container(
                                  height: BigPictureTheme.launchButtonHeight,
                                  decoration: BoxDecoration(
                                    color: AppColors.successGreen
                                        .withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(
                                        BigPictureTheme.buttonRadius),
                                    border: Border.all(
                                        color: AppColors.successGreen,
                                        width: 1.5),
                                  ),
                                  child: Center(
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.check_circle_rounded,
                                            size: 24,
                                            color: AppColors.successGreen),
                                        const SizedBox(width: 8),
                                        Text(
                                          '已入库',
                                          style: TextStyle(
                                            fontFamily: 'Inter',
                                            fontSize: BigPictureTheme
                                                .subtitleFontSize,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.successGreen,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            else
                              SizedBox(
                                width: 280,
                                child: BpmInteractiveWrapper(
                                  onTap: _isDownloading ? null : _startDownload,
                                  autofocus: true,
                                  semanticsLabel: '获取作品',
                                  borderRadius: BorderRadius.circular(
                                      BigPictureTheme.buttonRadius),
                                  child: Container(
                                    height: BigPictureTheme.launchButtonHeight,
                                    decoration: BoxDecoration(
                                      color: AppColors.selectedAccent,
                                      borderRadius: BorderRadius.circular(
                                          BigPictureTheme.buttonRadius),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.selectedAccent
                                              .withOpacity(0.4),
                                          blurRadius: 16,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (_isDownloading)
                                          const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                      Colors.white),
                                            ),
                                          )
                                        else
                                          const Icon(Icons.download_rounded,
                                              size: 28, color: Colors.white),
                                        const SizedBox(width: 12),
                                        Text(
                                          _isDownloading ? '提交中...' : '下载游戏',
                                          style: TextStyle(
                                            fontFamily: 'Inter',
                                            fontSize: BigPictureTheme
                                                .subtitleFontSize,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            BpmInteractiveWrapper(
                              onTap: () => Navigator.of(context).pop(),
                              semanticsLabel: '关闭',
                              borderRadius: BorderRadius.circular(
                                  BigPictureTheme.buttonRadius),
                              child: Container(
                                height: BigPictureTheme.launchButtonHeight,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 16),
                                decoration: BoxDecoration(
                                  color: AppColors.buttonBackground,
                                  borderRadius: BorderRadius.circular(
                                      BigPictureTheme.buttonRadius),
                                  border: Border.all(
                                      color: AppColors.border, width: 1.5),
                                ),
                                child: Center(
                                  child: Text(
                                    '关闭',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: BigPictureTheme.bodyFontSize,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.secondaryText,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
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
}
