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
          opacity: 0.57,
          child: Text(
            '正 在 解 压',
            style: TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 30,
              letterSpacing: 2.0,
              color: const Color(0xFF8B7355),
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
                style: const TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 16,
                  height: 24 / 16,
                  color: Color(0xFF5C4A3D),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${(extractProgress * 100).toInt()}%',
              style: const TextStyle(
                fontFamily: 'Mali',
                fontSize: 24,
                height: 32 / 24,
                letterSpacing: 1.2,
                color: Color(0xFF5C4A3D),
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