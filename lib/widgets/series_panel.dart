import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../models/series_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import 'animated_overlay.dart';
import 'explore_hall/series_game_card.dart';
import 'interactive_wrapper.dart';
import 'nsfw/nsfw_image.dart';
import 'series_strip.dart' show SeriesGameNavigate;

/// 完整系列弹层面板（Overlay 顶层挂载）
///
/// 展示系列树：主线编号（建议游玩顺序）+ 分支缩进挂在父作品下。
/// 弹层内部自身可滚动（仅此区域），详情页保持单页无滚动。
/// 纯导航设计：点击作品跳转详情页，获取/安装操作留在详情页。
class SeriesPanel extends StatelessWidget {
  final SeriesData seriesData;
  final String currentGameId;
  final SeriesGameNavigate onNavigateToGame;
  final VoidCallback onClose;

  const SeriesPanel({
    super.key,
    required this.seriesData,
    required this.currentGameId,
    required this.onNavigateToGame,
    required this.onClose,
  });

  /// 挂载到根 Overlay（与 SettingsModal 同一套路，确保绘制在所有页面之上）
  static void show(
    BuildContext context, {
    required SeriesData seriesData,
    required String currentGameId,
    required SeriesGameNavigate onNavigateToGame,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    final key = GlobalKey<AnimatedOverlayState>();
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () => entry.remove(),
        child: SeriesPanel(
          seriesData: seriesData,
          currentGameId: currentGameId,
          onNavigateToGame: (gameId, title, coverUrl) {
            key.currentState?.dismiss();
            onNavigateToGame(gameId, title, coverUrl);
          },
          onClose: () => key.currentState?.dismiss(),
        ),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: 640,
          constraints: BoxConstraints(
            maxHeight: (screenHeight - 120).clamp(360.0, 760.0),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 2),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            boxShadow: [
              BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(4, 5),
                  blurRadius: 0),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xl - 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                _buildOrderHint(),
                // 弹层内唯一可滚动区域：系列树
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    child: _buildTree(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 头部：系列封面 + 系列名 + 作品数 + 关闭按钮
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.placeholderCover, width: 2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 系列封面
          Container(
            width: 40,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.placeholderCover,
              border: Border.all(color: AppColors.border, width: 1.5),
            ),
            clipBehavior: Clip.hardEdge,
            child: _buildCoverImage(
                seriesData.series.coverUrl, width: 40, height: 56),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${seriesData.series.title} ${seriesData.isCollectionMode ? '合集' : '系列'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 24,
                      letterSpacing: 3.0,
                      color: AppColors.primaryText),
                ),
                const SizedBox(height: 4),
                Text(
                  '共 ${seriesData.entries.length} 部作品',
                  style: AppStyles.bodyRegular.copyWith(
                      fontSize: 13,
                      color: AppColors.secondaryText.withOpacity(0.8)),
                ),
                // 系列简介（v2 series_meta.description；空值不占位）
                if (seriesData.series.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    seriesData.series.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppStyles.bodyRegular.copyWith(
                        fontSize: 11.5,
                        height: 1.45,
                        color: AppColors.secondaryText.withOpacity(0.65)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _buildCloseButton(),
        ],
      ),
    );
  }

