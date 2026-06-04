import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class DownloadProgressBar extends StatelessWidget {
  final double progress;
  final Color fillColor;
  final double width;

  const DownloadProgressBar({
    super.key,
    required this.progress,
    this.fillColor = const Color(0xFFB4D4FF),
    this.width = 465,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Container(
        height: 21,
        decoration: BoxDecoration(
          color: const Color(0xFFF0E6D2),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
              color: const Color(0x1A8B7355),
              offset: const Offset(0, 2),
              blurRadius: 4,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              alignment: Alignment.centerLeft,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: AppColors.border, width: 2),
                  ),
                  color: AppColors.selectedBlue,
                ),
                child: CustomPaint(
                  painter: _StripedPainter(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ExtractSubBar extends StatelessWidget {
  final double progress;
  final double width;

  const ExtractSubBar({
    super.key,
    required this.progress,
    this.width = 465,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Container(
        height: 5,
        decoration: BoxDecoration(
          color: const Color(0xFFF0E6D2),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
              color: const Color(0x0D8B7355),
              offset: const Offset(0, 1),
              blurRadius: 2,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(
              height: 5,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: const Color(0xFFF6D04D),
              ),
              child: CustomPaint(
                painter: _YellowStripePainter(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StripedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x33FFFFFF);

    final spacing = 16.0;
    final angle = 83.32 * 3.14159 / 180;
    final stripeWidth = size.height * 2.0;

    for (double start = -size.height;
        start < size.width + size.height;
        start += spacing) {
      final path = Path();
      path.moveTo(start, 0);
      path.lineTo(
          start + size.height * (size.height / stripeWidth).clamp(1.0, 3.0),
          size.height);
      path.lineTo(
          start +
              size.height * (size.height / stripeWidth).clamp(1.0, 3.0) +
              stripeWidth,
          size.height);
      path.lineTo(start + stripeWidth, 0);
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _YellowStripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x66FFFFFF);

    final spacing = 8.0;
    var x = -size.height * 0.5;
    while (x < size.width + size.height) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height * 0.8, size.height),
        paint,
      );
      x += spacing;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
