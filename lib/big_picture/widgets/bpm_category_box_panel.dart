import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/collection_service.dart';
import '../../theme/app_styles.dart';
import '../../widgets/library/category_box_sidebar.dart'
    show CategoryBoxCompany, CategoryBoxTag, CategoryBoxTagSection;
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 分类匣面板（库页右侧滑入；三视图：收藏夹 / 标签库 / 会社墙）
///
/// - 动效与信息结构对齐桌面 [CategoryBoxSidebar]：220ms easeOutCubic 宽度动画、
///   头部三视图切换 + 关闭；配色走 BpmColors（深浅主题自适应）。
/// - 纯展示组件：数据与筛选状态全部由宿主（库页）注入/回传。
/// - 交互：A 进入筛选 · ⋯ 行操作（重命名/置顶/删除）· B 或点遮罩关闭。
/// - ⛔ 不做拖拽投放（鼠标特性）——游戏成员管理走卡片右键 → BpmCollectionPicker。
class BpmCategoryBoxPanel extends StatefulWidget {
  /// 展开/收起（宽度动画；收起时 IgnorePointer）
  final bool open;

  /// 打开时宿主 requestFocus 的首行焦点节点（防焦点悬空）
  final FocusNode leadFocusNode;

  // —— 收藏夹 ——
  final List<GameCollection> collections;
  final String? activeCollectionId;
  final int allGamesCount;
  final int Function(String id) gameCountOf;
  final ValueChanged<String?> onEnterCollection;
  final VoidCallback onCreateCollection;
  final Future<void> Function(GameCollection c) onRenameCollection;
  final Future<void> Function(GameCollection c) onDeleteCollection;
  final Future<void> Function(GameCollection c) onTogglePinCollection;

  // —— 标签库 ——
  final List<CategoryBoxTagSection> tagSections;
  final Set<String> activeTagKeys;
  final ValueChanged<String> onToggleTag;

  // —— 会社墙 ——
  final List<CategoryBoxCompany> companies;
  final String activeSmartGroupKey;
  final ValueChanged<String> onEnterCompany;
  final Future<void> Function(CategoryBoxCompany c) onToggleFollowCompany;

  final VoidCallback onClose;

  const BpmCategoryBoxPanel({
    super.key,
    required this.open,
    required this.leadFocusNode,
    required this.collections,
    required this.activeCollectionId,
    required this.allGamesCount,
    required this.gameCountOf,
    required this.onEnterCollection,
    required this.onCreateCollection,
    required this.onRenameCollection,
    required this.onDeleteCollection,
    required this.onTogglePinCollection,
    required this.tagSections,
    required this.activeTagKeys,
    required this.onToggleTag,
    required this.companies,
    required this.activeSmartGroupKey,
    required this.onEnterCompany,
    required this.onToggleFollowCompany,
    required this.onClose,
  });

  @override
  State<BpmCategoryBoxPanel> createState() => _BpmCategoryBoxPanelState();
}

enum _BoxTab { favorites, tags, companies }

class _BpmCategoryBoxPanelState extends State<BpmCategoryBoxPanel> {
  static const double kWidth = 420;

