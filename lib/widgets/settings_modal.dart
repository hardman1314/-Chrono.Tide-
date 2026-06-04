import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update/update_service.dart';
import '../services/update/update_models.dart';
import 'update_dialog.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import 'interactive_wrapper.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import '../core/path_helper.dart';
import '../services/install_path_preference.dart';
import '../services/metadata_fetcher.dart';
import '../services/local_game_registry.dart';

enum SettingsTab { profile, preference, about }

class SettingsModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback? onBack;
  const SettingsModal({super.key, required this.onClose, this.onBack});

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  SettingsTab _currentTab = SettingsTab.profile;
  late final TextEditingController _nicknameController;
  late final TextEditingController _bioController;
  late final FocusNode _nicknameFocusNode;
  late final FocusNode _bioFocusNode;
  bool _isSaving = false;
  String? _saveMessage;
  bool _saveSuccess = false;
  UserModel? _user;
  String? _avatarUrl;
  bool _isUploadingAvatar = false;
  Uint8List? _tempAvatarBytes;
  String? _tempAvatarFileName;
  String _appVersion = '0.8.0';
  bool _closeHovered = false;
  bool _themeDesignerExpanded = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController();
    _bioController = TextEditingController();
    _proxyController = TextEditingController();
    _nicknameFocusNode = FocusNode();
    _bioFocusNode = FocusNode();
    _loadUserData();
    _loadAppVersion();
    _loadDefaultInstallPath();
    _loadProxySettings();
  }

  void _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = info.version);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _bioController.dispose();
    _proxyController.dispose();
    _nicknameFocusNode.dispose();
    _bioFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    final user = await AuthService.getCurrentUser();
    if (!mounted) return;
    setState(() {
      _user = user;
      _avatarUrl = user?.avatarUrl ?? '';
      _nicknameController.text = user?.name ?? '';
      _bioController.text = user?.bio ?? '';
    });

    debugPrint(
        '[USER_PROFILE] 已同步服务器用户信息，昵称=${user?.name ?? ""}，简介="${user?.bio ?? ""}"');
  }

  Future<void> _handleSave() async {
    final nickname = _nicknameController.text.trim();
    final bio = _bioController.text.trim();

    if (nickname.isEmpty) {
      setState(() {
        _saveMessage = '昵称不能为空';
        _saveSuccess = false;
      });
      return;
    }

    if (nickname.length < 1 || nickname.length > 20) {
      setState(() {
        _saveMessage = '昵称长度需在1-20个字符之间';
        _saveSuccess = false;
      });
      return;
    }

    if (bio.length > 200) {
      setState(() {
        _saveMessage = '简介最多200个字符';
        _saveSuccess = false;
      });
      return;
    }

    debugPrint(
        '[USER_PROFILE] 提交用户信息修改：昵称=$nickname，简介=${bio.isNotEmpty ? bio.substring(0, bio.length.clamp(0, 20)) + (bio.length > 20 ? "..." : "") : "(空)"}');

    setState(() {
      _isSaving = true;
      _saveMessage = null;
    });

    final result =
        await AuthService.updateProfile(name: nickname, description: bio);

    if (!mounted) return;

    setState(() => _isSaving = false);

    if (result.code == AuthResultCode.success) {
      setState(() {
        _saveMessage = '修改已保存';
        _saveSuccess = true;
        _user = result.user;
        _tempAvatarBytes = null;
        _tempAvatarFileName = null;
      });

      await UserCacheService.updateName(result.user?.name ?? nickname);
      await UserCacheService.updateBio(result.user?.bio ?? bio);

      await Future.delayed(const Duration(milliseconds: 1500));

      if (!mounted) return;

      await _loadUserData();
    } else {
      await _loadUserData();

      setState(() {
        _saveMessage = result.message ?? '修改失败，请稍后重试';
        _saveSuccess = false;
      });
    }
  }

  Future<void> _checkForUpdate() async {
    final result = await UpdateService.instance.checkForUpdate(silent: false);
    if (!mounted) return;

    if (result.result == UpdateResult.updateAvailable &&
        result.versionInfo != null) {
      UpdateDialog.show(
        context,
        currentVersion: result.localVersion ?? '0.0.0',
        newVersion: result.versionInfo!.latestVersion,
        updateLog: result.versionInfo!.updateLog,
        downloadUrl: result.versionInfo!.downloadUrl,
      );
    } else if (result.result == UpdateResult.alreadyLatest ||
        result.result == UpdateResult.skipped) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('当前已是最新版本'), duration: Duration(seconds: 2)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('检查更新失败：${result.userFriendlyError}'),
            duration: Duration(seconds: 3)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 700,
          height: 500,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSidebar(),
                    _buildContentArea(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      height: 70,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset('assets/images/settings_header_icon.svg',
                  width: 24, height: 24),
              const SizedBox(width: 12),
              Text(
                '设置 / Settings',
                style: TextStyle(
                  fontFamily: 'ZhiMangXing',
                  fontSize: 30,
                  height: 36 / 30,
                  letterSpacing: 2.0,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _closeHovered = true),
            onExit: (_) => setState(() => _closeHovered = false),
            child: GestureDetector(
              onTap: widget.onClose,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _closeHovered
                      ? AppColors.primaryText.withOpacity(0.1)
                      : AppColors.background,
                  border: Border.all(
                    color: _closeHovered
                        ? AppColors.border
                        : AppColors.border.withOpacity(0.5),
                    width: _closeHovered ? 2 : 1.6,
                  ),
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border,
                      offset: _closeHovered
                          ? const Offset(1, 2)
                          : const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: _closeHovered
                      ? AppColors.primaryText
                      : AppColors.secondaryText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 192,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          right: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 33),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTabButton(
            label: '个人资料',
            iconPath: 'assets/images/tab_profile_icon.svg',
            tab: SettingsTab.profile,
          ),
          const SizedBox(height: 9),
          _buildTabButton(
            label: '偏好设置',
            iconPath: 'assets/images/tab_preference_icon.svg',
            tab: SettingsTab.preference,
          ),
          const SizedBox(height: 8),
          _buildTabButton(
            label: '关于应用',
            iconPath: 'assets/images/tab_about_icon.svg',
            tab: SettingsTab.about,
          ),
          const Spacer(),
          InteractiveWrapper(
            onTap: widget.onBack ?? widget.onClose,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.background,
              ),
              alignment: Alignment.center,
              child: SvgPicture.asset(
                'assets/images/back_arrow_icon.svg',
                width: 18,
                height: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required String label,
    required String iconPath,
    required SettingsTab tab,
  }) {
    final isSelected = _currentTab == tab;
    return InteractiveWrapper(
      onTap: () => setState(() => _currentTab = tab),
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Container(
        width: 158,
        height: 51,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.buttonBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.border : Colors.transparent,
            width: 1.6,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.border,
                    offset: const Offset(2, 2),
                    blurRadius: 0,
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 49, 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(iconPath, width: 18, height: 18),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                height: 24 / 16,
                color: isSelected
                    ? AppColors.primaryText
                    : AppColors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentArea() {
    return Expanded(
      child: Container(
        color: AppColors.background,
        padding: const EdgeInsets.fromLTRB(24, 24, 39, 24),
        child: () {
          switch (_currentTab) {
            case SettingsTab.profile:
              return _buildProfileContent();
            case SettingsTab.preference:
              return _buildPreferenceContent();
            case SettingsTab.about:
              return _buildAboutContent();
          }
        }(),
      ),
    );
  }

  Widget _buildProfileContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(bottom: 9),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.borderLight,
                  width: 1.6,
                ),
              ),
            ),
            child: Row(
              children: [
                SvgPicture.asset('assets/images/edit_pencil_icon.svg',
                    width: 20, height: 20),
                const SizedBox(width: 8),
                Text(
                  ' 修改资料',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    height: 28 / 20,
                    color: AppColors.border,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildAvatarRow(),
          const SizedBox(height: 24),
          _buildFieldRow(label: '昵称', child: _buildTextInput()),
          const SizedBox(height: 24),
          _buildFieldRow(label: '个人简介', child: _buildTextArea()),
          if (_saveMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _saveSuccess ? AppColors.successBg : AppColors.errorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _saveSuccess
                      ? AppColors.successGreen
                      : AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _saveSuccess
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: _saveSuccess
                        ? AppColors.successGreen
                        : AppColors.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _saveMessage!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: _saveSuccess
                            ? AppColors.successGreen
                            : AppColors.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          _buildSaveButton(),
        ],
      ),
    );
  }

  Widget _buildAvatarRow() {
    return Row(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: const Color(0xFFF0E6D2),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF8B7355), width: 1.6),
            boxShadow: const [
              BoxShadow(
                color: Color(0xFF8B7355),
                offset: Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.all(5.5),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFBF6EF),
              border: Border.all(color: const Color(0xFF8B7355), width: 1),
            ),
            padding: const EdgeInsets.all(1),
            child: ClipOval(
              child: (_tempAvatarBytes != null)
                  ? Image.memory(
                      _tempAvatarBytes!,
                      width: 83,
                      height: 83,
                      fit: BoxFit.cover,
                    )
                  : UserCacheService.buildUserAvatar(
                      size: 83,
                      defaultAvatar: _buildDefaultAvatar(),
                      avatarUrl: _avatarUrl,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 24),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InteractiveWrapper(
              onTap: _isUploadingAvatar ? null : _handleAvatarUpload,
              cursor: _isUploadingAvatar
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  border: Border.all(
                      color: Colors.black.withOpacity(0.1), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border,
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(16, 7, 16, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isUploadingAvatar)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(AppColors.border),
                        ),
                      )
                    else
                      Text(
                        '上传新头像',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          height: 20 / 14,
                          color: AppColors.border,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '支持 JPG, PNG 格式，最大 2MB。',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 12,
                height: 16 / 12,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFieldRow({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w700,
            fontSize: 14,
            height: 20 / 14,
            color: AppColors.secondaryText,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildTextInput() {
    return Container(
      width: 442,
      height: 47,
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
      child: TextField(
        controller: _nicknameController,
        focusNode: _nicknameFocusNode,
        style: TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w500,
          fontSize: 16,
          height: 24 / 16,
          color: AppColors.primaryText,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          isDense: true,
          hintText: '输入昵称',
          hintStyle: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w400,
            fontSize: 16,
            color: AppColors.inputHint,
          ),
        ),
      ),
    );
  }

  Widget _buildTextArea() {
    return Container(
      width: 442,
      height: 99,
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
      child: TextField(
        controller: _bioController,
        focusNode: _bioFocusNode,
        maxLines: null,
        style: TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w500,
          fontSize: 14,
          height: 20 / 14,
          color: AppColors.primaryText,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          isDense: true,
          hintText: '写点什么介绍自己吧~',
          hintStyle: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w400,
            fontSize: 14,
            color: AppColors.inputHint,
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return Center(
      child: InteractiveWrapper(
        onTap: _isSaving ? null : _handleSave,
        cursor: _isSaving ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          constraints: const BoxConstraints(minWidth: 160),
          height: 55,
          decoration: BoxDecoration(
            color: _isSaving ? AppColors.selectedBlue : AppColors.selectedBlue,
            border:
                Border.all(color: Colors.black.withOpacity(0.1), width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryText,
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 29),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSaving)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.primaryText),
                  ),
                )
              else ...[
                SvgPicture.asset('assets/images/save_icon.svg',
                    width: 18, height: 18),
                const SizedBox(width: 8),
                Text(
                  ' 保存修改',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    height: 28 / 18,
                    color: AppColors.primaryText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreferenceContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(bottom: 9),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.borderLight,
                  width: 1.6,
                ),
              ),
            ),
            child: Row(
              children: [
                SvgPicture.asset('assets/images/tab_preference_icon.svg',
                    width: 20, height: 20),
                const SizedBox(width: 8),
                Text(
                  ' 外观与通知',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    height: 28 / 20,
                    color: AppColors.border,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildThemeDesignerCard(),
          const SizedBox(height: 20),
          _buildInstallPathCard(),
          const SizedBox(height: 20),
          _buildProxyCard(),
        ],
      ),
    );
  }

  Widget _buildNotificationCard() {
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
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '接收系统通知',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    height: 24 / 16,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '开启后会收到新游戏推荐或评论提醒。',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    height: 20 / 14,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 44,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.selectedBlue,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(22, 2, 2, 2),
            alignment: Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: const Color(0xFFFFFFFF), width: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _defaultInstallPath;
  bool _isSavingPath = false;
  String? _pathSaveMessage;
  bool _pathSaveSuccess = false;

  late final TextEditingController _proxyController;
  String? _proxySaveMessage;
  bool _proxySaveSuccess = false;

  Future<void> _loadDefaultInstallPath() async {
    final path = await InstallPathPreference.instance.getDefaultGameLocation();
    if (mounted) {
      setState(() {
        _defaultInstallPath = path;
      });
    }
  }

  Future<void> _loadProxySettings() async {
    final proxy = MetadataFetcher.currentProxy;
    if (mounted) {
      _proxyController.text = proxy ?? '';
    }
  }

  Widget _buildInstallPathCard() {
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '默认游戏安装路径',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 24 / 16,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '设置后，从探索页安装的游戏将默认存放到此位置。游戏本体与元数据分离存储。',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.4),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: AppColors.border),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _defaultInstallPath ?? LocalGameRegistry.gamesBaseDir,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      height: 20 / 14,
                      color: _defaultInstallPath != null
                          ? AppColors.primaryText
                          : AppColors.secondaryText.withOpacity(0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_pathSaveMessage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:
                    _pathSaveSuccess ? AppColors.successBg : AppColors.errorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _pathSaveSuccess
                      ? AppColors.successGreen
                      : AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _pathSaveSuccess
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: _pathSaveSuccess
                        ? AppColors.successGreen
                        : AppColors.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _pathSaveMessage!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: _pathSaveSuccess
                            ? AppColors.successGreen
                            : AppColors.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              InteractiveWrapper(
                onTap: _isSavingPath ? null : _handleBrowseInstallPath,
                cursor: _isSavingPath
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    border: Border.all(
                        color: Colors.black.withOpacity(0.1), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 9, 18, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isSavingPath)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(AppColors.border),
                          ),
                        )
                      else ...[
                        Icon(Icons.folder_open,
                            size: 16, color: AppColors.border),
                        const SizedBox(width: 6),
                        Text(
                          '浏览...',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            height: 20 / 14,
                            color: AppColors.border,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (_defaultInstallPath != null)
                InteractiveWrapper(
                  onTap: _handleClearInstallPath,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border: Border.all(color: AppColors.border, width: 1.4),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Text(
                      '清除设置',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleBrowseInstallPath() async {
    try {
      setState(() {
        _isSavingPath = true;
        _pathSaveMessage = null;
      });

      final result = await InstallPathPreference.instance.pickDirectory();

      if (result != null && result.isNotEmpty) {
        final success =
            await InstallPathPreference.instance.setDefaultGameLocation(result);

        if (!mounted) return;

        setState(() {
          _isSavingPath = false;
          if (success) {
            _defaultInstallPath = result;
            _pathSaveMessage = '已保存默认安装路径';
            _pathSaveSuccess = true;
          } else {
            _pathSaveMessage = '保存失败，请重试';
            _pathSaveSuccess = false;
          }
        });

        await Future.delayed(const Duration(milliseconds: 2000));
        if (mounted) {
          setState(() {
            _pathSaveMessage = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isSavingPath = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSavingPath = false;
          _pathSaveMessage = '选择目录失败: $e';
          _pathSaveSuccess = false;
        });
      }
    }
  }

  Future<void> _handleClearInstallPath() async {
    final success =
        await InstallPathPreference.instance.clearDefaultGameLocation();

    if (!mounted) return;

    setState(() {
      if (success) {
        _defaultInstallPath = null;
        _pathSaveMessage = '已清除默认安装路径设置';
        _pathSaveSuccess = true;
      } else {
        _pathSaveMessage = '清除失败，请重试';
        _pathSaveSuccess = false;
      }
    });

    await Future.delayed(const Duration(milliseconds: 2000));
    if (mounted) {
      setState(() {
        _pathSaveMessage = null;
      });
    }
  }

  Widget _buildProxyCard() {
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '网络代理设置',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 24 / 16,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '配置代理服务器以加速访问海外数据源（Steam、DLsite等）。格式示例：http://127.0.0.1:7890',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.4),
            ),
            child: TextField(
              controller: _proxyController,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 14,
                height: 20 / 14,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: 'http://127.0.0.1:7890',
                hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w400,
                  fontSize: 14,
                  color: AppColors.inputHint,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_proxySaveMessage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:
                    _proxySaveSuccess ? AppColors.successBg : AppColors.errorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _proxySaveSuccess
                      ? AppColors.successGreen
                      : AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _proxySaveSuccess
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: _proxySaveSuccess
                        ? AppColors.successGreen
                        : AppColors.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _proxySaveMessage!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: _proxySaveSuccess
                            ? AppColors.successGreen
                            : AppColors.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              InteractiveWrapper(
                onTap: _handleSaveProxy,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    border: Border.all(
                        color: Colors.black.withOpacity(0.1), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 9, 18, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.save, size: 16, color: AppColors.border),
                      const SizedBox(width: 6),
                      Text(
                        '保存',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          height: 20 / 14,
                          color: AppColors.border,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              InteractiveWrapper(
                onTap: _handleClearProxy,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(color: AppColors.border, width: 1.4),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Text(
                    '清除',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleSaveProxy() async {
    final proxyUrl = _proxyController.text.trim();

    try {
      await MetadataFetcher.updateProxy(proxyUrl.isEmpty ? null : proxyUrl);

      if (mounted) {
        setState(() {
          _proxySaveMessage =
              proxyUrl.isNotEmpty ? '代理已保存：$proxyUrl' : '已清除代理设置';
          _proxySaveSuccess = true;
        });
      }

      await Future.delayed(const Duration(milliseconds: 2000));
      if (mounted) {
        setState(() {
          _proxySaveMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _proxySaveMessage = '保存失败: $e';
          _proxySaveSuccess = false;
        });
      }
    }
  }

  Future<void> _handleClearProxy() async {
    _proxyController.clear();
    await _handleSaveProxy();
  }

  Widget _buildAboutContent() {
    return Container(
      width: double.infinity,
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.6),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border,
                    offset: const Offset(2, 3),
                    blurRadius: 0,
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'CT',
                    style: TextStyle(
                      fontFamily: 'ZhiMangXing',
                      fontSize: 36,
                      height: 40 / 36,
                      letterSpacing: 2.0,
                      color: AppColors.border,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Chrono Tide',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'ZhiMangXing',
                  fontSize: 30,
                  height: 36 / 30,
                  letterSpacing: 2.0,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Version $_appVersion (Galgame Style)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  height: 24 / 16,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 384,
            child: Text(
              '一个专为纯爱废萌和剧情向Galgame打造的本地管理与分享平台。用最温馨的设计，记录每一个心动瞬间。(´,,•ω•,,)♡',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w400,
                fontSize: 14,
                height: 20 / 14,
                color: AppColors.primaryText,
              ),
            ),
          ),
          const SizedBox(height: 32),
          if (BackendConfig.isBackendAvailable)
            Center(
              child: InteractiveWrapper(
                onTap: () => _checkForUpdate(),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 160),
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.selectedBlue,
                    border: Border.all(
                        color: Colors.black.withOpacity(0.1), width: 1.6),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryText,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.system_update,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '检查更新',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildThemeDesignerCard() {
    final currentTheme = AppThemeManager.instance.currentTheme;
    final standardThemes = AppThemeManager.standardThemes;
    final featuredThemes = AppThemeManager.featuredThemes;
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
          InteractiveWrapper(
            onTap: () => setState(
                () => _themeDesignerExpanded = !_themeDesignerExpanded),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.palette_outlined,
                      size: 20, color: AppColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '主题设计器',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 24 / 16,
                            color: AppColors.primaryText,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '自定义应用外观，含 ${featuredThemes.length} 款特色背景主题',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                            height: 18 / 13,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    turns: _themeDesignerExpanded ? 0.5 : 0,
                    child: Icon(Icons.expand_more,
                        size: 20, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: _themeDesignerExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 1.6,
                    color: AppColors.borderLight,
                    margin: const EdgeInsets.only(bottom: 14),
                  ),
                  Row(
                    children: [
                      Icon(Icons.tune,
                          size: 15, color: AppColors.secondaryText),
                      const SizedBox(width: 6),
                      Text(
                        '经典配色',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 18 / 13,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: standardThemes.map((theme) {
                      final data = AppThemeManager.themeData(theme);
                      final isSelected = currentTheme == theme;
                      return InteractiveWrapper(
                        onTap: () => AppThemeManager.instance.setTheme(theme),
                        hoverScale: 1.04,
                        child: Container(
                          width: 100,
                          height: 58,
                          decoration: BoxDecoration(
                            color: data.background,
                            border: Border.all(
                              color:
                                  isSelected ? data.border : data.borderLight,
                              width: isSelected ? 2.0 : 1.0,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: data.border,
                                      offset: const Offset(2, 2),
                                      blurRadius: 0,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                data.emoji,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                data.name,
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 12,
                                  height: 16 / 12,
                                  color: data.primaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  Container(
                    height: 1.6,
                    color: AppColors.borderLight,
                    margin: const EdgeInsets.only(top: 12, bottom: 14),
                  ),
                  if (featuredThemes.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.auto_awesome,
                            size: 15, color: AppColors.selectedBlue),
                        const SizedBox(width: 6),
                        Text(
                          '特色主题',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            height: 18 / 13,
                            color: AppColors.selectedBlue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...featuredThemes.map((theme) {
                      final data = AppThemeManager.themeData(theme);
                      final isSelected = currentTheme == theme;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InteractiveWrapper(
                          onTap: () => AppThemeManager.instance.setTheme(theme),
                          hoverScale: 1.01,
                          child: Container(
                            width: double.infinity,
                            height: 78,
                            decoration: BoxDecoration(
                              color: data.background,
                              border: Border.all(
                                color: isSelected
                                    ? data.selectedBlue
                                    : data.borderLight,
                                width: isSelected ? 2.2 : 1.2,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: data.shadowColor,
                                        offset: const Offset(2, 2),
                                        blurRadius: 0,
                                      ),
                                    ]
                                  : null,
                            ),
                            clipBehavior: Clip.hardEdge,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (data.hasBackgroundImage)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity: 0.35,
                                      child: Image.asset(
                                        data.backgroundImagePath!,
                                        fit: BoxFit.cover,
                                        alignment: Alignment.center,
                                      ),
                                    ),
                                  ),
                                if (data.hasBackgroundImage)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.centerLeft,
                                          end: Alignment.centerRight,
                                          colors: [
                                            data.background.withOpacity(0.75),
                                            data.background.withOpacity(0.45),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  left: 14,
                                  top: 0,
                                  bottom: 0,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            data.emoji,
                                            style:
                                                const TextStyle(fontSize: 20),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            data.name,
                                            style: TextStyle(
                                              fontFamily: 'Inter',
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16,
                                              height: 22 / 16,
                                              color: data.primaryText,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        data.description ?? '',
                                        style: TextStyle(
                                          fontFamily: 'Inter',
                                          fontWeight: FontWeight.w500,
                                          fontSize: 11,
                                          height: 15 / 11,
                                          color: data.secondaryText,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isSelected)
                                  Positioned(
                                    right: 12,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: Icon(Icons.check_circle,
                                          size: 22, color: data.selectedBlue),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    height: 1.6,
                    color: AppColors.borderLight,
                    margin: const EdgeInsets.only(bottom: 14),
                  ),
                  Row(
                    children: [
                      Icon(Icons.image_outlined,
                          size: 15, color: AppColors.placeholderText),
                      const SizedBox(width: 6),
                      Text(
                        '自定义背景',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 18 / 13,
                          color: AppColors.placeholderText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  InteractiveWrapper(
                    onTap: null,
                    child: Container(
                      width: double.infinity,
                      height: 56,
                      decoration: BoxDecoration(
                        color: AppColors.placeholderBg,
                        border: Border.all(
                            color: AppColors.borderLight, width: 1.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_upload_outlined,
                              size: 18, color: AppColors.placeholderText),
                          const SizedBox(width: 8),
                          Text(
                            '上传图片或 GIF 作为应用背景（即将推出）',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w500,
                              fontSize: 12,
                              color: AppColors.placeholderText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 32,
        height: 32,
        colorFilter: ColorFilter.mode(AppColors.secondaryText, BlendMode.srcIn),
      ),
    );
  }

  Future<void> _handleAvatarUpload() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null || file.bytes!.isEmpty) return;

      final ext = file.path?.split('.').last.toLowerCase() ?? '';
      if (!['jpg', 'jpeg', 'png'].contains(ext)) {
        if (!mounted) return;
        setState(() {
          _saveMessage = '头像文件过大/格式不支持，请选择≤2MB的JPG/PNG图片';
          _saveSuccess = false;
        });
        return;
      }

      if (file.size != null && file.size! > 2 * 1024 * 1024) {
        if (!mounted) return;
        setState(() {
          _saveMessage = '头像文件过大/格式不支持，请选择≤2MB的JPG/PNG图片';
          _saveSuccess = false;
        });
        return;
      }

      if (!mounted) return;

      // 1. 转Base64
      final base64Str = base64Encode(file.bytes!);

      // 2. 写入缓存（必须await）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_avatar_base64', base64Str);

      // 3. 刷新UI显示新头像
      setState(() {
        _tempAvatarBytes = file.bytes!;
        _tempAvatarFileName = file.name;
        _avatarUrl = null;
        _saveMessage = null;
      });

      // 4. 异步上传到服务器（后台操作，不等待结果）
      _uploadAvatarToServer(file.name, file.bytes!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveMessage = '选择文件失败，请重试';
        _saveSuccess = false;
      });
    }
  }

  Future<void> _uploadAvatarToServer(String fileName, List<int> bytes) async {
    try {
      debugPrint('[UPLOAD] 正在异步上传头像到服务器...');

      final result = await AuthService.uploadAvatar(
        fileName: fileName,
        bytes: bytes,
      );

      if (result.code == AuthResultCode.success) {
      } else {}
    } catch (e) {}
  }
}
