import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'interactive_wrapper.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';

class DownloadButton extends StatelessWidget {
  final void Function()? onTap;
  final void Function()? onLaunch;
  final void Function()? onUninstall;
  final bool isDownloading;
  final bool isCompleted;
  final bool isExtracting;
  final ButtonVariant variant;

  const DownloadButton({
    super.key,
    required this.onTap,
    this.onLaunch,
    this.onUninstall,
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

  /// 通用按钮外壳：宽度自适应内容，最大 260，最小 160，高度 56
  Widget _buildButtonShell({
    required Widget child,
    required Color bgColor,
    required Color borderColor,
    double height = 56,
  }) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: 160,
          maxWidth: 260,
        ),
        height: height,
        decoration: BoxDecoration(
          color: bgColor,
          border: AppStyle.isModern
              ? Border.all(
                  color: borderColor.withAlpha(89), width: AppStyle.wHairline)
              : Border.all(color: borderColor, width: 2),
          borderRadius:
              BorderRadius.circular(AppStyle.isModern ? AppStyle.rMd : 6),
          boxShadow: AppStyle.isModern
              ? AppStyle.e1
              : [
                  BoxShadow(
                    color: borderColor,
                    offset: const Offset(2, 3),
                    blurRadius: 0,
                  ),
                ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: child,
      ),
    );
  }

  Widget _buildDownloadButton() {
    return _buildButtonShell(
      bgColor: AppColors.infoBg,
      borderColor: AppColors.infoBlue,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/images/download_btn_icon.svg',
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(
              AppColors.infoBlue,
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '获取作品',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 3.0,
              color: AppColors.infoBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelButton() {
    return _buildButtonShell(
      bgColor: AppColors.errorBg,
      borderColor: AppColors.dangerRed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.close_rounded, size: 20, color: AppColors.dangerRed),
          const SizedBox(width: 10),
          Text(
            '取消获取',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 3.0,
              color: AppColors.dangerRed,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpenLibraryButton() {
    return _buildButtonShell(
      bgColor: AppColors.infoBg,
      borderColor: AppColors.infoBlue,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/images/download_btn_icon.svg',
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(
              AppColors.infoBlue,
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '前往库查看',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.5,
              color: AppColors.infoBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionButton('启动', AppColors.primaryText, onLaunch ?? () {}),
        const SizedBox(width: 16),
        _buildActionButton('卸载', AppColors.dangerRed, onUninstall ?? () {}),
      ],
    );
  }

  Widget _buildActionButton(String label, Color color, VoidCallback onTap) {
    return InteractiveWrapper(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 96,
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: AppStyle.isModern
              ? Border.all(
                  color: AppColors.borderLight, width: AppStyle.wHairline)
              : Border.all(color: AppColors.border, width: 2),
          borderRadius:
              BorderRadius.circular(AppStyle.isModern ? AppStyle.rMd : 6),
          boxShadow: AppStyle.isModern
              ? AppStyle.e1
              : [
                  BoxShadow(
                    color: AppColors.border,
                    offset: const Offset(2, 3),
                    blurRadius: 0,
                  ),
                ],
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildRetryButton() {
    return _buildButtonShell(
      bgColor: AppColors.buttonBackground,
      borderColor: AppColors.border,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, size: 20, color: AppColors.border),
          const SizedBox(width: 10),
          Text(
            '重新尝试',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 3.0,
              color: AppColors.border,
            ),
          ),
        ],
      ),
    );
  }
}

enum ButtonVariant { download, openLibrary, retry }
