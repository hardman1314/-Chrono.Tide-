import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';

enum NavPage { library, discover, join }

class Sidebar extends StatefulWidget {
  final NavPage currentPage;
  final ValueChanged<NavPage> onPageChanged;
  final bool isCollapsed;
  final VoidCallback? onToggle;
  final bool isLocalMode;

  const Sidebar({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    this.isCollapsed = false,
    this.onToggle,
    this.isLocalMode = false,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  int _hoveredIndex = -1;

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
                    style: TextStyle(
                      fontFamily: 'Zhi Mang Xing',
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryText,
                      letterSpacing: 0.2,
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
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: widget.isCollapsed
                    ? Padding(
                        padding:
                            const EdgeInsets.only(left: 12, right: 12, top: 8),
                        child: Column(
                          children: [
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/library_icon_new.svg',
                              activeIconPath:
                                  'assets/images/library_icon_new.svg',
                              page: NavPage.library,
                              isActive: widget.currentPage == NavPage.library,
                              index: 0,
                            ),
                            if (!widget.isLocalMode)
                              _buildNavItemCollapsed(
                                iconPath: 'assets/images/discover_icon.svg',
                                activeIconPath:
                                    'assets/images/discover_active_icon.svg',
                                page: NavPage.discover,
                                isActive:
                                    widget.currentPage == NavPage.discover,
                                index: 1,
                              ),
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/add_icon.svg',
                              activeIconPath:
                                  'assets/images/add_active_icon.svg',
                              page: NavPage.join,
                              isActive: widget.currentPage == NavPage.join,
                              index: 2,
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
                            if (!widget.isLocalMode)
                              _buildNavItemExpanded(
                                iconPath: 'assets/images/discover_icon.svg',
                                activeIconPath:
                                    'assets/images/discover_active_icon.svg',
                                label: '探索',
                                page: NavPage.discover,
                                isActive:
                                    widget.currentPage == NavPage.discover,
                                hasBookmark: true,
                                bookmarkPath:
                                    'assets/images/discover_active_bookmark.png',
                                index: 1,
                              ),
                            _buildNavItemExpanded(
                              iconPath: 'assets/images/add_icon.svg',
                              activeIconPath:
                                  'assets/images/add_active_icon.svg',
                              label: '添加',
                              page: NavPage.join,
                              isActive: widget.currentPage == NavPage.join,
                              hasBookmark: true,
                              bookmarkPath:
                                  'assets/images/add_active_bookmark.png',
                              index: 2,
                            ),
                          ],
                        ),
                      ),
              ),
              if (widget.isLocalMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: widget.isCollapsed
                      ? Tooltip(
                          message: '本地模式',
                          child: Icon(
                            Icons.storage,
                            size: 18,
                            color: AppColors.secondaryText,
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.storage,
                              size: 14,
                              color: AppColors.secondaryText,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '本地模式',
                              style: TextStyle(
                                fontFamily: 'Mali',
                                fontSize: 12,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildSemicircleToggle({required bool isLeft}) {
    const double diameter = 34.0;
    const double radius = 17.0;
    final icon = isLeft ? Icons.chevron_left : Icons.chevron_right;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onToggle ?? () {},
        child: SizedBox(
          width: radius,
          height: diameter,
          child: CustomPaint(
            painter: SemicirclePainter(isLeft: isLeft),
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(
                  left: isLeft ? 4 : 0,
                  right: isLeft ? 0 : 4,
                ),
                child: Icon(
                  icon,
                  size: 16,
                  color: AppColors.toggleIcon,
                  weight: 700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

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

    return MouseRegion(
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
            color: isHovered && !isActive
                ? AppColors.cardHoverBg
                : AppColors.background,
            border: Border.all(
              color: isActive ? AppColors.border : AppColors.border,
              width: isActive || isHovered ? 2.0 : 1.6,
            ),
            boxShadow: (isActive || isHovered)
                ? [
                    BoxShadow(
                      color:
                          isHovered ? AppColors.borderLight : AppColors.border,
                      offset:
                          isHovered ? const Offset(0, 3) : const Offset(2, 3),
                      blurRadius: isHovered ? 10 : 0,
                    )
                  ]
                : null,
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
  }

  Widget _buildNavItemCollapsed({
    required String iconPath,
    required String activeIconPath,
    required NavPage page,
    required bool isActive,
    required int index,
  }) {
    final currentPath = isActive ? activeIconPath : iconPath;
    final isHovered = _hoveredIndex == index;

    return MouseRegion(
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
            borderRadius: BorderRadius.circular(14),
            color: isActive
                ? const Color(0xFFFFFFFF).withOpacity(0.65)
                : (isHovered
                    ? const Color(0xFFFFFFFF).withOpacity(0.25)
                    : Colors.transparent),
            border: Border.all(
              color: isActive
                  ? const Color(0xFFA07840)
                  : (isHovered
                      ? const Color(0xFFC8B49A)
                      : const Color(0xFFC8B49A).withOpacity(0.5)),
              width: 1,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: const Color(0xFF8C6428).withOpacity(0.10),
                      offset: const Offset(0, 1),
                      blurRadius: 6,
                    )
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: _buildIcon(currentPath, 28, 28),
          ),
        ),
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

  SemicirclePainter({required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    const double r = 17.0;
    const double d = 34.0;
    final paint = Paint()
      ..color = const Color(0xFFE8E0D0)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFFC8B49A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final shadowPaint = Paint()
      ..color = const Color(0xFF64461E).withOpacity(0.12)
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
      isLeft != oldDelegate.isLeft;
}
