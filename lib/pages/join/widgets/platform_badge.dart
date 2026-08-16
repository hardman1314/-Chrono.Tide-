import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';

/// 元数据平台徽章信息
///
/// 描述一个元数据来源平台在 UI 上的视觉表现：
/// - [color] 徽章背景色
/// - [label] 徽章显示文字（如 'VNDB'）
/// - [tooltip] hover 提示说明（如 'VNDB：视觉小说数据库'）
class PlatformBadge {
  final Color color;
  final String label;
  final String tooltip;
  const PlatformBadge({
    required this.color,
    required this.label,
    required this.tooltip,
  });
}

/// 根据元数据 platform 字段返回徽章信息（大小写不敏感）
///
/// 复用自原 `metadata_section.dart:196-240` 的多平台判定逻辑，
/// 供 [MetadataCard] 与 [BatchGameCard] 共享，避免重复实现。
///
/// 平台字段值来源于 `metadata_fetcher.dart:_convertToLegacyFormat`
/// 的 `'platform': game.sourceType.displayName`，值为
/// 'Bangumi'/'VNDB'/'月幕GAL'/'Steam'/'DLsite'/'ErogameScape'/'TouchGal'。
///
/// **关键修复**：原 `batch_import_section.dart:486` 用 `platform == 'vndb'`
/// 小写比较，但 displayName 返回 'VNDB' 大写，导致永远 false → 固定显示
/// 'Bangumi'。此处统一用 toLowerCase() 大小写不敏感匹配。
PlatformBadge resolvePlatformBadge(dynamic platform) {
  final platformLower = platform?.toString().toLowerCase() ?? '';

  if (platformLower == 'bangumi') {
    return PlatformBadge(
      color: AppColors.dangerRed.withOpacity(0.7),
      label: 'Bangumi',
      tooltip: 'Bangumi：日本 ACG 资料库',
    );
  } else if (platformLower == 'vndb') {
    return const PlatformBadge(
      color: Color(0xFF4A72A5),
      label: 'VNDB',
      tooltip: 'VNDB：视觉小说数据库',
    );
  } else if (platformLower == 'steam') {
    return const PlatformBadge(
      color: Color(0xFF1b2838),
      label: 'Steam',
      tooltip: 'Steam：Valve 游戏平台',
    );
  } else if (platform == '月幕GAL' || platformLower == 'ymgal') {
    return PlatformBadge(
      color: AppColors.successGreen,
      label: '月幕GAL',
      tooltip: '月幕 GAL：中文 GALGAME 社区',
    );
  } else if (platformLower == 'dlsite') {
    return const PlatformBadge(
      color: Color(0xFF7AB8C0),
      label: 'DLsite',
      tooltip: 'DLsite：日本同人作品销售平台',
    );
  } else if (platformLower == 'erogamescape') {
    return const PlatformBadge(
      color: Color(0xFFB8860B),
      label: 'ErogameScape',
      tooltip: 'ErogameScape：日本美少女游戏数据库',
    );
  } else if (platformLower == 'touchgal') {
    return const PlatformBadge(
      color: Color(0xFF9C6ADE),
      label: 'TouchGal',
      tooltip: 'TouchGal：中文 Calgame 数据库',
    );
  } else {
    // 未知平台：用 border 色降级，避免空白
    return PlatformBadge(
      color: AppColors.border,
      label: platform?.toString() ?? '未知',
      tooltip: platform?.toString() ?? '未知',
    );
  }
}

/// 平台徽章 Widget（带 Tooltip）
///
/// 统一封装平台徽章的视觉呈现：圆角矩形 + 白色加粗文字 +
/// hover 显示平台说明 Tooltip（waitDuration 300ms，对齐原行为）。
class PlatformBadgeWidget extends StatelessWidget {
  final PlatformBadge badge;
  const PlatformBadgeWidget({super.key, required this.badge});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: badge.tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: badge.color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          badge.label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
