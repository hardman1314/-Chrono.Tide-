import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/ct_theme_package.dart';
import '../theme/theme_storage.dart';
import 'app_snack_bar.dart';
import 'interactive_wrapper.dart';
import 'theme_editor_dialog.dart';

/// v3.0 P4：我的主题列表区
///
/// 展示用户自定义主题（source=user），提供：
/// - 应用：切换为激活主题
/// - 编辑：打开主题设计器编辑该主题（editThemeId 模式，应用时更新原主题）
/// - 复制：生成副本（新 UUID + "(副本)" 后缀）
/// - 删除：删除主题 JSON + 关联背景图
/// - 导入：从 .cttheme 文件导入（P5 接入）
///
/// 空状态隐藏（无用户主题时返回 SizedBox.shrink，避免新用户看到空白）。
///
/// 响应式：通过 AnimatedBuilder 监听 AppThemeManager，主题增删后自动刷新。
class MyThemesSection extends StatefulWidget {
  /// v3.0 P5：导入回调（由 settings_modal 注入 CtThemePackage.import 流程）
  final VoidCallback? onImport;

  const MyThemesSection({super.key, this.onImport});

  @override
  State<MyThemesSection> createState() => _MyThemesSectionState();
}

class _MyThemesSectionState extends State<MyThemesSection> {
  bool _expanded = true;

  /// v3.0 P6 修复：正在重命名的主题 id（null 表示无）
  String? _renamingThemeId;
  late final TextEditingController _renameController;
  late final FocusNode _renameFocusNode;

  /// v3.0 P6 修复：正在确认删除的主题 id（null 表示无）
  /// 改为内联两步确认，避免弹窗层级问题
  String? _confirmingDeleteThemeId;

  /// v3.0 P6 修复2：当前打开的更多操作菜单 OverlayEntry
  /// 用于在 State dispose 时清理，避免菜单残留阻塞 UI（关闭设置页时菜单不会自动跟随消失）
  OverlayEntry? _moreMenuEntry;

  @override
  void initState() {
    super.initState();
    _renameController = TextEditingController();
    _renameFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _renameController.dispose();
    _renameFocusNode.dispose();
    // 清理可能残留的更多操作菜单（用户关闭设置页时，菜单不会自动消失）
    _moreMenuEntry?.remove();
    _moreMenuEntry = null;
    super.dispose();
  }

