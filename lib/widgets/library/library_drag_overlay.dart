import 'dart:io';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../services/local_game_registry.dart';

/// UX-13: 从 library_page.dart 抽取的拖拽跟随浮层。
///
/// 跟随指针移动的卡片视觉，包含缩放、阴影、抬升动画。
/// 通过 [liftAnimation] 控制拖拽起始/结束的过渡。
class LibraryDragOverlay extends StatefulWidget {
  final LibraryGame game;
  final Offset dragPosition;
  final Offset dragAnchor;
  final Animation<double> liftAnimation;
  final bool isMarked;
  final Size? cardSize;

  /// UX-34: 预缓存的封面路径，避免 build 中的同步 I/O
  final String? coverPath;

  const LibraryDragOverlay({
    super.key,
    required this.game,
    required this.dragPosition,
    required this.dragAnchor,
    required this.liftAnimation,
    required this.isMarked,
    this.cardSize,
    this.coverPath,
  });

  @override
  State<LibraryDragOverlay> createState() => _LibraryDragOverlayState();
}

class _LibraryDragOverlayState extends State<LibraryDragOverlay> {
  late final CurvedAnimation _curvedAnimation;

  @override
  void initState() {
    super.initState();
    _curvedAnimation = CurvedAnimation(
      parent: widget.liftAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _curvedAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 动态获取卡片尺寸，fallback 到 GridView 的默认计算
    final double overlayWidth = widget.cardSize?.width ?? 240.0;
    final double overlayHeight = widget.cardSize?.height ?? (240.0 / 0.60);

    return Positioned(
      left: widget.dragPosition.dx - widget.dragAnchor.dx,
      top: widget.dragPosition.dy - widget.dragAnchor.dy,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _curvedAnimation,
          builder: (context, child) {
            final t = _curvedAnimation.value;
            final scale = 1.02 + 0.03 * t;

            return Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: Opacity(
                opacity: 0.95,
                child: Container(
                  width: overlayWidth,
                  height: overlayHeight,
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: AppColors.selectedAccent, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x668B7355),
                        offset: Offset(8 * t, 12 * t),
                        blurRadius: 20 + 15 * t,
                        spreadRadius: 3 * t,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2 * t),
                        offset: Offset(4 * t, 6 * t),
                        blurRadius: 10 + 5 * t,
                      ),
                    ],
                    color: AppColors.background,
                  ),
                  child: _buildCardContent(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCardContent() {
    // UX-34: 使用预缓存的 coverPath，不再在 build 中做同步 I/O
    final path = widget.coverPath;
    Widget content;
    if (path != null && path.isNotEmpty) {
      content = Image.file(
        File(path),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    } else {
      content = _buildPlaceholder();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: content),
              if (widget.isMarked)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    Icons.star_rounded,
                    size: 20,
                    color: AppColors.starGold,
                    shadows: [
                      Shadow(
                          color: Colors.white.withOpacity(0.8), blurRadius: 2),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 22,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              widget.game.title.isNotEmpty ? widget.game.title : '未命名游戏',
              style: AppStyles.gameTitle.copyWith(fontSize: 18),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (widget.game.developer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              widget.game.developer,
              style: TextStyle(
                fontFamily: 'Inter',
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
    );
  }

  Widget _buildPlaceholder() {
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
}