  Widget _buildCloseButton() {
    return InteractiveWrapper(
      onTap: onClose,
      hoverScale: 1.05,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Icon(Icons.close_rounded,
            size: 16, color: AppColors.secondaryText.withOpacity(0.8)),
      ),
    );
  }

  /// 游玩顺序提示行（按模式区分文案）
  Widget _buildOrderHint() {
    final String hint;
    if (seriesData.isCollectionMode) {
      hint = '合集内作品相互独立，无先后依赖，可按任意顺序游玩';
    } else if (seriesData.hasParallelMainlines) {
      hint = '建议游玩顺序：沿主线编号 ① → ② → ③；本系列含多条平行主线，'
          '各条线互相独立，可任选一条开始；分支可在对应本篇之后随时插入';
    } else {
      hint = '建议游玩顺序：沿主线编号 ① → ② → ③；分支可在对应本篇之后随时插入';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(Icons.route_rounded,
              size: 14, color: AppColors.secondaryText.withOpacity(0.6)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hint,
              style: AppStyles.bodyRegular.copyWith(
                  fontSize: 12,
                  color: AppColors.secondaryText.withOpacity(0.75)),
            ),
          ),
        ],
      ),
    );
  }

  /// 系列树：
  /// - collection 模式：作品平铺，无编号无分支（相互独立）
  /// - tree 模式：按链渲染（平行主线各自编号），分支缩进挂在父作品下
  Widget _buildTree() {
    // 合集模式：作品相互独立 → 大厅同款卡片网格平铺
    if (seriesData.isCollectionMode) {
      final ordered = seriesData.displayOrder;
      return Wrap(
        spacing: 8,
        runSpacing: 10,
        children: [
          for (final entry in ordered)
            SeriesGameCard(
              title: entry.gameTitle,
              coverUrl: entry.gameCoverUrl,
              releaseDate: entry.releaseDate,
              // 合集无关系语义，不显示定位角标
              badge: '',
              isCurrent: entry.gameId == currentGameId,
              width: 136,
              onTap: entry.gameId == currentGameId
                  ? null
                  : () => onNavigateToGame(entry.gameId, entry.gameTitle,
                      entry.gameCoverUrl),
            ),
        ],
      );
    }

    // tree 模式：逐链渲染（平行主线编号各自从 ① 开始）
    final children = <Widget>[];
    for (var c = 0; c < seriesData.mainlines.length; c++) {
      final chain = seriesData.mainlines[c];
      // 平行主线分隔提示（首条之前不加）
      if (c > 0) {
        children.add(const SizedBox(height: 10));
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                  child: Container(
                      height: 1,
                      color: AppColors.border.withOpacity(0.4))),
              const SizedBox(width: 10),
              Text('平行主线',
                  style: AppStyles.bodyRegular.copyWith(
                      fontSize: 11,
                      color: AppColors.secondaryText.withOpacity(0.6))),
              const SizedBox(width: 10),
              Expanded(
                  child: Container(
                      height: 1,
                      color: AppColors.border.withOpacity(0.4))),
            ],
          ),
        ));
      }
      for (var i = 0; i < chain.length; i++) {
        final node = chain[i];
        children.add(_buildMainlineNode(node.entry, i + 1));
        if (node.branches.isNotEmpty) {
          children.add(const SizedBox(height: 4));
          children.add(_buildBranchList(node.branches));
        }
        children.add(const SizedBox(height: 6));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 主线节点：编号圆 + 作品卡
  Widget _buildMainlineNode(SeriesEntryModel entry, int number) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.buttonBackground,
            border: Border.all(color: AppColors.border, width: 2),
          ),
          alignment: Alignment.center,
          child: Text(
            '$number',
            style: AppStyles.bodyRegular.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: _buildNodeCard(entry)),
      ],
    );
  }

  /// 分支列表：左侧引导线 + 缩进的分支节点（支持嵌套）
  Widget _buildBranchList(List<SeriesTreeNode> branches) {
    return Padding(
      padding: const EdgeInsets.only(left: 11),
      child: Container(
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
                color: AppColors.border.withOpacity(0.5), width: 2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final branch in branches) ...[
              _buildBranchNode(branch.entry),
              if (branch.branches.isNotEmpty)
                _buildBranchList(branch.branches),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }

  /// 分支节点：拐角箭头 + 作品卡
  Widget _buildBranchNode(SeriesEntryModel entry) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.subdirectory_arrow_right_rounded,
            size: 16, color: AppColors.secondaryText.withOpacity(0.5)),
        const SizedBox(width: 4),
        Expanded(child: _buildNodeCard(entry)),
      ],
    );
  }

  /// 作品卡：大封面 + 标题/发售日期信息栏 + 精确定位徽章 + 当前作品标记
  Widget _buildNodeCard(SeriesEntryModel entry) {
    final isCurrent = entry.gameId == currentGameId;
    return InteractiveWrapper(
      onTap: isCurrent
          ? null
          : () => onNavigateToGame(
              entry.gameId, entry.gameTitle, entry.gameCoverUrl),
      hoverScale: isCurrent ? 1.0 : 1.01,
      hoverOffset: const Offset(0, -1),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent
              ? AppColors.navActiveBg
              : AppColors.buttonBackground,
          border: Border.all(
            color: isCurrent ? AppColors.selectedAccent : AppColors.border,
            width: isCurrent ? 2 : 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 74,
              decoration: BoxDecoration(
                color: AppColors.placeholderCover,
                border: Border.all(color: AppColors.border, width: 1),
              ),
              clipBehavior: Clip.hardEdge,
              child:
                  _buildCoverImage(entry.gameCoverUrl, width: 52, height: 74),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.gameTitle.isNotEmpty ? entry.gameTitle : '未知作品',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppStyles.bodyRegular.copyWith(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primaryText),
                  ),
                  // 发售日期（v2 数据；空值不占位）
                  if (entry.releaseDate.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      entry.releaseDate,
                      style: AppStyles.bodyRegular.copyWith(
                          fontSize: 11,
                          color: AppColors.secondaryText.withOpacity(0.7)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 精确定位徽章：主线类型描边强调，分支类型弱化；
            // 主轴=本篇/续作（v2Relation 空回落枚举），分支=十二值词表标签
            // （正统续作/FD/外传/重制版/同世界观…）；合集模式不显示
            if (!seriesData.isCollectionMode)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: entry.relationType.isMainline
                        ? AppColors.selectedAccent
                        : AppColors.border,
                    width: 1.5,
                  ),
                ),
                child: Text(
                  entry.preciseLabel,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11,
                    color: entry.relationType.isMainline
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText.withOpacity(0.85)),
                ),
              ),
            const SizedBox(width: 8),
            if (isCurrent)
              Text('当前作品',
                  style: AppStyles.bodyRegular.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.selectedAccent))
            else
              Icon(Icons.chevron_right_rounded,
                  size: 16,
                  color: AppColors.secondaryText.withOpacity(0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverImage(String url,
      {required double width, required double height}) {
    if (url.isEmpty || !url.startsWith('http')) {
      return Center(
        child: Icon(Icons.image_outlined,
            size: width * 0.45,
            color: AppColors.secondaryText.withOpacity(0.3)),
      );
    }
    // 系列封面：URL 渲染，缓存落盘后按需补检（§7.1 风险🟠4）
    return NsfwImage.network(
      url,
      contentKind: NsfwContentKind.cover,
      fit: BoxFit.cover,
      detectOnDemand: true,
      child: CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => Center(
          child: Icon(Icons.image_outlined,
              size: width * 0.45,
              color: AppColors.secondaryText.withOpacity(0.3)),
        ),
        errorWidget: (_, __, ___) => Center(
          child: Icon(Icons.broken_image_outlined,
              size: width * 0.4,
              color: AppColors.secondaryText.withOpacity(0.25)),
        ),
      ),
    );
  }
}
