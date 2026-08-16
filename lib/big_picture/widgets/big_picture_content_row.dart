import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../services/local_game_registry.dart';
import '../big_picture_theme.dart';
import 'big_picture_game_card.dart';

/// BPM 水平滚动内容行
///
/// 用于首页展示"最近游玩"、"我的收藏"、"全部游戏"等内容分类。
/// 每行包含一个标题 + "查看全部"按钮 + 横向滚动的 [BigPictureGameCard] 列表。
///
/// 焦点策略:
/// - 左右方向键在卡片间切换 (由 FocusTraversalGroup 自动处理)
/// - 焦点到达边缘时自动滚动到对应卡片
class BigPictureContentRow extends StatefulWidget {
  /// 行标题 (如 "最近游玩")
  final String title;

  /// 游戏列表
  final List<LibraryGame> games;

  /// 单击游戏卡片回调 (通常打开详情页)
  final ValueChanged<LibraryGame> onGameTap;

  /// 双击游戏卡片回调 (通常启动游戏)
  final ValueChanged<LibraryGame> onGameDoubleTap;

  /// 长按游戏卡片回调 (通常弹出动作表)
  final ValueChanged<LibraryGame>? onGameLongPress;

  /// "查看全部"按钮回调 (可选,不提供则不显示按钮)
  final VoidCallback? onViewAll;

  const BigPictureContentRow({
    super.key,
    required this.title,
    required this.games,
    required this.onGameTap,
    required this.onGameDoubleTap,
    this.onGameLongPress,
    this.onViewAll,
  });

  @override
  State<BigPictureContentRow> createState() => _BigPictureContentRowState();
}

class _BigPictureContentRowState extends State<BigPictureContentRow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: BigPictureTheme.sectionSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BigPictureTheme.pagePadding,
            ),
            child: Row(
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.titleFontSize,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${widget.games.length}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: BigPictureTheme.bodyFontSize,
                    color: AppColors.secondaryText,
                  ),
                ),
                const Spacer(),
                if (widget.onViewAll != null) _buildViewAllButton(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 横向滚动卡片列表
          SizedBox(
            height: BigPictureTheme.cardHeight + 16, // 留出焦点缩放空间
            child: ListView.separated(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: BigPictureTheme.pagePadding,
              ),
              itemCount: widget.games.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: BigPictureTheme.cardSpacing),
              itemBuilder: (context, index) {
                final game = widget.games[index];
                return BigPictureGameCard(
                  game: game,
                  onTap: () => widget.onGameTap(game),
                  onDoubleTap: () => widget.onGameDoubleTap(game),
                  onLongPress: widget.onGameLongPress != null
                      ? () => widget.onGameLongPress!(game)
                      : null,
                  autofocus: index == 0,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewAllButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onViewAll,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            border: Border.all(
              color: AppColors.border,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '查看全部',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.labelFontSize,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.secondaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
