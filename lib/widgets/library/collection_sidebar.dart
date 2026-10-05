import 'package:flutter/material.dart';

import '../../services/collection_service.dart';
import '../../services/library_smart_group_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_dialog.dart';

// 原收藏夹侧栏（CollectionSidebar）已整体改造为「分类匣」
// `category_box_sidebar.dart`；本文件仅保留其复用的编辑弹窗。

/// 收藏夹编辑结果
class CollectionEditResult {
  final bool deleted;
  final String name;
  final int colorValue;

  const CollectionEditResult({
    required this.deleted,
    required this.name,
    required this.colorValue,
  });
}

/// 新建 / 编辑收藏夹对话框（名称 + 颜色，编辑模式附带删除）
///
/// 通过 showAppDialog 展示（遮罩从标题栏下方开始），
/// 返回 [CollectionEditResult]，null 表示取消。
class CollectionEditDialog extends StatefulWidget {
  const CollectionEditDialog({super.key, this.existing});

  final GameCollection? existing;

  static Future<CollectionEditResult?> show(BuildContext context,
      {GameCollection? existing}) {
    return showAppDialog<CollectionEditResult>(
      context: context,
      builder: (_) => CollectionEditDialog(existing: existing),
    );
  }

  @override
  State<CollectionEditDialog> createState() => _CollectionEditDialogState();
}

class _CollectionEditDialogState extends State<CollectionEditDialog> {
  late final TextEditingController _nameController;
  late int _selectedColor;
  bool _deleteArmed = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _selectedColor =
        widget.existing?.colorValue ?? CollectionService.palette.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(CollectionEditResult(
      deleted: false,
      name: _nameController.text.trim(),
      colorValue: _selectedColor,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEdit ? '编辑收藏夹' : '新建收藏夹',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                autofocus: true,
                style: TextStyle(
                    fontSize: 14,
                    color: AppColors.primaryText),
                decoration: InputDecoration(
                  hintText: '收藏夹名称',
                  hintStyle:
                      TextStyle(color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.5),
                  ),
                  filled: true,
                  fillColor: AppColors.background,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              Text(
                '颜色标识',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: CollectionService.palette.map((value) {
                  return _buildColorOption(Color(value), value);
                }).toList(),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (isEdit) _buildDeleteButton(),
                  const Spacer(),
                  _buildActionButton('取消', AppColors.secondaryText, () {
                    Navigator.of(context).pop();
                  }),
                  const SizedBox(width: 10),
                  _buildActionButton(
                      '保存', AppColors.selectedAccent, _submit),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorOption(Color color, int value) {
    final isSelected = _selectedColor == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _selectedColor = value),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryText
                  : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: isSelected
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }

  /// 两段式删除：第一次点击进入待确认态，第二次点击才真正删除
  Widget _buildDeleteButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (!_deleteArmed) {
            setState(() => _deleteArmed = true);
          } else {
            Navigator.of(context).pop(CollectionEditResult(
              deleted: true,
              name: widget.existing?.name ?? '',
              colorValue: _selectedColor,
            ));
          }
        },
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
                color: _deleteArmed
                    ? AppColors.dangerRed
                    : AppColors.border),
            borderRadius: BorderRadius.circular(8),
            color: _deleteArmed
                ? AppColors.dangerRed.withOpacity(0.1)
                : Colors.transparent,
          ),
          child: Text(
            _deleteArmed ? '确认删除' : '删除',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _deleteArmed
                  ? AppColors.dangerRed
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(
      String label, Color color, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 智能归纳分组编辑结果
class SmartGroupEditResult {
  /// 新的展示名（null / 空串 = 不改名，回退到数据原值）
  final String? displayName;
  final bool pinned;
  final bool hidden;

  /// true = 恢复默认（清空该分组的全部展示层覆盖项）
  final bool reset;

  const SmartGroupEditResult({
    required this.displayName,
    required this.pinned,
    required this.hidden,
    this.reset = false,
  });
}

/// 智能归纳分组编辑弹窗（重命名 / 置顶 / 隐藏 / 恢复默认）
///
/// ⚠️ 这里**只能改展示层**。分组成员由游戏数据派生（标签 / 会社），
/// 增删成员请在游戏详情里改标签/会社——这样分组与数据永远不会脱节。
class SmartGroupEditDialog extends StatefulWidget {
  const SmartGroupEditDialog({super.key, required this.group});

  final SmartGroup group;

  static Future<SmartGroupEditResult?> show(BuildContext context,
      {required SmartGroup group}) {
    return showAppDialog<SmartGroupEditResult>(
      context: context,
      builder: (_) => SmartGroupEditDialog(group: group),
    );
  }

  @override
  State<SmartGroupEditDialog> createState() => _SmartGroupEditDialogState();
}

class _SmartGroupEditDialogState extends State<SmartGroupEditDialog> {
  late final TextEditingController _nameController;
  late bool _pinned;
  late bool _hidden;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.group.displayName);
    _pinned = widget.group.pinned;
    _hidden = widget.group.hidden;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String get _sourceLabel {
    final g = widget.group;
    if (g.kind == SmartGroupKind.tag) return '标签：${g.value}';
    if (g.isUnassignedDeveloper) return '会社：未填写';
    return '会社：${g.value}';
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Center(
      child: Container(
        width: 380,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadowColor.withOpacity(0.18),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '编辑归纳分组',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$_sourceLabel · ${g.count} 部游戏（成员由游戏数据派生，改标签/会社即变）',
              style: TextStyle(
                  fontSize: 12, color: AppColors.placeholderText),
            ),
            const SizedBox(height: 14),
            Text('显示名称',
                style: TextStyle(
                    fontSize: 12, color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.pageBackground,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _nameController,
                style:
                    TextStyle(fontSize: 13, color: AppColors.primaryText),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: g.isUnassignedDeveloper
                      ? SmartGroupService.kUnassignedDevLabel
                      : g.value,
                  hintStyle: TextStyle(
                      fontSize: 13, color: AppColors.inputHint),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildSwitchRow(
              label: '置顶',
              value: _pinned,
              onChanged: (v) => setState(() => _pinned = v),
            ),
            _buildSwitchRow(
              label: '隐藏',
              value: _hidden,
              onChanged: (v) => setState(() => _hidden = v),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildActionButton('恢复默认', AppColors.secondaryText, () {
                  Navigator.of(context).pop(const SmartGroupEditResult(
                    displayName: null,
                    pinned: false,
                    hidden: false,
                    reset: true,
                  ));
                }),
                const SizedBox(width: 10),
                _buildActionButton('取消', AppColors.secondaryText, () {
                  Navigator.of(context).pop();
                }),
                const SizedBox(width: 10),
                _buildActionButton('保存', AppColors.selectedAccent, () {
                  Navigator.of(context).pop(SmartGroupEditResult(
                    displayName: _nameController.text,
                    pinned: _pinned,
                    hidden: _hidden,
                  ));
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, color: AppColors.primaryText)),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _buildActionButton(
      String label, Color color, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
