import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_styles.dart';
import 'smart_import_notification.dart';

enum NavPage { library, discover, join, home }

class Sidebar extends StatefulWidget {
  final NavPage currentPage;
  final ValueChanged<NavPage> onPageChanged;
  final bool isCollapsed;
  final VoidCallback? onToggle;

  /// 入库成功回调（侧边栏通知气泡一键入库后刷新库页）
  final VoidCallback? onGameAdded;

  const Sidebar({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    this.isCollapsed = false,
    this.onToggle,
    this.onGameAdded,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  int _hoveredIndex = -1;
  int _homeHoveredIndex = -1; // 0=normal, 1=hovered

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.none,
      width: widget.isCollapsed ? 71 : 224,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          right: BorderSide(
            color: AppColors.borderLight,
            width: 0.8,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.05),
            offset: const Offset(2, 0),
            blurRadius: 5,
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.isCollapsed)
                Padding(
                  padding: const EdgeInsets.only(top: 22, bottom: 20),
                  child: Text(
                    'CT',
                    // 与展开态「Chrono Tide」同一套标题样式（F1 得意黑
                    // titleLarge）：此前收起态是独立 TextStyle（系统默认
                    // 字体 + w700 合成粗体 + 20px），导致收起/展开切换时
                    // 标题字体肉眼可见地不一致。
                    style: AppStyles.titleLarge.copyWith(
                      color: AppColors.border,
                      letterSpacing: 0.6,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 31, bottom: 17),
                  child: SizedBox(
                    width: 223,
                    child: Text(
                      'Chrono Tide',
                      textAlign: TextAlign.center,
                      style: AppStyles.titleLarge.copyWith(
                      color: AppColors.border,
                      letterSpacing: 0.6,
                    ),
                    ),
                  ),
                ),
              Expanded(
                child: widget.isCollapsed
                    ? Padding(
                        padding: const EdgeInsets.only(
                            left: 12, right: 12, top: 8, bottom: 8),
                        child: Column(
                          children: [
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/library_icon_new.svg',
                              activeIconPath:
                                  'assets/images/library_icon_new.svg',
                              label: '库',
                              page: NavPage.library,
                              isActive: widget.currentPage == NavPage.library,
                              index: 0,
                            ),
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/discover_icon.svg',
                              activeIconPath:
                                  'assets/images/discover_active_icon.svg',
                              label: '探索',
                              page: NavPage.discover,
                              isActive: widget.currentPage == NavPage.discover,
                              index: 1,
                            ),
                            // 智能导入通知：徽章 + 悬停/主动弹出气泡
                            // 收起态按钮 47x60 含顶部 margin 12：
                            // - 徽章 top = 12 - 5 = 7（抵消 margin，贴按钮右上角）
                            // - 气泡垂直校正 +6（按钮中心 42 vs 含 margin 整体中心 36）
                            SmartImportNotification(
                              isActive: widget.currentPage == NavPage.join,
                              onGameAdded: widget.onGameAdded,
                              badgeTop: 7,
                              bubbleOffset: const Offset(8, 6),
                              child: _buildNavItemCollapsed(
                                iconPath: 'assets/images/add_icon.svg',
                                activeIconPath:
                                    'assets/images/add_active_icon.svg',
                                label: '添加',
                                page: NavPage.join,
                                isActive:
                                    widget.currentPage == NavPage.join,
                                index: 2,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Padding(
                        padding:
                            const EdgeInsets.only(left: 24, right: 24, top: 10),
                        child: Column(
                          children: [
                            _buildNavItemExpanded(
                              iconPath: 'assets/images/library_icon_new.svg',
                              activeIconPath:
                                  'assets/images/library_icon_new.svg',
                              label: '库',
                              page: NavPage.library,
                              isActive: widget.currentPage == NavPage.library,
                              hasBookmark: true,
                              bookmarkPath:
                                  'assets/images/discover_active_bookmark.png',
                              index: 0,
                            ),
                            _buildNavItemExpanded(
                              iconPath: 'assets/images/discover_icon.svg',
                              activeIconPath:
                                  'assets/images/discover_active_icon.svg',
                              label: '探索',
                              page: NavPage.discover,
                              isActive: widget.currentPage == NavPage.discover,
                              hasBookmark: true,
                              bookmarkPath:
                                  'assets/images/discover_active_bookmark.png',
                              index: 1,
                            ),
                            // 智能导入通知：徽章 + 悬停/主动弹出气泡
                            // 展开态卡片 175x144 含底部 margin 32：
                            // - 徽章默认 top -5（卡片无顶部 margin，位置正确）
                            // - 气泡垂直校正 -16（卡片中心 72 vs 含 margin 整体中心 88）
                            SmartImportNotification(
                              isActive: widget.currentPage == NavPage.join,
                              onGameAdded: widget.onGameAdded,
                              bubbleOffset: const Offset(8, -16),
                              child: _buildNavItemExpanded(
                                iconPath: 'assets/images/add_icon.svg',
                                activeIconPath:
                                    'assets/images/add_active_icon.svg',
                                label: '添加',
                                page: NavPage.join,
                                isActive:
                                    widget.currentPage == NavPage.join,
                                hasBookmark: true,
                                bookmarkPath:
                                    'assets/images/add_active_bookmark.png',
                                index: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              // 主页按钮 - 位于侧边栏底部
              // 网络状态指示已移至用户头像浮动气泡（见 FloatingUserButton）
              _buildHomeButton(),
            ],
          ),
        ],
      ),
    );
  }

  // 2026-09-11: 已删除死代码 buildSemicircleToggle（0 调用点，经用户批准）。
  // 其 UX-25 改进（Tooltip/Semantics/weight:700）已移植到在用组件
  // SidebarToggleWidget（main_container.dart）。在用按钮本体见
  // main_container.dart:854-866 挂载点。widget.onToggle 字段保留
  // （公开 API，暂无消费方）。

  Widget _buildNavItemExpanded({
    required String iconPath,
    required String activeIconPath,
    required String label,
    required NavPage page,
    required bool isActive,
    bool hasBookmark = false,
    String bookmarkPath = 'assets/images/add_active_bookmark.png',
    required int index,
  }) {
    final currentPath = isActive ? activeIconPath : iconPath;
    final isHovered = _hoveredIndex == index;

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => widget.onPageChanged(page),
        onTapDown: (_) => setState(() => _hoveredIndex = index),
        onTapUp: (_) => setState(() => _hoveredIndex = -1),
        onTapCancel: () => setState(() => _hoveredIndex = -1),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(bottom: 32),
          width: 175,
          height: 144,
          decoration: BoxDecoration(
            borderRadius: AppStyle.navHeroRadius,
            color: isHovered && !isActive
                ? AppColors.cardHoverBg
                // 石英白画布与 background 同色：极光档静息用白卡面保证按钮可见
                : (AppStyle.isModern
                    ? AppColors.buttonBackground
                    : AppColors.background),
            border:
                AppStyle.navHeroBorder(active: isActive, hovered: isHovered),
            boxShadow:
                AppStyle.navHeroShadow(active: isActive, hovered: isHovered),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (hasBookmark && isActive)
                Positioned(
                  left: -11,
                  top: 63,
                  child: Transform.rotate(
                    angle: -6 * 3.14159 / 180,
                    child: Image.asset(
                      bookmarkPath,
                      width: 16,
                      height: 18,
                    ),
                  ),
                ),
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildIcon(currentPath, 32, 32),
                    const SizedBox(height: 12),
                    Text(
                      label,
                      style: isActive
                          ? AppStyles.navActive
                          : AppStyles.navInactive,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // UX-25: 导航项添加 Tooltip（hover 显示名称）+ Semantics（屏幕阅读器播报）
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: core,
      ),
    );
  }

  Widget _buildNavItemCollapsed({
    required String iconPath,
    required String activeIconPath,
    required String label,
    required NavPage page,
    required bool isActive,
    required int index,
  }) {
    final currentPath = isActive ? activeIconPath : iconPath;
    final isHovered = _hoveredIndex == index;

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => widget.onPageChanged(page),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(top: 12),
          width: 47,
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppStyle.rNavItem),
            // BUG-05: 硬编码白色背景替换为主题感知的 navActiveBg / cardHoverBg
            color: isActive
                ? AppColors.navActiveBg
                : (isHovered ? AppColors.cardHoverBg : Colors.transparent),
            border:
                AppStyle.navPillBorder(active: isActive, hovered: isHovered),
            boxShadow: AppStyle.navPillShadow(active: isActive),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: _buildIcon(currentPath, 28, 28),
          ),
        ),
      ),
    );
    // UX-25: 收起态导航项——Tooltip 尤为关键（标签被隐藏），辅助屏幕阅读器播报
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: core,
      ),
    );
  }

  /// 网络状态指示已移至用户头像浮动气泡（FloatingUserButton），
  /// 见 lib/widgets/floating_user_button.dart。

  Widget _buildHomeButton() {
    final isActive = widget.currentPage == NavPage.home;
    final isHovered = _homeHoveredIndex == 1;

    if (widget.isCollapsed) {
      // 收起模式：紧凑圆形按钮
      final core = Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _homeHoveredIndex = 1),
          onExit: (_) => setState(() => _homeHoveredIndex = -1),
          child: GestureDetector(
            onTap: () => widget.onPageChanged(NavPage.home),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 47,
              height: 47,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppStyle.rNavItem),
                // BUG-05: 硬编码颜色替换为主题感知变量
                color: isActive
                    ? AppColors.navActiveBg
                    : (isHovered ? AppColors.cardHoverBg : Colors.transparent),
                border:
                    AppStyle.navPillBorder(active: isActive, hovered: isHovered),
                boxShadow: AppStyle.navPillShadow(active: isActive),
              ),
              child: Center(
                child: Icon(
                  Icons.home_rounded,
                  size: 22,
                  // BUG-05: 图标颜色从硬编码替换为主题感知变量
                  color: AppStyle.navIconColor(
                      active: isActive, hovered: isHovered),
                ),
              ),
            ),
          ),
        ),
      );
      // UX-25: 主页按钮添加 Tooltip + Semantics
      return Tooltip(
        message: '主页',
        waitDuration: const Duration(milliseconds: 400),
        child: Semantics(
          button: true,
          selected: isActive,
          label: '主页',
          child: core,
        ),
      );
    }

    // 展开模式：与导航卡同宽(175)的扁条按钮，风格统一（图标在上、文字在下）
    final core = Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _homeHoveredIndex = 1),
        onExit: (_) => setState(() => _homeHoveredIndex = -1),
        child: GestureDetector(
          onTap: () => widget.onPageChanged(NavPage.home),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 175,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: AppStyle.navHeroRadius,
              border:
                  AppStyle.homeHeroBorder(active: isActive, hovered: isHovered),
              color: isHovered && !isActive
                  ? AppColors.cardHoverBg
                  // 同上：极光档静息用白卡面（石英白画布上不可隐形）
                  : (AppStyle.isModern
                      ? AppColors.buttonBackground
                      : AppColors.background),
              boxShadow:
                  AppStyle.homeHeroShadow(active: isActive, hovered: isHovered),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.home_rounded,
                  size: 22,
                  color: AppStyle.homeIconColor(
                      active: isActive, hovered: isHovered),
                ),
                const SizedBox(height: 4),
                Text(
                  '主页',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: isActive
                        ? AppColors.titleBrown
                        : (isHovered
                            ? AppColors.titleBrown
                            : AppColors.secondaryText),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // UX-25: 主页按钮添加 Tooltip + Semantics
    return Tooltip(
      message: '主页',
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: '主页',
        child: core,
      ),
    );
  }

  Widget _buildIcon(String path, double width, double height) {
    if (path.endsWith('.svg')) {
      return FutureBuilder<String>(
        future: DefaultAssetBundle.of(context).loadString(path),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return SvgPicture.string(
              snapshot.data!,
              width: width,
              height: height,
              fit: BoxFit.contain,
            );
          }
          if (snapshot.hasError) {
            debugPrint(
                '[SIDEBAR] ⚠️ SVG加载失败(已静默处理): $path | ${snapshot.error}');
            return const SizedBox.shrink();
          }
          return SizedBox(width: width, height: height);
        },
      );
    }
    return Image.asset(
      path,
      width: width,
      height: height,
      errorBuilder: (context, error, stackTrace) {
        debugPrint('[SIDEBAR] ❌ 图标加载失败: $path | 错误: $error');
        return const SizedBox.shrink();
      },
    );
  }
}

