import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../services/company_alias_store.dart'; // ★ 会社归一化：输入联想
import 'field_lock_button.dart';

class CoverSection extends StatelessWidget {
  final JoinController controller;

  const CoverSection({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return CoverSectionWithLock(controller: controller);
  }
}

class NameInput extends StatefulWidget {
  final JoinController controller;

  const NameInput({super.key, required this.controller});

  @override
  State<NameInput> createState() => _NameInputState();
}

class _NameInputState extends State<NameInput> {
  bool _hasInteracted = false;
  bool _isSwitchHovered = false;
  bool get _showError =>
      _hasInteracted && widget.controller.nameController.text.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // 双标题：右下角显示"另一个标题"，点击切换
    final canToggle = controller.canToggleTitle;
    final otherTitle = controller.usingMetadataTitle
        ? controller.originalTitle
        : (controller.metadataTitle ?? '');
    final otherLabel = controller.usingMetadataTitle ? '原标题' : '元数据标题';
    final showSwitch = canToggle && otherTitle.isNotEmpty;

    return _LockableField(
      isLocked: controller.nameLocked,
      onToggleLock: () => controller.toggleNameLock(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Container(
                // 设计稿「Text Input - 游戏名称」容器 314×62.2
                height: 62,
                decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(
                      color: controller.nameLocked
                          ? AppColors.primaryText
                          : (_showError
                              ? AppColors.dangerRed
                              : AppColors.border),
                      width: controller.nameLocked ? 2.4 : 1.4,
                    ),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.shadowColor,
                          offset: const Offset(2, 3),
                          blurRadius: 0)
                    ]),
                padding: const EdgeInsets.all(14),
                child: TextField(
                  controller: controller.nameController,
                  // 设计稿 fs=21.97 letterSpacing=0.915
                  style: TextStyle(
                      fontSize: 22,
                      letterSpacing: 0.9,
                      color: AppColors.primaryText),
                  decoration: InputDecoration(
                      hintText: '输入名字',
                      hintStyle: TextStyle(
                          fontSize: 22,
                          letterSpacing: 0.9,
                          color: AppColors.placeholderText),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true),
                  onChanged: (_) {
                    _hasInteracted = true;
                    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                    controller.notifyListeners();
                    setState(() {});
                  },
                  onTap: () => _hasInteracted = true,
                ),
              ),
              // 双标题切换：右下角小字显示另一个标题，点击切换
              if (showSwitch)
                Positioned(
                  right: 6,
                  bottom: 5,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _isSwitchHovered = true),
                    onExit: (_) => setState(() => _isSwitchHovered = false),
                    child: GestureDetector(
                      onTap: () {
                        controller.toggleTitlePreference();
                        setState(() {});
                      },
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.background.withOpacity(0.88),
                          borderRadius: BorderRadius.circular(2),
                          border: _isSwitchHovered
                              ? Border.all(
                                  color: AppColors.infoBlue, width: 0.8)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.swap_horiz,
                              size: 11,
                              color: AppColors.infoBlue,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                '$otherLabel: $otherTitle',
                                style: TextStyle(
                                  // 设计稿 fs=9.15
                                  fontSize: 9.5,
                                  color: AppColors.secondaryText,
                                  decoration: _isSwitchHovered
                                      ? TextDecoration.underline
                                      : null,
                                  decorationColor: AppColors.infoBlue,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // 副标题输入：主标题下方的轻量输入区域（通常为日文原版标题，
          // 一键抓取后自动填充，用户可编辑），样式轻量不喧宾夺主
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              // 设计稿「Text Input - 副标题」314×36.6，边框 0.68，左右内边距 10
              height: 37,
              decoration: BoxDecoration(
                  color: AppColors.background,
                  border: Border.all(color: AppColors.border, width: 0.8),
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.shadowColor,
                        offset: const Offset(2, 2),
                        blurRadius: 0)
                  ]),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.subtitles_outlined,
                    size: 12,
                    color: AppColors.secondaryText,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: controller.subtitleController,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.primaryText),
                      decoration: InputDecoration(
                          hintText: '副标题（原版标题，抓取后自动填充）',
                          hintStyle: TextStyle(
                              // 设计稿 fs=10.99
                              fontSize: 11,
                              color: AppColors.placeholderText),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isCollapsed: true),
                      onChanged: (_) {
                        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                        controller.notifyListeners();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // UX-05: 名称为空时的实时错误提示
          if (_showError)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                '游戏名称不能为空',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.dangerRed,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class TagsInput extends StatelessWidget {
  final JoinController controller;

  const TagsInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return _LockableField(
      isLocked: controller.tagsLocked,
      onToggleLock: () => controller.toggleTagsLock(),
      child: Container(
        // 设计稿「Text Input - 制作人员(即标签)」容器 314×46.7
        height: 47,
        decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: controller.tagsLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.tagsLocked ? 2.4 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ]),
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: controller.tagsController,
          // 设计稿 fs=12.82 fw=700
          style: TextStyle(
              fontSize: 12.8,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText),
          decoration: InputDecoration(
              hintText: '标签（如：治愈, 废萌）',
              hintStyle: TextStyle(
                  fontSize: 12.8,
                  fontWeight: FontWeight.w700,
                  color: AppColors.placeholderText),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true),
        ),
      ),
    );
  }
}

