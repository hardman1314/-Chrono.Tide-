import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'interactive_wrapper.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';

class DownloadButton extends StatelessWidget {
  final void Function()? onTap;
  final bool isDownloading;
  final bool isCompleted;
  final bool isExtracting;
  final ButtonVariant variant;

  const DownloadButton({
    super.key,
    required this.onTap,
    this.isDownloading = false,
    this.isCompleted = false,
    this.isExtracting = false,
    this.variant = ButtonVariant.download,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompleted) {
      return _buildCompletedButtons();
    }

    if (isDownloading || isExtracting) {
      return _buildCancelButton();
    }

    switch (variant) {
      case ButtonVariant.download:
        return _buildDownloadButton();
      case ButtonVariant.openLibrary:
        return _buildOpenLibraryButton();
      case ButtonVariant.retry:
        return _buildRetryButton();
    }
  }

  Widget _buildDownloadButton() {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        width: 218,
        height: 67,
        decoration: BoxDecoration(
          color: const Color(0xFFE6F0FF),
          border: Border.all(color: const Color(0xFF4A72A5), width: 2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A72A5),
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/images/download_btn_icon.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                const Color(0xFF4A72A5),
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 12),
            Text('下 载 游 戏',
                style: AppStyles.heading.copyWith(
                  fontSize: 24,
                  letterSpacing: 2.0,
                  color: const Color(0xFF4A72A5),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildCancelButton() {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        width: 218,
        height: 67,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE6EA),
          border: Border.all(color: AppColors.dangerRed, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.dangerRed,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close_rounded, size: 20, color: AppColors.dangerRed),
            const SizedBox(width: 12),
            Text('取 消 下 载',
                style: AppStyles.heading.copyWith(
                  fontSize: 24,
                  letterSpacing: 2.0,
                  color: AppColors.dangerRed,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildOpenLibraryButton() {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        width: 218,
        height: 67,
        decoration: BoxDecoration(
          color: const Color(0xFFE6F0FF),
          border: Border.all(color: const Color(0xFF4A72A5), width: 2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A72A5),
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/images/download_btn_icon.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                const Color(0xFF4A72A5),
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 12),
            Text('前 往 库 查 看',
                style: AppStyles.heading.copyWith(
                  fontSize: 22,
                  letterSpacing: 1.8,
                  color: const Color(0xFF4A72A5),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionButton('启 动', AppColors.primaryText, () {}),
        const SizedBox(width: 16),
        _buildActionButton('卸 载', AppColors.dangerRed, () {}),
      ],
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback onTap) {
    return InteractiveWrapper(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 100,
        height: 67,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.border,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(label, style: AppStyles.heading.copyWith(fontSize: 20)),
      ),
    );
  }

  Widget _buildRetryButton() {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        width: 218,
        height: 67,
        decoration: BoxDecoration(
          color: const Color(0xFFF0E6D2),
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
              color: AppColors.border,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded,
                size: 20, color: const Color(0xFF8B7355)),
            const SizedBox(width: 12),
            Text('重 新 尝 试',
                style: AppStyles.heading.copyWith(
                  fontSize: 24,
                  letterSpacing: 2.0,
                  color: const Color(0xFF8B7355),
                )),
          ],
        ),
      ),
    );
  }
}

enum ButtonVariant { download, openLibrary, retry }
