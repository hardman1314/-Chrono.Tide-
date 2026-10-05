import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../modules/auth/local_account_service.dart';
import '../../modules/auth/user_model.dart';
import '../../theme/app_colors.dart';
import '../../widgets/interactive_wrapper.dart';

/// 本地账户基础信息填写窗口（需求 2）。
///
/// 入口：登录窗口【以本地游客进入】→ 直接进入软件 → 首帧弹出本窗口。
/// 名字必填，头像/个人简介可选；确认后经 [LocalAccountService.create]
/// 注册为本地账号，随后以「本地状态」使用软件。
///
/// 🔴 不可关闭（无关闭按钮、点击遮罩不关闭）：关闭将产生「已进入软件
/// 却没有身份」的边缘态，故必须完成填写。
class LocalAccountSetupDialog extends StatefulWidget {
  final ValueChanged<UserModel> onCreated;

  const LocalAccountSetupDialog({super.key, required this.onCreated});

  /// 首帧弹出（MainContainer initState 的 postFrame 调用）。
  static Future<void> show(
    BuildContext context, {
    required ValueChanged<UserModel> onCreated,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => LocalAccountSetupDialog(onCreated: onCreated),
    );
  }

  @override
  State<LocalAccountSetupDialog> createState() =>
      _LocalAccountSetupDialogState();
}

class _LocalAccountSetupDialogState extends State<LocalAccountSetupDialog> {
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();

  Uint8List? _avatarBytes;
  bool _creating = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  // ==================== 交互 ====================

  Future<void> _pickAvatar() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowedExtensions: const ['jpg', 'jpeg', 'png'],
        withData: true,
        dialogTitle: '选择头像（可选）',
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final ext = file.path?.split('.').last.toLowerCase() ?? '';
      if (!['jpg', 'jpeg', 'png'].contains(ext) ||
          (file.size > 2 * 1024 * 1024)) {
        setState(() => _errorMessage = '头像仅支持 ≤2MB 的 JPG/PNG 图片');
        return;
      }
      if (file.bytes == null || file.bytes!.isEmpty) return;

      if (!mounted) return;
      setState(() {
        _avatarBytes = file.bytes;
        _errorMessage = null;
      });
    } catch (e) {
      debugPrint('[LOCAL-SETUP] 选择头像失败: $e');
      if (mounted) setState(() => _errorMessage = '选择图片失败，请重试');
    }
  }

  Future<void> _handleConfirm() async {
    if (_creating) return;
    final name = _nameController.text.trim();
    final bio = _bioController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = '请为自己起一个名字');
      return;
    }
    if (name.length > 20) {
      setState(() => _errorMessage = '名字长度需在 1-20 个字符之间');
      return;
    }
    if (bio.length > 200) {
      setState(() => _errorMessage = '简介最多 200 个字符');
      return;
    }

    setState(() {
      _creating = true;
      _errorMessage = null;
    });

    try {
      final user = await LocalAccountService.create(
        name: name,
        bio: bio,
        avatarBytes: _avatarBytes,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onCreated(user);
    } catch (e) {
      debugPrint('[LOCAL-SETUP] 创建本地账户失败: $e');
      if (!mounted) return;
      setState(() {
        _creating = false;
        _errorMessage = '创建失败，请重试';
      });
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
        decoration: BoxDecoration(
          color: AppColors.sidebarBackground,
          border: Border.all(color: AppColors.border, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.border,
              offset: Offset(4, 6),
              blurRadius: 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            _buildAvatarPicker(),
            const SizedBox(height: 16),
            _buildNameField(),
            const SizedBox(height: 12),
            _buildBioField(),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildErrorMessage(),
            ],
            const SizedBox(height: 20),
            _buildConfirmButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '本地信息',
          style: TextStyle(
            fontSize: 28,
            height: 34 / 28,
            letterSpacing: 2.0,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '填写后即可开始使用 · 无需注册登录',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            height: 18 / 13,
            letterSpacing: 0.7,
            color: AppColors.secondaryText,
          ),
        ),
      ],
    );
  }

  /// 头像选择区（可选）：圆形预览 + 悬停遮罩，未选时显示默认图标。
  Widget _buildAvatarPicker() {
    return Center(
      child: GestureDetector(
        onTap: _creating ? null : _pickAvatar,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.placeholderCover,
              border: Border.all(color: AppColors.border, width: 1.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor,
                  offset: Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            padding: const EdgeInsets.all(4),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sidebarBackground,
                border: Border.all(color: AppColors.border, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: _avatarBytes != null
                  ? Image.memory(
                      _avatarBytes!,
                      width: 76,
                      height: 76,
                      fit: BoxFit.cover,
                    )
                  : SizedBox(
                      width: 76,
                      height: 76,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SvgPicture.asset(
                            'assets/images/user_avatar_icon.svg',
                            width: 28,
                            height: 28,
                            colorFilter: ColorFilter.mode(
                              AppColors.inputHint,
                              BlendMode.srcIn,
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            child: Text(
                              '选择头像（可选）',
                              style: TextStyle(
                                fontSize: 9,
                                height: 1.0,
                                color: AppColors.inputHint,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return _buildInputBox(
      controller: _nameController,
      hint: '起一个名字（必填）',
      iconPath: 'assets/images/person_icon.svg',
      maxLength: 20,
      enabled: !_creating,
      onSubmitted: (_) => _handleConfirm(),
    );
  }

  Widget _buildBioField() {
    return _buildInputBox(
      controller: _bioController,
      hint: '一句话介绍自己（可选）',
      maxLength: 200,
      enabled: !_creating,
      onSubmitted: (_) => _handleConfirm(),
    );
  }

  Widget _buildInputBox({
    required TextEditingController controller,
    required String hint,
    String? iconPath,
    int? maxLength,
    required bool enabled,
    required ValueChanged<String> onSubmitted,
  }) {
    return Container(
      width: double.infinity,
      height: 51,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(
          color: _errorMessage != null && hint.contains('必填')
              ? AppColors.dangerRed
              : AppColors.border,
          width: 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.borderLight,
            offset: Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(iconPath != null ? 38 : 12, 10, 10, 10),
            child: TextField(
              controller: controller,
              enabled: enabled,
              maxLength: maxLength,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.primaryText,
              ),
              onSubmitted: onSubmitted,
              decoration: InputDecoration(
                hintText: hint,
                counterText: '',
                hintStyle: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                  color: AppColors.inputHint,
                ),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
              ),
            ),
          ),
          if (iconPath != null)
            Positioned(
              left: 11,
              top: 15,
              child: SvgPicture.asset(iconPath, width: 18, height: 18),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.dangerRed, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 16, color: AppColors.dangerRed),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: AppColors.dangerRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmButton() {
    return InteractiveWrapper(
      onTap: _creating ? null : _handleConfirm,
      cursor: _creating ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        width: double.infinity,
        height: 55,
        decoration: BoxDecoration(
          color: _creating
              ? AppColors.infoBlue.withOpacity(0.7)
              : AppColors.selectedAccent,
          border: Border.all(color: AppColors.borderLight, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryText,
              offset: Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: _creating
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.primaryText),
                ),
              )
            : Text(
                '进入 Chrono Tide',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  height: 28 / 18,
                  color: AppColors.primaryText,
                ),
              ),
      ),
    );
  }
}
