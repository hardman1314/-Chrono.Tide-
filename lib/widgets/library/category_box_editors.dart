import 'package:flutter/material.dart';

import '../../services/library_smart_group_service.dart';
import '../../theme/app_colors.dart';
import '../app_dialog.dart';
import '../app_snack_bar.dart';

/// 「编辑标签」结果载荷。
class TagManageResult {
  const TagManageResult();
}

/// 标签库管理弹窗（Footer「+ 编辑标签」入口）。
///
/// 边界与旧「智能归纳编辑」一致：**只能改展示层**——
/// - 重命名 = 写 `SmartGroupService` 的展示名覆盖（不批量改游戏数据）；
/// - 隐藏 / 恢复 = 展示层开关（隐藏后不再出现在标签库，可随时恢复）；
/// - 成员增删请在游戏详情里改标签（分组与数据永不脱节）。
///
/// 列表 = 种子分类法标签 + 库内派生标签（[entries] 由库页组装）。
class TagManageDialog extends StatefulWidget {
  const TagManageDialog({super.key, required this.entries});

  /// 可管理的标签条目（name / count / key）。
  final List<TagManageEntry> entries;

  static Future<TagManageResult?> show(BuildContext context,
      {required List<TagManageEntry> entries}) {
    return showAppDialog<TagManageResult>(
      context: context,
      builder: (_) => TagManageDialog(entries: entries),
    );
  }

  @override
  State<TagManageDialog> createState() => _TagManageDialogState();
}

class _TagManageDialogState extends State<TagManageDialog> {
  /// 每行的展开态（展开后显示重命名输入框）。
  final Set<String> _expanded = {};

  late final Map<String, TextEditingController> _nameControllers;

  @override
  void initState() {
    super.initState();
    _nameControllers = {
      for (final e in widget.entries)
        e.key: TextEditingController(text: e.displayName),
    };
  }

  @override
  void dispose() {
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _rename(TagManageEntry entry) async {
    final controller = _nameControllers[entry.key]!;
    final trimmed = controller.text.trim();
    // 与 SmartGroupEditDialog 同语义：空串/原值 = 恢复默认显示
    await SmartGroupService.instance.renameGroup(
      entry.key,
      (trimmed.isEmpty || trimmed == entry.name) ? null : trimmed,
    );
    if (mounted) AppSnackBar.success(context, '已更新标签「${entry.name}」的显示名');
  }

  Future<void> _toggleHidden(TagManageEntry entry) async {
    await SmartGroupService.instance
        .setHidden(entry.key, !entry.hidden);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
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
                '编辑标签',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '仅调整标签的显示名与可见性；成员由游戏数据派生，'
                '增删请在游戏详情里改标签。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.placeholderText),
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                child: widget.entries.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '暂无可管理的标签',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.placeholderText),
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: widget.entries.length,
                        itemBuilder: (context, index) =>
                            _buildRow(widget.entries[index]),
                      ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: _actionButton('完成', AppColors.selectedAccent, () {
                  Navigator.of(context).pop(const TagManageResult());
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(TagManageEntry entry) {
    final expanded = _expanded.contains(entry.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entry.hidden ? '${entry.displayName}（已隐藏）' : entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: entry.hidden
                        ? AppColors.placeholderText
                        : AppColors.primaryText,
                  ),
                ),
              ),
              Text(
                '${entry.count}',
                style: TextStyle(
                    fontSize: 11, color: AppColors.placeholderText),
              ),
              const SizedBox(width: 10),
              _smallAction(
                expanded ? '收起' : '重命名',
                () => setState(() {
                  expanded
                      ? _expanded.remove(entry.key)
                      : _expanded.add(entry.key);
                }),
              ),
              const SizedBox(width: 6),
              _smallAction(
                entry.hidden ? '恢复显示' : '隐藏',
                () => _toggleHidden(entry),
              ),
            ],
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameControllers[entry.key],
                    style: TextStyle(
                        fontSize: 13, color: AppColors.primaryText),
                    cursorColor: AppColors.selectedAccent,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: entry.name,
                      hintStyle: TextStyle(
                          fontSize: 12,
                          color: AppColors.placeholderText),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.selectedAccent, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _smallAction('保存', () => _rename(entry)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _smallAction(String label, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 11, color: AppColors.secondaryText),
          ),
        ),
      ),
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
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

/// 编辑标签弹窗的行数据（库页组装，含派生计数与覆盖项现状）。
class TagManageEntry {
  const TagManageEntry({
    required this.key,
    required this.name,
    required this.displayName,
    required this.count,
    required this.hidden,
  });

  /// `tag:<名称>`（SmartGroupService 口径）。
  final String key;

  /// 原始标签名。
  final String name;

  /// 当前展示名（含用户覆盖）。
  final String displayName;
  final int count;
  final bool hidden;
}

/// 「添加会社」弹窗结果。
class AddCompanyResult {
  const AddCompanyResult({required this.name, required this.subName});

  final String name;
  final String subName;
}

/// 添加自定义会社弹窗（Footer「+ 添加会社」入口）。
///
/// 自定义会社的成员计数按 `developer` 原文精确匹配（trim 后），
/// 不进入会社词典——词典归一化仍只属于 `CompanyAliasStore`。
class AddCompanyDialog extends StatefulWidget {
  const AddCompanyDialog({super.key});

  static Future<AddCompanyResult?> show(BuildContext context) {
    return showAppDialog<AddCompanyResult>(
      context: context,
      builder: (_) => const AddCompanyDialog(),
    );
  }

  @override
  State<AddCompanyDialog> createState() => _AddCompanyDialogState();
}

class _AddCompanyDialogState extends State<AddCompanyDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _subController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _subController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppSnackBar.warning(context, '请填写会社名称');
      return;
    }
    Navigator.of(context).pop(AddCompanyResult(
      name: name,
      subName: _subController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
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
                '添加会社',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '自定义会社按「游戏详情里的会社名」原文匹配作品；'
                '与内置词典同名的会社不会重复添加。',
                style: TextStyle(
                    fontSize: 11, color: AppColors.placeholderText),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                autofocus: true,
                style: TextStyle(
                    fontSize: 14, color: AppColors.primaryText),
                cursorColor: AppColors.selectedAccent,
                decoration: InputDecoration(
                  hintText: '会社名称（如：柚子社）',
                  hintStyle: TextStyle(
                      fontSize: 13, color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.5),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _subController,
                style: TextStyle(
                    fontSize: 13, color: AppColors.primaryText),
                cursorColor: AppColors.selectedAccent,
                decoration: InputDecoration(
                  hintText: '副名（英/日文原名，可选）',
                  hintStyle: TextStyle(
                      fontSize: 12, color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.5),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _actionButton('取消', AppColors.secondaryText, () {
                    Navigator.of(context).pop();
                  }),
                  const SizedBox(width: 10),
                  _actionButton('添加', AppColors.selectedAccent, _submit),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
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