class SemicirclePainter extends CustomPainter {
  final bool isLeft;
  // BUG-05: 颜色从外部传入，避免硬编码，使主题切换时半圆按钮颜色跟随变化
  final Color fillColor;
  final Color borderColor;
  final Color shadowColor;

  SemicirclePainter({
    required this.isLeft,
    required this.fillColor,
    required this.borderColor,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double r = 17.0;
    const double d = 34.0;
    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final shadowPaint = Paint()
      ..color = shadowColor.withOpacity(0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final path = Path();
    if (isLeft) {
      path.moveTo(r, 0);
      path.arcToPoint(
        Offset(r, d),
        radius: const Radius.circular(r),
        clockwise: false,
      );
      path.close();
      canvas.saveLayer(
        Rect.fromLTWH(0, -2, r, d + 4),
        Paint(),
      );
      canvas.translate(0, 1);
      canvas.drawPath(path, shadowPaint);
      canvas.restore();
    } else {
      path.moveTo(0, 0);
      path.arcToPoint(
        Offset(0, d),
        radius: const Radius.circular(r),
        clockwise: true,
      );
      path.close();
      canvas.saveLayer(
        Rect.fromLTWH(-2, -2, r + 4, d + 4),
        Paint(),
      );
      canvas.translate(0, 1);
      canvas.drawPath(path, shadowPaint);
      canvas.restore();
    }

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(SemicirclePainter oldDelegate) =>
      isLeft != oldDelegate.isLeft ||
      fillColor != oldDelegate.fillColor ||
      borderColor != oldDelegate.borderColor ||
      shadowColor != oldDelegate.shadowColor;
}
