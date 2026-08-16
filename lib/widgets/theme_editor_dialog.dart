import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_config.dart';
import '../theme/theme_element_registry.dart';
import '../theme/theme_storage.dart';
import 'animated_overlay.dart';
import 'app_snack_bar.dart';
import 'background_image_editor_dialog.dart';
import 'color_channel_panel.dart';
import 'editor_preview_builder.dart';
import 'eyedropper_overlay.dart';
import 'interactive_wrapper.dart';
import 'layer_tree_panel.dart';
import 'name_dialog.dart';
import 'recent_colors_strip.dart';
import 'undo_redo_bar.dart';

/// v3.0 P3：主题设计器（全屏弹窗，WYSIWYG 调色器）
///
/// v3 单 Tab 设计（D4 决策）：仅有"调色板"主界面，无 Tab 切换。
///
/// 整体布局：
/// - 左侧：可缩放实时 UI 预览骨架（EditorPreviewBuilder）
/// - 右侧：颜色通道面板（ColorChannelPanel）+ 影响范围提示（ImpactHint）
/// - 顶部工具栏：撤销/重做（D3: 50 步栈）
/// - 底部操作：取消 / 保存为新主题 / 应用
///
/// 预览隔离：
/// - 编辑器内修改仅影响预览，"应用"才触发全应用过渡
/// - 通过 ValueNotifier<CTThemeData> 局部重建实现
class ThemeEditorDialog extends StatefulWidget {
  /// 编辑器关闭回调（触发 AnimatedOverlay 退场动画并移除 OverlayEntry）
  final VoidCallback? onClose;

  /// v3.0 P4：要编辑的已有用户主题 id（null 表示编辑当前主题/新建）
  /// 传入时：编辑器加载该主题数据，"应用"时更新该主题（保留原 id）而非新建
  final String? editThemeId;

  const ThemeEditorDialog({super.key, this.onClose, this.editThemeId});

  /// 打开编辑器（全局静态方法）
  ///
  /// v3.0.1 修复7（层级问题根因修复）：
  /// SettingsModal 是通过 `Overlay.of(context).insert(entry)` 直接注入 Overlay 的，
  /// 而非标准 showDialog。原先用 `showDialog(useRootNavigator: true)` 打开本弹窗时，
  /// Navigator 推入的 DialogRoute 的 OverlayEntry 与 SettingsModal 的直接 OverlayEntry
  /// 在同一 Overlay 中，z-order 不稳定，导致本弹窗被压在 SettingsModal 下方。
  ///
  /// 修复：改用与 SettingsModal 完全相同的方式——直接 `Overlay.of(context).insert(entry)`，
  /// 后插入的 entry 必然在上方，层级关系确定可靠。退场通过 AnimatedOverlay 动画后 remove()。
  ///
  /// v3.0 P4：[editThemeId] 用于编辑已有用户主题（"我的主题"列表的"编辑"按钮调用）。
  static Future<void> show(BuildContext context, {String? editThemeId}) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<AnimatedOverlayState>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          if (entry.mounted) entry.remove();
        },
        barrierColor: Colors.black54,
        dismissOnBarrierTap: false,
        enableScale: false,
        child: ThemeEditorDialog(
          onClose: () => key.currentState?.dismiss(),
          editThemeId: editThemeId,
        ),
      ),
    );
    overlay.insert(entry);
    return Future.value();
  }

  @override
  State<ThemeEditorDialog> createState() => _ThemeEditorDialogState();
}

class _ThemeEditorDialogState extends State<ThemeEditorDialog> {
  /// 编辑器预览状态（隔离的，不影响全局）
  late ValueNotifier<CTThemeData> _previewNotifier;

  /// v3.0.1 修复6：初始主题快照（用于"重置"功能）
  late final CTThemeData _initialTheme;

  /// 当前选中元素 id
  String _selectedElementId = ThemeElementRegistry.defaultElementId;

  /// v3.0.1 修复2：当前预览的页面（库/探索/添加）
  PreviewPage _previewPage = PreviewPage.library;

  /// 撤销/重做控制器（D3：50 步栈）
  final UndoRedoController _undoRedo = UndoRedoController();

  /// Recent Colors 管理器（D2：会话级）
  final RecentColorsManager _recentColors = RecentColorsManager();

  /// v3.0 P6 提色器：预览区 RepaintBoundary 的 key（用于截取预览图）
  final GlobalKey _previewBoundaryKey = GlobalKey();

  /// 通道可见性状态（key = tokenField）
  final Map<String, bool> _channelVisibility = {};

