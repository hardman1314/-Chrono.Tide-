import 'package:flutter/material.dart';

import '../models/series_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../theme/app_breakpoints.dart';
import 'explore_hall/hall_cover_image.dart';
import 'explore_hall/hall_visuals.dart' show HallHScroll;
import 'interactive_wrapper.dart';

/// 系列内跳转回调：目标游戏 id / 标题 / 封面 URL
typedef SeriesGameNavigate = void Function(
    String gameId, String title, String coverUrl);

/// 探索详情页的「系列框」速览组件（轻量版 · 只显示与当前作品相关的条目）
///
/// 设计目标：轻量、紧凑、把纵向空间还给截图区——
/// - 无外框容器：一条细分割线 + 极简头部行，不与截图/安装区争夺视觉重量
/// - 只展示与当前作品**最密切**的条目（选取规则见
///   [SeriesData.relatedSelection]：紧邻前作 → 当前 → 紧邻续作 → 直接分支，
///   不足 3 部自动放宽补足），非全系列铺开
/// - **单行横版拖动列表**（2026-10-05 依反馈改版）：探索大厅系列栏目同款
///   [HallHScroll] 鼠标拖动滚动的横向单行列表；横版作品卡（左封面缩略 +
///   右侧作品名主行 + 定位角标 + 发售日期），当前作品强调描边；
///   尾部「+N 更多作品」格引导打开完整系列弹层
/// - 纵向占比（与详情页右栏配合）：截图区 ≈ 2/3，系列框 ≈ 1/3
/// compact 窄窗口下降级为单行入口按钮。
class SeriesStrip extends StatelessWidget {
  final SeriesData seriesData;
  final String currentGameId;
  final SeriesGameNavigate onNavigateToGame;
  final VoidCallback onOpenPanel;

  /// 横版卡尺寸与间距
  static const double _cardHeight = 76;
  static const double _cardWidth = 210;
  static const double _coverWidth = 56;
  static const double _itemGap = 10;

  const SeriesStrip({
    super.key,
    required this.seriesData,
    required this.currentGameId,
    required this.onNavigateToGame,
    required this.onOpenPanel,
  });

  @override
  Widget build(BuildContext context) {
    // compact 窄窗口：空间不足，降级为单行入口
    if (AppBreakpoints.isCompact(context)) {
      return _buildCompactEntry();
    }
    return _buildFullStrip();
  }

  /// 头部措辞：tree=系列 / collection=合集
  String get _collectionWord =>
      seriesData.isCollectionMode ? '合集' : '系列';

