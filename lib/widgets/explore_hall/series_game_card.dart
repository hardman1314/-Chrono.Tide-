import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../interactive_wrapper.dart';
import 'hall_cover_image.dart';
import 'hall_visuals.dart';

/// 系列作品统一卡片（探索大厅系列栏目 `_SeriesChip` 同款风格）
///
/// 全幅封面 + 底部渐变信息栏（作品名 + 发售日期）+ 左上角定位胶囊角标；
/// 当前作品：强调色描边 + 右上角「当前」胶囊。
///
/// 三处共用保证风格统一：
/// - 探索详情页「系列相关」速览条（series_strip.dart）
/// - 完整系列面板合集网格（series_panel.dart）
/// - （详情页树模式节点卡保留横向行布局，仅对齐徽章与信息字段）
class SeriesGameCard extends StatelessWidget {
  final String title;
  final String coverUrl;

  /// 发售日期（可空；有值时显示在信息栏第二行）
  final String releaseDate;

  /// 系列定位标签（''=不显示角标，如合集模式）
  final String badge;
  final bool isCurrent;
  final double width;

  /// null = 不可点（当前作品 / 纯展示）
  final VoidCallback? onTap;

  /// 封面宽高比（真实封面 0.7 宽高比）
  static const double coverAspect = 0.7;

  const SeriesGameCard({
    super.key,
    required this.title,
    this.coverUrl = '',
    this.releaseDate = '',
    this.badge = '',
    this.isCurrent = false,
    required this.width,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final height = width / coverAspect;
    final card = SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            HallCoverImage(networkUrl: coverUrl),
            // 底部渐变信息栏（白字在深浅主题的封面上都要暗底，同 _SeriesChip）
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: HallGradients.coverScrim),
                child: SizedBox(height: 30),
              ),
            ),
            Positioned(
              left: 7,
              right: 6,
              bottom: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (releaseDate.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      releaseDate,
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 8.5,
                        height: 1,
                        color: Colors.white.withOpacity(0.72),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // 左上角：该作品的系列定位（主线①/FD/外传/重制版…）
            if (badge.isNotEmpty)
              Positioned(
                left: 5,
                top: 5,
                child: _pill(badge,
                    background: Colors.black.withOpacity(0.55)),
              ),
            // 右上角：「当前」标记（与定位角标分居两侧互不遮挡）
            if (isCurrent)
              Positioned(
                right: 5,
                top: 5,
                child:
                    _pill('当前', background: AppColors.selectedAccent),
              ),
          ],
        ),
      ),
    );

    // 当前作品：强调色描边（画在 ClipRRect 外层，圆角对齐不被裁切）
    return InteractiveWrapper(
      onTap: onTap,
      hoverScale: onTap == null ? 1.0 : 1.03,
      child: Container(
        decoration: isCurrent
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border:
                    Border.all(color: AppColors.selectedAccent, width: 2),
              )
            : null,
        child: card,
      ),
    );
  }

  /// 胶囊角标（与 _SeriesChip 左上角「系列/合集」同款）
  Widget _pill(String text, {required Color background}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 8.5,
          height: 1,
          color: Colors.white,
        ),
      ),
    );
  }
}