  @override
  void initState() {
    super.initState();
    // v3.0 P4：若指定 editThemeId，加载该用户主题用于编辑；否则取当前主题
    CTThemeData initial;
    if (widget.editThemeId != null) {
      final editing =
          AppThemeManager.instance.themeDataById(widget.editThemeId!);
      if (editing != null && editing.isUserTheme) {
        initial = editing;
        _isEditing = true;
      } else {
        initial = AppThemeManager.instance.current;
      }
    } else {
      initial = AppThemeManager.instance.current;
    }
    _initialTheme = initial;
    _previewNotifier = ValueNotifier<CTThemeData>(initial);
    _undoRedo.initialize(initial);
    ThemeElementRegistry.register();
  }

  /// v3.0 P4：是否为编辑已有用户主题模式（应用时更新原主题而非新建）
  bool _isEditing = false;

  @override
  void dispose() {
    _previewNotifier.dispose();
    super.dispose();
  }

  CTThemeData get _preview => _previewNotifier.value;

  ThemeElementDescriptor? get _selectedElement =>
      ThemeElementRegistry.byId(_selectedElementId);

  /// 高频颜色变化（拖动中）—— 不入 undo 栈
  void _onColorChanged(String tokenField, Color newColor) {
    final newData = _preview.withColor(tokenField, newColor);
    _previewNotifier.value = newData;
  }

  /// 完整动作结束 —— 入 undo 栈 + Recent Colors
  void _onColorChangeEnd(String tokenField, Color newColor) {
    final newData = _preview.withColor(tokenField, newColor);
    _previewNotifier.value = newData;
    _undoRedo.push(newData);

    // 加入 Recent Colors
    final element = _selectedElement;
    if (element != null) {
      for (final p in element.properties) {
        if (p.tokenField == tokenField) {
          final key =
              '${element.id}.${p.channel.name}.${p.tokenField}';
          _recentColors.addColor(key, newColor);
        }
      }
    }
  }

  void _onElementTap(String elementId) {
    setState(() {
      _selectedElementId = elementId;
    });
  }

  void _onElementDoubleTap(String elementId) {
    setState(() {
      _selectedElementId = elementId;
    });
  }

  void _onUndo() {
    final state = _undoRedo.undo();
    if (state != null) {
      _previewNotifier.value = state;
    }
  }

  void _onRedo() {
    final state = _undoRedo.redo();
    if (state != null) {
      _previewNotifier.value = state;
    }
  }

  /// v3.0.1 修复6：重置到初始主题（清空 undo 栈）
  void _onReset() {
    _previewNotifier.value = _initialTheme;
    _undoRedo.initialize(_initialTheme);
    setState(() {
      _selectedElementId = ThemeElementRegistry.defaultElementId;
    });
  }

  void _onToggleVisibility(String tokenField, bool visible) {
    setState(() {
      _channelVisibility[tokenField] = visible;
    });
  }

  /// v3.0 P6 提色器：截取预览区，启动提色器，返回拾取的颜色
  Future<Color?> _pickColorFromPreview() async {
    return EyedropperOverlay.pick(
      context: context,
      boundaryKey: _previewBoundaryKey,
    );
  }

  Future<void> _onUploadBackground() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final sourcePath = result.files.single.path;
      if (sourcePath == null) return;

      final bgConfig =
          await ThemeStorage.uploadBackgroundImage(sourcePath);
      final newData = _preview.withBackgroundImage(bgConfig);
      _previewNotifier.value = newData;
      _undoRedo.push(newData);

