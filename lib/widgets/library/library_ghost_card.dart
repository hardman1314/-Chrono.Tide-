import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../services/local_game_registry.dart';
import '../nsfw/nsfw_image.dart';
import 'collection_badges.dart';

/// UX-13: 从 library_page.dart 抽取的拖拽占位卡片。
///
/// 拖拽期间显示在被拖卡片的原位置，半透明且非交互，
/// 仅作视觉占位。包含封面、游玩状态徽章、星标和标题信息。
class LibraryGhostCard extends StatelessWidget {
  final LibraryGame game;

  /// UX-34: 预缓存的封面路径，避免 build 中的同步 I/O
  final String? coverPath;

  const LibraryGhostCard({
    super.key,
    required this.game,
    this.coverPath,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border, width: 2),
              borderRadius: BorderRadius.circular(4),
              color: AppColors.background,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: game.isBlurred
                        ? ImageFiltered(
                            imageFilter:
                                ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: _buildCoverImage(),
                          )
                        : _buildCoverImage(),
                  ),
                ),
                // 游玩状态标识
                Positioned(
                  bottom: 6,
                  left: 6,
                  child: _buildPlayStatusBadge(game.playStatus),
                ),
                // 收藏夹书签角标（替代原星标）
                if (game.collectionIds.isNotEmpty)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: CollectionBadges(
                      collectionIds: game.collectionIds,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 22,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              game.title.isNotEmpty ? game.title : '未命名游戏',
              style: AppStyles.gameTitle.copyWith(fontSize: 18),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (game.developer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              game.developer,
              style: TextStyle(
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

  Widget _buildPlayStatusBadge(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
                color: AppColors.secondaryText.withOpacity(0.6), width: 1.5),
          ),
        );
      case PlayStatus.inProgress:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 4)
            ],
          ),
        );
      case PlayStatus.dropped:
        return Container(
          padding: EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.9),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.exit_to_app, size: 10, color: Colors.white),
        );
      case PlayStatus.completed:
        return Container(
          padding: EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.starGold,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.emoji_events, size: 12, color: Colors.white),
        );
    }
  }

  /// UX-34: 使用预缓存的 coverPath 构建封面，不再在 build 中做同步 I/O
  /// 性能优化: 添加 cacheWidth/cacheHeight 避免全分辨率解码
  Widget _buildCoverImage() {
    final path = coverPath;
    if (path != null && path.isNotEmpty) {
      return NsfwImage.file(
        path,
        contentKind: NsfwContentKind.cover,
        width: double.infinity,
        height: double.infinity,
        child: Image.file(
          File(path),
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          cacheWidth: 480, // 物理像素: 240px卡片 × 2x DPR
          cacheHeight: 720,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        ),
      );
    }
    return _buildPlaceholder();
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
