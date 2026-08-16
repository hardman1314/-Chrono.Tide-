import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../widgets/sidebar.dart' show NavPage;
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 左侧导航栏
///
/// 大尺寸垂直导航栏 (96px 宽),含 4 个主导航项 (Home/Library/Discover/Join)
/// + Exit BPM 按钮。每个导航项 64x64,图标 32x32,焦点感知。
///
/// 当前页通过左侧 4px 高亮条 + 背景色标识。
/// 与桌面端 [Sidebar] 不同,BPM 导航栏始终展开 (无折叠态)。
class BigPictureNavBar extends StatelessWidget {
  /// 当前激活的页面
  final NavPage currentPage;

  /// 页面切换回调
  final ValueChanged<NavPage> onPageChanged;

  /// 退出 BPM 模式回调 (底部按钮)
  final VoidCallback? onExitBpm;

  const BigPictureNavBar({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    this.onExitBpm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: BigPictureTheme.navBarWidth,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          right: BorderSide(
            color: AppColors.borderLight,
            width: 0.8,
          ),
        ),
      ),
      child: Column(
        children: [
          // 顶部预留标题栏高度
          const SizedBox(height: 40 + BigPictureTheme.sectionSpacing),
          // 应用 Logo (CT 字样)
          Text(
            'CT',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: BigPictureTheme.sectionSpacing),
          // 4 个主导航项 (显式顺序: 首页 → 库 → 探索 → 添加)
          // 不使用 NavPage.values 因为枚举定义顺序 (library, discover, join, home) 与 BPM 期望顺序不符
          ...[NavPage.home, NavPage.library, NavPage.discover, NavPage.join]
              .map((page) => _buildNavItem(page)),
          const Spacer(),
          // 退出 BPM 按钮
          _buildExitButton(),
          const SizedBox(height: BigPictureTheme.sectionSpacing),
        ],
      ),
    );
  }

  Widget _buildNavItem(NavPage page) {
    final isActive = currentPage == page;
    final icon = _navIcon(page);
    final label = _navLabel(page);

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: BigPictureTheme.navItemSpacing / 3,
      ),
      child: Stack(
        children: [
          // 左侧高亮条 (激活态)
          if (isActive)
            Positioned(
              left: 0,
              top: 8,
              bottom: 8,
              child: Container(
                width: BigPictureTheme.navActiveIndicatorWidth,
                decoration: BoxDecoration(
                  color: AppColors.selectedAccent,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ),
          BpmInteractiveWrapper(
            onTap: () => onPageChanged(page),
            semanticsLabel: label,
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            child: Container(
              width: BigPictureTheme.navItemSize,
              height: BigPictureTheme.navItemSize,
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.selectedAccent.withOpacity(0.15)
                    : Colors.transparent,
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: BigPictureTheme.navIconSize,
                    color: isActive
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive
                          ? AppColors.selectedAccent
                          : AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExitButton() {
    return BpmInteractiveWrapper(
      onTap: onExitBpm,
      semanticsLabel: '退出大屏模式',
      borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
      child: Container(
        width: BigPictureTheme.navItemSize,
        height: BigPictureTheme.navItemSize,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.fullscreen_exit_rounded,
              size: BigPictureTheme.navIconSize,
              color: AppColors.secondaryText,
            ),
            const SizedBox(height: 4),
            Text(
              '退出',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _navIcon(NavPage page) {
    switch (page) {
      case NavPage.home:
        return Icons.home_rounded;
      case NavPage.library:
        return Icons.library_books_rounded;
      case NavPage.discover:
        return Icons.explore_rounded;
      case NavPage.join:
        return Icons.add_circle_outline_rounded;
    }
  }

  String _navLabel(NavPage page) {
    switch (page) {
      case NavPage.home:
        return '首页';
      case NavPage.library:
        return '游戏库';
      case NavPage.discover:
        return '探索';
      case NavPage.join:
        return '添加';
    }
  }
}