      if (mounted) {
        AppSnackBar.success(context, '已添加背景图（点击"应用"生效）');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '背景上传失败: $e');
      }
    }
  }

  void _onClearBackground() {
    final newData =
        _preview.withBackgroundImage(const BackgroundImageConfig.none());
    _previewNotifier.value = newData;
    _undoRedo.push(newData);
  }

  /// v3.0 P7：打开背景图编辑器，用户调整位置/缩放后应用到预览
  ///
  /// 编辑器内部高频拖拽不入撤销栈，仅在用户点"应用"后一次性 push
  /// （原子操作，Ctrl+Z 可整体撤销"调整位置"动作）。
  Future<void> _onAdjustBackground() async {
    final result = await BackgroundImageEditorDialog.show(
      context: context,
      config: _preview.backgroundImage,
    );
    if (result == null) return; // 用户取消
    final newData = _preview.withBackgroundImage(result);
    _previewNotifier.value = newData;
    _undoRedo.push(newData);
  }

  /// 应用：将预览状态直接激活为当前主题（覆盖式）
  Future<void> _onApply() async {
    try {
      final CTThemeData userTheme;
      if (_isEditing) {
        // v3.0 P4：编辑模式——保留原 id/名称，仅更新颜色与背景图
        userTheme = _preview;
      } else {
        // v3.0 P6 优化：新建模式——先弹命名框让用户命名
        final name = await NameDialog.show(context,
            title: '命名并应用主题', initialValue: '我的主题');
        if (name == null) return; // 用户取消
        final newId = ThemeStorage.newThemeId();
        userTheme = _preview.asUserThemeCopy(
          newId: newId,
          name: name,
          emoji: '🎨',
          description: '通过主题设计器创建',
        );
      }

      // 持久化用户主题 JSON
      await ThemeStorage.saveUserTheme(userTheme);

      // 应用为激活主题（触发 250ms 过渡）
      await AppThemeManager.instance.applyCustomTheme(userTheme);

      if (mounted) {
        AppSnackBar.success(
            context, _isEditing ? '已更新主题' : '已应用并保存为新主题');
        widget.onClose?.call();
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '应用失败: $e');
      }
    }
  }

  /// 仅保存为新主题（不切换激活）
  Future<void> _onSaveAsNew() async {
    try {
      // v3.0 P6 优化：先弹命名框让用户命名
      final name = await NameDialog.show(context,
          title: '保存为新主题', initialValue: '我的主题');
      if (name == null) return; // 用户取消

      final newId = ThemeStorage.newThemeId();
      final userTheme = _preview.asUserThemeCopy(
        newId: newId,
        name: name,
        emoji: '🎨',
        description: '通过主题设计器创建',
      );

      await ThemeStorage.saveUserTheme(userTheme);
      // 修复 BUG：必须注册到 AppThemeManager 并通知监听者，
      // 否则"我的主题"列表不会刷新，新主题要重启应用才可见
      AppThemeManager.instance.registerTheme(userTheme);
      AppThemeManager.instance.notifyThemeChanged();

      if (mounted) {
        AppSnackBar.success(context, '已保存为新主题「$name」');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '保存失败: $e');
      }
    }
  }

  void _onCancel() {
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.background,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      child: UndoRedoKeyboardHandler(
        controller: _undoRedo,
        onUndo: _onUndo,
        onRedo: _onRedo,
        onEscape: _onCancel,
        child: Container(
          width: double.maxFinite,
          height: double.maxFinite,
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左侧预览区
                    Expanded(
                      flex: 3,
                      child: _buildPreviewArea(),
                    ),
                    const SizedBox(width: 12),
                    // 右侧调色板
                    Expanded(
                      flex: 2,
                      child: _buildPaletteArea(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(Icons.palette_outlined, size: 20, color: AppColors.primaryText),
        const SizedBox(width: 8),
        Text(
          '主题设计器 / 调色板',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(width: 10),
        // v3.0 P7 修复：模式徽章——让用户明确区分"编辑已有主题"和"新建主题"
        // 编辑模式：强调色 + edit 图标 + "编辑：[主题名]"，应用时更新原主题
        // 新建模式：infoBlue + fiber_new 图标 + "新建主题"，应用时弹命名框创建
        Tooltip(
          message: _isEditing
              ? '正在编辑已有主题（应用时更新原主题，不创建新主题）'
              : '新建主题模式（应用时需命名并创建为新主题）',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _isEditing
                  ? AppColors.selectedAccent.withOpacity(0.18)
                  : AppColors.infoBg,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: _isEditing
                    ? AppColors.selectedAccent.withOpacity(0.6)
                    : AppColors.infoBlue.withOpacity(0.6),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isEditing
                      ? Icons.edit_rounded
                      : Icons.fiber_new_rounded,
                  size: 11,
                  color: _isEditing
                      ? AppColors.selectedAccent
                      : AppColors.infoBlue,
                ),
                const SizedBox(width: 4),
                Text(
                  _isEditing ? '编辑：${_initialTheme.name}' : '新建主题',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _isEditing
                        ? AppColors.selectedAccent
                        : AppColors.infoBlue,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // v3.0.1 修复6：副标题提示快捷键
        Tooltip(
          message: '快捷键：Ctrl+Z 撤销 / Ctrl+Y 或 Ctrl+Shift+Z 重做 / Esc 取消',
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              borderRadius: BorderRadius.circular(3),
              border:
                  Border.all(color: AppColors.borderLight, width: 0.6),
            ),
            child: Text(
              'Ctrl+Z / Y',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 9,
                color: AppColors.placeholderText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        const Spacer(),
        // v3.0.1 修复6：重置按钮
        _buildHeaderButton(
          icon: Icons.restart_alt_rounded,
          label: '重置',
          tooltip: '重置到初始主题（清空编辑历史）',
          onTap: _onReset,
        ),
        const SizedBox(width: 8),
        UndoRedoBar(
          controller: _undoRedo,
          onUndo: _onUndo,
          onRedo: _onRedo,
        ),
      ],
    );
  }

  /// v3.0.1 修复6：头部工具按钮（带 tooltip）
  Widget _buildHeaderButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InteractiveWrapper(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.borderLight, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: AppColors.primaryText),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewArea() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderLight, width: 1.0),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 预览标题 + 页面切换 Tab + 提示
          Row(
            children: [
              Text(
                'UI 预览',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 12),
              // v3.0.1 修复2：页面切换 Tab（库/探索/添加）
              _buildPreviewPageTabs(),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '双击元素进入编辑（点击选择）',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    color: AppColors.placeholderText,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 当前选中元素面包屑
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.borderLight, width: 0.6),
            ),
            child: Row(
              children: [
                Icon(Icons.ads_click, size: 12, color: AppColors.infoBlue),
                const SizedBox(width: 4),
                Text(
                  '当前选中：${_selectedElement?.displayName ?? "未选择"}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: AppColors.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // v3.0.1 修复3：左侧图层树 + 右侧预览骨架
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 图层目录树
                SizedBox(
                  width: 200,
                  child: LayerTreePanel(
                    selectedElementId: _selectedElementId,
                    onElementSelect: (id) => _onElementTap(id),
                  ),
                ),
                const SizedBox(width: 8),
                // 预览骨架
                Expanded(
                  child: ValueListenableBuilder<CTThemeData>(
                    valueListenable: _previewNotifier,
                    builder: (context, previewData, _) {
                      // v3.0 P6-1：RepaintBoundary 隔离预览重绘，
                      // 避免拖动调色时整个弹窗被重新光栅化
                      return RepaintBoundary(
                        key: _previewBoundaryKey,
                        child: EditorPreviewBuilder(
                          themeData: previewData,
                          selectedElementId: _selectedElementId,
                          onElementTap: _onElementTap,
                          onElementDoubleTap: _onElementDoubleTap,
                          previewPage: _previewPage,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v3.0.1 修复2：预览页面切换 Tab（库/探索/添加/主页/详情窗口）
  Widget _buildPreviewPageTabs() {
    const pages = [
      (PreviewPage.library, '库页', Icons.grid_view_outlined),
      (PreviewPage.discover, '探索页', Icons.explore_outlined),
      (PreviewPage.join, '添加页', Icons.add_circle_outline),
      (PreviewPage.home, '主页', Icons.home_outlined),
      (PreviewPage.detail, '详情窗口', Icons.info_outline),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.borderLight, width: 0.6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: pages.map((p) {
          final isActive = _previewPage == p.$1;
          return InteractiveWrapper(
            onTap: () => setState(() => _previewPage = p.$1),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.selectedAccent.withOpacity(0.25)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Row(
                children: [
                  Icon(p.$3,
                      size: 11,
                      color: isActive
                          ? AppColors.primaryText
                          : AppColors.secondaryText),
                  const SizedBox(width: 4),
                  Text(
                    p.$2,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      fontWeight: isActive
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isActive
                          ? AppColors.primaryText
                          : AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPaletteArea() {
    final element = _selectedElement;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderLight, width: 1.0),
      ),
      child: ValueListenableBuilder<CTThemeData>(
        valueListenable: _previewNotifier,
        builder: (context, previewData, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部：影响范围提示
              if (element != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ImpactHint(descriptor: element),
                ),
              // 中间：颜色通道面板
              Expanded(
                child: element == null
                    ? Center(
                        child: Text(
                          '请在左侧预览中选择元素',
                          style: TextStyle(
                            color: AppColors.secondaryText,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ColorChannelPanel(
                        element: element,
                        themeData: previewData,
                        onColorChanged: _onColorChanged,
                        onColorChangeEnd: _onColorChangeEnd,
                        recentColors: _recentColors,
                        channelVisibility: _channelVisibility,
                        onToggleVisibility: _onToggleVisibility,
                        onPickColor: _pickColorFromPreview,
                      ),
              ),
              // 底部：背景图上传
              _buildBackgroundUploadSection(previewData),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBackgroundUploadSection(CTThemeData previewData) {
    final hasUserBg =
        previewData.backgroundImage.source == BackgroundImageSource.file;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        border: Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.wallpaper_outlined,
              size: 14, color: AppColors.secondaryText),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hasUserBg ? '已设置背景图' : '应用背景图',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                color: AppColors.secondaryText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InteractiveWrapper(
            onTap: _onUploadBackground,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.borderLight, width: 0.6),
              ),
              child: Text(
                '上传',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
            ),
          ),
          if (hasUserBg) ...[
            const SizedBox(width: 4),
            // v3.0 P7：调整位置（拖拽 + 滚轮缩放，Figma 风格）
            InteractiveWrapper(
              onTap: _onAdjustBackground,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.borderLight, width: 0.6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.crop_free_rounded,
                        size: 11, color: AppColors.primaryText),
                    const SizedBox(width: 4),
                    Text(
                      '调整位置',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            InteractiveWrapper(
              onTap: _onClearBackground,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.errorBg,
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: AppColors.dangerRed, width: 0.6),
                ),
                child: Text(
                  '移除',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.dangerRed,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooter() {
    // v3.0.1 修复6：检测是否有未保存的修改
    final hasUnsavedChanges = _previewNotifier.value != _initialTheme;

    // v3.0 P7 修复：Footer 按钮文字/tooltip 根据 _isEditing 动态变化
    // 编辑模式：主按钮="更新主题"（更新原主题，不弹命名框）
    // 新建模式：主按钮="保存为新主题并应用"（弹命名框创建）
    final applyLabel = _isEditing ? '更新主题' : '保存为新主题并应用';
    final applyTooltip = _isEditing
        ? '更新当前编辑的主题并立即应用到全应用'
        : '创建新主题并立即应用到全应用';
    final saveAsNewLabel = _isEditing ? '另存为新主题' : '保存为新主题';
    final saveAsNewTooltip = _isEditing
        ? '基于当前编辑另存为新主题（不切换当前主题）'
        : '保存到"我的主题"列表，但不切换当前主题';
    final applyIcon = _isEditing ? Icons.save_as_rounded : Icons.check_rounded;

    return Row(
      children: [
        // v3.0.1 修复6：左侧未保存指示器
        if (hasUnsavedChanges) ...[
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.infoBg,
              borderRadius: BorderRadius.circular(4),
              border:
                  Border.all(color: AppColors.infoBlue, width: 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note,
                    size: 12, color: AppColors.infoBlue),
                const SizedBox(width: 4),
                Text(
                  '有未保存的修改',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.infoBlue,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: AppColors.borderLight, width: 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 12, color: AppColors.secondaryText),
                const SizedBox(width: 4),
                Text(
                  '无修改',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
        const Spacer(),
        // 取消
        _buildFooterButton(
          icon: Icons.close_rounded,
          label: '取消',
          tooltip: '关闭编辑器（不保存）',
          onTap: _onCancel,
          backgroundColor: AppColors.placeholderBg,
          borderColor: AppColors.borderLight,
          textColor: AppColors.secondaryText,
        ),
        const SizedBox(width: 8),
        // 保存为新主题 / 另存为新主题（根据模式动态切换文字）
        _buildFooterButton(
          icon: Icons.bookmark_add_outlined,
          label: saveAsNewLabel,
          tooltip: saveAsNewTooltip,
          onTap: _onSaveAsNew,
          backgroundColor: AppColors.buttonBackground,
          borderColor: AppColors.border,
          textColor: AppColors.primaryText,
        ),
        const SizedBox(width: 8),
        // 应用并保存 / 更新主题（根据模式动态切换文字与图标）
        _buildFooterButton(
          icon: applyIcon,
          label: applyLabel,
          tooltip: applyTooltip,
          onTap: _onApply,
          backgroundColor: AppColors.selectedAccent,
          borderColor: AppColors.border,
          textColor: AppColors.primaryText,
          isPrimary: true,
        ),
      ],
    );
  }

  /// v3.0.1 修复6：底部操作按钮（带图标 + tooltip）
  Widget _buildFooterButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
    required Color backgroundColor,
    required Color borderColor,
    required Color textColor,
    bool isPrimary = false,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InteractiveWrapper(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: borderColor, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 14,
                  color: isPrimary ? textColor : textColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight:
                      isPrimary ? FontWeight.w700 : FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
