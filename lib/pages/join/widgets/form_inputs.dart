import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
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
                height: 67,
                decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(
                      color: controller.nameLocked
                          ? AppColors.primaryText
                          : (_showError
                              ? AppColors.dangerRed
                              : AppColors.border),
                      width: controller.nameLocked ? 3 : 2,
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
                  style: TextStyle(
                      fontFamily: 'ZhiMangXing',
                      fontSize: 24,
                      letterSpacing: 2.0,
                      color: AppColors.primaryText),
                  decoration: InputDecoration(
                      hintText: '输入名字',
                      hintStyle: TextStyle(
                          fontFamily: 'ZhiMangXing',
                          fontSize: 24,
                          letterSpacing: 2.0,
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
                                  fontFamily: 'Inter',
                                  fontSize: 10,
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
          // UX-05: 名称为空时的实时错误提示
          if (_showError)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                '游戏名称不能为空',
                style: TextStyle(
                  fontFamily: 'Inter',
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
        height: 51,
        decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: controller.tagsLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.tagsLocked ? 3 : 2,
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
          style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText),
          decoration: InputDecoration(
              hintText: '标签（如：治愈, 废萌）',
              hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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

  @override
  Widget build(BuildContext context) {
    return _LockableField(
      isLocked: controller.developerLocked,
      onToggleLock: () => controller.toggleDeveloperLock(),
      child: Container(
        height: 51,
        decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: controller.developerLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.developerLocked ? 3 : 2,
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
          style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText),
          decoration: InputDecoration(
              hintText: '会社（开发商）',
              hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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
            border: Border.all(
              color: controller.descLocked
                  ? AppColors.primaryText
                  : AppColors.border,
              width: controller.descLocked ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ]),
        padding: const EdgeInsets.all(18),
        child: TextField(
          controller: controller.descController,
          style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText),
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: InputDecoration(
              hintText: '输入游戏简介...',
              hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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
