import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/collection_service.dart';
import '../../theme/app_colors.dart';
import 'panel_hover_builder.dart';

// =============================================================================
// 分类匣（CategoryBox）—— 库页右侧分类侧栏
//
// 由原「收藏夹栏」整体改造而来（features/category_box.md），按「用户分类 /
// 系统分类」组织为三个视图，头部下拉切换：
// 1. 收藏夹（用户分类）：用户自建收藏夹 —— 逻辑与原侧栏完全一致（进入 /
//    拖拽归类 / 悬停编辑 / 新建），仅 UI 换新。
// 2. 标签库（系统分类）：种子分类法（题材/体验…）+ 库内派生计数；
//    标签可多选（并集过滤），拖卡片到标签 = 写穿加标签。
// 3. 会社墙（系统分类）：示例会社 + 有游戏的词典会社 + 自定义会社；
//    点卡片 = 按会社过滤，拖卡片 = 写穿设会社，「+ 关注」落盘。
//
// 几何规格来自 Figma「Sidebar - 分类匣」（1280x720 @1x）：
// - 侧栏总宽 324（含 1px 左缘描边 + 右侧 24px 留白列），内容列 ≈299
// - Header 高 55.2 / 搜索框高 28.8 / 下拉面板宽 235.2 / 会社卡 127x131 两列
// - 颜色一律映射 AppColors 语义令牌（设计稿暖米色在深色主题下由令牌自适应）
// =============================================================================

/// 分类匣视图。
enum CategoryBoxTab {
  /// 收藏夹（用户分类）
  favorites,

  /// 标签库（系统分类）
  tags,

  /// 会社墙（系统分类）
  companies,
}

extension CategoryBoxTabMeta on CategoryBoxTab {
  String get label => switch (this) {
        CategoryBoxTab.favorites => '收藏夹',
        CategoryBoxTab.tags => '标签库',
        CategoryBoxTab.companies => '会社墙',
      };

  /// 下拉条目与视图头部共用的一句副题（Figma 文案）。
  String get subtitle => switch (this) {
        CategoryBoxTab.favorites => '收好每一份心动',
        CategoryBoxTab.tags => '用标签串起游戏偏好',
        CategoryBoxTab.companies => '发现作品背后的创作者',
      };

  IconData get icon => switch (this) {
        CategoryBoxTab.favorites => Icons.folder_open_outlined,
        CategoryBoxTab.tags => Icons.local_offer_outlined,
        CategoryBoxTab.companies => Icons.home_work_outlined,
      };
}

/// 标签库视图的单个标签条目（父级构建，含派生计数与选中态）。
@immutable
class CategoryBoxTag {
  const CategoryBoxTag({
    required this.key,
    required this.name,
    required this.count,
    this.dotColor,
    this.selected = false,
    this.hidden = false,
    this.writeTarget,
    this.isConcept = false,
  });

  /// 稳定键（`tag:<标签名>`，与 SmartGroupService 同口径）。
  final String key;
  final String name;

  /// 圆点色（null = 由 UI 哈希调色板兜底）。
  final Color? dotColor;
  final int count;
  final bool selected;

  /// 被用户隐藏（全局隐藏：普通模式不渲染，编辑模式画斜眼可恢复）。
  final bool hidden;

  /// 写穿匹配的底层标签（重命名/删除时按它归一化匹配游戏数据；
  /// null = 用 [name]。概念标签 = 规范名（游戏里存的就是它），
  /// 未归类标签 = 原文。
  final String? writeTarget;

  /// 是否受控词表概念（决定重命名后的覆盖层键迁移方向）。
  final bool isConcept;
}

/// 标签库视图的一个大分组（如「玩法结构」「其他」）。
@immutable
class CategoryBoxTagSection {
  const CategoryBoxTagSection({
    required this.title,
    required this.tags,
    this.dimId = '',
    this.isUserDim = false,
  });

  final String title;
  final List<CategoryBoxTag> tags;

  /// 维度 id（内联编辑模式的拖拽目标；空 = 旧「其他」分区无 id）。
  final String dimId;

  /// 是否用户新增维度（编辑模式 UI 标记）。
  final bool isUserDim;
}

/// 会社墙视图的单张会社卡片数据（父级构建）。
@immutable
class CategoryBoxCompany {
  const CategoryBoxCompany({
    required this.key,
    required this.name,
    required this.subName,
    required this.logoText,
    required this.logoBg,
    required this.logoFg,
    required this.gameCount,
    required this.followed,
    this.isCustom = false,
    this.logoPath,
    this.vndbId,
    this.nameCandidates = const [],
    this.standardName,
  });

  /// 过滤/拖拽键：词典会社 `devId:<id>`，自定义会社 `dev:<名称>`。
  final String key;
  final String name;
  final String subName;
  final String logoText;
  final Color logoBg;
  final Color logoFg;
  final int gameCount;
  final bool followed;
  final bool isCustom;

  /// 会社图标绝对路径（null/文件不存在 = 回退衬线字标）。
  final String? logoPath;

  /// VNDB producer id（如 `p98`；自定义会社通常为 null）——图标抓取锚点。
  final String? vndbId;

  /// 图标抓取时依次尝试的名字（[中文名, 日文名, 标准名]）。
  final List<String> nameCandidates;

  /// 词典标准名（显示名覆盖的还原基准；自定义会社 = name）。
  final String? standardName;

  /// 编辑会社信息弹窗所需的存储键（词典会社 = `"<id>"`）。
  String get storeKey => key.startsWith('devId:') ? key.substring(6) : key;
}

