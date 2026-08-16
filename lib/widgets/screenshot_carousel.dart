import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../services/screenshot_fetch_service.dart';

/// 通用截图轮播组件
/// 支持网络图片（CachedNetworkImage）和本地文件图片（Image.file）
/// 网络图片支持预加载：所有URL同时开始加载，每张图加载完即可显示
///
/// 截图状态感知：当传入 [gameTitle] 时，组件会监听 ScreenshotFetchService
/// 的状态变化，在截图后台下载过程中展示对应的加载/失败/重试UI。
class ScreenshotCarousel extends StatefulWidget {
  /// 截图路径列表（网络URL或本地文件绝对路径）
  final List<String> paths;

  /// 是否为网络图片
  final bool isNetwork;

  /// 截图展示高度（仅无截图占位时使用）
  final double height;

  /// 是否显示底部指示点
  final bool showIndicator;

  /// 是否显示左右箭头
  final bool showArrows;

  /// 游戏标题（用于关联截图后台抓取状态）
  ///
  /// 传入后组件会自动监听 ScreenshotFetchService 的状态：
  /// - pending/downloading: 显示"截图获取中"加载动画
  /// - failed: 显示"截图获取失败"+ 重试按钮
  /// - completed: 正常展示截图
  final String? gameTitle;

  const ScreenshotCarousel({
    super.key,
    required this.paths,
    this.isNetwork = true,
    this.height = 140,
    this.showIndicator = true,
    this.showArrows = true,
    this.gameTitle,
  });

  @override
  State<ScreenshotCarousel> createState() => _ScreenshotCarouselState();
}

