import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import 'interactive_wrapper.dart';

/// 全部标签选择弹窗
///
/// 阶段4.2：工具栏只显示前 N 个标签，多余标签通过本弹窗选择。
/// - 顶部搜索框：实时过滤标签名
/// - 中部 Wrap：所有标签芯片，点击切换选中
/// - 底部操作栏：已选计数 + 清空 + 确认
///
/// 调用方式：
/// ```dart
/// final result = await DiscoverAllTagsDialog.show(
///   context: context,
///   allTags: ['恋爱', '悬疑', ...],
///   selectedTags: {'恋爱'},
/// );
/// if (result != null) { /* result 为新的选中集合，null 表示取消 */ }
/// ```
class DiscoverAllTagsDialog extends StatefulWidget {
  final List<String> allTags;
  final Set<String> selectedTags;

  const DiscoverAllTagsDialog({
    super.key,
    required this.allTags,
    required this.selectedTags,
  });

  /// 弹出全部标签弹窗，返回用户最终选中的标签集合。
  /// 返回 null 表示用户取消（点击关闭/遮罩）。
  static Future<Set<String>?> show({
    required BuildContext context,
    required List<String> allTags,
    required Set<String> selectedTags,
  }) {
    return showDialog<Set<String>?>(
      context: context,
      builder: (ctx) => DiscoverAllTagsDialog(
        allTags: allTags,
        selectedTags: Set.from(selectedTags),
      ),
    );
  }

  @override
  State<DiscoverAllTagsDialog> createState() => _DiscoverAllTagsDialogState();
}

class _DiscoverAllTagsDialogState extends State<DiscoverAllTagsDialog> {
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
    return sorted
        .where((t) => t.toLowerCase().contains(_query))
        .toList();
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
    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border, width: 1.5),
      ),
      child: Container(
        width: 560,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            _buildSearchField(),
            Flexible(child: _buildTagGrid()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.placeholderCover, width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.label_outline_rounded,
              size: 22, color: AppColors.border),
          const SizedBox(width: 10),
          Text(
            '全部标签',
            style: AppStyles.titleLarge.copyWith(fontSize: 20),
          ),
          const Spacer(),
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(null),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 20, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          border: Border.all(color: AppColors.border, width: 1.4),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.search_rounded,
                size: 16, color: AppColors.secondaryText.withOpacity(0.6)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                style: AppStyles.bodyRegular.copyWith(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索标签...',
                  hintStyle: AppStyles.bodyRegular.copyWith(
                    fontSize: 13,
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
                onTap: () {
                  _searchController.clear();
                },
                hoverScale: 1.0,
                hoverOffset: Offset.zero,
                child: Icon(Icons.cancel_rounded,
                    size: 16, color: AppColors.secondaryText.withOpacity(0.5)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagGrid() {
    final tags = _filteredTags;
    if (tags.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off_rounded,
                  size: 36, color: AppColors.secondaryText.withOpacity(0.3)),
              const SizedBox(height: 12),
              Text(
                '未找到匹配的标签',
                style: AppStyles.bodyRegular
                    .copyWith(color: AppColors.secondaryText),
              ),
            ],
          ),
        ),
      );
    }

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tags.map((tag) {
            final isSelected = _selected.contains(tag);
            return _DialogTagChip(
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
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: AppColors.placeholderCover, width: 1)),
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length} 个',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 13,
              color: AppColors.secondaryText,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          // 清空按钮
          InteractiveWrapper(
            onTap: _selected.isEmpty ? null : _clearAll,
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _selected.isEmpty
                      ? AppColors.placeholderCover
                      : AppColors.dangerRed.withOpacity(0.5),
                  width: 1.2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '清空',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _selected.isEmpty
                      ? AppColors.secondaryText.withOpacity(0.4)
                      : AppColors.dangerRed.withOpacity(0.8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 确认按钮
          InteractiveWrapper(
            onTap: () => Navigator.of(context).pop(_selected),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.15),
                    offset: const Offset(0, 2),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Text(
                '确认',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 13,
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

/// 弹窗内的标签芯片（与工具栏 _TagChip 视觉一致，但简化动画）
class _DialogTagChip extends StatelessWidget {
  final String tag;
  final bool isSelected;
  final VoidCallback onTap;

  const _DialogTagChip({
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.infoBlue.withOpacity(0.12)
                : AppColors.buttonBackground,
            border: Border.all(
              color: isSelected ? AppColors.infoBlue : AppColors.border,
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(14),
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