class DeveloperInput extends StatelessWidget {
  final JoinController controller;

  const DeveloperInput({super.key, required this.controller});

  /// 会社联想候选（会社归一化）：输入非空时从词典联想；排除与输入归一化
  /// 相同的标准名。数量限 6。
  static List<CompanyRecord> _suggestionsFor(String raw) {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return const [];
    final query = raw.trim();
    if (query.isEmpty) return const [];
    final nq = CompanyAliasStore.normalize(query);
    return store
        .search(query, limit: 8)
        .where((r) => CompanyAliasStore.normalize(r.standardName) != nq)
        .take(6)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return _LockableField(
      isLocked: controller.developerLocked,
      onToggleLock: () => controller.toggleDeveloperLock(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            // 设计稿「Text Input - 开发商」容器 314×46.7
            height: 47,
            decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(
                  color: controller.developerLocked
                      ? AppColors.primaryText
                      : AppColors.border,
                  width: controller.developerLocked ? 2.4 : 1.4,
                ),
                boxShadow: [
                  BoxShadow(
                      color: AppColors.shadowColor,
                      offset: const Offset(2, 3),
                      blurRadius: 0)
                ]),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: controller.developerController,
              // 设计稿 fs=12.82 fw=700
              style: TextStyle(
                  fontSize: 12.8,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText),
              decoration: InputDecoration(
                  hintText: '会社（开发商）',
                  hintStyle: TextStyle(
                      fontSize: 12.8,
                      fontWeight: FontWeight.w700,
                      color: AppColors.placeholderText),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true),
            ),
          ),
          // ★ 会社归一化：词典联想候选——点击即填入标准名（入库时
          //   writeGameDir 解析必命中，devId 分组即时归并）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller.developerController,
            builder: (context, value, _) {
              final suggestions = _suggestionsFor(value.text);
              if (suggestions.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final rec in suggestions)
                      GestureDetector(
                        onTap: () {
                          controller.developerController.text =
                              rec.standardName;
                          controller.developerController.selection =
                              TextSelection.collapsed(
                                  offset: rec.standardName.length);
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            // 设计稿会社联想胶囊 65.8×23.8，边框 0.68，圆角 5.49
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(5.5),
                              border: Border.all(
                                  color: AppColors.placeholderCover,
                                  width: 0.8),
                            ),
                            child: Builder(builder: (context) {
                              final cn = rec.cnName;
                              final label =
                                  (cn != null && cn != rec.standardName)
                                      ? '${rec.standardName}（$cn）'
                                      : rec.standardName;
                              return Text(
                                label,
                                style: TextStyle(
                                  // 设计稿 fs=10.07
                                  fontSize: 10.5,
                                  color: AppColors.secondaryText,
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class DescInput extends StatelessWidget {
  final JoinController controller;

  const DescInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return _LockableField(
      isLocked: controller.descLocked,
      onToggleLock: () => controller.toggleDescLock(),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
            color: AppColors.background,
            // 设计稿简介容器 475×135，边框 1.48
            border: Border.all(
              color: controller.descLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.descLocked ? 2.4 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ]),
        // 简介可用区放大（18 → 14）：配合左栏上方收紧，整体多显示约 2 行正文
        padding: const EdgeInsets.all(14),
        child: TextField(
          controller: controller.descController,
          // 设计稿叙述性文本 fw=400（结构字段用 700，构成「粗/细」两档排版体系）
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.primaryText),
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: InputDecoration(
              hintText: '输入游戏简介...',
              hintStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.placeholderText),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true),
        ),
      ),
    );
  }
}

/// 可锁定字段的包装器
/// 在输入框右上角显示锁定按钮
class _LockableField extends StatelessWidget {
  final bool isLocked;
  final VoidCallback onToggleLock;
  final Widget child;

  const _LockableField({
    required this.isLocked,
    required this.onToggleLock,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        // 锁定按钮 - 右上角悬浮
        Positioned(
          top: -2,
          right: -2,
          child: FieldLockButton(
            isLocked: isLocked,
            onToggle: onToggleLock,
            size: 18,
          ),
        ),
      ],
    );
  }
}
