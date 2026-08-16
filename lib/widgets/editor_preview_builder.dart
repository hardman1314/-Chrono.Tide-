import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_resolver.dart';

/// v3.0.1 修复9：预览页面类型（新增 home 主页 / detail 库页详情窗口）
enum PreviewPage {
  library,
  discover,
  join,
  home,
  detail,
}

/// v3.0 P2：编辑器预览骨架（WYSIWYG 1:1 还原真实 UI）
///
/// v3.0.1 修复9：彻底按真实组件实现精确复刻：
/// - 4 个页面：库 / 探索 / 添加 / 主页（之前缺主页）
/// - 侧栏收展：224 ↔ 71，半圆 toggle 按钮，收起态"CT"+图标导航
/// - 卡片：padding 8 + Column(Expanded 封面 + 5gap + 标题栏 22 + 制作方栏 18)
///   标题/制作方用灰色占位条代替不确定文字（用户要求"用符号替代"）
/// - 管理按钮：透明背景 + tune 图标（size 20, secondaryText），非带边框按钮
/// - 添加页：左列(封面+表单/截图/简介) + 右列(元数据抓取/置入区/入库按钮)
/// - 主页：左详情面板(flex 3) + 右游戏列表(320 宽)
class EditorPreviewBuilder extends StatefulWidget {
  final CTThemeData themeData;
  final String? selectedElementId;
  final ValueChanged<String> onElementTap;
  final ValueChanged<String> onElementDoubleTap;
  final double scale;

  final PreviewPage previewPage;

  const EditorPreviewBuilder({
    super.key,
    required this.themeData,
    this.selectedElementId,
    required this.onElementTap,
    required this.onElementDoubleTap,
    this.scale = 0.5,
    this.previewPage = PreviewPage.library,
  });

  @override
  State<EditorPreviewBuilder> createState() => _EditorPreviewBuilderState();
}

class _EditorPreviewBuilderState extends State<EditorPreviewBuilder> {
  /// v3.0.1 修复9：侧栏收展状态（预览内可交互切换）
  bool _isSidebarCollapsed = false;

  CTThemeData get t => widget.themeData;

  // ============ 可选中元素包装器 ============
  Widget _sel({required String elementId, required Widget child}) {
    return _SelectableElement(
      elementId: elementId,
      selectedId: widget.selectedElementId,
      onTap: widget.onElementTap,
      onDoubleTap: widget.onElementDoubleTap,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.05),
        border: Border.all(color: t.borderLight, width: 1.0),
        borderRadius: BorderRadius.circular(7),
      ),
      padding: const EdgeInsets.all(8),
      // v3.0 P6 修复：Stack 包裹 FittedBox，浮动侧栏收展按钮不受缩放影响
      child: Stack(
        children: [
          FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 1280,
              height: 720,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  children: [
                    _buildBackground(context),
                    Column(
                      children: [
                        _buildTitleBar(),
                        Expanded(
                          child: Row(
                            children: [
                              _buildSidebar(context),
                              Expanded(child: _buildContentArea()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // v3.0 P6 修复：浮动侧栏收展按钮（右上角，不受 FittedBox 缩放）
          Positioned(
            top: 2,
            right: 2,
            child: _buildFloatingSidebarToggle(),
          ),
        ],
      ),
    );
  }

  /// 浮动侧栏收展按钮（预览区右上角，方便用户切换展开/收起状态）
  Widget _buildFloatingSidebarToggle() {
    return Tooltip(
      message: _isSidebarCollapsed ? '展开侧栏' : '收起侧栏',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () =>
              setState(() => _isSidebarCollapsed = !_isSidebarCollapsed),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: t.buttonBackground,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: t.borderLight, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: t.shadowColor,
                  blurRadius: 2,
                  offset: const Offset(1, 1),
                ),
              ],
            ),
            child: Icon(
              _isSidebarCollapsed
                  ? Icons.view_sidebar_rounded
                  : Icons.view_sidebar_outlined,
              size: 14,
              color: t.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  // ============ 背景层（接入 BackgroundImageResolver，支持上传图预览）============
  Widget _buildBackground(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: t.background),
          if (t.hasBackgroundImage)
            BackgroundImageResolver(
              key: ValueKey(
                  'preview_bg_${t.backgroundImage.filename ?? t.backgroundImage.assetPath ?? "none"}'),
              config: t.backgroundImage,
              overlayColor: t.background,
            ),
        ],
      ),
    );
  }

  // ============ 标题栏（1:1 还原 CustomTitleBar：32 高，左标题，右三个窗口按钮）============
  Widget _buildTitleBar() {
    return _sel(
      elementId: 'app_titlebar',
      child: Container(
        height: 32,
        decoration: BoxDecoration(
          color: t.titleBarBackground,
          border: Border(
              bottom: BorderSide(color: t.borderLight, width: 1)),
        ),
        child: Row(
          children: [
            Expanded(
              child: _sel(
                elementId: 'app_titlebar_text',
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Chrono Tide',
                        style: TextStyle(
                            color: t.primaryText,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Inter')),
                  ),
                ),
              ),
            ),
            _winBtn(Icons.horizontal_rule_rounded),
            _winBtn(Icons.crop_square_outlined),
            _winBtn(Icons.close_rounded, isClose: true),
          ],
        ),
      ),
    );
  }

