import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../join_controller.dart';
import '../../../widgets/interactive_wrapper.dart';

class MetadataSection extends StatelessWidget {
  final JoinController controller;

  const MetadataSection({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 203,
      decoration: BoxDecoration(
        color: const Color(0xFFFDFBF7),
        border: Border.all(color: const Color(0xFF8B7355), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B7355),
            offset: const Offset(4, 5),
            blurRadius: 0,
          )
        ],
        borderRadius: BorderRadius.circular(0),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 11),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF8B7355).withOpacity(0.2),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 18, color: const Color(0xFF8B7355)),
                    const SizedBox(width: 8),
                    Text(
                      '元数据匹配',
                      style: TextStyle(
                        fontFamily: 'Zhi Mang Xing',
                        fontSize: 18,
                        letterSpacing: 2.0,
                        color: const Color(0xFF8B7355),
                      ),
                    ),
                  ],
                ),
                InteractiveWrapper(
                  onTap: controller.isScraping
                      ? null
                      : () => controller.fetchScrapeData(),
                  cursor: controller.isScraping
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B7355),
                      border:
                          Border.all(color: const Color(0xFF8B7355), width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF8B7355).withOpacity(0.4),
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
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                '抓取中...',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            '一键抓取',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.4,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: controller.scrapeResults.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: controller.scrapeResults
                            .map((result) => SizedBox(
                                  width: (MediaQuery.of(context).size.width *
                                          0.45 -
                                      18),
                                  child: MetadataCard(
                                      result: result, controller: controller),
                                ))
                            .toList(),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
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
    final platform = result['platform'] ?? 'bangumi';
    final platformId = result['platform_id'] ?? '';
    final releaseDate = result['release_date'] ?? '';

    final isBangumi = platform == 'bangumi';
    final isVndb = platform == 'vndb';
    final isSteam = platform == 'steam';
    final isYmgal = platform == 'ymgal';

    Color platformColor;
    String platformLabel;

    if (isBangumi) {
      platformColor = const Color(0xFFF27494);
      platformLabel = 'Bangumi';
    } else if (isVndb) {
      platformColor = const Color(0xFF4A72A5);
      platformLabel = 'VNDB';
    } else if (isSteam) {
      platformColor = const Color(0xFF1b2838);
      platformLabel = 'Steam';
    } else if (isYmgal) {
      platformColor = const Color(0xFF4CAF50);
      platformLabel = '月幕GAL';
    } else {
      platformColor = const Color(0xFF8B7355);
      platformLabel = platform.toUpperCase();
    }

    return InteractiveWrapper(
      onTap: () => controller.selectScrapeResult(result),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7),
          border: Border.all(
            color:
                isSelected ? const Color(0xFF8B7355) : const Color(0xFF8B7355),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  const Color(0xFF8B7355).withOpacity(isSelected ? 0.4 : 0.15),
              offset: const Offset(2, 3),
              blurRadius: 0,
            )
          ],
        ),
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 73,
              decoration: BoxDecoration(
                color: const Color(0xFFE9E0D1),
                border: Border.all(color: const Color(0xFF8B7355), width: 2),
              ),
              clipBehavior: Clip.hardEdge,
              child: _buildCoverImage(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: platformColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          platformLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        platformId,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFFA08264),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF5C4A3D),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    releaseDate,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      color: const Color(0xFFA08264),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
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
      return CachedNetworkImage(
        imageUrl: coverUrl.toString(),
        width: 56,
        height: 73,
        fit: BoxFit.cover,
        placeholder: (context, url) => Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF8B7355)),
          ),
        ),
        errorWidget: (context, url, error) => Center(
          child: Icon(Icons.image_outlined,
              size: 16, color: const Color(0xFF8B7355)),
        ),
        memCacheWidth: 112,
        memCacheHeight: 146,
      );
    } else {
      return Center(
        child: Icon(Icons.image_outlined,
            size: 16, color: const Color(0xFF8B7355)),
      );
    }
  }
}