class _ScreenshotCarouselState extends State<ScreenshotCarousel> {
  late PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 初始化时预加载所有网络图片
    if (widget.isNetwork && widget.paths.isNotEmpty) {
      _precacheAllImages();
    }
    // 监听截图抓取服务状态变化
    ScreenshotFetchService.instance.addListener(_onScreenshotFetchChanged);
  }

  void _onScreenshotFetchChanged() {
    if (!mounted) return;
    // 状态变化时刷新UI（只有关联了 gameTitle 时才需要）
    if (widget.gameTitle != null && widget.paths.isEmpty) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(ScreenshotCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths != widget.paths) {
      if (_currentPage >= widget.paths.length) {
        _currentPage = 0;
        _pageController.jumpToPage(0);
      }
      // 路径变化时重新预加载
      if (widget.isNetwork && widget.paths.isNotEmpty) {
        _precacheAllImages();
      }
    }
  }

  /// 预加载所有网络图片，确保6张图同时开始加载
  /// 每张图加载完成后 CachedNetworkImage 会自动缓存并显示
  void _precacheAllImages() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final path in widget.paths) {
        if (path.startsWith('http')) {
          precacheImage(
              CachedNetworkImageProvider(path,
                  cacheManager: PortableImageCacheManager()),
              context);
        }
      }
    });
  }

  @override
  void dispose() {
    ScreenshotFetchService.instance.removeListener(_onScreenshotFetchChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    if (page < 0 || page >= widget.paths.length) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// 获取当前截图抓取状态（仅当关联了 gameTitle 时）
  ScreenshotFetchStatus? _getFetchStatus() {
    if (widget.gameTitle == null) return null;
    return ScreenshotFetchService.instance.getStatus(widget.gameTitle!);
  }

  @override
  Widget build(BuildContext context) {
    // 无截图时根据状态展示不同UI
    if (widget.paths.isEmpty) {
      final status = _getFetchStatus();
      // 有关联游戏且状态为 pending/downloading → 显示加载中
      if (status == ScreenshotFetchStatus.pending ||
          status == ScreenshotFetchStatus.downloading) {
        return _buildFetchingPlaceholder(status!);
      }
      // 有关联游戏且状态为 failed → 显示失败+重试
      if (status == ScreenshotFetchStatus.failed) {
        return _buildFailedPlaceholder();
      }
      // 无状态或已完成 → 显示"暂无截图"
      return _buildEmptyPlaceholder();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 截图展示区域 — 16:9 比例自适应
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // PageView
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.paths.length,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                  },
                  itemBuilder: (context, index) {
                    return _buildImage(widget.paths[index]);
                  },
                ),

                // 左箭头
                if (widget.showArrows && widget.paths.length > 1)
                  Positioned(
                    left: 4,
                    top: 0,
                    bottom: 0,
                    child: _buildArrowButton(
                      icon: Icons.chevron_left,
                      onPressed: _currentPage > 0
                          ? () => _goToPage(_currentPage - 1)
                          : null,
                    ),
                  ),

                // 右箭头
                if (widget.showArrows && widget.paths.length > 1)
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    child: _buildArrowButton(
                      icon: Icons.chevron_right,
                      onPressed: _currentPage < widget.paths.length - 1
                          ? () => _goToPage(_currentPage + 1)
                          : null,
                    ),
                  ),

                // 计数标签
                if (widget.paths.length > 1)
                  Positioned(
                    right: 8,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_currentPage + 1}/${widget.paths.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // 底部指示点
        if (widget.showIndicator && widget.paths.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.paths.length, (index) {
                final isActive = index == _currentPage;
                return GestureDetector(
                  onTap: () => _goToPage(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    width: isActive ? 12 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.selectedAccent
                          : AppColors.borderLight,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }

  /// 截图获取中占位图（pending/downloading 状态）
  Widget _buildFetchingPlaceholder(ScreenshotFetchStatus status) {
    final progress = widget.gameTitle != null
        ? ScreenshotFetchService.instance.getProgress(widget.gameTitle!)
        : null;
    final progressText = progress != null && progress.totalCount > 0
        ? '${progress.completedCount}/${progress.totalCount}'
        : '';

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.placeholderCover,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                status == ScreenshotFetchStatus.downloading &&
                        progressText.isNotEmpty
                    ? '截图获取中 $progressText'
                    : '截图获取中...',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.placeholderText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 截图获取失败占位图（failed 状态，含重试按钮）
  Widget _buildFailedPlaceholder() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.placeholderCover,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 28,
                color: AppColors.border,
              ),
              const SizedBox(height: 6),
              Text(
                '截图获取失败',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.border,
                ),
              ),
              const SizedBox(height: 8),
              _RetryButton(
                gameTitle: widget.gameTitle!,
                onRetry: () => setState(() {}),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 无截图占位图（无状态或completed）
  Widget _buildEmptyPlaceholder() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.placeholderCover,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.screenshot_outlined,
                  size: 28, color: AppColors.border),
              const SizedBox(height: 6),
              Text(
                '暂无截图',
                style: TextStyle(
                  fontFamily: 'ZhiMangXing',
                  fontSize: 14,
                  letterSpacing: 1.5,
                  color: AppColors.border,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String path) {
    if (widget.isNetwork) {
      return CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: path,
        fit: BoxFit.cover,
        // 加载中：显示占位背景+转圈
        placeholder: (context, url) => Container(
          color: AppColors.placeholderCover,
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        // 加载完成：直接显示图片（CachedNetworkImage自动处理）
        // 加载失败：显示错误图标
        errorWidget: (context, url, error) => Container(
          color: AppColors.placeholderCover,
          child: Icon(
            Icons.broken_image_outlined,
            color: AppColors.placeholderText,
            size: 28,
          ),
        ),
      );
    } else {
      final file = File(path);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            color: AppColors.placeholderCover,
            child: Icon(
              Icons.broken_image_outlined,
              color: AppColors.placeholderText,
              size: 28,
            ),
          ),
        );
      } else {
        return Container(
          color: AppColors.placeholderCover,
          child: Icon(
            Icons.image_not_supported_outlined,
            color: AppColors.placeholderText,
            size: 28,
          ),
        );
      }
    }
  }

  Widget _buildArrowButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    // UX-37: 改用独立组件承载 hover 反馈
    return _ArrowButton(icon: icon, onPressed: onPressed);
  }
}

/// 截图重试按钮
class _RetryButton extends StatefulWidget {
  final String gameTitle;
  final VoidCallback onRetry;

  const _RetryButton({required this.gameTitle, required this.onRetry});

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
  bool _hovered = false;
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ScreenshotFetchService.instance
          .triggerManualFetch(widget.gameTitle);
    } finally {
      if (mounted) {
        setState(() => _retrying = false);
        widget.onRetry();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _retrying ? null : _retry,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.selectedAccent.withOpacity(0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _hovered ? AppColors.selectedAccent : AppColors.border,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_retrying)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                Icon(Icons.refresh, size: 12, color: AppColors.border),
              const SizedBox(width: 4),
              Text(
                _retrying ? '重试中' : '重新获取',
                style: TextStyle(
                  fontSize: 11,
                  color: _hovered ? AppColors.selectedAccent : AppColors.border,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// UX-37: 截图轮播箭头按钮——桌面端 hover 时背景加深、轻微放大，明确可点击区域。
class _ArrowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _ArrowButton({required this.icon, required this.onPressed});

  @override
  State<_ArrowButton> createState() => _ArrowButtonState();
}

class _ArrowButtonState extends State<_ArrowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onPressed != null;
    return Center(
      child: MouseRegion(
        cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _hovered && isEnabled ? 1.12 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isEnabled
                    ? (_hovered
                        ? Colors.black.withOpacity(0.7)
                        : Colors.black45)
                    : Colors.black26,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.icon,
                color: isEnabled ? Colors.white : Colors.white38,
                size: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