  /// compact 降级：单行"查看系列"入口按钮
  Widget _buildCompactEntry() {
    return InteractiveWrapper(
      onTap: onOpenPanel,
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: AppColors.border,
                offset: const Offset(2, 3),
                blurRadius: 0),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_rounded,
                size: 15, color: AppColors.secondaryText.withOpacity(0.7)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${seriesData.series.title} $_collectionWord · ${seriesData.entries.length} 部作品',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppStyles.bodyRegular.copyWith(
                    fontSize: 13,
                    color: AppColors.secondaryText.withOpacity(0.85)),
              ),
            ),
            const SizedBox(width: 8),
            Text('查看系列',
                style: AppStyles.bodyRegular
                    .copyWith(fontSize: 13, color: AppColors.primaryText)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColors.secondaryText.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  /// 完整系列框：极简头部行 + 细分割线 + 横版卡片网格（2 列 × 最多 2 行）
  Widget _buildFullStrip() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部行：系列名（左） + 完整系列入口（右）
          Row(
            children: [
              Icon(Icons.auto_stories_rounded,
                  size: 14, color: AppColors.secondaryText.withOpacity(0.55)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${seriesData.series.title} $_collectionWord · ${seriesData.entries.length} 部作品',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.bodyRegular.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText.withOpacity(0.9)),
                ),
              ),
              const SizedBox(width: 12),
              InteractiveWrapper(
                onTap: onOpenPanel,
                hoverScale: 1.0,
                hoverOffset: const Offset(0, -1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('完整系列',
                        style: AppStyles.bodyRegular.copyWith(
                            fontSize: 12,
                            color:
                                AppColors.secondaryText.withOpacity(0.75))),
                    Icon(Icons.chevron_right_rounded,
                        size: 14,
                        color: AppColors.secondaryText.withOpacity(0.55)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 细分割线：与上方截图区做轻量区隔
          Container(height: 1, color: AppColors.border.withOpacity(0.25)),
          const SizedBox(height: 10),
          // 相关条目单行拖动滚动列表（大厅系列栏目同款 HallHScroll；
          // 全部相关条目入列，尾部「+N」格引导完整系列弹层）
          LayoutBuilder(builder: (context, constraints) {
            final picks = seriesData.relatedSelection(currentGameId);
            if (picks.isEmpty) return const SizedBox.shrink();
            // 空闲宽度能放下几张就用几张，超出的靠鼠标拖动滚动查看
            final visibleCount = ((constraints.maxWidth + _itemGap) /
                    (_cardWidth + _itemGap))
                .floor()
                .clamp(1, picks.length);
            final remaining = seriesData.entries.length - picks.length;
            return SizedBox(
              height: _cardHeight,
              child: HallHScroll(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  itemCount: visibleCount + (remaining > 0 ? 1 : 0),
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: _itemGap),
                  itemBuilder: (context, i) {
                    if (i < visibleCount) return _buildCard(picks[i]);
                    return _buildMoreIndicator(remaining);
                  },
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// 横版作品卡：左封面缩略 + 右侧「作品名 + 定位角标 + 发售日期」
  Widget _buildCard(RelatedPick item) {
    final entry = item.entry;
    final date = entry.releaseDate;
    return Tooltip(
      message: entry.gameTitle,
      waitDuration: const Duration(milliseconds: 300),
      child: InteractiveWrapper(
        onTap: item.isCurrent
            ? null
            : () => onNavigateToGame(
                entry.gameId, entry.gameTitle, entry.gameCoverUrl),
        hoverScale: item.isCurrent ? 1.0 : 1.02,
        hoverOffset: const Offset(0, -1),
        child: Container(
          width: _cardWidth,
          height: _cardHeight,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: item.isCurrent
                ? AppColors.navActiveBg
                : AppColors.buttonBackground,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: item.isCurrent
                  ? AppColors.selectedAccent
                  : AppColors.border,
              width: item.isCurrent ? 2 : 1.5,
            ),
          ),
          child: Row(
            children: [
              // 左：封面缩略（高度撑满）
              SizedBox(
                width: _coverWidth,
                height: _cardHeight,
                child: HallCoverImage(networkUrl: entry.gameCoverUrl),
              ),
              // 右：作品名（主）+ 定位角标 + 发售日期
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.gameTitle.isNotEmpty ? entry.gameTitle : '未知作品',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppStyles.bodyRegular.copyWith(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryText),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          // 定位角标：当前作品实心强调，其余描边弱化
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: item.isCurrent
                                  ? AppColors.selectedAccent
                                  : Colors.transparent,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.xs),
                              border: Border.all(
                                color: item.isCurrent
                                    ? AppColors.selectedAccent
                                    : AppColors.border,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              item.badge,
                              style: AppStyles.bodyRegular.copyWith(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: item.isCurrent
                                      ? AppColors.primaryText
                                      : AppColors.secondaryText
                                          .withOpacity(0.85)),
                            ),
                          ),
                          if (date.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                date,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppStyles.bodyRegular.copyWith(
                                    fontSize: 10,
                                    color: AppColors.secondaryText
                                        .withOpacity(0.6)),
                              ),
                            ),
                          ],
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
    );
  }

  /// 「+N」收尾格：与作品卡同尺寸，引导打开完整系列弹层
  Widget _buildMoreIndicator(int remaining) {
    return InteractiveWrapper(
      onTap: onOpenPanel,
      hoverScale: 1.02,
      hoverOffset: Offset.zero,
      child: Container(
        width: _cardWidth,
        height: _cardHeight,
        decoration: BoxDecoration(
          color: AppColors.placeholderCover.withOpacity(0.4),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border:
              Border.all(color: AppColors.border.withOpacity(0.7), width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '+$remaining',
              style: AppStyles.bodyRegular.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.secondaryText.withOpacity(0.75)),
            ),
            const SizedBox(height: 1),
            Text(
              '更多作品',
              style: AppStyles.bodyRegular.copyWith(
                  fontSize: 10,
                  color: AppColors.secondaryText.withOpacity(0.65)),
            ),
          ],
        ),
      ),
    );
  }
}