  Widget _winBtn(IconData icon, {bool isClose = false}) {
    return Container(
      width: 38,
      height: 32,
      alignment: Alignment.center,
      child: Icon(icon, size: 12,
          color: isClose ? t.dangerRed : t.secondaryText),
    );
  }

  // ============ 侧栏（1:1 还原 Sidebar：224↔71 收展，半圆 toggle，4 导航 + 主页按钮）============
  Widget _buildSidebar(BuildContext context) {
    return _sel(
      elementId: 'app_sidebar',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: _isSidebarCollapsed ? 71 : 224,
            height: double.infinity,
            decoration: BoxDecoration(
              color: t.sidebarBackground,
              border: Border(
                  right: BorderSide(color: t.borderLight, width: 0.8)),
            ),
            child: _isSidebarCollapsed
                ? _buildSidebarCollapsed(context)
                : _buildSidebarExpanded(context),
          ),
          // 半圆 toggle 按钮（贴在侧栏右边缘，垂直居中，1:1 还原实际 UI）
          Positioned(
            top: 0,
            bottom: 0,
            right: -10,
            child: Center(child: _buildSidebarToggle()),
          ),
        ],
      ),
    );
  }

  /// 半圆收展 toggle（1:1 还原 buildSemicircleToggle：toggleBg/toggleBorder/toggleIcon）
  Widget _buildSidebarToggle() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(
            () => _isSidebarCollapsed = !_isSidebarCollapsed),
        child: Container(
          width: 20,
          height: 40,
          decoration: BoxDecoration(
            color: t.toggleBg,
            borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(10)),
            border: Border.all(color: t.toggleBorder, width: 1),
          ),
          child: Center(
            child: Icon(
              _isSidebarCollapsed
                  ? Icons.chevron_right_rounded
                  : Icons.chevron_left_rounded,
              size: 14,
              color: t.toggleIcon,
            ),
          ),
        ),
      ),
    );
  }

  /// 侧栏展开态：Chrono Tide 标题 + 3 个 175×144 导航卡 + 主页按钮
  Widget _buildSidebarExpanded(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _sel(
          elementId: 'sidebar_title',
          child: Padding(
            padding: const EdgeInsets.only(top: 31, bottom: 17),
            child: SizedBox(
              width: 223,
              child: Text('Chrono Tide',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: 'ZhiMangXing',
                      fontSize: 30,
                      height: 36 / 30,
                      letterSpacing: 2.0,
                      color: t.border)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24, right: 24, top: 10),
          child: Column(
            children: [
              _buildNavCard(context, 'assets/images/library_icon_new.svg',
                  '库', PreviewPage.library),
              _buildNavCard(context, 'assets/images/discover_icon.svg',
                  '探索', PreviewPage.discover,
                  activeIcon: 'assets/images/discover_active_icon.svg'),
              _buildNavCard(context, 'assets/images/add_icon.svg', '添加',
                  PreviewPage.join,
                  activeIcon: 'assets/images/add_active_icon.svg'),
            ],
          ),
        ),
        const Spacer(),
        _buildHomeButtonExpanded(),
      ],
    );
  }

  /// 侧栏收起态：CT 标题 + 3 个 47×47 图标导航 + 主页圆形按钮
  Widget _buildSidebarCollapsed(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 20),
          child: Text('CT',
              style: TextStyle(
                  fontFamily: 'ZhiMangXing',
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: t.primaryText,
                  letterSpacing: 0.2)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, top: 8, bottom: 8),
          child: Column(
            children: [
              _buildNavCollapsed(context, 'assets/images/library_icon_new.svg',
                  '库', PreviewPage.library),
              _buildNavCollapsed(context, 'assets/images/discover_icon.svg',
                  '探索', PreviewPage.discover),
              _buildNavCollapsed(context, 'assets/images/add_icon.svg', '添加',
                  PreviewPage.join),
            ],
          ),
        ),
        const Spacer(),
        _buildHomeButtonCollapsed(),
      ],
    );
  }

  /// 展开态导航卡（1:1 还原 _buildNavItemExpanded：175×144，边框，激活书签）
  Widget _buildNavCard(BuildContext context, String iconPath, String label,
      PreviewPage page,
      {String? activeIcon}) {
    final isActive = widget.previewPage == page;
    final eid = isActive ? 'nav_active' : 'nav_inactive';
    return _sel(
      elementId: eid,
      child: Container(
        margin: const EdgeInsets.only(bottom: 32),
        width: 175,
        height: 144,
        decoration: BoxDecoration(
          color: t.background,
          border: Border.all(
              color: t.border, width: isActive ? 2.0 : 1.6),
          boxShadow: isActive
              ? [BoxShadow(color: t.border, offset: const Offset(2, 3), blurRadius: 0)]
              : null,
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _svgIcon(context, isActive ? (activeIcon ?? iconPath) : iconPath, 32, 32),
              const SizedBox(height: 12),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      height: 24 / 16,
                      letterSpacing: 0.5,
                      color: isActive ? t.primaryText : t.secondaryText)),
            ],
          ),
        ),
      ),
    );
  }

  /// 收起态导航（1:1 还原 _buildNavItemCollapsed：47×47 圆角图标）
  Widget _buildNavCollapsed(BuildContext context, String iconPath, String label,
      PreviewPage page) {
    final isActive = widget.previewPage == page;
    final eid = isActive ? 'nav_active' : 'nav_inactive';
    return _sel(
      elementId: eid,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        width: 47,
        height: 47,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: isActive ? t.navActiveBg : Colors.transparent,
          border: Border.all(
              color: isActive ? t.navActiveBorder : t.navInactiveBorder,
              width: 1),
        ),
        child: Center(
          child: _svgIcon(context, iconPath, 22, 22),
        ),
      ),
    );
  }

  /// 展开态主页按钮（54×54 圆形）
  Widget _buildHomeButtonExpanded() {
    final isActive = widget.previewPage == PreviewPage.home;
    return _sel(
      elementId: 'home_button',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: t.border.withOpacity(0.7), width: 2),
            color: isActive ? t.navActiveBg : t.buttonBackground,
            boxShadow: [
              BoxShadow(
                  color: t.border.withOpacity(0.2),
                  offset: const Offset(2, 3),
                  blurRadius: 0),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.home_rounded, size: 17, color: t.titleBrown),
              const SizedBox(height: 1),
              Text('主页',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: t.secondaryText,
                      height: 28 / 10)),
            ],
          ),
        ),
      ),
    );
  }

  /// 收起态主页按钮（47×47 圆角）
  Widget _buildHomeButtonCollapsed() {
    final isActive = widget.previewPage == PreviewPage.home;
    return _sel(
      elementId: 'home_button',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          width: 47,
          height: 47,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: isActive ? t.navActiveBg : Colors.transparent,
            border: Border.all(
                color: isActive ? t.navActiveBorder : t.navInactiveBorder,
                width: 1),
          ),
          child: Center(
            child: Icon(Icons.home_rounded, size: 20, color: t.titleBrown),
          ),
        ),
      ),
    );
  }

  Widget _svgIcon(BuildContext context, String path, double w, double h) {
    if (path.endsWith('.svg')) {
      return FutureBuilder<String>(
        future: DefaultAssetBundle.of(context).loadString(path),
        builder: (context, snap) {
          if (snap.hasData) {
            return SvgPicture.string(snap.data!, width: w, height: h, fit: BoxFit.contain);
          }
          return SizedBox(width: w, height: h);
        },
      );
    }
    return Image.asset(path, width: w, height: h,
        errorBuilder: (_, __, ___) => const SizedBox.shrink());
  }

  // ============ 内容区 ============
  Widget _buildContentArea() {
    final bg = t.hasBackgroundImage ? Colors.transparent : t.background;
    return _sel(
      elementId: 'app_window',
      child: Container(
        color: bg,
        child: switch (widget.previewPage) {
          PreviewPage.library => _buildLibraryContent(),
          PreviewPage.discover => _buildDiscoverContent(),
          PreviewPage.join => _buildJoinContent(),
          PreviewPage.home => _buildHomeContent(),
          PreviewPage.detail => _buildDetailContent(),
        },
      ),
    );
  }

  // ============ 库页（padding 24/20/24/8，网格 + 右上角透明管理按钮）============
  Widget _buildLibraryContent() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Stack(
        children: [
          _buildGameGrid(8),
          Positioned(top: 0, right: 0, child: _buildManageButton()),
        ],
      ),
    );
  }

  /// 管理按钮（1:1 还原：透明背景 + tune 图标，非带边框按钮）
  Widget _buildManageButton() {
    return _sel(
      elementId: 'button_bg',
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.tune, size: 20, color: t.secondaryText),
      ),
    );
  }

  Widget _buildGameGrid(int count) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 24,
            crossAxisSpacing: 24,
            childAspectRatio: 0.60,
          ),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: count,
          itemBuilder: (context, i) => _buildGameCard(),
        );
      },
    );
  }

  /// 游戏卡片（1:1 还原 _LibraryCardWidget：padding 8 + Column(Expanded 封面 + 5gap + 标题栏 + 制作方栏)）
  /// 标题/制作方用灰色占位条代替不确定文字
  Widget _buildGameCard() {
    return _sel(
      elementId: 'app_card',
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.max,
          children: [
            // 封面（Expanded 占大部分）
            Expanded(
              child: _sel(
                elementId: 'card_cover_placeholder',
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: t.border, width: 2),
                    borderRadius: BorderRadius.circular(4),
                    color: t.background,
                    boxShadow: [
                      BoxShadow(
                          color: t.border.withOpacity(0.2),
                          offset: const Offset(2, 3),
                          blurRadius: 0),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Container(
                      color: t.placeholderCover,
                      child: Center(
                        child: Icon(Icons.videogame_asset_rounded,
                            size: 40, color: t.border.withOpacity(0.4)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            // 标题占位条（22 高，灰色圆角条代替"游戏 N"文字）
            SizedBox(
              height: 22,
              width: double.infinity,
              child: _sel(
                elementId: 'card_title',
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      height: 12,
                      width: 90,
                      decoration: BoxDecoration(
                        color: t.placeholderBg,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 制作方占位条（18 高，更短的灰色条）
            SizedBox(
              height: 18,
              child: Padding(
                padding: const EdgeInsets.only(left: 2, top: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 8,
                    width: 56,
                    decoration: BoxDecoration(
                      color: t.placeholderBg.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 探索页（padding 24/24/24/0，搜索 + 筛选 + 标签 + 网格）============
  Widget _buildDiscoverContent() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _sel(
                  elementId: 'text_placeholder',
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: t.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: t.border, width: 1.4),
                      boxShadow: [
                        BoxShadow(
                            color: t.border.withOpacity(0.2),
                            offset: const Offset(2, 3),
                            blurRadius: 0),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.help_outline_rounded,
                            size: 18, color: t.secondaryText.withOpacity(0.5)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('搜索游戏 / 标签...',
                              style: TextStyle(
                                  color: t.placeholderText,
                                  fontSize: 14,
                                  fontFamily: 'Inter')),
                        ),
                        Icon(Icons.search, size: 18, color: t.secondaryText),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _sel(
                elementId: 'button_bg',
                child: Container(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    color: t.buttonBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.border, width: 1.4),
                  ),
                  child: Icon(Icons.filter_list, size: 18, color: t.primaryText),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _tag('全部', true),
                const SizedBox(width: 8),
                _tag('幻想'),
                const SizedBox(width: 8),
                _tag('恋爱'),
                const SizedBox(width: 8),
                _tag('动作'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildGameGrid(8)),
        ],
      ),
    );
  }

  Widget _tag(String label, [bool isActive = false]) {
    return _sel(
      elementId: isActive ? 'accent_color' : 'button_bg',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? t.selectedAccent : t.buttonBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: isActive ? t.selectedAccent : t.border, width: 1.0),
        ),
        child: Text(label,
            style: TextStyle(
                color: isActive ? t.primaryText : t.secondaryText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'Inter')),
      ),
    );
  }

  // ============ 添加页（padding 24，左 flex5 / 右 flex7）============
  Widget _buildJoinContent() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _buildJoinLeft()),
          const SizedBox(width: 20),
          Expanded(flex: 7, child: _buildJoinRight()),
        ],
      ),
    );
  }

  /// 添加页左列：封面+表单 → 截图 → 简介（1:1 还原 _buildLeftColumn）
  Widget _buildJoinLeft() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 封面 + 名称/标签/制作方
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sel(
              elementId: 'card_cover_placeholder',
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  color: t.placeholderCover,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.border, width: 1.4),
                ),
                child: Center(
                  child: Icon(Icons.add_photo_alternate_outlined,
                      size: 36, color: t.border.withOpacity(0.5)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  _joinField('游戏名称', 'text_primary'),
                  const SizedBox(height: 6),
                  _joinField('标签', 'text_secondary'),
                  const SizedBox(height: 6),
                  _joinField('制作方', 'text_secondary'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 截图轮播
        _sel(
          elementId: 'card_cover_placeholder',
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              color: t.placeholderCover,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border, width: 1.4),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_library_outlined,
                      size: 28, color: t.border.withOpacity(0.5)),
                  const SizedBox(height: 4),
                  Text('截图轮播',
                      style: TextStyle(
                          color: t.placeholderText,
                          fontSize: 11,
                          fontFamily: 'Inter')),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 简介输入区（Expanded）
        Expanded(
          child: _sel(
            elementId: 'card_cover_placeholder',
            child: Container(
              decoration: BoxDecoration(
                color: t.placeholderCover.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border, width: 1.4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('简介',
                        style: TextStyle(
                            color: t.secondaryText,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'Inter')),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _lineBar(0.9),
                          const SizedBox(height: 4),
                          _lineBar(0.7),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 添加页右列：元数据匹配 → 置入区(Expanded) → 取消+入库按钮（1:1 还原 _buildRightColumn）
  Widget _buildJoinRight() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 元数据匹配板块（1:1 还原 MetadataSection：height 203，border 2，shadow(4,5)，圆角0）
        _sel(
          elementId: 'app_card',
          child: Container(
            height: 203,
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 4),
            decoration: BoxDecoration(
              color: t.background,
              border: Border.all(color: t.border, width: 2),
              boxShadow: [
                BoxShadow(
                    color: t.border, offset: const Offset(4, 5), blurRadius: 0),
              ],
              borderRadius: BorderRadius.circular(0),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行（带底边框：auto_awesome + 元数据匹配 ZhiMangXing + 齿轮 + 一键抓取）
                Container(
                  padding: const EdgeInsets.only(bottom: 5),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: t.shadowColor, width: 1)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_awesome,
                              size: 16, color: t.border),
                          const SizedBox(width: 6),
                          Text('元数据匹配',
                              style: TextStyle(
                                  fontFamily: 'ZhiMangXing',
                                  fontSize: 16,
                                  letterSpacing: 2.0,
                                  color: t.border)),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 齿轮设定按钮
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: t.background,
                              border:
                                  Border.all(color: t.border, width: 1.2),
                            ),
                            child: Icon(Icons.settings,
                                size: 14, color: t.secondaryText),
                          ),
                          const SizedBox(width: 6),
                          // 一键抓取按钮（强调色）
                          _sel(
                            elementId: 'accent_color',
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.selectedAccent,
                                border:
                                    Border.all(color: t.border, width: 1.2),
                              ),
                              child: Text('一键抓取',
                                  style: TextStyle(
                                      color: t.primaryText,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      fontFamily: 'Inter')),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 元数据来源 chips（VNDB/Bangumi/DLsite 等）
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _metaChip('VNDB'),
                    _metaChip('Bangumi'),
                    _metaChip('DLsite'),
                    _metaChip('ErogameScape'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 置入区（1:1 还原 FileDropZone：border 1.6 + 80×80 folder 图标框 + 置入本地游戏文件）
        Expanded(
          child: _sel(
            elementId: 'card_cover_placeholder',
            child: Container(
              decoration: BoxDecoration(
                color: t.background,
                border: Border.all(
                    color: t.border, width: 1.6, style: BorderStyle.solid),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 80×80 folder 图标框
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: t.placeholderBg,
                        border: Border.all(color: t.border, width: 1.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.folder_outlined,
                          size: 40, color: t.border),
                    ),
                    const SizedBox(height: 16),
                    Text('置入本地游戏文件',
                        style: TextStyle(
                            fontFamily: 'ZhiMangXing',
                            fontSize: 18,
                            letterSpacing: 1.2,
                            color: t.border)),
                    const SizedBox(height: 8),
                    Text('支持 .zip 压缩包 · 拖放或点击选择',
                        style: TextStyle(
                            color: t.placeholderText,
                            fontSize: 11,
                            fontFamily: 'Inter')),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 操作按钮（1:1 还原 ActionButtons：取消 + 入库，Transform.translate -40）
        Transform.translate(
          offset: const Offset(-40, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 取消按钮
              _sel(
                elementId: 'button_bg',
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  decoration: BoxDecoration(
                    color: t.background,
                    border: Border.all(color: t.border, width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: t.border,
                          offset: const Offset(2, 3),
                          blurRadius: 0),
                    ],
                  ),
                  child: Text('取消',
                      style: TextStyle(
                          color: t.secondaryText,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Inter')),
                ),
              ),
              const SizedBox(width: 10),
              // 入库按钮（强调色）
              _sel(
                elementId: 'accent_color',
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  decoration: BoxDecoration(
                    color: t.selectedAccent,
                    border: Border.all(color: t.border, width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: t.border,
                          offset: const Offset(2, 3),
                          blurRadius: 0),
                    ],
                  ),
                  child: Text('入库',
                      style: TextStyle(
                          color: t.primaryText,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Inter')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.borderLight, width: 0.8),
      ),
      child: Text(label,
          style: TextStyle(
              color: t.secondaryText,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              fontFamily: 'Inter')),
    );
  }

  Widget _joinField(String placeholder, String eid) {
    return _sel(
      elementId: eid,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: t.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.border, width: 1.4),
        ),
        alignment: Alignment.centerLeft,
        child: Text(placeholder,
            style: TextStyle(
                color: t.placeholderText, fontSize: 14, fontFamily: 'Inter')),
      ),
    );
  }

  Widget _lineBar(double widthRatio) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthRatio,
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          color: t.placeholderBg,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  // ============ 主页（1:1 还原 HomePage：左详情面板 flex3 + 右游戏列表 320）============
  // 详情面板是杂志式布局：模糊背景 + 标签行 + 大标题 + 制作方 + 简介 + Spacer + 底部(封面+统计+启动按钮)
  Widget _buildHomeContent() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: t.hasBackgroundImage ? Colors.transparent : t.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: _buildHomeDetailPanel()),
          SizedBox(width: 320, child: _buildHomeGameList()),
        ],
      ),
    );
  }

  /// 主页详情面板（1:1 还原 _buildDetailContent：模糊背景 + 杂志式内容）
  Widget _buildHomeDetailPanel() {
    return _sel(
      elementId: 'app_card',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        child: Stack(
          children: [
            // 模糊背景层（放大封面 + 半透明遮罩，对应 _buildBlurredBackground）
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: t.placeholderCover),
                    Container(
                        color: t.background.withOpacity(0.18)),
                  ],
                ),
              ),
            ),
            // 主内容 Column（对应 _buildDetailContent 的 Column）
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标签行（对应 _buildTagRow）
                  _buildHomeTagRow(),
                  const SizedBox(height: 12),
                  // 游戏大标题（对应 _buildGameTitle，ZhiMangXing 大字）
                  _sel(
                    elementId: 'card_title',
                    child: Container(
                      height: 32,
                      width: 240,
                      decoration: BoxDecoration(
                        color: t.primaryText.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 制作方（对应 _buildDeveloper，icon + 文字）
                  Row(
                    children: [
                      Icon(Icons.business_rounded,
                          size: 14,
                          color: t.secondaryText.withOpacity(0.6)),
                      const SizedBox(width: 6),
                      Container(
                        height: 10,
                        width: 90,
                        decoration: BoxDecoration(
                          color: t.secondaryText.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 游戏简介（对应 _buildGameDescription，3 行占位）
                  _lineBar(0.92),
                  const SizedBox(height: 5),
                  _lineBar(0.85),
                  const SizedBox(height: 5),
                  _lineBar(0.7),
                  const Spacer(),
                  // 底部区域：封面卡片 + 统计 + 启动按钮（对应 _buildBottomSection）
                  _buildHomeBottomSection(),
                ],
              ),
            ),
            // 右上角游玩状态标签
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.successBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.successGreen, width: 0.8),
                ),
                child: Text('已游玩',
                    style: TextStyle(
                        color: t.successGreen,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Inter')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主页标签行（对应 _buildTagRow：几个 chip）
  Widget _buildHomeTagRow() {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _homeChip('幻想'),
        _homeChip('恋爱'),
        _homeChip('中文'),
      ],
    );
  }

  Widget _homeChip(String label) {
    return _sel(
      elementId: 'accent_color',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: t.buttonBackground.withOpacity(0.7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.border, width: 0.8),
        ),
        child: Text(label,
            style: TextStyle(
                color: t.secondaryText,
                fontSize: 10,
                fontFamily: 'Inter')),
      ),
    );
  }

  /// 主页底部区域（对应 _buildBottomSection：封面 180×240 + 统计chip + 启动按钮）
  Widget _buildHomeBottomSection() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 封面卡片（180×240，4:3，border 2，shadow）
        _sel(
          elementId: 'card_cover_placeholder',
          child: Container(
            width: 150,
            height: 200,
            decoration: BoxDecoration(
              color: t.placeholderCover,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border, width: 2),
              boxShadow: [
                BoxShadow(
                    color: t.border.withOpacity(0.15),
                    offset: const Offset(2, 3),
                    blurRadius: 6),
              ],
            ),
            child: Center(
              child: Icon(Icons.videogame_asset_rounded,
                  size: 36, color: t.border.withOpacity(0.4)),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 统计 chips（对应 _buildStatChips：游玩时长 + 上次游玩）
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _homeStatChip(Icons.schedule_outlined, '12h 30m'),
                  _homeStatChip(Icons.access_time, '昨天'),
                ],
              ),
              const SizedBox(height: 14),
              // 启动按钮（对应 _buildActionButtons，强调色大按钮）
              _sel(
                elementId: 'accent_color',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 12),
                  decoration: BoxDecoration(
                    color: t.selectedAccent,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                          color: t.border.withOpacity(0.3),
                          offset: const Offset(2, 3),
                          blurRadius: 0),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow_rounded,
                          size: 20, color: t.primaryText),
                      const SizedBox(width: 8),
                      Text('启动游戏',
                          style: TextStyle(
                              color: t.primaryText,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Inter')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _homeStatChip(IconData icon, String value) {
    return _sel(
      elementId: 'button_bg',
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: t.buttonBackground.withOpacity(0.8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.border, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: t.secondaryText),
            const SizedBox(width: 4),
            Text(value,
                style: TextStyle(
                    color: t.primaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Inter')),
          ],
        ),
      ),
    );
  }

  /// 主页游戏列表（1:1 还原 _buildGameListPanel：边框容器 + 头部 + 列表）
  Widget _buildHomeGameList() {
    return _sel(
      elementId: 'app_window',
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 16, 20, 16),
        decoration: BoxDecoration(
          border: Border.all(color: t.border, width: 2),
          borderRadius: BorderRadius.circular(12),
          color: t.background.withOpacity(0.85),
          boxShadow: [
            BoxShadow(
                color: t.border.withOpacity(0.15),
                offset: const Offset(4, 6)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部（对应 _buildListHeader：图标 + 游戏库 + 数量徽章）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.videogame_asset_rounded,
                      size: 16, color: t.border),
                  const SizedBox(width: 6),
                  Text('游戏库',
                      style: TextStyle(
                          color: t.primaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          fontFamily: 'Inter')),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: t.borderLight),
                      color: t.background,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('8 款',
                        style: TextStyle(
                            color: t.border,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Inter')),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildHomeListItems()),
          ],
        ),
      ),
    );
  }

  /// 主页列表项（对应 _buildGameListView：缩略封面 + 标题/制作方，选中态强调边框）
  Widget _buildHomeListItems() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: 6,
      itemBuilder: (context, i) => _buildHomeListItem(i == 0),
    );
  }

  Widget _buildHomeListItem(bool isActive) {
    return _sel(
      elementId: 'app_card',
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isActive ? t.cardHoverBg : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isActive
              ? Border.all(color: t.selectedAccent, width: 1.4)
              : null,
        ),
        child: Row(
          children: [
            _sel(
              elementId: 'card_cover_placeholder',
              child: Container(
                width: 36,
                height: 50,
                decoration: BoxDecoration(
                  color: t.placeholderCover,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: t.borderLight, width: 0.6),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    height: 9,
                    width: 90,
                    decoration: BoxDecoration(
                      color: t.placeholderBg,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    height: 7,
                    width: 56,
                    decoration: BoxDecoration(
                      color: t.placeholderBg.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              Icon(Icons.play_arrow_rounded,
                  size: 14, color: t.selectedAccent),
          ],
        ),
      ),
    );
  }

  // ============ 库页详情窗口（1:1 还原 GameDetailPage）============
  // Stack[Container(padding 32, Row[左 width 440 + 32gap + 右 Expanded]), 返回按钮]
  // 左：Row[封面 216×323 旋转-2° + 游戏信息(标题36 + 制作方 + 元数据 + 标签)] + 24gap + 简介
  // 右：截图大图 + Spacer + 安装按钮
  Widget _buildDetailContent() {
    return _sel(
      elementId: 'app_window',
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: t.hasBackgroundImage ? Colors.transparent : t.background,
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              height: double.infinity,
              padding: const EdgeInsets.all(32),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDetailLeftSection(),
                  const SizedBox(width: 32),
                  Expanded(child: _buildDetailRightSection()),
                ],
              ),
            ),
            // 返回按钮（左上角，对应 _buildBackButton）
            Positioned(
              left: 16,
              top: 16,
              child: _sel(
                elementId: 'button_bg',
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: t.buttonBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.border, width: 1.2),
                  ),
                  child: Icon(Icons.arrow_back_rounded,
                      size: 18, color: t.primaryText),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 详情页左区（1:1 还原 _buildLeftSection：width 440，封面+信息行 + 简介）
  Widget _buildDetailLeftSection() {
    return SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面 + 游戏信息行
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面卡片（216×323，旋转 -2°，border 2，shadow offset(4,5)）
              _buildDetailCover(),
              const SizedBox(width: 29),
              Expanded(child: _buildDetailGameInfo()),
            ],
          ),
          const SizedBox(height: 24),
          // 简介区（对应 _buildDescription）
          _buildDetailDescription(),
        ],
      ),
    );
  }

  /// 详情页封面（1:1 还原 _buildGameCover：216×323 旋转 -2°）
  Widget _buildDetailCover() {
    return _sel(
      elementId: 'card_cover_placeholder',
      child: Transform.rotate(
        angle: -2 * 3.14159 / 180,
        child: Container(
          width: 180,
          height: 270,
          decoration: BoxDecoration(
            color: t.placeholderCover,
            border: Border.all(color: t.border, width: 2),
            boxShadow: [
              BoxShadow(
                  color: t.border,
                  offset: const Offset(4, 5),
                  blurRadius: 0),
            ],
          ),
          child: Center(
            child: Icon(Icons.videogame_asset_rounded,
                size: 44, color: t.border.withOpacity(0.4)),
          ),
        ),
      ),
    );
  }

  /// 详情页游戏信息（1:1 还原 _buildGameInfo：标题36 + 制作方 + 元数据 + 标签）
  Widget _buildDetailGameInfo() {
    return Container(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题（ZhiMangXing 36，对应 titleLarge.copyWith(fontSize: 36)）
          _sel(
            elementId: 'card_title',
            child: Container(
              height: 40,
              width: double.infinity,
              decoration: BoxDecoration(
                color: t.primaryText.withOpacity(0.85),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 制作方（business icon + 文字）
          Row(
            children: [
              Icon(Icons.business_rounded,
                  size: 15, color: t.secondaryText.withOpacity(0.6)),
              const SizedBox(width: 6),
              Container(
                height: 12,
                width: 110,
                decoration: BoxDecoration(
                  color: t.secondaryText.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 元数据 chips（发售日 / 评分 / 热度 / 来源平台）
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              _detailMetaChip(Icons.event_outlined, '2024.01'),
              _detailMetaChip(Icons.star_rounded, '8.5'),
              _detailMetaChip(Icons.whatshot_rounded, '1.2k'),
            ],
          ),
          const SizedBox(height: 12),
          // 标签 Wrap（对应 tags.map(_buildTag)）
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _detailTag('幻想'),
              _detailTag('恋爱'),
              _detailTag('冒险'),
              _detailTag('中文'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailMetaChip(IconData icon, String value) {
    return _sel(
      elementId: 'state_info',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: t.secondaryText),
          const SizedBox(width: 3),
          Text(value,
              style: TextStyle(
                  color: t.secondaryText,
                  fontSize: 11,
                  fontFamily: 'Inter')),
        ],
      ),
    );
  }

  Widget _detailTag(String label) {
    return _sel(
      elementId: 'accent_color',
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: t.buttonBackground,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: t.border, width: 0.8),
        ),
        child: Text(label,
            style: TextStyle(
                color: t.primaryText,
                fontSize: 11,
                fontFamily: 'Inter')),
      ),
    );
  }

  /// 详情页简介（对应 _buildDescription：标题 + 多行占位）
  Widget _buildDetailDescription() {
    return _sel(
      elementId: 'text_secondary',
      child: Container(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('简介',
                style: TextStyle(
                    color: t.primaryText,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Inter')),
            const SizedBox(height: 8),
            _lineBar(0.98),
            const SizedBox(height: 5),
            _lineBar(0.95),
            const SizedBox(height: 5),
            _lineBar(0.9),
            const SizedBox(height: 5),
            _lineBar(0.85),
            const SizedBox(height: 5),
            _lineBar(0.6),
          ],
        ),
      ),
    );
  }

  /// 详情页右区（1:1 还原 _buildRightSection：截图大图 + Spacer + 安装按钮）
  Widget _buildDetailRightSection() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        // 截图大图（对应 ScreenshotCarousel，大块占位）
        _sel(
          elementId: 'card_cover_placeholder',
          child: Container(
            height: 320,
            decoration: BoxDecoration(
              color: t.placeholderCover,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border, width: 1.4),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_library_outlined,
                      size: 48, color: t.border.withOpacity(0.4)),
                  const SizedBox(height: 8),
                  Text('游戏截图',
                      style: TextStyle(
                          color: t.placeholderText,
                          fontSize: 13,
                          fontFamily: 'Inter')),
                ],
              ),
            ),
          ),
        ),
        const Spacer(),
        // 安装按钮（对应 _buildIdleUI，强调色大按钮 + 文件大小）
        _sel(
          elementId: 'accent_color',
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 32, vertical: 16),
            decoration: BoxDecoration(
              color: t.selectedAccent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                    color: t.border.withOpacity(0.3),
                    offset: const Offset(2, 3),
                    blurRadius: 0),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_rounded,
                    size: 20, color: t.primaryText),
                const SizedBox(width: 10),
                Text('安装游戏',
                    style: TextStyle(
                        color: t.primaryText,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Inter')),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.background.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('4.2 GB',
                      style: TextStyle(
                          color: t.primaryText,
                          fontSize: 11,
                          fontFamily: 'Inter')),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // _sel 包装器已在类顶部定义
}

/// v3.0 P2：可选中的元素包装器（点击/双击 + 选中高亮 + 悬停覆盖）
class _SelectableElement extends StatefulWidget {
  final String elementId;
  final String? selectedId;
  final ValueChanged<String> onTap;
  final ValueChanged<String> onDoubleTap;
  final Widget child;

  const _SelectableElement({
    required this.elementId,
    required this.selectedId,
    required this.onTap,
    required this.onDoubleTap,
    required this.child,
  });

  @override
  State<_SelectableElement> createState() => _SelectableElementState();
}

class _SelectableElementState extends State<_SelectableElement> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.selectedId == widget.elementId;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onTap(widget.elementId),
        onDoubleTap: () => widget.onDoubleTap(widget.elementId),
        child: Stack(
          children: [
            widget.child,
            if (_isHovered && !isSelected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      border: Border.all(
                          color: Colors.blue.withOpacity(0.5), width: 1.0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            if (isSelected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border:
                          Border.all(color: Colors.blue, width: 2.0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