  _BoxTab _tab = _BoxTab.favorites;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BpmCategoryBoxPanel old) {
    super.didUpdateWidget(old);
    // 每次重新展开 → 回收藏夹视图并清搜索（与「打开即总览」的直觉一致）
    if (widget.open && !old.open) {
      _tab = _BoxTab.favorites;
      _search.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !widget.open,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: widget.open ? kWidth : 0,
        child: ClipRect(
          child: SizedBox(
            width: kWidth,
            child: Container(
              decoration: BoxDecoration(
                color: BpmColors.deepPanel,
                border: Border(
                  left: BorderSide(color: BpmColors.mistBlueBorder, width: 1),
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    offset: const Offset(-6, 0),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  _buildSearchField(),
                  Expanded(child: _buildBody()),
                  _buildFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 头部：三视图切换 + 关闭
  // ---------------------------------------------------------------------------

  Widget _buildHeader() {
    const labels = {
      _BoxTab.favorites: '收藏夹',
      _BoxTab.tags: '标签库',
      _BoxTab.companies: '会社墙',
    };
    return Container(
      height: 60,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 0),
      child: Row(
        children: [
          for (final t in _BoxTab.values) ...[
            _tabPill(t, labels[t]!),
            const SizedBox(width: 8),
          ],
          const Spacer(),
          _closeButton(),
        ],
      ),
    );
  }

  Widget _tabPill(_BoxTab t, String label) {
    final active = _tab == t;
    return BpmInteractiveWrapper(
      onTap: () => setState(() => _tab = t),
      semanticsLabel: '切换到$label视图',
      borderRadius: BorderRadius.circular(17),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? BpmColors.cherryRose.withOpacity(0.22) : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: active ? BpmColors.cherryRoseBorder : Colors.white10,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: active ? BpmColors.textPrimary : BpmColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _closeButton() {
    return BpmInteractiveWrapper(
      onTap: widget.onClose,
      semanticsLabel: '关闭分类匣',
      borderRadius: BorderRadius.circular(15),
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(Icons.close_rounded, size: 19, color: BpmColors.textMuted),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 搜索（作用于当前视图列表）
  // ---------------------------------------------------------------------------

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: BpmColors.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search_rounded,
                size: 17, color: BpmColors.textMuted),
            hintText: '搜索当前视图',
            hintStyle: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 13,
              color: BpmColors.textMuted,
            ),
            contentPadding: EdgeInsets.zero,
            filled: true,
            fillColor: BpmColors.panelGlass,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide(color: BpmColors.mistBlueBorder, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide(color: BpmColors.mistBlueBorder, width: 1),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 主体
  // ---------------------------------------------------------------------------

  Widget _buildBody() {
    switch (_tab) {
      case _BoxTab.favorites:
        return _buildFavoritesBody();
      case _BoxTab.tags:
        return _buildTagsBody();
      case _BoxTab.companies:
        return _buildCompaniesBody();
    }
  }

  String get _queryLower => _search.text.trim().toLowerCase();

  // ── 收藏夹 ──

  Widget _buildFavoritesBody() {
    final q = _queryLower;
    final collections = widget.collections
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q))
        .toList();
    final anyMatch = q.isEmpty ||
        '所有游戏'.contains(q) ||
        collections.isNotEmpty;

    if (!anyMatch) {
      return _emptyHint('没有匹配的收藏夹');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      children: [
        // 「所有游戏」= 清除收藏夹筛选（lead 焦点行）
        _collectionRow(
          key: const ValueKey('catbox_all'),
          focusNode: widget.leadFocusNode,
          selected: widget.activeCollectionId == null,
          dotColor: BpmColors.cherryRose,
          name: '所有游戏',
          count: widget.allGamesCount,
          pinnedTop: false,
          isPreset: false,
          onTap: () => widget.onEnterCollection(null),
        ),
        for (final c in collections)
          _collectionRow(
            key: ValueKey('catbox_${c.id}'),
            selected: widget.activeCollectionId == c.id,
            dotColor: Color(c.colorValue),
            name: c.name,
            count: widget.gameCountOf(c.id),
            pinnedTop: c.isPinnedTop,
            isPreset: c.isPreset,
            onTap: () => widget.onEnterCollection(c.id),
            showActions: !c.isPreset,
            actionTarget: c,
          ),
        const SizedBox(height: 6),
        _newCollectionButton(),
      ],
    );
  }

  Widget _collectionRow({
    required Key key,
    FocusNode? focusNode,
    required bool selected,
    required Color dotColor,
    required String name,
    required int count,
    required bool pinnedTop,
    required bool isPreset,
    required VoidCallback onTap,
    bool showActions = false,
    GameCollection? actionTarget,
  }) {
    return BpmInteractiveWrapper(
      key: key,
      focusNode: focusNode,
      onTap: onTap,
      semanticsLabel: '筛选 $name',
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 46,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? dotColor.withOpacity(0.18)
              : BpmColors.panelGlass,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? dotColor.withOpacity(0.85) : Colors.white10,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 14,
                  color: selected ? BpmColors.textPrimary : BpmColors.textSecondary,
                ),
              ),
            ),
            if (pinnedTop)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin_rounded,
                    size: 13, color: BpmColors.textMuted),
              ),
            Text(
              '$count',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12,
                color: BpmColors.textMuted,
              ),
            ),
            if (showActions && actionTarget != null) ...[
              const SizedBox(width: 4),
              Builder(
                builder: (btnContext) => _rowActionsButton(
                  () => _showRowMenu(btnContext, actionTarget),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rowActionsButton(VoidCallback onTap) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      semanticsLabel: '收藏夹操作',
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 24,
        height: 24,
        child: Icon(Icons.more_horiz_rounded, size: 16, color: BpmColors.textMuted),
      ),
    );
  }

  Widget _newCollectionButton() {
    return BpmInteractiveWrapper(
      onTap: widget.onCreateCollection,
      semanticsLabel: '新建收藏夹',
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: BpmColors.mistBlueBorder,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.add_rounded, size: 18, color: BpmColors.mistBlue),
            const SizedBox(width: 8),
            Text(
              '新建收藏夹',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 13,
                color: BpmColors.mistBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 收藏夹行操作菜单（重命名 / 置顶切换 / 删除）
  /// [buttonContext] = ⋯ 按钮的 context，菜单精确锚定其正下方。
  Future<void> _showRowMenu(
      BuildContext buttonContext, GameCollection c) async {
    final button = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null || !mounted) return;
    final topLeft = button.localToGlobal(
        Offset(button.size.width - 170, button.size.height + 4),
        ancestor: overlay);
    final bottomRight = button.localToGlobal(
        Offset(button.size.width + 20, button.size.height + 170),
        ancestor: overlay);
    final anchorRect = Rect.fromPoints(topLeft, bottomRight);
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
          anchorRect, Offset.zero & overlay.size),
      color: BpmColors.deepPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: BpmColors.mistBlueBorder),
      ),
      items: [
        _menuItem('rename', '重命名', Icons.edit_rounded),
        _menuItem(
            c.pinned ? 'unpin' : 'pin',
            c.pinned ? '取消置顶' : '置顶',
            Icons.push_pin_rounded),
        _menuItem('delete', '删除', Icons.delete_outline_rounded),
      ],
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'rename':
        await widget.onRenameCollection(c);
        break;
      case 'pin':
      case 'unpin':
        await widget.onTogglePinCollection(c);
        break;
      case 'delete':
        await widget.onDeleteCollection(c);
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String value, String label, IconData icon) {
    return PopupMenuItem<String>(
      value: value,
      height: 42,
      child: Row(
        children: [
          Icon(icon, size: 17, color: BpmColors.textSecondary),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 14,
              color: BpmColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ── 标签库 ──

  Widget _buildTagsBody() {
    final q = _queryLower;
    final sections = widget.tagSections
        .map((s) => CategoryBoxTagSection(
              title: s.title,
              tags: s.tags
                  .where((t) => q.isEmpty || t.name.toLowerCase().contains(q))
                  .toList(),
            ))
        .where((s) => s.tags.isNotEmpty)
        .toList();
    if (sections.isEmpty) {
      return _emptyHint(q.isEmpty ? '库内还没有可分类的标签' : '没有匹配的标签');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      children: [
        for (final s in sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6, left: 2),
            child: Text(
              s.title,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12,
                color: BpmColors.textMuted,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in s.tags) _tagChip(t),
            ],
          ),
        ],
      ],
    );
  }

  Widget _tagChip(CategoryBoxTag t) {
    final selected = widget.activeTagKeys.contains(t.key);
    return BpmInteractiveWrapper(
      onTap: () => widget.onToggleTag(t.key),
      semanticsLabel: '${selected ? '取消筛选' : '筛选'}标签 ${t.name}',
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? BpmColors.cherryRose.withOpacity(0.20)
              : BpmColors.panelGlass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? BpmColors.cherryRose.withOpacity(0.85)
                : Colors.white10,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.dotColor != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                    color: t.dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
            ],
            Text(
              '${t.name} ${t.count}',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12.5,
                color:
                    selected ? BpmColors.textPrimary : BpmColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 会社墙 ──

  Widget _buildCompaniesBody() {
    final q = _queryLower;
    final companies = widget.companies
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q))
        .toList();
    if (companies.isEmpty) {
      return _emptyHint(q.isEmpty ? '库内还没有会社数据' : '没有匹配的会社');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      children: [
        for (final c in companies) _companyRow(c),
      ],
    );
  }

  Widget _companyRow(CategoryBoxCompany c) {
    final selected = widget.activeSmartGroupKey == c.key;
    return BpmInteractiveWrapper(
      key: ValueKey('catbox_co_${c.key}'),
      onTap: () => widget.onEnterCompany(c.key),
      semanticsLabel: '筛选会社 ${c.name}',
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 54,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color:
              selected ? BpmColors.cherryRose.withOpacity(0.16) : BpmColors.panelGlass,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? BpmColors.cherryRose.withOpacity(0.85)
                : Colors.white10,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            _companyLogo(c),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 13.5,
                      color: selected
                          ? BpmColors.textPrimary
                          : BpmColors.textSecondary,
                    ),
                  ),
                  if (c.subName.isNotEmpty)
                    Text(
                      c.subName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 11,
                        color: BpmColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              '${c.gameCount}',
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12,
                color: BpmColors.textMuted,
              ),
            ),
            const SizedBox(width: 6),
            _followButton(c),
          ],
        ),
      ),
    );
  }

  Widget _companyLogo(CategoryBoxCompany c) {
    final path = c.logoPath;
    Widget content;
    if (path != null && File(path).existsSync()) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 34,
          height: 34,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _logoMonogram(c),
        ),
      );
    } else {
      content = _logoMonogram(c);
    }
    return SizedBox(width: 34, height: 34, child: content);
  }

  Widget _logoMonogram(CategoryBoxCompany c) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.logoBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        c.logoText,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: c.logoFg,
        ),
      ),
    );
  }

  Widget _followButton(CategoryBoxCompany c) {
    return BpmInteractiveWrapper(
      onTap: () => widget.onToggleFollowCompany(c),
      semanticsLabel: '${c.followed ? '取消关注' : '关注'} ${c.name}',
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 26,
        height: 26,
        child: Icon(
          c.followed ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 18,
          color: c.followed ? BpmColors.cherryRose : BpmColors.textMuted,
        ),
      ),
    );
  }

  // ── 通用 ──

  Widget _emptyHint(String text) {
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 13,
          color: BpmColors.textMuted,
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: BpmColors.mistBlueBorder, width: 1)),
      ),
      child: Text(
        'A 进入筛选 · ⋯ 行操作 · B / 点遮罩关闭',
        style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 11,
          color: BpmColors.textMuted,
        ),
      ),
    );
  }
}

/// 面板标签 chip 直接复用宿主传入的 [CategoryBoxTag]（key/name/count/选中态已算好）
