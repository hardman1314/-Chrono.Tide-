import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/portable_image_cache_manager.dart';
import '../join_controller.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/cover_preview_overlay.dart';
import '../../../widgets/nsfw/nsfw_image.dart';
import '../../../theme/app_colors.dart';
import 'ct_library_picker_dialog.dart';
import 'metadata_source_settings_dialog.dart';
import 'platform_badge.dart';

class MetadataSection extends StatelessWidget {
  final JoinController controller;

  const MetadataSection({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // 设计稿「Section - 元数据匹配」664×206，边框 1.48
      height: 206,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.border,
            offset: const Offset(4, 5),
            blurRadius: 0,
          )
        ],
        borderRadius: BorderRadius.circular(0),
      ),
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 5),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.shadowColor,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 16, color: AppColors.border),
                    const SizedBox(width: 6),
                    Text(
                      '元数据匹配',
                      style: TextStyle(
                        fontSize: 16,
                        letterSpacing: 2.0,
                        color: AppColors.border,
                      ),
                    ),
                  ],
                ),
                // 按钮组：相册（数量徽章）+ 齿轮设定 + 一键抓取
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ★ 2026-10-05 相册入口：预览选中结果的竖版+横幅封面，
                    //   左侧数字 = 已抓取到的封面图数量（0 张禁用）
                    _buildGalleryEntry(context),
                    const SizedBox(width: 6),
                    // 齿轮设定按钮（左侧）：弹出数据源选择弹窗
                    Tooltip(
                      message: '抓取数据源设定',
                      waitDuration: const Duration(milliseconds: 500),
                      child: InteractiveWrapper(
                        onTap: () => showMetadataSourceSettingsDialog(context),
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          // 设计稿「Button - 元数据设置」25×25，边框 0.74
                          padding: const EdgeInsets.all(4.5),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            border:
                                Border.all(color: AppColors.border, width: 0.8),
                          ),
                          child: Icon(
                            Icons.settings,
                            size: 14,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // CT 探索库入口（2026-10-05）：浏览自有云端元数据平台的
                    // 全部作品（支持搜索），选中后直接导入左侧数据板块
                    Tooltip(
                      message: 'CT 探索库：浏览社区共建的中文元数据作品',
                      waitDuration: const Duration(milliseconds: 500),
                      child: InteractiveWrapper(
                        onTap: () =>
                            showCtLibraryPickerDialog(context, controller),
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4.5),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            border: Border.all(
                                color: AppColors.border, width: 0.8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.travel_explore,
                                size: 14,
                                color: AppColors.secondaryText,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'CT 探索库',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 一键抓取按钮（右侧）
                    InteractiveWrapper(
                      onTap: controller.isScraping
                          ? null
                          : () => controller.fetchScrapeData(),
                      cursor: controller.isScraping
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.click,
                      child: Container(
                        // 设计稿「一键抓取」按钮 77×30（文字 4 字×12px + ls1
                        // ≈51px，左右各 13 → 77；行高 ≈17 + 上下各 6 → 29）
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          border: Border.all(color: AppColors.border, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.border.withOpacity(0.4),
                              offset: const Offset(2, 3),
                              blurRadius: 0,
                            )
                          ],
                        ),
                        child: controller.isScraping
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white),
                                    ),
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    '抓取中...',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1.0,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                '一键抓取',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.0,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: controller.scrapeResults.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    // 自适应多列：按可用宽度计算列数（单卡最小约 250px），
                    // 窄窗 2 列、宽窗 3 列，避免原 `屏宽*0.45` 公式导致一行仅一张。
                    // 卡片宽度基于板块实际可用内宽，而非整屏宽度。
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const gap = 12.0;
                        const minCardWidth = 250.0;
                        final available = constraints.maxWidth;
                        final columns = (available / (minCardWidth + gap))
                            .floor()
                            .clamp(1, 8);
                        final cardWidth =
                            (available - gap * (columns - 1)) / columns;
                        // 卡片 hover 反馈：
                        // MetadataCard 的 InteractiveWrapper 已关闭 hoverScale（1.0）
                        // 和 hoverOffset（zero），仅保留 cursor 变化和 press 缩放作为
                        // 交互反馈，从源头消除 transform 溢出，无需 Clip.none
                        return SingleChildScrollView(
                          child: Wrap(
                            spacing: gap,
                            runSpacing: gap,
                            children: controller.scrapeResults
                                .map((result) => SizedBox(
                                      width: cardWidth,
                                      child: MetadataCard(
                                          result: result,
                                          controller: controller),
                                    ))
                                .toList(),
                          ),
                        );
                      },
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// 相册入口（2026-10-05）：左侧数字 = 选中结果已抓取到的封面图数量
  /// （竖版 cover_url + 横幅 banner_url），点击打开竖/横双类型预览浮层。
  /// 未选中结果或 0 张时禁用。
  Widget _buildGalleryEntry(BuildContext context) {
    final sel = controller.selectedResult;
    final items = <CoverPreviewItem>[];
    if (sel != null) {
      final cover = sel['cover_url']?.toString() ?? '';
      if (cover.startsWith('http')) {
        items.add(CoverPreviewItem(url: cover, label: '竖屏封面'));
      }
      final banner = sel['banner_url']?.toString() ?? '';
      if (banner.startsWith('http')) {
        items.add(CoverPreviewItem(url: banner, label: '横幅封面'));
      }
    }
    final count = items.length;
    final enabled = count > 0;

    return Tooltip(
      message: enabled
          ? '相册：查看已抓取的 $count 张封面（竖版/横幅）'
          : '相册：先选择一个抓取结果',
      waitDuration: const Duration(milliseconds: 500),
      child: InteractiveWrapper(
        onTap: enabled
            ? () => showGeneralDialog(
                  context: context,
                  barrierDismissible: false,
                  barrierColor: Colors.transparent,
                  barrierLabel: '封面预览',
                  pageBuilder: (_, __, ___) => CoverPreviewOverlay(
                    gameTitle: sel?['game_name']?.toString() ?? '',
                    items: items,
                  ),
                )
            : null,
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: enabled ? AppColors.border : AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.photo_library_outlined,
                size: 14,
                color:
                    enabled ? AppColors.secondaryText : AppColors.borderLight,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MetadataCard extends StatelessWidget {
  final Map<String, dynamic> result;
  final JoinController controller;

  const MetadataCard({
    super.key,
    required this.result,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = controller.selectedResult == result;
    final title = result['game_name'] ?? '未知游戏';
    final platform = result['platform'] ?? 'Bangumi';
    final platformId = result['platform_id'] ?? '';
    final releaseDate = result['release_date'] ?? '';

    // 平台徽章：复用共享 resolvePlatformBadge（含 7 平台颜色/标签/Tooltip）
    final badge = resolvePlatformBadge(platform);

    return InteractiveWrapper(
      onTap: () => controller.selectScrapeResult(result),
      hoverScale: 1.0,
      hoverOffset: Offset.zero,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(
            color: AppColors.border,
            width: isSelected ? 2.5 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? AppColors.border.withOpacity(0.5)
                  : AppColors.borderLight,
              offset: const Offset(2, 3),
              blurRadius: 0,
            )
          ],
        ),
        padding: const EdgeInsets.all(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 62,
              decoration: BoxDecoration(
                color: AppColors.placeholderCover,
                border: Border.all(color: AppColors.border, width: 1.5),
              ),
              clipBehavior: Clip.hardEdge,
              child: _buildCoverImage(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        // UX-20: 平台徽章（含 Tooltip，hover 显示平台说明）
                        PlatformBadgeWidget(badge: badge),
                        const SizedBox(width: 6),
                        // Flexible 包裹：长 ID 单行省略，避免撑爆窄卡
                        Flexible(
                          child: Text(
                            platformId,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleBrown,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      releaseDate.isNotEmpty ? '$releaseDate发行' : '—',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.secondaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverImage() {
    final coverUrl = result['cover_url'];

    if (coverUrl != null &&
        coverUrl.toString().isNotEmpty &&
        coverUrl.toString().startsWith('http')) {
      // 刮削结果预览：URL 渲染，缓存落盘后按需补检（§7.1 风险🟠4）
      return NsfwImage.network(
        coverUrl.toString(),
        contentKind: NsfwContentKind.cover,
        width: 46,
        height: 62,
        detectOnDemand: true,
        child: CachedNetworkImage(
          cacheManager: PortableImageCacheManager(),
          imageUrl: coverUrl.toString(),
          width: 46,
          height: 62,
          fit: BoxFit.cover,
          placeholder: (context, url) => Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
            ),
          ),
          errorWidget: (context, url, error) => Center(
            child: Icon(Icons.image_outlined, size: 14, color: AppColors.border),
          ),
          memCacheWidth: 92,
          memCacheHeight: 124,
        ),
      );
    } else {
      return Center(
        child: Icon(Icons.image_outlined, size: 16, color: AppColors.border),
      );
    }
  }
}