/// 会社卡 logo 区的柔和底色 + 配套前景色（取色自设计稿四卡）。
const List<(Color, Color)> kCompanyTintPairs = [
  (Color(0xFFE7EDE2), Color(0xFF7E9678)), // 鼠尾草绿
  (Color(0xFFF2E9D8), Color(0xFFB08D4A)), // 奶油米黄
  (Color(0xFFF2E4E4), Color(0xFFB98A8A)), // 樱贝粉
  (Color(0xFFE9E6F2), Color(0xFF8D86B5)), // 藤紫
  (Color(0xFFE4EEF0), Color(0xFF6F9BA5)), // 青瓷
  (Color(0xFFEFE7DA), Color(0xFF9A8468)), // 亚麻棕
];

/// 未在种子表中的标签圆点色兜底调色板（低饱和，贴合整体米色调）。
const List<Color> kFallbackDotColors = [
  Color(0xFFC96F6F),
  Color(0xFF7FA76F),
  Color(0xFF9B85C9),
  Color(0xFFD4A94E),
  Color(0xFF6F8FC0),
  Color(0xFF6FAFA5),
  Color(0xFFC98D5A),
  Color(0xFFC97FA0),
];

Color fallbackDotColor(String key) =>
    kFallbackDotColors[key.hashCode.abs() % kFallbackDotColors.length];

(Color, Color) companyTintFor(String key) =>
    kCompanyTintPairs[key.hashCode.abs() % kCompanyTintPairs.length];

// =============================================================================
// 侧栏本体
// =============================================================================

class CategoryBoxSidebar extends StatefulWidget {
  CategoryBoxSidebar({
    super.key,
    required this.open,
    required this.onClose,
    // —— 收藏夹视图（与原 CollectionSidebar 契约一致）——
    required this.collections,
    required this.activeCollectionId,
    required this.gameCountOf,
    required this.itemKeys,
    required this.dropTargetId,
    required this.onEnterCollection,
    required this.onCreate,
    required this.onEdit,
    // —— 标签库视图 ——
    required this.tagSections,
    required this.onToggleTag,
    // —— 标签库内联编辑（2026-10-04 升级）——
    required this.onRenameTag,
    required this.onRemoveTag,
    required this.onToggleHideTag,
    required this.onMoveTagToDim,
    required this.onRenameDimension,
    required this.onAddDimension,
    // —— 会社墙视图 ——
    required this.companies,
    required this.onEnterCompany,
    required this.onToggleFollowCompany,
    required this.onAddCompany,
    required this.onEditCompany,
    // —— 标签/会社共用的拖拽投放命中表（原智能归纳机制复用）——
    required this.smartItemKeys,
    required this.smartDropTargetId,
  });

  /// 面板总宽（含左缘描边与右侧留白列）。
  static const double kWidth = 324;

  final bool open;
  final VoidCallback onClose;

  // 收藏夹
  final List<GameCollection> collections;
  final String activeCollectionId;
  final int Function(String collectionId) gameCountOf;
  final Map<String, GlobalKey> itemKeys;
  final ValueListenable<String?> dropTargetId;
  final ValueChanged<String> onEnterCollection;
  final VoidCallback onCreate;
  final ValueChanged<GameCollection> onEdit;

  // 标签库
  final List<CategoryBoxTagSection> tagSections;
  final ValueChanged<String> onToggleTag;

  // 标签库内联编辑（全部回调在库页实现：确认弹窗 + 写穿 / 覆盖层落盘）
  //
  // [onRenameTag]：全局写穿重命名（库页负责二次确认，不可逆）；
  // [onRemoveTag]：从所有游戏删除（写穿，不可逆）；
  // [onToggleHideTag]：隐藏/恢复（覆盖层，全局生效）；
  // [onMoveTagToDim]：改挂维度（tagKey → 目标维度 id）；
  // [onRenameDimension] / [onAddDimension]：维度改名 / 新增。
  final void Function(String writeTarget, String displayName) onRenameTag;
  final void Function(String writeTarget, String displayName) onRemoveTag;

  /// 隐藏/恢复（[writeTarget] = 写穿匹配的底层标签，覆盖层按归一化记键）。
  final void Function(String writeTarget, bool hide) onToggleHideTag;
  final void Function(String tagKey, String dimId) onMoveTagToDim;
  final void Function(String dimId, String newTitle) onRenameDimension;
  final void Function(String title) onAddDimension;

  // 会社墙
  final List<CategoryBoxCompany> companies;
  final ValueChanged<String> onEnterCompany;
  final ValueChanged<CategoryBoxCompany> onToggleFollowCompany;
  final VoidCallback onAddCompany;

  /// 打开「编辑会社信息」弹窗（会社卡片右上角圆形按钮）。
  final ValueChanged<CategoryBoxCompany> onEditCompany;

  // 标签/会社拖拽投放（键 = tag:* / dev:* / devId:*，与命中检测契约同原侧栏）
  final Map<String, GlobalKey> smartItemKeys;
  final ValueListenable<String?> smartDropTargetId;

  @override
  State<CategoryBoxSidebar> createState() => _CategoryBoxSidebarState();
}

class _CategoryBoxSidebarState extends State<CategoryBoxSidebar> {
  CategoryBoxTab _tab = CategoryBoxTab.favorites;
  bool _switcherOpen = false;

  final TextEditingController _favSearch = TextEditingController();
  final TextEditingController _tagSearch = TextEditingController();
  final TextEditingController _coSearch = TextEditingController();

  /// 会社墙列表页签（全部会社 / 已关注）。
  bool _coShowFollowedOnly = false;

