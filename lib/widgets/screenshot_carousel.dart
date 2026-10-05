import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../services/screenshot_fetch_service.dart';
import '../services/nsfw/nsfw_detection_store.dart';
import 'nsfw/nsfw_image.dart';

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

  /// 双击图片回调（传回被双击图片的下标）
  ///
  /// 为 null 时（默认）不启用双击交互；
  /// 详情窗口传入后可实现"双击看大图"。
  final void Function(int index)? onImageDoubleTap;

  /// 是否启用悬停放大镜交互
  ///
  /// 为 true 时：鼠标悬停在截图上 → 光标变为系统放大镜，
  /// 同时截图轻微放大（1.03x），鼠标移开后复原。
  /// 仅影响鼠标，触摸手势不受影响。
  final bool enableHoverZoom;

  /// 无截图/加载失败时的"重新加载"回调
  ///
  /// 传入后：截图区域中央显示可点击的刷新图标（圆圈箭头样式），
  /// 点击触发重新加载；加载过程中图标变为旋转动画。
  /// 为 null 时退化为静态"暂无截图"占位（无重试入口）。
  final Future<void> Function()? onRefresh;

  const ScreenshotCarousel({
    super.key,
    required this.paths,
    this.isNetwork = true,
    this.height = 140,
    this.showIndicator = true,
    this.showArrows = true,
    this.gameTitle,
    this.onImageDoubleTap,
    this.enableHoverZoom = false,
    this.onRefresh,
  });

  @override
  State<ScreenshotCarousel> createState() => _ScreenshotCarouselState();
}

class _ScreenshotCarouselState extends State<ScreenshotCarousel> {
  late PageController _pageController;
  int _currentPage = 0;

  /// 重新加载中（点击刷新图标后）
  bool _refreshing = false;

