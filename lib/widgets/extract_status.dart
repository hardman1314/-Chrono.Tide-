import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'download_progress_bar.dart';

class ExtractStatus extends StatelessWidget {
  final double downloadProgress;
  final double extractProgress;
  final double speed;

  const ExtractStatus({
    super.key,
    required this.downloadProgress,
    required this.extractProgress,
    this.speed = 19,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          // UX-10: 提高不透明度以改善对比度（原 0.57 导致大字文本对比度不足）
          opacity: 0.85,
          child: Text(
            '正 在 解 压',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 30,
              letterSpacing: 2.0,
              color: AppColors.border,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 465,
          child: _buildProgressBar(),
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: 0.8,
              child: Text(
                '解压速度: ${speed.toInt()} MB/s',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  height: 24 / 16,
                  color: AppColors.titleBrown,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${(extractProgress * 100).toInt()}%',
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 24,
                height: 32 / 24,
                letterSpacing: 1.2,
                color: AppColors.titleBrown,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DownloadProgressBar(progress: downloadProgress),
        const SizedBox(height: 2),
        ExtractSubBar(progress: extractProgress),
      ],
    );
  }
}
