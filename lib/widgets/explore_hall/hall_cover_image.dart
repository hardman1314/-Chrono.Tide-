import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../nsfw/nsfw_image.dart';

/// 探索大厅统一封面渲染：
/// - 本地文件（本地库随机一作）→ Image.file + errorBuilder 兜底
/// - 云端 URL → NsfwImage.network 装饰 CachedNetworkImage（纯净模式打码，
///   contentKind: cover 与探索页封面口径一致，见 nsfw_image.dart §4.5）
/// - 空值 → 占位图
class HallCoverImage extends StatelessWidget {
  /// 云端封面完整 URL（可空）
  final String networkUrl;

  /// 本地封面文件路径（本地库游戏用，可空）
  final String? filePath;
  final BoxFit fit;
  final double? width;
  final double? height;

  const HallCoverImage({
    super.key,
    this.networkUrl = '',
    this.filePath,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final path = filePath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: fit,
        width: width,
        height: height,
        cacheWidth: 200,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    if (networkUrl.isEmpty) return _placeholder();
    return NsfwImage.network(
      networkUrl,
      contentKind: NsfwContentKind.cover,
      fit: fit,
      width: width,
      height: height,
      child: CachedNetworkImage(
        imageUrl: networkUrl,
        fit: fit,
        memCacheWidth: 200,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) => _placeholder(),
      ),
    );
  }

  Widget _placeholder() => Container(
        width: width,
        height: height,
        color: AppColors.placeholderCover,
        alignment: Alignment.center,
        child: Icon(
          Icons.sports_esports_rounded,
          size: 16,
          color: AppColors.secondaryText,
        ),
      );
}