  /// 点击刷新图标：调用外部 onRefresh，期间显示旋转动画
  Future<void> _handleRefresh() async {
    if (_refreshing || widget.onRefresh == null) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh!();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
          // §9.4：已判定含敏感区域的截图不预加载原图——
          // 渲染层会用局部马赛克接管（原图仅作马赛克采样源按需解码），
          // 提前 precache 会把敏感原图拉进内存缓存并造成"未打码闪现"窗口
          final detection = NsfwDetectionStore.instance
              .detectionForAny(<String>[NsfwDetectionStore.keyForUrl(path)]);
          if (detection != null && detection.boxes.isNotEmpty) continue;
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
      // 有关联游戏且状态为 failed → 显示失败 + 重新加载图标
      if (status == ScreenshotFetchStatus.failed) {
        return _buildFailedPlaceholder();
      }
      // 无状态或已完成 → 显示"暂无截图" + 重新加载图标（可重试抓取）
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
                    final image = _buildImage(widget.paths[index]);
                    if (widget.onImageDoubleTap == null &&
                        !widget.enableHoverZoom) {
                      return image;
                    }
                    return _HoverZoomImage(
                      onDoubleTap: widget.onImageDoubleTap != null
                          ? () => widget.onImageDoubleTap!(index)
                          : null,
                      enableHoverZoom: widget.enableHoverZoom,
                      child: image,
                    );
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

  /// 截图获取失败占位图（failed 状态，中央刷新图标可重新加载）
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
          child: Center(
            child: _RefreshIcon(
              refreshing: _refreshing,
              label: '截图获取失败，点击重新加载',
              onTap: widget.onRefresh != null
                  ? _handleRefresh
                  : (widget.gameTitle != null
                      ? () => ScreenshotFetchService.instance
                          .triggerManualFetch(widget.gameTitle!)
                          .then((_) {
                          if (mounted) setState(() {});
                        })
                      : null),
            ),
          ),
        ),
      ),
    );
  }

  /// 无截图占位图（无状态或completed，中央刷新图标可重新加载）
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
          child: Center(
            child: widget.onRefresh != null
                ? _RefreshIcon(
                    refreshing: _refreshing,
                    label: '暂无截图，点击重新加载',
                    onTap: _handleRefresh,
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.screenshot_outlined,
                          size: 28, color: AppColors.border),
                      const SizedBox(height: 6),
                      Text(
                        '暂无截图',
                        style: TextStyle(
                          fontSize: 14,
                          letterSpacing: 1.5,
                          color: AppColors.border,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String path) {
    if (widget.isNetwork) {
      // NSFW 局部打码（v2）：原有渲染整块作为 child 传入，健康图/未判定图
      // 走的就是原来那棵 widget 子树，渲染结果逐像素一致。
      return NsfwImage.network(
        path,
        fit: BoxFit.cover,
        enableReveal: true,
        // 网络截图（PB 回传 / VNDB 等三源抓取）从不落盘为本地文件，
        // 全量扫描覆盖不到，必须开启按需检测：缓存落盘后即入队检测，
        // 结果以「URL 主键 + 本地缓存路径别名」双键写入判定缓存。
        detectOnDemand: true,
        // 与 child 的 memCacheWidth 对齐，缓存键一致、单次解码
        // （本地分支同用 1920，见下）。不设 diskCacheWidth：缩略图会被
        // flutter_cache_manager 重编码为 PNG 反而增盘，磁盘尺寸交给
        // CacheQuotaService 的字节配额淘汰兜底。
        decodeWidth: 1920,
        child: CachedNetworkImage(
          cacheManager: PortableImageCacheManager(),
          imageUrl: path,
          fit: BoxFit.cover,
          // ★ 性能优化：限制解码宽度。4K 原图全解码单张 ~33MB 内存尖峰，
          // 1920 物理像素在 cover 拉伸下视觉无感知差异，解码内存降至 ~8MB。
          memCacheWidth: 1920,
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
        ),
      );
    } else {
      final file = File(path);
      if (file.existsSync()) {
        return NsfwImage.file(
          path,
          fit: BoxFit.cover,
          // 与 child 的 cacheWidth 保持一致，让两边 ImageProvider 缓存键相同，
          // 同一张图只解码一次（见 NsfwImage 文档）。
          decodeWidth: 1920,
          enableReveal: true,
          child: Image.file(
            file,
            fit: BoxFit.cover,
            // ★ 性能优化：限制解码宽度。4K 原图全解码单张 ~33MB 内存尖峰，
            // 1920 物理像素在 cover 拉伸下视觉无感知差异，解码内存降至 ~8MB。
            cacheWidth: 1920,
            errorBuilder: (context, error, stackTrace) => Container(
              color: AppColors.placeholderCover,
              child: Icon(
                Icons.broken_image_outlined,
                color: AppColors.placeholderText,
                size: 28,
              ),
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

/// 重新加载图标（截图区域中央）
///
/// 常见网站刷新按钮样式：圆圈 + 箭头，点击触发重新加载。
/// - 加载中：图标旋转动画 + "加载中..."文案，忽略重复点击
/// - 悬停：轻微放大 + 高亮，鼠标变为手型
/// - 无回调（onTap=null）时仅静态展示，不可交互
class _RefreshIcon extends StatefulWidget {
  final bool refreshing;
  final String label;
  final VoidCallback? onTap;

  const _RefreshIcon({
    required this.refreshing,
    required this.label,
    this.onTap,
  });

  @override
  State<_RefreshIcon> createState() => _RefreshIconState();
}

class _RefreshIconState extends State<_RefreshIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null && !widget.refreshing;
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) {
        if (interactive) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: GestureDetector(
        onTap: interactive ? widget.onTap : null,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: _hovered ? 1.12 : 1.0,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _hovered || widget.refreshing ? 1.0 : 0.75,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 圆圈背景 + 旋转箭头（加载中旋转）
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.placeholderCover,
                    border: Border.all(
                      color: _hovered || widget.refreshing
                          ? AppColors.selectedAccent
                          : AppColors.border,
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: widget.refreshing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.refresh_rounded,
                            size: 24,
                            color: _hovered
                                ? AppColors.selectedAccent
                                : AppColors.placeholderText,
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.refreshing ? '加载中...' : widget.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: _hovered
                        ? AppColors.selectedAccent
                        : AppColors.placeholderText,
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

/// 截图悬停/双击交互包装：
/// - 悬停：光标变系统放大镜 + 截图轻微放大（1.03x），移开复原（仅鼠标，触摸不受影响）
/// - 双击：触发外部回调（如弹出大图查看）
class _HoverZoomImage extends StatefulWidget {
  final VoidCallback? onDoubleTap;
  final bool enableHoverZoom;
  final Widget child;

  const _HoverZoomImage({
    required this.child,
    this.onDoubleTap,
    this.enableHoverZoom = false,
  });

  @override
  State<_HoverZoomImage> createState() => _HoverZoomImageState();
}

class _HoverZoomImageState extends State<_HoverZoomImage> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enableHoverZoom
          ? SystemMouseCursors.zoomIn
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onDoubleTap: widget.onDoubleTap,
        child: ClipRect(
          child: AnimatedScale(
            scale: widget.enableHoverZoom && _hovered ? 1.03 : 1.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: widget.child,
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