  // —— 标签库内联编辑模式（2026-10-04 升级）——
  /// 编辑模式总开关（底栏「编辑标签」⇄「完成编辑」）。
  bool _tagEditMode = false;

  /// 正在改名的维度 id（null = 无；点击维度标题 ✎ 进入，失焦/回车提交）。
  String? _editingDimId;

  /// 正在新增维度的输入行显示中。
  bool _addingDim = false;

  // —— 会社墙卡片（2026-10-04 回归原版两列方块 + logo 显示适配）——
  //
  // 卡片结构 = 原版两段式：上 64 高 logo 区（tint 底）+ 下不透明信息区，
  // GridView 两列固定行高。唯一适配点：logo 由 BoxFit.cover（会裁掉
  // 横长条 logo 如 Navel）改为 BoxFit.contain（tint 底上完整居中显示，
  // 零裁切；左右留白由 tint 底色自然承接，与字标回退观感一致）。

  @override
  void dispose() {
    _favSearch.dispose();
    _tagSearch.dispose();
    _coSearch.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 骨架
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !widget.open,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: widget.open ? CategoryBoxSidebar.kWidth : 0,
        child: ClipRect(
          child: SizedBox(
            width: CategoryBoxSidebar.kWidth,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border(
                  left: BorderSide(color: AppColors.border, width: 1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.13),
                    offset: const Offset(-4, 5),
                    blurRadius: 0,
                  ),
                ],
              ),
              // Figma：内容列右侧固定 24px 留白（'Sidebar - 分类匣' paddingRight）
              child: Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(),
                        Expanded(child: _buildBody()),
                        _buildFooter(),
                      ],
                    ),
                    // 切换下拉（覆盖在内容区之上）
                    if (_switcherOpen) _buildSwitcherLayer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header：视图切换触发按钮 + 「分类匣」pill + 关闭
  // ---------------------------------------------------------------------------

  Widget _buildHeader() {
    return Container(
      height: 55.2,
      padding: const EdgeInsets.only(left: 16.8, right: 13.6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          _buildSwitcherTrigger(),
          const Spacer(),
          // 「分类匣」pill：与触发按钮等价，打开/关闭切换下拉
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _toggleSwitcher,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.borderLight),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '分类匣',
                  style: _ts(fontSize: 9.6, color: AppColors.secondaryText),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _buildCloseButton(),
        ],
      ),
    );
  }

  /// 视图切换触发按钮：图标 + 标题 + 箭头（展开时旋转 180°）。
  Widget _buildSwitcherTrigger() {
    return PanelHoverBuilder(
      builder: (isHovered) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _toggleSwitcher,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.fromLTRB(0, 6.4, 6.4, 6.4),
              decoration: BoxDecoration(
                color: isHovered || _switcherOpen
                    ? AppColors.cardHoverBg
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_tab.icon,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8.8),
                  Text(
                    _tab.label,
                    style: _ts(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                      color: AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _switcherOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          width: 21.6,
          height: 21.6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3.2),
          ),
          child: Icon(Icons.close, size: 15, color: AppColors.secondaryText),
        ),
      ),
    );
  }

  void _toggleSwitcher() => setState(() => _switcherOpen = !_switcherOpen);

  // ---------------------------------------------------------------------------
  // 切换下拉（Figma 235.2 宽面板，选中态 #f4ede3 → cardHoverBg）
  // ---------------------------------------------------------------------------

  Widget _buildSwitcherLayer() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 屏障：点面板以外任意处关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _switcherOpen = false),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            top: 60,
            left: 12,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 235.2,
                padding: const EdgeInsets.all(6.4),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(6.4),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.shadowColor.withOpacity(0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(9.6, 6.4, 9.6, 6.4),
                      child: Text(
                        '分类匣 · 切换视图',
                        style: _ts(
                          fontSize: 8.8,
                          letterSpacing: 1.5,
                          color: AppColors.placeholderText,
                        ),
                      ),
                    ),
                    for (final tab in CategoryBoxTab.values)
                      _buildSwitcherItem(tab),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitcherItem(CategoryBoxTab tab) {
    final selected = tab == _tab;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _tab = tab;
            _switcherOpen = false;
          });
        },
        child: Container(
          padding: const EdgeInsets.all(9.6),
          decoration: BoxDecoration(
            color: selected ? AppColors.cardHoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(3.2),
          ),
          child: Row(
            children: [
              Icon(tab.icon, size: 16, color: AppColors.secondaryText),
              const SizedBox(width: 9.6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tab.label,
                      style: _ts(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tab.subtitle,
                      style: _ts(
                          fontSize: 8.8, color: AppColors.placeholderText),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded,
                    size: 14, color: AppColors.secondaryText),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Body：三视图分发
  // ---------------------------------------------------------------------------

  Widget _buildBody() {
    switch (_tab) {
      case CategoryBoxTab.favorites:
        return _buildFavoritesView();
      case CategoryBoxTab.tags:
        return _buildTagsView();
      case CategoryBoxTab.companies:
        return _buildCompaniesView();
    }
  }

  /// 视图头部：左侧一句副题 + 右侧计数（衬线小字，Figma 双色 #a18c75/#ad9780
  /// → secondaryText / placeholderText）。
  Widget _buildSubtitleRow(String subtitle, String countText) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              subtitle,
              style: _ts(fontSize: 9.6, color: AppColors.secondaryText),
            ),
          ),
          Text(
            countText,
            style: _tsSerif(fontSize: 9.6, color: AppColors.placeholderText),
          ),
        ],
      ),
    );
  }

  /// 搜索框（Figma Label：高 28.8 / radius 4 / bg #faf6ef / 边 #e0d5c5）。
  Widget _buildSearchField(
      TextEditingController controller, String hintText) {
    return Container(
      height: 28.8,
      margin: const EdgeInsets.only(bottom: 17.6),
      padding: const EdgeInsets.symmetric(horizontal: 9.6),
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        border: Border.all(color: AppColors.borderLight, width: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded,
              size: 12, color: AppColors.placeholderText),
          const SizedBox(width: 6.4),
          Expanded(
            child: TextField(
              controller: controller,
              style: _ts(fontSize: 9.6, color: AppColors.primaryText),
              cursorColor: AppColors.selectedAccent,
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle:
                    _ts(fontSize: 9.6, color: AppColors.placeholderText),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组标题行：标题 + 弹性细线 + 右侧计数（Figma Section header）。
  Widget _buildSectionHeader(String title, String countText) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9.6),
      child: Row(
        children: [
          Text(
            title,
            style: _ts(
              fontSize: 9.6,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 6.4),
          Expanded(child: Container(height: 1, color: AppColors.borderLight)),
          const SizedBox(width: 6.4),
          Text(
            countText,
            style: _tsSerif(fontSize: 9.6, color: AppColors.placeholderText),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 视图一：收藏夹（用户分类）
  // ===========================================================================

  Widget _buildFavoritesView() {
    final query = _favSearch.text.trim();
    final visible = query.isEmpty
        ? widget.collections
        : widget.collections
            .where((c) => c.name.toLowerCase().contains(query.toLowerCase()))
            .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(17.6, 18.4, 17.6, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSubtitleRow(CategoryBoxTab.favorites.subtitle,
              '${widget.collections.length} 个收藏夹'),
          _buildSearchField(_favSearch, '搜索收藏夹...'),
          // 「我的收藏」节头（Figma：标题 + 弹性细线）
          _buildSectionHeader('我的收藏', ''),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: widget.dropTargetId,
              builder: (context, droppingId, _) {
                return _buildFavoritesList(visible, droppingId, query.isEmpty);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesList(
      List<GameCollection> visible, String? droppingId, bool unfiltered) {
    // 空库（连预设都没有）或搜索无结果：整块提示
    if (widget.collections.isEmpty) {
      return _buildFavoritesHint();
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的收藏夹',
          style: _ts(fontSize: 9.6, color: AppColors.placeholderText),
        ),
      );
    }

    final hasUserCollections =
        widget.collections.any((c) => !c.isPreset);
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: visible.length + 1,
      itemBuilder: (context, index) {
        if (index < visible.length) {
          return _buildCollectionEntry(visible[index], droppingId);
        }
        // 尾部：未自建任何收藏夹时展示留白提示（Figma 虚线块）
        if (unfiltered && !hasUserCollections) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _buildFavoritesHint(),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildCollectionEntry(GameCollection c, String? droppingId) {
    final isActive = c.id == widget.activeCollectionId;
    final isDropping = droppingId == c.id;
    final count = widget.gameCountOf(c.id);
    // Figma 条目图标：文件夹描边 / 特别关注 = 实心琥珀星
    final isStar = c.iconKind == GameCollection.kIconStar;
    final iconColor =
        isStar ? AppColors.starGold : AppColors.secondaryText;

    return PanelHoverBuilder(
      builder: (isHovered) {
        return GestureDetector(
          onTap: () => widget.onEnterCollection(c.id),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              key: widget.itemKeys[c.id],
              margin: const EdgeInsets.only(bottom: 2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              decoration: BoxDecoration(
                color: isDropping
                    ? AppColors.selectedAccent.withOpacity(0.14)
                    : isActive
                        ? AppColors.selectedAccent.withOpacity(0.08)
                        : isHovered
                            ? AppColors.cardHoverBg
                            : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: isDropping
                    ? Border.all(color: AppColors.selectedAccent, width: 2)
                    : isActive
                        ? Border.all(
                            color:
                                AppColors.selectedAccent.withOpacity(0.5))
                        : null,
              ),
              child: Row(
                children: [
                  Icon(
                    isStar
                        ? Icons.star_rounded
                        : Icons.folder_open_outlined,
                    size: 18,
                    color: iconColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _ts(
                        fontSize: 13,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                  // 置顶图钉（预设恒置顶）
                  if (c.isPinnedTop)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.push_pin,
                          size: 11, color: AppColors.placeholderText),
                    ),
                  Text(
                    '$count',
                    style: _tsSerif(
                        fontSize: 10, color: AppColors.secondaryText),
                  ),
                  const SizedBox(width: 2),
                  // 悬停编辑入口（重命名/改色/删除）
                  if (isHovered)
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => widget.onEdit(c),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.edit_outlined,
                              size: 14, color: AppColors.secondaryText),
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 22),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 收藏夹留白提示（Figma：虚线 + 文件夹 + 三行文案）。
  Widget _buildFavoritesHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          _DashedLine(color: AppColors.borderLight),
          const SizedBox(height: 19.2),
          Icon(Icons.folder_open_outlined,
              size: 26, color: AppColors.placeholderText),
          const SizedBox(height: 10),
          Text(
            '为喜欢的作品，留一个位置',
            style: _tsSerif(fontSize: 11, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 8),
          Text(
            '按游玩计划、心情或主题整理\n你的下一段游戏时光',
            textAlign: TextAlign.center,
            style: _ts(fontSize: 8.8, color: AppColors.placeholderText),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 视图二：标签库（系统分类）
  // ===========================================================================

  Widget _buildTagsView() {
    final query = _tagSearch.text.trim().toLowerCase();
    final sections = widget.tagSections
        .map((s) => CategoryBoxTagSection(
              title: s.title,
              dimId: s.dimId,
              isUserDim: s.isUserDim,
              tags: query.isEmpty
                  ? s.tags
                  : s.tags
                      .where((t) => t.name.toLowerCase().contains(query))
                      .toList(),
            ))
        .where((s) => s.tags.isNotEmpty || (_tagEditMode && s.dimId.isNotEmpty))
        .toList();

    return ValueListenableBuilder<String?>(
      valueListenable: widget.smartDropTargetId,
      builder: (context, droppingKey, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(17.6, 18.4, 17.6, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSubtitleRow(
                  CategoryBoxTab.tags.subtitle,
                  '${widget.tagSections.fold<int>(0, (n, s) => n + s.tags.length)} 个标签'),
              _buildSearchField(_tagSearch, '搜索标签...'),
              // 编辑模式：新增维度入口（用户自定义维度，系统不自动归类）
              if (_tagEditMode) _buildAddDimRow(),
              Expanded(
                child: sections.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的标签',
                          style: _ts(
                              fontSize: 9.6,
                              color: AppColors.placeholderText),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: sections.length + 1,
                        itemBuilder: (context, index) {
                          if (index < sections.length) {
                            return _buildTagSection(
                                sections[index], droppingKey);
                          }
                          // 尾部说明块（Figma 文案；编辑模式换整理提示）
                          return _tagEditMode
                              ? _buildEditNote()
                              : _buildTagsNote();
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 编辑模式：「＋ 新增维度」按钮 ⇄ 输入行。
  Widget _buildAddDimRow() {
    if (!_addingDim) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() => _addingDim = true),
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.borderLight,
                  width: 0.6,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded,
                      size: 12, color: AppColors.secondaryText),
                  const SizedBox(width: 5),
                  Text('新增维度',
                      style: _ts(
                          fontSize: 10, color: AppColors.secondaryText)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: _DimRenameField(
        initial: '',
        autofocus: true,
        hint: '维度名称，回车确认',
        onSubmit: (t) {
          setState(() => _addingDim = false);
          if (t.trim().isNotEmpty) widget.onAddDimension(t.trim());
        },
        onCancel: () => setState(() => _addingDim = false),
      ),
    );
  }

  /// 编辑模式尾部提示（开发者要求的两条说明）。
  Widget _buildEditNote() {
    return Container(
      padding: const EdgeInsets.only(top: 12.8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.6),
        ),
      ),
      child: Text(
        '修改维度标题或标签归属，不会更改筛选内容；\n'
        '新增维度系统不做自动归类，标签需自行整理。\n'
        '重命名/删除会写穿全部游戏数据，操作前会再确认。',
        style: _ts(fontSize: 8.8, height: 1.7, color: AppColors.placeholderText),
      ),
    );
  }

  Widget _buildTagSection(CategoryBoxTagSection section, String? droppingKey) {
    final editing = _tagEditMode;
    final hasDim = section.dimId.isNotEmpty;

    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editing && hasDim)
          _buildEditableSectionHeader(section)
        else
          _buildSectionHeader(section.title, '${section.tags.length}'),
        // ⚠️ 探索大厅同款布局坑：右栏内容宽度极窄，标签行必须 Wrap +
        //    子项内 IntrinsicWidth，禁止 Row+Spacer（main.dart:488 同源）
        Wrap(
          spacing: 6.4,
          runSpacing: 6.4,
          children: [
            // 隐藏标签：普通模式不渲染；编辑模式显示（斜眼样式，可恢复）
            for (final tag in section.tags)
              if (!tag.hidden || editing)
                IntrinsicWidth(
                    child: _buildTagChip(tag, droppingKey, editing: editing)),
          ],
        ),
      ],
    );

    // 编辑模式：整个分区是拖拽目标（标签跨维度拖动）
    if (editing && hasDim) {
      // ⚠️ Dart 闭包捕获的是「变量」而非「值」：body 随后被重新赋值为 DragTarget
      //    本身，若 builder 直接引用 body 会自包含递归 → 挂载时无限嵌套 →
      //    栈溢出 / release 灰屏（真机「编辑标签变灰块」根因，2026-10-04）。
      //    必须先快照当前值再进 builder。
      final sectionBody = body;
      body = DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
        onAcceptWithDetails: (details) =>
            widget.onMoveTagToDim(details.data, section.dimId),
        builder: (context, candidate, _) {
          final hovering = candidate.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: hovering
                  ? Border.all(color: AppColors.selectedAccent, width: 1.4)
                  : null,
              color: hovering
                  ? AppColors.selectedAccent.withOpacity(0.07)
                  : null,
            ),
            padding: hovering
                ? const EdgeInsets.all(6)
                : EdgeInsets.zero,
            child: sectionBody,
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 22.4),
      child: body,
    );
  }

  /// 编辑模式下的维度标题行：✎ 进入改名（TextField），回车/失焦提交。
  Widget _buildEditableSectionHeader(CategoryBoxTagSection section) {
    final dimId = section.dimId;
    final isEditingThis = _editingDimId == dimId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: isEditingThis
                ? _DimRenameField(
                    initial: section.title,
                    onSubmit: (t) {
                      setState(() => _editingDimId = null);
                      if (t.trim().isNotEmpty && t.trim() != section.title) {
                        widget.onRenameDimension(dimId, t.trim());
                      }
                    },
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _editingDimId = dimId),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            section.title,
                            style: _ts(
                              fontSize: 10.4,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.2,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.edit_outlined,
                            size: 11, color: AppColors.placeholderText),
                        if (section.isUserDim) ...[
                          const SizedBox(width: 4),
                          Text(
                            '自定义',
                            style: _ts(
                                fontSize: 8,
                                color: AppColors.placeholderText),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          Text(
            '${section.tags.length}',
            style: _tsSerif(fontSize: 9.6, color: AppColors.placeholderText),
          ),
        ],
      ),
    );
  }

  Widget _buildTagChip(CategoryBoxTag tag, String? droppingKey,
      {bool editing = false}) {
    final isDropping = droppingKey == tag.key;
    final dot = tag.dotColor ?? fallbackDotColor(tag.key);
    final hidden = tag.hidden;
    return PanelHoverBuilder(
      builder: (isHovered) {
        Widget chip = MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            // 编辑模式：点 chip 也弹管理菜单（编辑模式不做筛选选择）
            onTap: () =>
                editing ? _showTagMenu(tag, context) : widget.onToggleTag(tag.key),
            child: Container(
              key: widget.smartItemKeys[tag.key],
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: isDropping
                    ? AppColors.selectedAccent.withOpacity(0.14)
                    : hidden
                        ? AppColors.placeholderBg.withOpacity(0.45)
                        : tag.selected
                            ? AppColors.cardHoverBg
                            : isHovered
                                ? AppColors.placeholderBg
                                : AppColors.background,
                borderRadius: BorderRadius.circular(4),
                border: isDropping
                    ? Border.all(color: AppColors.selectedAccent, width: 2)
                    : Border.all(
                        color: hidden
                            ? AppColors.borderLight.withOpacity(0.5)
                            : tag.selected
                                ? AppColors.selectedAccent.withOpacity(0.6)
                                : AppColors.borderLight,
                        width: tag.selected ? 1.2 : 0.6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hidden)
                    // 隐藏态：斜眼图标替代色点（与 NSFW 打码同款视觉语义）
                    Icon(Icons.visibility_off_outlined,
                        size: 9, color: AppColors.placeholderText)
                  else
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                          color: dot, shape: BoxShape.circle),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    tag.name,
                    style: _ts(
                      fontSize: 10.5,
                      fontWeight:
                          tag.selected ? FontWeight.w600 : FontWeight.w400,
                      color: hidden
                          ? AppColors.placeholderText
                          : AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${tag.count}',
                    style: _tsSerif(
                        fontSize: 9.6,
                        color: hidden
                            ? AppColors.placeholderText.withOpacity(0.6)
                            : AppColors.placeholderText),
                  ),
                  if (editing) ...[
                    const SizedBox(width: 5),
                    _TagMenuDot(onTap: () => _showTagMenu(tag, context)),
                  ],
                ],
              ),
            ),
          ),
        );
        // 编辑模式：chip 可拖拽（拖到目标维度分区 = 改挂维度）
        if (editing) {
          chip = Draggable<String>(
            data: tag.key,
            feedback: _DragChipFeedback(label: tag.name),
            dragAnchorStrategy: pointerDragAnchorStrategy,
            childWhenDragging: Opacity(opacity: 0.35, child: chip),
            child: chip,
          );
        }
        return chip;
      },
    );
  }

  /// 标签管理菜单（编辑模式 ⚙ / 点 chip 触发）。
  Future<void> _showTagMenu(CategoryBoxTag tag, BuildContext ctx) async {
    final box = ctx.findRenderObject() as RenderBox?;
    final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final size = box?.size ?? Size.zero;
    final action = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy + size.height, pos.dx + size.width, pos.dy),
      color: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.border, width: 0.6),
      ),
      items: [
        _menuItem('rename', Icons.drive_file_rename_outline_outlined,
            '重命名（写穿全部游戏）'),
        _menuItem(
            tag.hidden ? 'show' : 'hide',
            tag.hidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            tag.hidden ? '取消隐藏' : '隐藏（全局）'),
        const PopupMenuDivider(),
        _menuItem(
            'remove', Icons.delete_outline, '从所有游戏中删除', danger: true),
      ],
    );
    if (action == null) return;
    final writeTarget = tag.writeTarget ?? tag.name;
    switch (action) {
      case 'rename':
        widget.onRenameTag(writeTarget, tag.name);
        break;
      case 'remove':
        widget.onRemoveTag(writeTarget, tag.name);
        break;
      case 'hide':
        widget.onToggleHideTag(writeTarget, true);
        break;
      case 'show':
        widget.onToggleHideTag(writeTarget, false);
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
      {bool danger = false}) {
    final color = danger ? AppColors.dangerRed : AppColors.secondaryText;
    return PopupMenuItem<String>(
      value: value,
      height: 34,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 8),
          Text(label, style: _ts(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  /// 切换标签库编辑模式（底栏按钮 / 完成编辑）。
  void _toggleTagEditMode() {
    setState(() {
      _tagEditMode = !_tagEditMode;
      _editingDimId = null;
      _addingDim = false;
    });
  }

  Widget _buildTagsNote() {
    return Container(
      padding: const EdgeInsets.only(top: 12.8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.6),
        ),
      ),
      child: Text(
        '按维度分类归纳，同义标签自动归并。\n同一维度内多选取并集，不同维度之间取交集。',
        style: _ts(fontSize: 8.8, height: 1.7, color: AppColors.placeholderText),
      ),
    );
  }

  // ===========================================================================
  // 视图三：会社墙（系统分类）
  // ===========================================================================

  Widget _buildCompaniesView() {
    final query = _coSearch.text.trim().toLowerCase();
    var visible = widget.companies;
    if (_coShowFollowedOnly) {
      visible = visible.where((c) => c.followed).toList();
    }
    if (query.isNotEmpty) {
      visible = visible
          .where((c) =>
              c.name.toLowerCase().contains(query) ||
              c.subName.toLowerCase().contains(query))
          .toList();
    }
    final followedCount =
        widget.companies.where((c) => c.followed).length;

    return ValueListenableBuilder<String?>(
      valueListenable: widget.smartDropTargetId,
      builder: (context, droppingKey, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(17.6, 18.4, 17.6, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSubtitleRow(
                  CategoryBoxTab.companies.subtitle, '$followedCount 家已关注'),
              _buildSearchField(_coSearch, '搜索会社...'),
              _buildCompanyTabs(followedCount),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _coShowFollowedOnly
                              ? '还没有关注任何会社\n点击卡片上的「+ 关注」即可收藏'
                              : '没有匹配的会社',
                          textAlign: TextAlign.center,
                          style: _ts(
                              fontSize: 9.6,
                              height: 1.7,
                              color: AppColors.placeholderText),
                        ),
                      )
                    // 两列方块网格（原版格局）；logo 区做正方形 →
                    // 行高 = 卡宽（正方形 logo 区）+ 信息区固定高
                    : LayoutBuilder(builder: (context, box) {
                        const gap = 9.6;
                        final cardW = (box.maxWidth - gap) / 2;
                        return GridView.builder(
                          padding: const EdgeInsets.only(top: 2, bottom: 8),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: gap,
                            mainAxisSpacing: gap,
                            mainAxisExtent: cardW + _companyInfoH,
                          ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) =>
                              _buildCompanyCard(visible[index], droppingKey, cardW),
                        );
                      }),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 页签行：「全部会社 / 已关注 N」（会社墙纯派生，不再有示例/自定义筛选）。
  Widget _buildCompanyTabs(int followedCount) {
    Widget tab(String label, bool active, VoidCallback onTap,
        {int? badge}) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: _ts(
                    fontSize: 10.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active
                        ? AppColors.primaryText
                        : AppColors.placeholderText,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 3),
                  Text('$badge',
                      style: _tsSerif(
                          fontSize: 9.6, color: AppColors.placeholderText)),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: Row(
        children: [
          tab('全部会社', !_coShowFollowedOnly, () {
            setState(() => _coShowFollowedOnly = false);
          }),
          const SizedBox(width: 16),
          tab('已关注', _coShowFollowedOnly, () {
            setState(() => _coShowFollowedOnly = true);
          }, badge: followedCount),
        ],
      ),
    );
  }

  /// 信息区固定高度（原版 67 压缩而来：内边距与行距收紧）。
  static const double _companyInfoH = 64;

  /// 会社卡片（2026-10-04 回归原版两段式 + logo 区正方形）：
  ///
  /// ```
  /// ┌──────────────────┐
  /// │                  │
  /// │   logo 显示区     │  高 = 卡宽（正方形）；tint 底 + 图标 contain
  /// │   （正方形）      │  完整居中显示，零裁切；留白由 tint 底承接
  /// │                  │
  /// ├──────────────────┤
  /// │ 名字              │
  /// │ 副名   N 部作品 +关注│  不透明信息区（压缩高度）
  /// └──────────────────┘
  /// ```
  Widget _buildCompanyCard(
      CategoryBoxCompany company, String? droppingKey, double cardW) {
    final isDropping = droppingKey == company.key;
    final path = company.logoPath;
    final hasImage = path != null && File(path).existsSync();

    return PanelHoverBuilder(
      builder: (isHovered) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => widget.onEnterCompany(company.key),
            child: Container(
              key: widget.smartItemKeys[company.key],
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(4),
                border: isDropping
                    ? Border.all(color: AppColors.selectedAccent, width: 2)
                    : Border.all(
                        color: isHovered
                            ? AppColors.selectedAccent.withOpacity(0.55)
                            : AppColors.borderLight,
                        width: isHovered ? 1.2 : 0.6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // logo 显示区：正方形（高 = 卡宽）；图标 contain 完整显示，
                  // 不再像旧版 cover 那样裁掉横长条 logo（如 Navel）。
                  // ClipRRect：裁齐顶部圆角（与外框圆角 4 - 边框 0.6 匹配），
                  // 防止 tint 底/图片直角盖过外框圆角
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(3.4)),
                    child: SizedBox(
                      height: cardW,
                      child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(
                          color: company.logoBg,
                          child: hasImage
                              ? Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Image.file(
                                    File(path),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    errorBuilder: (_, __, ___) =>
                                        _companyWordmark(company),
                                  ),
                                )
                              : Center(child: _companyWordmark(company)),
                        ),
                        if (isHovered)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: _buildCompanyEditButton(company),
                          ),
                      ],
                      ),
                    ),
                  ),
                  // 信息区：不透明（原版样式），高度压缩至 _companyInfoH
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(9.6, 5, 9.6, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            company.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _ts(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryText,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            company.subName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _ts(
                                fontSize: 8.8,
                                color: AppColors.placeholderText),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${company.gameCount} 部作品',
                                  style: _ts(
                                      fontSize: 8.8,
                                      color: AppColors.placeholderText),
                                ),
                              ),
                              _buildFollowChip(company),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 衬线字标（无图标时的兜底，与原版一致）。
  Widget _companyWordmark(CategoryBoxCompany company) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        company.logoText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _tsSerif(
          fontSize: company.logoText.length <= 2 ? 22 : 17,
          color: company.logoFg,
        ),
      ),
    );
  }

  /// 「编辑会社信息」圆形小按钮（hover 浮现于 logo 区右上角）。
  Widget _buildCompanyEditButton(CategoryBoxCompany company) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onEditCompany(company),
        child: Tooltip(
          message: '编辑会社信息',
          waitDuration: const Duration(milliseconds: 500),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(0.92),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.borderLight, width: 0.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor.withOpacity(0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.settings_outlined,
              size: 12,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowChip(CategoryBoxCompany company) {
    final followed = company.followed;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onToggleFollowCompany(company),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: followed ? AppColors.cardHoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(3.2),
            border: Border.all(
              color: followed
                  ? AppColors.selectedAccent.withOpacity(0.6)
                  : AppColors.borderLight,
              width: 0.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                followed ? Icons.check_rounded : Icons.add_rounded,
                size: 10,
                color: followed
                    ? AppColors.selectedAccent
                    : AppColors.secondaryText,
              ),
              const SizedBox(width: 3),
              Text(
                followed ? '已关注' : '关注',
                style: _ts(
                  fontSize: 8.8,
                  color:
                      followed ? AppColors.secondaryText : AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Footer：视图专属行动按钮（Figma：上缘分隔线 + 39.2 高主按钮）
  // ---------------------------------------------------------------------------

  Widget _buildFooter() {
    final (label, icon, onTap) = switch (_tab) {
      CategoryBoxTab.favorites =>
        ('新建收藏夹', Icons.add_rounded, widget.onCreate),
      CategoryBoxTab.tags => _tagEditMode
          ? ('完成编辑', Icons.check_rounded, _toggleTagEditMode)
          : ('编辑标签', Icons.edit_outlined, _toggleTagEditMode),
      CategoryBoxTab.companies =>
        ('添加会社', Icons.add_rounded, widget.onAddCompany),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10.4, 11.2, 10.4, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 39.2,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.navActiveBorder, width: 0.6),
              borderRadius: BorderRadius.circular(6.4),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: AppColors.secondaryText),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: _ts(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 小工具
// =============================================================================

/// 维度改名 / 新增维度输入框（标签库内联编辑）。
///
/// 提交时机：回车或失焦（有变更才触发 [onSubmit]）；[onCancel] 可选
/// （ESC / 取消按钮时还原，仅「新增」场景用）。
class _DimRenameField extends StatefulWidget {
  const _DimRenameField({
    required this.initial,
    required this.onSubmit,
    this.autofocus = false,
    this.hint,
    this.onCancel,
  });

  final String initial;
  final ValueChanged<String> onSubmit;
  final bool autofocus;
  final String? hint;
  final VoidCallback? onCancel;

  @override
  State<_DimRenameField> createState() => _DimRenameFieldState();
}

class _DimRenameFieldState extends State<_DimRenameField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _commit() {
    widget.onSubmit(_c.text);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      autofocus: widget.autofocus,
      style: _ts(fontSize: 10.4, color: AppColors.primaryText),
      cursorColor: AppColors.selectedAccent,
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        hintText: widget.hint ?? widget.initial,
        hintStyle: _ts(fontSize: 10, color: AppColors.placeholderText),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 6, horizontal: 9),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide(color: AppColors.border, width: 0.6),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide:
              BorderSide(color: AppColors.selectedAccent, width: 1.2),
        ),
        suffixIcon: widget.onCancel == null
            ? null
            : GestureDetector(
                onTap: widget.onCancel,
                child: Icon(Icons.close_rounded,
                    size: 12, color: AppColors.placeholderText),
              ),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 24, minHeight: 24),
      ),
    );
  }
}

/// 标签 chip 右侧的 ⚙ 管理入口小圆点（编辑模式 hover 显示）。
class _TagMenuDot extends StatelessWidget {
  const _TagMenuDot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Icon(
          Icons.settings_outlined,
          size: 10,
          color: AppColors.placeholderText,
        ),
      ),
    );
  }
}

