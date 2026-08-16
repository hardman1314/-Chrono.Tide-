import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import 'interactive_wrapper.dart';

/// 全部标签弹出菜单
///
/// 交互形式：类似库页右键菜单的 Overlay 弹出层，而非独立 Dialog。
/// - 顶部搜索框：实时过滤标签名
/// - 中部 Wrap：所有标签芯片，点击切换选中
/// - 底部操作栏：已选计数 + 清空 + 确认
/// - 点击菜单外区域自动关闭
///
/// 调用方式：
/// ```dart
/// final result = await TagsPopupMenu.show(
///   context: context,
///   anchorKey: _buttonKey,
///   allTags: ['恋爱', '悬疑', ...],
///   selectedTags: {'恋爱'},
/// );
/// if (result != null) { /* result 为新的选中集合 */ }
/// ```
class TagsPopupMenu extends StatefulWidget {
  final List<String> allTags;
  final Set<String> selectedTags;
  final Rect anchorRect;
  final VoidCallback? onDismiss;

  const TagsPopupMenu({
    super.key,
    required this.allTags,
    required this.selectedTags,
    required this.anchorRect,
    this.onDismiss,
  });

  /// 弹出标签菜单，返回用户最终选中的标签集合。
  /// 返回 null 表示用户取消（点击遮罩）。
  static Future<Set<String>?> show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required List<String> allTags,
    required Set<String> selectedTags,
  }) {
    // 获取锚点按钮的位置和尺寸
    final renderBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return Future.value(null);

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final anchorRect = offset & size;

    final completer = Completer<Set<String>?>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TagsPopupMenuOverlay(
        anchorRect: anchorRect,
        allTags: allTags,
        selectedTags: Set.from(selectedTags),
        onConfirm: (tags) {
          entry.remove();
          if (!completer.isCompleted) completer.complete(tags);
        },
        onCancel: () {
          entry.remove();
          if (!completer.isCompleted) completer.complete(null);
        },
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(entry);
    return completer.future;
  }

  @override
  State<TagsPopupMenu> createState() => _TagsPopupMenuState();
}

class _TagsPopupMenuState extends State<TagsPopupMenu> {
  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

// ==================== Overlay 内容 ====================

class _TagsPopupMenuOverlay extends StatefulWidget {
  final Rect anchorRect;
  final List<String> allTags;
  final Set<String> selectedTags;
  final ValueChanged<Set<String>> onConfirm;
  final VoidCallback onCancel;

  const _TagsPopupMenuOverlay({
    required this.anchorRect,
    required this.allTags,
    required this.selectedTags,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_TagsPopupMenuOverlay> createState() => _TagsPopupMenuOverlayState();
}

class _TagsPopupMenuOverlayState extends State<_TagsPopupMenuOverlay> {
  late Set<String> _selected;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.selectedTags);
    _searchController.addListener(() {
      final newQuery = _searchController.text.trim().toLowerCase();
      if (newQuery != _query) {
        setState(() => _query = newQuery);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _filteredTags {
    final sorted = List<String>.from(widget.allTags)..sort();
    if (_query.isEmpty) return sorted;
    return sorted.where((t) => t.toLowerCase().contains(_query)).toList();
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else {
        _selected.add(tag);
      }
    });
  }

  void _clearAll() {
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 340.0;
    const margin = 8.0;

    // 菜单水平位置：优先锚点左对齐，不溢出右边
    final maxLeft =
        math.max(margin, screenSize.width - menuWidth - margin);
    final left = widget.anchorRect.left.clamp(margin, maxLeft);

    // 菜单垂直位置：优先锚点下方，放不下时上翻
    const estimatedMenuHeight = 380.0;
    double top;
    if (widget.anchorRect.bottom + estimatedMenuHeight >
        screenSize.height - margin) {
      top = math.max(
          margin, widget.anchorRect.top - estimatedMenuHeight);
    } else {
      top = widget.anchorRect.bottom + 6;
    }

    return Stack(
      children: [
        // 全屏遮罩：点击关闭菜单
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onCancel,
          ),
        ),
        // 菜单本体
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: menuWidth,
              constraints: BoxConstraints(
                maxHeight: screenSize.height * 0.7,
              ),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 2),
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.13),
                    offset: const Offset(4, 5),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSearchField(),
                  Flexible(child: _buildTagGrid()),
                  _buildFooter(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: Border.all(color: AppColors.border, width: 1.2),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(Icons.search_rounded,
                size: 15, color: AppColors.secondaryText.withOpacity(0.6)),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: AppStyles.bodyRegular.copyWith(fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索标签...',
                  hintStyle: AppStyles.bodyRegular.copyWith(
                    fontSize: 12,
                    color: AppColors.primaryText.withOpacity(0.4),
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_query.isNotEmpty)
              InteractiveWrapper(
                onTap: () => _searchController.clear(),
                hoverScale: 1.0,
                hoverOffset: Offset.zero,
                child: Icon(Icons.cancel_rounded,
                    size: 14,
                    color: AppColors.secondaryText.withOpacity(0.5)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagGrid() {
    final tags = _filteredTags;
    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 28,
                color: AppColors.secondaryText.withOpacity(0.3)),
            const SizedBox(height: 8),
            Text(
              '未找到匹配的标签',
              style: AppStyles.bodyRegular
                  .copyWith(fontSize: 12, color: AppColors.secondaryText),
            ),
          ],
        ),
      );
    }

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: tags.map((tag) {
            final isSelected = _selected.contains(tag);
            return _MenuTagChip(
              tag: tag,
              isSelected: isSelected,
              onTap: () => _toggleTag(tag),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.placeholderCover, width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length}',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 12,
              color: AppColors.secondaryText,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          InteractiveWrapper(
            onTap: _selected.isEmpty ? null : _clearAll,
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _selected.isEmpty
                      ? AppColors.placeholderCover
                      : AppColors.dangerRed.withOpacity(0.5),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '清空',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _selected.isEmpty
                      ? AppColors.secondaryText.withOpacity(0.4)
                      : AppColors.dangerRed.withOpacity(0.8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InteractiveWrapper(
            onTap: () => widget.onConfirm(_selected),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.15),
                    offset: const Offset(0, 2),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Text(
                '确认',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 菜单内的标签芯片（紧凑版，与工具栏 _TagChip 视觉一致）
class _MenuTagChip extends StatelessWidget {
  final String tag;
  final bool isSelected;
  final VoidCallback onTap;

  const _MenuTagChip({
    required this.tag,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.infoBlue.withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? AppColors.infoBlue : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? AppColors.infoBlue : AppColors.secondaryText,
              height: 16 / 12,
            ),
          ),
        ),
      ),
    );
  }
}
