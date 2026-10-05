import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/portable_image_cache_manager.dart';
import 'nsfw/nsfw_image.dart';
import '../theme/app_colors.dart';

/// 添加页封面预览浮层（2026-10-05，详情窗封面管理浮层的轻量变体）。
///
/// 场景差异：添加页尚未入库（无 metaDataDir / 无本地文件），封面是
/// 抓取结果的**网络 URL**（竖版 cover_url + 横幅 banner_url），因此
/// 本浮层为只读预览：无上传/删除/设定，仅查看 + 竖/横切换 + 拖拽缩放。
class CoverPreviewItem {
  final String url;
  final String label;

  const CoverPreviewItem({required this.url, required this.label});
}

class CoverPreviewOverlay extends StatefulWidget {
  final String gameTitle;
  final List<CoverPreviewItem> items;
  final int initialIndex;

  const CoverPreviewOverlay({
    super.key,
    required this.gameTitle,
    required this.items,
    this.initialIndex = 0,
  });

  @override
  State<CoverPreviewOverlay> createState() => _CoverPreviewOverlayState();
}

class _CoverPreviewOverlayState extends State<CoverPreviewOverlay> {
  static const double _minScale = 0.5;
  static const double _maxScale = 5.0;

  /// 图片默认显示尺寸 = 视口 × 此系数（2026-10-05，与封面管理浮层同口径：
  /// 横幅/竖图都不要默认贴满全窗口，缩小居中、四周留磨砂；看大图用缩放按钮）
  static const double _contentScale = 0.7;

  final TransformationController _tc = TransformationController();
  late int _index;
  Size _viewSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _index = widget.items.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.items.length - 1);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _go(int delta) {
    if (widget.items.length < 2) return;
    setState(() {
      _index = (_index + delta + widget.items.length) % widget.items.length;
      _tc.value = Matrix4.identity();
    });
  }

  void _resetView() => _tc.value = Matrix4.identity();

  /// 以视口中心为锚点缩放（仅预览）
  void _zoom(double factor) {
    final current = _tc.value;
    final scale = current.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final newScale = (scale * factor).clamp(_minScale, _maxScale);
    final eff = newScale / scale;
    final cx = _viewSize.width / 2;
    final cy = _viewSize.height / 2;
    final anchor = Matrix4.identity()
      ..translate(cx, cy)
      ..scale(eff)
      ..translate(-cx, -cy);
    _tc.value = anchor.multiplied(current);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark;
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (widget.items.length >= 2) ...{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _go(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _go(1),
            },
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: _close,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: isDark
                        ? Colors.black.withOpacity(0.50)
                        : Colors.black.withOpacity(0.35),
                  ),
                ),
              ),
              // 图片区：全窗口自由拖拽 + 缩放
              // 🔴 必须排在顶栏/工具条**之前**（2026-10-05 修复，同
              //    CoverGalleryOverlay）：原先排在顶栏之后，InteractiveViewer
              //    全窗口吞掉指针事件，右上角关闭按钮永远点不到 → 无法退出
              Positioned.fill(child: _buildViewer()),
              Positioned(
                top: 16,
                left: 20,
                right: 16,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.gameTitle} - 封面预览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _close,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.9),
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 18, color: Colors.black87),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: _buildToolbar(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final item =
            widget.items.isEmpty ? null : widget.items[_index.clamp(0, widget.items.length - 1)];
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: _minScale,
                maxScale: _maxScale,
                panEnabled: true,
                child: Center(
                  child: item == null
                      ? const Text(
                          '暂无封面图\n先在左侧选择一个抓取结果',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              height: 1.6),
                        )
                      : ConstrainedBox(
                          // 2026-10-05：默认显示框压到视口 × _contentScale，
                          // 横幅/竖图都居中缩小，不再贴满全窗口
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * _contentScale,
                            maxHeight: constraints.maxHeight * _contentScale,
                          ),
                          child: GestureDetector(
                            onDoubleTap: _resetView,
                            child: NsfwImage.network(
                              item.url,
                              contentKind: NsfwContentKind.cover,
                              detectOnDemand: true,
                              child: CachedNetworkImage(
                                cacheManager: PortableImageCacheManager(),
                                imageUrl: item.url,
                                fit: BoxFit.contain,
                                placeholder: (context, url) => const Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                ),
                                errorWidget: (context, url, error) =>
                                    const Icon(
                                  Icons.broken_image_outlined,
                                  size: 48,
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (item != null)
              Positioned(
                // 2026-10-05 下移避让顶栏标题（图片层已改到顶栏之下）
                top: 56,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    widget.items.length > 1
                        ? '${item.label} · ${_index + 1}/${widget.items.length}'
                        : item.label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolButton(
                  icon: Icons.zoom_out_rounded,
                  tip: '缩小预览',
                  onTap: () => _zoom(1 / 1.25)),
              _toolButton(
                  icon: Icons.zoom_in_rounded,
                  tip: '放大预览',
                  onTap: () => _zoom(1.25)),
              _toolButton(
                icon: Icons.chevron_left_rounded,
                tip: '上一张',
                onTap: widget.items.length >= 2 ? () => _go(-1) : null,
              ),
              _toolButton(
                  icon: Icons.center_focus_strong_rounded,
                  tip: '恢复初始居中',
                  onTap: _resetView),
              _toolButton(
                icon: Icons.chevron_right_rounded,
                tip: '下一张',
                onTap: widget.items.length >= 2 ? () => _go(1) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon,
                size: 20, color: enabled ? Colors.white : Colors.white30),
          ),
        ),
      ),
    );
  }
}