  /// 获取全部用户主题（按名称排序）
  List<CTThemeData> get _userThemes {
    final manager = AppThemeManager.instance;
    final themes = manager.allThemeIds
        .map((id) => manager.themeDataById(id))
        .whereType<CTThemeData>()
        .where((t) => t.isUserTheme)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return themes;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppThemeManager.instance,
      builder: (context, _) {
        final themes = _userThemes;
        // 空状态隐藏（P4 任务4：避免新用户看到空白）
        if (themes.isEmpty) return const SizedBox.shrink();
        return _buildSection(themes);
      },
    );
  }

  Widget _buildSection(List<CTThemeData> themes) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: AppColors.borderLight,
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行（可折叠）
          InteractiveWrapper(
            onTap: () => setState(() => _expanded = !_expanded),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.collections_bookmark_outlined,
                      size: 20, color: AppColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '我的主题',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryText,
                          ),
                        ),
                        Text(
                          '${themes.length} 个自定义主题',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 导入按钮（P5）
                  if (widget.onImport != null)
                    InteractiveWrapper(
                      onTap: widget.onImport,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.buttonBackground,
                          border:
                              Border.all(color: AppColors.border, width: 1.0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.file_download_outlined,
                                size: 13, color: AppColors.primaryText),
                            const SizedBox(width: 4),
                            Text('导入',
                                style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primaryText)),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: AppColors.secondaryText,
                  ),
                ],
              ),
            ),
          ),
          // 主题卡片列表
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              // v3.0 P6-2：ListView.builder 懒加载（shrinkWrap + NeverScrollable
              // 嵌入父级滚动视图；每张卡片 RepaintBoundary 隔离重绘）
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: themes.length,
                itemBuilder: (context, index) {
                  return RepaintBoundary(
                    child: _buildThemeCard(themes[index]),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 单个用户主题卡片
  Widget _buildThemeCard(CTThemeData theme) {
    final isActive = AppThemeManager.instance.currentThemeId == theme.id;
    final isRenaming = _renamingThemeId == theme.id;
    final isConfirmingDelete = _confirmingDeleteThemeId == theme.id;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(
            color: isActive ? AppColors.selectedAccent : AppColors.borderLight,
            width: isActive ? 1.6 : 1.0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // 主题色预览圆（取 background + selectedAccent 双色）
          _buildColorPreview(theme),
          const SizedBox(width: 12),
          // 名称 + 描述（或重命名输入框）
          Expanded(
            child: isRenaming
                ? _buildRenameInput(theme)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(theme.emoji,
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              theme.name,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryText,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppColors.successBg,
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                    color: AppColors.successGreen, width: 0.6),
                              ),
                              child: Text('当前',
                                  style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.successGreen)),
                            ),
                          ],
                        ],
                      ),
                      if (theme.description != null &&
                          theme.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            theme.description!,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              color: AppColors.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: 8),
          // 操作按钮组（或删除确认 / 重命名确认）
          if (isConfirmingDelete)
            _buildDeleteConfirmation(theme)
          else if (isRenaming)
            const SizedBox.shrink() // 重命名确认按钮在输入框内
          else
            _buildActions(theme, isActive),
        ],
      ),
    );
  }

  /// v3.0 P6 修复：内联重命名输入框
  Widget _buildRenameInput(CTThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _renameController,
            focusNode: _renameFocusNode,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: AppColors.border, width: 1.0),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide:
                    BorderSide(color: AppColors.selectedAccent, width: 1.4),
              ),
            ),
            onSubmitted: (_) => _onConfirmRename(theme),
            autofocus: true,
          ),
        ),
        const SizedBox(width: 6),
        _actionBtn(Icons.check_rounded, '确定',
            onTap: () => _onConfirmRename(theme)),
        const SizedBox(width: 4),
        _actionBtn(Icons.close_rounded, '取消',
            onTap: _onCancelRename),
      ],
    );
  }

  /// v3.0 P6 修复：内联删除确认（替代弹窗，避免层级问题）
  Widget _buildDeleteConfirmation(CTThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('确认删除？',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.dangerRed)),
        const SizedBox(width: 6),
        _actionBtn(Icons.check_rounded, '删除',
            isDanger: true, onTap: () => _onConfirmDelete(theme)),
        const SizedBox(width: 4),
        _actionBtn(Icons.close_rounded, '取消',
            onTap: _onCancelDelete),
      ],
    );
  }

  /// 主题色预览（双色圆：background 底 + selectedAccent 描边 + accent 点）
  Widget _buildColorPreview(CTThemeData theme) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: theme.background,
        shape: BoxShape.circle,
        border: Border.all(color: theme.selectedAccent, width: 2),
      ),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: theme.selectedAccent,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  /// 操作按钮组：应用 / 编辑 + 更多菜单（重命名/复制/导出/删除）
  /// v3.0 P6 优化：次要操作收入 PopupMenuButton，避免按钮过多挤压文字
  Widget _buildActions(CTThemeData theme, bool isActive) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isActive)
          _actionBtn(Icons.check_rounded, '应用',
              onTap: () => _onApply(theme)),
        if (!isActive) const SizedBox(width: 4),
        _actionBtn(Icons.edit_outlined, '编辑',
            onTap: () => _onEdit(theme)),
        const SizedBox(width: 4),
        _buildMoreMenu(theme),
      ],
    );
  }

  /// 更多操作菜单按钮 — 点击后通过 root overlay 显示自定义菜单
  /// v3.0 P6 修复：PopupMenuButton 走 Navigator.push，层级不稳定（会被压在
  /// SettingsModal 之下）。改用 Overlay.of(rootOverlay: true) 直接注入，
  /// 与 SettingsModal / ThemeEditorDialog 完全相同的层级方式。
  ///
  /// v3.0 P6 修复2：原来 _showMoreMenu(theme, context) 传入的是 State 的 context，
  /// findRenderObject 返回的是整个 MyThemesSection 区块的 RenderBox（而非按钮），
  /// 导致 menuTop = 区块顶部 + 区块高度 = 区块底部以下，菜单被定位到屏幕外。
  /// 现在用 Builder 包裹，拿到按钮自身的 context，findRenderObject 才会返回按钮的 RenderBox。
  Widget _buildMoreMenu(CTThemeData theme) {
    return Tooltip(
      message: '更多操作',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Builder(
          builder: (buttonCtx) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showMoreMenu(theme, buttonCtx),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                border:
                    Border.all(color: AppColors.borderLight, width: 0.8),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(Icons.more_vert_rounded,
                  size: 14, color: AppColors.secondaryText),
            ),
          ),
        ),
      ),
    );
  }

  /// 显示更多操作菜单（root overlay 注入，确保层级正确）
  /// [buttonContext] 必须是按钮自身的 BuildContext（通过 Builder 获取），
  /// 这样 findRenderObject 才会返回按钮的 RenderBox 而非整个区块。
  void _showMoreMenu(CTThemeData theme, BuildContext buttonContext) {
    // 清理可能已存在的菜单（避免重复弹出）
    _moreMenuEntry?.remove();
    _moreMenuEntry = null;

    final overlay = Overlay.of(buttonContext, rootOverlay: true);

    // 计算按钮在屏幕上的位置（使用按钮自身的 RenderBox）
    final renderBox = buttonContext.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;

    debugPrint('[MoreMenu] 按钮位置=($buttonPos), 尺寸=$buttonSize');

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _MoreMenuOverlay(
        buttonPos: buttonPos,
        buttonSize: buttonSize,
        onRename: () {
          entry.remove();
          _moreMenuEntry = null;
          _onStartRename(theme);
        },
        onDuplicate: () {
          entry.remove();
          _moreMenuEntry = null;
          _onDuplicate(theme);
        },
        onExport: () {
          entry.remove();
          _moreMenuEntry = null;
          _onExport(theme);
        },
        onDelete: () {
          entry.remove();
          _moreMenuEntry = null;
          _onStartDelete(theme);
        },
        onDismiss: () {
          entry.remove();
          _moreMenuEntry = null;
        },
      ),
    );
    _moreMenuEntry = entry;
    overlay.insert(entry);
  }

  Widget _actionBtn(IconData icon, String tooltip,
      {required VoidCallback onTap, bool isDanger = false}) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InteractiveWrapper(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: isDanger
                ? AppColors.errorBg
                : AppColors.buttonBackground,
            border: Border.all(
                color: isDanger
                    ? AppColors.hoverCloseBorder
                    : AppColors.borderLight,
                width: 0.8),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(icon,
              size: 14,
              color: isDanger
                  ? AppColors.dangerRed
                  : AppColors.secondaryText),
        ),
      ),
    );
  }

  // ============ 操作处理 ============

  Future<void> _onApply(CTThemeData theme) async {
    await AppThemeManager.instance.setThemeById(theme.id);
    if (mounted) AppSnackBar.success(context, '已切换到「${theme.name}」');
  }

  void _onEdit(CTThemeData theme) {
    ThemeEditorDialog.show(context, editThemeId: theme.id);
  }

  Future<void> _onDuplicate(CTThemeData theme) async {
    try {
      final copy = await ThemeStorage.duplicateAndSave(theme);
      AppThemeManager.instance.registerTheme(copy);
      AppThemeManager.instance.notifyThemeChanged();
      if (mounted) AppSnackBar.success(context, '已复制为「${copy.name}」');
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '复制失败: $e');
    }
  }

  /// v3.0 P5：导出为 .cttheme 文件（系统保存对话框）
  Future<void> _onExport(CTThemeData theme) async {
    try {
      final safeName = theme.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '导出主题',
        fileName: '$safeName.cttheme',
        type: FileType.custom,
        allowedExtensions: ['cttheme'],
      );
      if (outputPath == null) return; // 用户取消

      await CtThemePackage.exportToFile(theme, outputPath);
      if (mounted) AppSnackBar.success(context, '已导出到：$outputPath');
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '导出失败: $e');
    }
  }

  // ============ 重命名 ============

  void _onStartRename(CTThemeData theme) {
    setState(() {
      _renamingThemeId = theme.id;
      _renameController.text = theme.name;
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: theme.name.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renameFocusNode.requestFocus();
    });
  }

  void _onCancelRename() {
    setState(() {
      _renamingThemeId = null;
    });
  }

  Future<void> _onConfirmRename(CTThemeData theme) async {
    final newName = _renameController.text.trim();
    if (newName.isEmpty) {
      AppSnackBar.error(context, '名称不能为空');
      return;
    }
    if (newName == theme.name) {
      setState(() => _renamingThemeId = null);
      return;
    }
    try {
      final renamed = theme.asUserThemeCopy(
        newId: theme.id,
        name: newName,
      );
      await ThemeStorage.saveUserTheme(renamed);
      AppThemeManager.instance.registerTheme(renamed);
      AppThemeManager.instance.notifyThemeChanged();
      if (mounted) {
        AppSnackBar.success(context, '已重命名为「$newName」');
        setState(() => _renamingThemeId = null);
      }
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '重命名失败: $e');
    }
  }

  // ============ 删除（内联两步确认）============

  void _onStartDelete(CTThemeData theme) {
    setState(() {
      _confirmingDeleteThemeId = theme.id;
    });
  }

  void _onCancelDelete() {
    setState(() {
      _confirmingDeleteThemeId = null;
    });
  }

  Future<void> _onConfirmDelete(CTThemeData theme) async {
    try {
      await ThemeStorage.deleteUserThemeWithBackground(theme);
      // 若删除的是当前激活主题，unregisterTheme 会自动走 250ms 过渡动画回退到 warmSun
      await AppThemeManager.instance.unregisterTheme(theme.id);
      if (mounted) {
        AppSnackBar.success(context, '已删除「${theme.name}」');
        setState(() => _confirmingDeleteThemeId = null);
      }
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '删除失败: $e');
    }
  }
}

