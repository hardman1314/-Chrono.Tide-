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
import '../theme/background_image_config.dart';
import '../theme/theme_storage.dart';
import '../theme/ct_theme_package.dart';
import 'interactive_wrapper.dart';
import 'app_snack_bar.dart';
import 'theme_editor_dialog.dart';
import 'my_themes_section.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import '../core/path_helper.dart';
import '../services/install_path_preference.dart';
import '../services/metadata_fetcher.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart'; // ★ v3 阶段 2: 统计重建
import '../services/magpie_service.dart';
import '../services/autostart_service.dart';
import '../services/storage/storage_cleanup_service.dart';

enum SettingsTab { profile, preference, about }

class SettingsModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback? onBack;
  final VoidCallback? onAvatarChanged;
  const SettingsModal(
      {super.key, required this.onClose, this.onBack, this.onAvatarChanged});

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
  bool _magpieExpanded = false;
  bool _magpieExternalPathHovered = false;
  String? _magpieStatusMessage;
  bool _magpieStatusSuccess = false;
  bool _autoStartEnabled = false;
  // ===== ★ v3 阶段 2：统计重建状态 =====
  bool _isRebuildingStats = false;
  String? _rebuildStatsMessage;
  bool _rebuildStatsSuccess = false;
  // ===== 存储管理状态 =====
  List<CacheUnitInfo> _cacheUnits = const [];
  int _cacheTotalBytes = 0;
  int _downloadArchivesSize = 0;
  bool _isCacheLoading = false;
  bool _isCleaningCache = false;
  String? _cacheCleanupMessage;
  bool _cacheCleanupSuccess = false;

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
    _loadAutoStartStatus();
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

    // UX-31: 移除冗余的 nickname.length < 1 条件（前面 isEmpty 已拦截空字符串）
    if (nickname.length > 20) {
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
            color: AppColors.placeholderCover,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.border, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.all(5.5),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sidebarBackground,
              border: Border.all(color: AppColors.border, width: 1),
            ),
            alignment: Alignment.center,
            child: ClipOval(
              child: SizedBox(
                width: 83,
                height: 83,
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
                  border: Border.all(color: AppColors.borderLight, width: 2),
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
            color: _isSaving
                ? AppColors.selectedAccent.withOpacity(0.6)
                : AppColors.selectedAccent,
            border: Border.all(color: AppColors.borderLight, width: 1.6),
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
          _buildAutoStartCard(),
          const SizedBox(height: 20),
          _buildInstallPathCard(),
          const SizedBox(height: 20),
          _buildProxyCard(),
          const SizedBox(height: 20),
          _buildMagpieCard(),
          const SizedBox(height: 20),
          _buildStorageManagementCard(),
          const SizedBox(height: 20),
          _buildPlaytimeTrackingCard(),
        ],
      ),
    );
  }

  // ========== 时长统计模式卡片 ==========
  // ★ v2: 切换"精准模式"（仅前台时计时）与"宽松模式"（启动到退出全程计时）
  // 借鉴 ReinaManager 的 TimeTrackingMode 设计
  Widget _buildPlaytimeTrackingCard() {
    final mode = LocalGameRegistry.instance.globalTrackingMode;
    final isPlaytime = mode == TimeTrackingMode.playtime;

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
            '游玩时长统计模式',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 24 / 16,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '精准模式：仅游戏窗口在前台时才计时（推荐）\n'
            '宽松模式：从启动到退出的墙钟时长',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              height: 18 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: InteractiveWrapper(
                  onTap: () async {
                    if (isPlaytime) return;
                    await LocalGameRegistry.instance
                        .setTrackingMode(TimeTrackingMode.playtime);
                    if (mounted) setState(() {});
                    AppSnackBar.success(context, '已切换到精准模式');
                  },
                  hoverScale: 1.0,
                  hoverOffset: const Offset(0, -1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: isPlaytime
                          ? AppColors.buttonBackground
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isPlaytime
                            ? AppColors.border
                            : AppColors.borderLight,
                        width: 1.4,
                      ),
                    ),
                    child: Text(
                      '精准模式（推荐）',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InteractiveWrapper(
                  onTap: () async {
                    if (!isPlaytime) return;
                    await LocalGameRegistry.instance
                        .setTrackingMode(TimeTrackingMode.elapsed);
                    if (mounted) setState(() {});
                    AppSnackBar.success(context, '已切换到宽松模式');
                  },
                  hoverScale: 1.0,
                  hoverOffset: const Offset(0, -1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: !isPlaytime
                          ? AppColors.buttonBackground
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: !isPlaytime
                            ? AppColors.border
                            : AppColors.borderLight,
                        width: 1.4,
                      ),
                    ),
                    child: Text(
                      '宽松模式',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // ★ v3 阶段 2：统计重建（自愈）区域
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.borderLight, width: 1.0),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.healing,
                        size: 16, color: AppColors.secondaryText),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '统计重建（自愈）',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppColors.primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '当游玩时长统计不准确时，可从会话历史记录全量重算。\n'
                  '会话记录是事实表，统计是其投影，损坏时可由此重建。',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    height: 16 / 11,
                    color: AppColors.secondaryText,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    InteractiveWrapper(
                      onTap: _isRebuildingStats
                          ? null
                          : () => _rebuildStatisticsForAllGames(),
                      hoverScale: 1.0,
                      hoverOffset: const Offset(0, -1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 14),
                        decoration: BoxDecoration(
                          color: _isRebuildingStats
                              ? AppColors.borderLight
                              : AppColors.buttonBackground,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: AppColors.border,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isRebuildingStats)
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryText),
                                ),
                              )
                            else
                              Icon(Icons.refresh,
                                  size: 14, color: AppColors.primaryText),
                            const SizedBox(width: 6),
                            Text(
                              _isRebuildingStats ? '重建中...' : '重建所有游戏统计',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: AppColors.primaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_rebuildStatsMessage != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _rebuildStatsMessage!,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: _rebuildStatsSuccess
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFE57373),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ★ v3 阶段 2：重建所有游戏的统计数据（自愈）
  /// 遍历所有游戏，调用 rebuildPlayTimeFromSessions 从会话事实表全量重算
  Future<void> _rebuildStatisticsForAllGames() async {
    setState(() {
      _isRebuildingStats = true;
      _rebuildStatsMessage = null;
    });

    try {
      final games = LocalGameRegistry.instance.allGames;
      int successCount = 0;
      int totalSessions = 0;

      for (final game in games) {
        if (game.metaDataDir.isEmpty) continue;
        final result =
            await GameDataFormat.rebuildPlayTimeFromSessions(game.metaDataDir);
        if (result != null) {
          successCount++;
          totalSessions += result.sessionCount;
          // 同步内存中的 playTime
          game.playTime = result.totalPlayTime;
        }
      }

      // 通知 UI 刷新
      await LocalGameRegistry.instance.scan();

      if (mounted) {
        setState(() {
          _isRebuildingStats = false;
          _rebuildStatsSuccess = true;
          _rebuildStatsMessage =
              '已重建 $successCount/${games.length} 个游戏 | 共 $totalSessions 条会话';
        });
      }

      // 3 秒后清除消息
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        setState(() {
          _rebuildStatsMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRebuildingStats = false;
          _rebuildStatsSuccess = false;
          _rebuildStatsMessage = '重建失败: $e';
        });
      }
    }
  }

  void _loadAutoStartStatus() async {
    final enabled = await AutoStartService.instance.isEnabled();
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Widget _buildAutoStartCard() {
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _autoStartEnabled
                  ? const Color(0xFF4CAF50).withOpacity(0.1)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.power_settings_new_rounded,
              size: 22,
              color: _autoStartEnabled
                  ? const Color(0xFF4CAF50)
                  : AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '开机自启动',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    height: 24 / 16,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _autoStartEnabled
                      ? '已开启 · 开机后自动静默运行于系统托盘'
                      : '开启后，开机自动运行于系统托盘，随时快速启动游戏',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    height: 18 / 13,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _autoStartEnabled,
            activeColor: const Color(0xFF4CAF50),
            onChanged: (value) async {
              bool success;
              if (value) {
                success = await AutoStartService.instance.enable();
              } else {
                success = await AutoStartService.instance.disable();
              }
              if (success && mounted) {
                setState(() => _autoStartEnabled = value);
              }
            },
          ),
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
              color: AppColors.selectedAccent,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(22, 2, 2, 2),
            alignment: Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.background,
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
                    border: Border.all(color: AppColors.borderLight, width: 2),
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
                    border: Border.all(color: AppColors.borderLight, width: 2),
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

  // ========== Magpie 超分增强配置卡片 ==========
  Widget _buildMagpieCard() {
    return ListenableBuilder(
      listenable: MagpieService.instance,
      builder: (context, _) {
        final magpie = MagpieService.instance;

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
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _magpieExpanded = !_magpieExpanded),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_fix_high_rounded,
                          size: 20,
                          color: AppColors.selectedAccent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '超分增强 (Magpie)',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 24 / 16,
                            color: AppColors.primaryText,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '为游戏提供分辨率增强功能',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                        AnimatedRotation(
                          duration: const Duration(milliseconds: 200),
                          turns: _magpieExpanded ? 0.5 : 0,
                          child: Icon(
                            Icons.expand_more,
                            size: 20,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 展开内容
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildMagpieExpandedContent(),
                crossFadeState: _magpieExpanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 250),
                sizeCurve: Curves.easeInOut,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMagpieExpandedContent() {
    return ListenableBuilder(
      listenable: MagpieService.instance,
      builder: (context, _) {
        final magpie = MagpieService.instance;
        final isExternal = magpie.mode == MagpieMode.external;

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.borderLight, width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),

              // 数据来源选择
              Text(
                '数据来源',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildMagpieRadio(
                    label: '使用内置版本',
                    selected: !isExternal,
                    onTap: () => magpie.setMode(MagpieMode.internal),
                  ),
                  const SizedBox(width: 20),
                  _buildMagpieRadio(
                    label: '外接本地 Magpie',
                    selected: isExternal,
                    onTap: () => magpie.setMode(MagpieMode.external),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 外接设置面板
              if (isExternal) ...[
                _buildMagpieExternalPanel(),
                const SizedBox(height: 16),
              ],

              // 内接设置面板
              if (!isExternal) ...[
                _buildMagpieInternalPanel(),
                const SizedBox(height: 16),
              ],

              // 高级选项
              Text(
                '高级选项',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 10),
              _buildMagpieCheckbox(
                label: '游戏退出后自动关闭 Magpie',
                value: magpie.autoClose,
                onChanged: (v) => magpie.setAutoClose(v),
              ),
              const SizedBox(height: 6),
              _buildMagpieCheckbox(
                label: '启动失败时回退到普通启动',
                value: magpie.fallbackOnFail,
                onChanged: (v) => magpie.setFallbackOnFail(v),
              ),

              // 状态消息
              if (_magpieStatusMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _magpieStatusSuccess
                        ? AppColors.successBg
                        : AppColors.errorBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _magpieStatusSuccess
                          ? AppColors.successGreen
                          : AppColors.dangerRed,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _magpieStatusSuccess
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 16,
                        color: _magpieStatusSuccess
                            ? AppColors.successGreen
                            : AppColors.dangerRed,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _magpieStatusMessage!,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                            color: _magpieStatusSuccess
                                ? AppColors.successGreen
                                : AppColors.dangerRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMagpieRadio({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? AppColors.selectedAccent
                      : AppColors.secondaryText.withOpacity(0.4),
                  width: 2,
                ),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.selectedAccent,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color:
                    selected ? AppColors.primaryText : AppColors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMagpieCheckbox({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: value
                      ? AppColors.selectedAccent
                      : AppColors.secondaryText.withOpacity(0.4),
                  width: 2,
                ),
                color: value ? AppColors.selectedAccent : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: value
                  ? Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: AppColors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMagpieExternalPanel() {
    final magpie = MagpieService.instance;
    final path = magpie.externalPath;
    final pathValid = path.isNotEmpty && File(path).existsSync();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Magpie 路径',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          MouseRegion(
            onEnter: (_) => setState(() => _magpieExternalPathHovered = true),
            onExit: (_) => setState(() => _magpieExternalPathHovered = false),
            child: GestureDetector(
              onTap: _handleBrowseMagpiePath,
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  border: Border.all(
                    color: _magpieExternalPathHovered
                        ? AppColors.selectedAccent
                        : AppColors.border,
                    width: 1.4,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: pathValid
                          ? AppColors.selectedAccent
                          : AppColors.secondaryText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        path.isNotEmpty ? path : '选择 Magpie.exe 所在路径...',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          color: path.isNotEmpty
                              ? AppColors.primaryText
                              : AppColors.inputHint,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.folder_open,
                      size: 16,
                      color: AppColors.secondaryText,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                pathValid
                    ? Icons.check_circle_outline
                    : (path.isEmpty ? Icons.info_outline : Icons.error_outline),
                size: 14,
                color: pathValid
                    ? AppColors.successGreen
                    : (path.isEmpty
                        ? AppColors.secondaryText
                        : AppColors.dangerRed),
              ),
              const SizedBox(width: 4),
              Text(
                pathValid
                    ? '已检测到 Magpie'
                    : (path.isEmpty ? '未设置路径' : '路径无效，请重新选择'),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                  color: pathValid
                      ? AppColors.successGreen
                      : (path.isEmpty
                          ? AppColors.secondaryText
                          : AppColors.dangerRed),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildMagpieCheckbox(
            label: '尊重用户自定义配置（不修改已有设置）',
            value: true,
            onChanged: (_) {}, // 外接模式默认尊重用户配置
          ),
        ],
      ),
    );
  }

  Widget _buildMagpieInternalPanel() {
    final magpie = MagpieService.instance;
    final presets = MagpieService.builtInPresets;
    final customTemplates = magpie.allPresets
        .where((p) => !MagpieService.builtInPresets.contains(p))
        .toList();
    final selectedPreset = magpie.defaultPreset;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 默认效果预设
          Text(
            '默认效果预设',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: presets.map((preset) {
              final isSelected = preset.name == selectedPreset;
              return _buildPresetChip(
                preset: preset,
                isSelected: isSelected,
                onTap: () => magpie.setDefaultPreset(preset.name),
              );
            }).toList(),
          ),

          // 自定义模板区域
          if (customTemplates.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '已导入的模板',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: customTemplates.map((preset) {
                final isSelected = preset.name == selectedPreset;
                return _buildPresetChip(
                  preset: preset,
                  isSelected: isSelected,
                  onTap: () => magpie.setDefaultPreset(preset.name),
                  onRemove: () => magpie.removeCustomTemplate(preset.name),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 16),

          // 导入模板按钮
          Row(
            children: [
              InteractiveWrapper(
                onTap: _handleImportMagpieTemplate,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.buttonBackground,
                    border: Border.all(color: AppColors.borderLight, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.border,
                        offset: const Offset(2, 3),
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 7, 14, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.file_upload_outlined,
                          size: 14, color: AppColors.border),
                      const SizedBox(width: 6),
                      Text(
                        '导入模板',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.border,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '支持 Magpie ScalingModes JSON 格式',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w400,
                  fontSize: 12,
                  color: AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChip({
    required ScalingPreset preset,
    required bool isSelected,
    required VoidCallback onTap,
    VoidCallback? onRemove,
  }) {
    final isCustom = onRemove != null;

    return Tooltip(
      message: preset.description,
      preferBelow: true,
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        color: Colors.white,
      ),
      decoration: BoxDecoration(
        color: AppColors.primaryText,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.selectedAccent.withOpacity(0.1)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? AppColors.selectedAccent : AppColors.border,
                width: isSelected ? 1.6 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.check_circle,
                        size: 14, color: AppColors.selectedAccent),
                  ),
                Text(
                  preset.displayName,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 12,
                    color: isSelected
                        ? AppColors.selectedAccent
                        : AppColors.primaryText,
                  ),
                ),
                if (isCustom) ...[
                  const SizedBox(width: 4),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onRemove,
                      child: Icon(
                        Icons.close,
                        size: 12,
                        color: AppColors.secondaryText.withOpacity(0.6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleBrowseMagpiePath() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['exe'],
        dialogTitle: '选择 Magpie.exe',
      );

      if (result != null && result.files.single.path != null) {
        final selectedPath = result.files.single.path!;
        if (selectedPath.endsWith('Magpie.exe')) {
          await MagpieService.instance.setExternalPath(selectedPath);
          setState(() {
            _magpieStatusMessage = '路径已保存';
            _magpieStatusSuccess = true;
          });
          await Future.delayed(const Duration(milliseconds: 2000));
          if (mounted) setState(() => _magpieStatusMessage = null);
        } else {
          setState(() {
            _magpieStatusMessage = '请选择 Magpie.exe 文件';
            _magpieStatusSuccess = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        _magpieStatusMessage = '选择文件失败: $e';
        _magpieStatusSuccess = false;
      });
    }
  }

  Future<void> _handleImportMagpieTemplate() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: '导入 Magpie 超分模板',
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final success =
            await MagpieService.instance.importCustomTemplate(filePath);

        if (mounted) {
          setState(() {
            _magpieStatusMessage = success ? '模板导入成功' : '模板格式不正确或无有效效果';
            _magpieStatusSuccess = success;
          });
          await Future.delayed(const Duration(milliseconds: 2500));
          if (mounted) setState(() => _magpieStatusMessage = null);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _magpieStatusMessage = '导入失败: $e';
          _magpieStatusSuccess = false;
        });
      }
    }
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
          Center(
            child: InteractiveWrapper(
              onTap: () => _checkForUpdate(),
              child: Container(
                constraints: const BoxConstraints(minWidth: 160),
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.selectedAccent,
                  border: Border.all(color: AppColors.borderLight, width: 1.6),
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

  // ========== 存储管理卡片 ==========
  // 展示可再生缓存大小并提供一键清理。
  // 仅清理图片缓存、临时文件、元数据缓存等可再生数据，
  // 保留主题、背景图、游戏配置、偏好等用户数据。
  Widget _buildStorageManagementCard() {
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
          Row(
            children: [
              Icon(Icons.cleaning_services_outlined,
                  size: 20, color: AppColors.border),
              const SizedBox(width: 10),
              Text(
                '缓存管理',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  height: 24 / 16,
                  color: AppColors.primaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '所有缓存均存储在软件安装目录内，不占用系统 C 盘。清理仅删除可再生缓存（图片、临时文件、元数据），主题、背景图、游戏配置等用户数据不会被清除。',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 16),
          // 缓存大小展示区
          _buildCacheSizeDisplay(),
          const SizedBox(height: 12),
          if (_cacheCleanupMessage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _cacheCleanupSuccess
                    ? AppColors.successBg
                    : AppColors.errorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _cacheCleanupSuccess
                      ? AppColors.successGreen
                      : AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _cacheCleanupSuccess
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: _cacheCleanupSuccess
                        ? AppColors.successGreen
                        : AppColors.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _cacheCleanupMessage!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: _cacheCleanupSuccess
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
                onTap: _isCleaningCache ? null : _handleClearCache,
                child: Container(
                  decoration: BoxDecoration(
                    color: _isCleaningCache
                        ? AppColors.borderLight
                        : AppColors.buttonBackground,
                    border: Border.all(color: AppColors.borderLight, width: 2),
                    boxShadow: _isCleaningCache
                        ? null
                        : [
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
                      if (_isCleaningCache)
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
                        Icon(Icons.delete_sweep_outlined,
                            size: 16, color: AppColors.border),
                      const SizedBox(width: 6),
                      Text(
                        _isCleaningCache ? '清理中...' : '清理缓存',
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
                onTap:
                    _isCleaningCache || _isCacheLoading ? null : _loadCacheSize,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    border: Border.all(color: AppColors.border, width: 1.4),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh,
                          size: 14, color: AppColors.secondaryText),
                      const SizedBox(width: 6),
                      Text(
                        '刷新',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 缓存大小展示区：总大小 + 各单元明细。
  Widget _buildCacheSizeDisplay() {
    if (_isCacheLoading) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border, width: 1.4),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.secondaryText),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在计算缓存大小...',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      );
    }

    if (_cacheUnits.isEmpty) {
      // 首次进入尚未加载：显示提示+触发加载
      return InteractiveWrapper(
        onTap: _loadCacheSize,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.4),
          ),
          child: Row(
            children: [
              Icon(Icons.storage_outlined,
                  size: 16, color: AppColors.secondaryText),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '点击查看缓存占用情况',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: AppColors.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storage_outlined, size: 16, color: AppColors.border),
              const SizedBox(width: 8),
              Text(
                '当前缓存总占用：',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                StorageCleanupService.formatBytes(_cacheTotalBytes),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.selectedAccent,
                ),
              ),
              // 缓存超阈值警告徽章(>1GB 显示红色警告)
              if (_cacheTotalBytes > 1024 * 1024 * 1024) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.15),
                    border: Border.all(color: Colors.red.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 12, color: Colors.red.shade700),
                      const SizedBox(width: 4),
                      Text(
                        '超过 1GB',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // 各单元明细
          ..._cacheUnits.map((u) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: u.sizeBytes > 0
                            ? AppColors.border
                            : AppColors.borderLight,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      u.label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        color: AppColors.secondaryText,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      u.sizeBytes > 0
                          ? StorageCleanupService.formatBytes(u.sizeBytes)
                          : '空',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: u.sizeBytes > 0
                            ? AppColors.primaryText
                            : AppColors.secondaryText.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              )),
          // 下载残留压缩包单独清理入口(不纳入"清理缓存"按钮,需二次确认)
          if (_downloadArchivesSize > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.borderLight.withOpacity(0.3),
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Row(
                children: [
                  Icon(Icons.download_for_offline_outlined,
                      size: 14, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '下载残留压缩包 (${StorageCleanupService.formatBytes(_downloadArchivesSize)})',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                  InteractiveWrapper(
                    onTap: _handleClearDownloadArchives,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.selectedAccent.withOpacity(0.15),
                        border: Border.all(
                            color: AppColors.selectedAccent.withOpacity(0.4)),
                      ),
                      child: Text(
                        '清理',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                          color: AppColors.selectedAccent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 加载缓存大小（首次进入或点击刷新时调用）。
  Future<void> _loadCacheSize() async {
    setState(() {
      _isCacheLoading = true;
      _cacheCleanupMessage = null;
    });
    try {
      final units = await StorageCleanupService.instance.getCacheUnits();
      final total = units.fold(0, (a, u) => a + u.sizeBytes);
      // 提取下载残留大小(单独显示)
      final dlSize = units
          .firstWhere(
            (u) => u.id == StorageCleanupService.unitDownloadArchives,
            orElse: () => const CacheUnitInfo(
                id: '', label: '', sizeBytes: 0, regenerable: false),
          )
          .sizeBytes;
      if (!mounted) return;
      setState(() {
        _cacheUnits = units;
        _cacheTotalBytes = total;
        _downloadArchivesSize = dlSize;
        _isCacheLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCacheLoading = false;
        _cacheCleanupMessage = '获取缓存大小失败: $e';
        _cacheCleanupSuccess = false;
      });
    }
  }

  /// 执行缓存清理。
  Future<void> _handleClearCache() async {
    // 首次进入若未加载，先加载以获得清理前大小
    if (_cacheUnits.isEmpty) {
      await _loadCacheSize();
    }

    setState(() {
      _isCleaningCache = true;
      _cacheCleanupMessage = null;
    });
    try {
      final result = await StorageCleanupService.instance.clearAll();
      if (!mounted) return;

      final totalFreed = result.totalFreed;
      final allOk = result.allSuccess;

      // 清理后刷新大小
      final units = await StorageCleanupService.instance.getCacheUnits();
      final total = units.fold(0, (a, u) => a + u.sizeBytes);
      final dlSize = units
          .firstWhere(
            (u) => u.id == StorageCleanupService.unitDownloadArchives,
            orElse: () => const CacheUnitInfo(
                id: '', label: '', sizeBytes: 0, regenerable: false),
          )
          .sizeBytes;

      if (!mounted) return;
      setState(() {
        _isCleaningCache = false;
        _cacheUnits = units;
        _cacheTotalBytes = total;
        _downloadArchivesSize = dlSize;
        _cacheCleanupSuccess = allOk;
        _cacheCleanupMessage = allOk
            ? '清理完成，已释放 ${StorageCleanupService.formatBytes(totalFreed)}'
            : '部分清理失败，已释放 ${StorageCleanupService.formatBytes(totalFreed)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCleaningCache = false;
        _cacheCleanupMessage = '清理失败: $e';
        _cacheCleanupSuccess = false;
      });
    }
  }

  /// 单独清理下载残留压缩包(带二次确认)。
  Future<void> _handleClearDownloadArchives() async {
    // 二次确认
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清理下载残留'),
        content: Text(
          '将永久删除 downloads 目录下的所有压缩包 '
          '(${StorageCleanupService.formatBytes(_downloadArchivesSize)})。\n\n'
          '此操作不可撤销,请确认这些压缩包不再需要。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isCleaningCache = true;
      _cacheCleanupMessage = null;
    });
    try {
      final result =
          await StorageCleanupService.instance.clearDownloadArchives();
      if (!mounted) return;

      // 清理后刷新大小
      await _loadCacheSize();
      if (!mounted) return;
      setState(() {
        _isCleaningCache = false;
        _cacheCleanupSuccess = result.ok;
        _cacheCleanupMessage = result.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCleaningCache = false;
        _cacheCleanupMessage = '清理失败: $e';
        _cacheCleanupSuccess = false;
      });
    }
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
                            size: 15, color: AppColors.selectedAccent),
                        const SizedBox(width: 6),
                        Text(
                          '特色主题',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            height: 18 / 13,
                            color: AppColors.selectedAccent,
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
                                    ? data.selectedAccent
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
                                              fontWeight: FontWeight.w600,
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
                                          fontSize: 12,
                                          height: 15 / 12,
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
                                          size: 22, color: data.selectedAccent),
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
                  // v3.0 P3：主题设计器（调色板）入口
                  // 打开 WYSIWYG 调色设计器弹窗，支持 24 个可编辑元素
                  InteractiveWrapper(
                    onTap: () => ThemeEditorDialog.show(context),
                    child: Container(
                      width: double.infinity,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.selectedAccent.withOpacity(0.5),
                            AppColors.brandBlue.withOpacity(0.5),
                          ],
                        ),
                        border: Border.all(color: AppColors.border, width: 1.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.palette_outlined,
                              size: 18, color: AppColors.primaryText),
                          const SizedBox(width: 8),
                          Text(
                            '主题设计器 · 调色 / 背景 / 保存',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: AppColors.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // v3.0 P1：原占位按钮替换为可用入口
                  // 点击直接打开文件选择器，上传后立即应用为当前主题背景
                  // v3.0 P3 将进一步接入完整主题编辑器（含调色板）
                  InteractiveWrapper(
                    onTap: _onPickCustomBackground,
                    child: Container(
                      width: double.infinity,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.placeholderBg,
                        border: Border.all(
                            color: AppColors.borderLight, width: 1.0),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_upload_outlined,
                              size: 16, color: AppColors.primaryText),
                          const SizedBox(width: 8),
                          Text(
                            '快速上传背景图',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w500,
                              fontSize: 11,
                              color: AppColors.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 当前背景状态指示（若已设置自定义背景则显示移除按钮）
                  AnimatedBuilder(
                    animation: AppThemeManager.instance,
                    builder: (context, _) {
                      final themeData = AppThemeManager.instance.current;
                      final isUserBg = themeData.backgroundImage.source ==
                          BackgroundImageSource.file;
                      if (!isUserBg) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 14, color: AppColors.successGreen),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '当前已应用自定义背景',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 11,
                                  color: AppColors.secondaryText,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            InteractiveWrapper(
                              onTap: _onClearCustomBackground,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
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
                        ),
                      );
                    },
                  ),
                  // v3.0 P4：我的主题列表区（用户自定义主题 CRUD，空状态自动隐藏）
                  const SizedBox(height: 12),
                  MyThemesSection(
                    onImport: _onImportTheme,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // v3.0.1 修复5：自定义背景图上传
  // 修复：原实现 withBackgroundImage 保留 builtin id，导致 applyCustomTheme
  // 覆盖内置主题。现改为创建新的用户主题（新 UUID + source=user），
  // 并将 overlayOpacity 降至 0.25 与特色主题一致。
  Future<void> _onPickCustomBackground() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );

      if (result == null || result.files.isEmpty) return;
      final sourcePath = result.files.single.path;
      if (sourcePath == null) {
        if (mounted) {
          AppSnackBar.warning(context, '无法获取所选文件路径');
        }
        return;
      }

      // 上传到 user_backgrounds 目录（overlayOpacity=0.25 与特色主题一致）
      final bgConfig = await ThemeStorage.uploadBackgroundImage(
        sourcePath,
        overlayOpacity: 0.25,
      );

      if (!mounted) return;

      // 创建新的用户主题（不覆盖内置主题）
      final currentData = AppThemeManager.instance.current;
      final newId = ThemeStorage.newThemeId();
      final newData = currentData
          .asUserThemeCopy(
            newId: newId,
            name: '${currentData.name} · 自定义背景',
            emoji: currentData.emoji,
            description: '基于 ${currentData.name} 的自定义背景主题',
          )
          .withBackgroundImage(bgConfig);

      // 持久化用户主题 JSON
      await ThemeStorage.saveUserTheme(newData);
      // 应用为激活主题（触发 250ms 过渡）
      await AppThemeManager.instance.applyCustomTheme(newData);

      if (mounted) {
        AppSnackBar.success(context, '已应用自定义背景');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '背景上传失败: $e');
      }
    }
  }

  // v3.0.1 修复5：清除自定义背景
  // 修复：创建新的用户主题（无背景图），而非覆盖当前主题
  Future<void> _onClearCustomBackground() async {
    try {
      final currentData = AppThemeManager.instance.current;
      final oldFilename = currentData.backgroundImage.filename;

      // 创建新的用户主题（无背景图）
      final newId = ThemeStorage.newThemeId();
      final newData = currentData
          .asUserThemeCopy(
            newId: newId,
            name: '${currentData.name} · 纯色',
            emoji: currentData.emoji,
            description: '无背景图主题',
          )
          .withBackgroundImage(const BackgroundImageConfig.none());

      await ThemeStorage.saveUserTheme(newData);
      await AppThemeManager.instance.applyCustomTheme(newData);

      // 删除用户上传的背景图文件（释放磁盘空间）
      if (oldFilename != null) {
        await ThemeStorage.deleteBackgroundImage(oldFilename);
      }

      if (mounted) {
        AppSnackBar.success(context, '已移除自定义背景');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '移除背景失败: $e');
      }
    }
  }

  // v3.0 P5：从 .cttheme 文件导入主题
  // 实现于 P5 阶段（CtThemePackage.import），此处为入口
  Future<void> _onImportTheme() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['cttheme'],
        dialogTitle: '导入主题',
      );
      if (result == null || result.files.single.path == null) return;

      final imported = await CtThemePackage.importFromFile(
        result.files.single.path!,
      );
      AppThemeManager.instance.registerTheme(imported);
      AppThemeManager.instance.notifyThemeChanged();
      if (mounted) {
        AppSnackBar.success(context, '已导入主题「${imported.name}」');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '导入失败: $e');
      }
    }
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
    if (_isUploadingAvatar) return;
    setState(() => _isUploadingAvatar = true);

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
        _isUploadingAvatar = false;
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
        _isUploadingAvatar = false;
        _saveMessage = '选择文件失败，请重试';
        _saveSuccess = false;
      });
    }
  }

  Future<void> _uploadAvatarToServer(String fileName, List<int> bytes) async {
    try {
      debugPrint('[UPLOAD] 正在上传头像到服务器...');

      final result = await AuthService.uploadAvatar(
        fileName: fileName,
        bytes: bytes,
      );

      if (result.code == AuthResultCode.success) {
        debugPrint('[UPLOAD] ✅ 头像上传成功');
        // 通知 MainContainer 刷新用户数据（包括头像URL）
        widget.onAvatarChanged?.call();
      } else {
        debugPrint('[UPLOAD] ❌ 头像上传失败: ${result.message}');
        if (mounted) {
          setState(() {
            _saveMessage = '头像上传失败，请重试';
            _saveSuccess = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[UPLOAD] ❌ 头像上传异常: $e');
      if (mounted) {
        setState(() {
          _saveMessage = '头像上传失败，请重试';
          _saveSuccess = false;
        });
      }
    }
  }
}