/// 跨维度拖拽时的跟手反馈 chip（迷你版：只带标签名）。
class _DragChipFeedback extends StatelessWidget {
  const _DragChipFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.selectedAccent, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadowColor.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          label,
          style: _ts(fontSize: 10.5, color: AppColors.primaryText),
        ),
      ),
    );
  }
}

/// 常规文本样式（正文走应用默认字体族）。
TextStyle _ts({
  double? fontSize,
  FontWeight? fontWeight,
  double? letterSpacing,
  double? height,
  Color? color,
}) {
  return TextStyle(
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    height: height,
    color: color,
  );
}

/// 衬线小字（计数 / 会社字标等装饰性文字）。
///
/// 应用未捆绑衬线中文字体，回退链：通用 serif → Windows 宋体。
/// 与设计稿的 Noto Serif SC 观感接近（细节差异见 features/category_box.md）。
TextStyle _tsSerif({double? fontSize, Color? color}) {
  return TextStyle(
    fontSize: fontSize,
    fontFamily: 'serif',
    fontFamilyFallback: const ['SimSun', 'NSimSun', 'NotoSerifSC'],
    color: color,
  );
}

/// 虚线分隔线（收藏夹留白提示块顶部，Figma 为点状虚线）。
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 1),
      painter: _DashedLinePainter(color: color),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dashWidth = 2.5;
    const dashGap = 3.5;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dashWidth, 0), paint);
      x += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
