import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/portable_image_cache_manager.dart';
import '../../pages/join/join_controller.dart';
import '../../theme/app_colors.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 风格元数据展示区 (v1.2 新增)
///
/// 包装桌面 [MetadataSection] 的抓取结果展示逻辑,替换交互层为 [BpmInteractiveWrapper],
/// 应用 BPM 视觉规范 (大字号、统一颜色、可配置高度)。
///
/// 复用 [JoinController] API:
/// - [JoinController.scrapeResults] / [JoinController.selectedResult]
/// - [JoinController.selectScrapeResult]
/// - [JoinController.isScraping]
class BpmMetadataSection extends StatelessWidget {
  final JoinController controller;

  /// 列表高度 (默认 320,适配 BPM 大屏)
  final double height;

  const BpmMetadataSection({
    super.key,
    required this.controller,
    this.height = 320,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: controller.scrapeResults.isEmpty
          ? Center(
              child: Text(
                controller.isScraping ? '抓取中...' : '暂无抓取结果',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: BigPictureTheme.bodyFontSize,
                  color: AppColors.placeholderText,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
              child: Wrap(
                spacing: BigPictureTheme.widgetPadding,
                runSpacing: BigPictureTheme.widgetPadding,
                children: controller.scrapeResults
                    .map((result) => _BpmMetadataCard(
                          result: result,
                          controller: controller,
                        ))
                    .toList(),
              ),
            ),
    );
  }
}

/// BPM 风格元数据结果卡片
class _BpmMetadataCard extends StatelessWidget {
  final Map<String, dynamic> result;
  final JoinController controller;

  const _BpmMetadataCard({
    required this.result,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = controller.selectedResult == result;
    final title = result['game_name'] ?? '未知游戏';
    final platform = result['platform'] ?? 'Bangumi';
    final releaseDate = result['release_date'] ?? '';
    final coverUrl = result['cover_url'] as String?;

    final (platformColor, platformLabel) = _getPlatformInfo(platform);

    return BpmInteractiveWrapper(
      onTap: () => controller.selectScrapeResult(result),
      autofocus: isSelected,
      semanticsLabel: '$title ($platformLabel)',
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.selectedAccent.withOpacity(0.08)
              : AppColors.buttonBackground,
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
          border: Border.all(
            color: isSelected ? AppColors.selectedAccent : AppColors.border,
            width: 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面缩略图
            Container(
              width: 56,
              height: 73,
              decoration: BoxDecoration(
                color: AppColors.placeholderCover,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.border, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: _buildCoverImage(coverUrl),
            ),
            const SizedBox(width: 12),
            // 信息区
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 平台徽章
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: platformColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      platformLabel,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: BigPictureTheme.labelFontSize,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 游戏名
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: BigPictureTheme.bodyFontSize,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryText,
                    ),
                  ),
                  if (releaseDate.toString().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      releaseDate.toString(),
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: BigPictureTheme.labelFontSize,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 选中标记
            if (isSelected)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: AppColors.selectedAccent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverImage(String? coverUrl) {
    if (coverUrl != null && coverUrl.isNotEmpty) {
      // 本地路径
      if (File(coverUrl).existsSync()) {
        return Image.file(
          File(coverUrl),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        );
      }
      // 网络图片
      return CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildPlaceholder(),
        errorWidget: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.placeholderCover,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 20,
        color: AppColors.secondaryText.withOpacity(0.5),
      ),
    );
  }

  (Color, String) _getPlatformInfo(dynamic platform) {
    final platformLower = platform.toString().toLowerCase();
    if (platformLower == 'bangumi') {
      return (AppColors.dangerRed.withOpacity(0.7), 'Bangumi');
    } else if (platformLower == 'vndb') {
      return (const Color(0xFF4A72A5), 'VNDB');
    } else if (platformLower == 'steam') {
      return (const Color(0xFF1b2838), 'Steam');
    } else if (platform == '月幕GAL' || platformLower == 'ymgal') {
      return (AppColors.successGreen, '月幕GAL');
    } else if (platformLower == 'dlsite') {
      return (const Color(0xFF7AB8C0), 'DLsite');
    } else if (platformLower == 'erogamescape') {
      return (const Color(0xFFB8860B), 'ErogameScape');
    } else if (platformLower == 'touchgal') {
      return (const Color(0xFF9C6ADE), 'TouchGal');
    }
    return (AppColors.border, platform.toString());
  }
}