/// v3.0 P6 修复：自定义更多操作菜单（root overlay 注入）
///
/// 替代 PopupMenuButton，避免 Navigator.push 导致的层级问题。
/// 全屏透明遮罩 + 定位菜单，点击遮罩或菜单项后自动关闭。
class _MoreMenuOverlay extends StatelessWidget {
  final Offset buttonPos;
  final Size buttonSize;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onExport;
  final VoidCallback onDelete;
  final VoidCallback onDismiss;

  const _MoreMenuOverlay({
    required this.buttonPos,
    required this.buttonSize,
    required this.onRename,
    required this.onDuplicate,
    required this.onExport,
    required this.onDelete,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    const menuWidth = 120.0;
    // 菜单预估高度：4 个 menu item（每项约 32）+ 2 个分隔线 + padding
    const menuEstimatedHeight = 160.0;

    // 水平定位：菜单左边缘默认对齐按钮左边缘，右溢出时左移
    double menuLeft = buttonPos.dx;
    if (menuLeft + menuWidth > screenW - 8) {
      menuLeft = screenW - menuWidth - 8;
    }
    if (menuLeft < 8) menuLeft = 8;

    // 垂直定位：默认在按钮下方 2px
    // v3.0 P6 修复2：原来用 State context 导致 buttonPos 是整个区块顶部、
    // buttonSize 是整个区块尺寸，menuTop 被推到区块底部以下（屏幕外）。
    // 现在用按钮自身 context，buttonPos/buttonSize 是按钮的真实位置/尺寸。
    // 同时加夹紧：下方空间不足时显示在按钮上方；上下都不够时夹在屏幕内。
    final spaceBelow = screenH - (buttonPos.dy + buttonSize.height + 2);
    final spaceAbove = buttonPos.dy - 2;
    double menuTop;
    if (spaceBelow >= menuEstimatedHeight) {
      // 下方足够
      menuTop = buttonPos.dy + buttonSize.height + 2;
    } else if (spaceAbove >= menuEstimatedHeight) {
      // 上方足够
      menuTop = buttonPos.dy - menuEstimatedHeight - 2;
    } else {
      // 上下都不够，选空间更大的一侧并夹紧
      menuTop = spaceBelow >= spaceAbove
          ? (screenH - menuEstimatedHeight - 8)
          : 8.0;
      if (menuTop < 8) menuTop = 8.0;
      if (menuTop + menuEstimatedHeight > screenH - 8) {
        menuTop = screenH - menuEstimatedHeight - 8;
      }
    }

    return Stack(
      children: [
        // 全屏透明遮罩（点击关闭）
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 菜单
        Positioned(
          left: menuLeft,
          top: menuTop,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: menuWidth,
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.0),
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.shadowColor,
                    blurRadius: 8,
                    offset: const Offset(2, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _menuItemTile(Icons.drive_file_rename_outline, '重命名',
                      onTap: onRename),
                  _divider(),
                  _menuItemTile(Icons.copy_all_rounded, '复制',
                      onTap: onDuplicate),
                  _menuItemTile(Icons.ios_share_rounded, '导出',
                      onTap: onExport),
                  _divider(),
                  _menuItemTile(Icons.delete_outline_rounded, '删除',
                      isDanger: true, onTap: onDelete),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItemTile(IconData icon, String label,
      {bool isDanger = false, required VoidCallback onTap}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 14,
                  color: isDanger
                      ? AppColors.dangerRed
                      : AppColors.secondaryText),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDanger
                          ? AppColors.dangerRed
                          : AppColors.primaryText)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: AppColors.borderLight,
    );
  }
}
