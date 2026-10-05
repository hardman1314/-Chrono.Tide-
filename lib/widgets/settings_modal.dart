import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update/update_service.dart';
// 本地账号体系（local_account_mode.md）：账号区块本地态分支
import '../modules/auth/local_account_service.dart';
import '../services/update/update_models.dart';
import 'update_dialog.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_spacing.dart';
import '../theme/app_styles.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_config.dart';
import '../theme/background_media.dart';
import 'background_image_editor_dialog.dart';
import '../theme/theme_storage.dart';
import '../theme/ct_theme_package.dart';
import 'interactive_wrapper.dart';
import 'app_snack_bar.dart';
import 'theme_editor_dialog.dart';
import 'my_themes_section.dart';
import 'settings/settings_tab.dart';
import 'settings/settings_section.dart';
import 'settings/archive_library_settings_card.dart';
import 'settings/cloud_backup_settings_card.dart';
import 'gamepad/gamepad_settings_section.dart';
import 'settings/settings_tile.dart';
import 'settings/settings_switch_tile.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import '../core/path_helper.dart';
import '../services/install_path_preference.dart';
import '../services/bpm_guide_preference.dart';
import '../services/metadata_fetcher.dart';
import '../services/local_game_registry.dart';
import '../services/quick_window_service.dart';
import '../services/game_data_format.dart'; // ★ v3 阶段 2: 统计重建
import '../services/magpie_service.dart';
import '../services/nsfw/nsfw_settings.dart';
import '../services/nsfw/nsfw_detection_service.dart';
import '../services/nsfw/nsfw_detection_store.dart';
import '../services/nsfw/nsfw_scan_service.dart';
import '../services/autostart_service.dart';
import '../services/storage/storage_cleanup_service.dart';
import '../services/download_intensity.dart';
import '../services/motion_preference.dart';
import '../services/auto_shortcut_preference.dart';
import '../services/bpm_op_video_preference.dart';

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
  // v3.9：外观栏拆为两张独立项目卡（2026-09-13）：
  // 「软件主题」= 系统主题（含跟随系统开关）+ 特色主题 + 快速上传背景图；
  // 「自定义设计」= 主题设计器入口 + 我的主题（默认展开——否则导入等
  // 快捷功能被折叠藏住，2026-09-13 用户反馈修正）。
  bool _softwareThemeExpanded = true;
  bool _customDesignExpanded = true;
  bool _magpieExpanded = false;
  bool _magpieExternalPathHovered = false;
  String? _magpieStatusMessage;
  bool _magpieStatusSuccess = false;
  bool _autoStartEnabled = false;
  // ===== 首次启动自动生成桌面快捷方式（2026-09-27 全局偏好，默认关闭）=====
  bool _autoShortcutEnabled = false;
  // ===== 快捷自定义窗口开关 =====
  bool _quickWindowEnabled = false;
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
  // ===== NSFW 内容保护（v2：YOLO 局部检测 + 局部马赛克）=====
  bool _nsfwEnabled = false;
  bool _nsfwReady = false;
  String? _nsfwInitError;
  bool _nsfwAllowReveal = true;
  NsfwDisplayMode _nsfwMode = NsfwDisplayMode.clean;
  // 上次见到的 modelSignature，用于检测"阈值/精度被用户调整"
  String _nsfwLastSignature = '';

  // ===== 下载强度（2026-09-26 批D：自动/轻量/全速 + 全局限速）=====
  DownloadIntensity _downloadIntensity = DownloadIntensity.auto;
  double _downloadSpeedLimitMbps = 0; // 0 = 不限

  // ===== 窗口尺寸（2026-09-08 IA 重构：由固定 700×500 改为可拉伸）=====
  // ⚠️ 设置窗口是 Overlay 内组件（main_container.dart:616-638），不是独立 OS 窗口，
  //    因此**不能用 window_manager 改尺寸**（会把整个主窗口一起放大），
  //    只能在组件内改 Container 的 width/height。
  static const double _kDefaultWidth = 900;
  static const double _kDefaultHeight = 620;
  static const double _kMinWidth = 820;
  static const double _kMinHeight = 520;
  static const double _kMaxWidth = 1200;
  static const double _kMaxHeight = 860;
  static const String _kPrefWidth = 'settings_modal_size_w';
  static const String _kPrefHeight = 'settings_modal_size_h';

  /// 用 ValueNotifier 驱动尺寸，配合 ValueListenableBuilder 的 child 缓存，
  /// 保证拖拽时**只重建最外层容器**、不重建内容子树（方案 §7 性能硬要求）。
  final ValueNotifier<Size> _size =
      ValueNotifier<Size>(const Size(_kDefaultWidth, _kDefaultHeight));

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
    _loadAutoShortcutPref();
    _loadQuickWindowStatus();
    _loadNsfwStatus();
    _loadWindowSize();
    _loadDownloadIntensity();
  }

  /// NSFW 设置与模型状态。
  ///
  /// 只在这里做一次 `load()`；后续设置变化通过 [NsfwSettings] 的
  /// ChangeNotifier 回调同步，避免每次 build 都读 SharedPreferences。
  Future<void> _loadNsfwStatus() async {
    final NsfwSettings settings = NsfwSettings.instance;
    await settings.load();
    settings.addListener(_onNsfwSettingsChanged);
    // 全量扫描进度通知 → 卡片状态行实时刷新
    NsfwScanService.instance.addListener(_onNsfwScanChanged);
    // 判定缓存变更（每次 put 有 200ms 去抖）→ 「待检测 N 张」跟随队列消耗刷新
    NsfwDetectionStore.instance.addListener(_onNsfwScanChanged);
    if (!mounted) return;
    setState(() {
      _nsfwEnabled = settings.enabled;
      _nsfwAllowReveal = settings.allowReveal;
      _nsfwMode = settings.mode;
    });
    // 记录当前签名，供 _onNsfwSettingsChanged 检测阈值/精度变化
    _nsfwLastSignature = settings.modelSignature;
    // 开启状态下才启动 worker isolate，避免无谓的 12MB 模型加载
    if (settings.enabled) await _ensureNsfwReady();
  }

  void _onNsfwSettingsChanged() {
    if (!mounted) return;
    final NsfwSettings settings = NsfwSettings.instance;
    setState(() {
      _nsfwEnabled = settings.enabled;
      _nsfwAllowReveal = settings.allowReveal;
      _nsfwMode = settings.mode;
    });
    // 置信度变化（推理档位已固定，不再参与变化）→ modelSignature 变化 →
    // 检测缓存整表失效，已扫过的图不会被任何触发点重新入队，必须强制重扫补齐判定
    final String sig = settings.modelSignature;
    if (settings.enabled &&
        _nsfwLastSignature.isNotEmpty &&
        sig != _nsfwLastSignature) {
      NsfwScanService.instance.startFullScan(force: true);
    }
    _nsfwLastSignature = sig;
  }

  void _onNsfwScanChanged() {
    if (!mounted) return;
    setState(() {}); // 扫描进度（isScanning/total/enqueued）变化
  }

  Future<void> _ensureNsfwReady() async {
    // 工作模式不做任何内容判定，不必加载 16.8MB 模型 / 起 worker isolate。
    if (NsfwSettings.instance.mode == NsfwDisplayMode.work) {
      if (mounted) {
        setState(() {
          _nsfwReady = false;
          _nsfwInitError = null;
        });
      }
      return;
    }
    final bool ok = await NsfwDetectionService.instance.ensureReady();
    if (!mounted) return;
    setState(() {
      _nsfwReady = ok;
      _nsfwInitError = NsfwDetectionService.instance.initError;
    });
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
    NsfwSettings.instance.removeListener(_onNsfwSettingsChanged);
    NsfwScanService.instance.removeListener(_onNsfwScanChanged);
    NsfwDetectionStore.instance.removeListener(_onNsfwScanChanged);
    _size.dispose();
    super.dispose();
  }

  /// 恢复上次拉伸后的窗口尺寸；未存过则用默认值。
  ///
  /// 读取一律 `?? 默认值`，不引入迁移。
  Future<void> _loadWindowSize() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final double w = prefs.getDouble(_kPrefWidth) ?? _kDefaultWidth;
    final double h = prefs.getDouble(_kPrefHeight) ?? _kDefaultHeight;
    if (!mounted) return;
    _size.value = Size(w, h);
  }

  Future<void> _saveWindowSize(Size size) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kPrefWidth, size.width);
    await prefs.setDouble(_kPrefHeight, size.height);
  }

  /// 下载强度与限速加载（批D）。读取一律 `?? 默认值`，不引入迁移。
  Future<void> _loadDownloadIntensity() async {
    final intensity = await DownloadIntensityPrefs.load();
    final limit = await DownloadIntensityPrefs.loadSpeedLimitMbps();
    if (!mounted) return;
    setState(() {
      _downloadIntensity = intensity;
      _downloadSpeedLimitMbps = limit;
    });
  }

  Future<void> _onIntensityChanged(DownloadIntensity v) async {
    setState(() => _downloadIntensity = v);
    await DownloadIntensityPrefs.save(v);
    // ★ 方案约定：切到轻量档时限速未配置（0=不限）则自动带默认 2MB/s，
    //   保证「弱网不抢前台」的档位语义开箱即得；其余档位不隐式改动。
    if (v == DownloadIntensity.light && _downloadSpeedLimitMbps <= 0) {
      setState(() => _downloadSpeedLimitMbps =
          DownloadIntensityPrefs.lightDefaultLimitMbps);
      await DownloadIntensityPrefs.saveSpeedLimitMbps(
          DownloadIntensityPrefs.lightDefaultLimitMbps);
    }
  }

  Future<void> _onSpeedLimitCommit(double v) async {
    await DownloadIntensityPrefs.saveSpeedLimitMbps(v);
  }

  /// 拖拽右下角手柄调整尺寸。
  ///
  /// 上下限同时受屏幕尺寸约束，避免小屏上拖出不可用尺寸。
  void _onResizeDrag(DragUpdateDetails details, Size screen) {
    final double maxW = math.min(_kMaxWidth, screen.width - 40);
    final double maxH = math.min(_kMaxHeight, screen.height - 40);
    final double minW = math.min(_kMinWidth, maxW);
    final double minH = math.min(_kMinHeight, maxH);
    final Size current = _size.value;
    _size.value = Size(
      (current.width + details.delta.dx).clamp(minW, maxW).toDouble(),
      (current.height + details.delta.dy).clamp(minH, maxH).toDouble(),
    );
  }

  Future<void> _loadUserData() async {
    // ★ 本地账号体系：无云端会话时读本地账户（getCurrentUser 无 token
    // 直接返回 null 且零网络调用，见 auth_service.dart:1031-1034）。
    var user = await AuthService.getCurrentUser();
    if (user == null && LocalAccountService.exists) {
      user = LocalAccountService.load();
    }
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

    // ★ 本地账号体系：本地账户资料写本地（local_account_*），不走云端。
    if (_user?.isLocalAccount ?? false) {
      await LocalAccountService.updateProfile(name: nickname, bio: bio);
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveMessage = '修改已保存';
        _saveSuccess = true;
        _user = _user!.copyWith(name: nickname, bio: bio);
        _tempAvatarBytes = null;
        _tempAvatarFileName = null;
      });
      return;
    }

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
      AppSnackBar.info(
        context,
        '当前已是最新版本',
        duration: Duration(seconds: 2),
      );
    } else {
      AppSnackBar.error(
        context,
        '检查更新失败：${result.userFriendlyError}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: ValueListenableBuilder<Size>(
          valueListenable: _size,
          builder: (BuildContext context, Size size, Widget? child) {
            return Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: AppColors.sidebarBackground,
                border: Border.all(color: AppColors.border, width: 1.6),
                borderRadius: BorderRadius.circular(AppRadius.xl),
                // 软阴影替代原硬边投影（原 Offset(4,6) blur 0），见方案 §5.3 U5
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.18),
                    offset: const Offset(0, 8),
                    blurRadius: 24,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: child!),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _buildResizeHandle(screen),
                  ),
                ],
              ),
            );
          },
          // 内容子树在此缓存：拖拽改变尺寸时不会重建（方案 §7 性能硬要求）
          child: Column(
            children: <Widget>[
              _buildHeader(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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

  /// 右下角拖拽手柄：拖拽调整尺寸，双击复位默认尺寸。
  ///
  /// ⚠️ 设置窗口是 Overlay 内组件，这里改的是**组件自身**尺寸，
  /// 不涉及 `window_manager`（那会放大整个主窗口）。
  Widget _buildResizeHandle(Size screen) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (DragUpdateDetails d) => _onResizeDrag(d, screen),
        onPanEnd: (_) => _saveWindowSize(_size.value),
        onDoubleTap: () {
          _size.value = const Size(_kDefaultWidth, _kDefaultHeight);
          _saveWindowSize(_size.value);
        },
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CustomPaint(painter: _ResizeGripPainter()),
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
      width: 200,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          right: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 2026-09-08 IA 重构：由 3 项（含「偏好设置」）改为 6 项，
          // 顺序与图标统一在 SettingsTabMeta.items 维护。
          for (int i = 0; i < SettingsTabMeta.items.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            _buildTabButton(meta: SettingsTabMeta.items[i]),
          ],
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

  Widget _buildTabButton({required SettingsTabMeta meta}) {
    final bool isSelected = _currentTab == meta.tab;
    return InteractiveWrapper(
      onTap: () => setState(() => _currentTab = meta.tab),
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Container(
        width: double.infinity,
        height: 40,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.buttonBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isSelected ? AppColors.border : Colors.transparent,
            width: 1.6,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: <Widget>[
            SvgPicture.asset(meta.iconPath, width: 18, height: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                meta.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  height: 24 / 16,
                  color: isSelected
                      ? AppColors.primaryText
                      : AppColors.secondaryText,
                ),
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
        // 原为 fromLTRB(24, 24, 39, 24)，右侧 39 属历史遗留的不对称值，统一为 24
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: () {
          switch (_currentTab) {
            case SettingsTab.profile:
              return _buildProfileContent();
            case SettingsTab.appearance:
              return _buildAppearanceContent();
            case SettingsTab.gameLaunch:
              return _buildGameLaunchContent();
            case SettingsTab.bigPicture:
              return _buildBigPictureContent();
            case SettingsTab.networkStorage:
              return _buildNetworkStorageContent();
            case SettingsTab.contentSafety:
              return _buildContentSafetyContent();
            case SettingsTab.about:
              return _buildAboutContent();
          }
        }(),
      ),
    );
  }

  /// 大屏模式页（2026-09-27 新增）：BPM 背景 OP 视频的两个偏好开关。
  ///
  /// 归属桌面设置页（用户拍板 Q1）—— 这两个开关只影响 BPM，但统一在设置里
  /// 管理，不给 BPM 顶部栏增加设置入口。
  ///
  /// 单个游戏的视频上传 / 移除在「编辑游戏信息」窗口内（BPM 详情面板 → 编辑）。
  Widget _buildBigPictureContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '背景 OP 视频',
            description: '为大屏模式主页上传 OP 视频后，选中该游戏停留 3 秒即自动播放，'
                '播完淡出恢复原背景。上传 / 移除在「编辑游戏信息」窗口内。',
            children: <Widget>[
              AnimatedBuilder(
                animation: BpmOpVideoPreference.instance,
                builder: (BuildContext context, Widget? _) {
                  final bool on = BpmOpVideoPreference.instance.soundEnabled;
                  return SettingsSwitchTile(
                    title: '播放声音',
                    icon: Icons.volume_up_rounded,
                    value: on,
                    // v3.18: 明确「默认」语义 —— 该游戏单独拨过开关后以详情页为准
                    statusText: on
                        ? '已开启 · 新游戏默认出声（可在详情内单独关）'
                        : '已关闭 · 新游戏默认静音（可在详情内单独开）',
                    onChanged: (bool value) async {
                      await BpmOpVideoPreference.instance
                          .setSoundEnabled(value);
                    },
                  );
                },
              ),
              AnimatedBuilder(
                animation: BpmOpVideoPreference.instance,
                builder: (BuildContext context, Widget? _) {
                  final bool on = BpmOpVideoPreference.instance.autoplayAlways;
                  return SettingsSwitchTile(
                    title: '每次选中都自动播放',
                    icon: Icons.repeat_rounded,
                    value: on,
                    statusText: on
                        ? '已开启 · 每次选中该游戏都会自动播放（默认）'
                        : '已关闭 · 本次进入大屏后每个游戏只自动播一次',
                    onChanged: (bool value) async {
                      await BpmOpVideoPreference.instance
                          .setAutoplayAlways(value);
                    },
                  );
                },
              ),
            ],
          ),
          const GamepadSettingsSection(),
          // v3.21: 操作引导总开关（用户拍板：开启显示、关闭完全不显示）
          SettingsSection(
            title: '操作引导',
            description: '在大屏模式显示上下文按键提示（图标化键帽，随键鼠/手柄'
                '自动切换）：卡片操作角标、搜索快捷键、侧缘翻页、LB/RB 切页等。',
            children: <Widget>[
              AnimatedBuilder(
                animation: BpmGuidePreference.instance,
                builder: (BuildContext context, Widget? _) {
                  final bool on = BpmGuidePreference.instance.enabled;
                  return SettingsSwitchTile(
                    title: '显示操作引导',
                    icon: Icons.gamepad_rounded,
                    value: on,
                    statusText: on
                        ? '已开启 · 各界面显示当前可用的快捷操作提示'
                        : '已关闭 · 完全不显示任何操作提示',
                    onChanged: (bool value) async {
                      await BpmGuidePreference.instance.setEnabled(value);
                    },
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 2026-09-08 IA 重构新增的四个页（由原「偏好设置」页拆分而来）。
  ///
  /// Phase 2 阶段先占位，Phase 3 分 4 批把原卡片方法迁移进来。
  /// 外观页（原「主题设计器」卡片迁移而来）。
  ///
  /// ⚠️ 该卡片是 450 行的单体可折叠组件（含内置配色网格、特色主题、背景上传、
  /// `MyThemesSection`），本次**保持内部实现零改动**整体迁入，仅在外层加分组容器。
  /// 深度拆分与视觉令牌化留到 Phase 4，本阶段优先保证功能零回归。
  Widget _buildAppearanceContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '软件主题',
            isFirst: true,
            description: '选择系统配色或特色背景主题，可上传自定义背景图并自由调整其位置。',
            children: <Widget>[
              _buildThemeDesignerCard(),
              // v3.10 R4：全局「减少动效」。
              // ⚠️ 作用范围**仅动态背景图**（GIF 不再循环播放，只渲染静态首帧），
              // 不包含界面过渡动效——文案必须与此保持一致，不得写成"关闭全部动画"。
              // 用 AnimatedBuilder 直连偏好单例，因此本页不需要额外的 State 字段，
              // 也不需要在 initState 里加载（值已在 main.dart 首帧前读好）。
              AnimatedBuilder(
                animation: MotionPreference.instance,
                builder: (BuildContext context, Widget? _) {
                  final bool on = MotionPreference.instance.reduceMotion;
                  return SettingsSwitchTile(
                    title: '减少动效',
                    icon: Icons.motion_photos_off_rounded,
                    value: on,
                    statusText: on
                        ? '已开启 · 动态背景图只显示首帧，不再循环播放'
                        : '已关闭 · GIF 动态背景图正常循环播放',
                    onChanged: (bool value) async {
                      await MotionPreference.instance.setReduceMotion(value);
                    },
                  );
                },
              ),
            ],
          ),
          SettingsSection(
            title: '自定义设计',
            description: '打开主题设计器逐项调色，管理我的主题（新建 / 编辑 / 导入 / 删除）。',
            children: <Widget>[_buildCustomDesignCard()],
          ),
        ],
      ),
    );
  }

  /// 游戏与启动页（原「开机自启动」「快捷窗口控制」「超分增强 Magpie」
  /// 「游玩时长统计模式」四张卡片迁移而来）。
  ///
  /// 同样保持各卡片内部实现零改动，仅按主题域分四个组。
  Widget _buildGameLaunchContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '系统',
            isFirst: true,
            children: <Widget>[
              _buildAutoStartCard(),
              _buildAutoShortcutCard(),
            ],
          ),
          SettingsSection(
            title: '游戏窗口',
            children: <Widget>[_buildQuickWindowCard()],
          ),
          SettingsSection(
            title: '超分增强',
            description: '用 Magpie 对启动的游戏做实时超分，可切换内置版本或外接本地 Magpie。',
            children: <Widget>[_buildMagpieCard()],
          ),
          SettingsSection(
            title: '游玩记录',
            children: <Widget>[_buildPlaytimeTrackingCard()],
          ),
        ],
      ),
    );
  }

  /// 网络与存储页（原「网络代理设置」「默认游戏安装路径」「缓存管理」
  /// 三张卡片迁移而来）。
  Widget _buildNetworkStorageContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '网络',
            isFirst: true,
            children: <Widget>[_buildProxyCard(), _buildDownloadIntensityCard()],
          ),
          SettingsSection(
            title: '游戏库目录',
            description: '从探索页安装的游戏默认存放到此位置，游戏本体与元数据分离存储。',
            children: <Widget>[_buildInstallPathCard()],
          ),
          // 「归档库」分组（方案 §7 Phase 4）：位置 / 保留份数 / 压缩档位。
          // 面板整体独立成 widget 文件，本文件只做挂载，避免继续膨胀。
          SettingsSection(
            title: '归档库',
            description: '「保存游戏数据 / 打包」产出的游戏数据归档存放位置与清理策略。',
            children: <Widget>[const ArchiveLibrarySettingsCard()],
          ),
          // 「云备份」分组（方案 §7 Phase 5）：WebDAV 直连 Provider，
          // 凭据 DPAPI 加密。上传入口在游戏数据弹窗的归档条目上（手动）。
          SettingsSection(
            title: '云备份',
            description: '把游戏归档手动上传到你的 WebDAV 网盘（坚果云 / Nextcloud / NAS）。',
            children: <Widget>[const CloudBackupSettingsCard()],
          ),
          SettingsSection(
            title: '缓存',
            children: <Widget>[_buildStorageManagementCard()],
          ),
        ],
      ),
    );
  }

  /// 内容保护页（原「NSFW 内容保护」卡片迁移而来）。
  ///
  /// 2026-09-08 IA 重构：卡片平铺 → 分组列表。
  /// ⚠️ 判定逻辑与 service 调用**一律未改**，只换容器与文案。
  Widget _buildContentSafetyContent() {
    final NsfwScanService scan = NsfwScanService.instance;
    final int pending = NsfwDetectionService.instance.pendingCount;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '内容保护',
            isFirst: true,
            description:
                '纯净模式由本地 AI 识别 R18+ 内容后模糊或隐藏；'
                    '工作模式不做判定，全部图片替换为占位图。'
                    '原图文件字节级不变，全程不联网。',
            children: <Widget>[
              SettingsSwitchTile(
                title: 'NSFW 内容保护',
                icon: Icons.visibility_off_rounded,
                value: _nsfwEnabled,
                statusText: _nsfwStatusText(),
                warning: _nsfwEnabled && !_nsfwReady,
                onChanged: (bool value) async {
                  await NsfwSettings.instance.setEnabled(value);
                  if (value) {
                    await _ensureNsfwReady();
                    // 首次开启：把库里存量封面/截图补进检测队列
                    // （仅跑一次，hasEverFullScanned 持久化防重；重复扫描幂等跳过）
                    // 工作模式不做判定，无需扫描。
                    if (NsfwSettings.instance.mode != NsfwDisplayMode.work) {
                      NsfwScanService.instance.startFullScan();
                    }
                  }
                },
              ),
              // 全量扫描进行中：单独一行显示进度，否则几百张图扫描期间用户无从感知
              if (_nsfwEnabled && scan.isScanning)
                SettingsTile(
                  title: '全量扫描中',
                  subtitle: '已入队 ${scan.enqueued}/${scan.total}'
                      '${pending > 0 ? ' · 待推理 $pending' : ''}',
                  icon: Icons.hourglass_top,
                ),
            ],
          ),
          if (_nsfwEnabled) ...<Widget>[
            SettingsSection(
              title: '处理模式',
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _buildNsfwModeOption(
                        NsfwDisplayMode.clean,
                        '本地 AI 判定敏感内容后模糊或隐藏，其余画面不受影响',
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _buildNsfwModeOption(
                        NsfwDisplayMode.work,
                        '所有图片替换为占位图，不做判定，最省资源',
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '高级',
              children: <Widget>[
                SettingsSwitchTile(
                  title: '允许点击临时揭示',
                  icon: Icons.touch_app_outlined,
                  value: _nsfwAllowReveal,
                  // v2.5：揭示入口由「整图点击」改为「右下角眼睛角标」，
                  // 网格卡片随之可用（此前为避免抢点击而一律关闭）。
                  statusText: '点右下角眼睛角标显示原图，再点恢复遮蔽'
                      '（封面卡片 / 详情封面 / 截图轮播生效）',
                  onChanged: (bool value) =>
                      NsfwSettings.instance.setAllowReveal(value),
                ),
                SettingsTile(
                  title: '补扫全部封面与截图',
                  subtitle: pending > 0
                      ? '待检测 $pending 张'
                      : '有新增或漏检的本地图片时可强制重扫（已判定的不会重复推理）',
                  icon: Icons.refresh,
                  trailing: OutlinedButton(
                    onPressed: (scan.isScanning || !_nsfwReady)
                        ? null
                        : () => scan.startFullScan(force: true),
                    child: Text(scan.isScanning ? '扫描中…' : '补扫'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// NSFW 状态文案。
  ///
  /// 2026-09-08 修复：原文案固定写「敏感部位自动局部打码」，
  /// 选「纯净模式」时与实际行为（隐藏 R18+ 截图 + 封面打码）不符。
  /// 另：**未启用**时用「已关闭」，启用态统一用「已启用」（术语统一，方案 §5.3 U3）。
  ///
  /// 2026-09-08 补：工作模式**不加载模型**（[NsfwDisplayMode.work]），
  /// 此时 [_nsfwReady] 恒为 false，故必须**先于**未就绪分支返回，
  /// 否则会误报「模型未就绪」。
  String _nsfwStatusText() {
    if (!_nsfwEnabled) return '已关闭 · 封面与截图原样显示';
    if (_nsfwMode == NsfwDisplayMode.work) {
      return '已启用 · 工作模式：全部图片替换为占位图，不做判定';
    }
    if (!_nsfwReady) return '模型未就绪 · ${_nsfwInitError ?? '等待加载'}';
    return switch (_nsfwMode) {
      NsfwDisplayMode.clean => '已启用 · 纯净模式：R18+ 截图隐藏、封面模糊',
      NsfwDisplayMode.work => '已启用 · 工作模式：全部图片替换为占位图',
    };
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

  Widget _buildNsfwModeOption(NsfwDisplayMode mode, String hint) {
    final bool selected = _nsfwMode == mode;
    return InteractiveWrapper(
      onTap: () => NsfwSettings.instance.setMode(mode),
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.buttonBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.border : AppColors.borderLight,
            width: 1.4,
          ),
        ),
        child: Column(
          children: <Widget>[
            Text(
              mode.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
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
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
                            fontSize: 11,
                            color: _rebuildStatsSuccess
                                ? AppColors.successGreen
                                : kSettingsWarning,
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

  /// 首次启动自动生成桌面快捷方式（全局偏好，2026-09-27）。
  ///
  /// [AutoShortcutPreference.load] 幂等（`main.dart` 首帧前已加载过），
  /// 此处只做一次读取回填。本页是唯一写入方，故不挂 listener。
  void _loadAutoShortcutPref() async {
    final AutoShortcutPreference pref = AutoShortcutPreference.instance;
    await pref.load();
    if (!mounted) return;
    setState(() => _autoShortcutEnabled = pref.enabled);
  }

  void _loadQuickWindowStatus() async {
    // 读设置页开关 prefs（控制"游戏启动后是否默认自动开启"），
    // 同步 UI 状态；与"当前会话 g_enabled"是两个独立概念。
    if (!mounted) return;
    final autoEnable = await QuickWindowService.instance.getAutoEnable();
    if (mounted) {
      setState(() {
        _quickWindowEnabled = autoEnable;
      });
    }
  }

  // ========== 快捷自定义窗口卡片（AltSnap 式游戏窗口控制） ==========
  Widget _buildQuickWindowCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _quickWindowEnabled
                      ? const Color(0xFF7C6CF0).withOpacity(0.12)
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.web_asset_rounded,
                  size: 22,
                  color: _quickWindowEnabled
                      ? const Color(0xFF7C6CF0)
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
                      '快捷窗口控制',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 24 / 16,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _quickWindowEnabled
                          ? '已开启 · 游戏启动后自动启用快捷窗口控制'
                          : '已关闭 · 游戏启动后需长按中键手动开启',
                      style: TextStyle(
                        fontSize: 13,
                        height: 18 / 13,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _quickWindowEnabled,
                activeColor: const Color(0xFF7C6CF0),
                onChanged: (value) async {
                  if (value && !QuickWindowService.instance.isAvailable) {
                    if (mounted) {
                      AppSnackBar.warning(
                        context,
                        '当前构建不支持快捷窗口控制，请更新程序',
                      );
                    }
                    return;
                  }
                  // 写 prefs（决定游戏启动后是否默认自动开启）并立即应用到当前会话
                  final ok =
                      await QuickWindowService.instance.setAutoEnable(value);
                  if (ok && mounted) {
                    setState(() => _quickWindowEnabled = value);
                  }
                },
              ),
            ],
          ),
          if (_quickWindowEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 12, left: 54),
              child: Text(
                '手势：中键单击弹出菜单 · Alt+左键拖拽移动 · Alt+边缘拖拽调整大小 · Alt+滚轮调透明度\n快捷开关：长按中键约1秒可临时挂起/恢复本功能（鼠标旁有进度提示，不影响此处的开关设置）\n菜单：置顶 / 透明度 / 静音（仅游戏进程）/ 最大化 / 居中 / 关闭',
                style: TextStyle(
                  fontSize: 12,
                  height: 18 / 12,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAutoStartCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
                  ? AppColors.successGreen.withOpacity(0.1)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.power_settings_new_rounded,
              size: 22,
              color: _autoStartEnabled
                  ? AppColors.successGreen
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
            activeColor: AppColors.successGreen,
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

  /// 全局「首次启动自动生成桌面快捷方式」开关卡片。
  ///
  /// 2026-09-27：该能力原为启动管理弹窗中的**每游戏**开关
  /// （`game.json.auto_create_shortcut`，默认 `true`），现改为全局偏好
  /// （[AutoShortcutPreference]）并**默认关闭**。
  /// 样式与同组 [_buildAutoStartCard] 保持一致（同一分组内两张同款卡片）。
  Widget _buildAutoShortcutCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
              color: _autoShortcutEnabled
                  ? AppColors.successGreen.withOpacity(0.1)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.desktop_windows_rounded,
              size: 22,
              color: _autoShortcutEnabled
                  ? AppColors.successGreen
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
                  '首次启动自动生成桌面快捷方式',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    height: 24 / 16,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _autoShortcutEnabled
                      ? '已开启 · 首次启动游戏时自动创建桌面快捷方式'
                      : '已关闭 · 不再自动创建，可在启动管理中手动生成',
                  style: TextStyle(
                    fontSize: 13,
                    height: 18 / 13,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _autoShortcutEnabled,
            activeColor: AppColors.successGreen,
            onChanged: (value) async {
              setState(() => _autoShortcutEnabled = value);
              await AutoShortcutPreference.instance.setEnabled(value);
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
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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

  /// 下载强度卡（2026-09-26 批D）：三档 + 全局限速滑条。
  ///
  /// 修改即时写 prefs；对**下一次**下载任务生效（内核 start 时读取）。
  Widget _buildDownloadIntensityCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
            '下载强度',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 24 / 16,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '控制下载占用的连接数与带宽，修改对下一次下载生效。',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          ...DownloadIntensity.values.map(_buildIntensityRow),
          const SizedBox(height: 12),
          Text(
            _downloadSpeedLimitMbps <= 0
                ? '全局限速：不限速'
                : '全局限速：${_downloadSpeedLimitMbps.toStringAsFixed(_downloadSpeedLimitMbps.truncateToDouble() == _downloadSpeedLimitMbps ? 0 : 1)} MB/s',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.primaryText,
            ),
          ),
          Slider(
            value: _downloadSpeedLimitMbps.clamp(0.0, 100.0),
            min: 0,
            max: 100,
            divisions: 200,
            label: _downloadSpeedLimitMbps <= 0
                ? '不限'
                : '${_downloadSpeedLimitMbps.toStringAsFixed(_downloadSpeedLimitMbps.truncateToDouble() == _downloadSpeedLimitMbps ? 0 : 1)} MB/s',
            onChanged: (v) => setState(() => _downloadSpeedLimitMbps = v),
            onChangeEnd: _onSpeedLimitCommit,
          ),
        ],
      ),
    );
  }

  Widget _buildIntensityRow(DownloadIntensity v) {
    final bool selected = _downloadIntensity == v;
    return InkWell(
      onTap: () => _onIntensityChanged(v),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 18,
              color: selected
                  ? AppColors.selectedAccent
                  : AppColors.secondaryText,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 20 / 14,
                      color: AppColors.primaryText,
                    ),
                  ),
                  Text(
                    v.description,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      height: 16 / 12,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProxyCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
        if (selectedPath.toLowerCase().endsWith('magpie.exe')) {
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
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
          const SizedBox(height: 32),
          Text(
            '开源组件致谢',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'SDL3 (Simple DirectMedia Layer) — Copyright (c) Sam Lantinga & libsdl-org contributors, zlib License。用于跨厂商手柄输入（Xbox / PlayStation / Switch 等），完整许可文本见安装目录 runtime/sdl3/LICENSE.txt。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
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
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                StorageCleanupService.formatBytes(_cacheTotalBytes),
                style: TextStyle(
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
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
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
                () => _softwareThemeExpanded = !_softwareThemeExpanded),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.wallpaper_rounded,
                      size: 20, color: AppColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '软件主题',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 24 / 16,
                            color: AppColors.primaryText,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '系统主题 · 特色主题 · 自定义背景图',
                          style: TextStyle(
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
                    turns: _softwareThemeExpanded ? 0.5 : 0,
                    child: Icon(Icons.expand_more,
                        size: 20, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: _softwareThemeExpanded
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
                        '系统主题',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 18 / 13,
                          color: AppColors.secondaryText,
                        ),
                      ),
                      const Spacer(),
                      // v3.9：跟随系统主题开关——默认关闭（软件默认暖白），
                      // 开启后按设备深浅色自动切换 浅色/深色；
                      // 手动选择其它主题会自动退出跟随（否则行为不一致）
                      Text(
                        '跟随系统',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                          color: AppColors.secondaryText,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: AppThemeManager.instance.followSystemTheme,
                          onChanged: (v) =>
                              AppThemeManager.instance.setFollowSystemTheme(v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // v3.9：系统主题——圆角方形小卡横向排列（2026-09-13 用户
                  // 指定；竖向通栏卡占纵向空间过多），选中=accent 边+抬升
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: standardThemes.map((theme) {
                      final data = AppThemeManager.themeData(theme);
                      final isSelected = currentTheme == theme;
                      // ⚠️ 卡片槽位必须先定宽再交给 InteractiveWrapper：
                      // 其内部 AnimatedContainer 带 alignment(=> Align)，在有界
                      // 约束下会撑满整行宽度；直接作为 Wrap 子项会导致「每行只
                      // 放得下一张卡」的竖排（2026-09-19 修复）。
                      final card = InteractiveWrapper(
                        onTap: () => AppThemeManager.instance.setTheme(theme),
                        hoverScale: 1.04,
                        child: Container(
                          width: 108,
                          height: 64,
                          decoration: BoxDecoration(
                            color: data.background,
                            border: Border.all(
                              color: isSelected
                                  ? data.selectedAccent
                                  : data.borderLight,
                              width: AppStyle.isModern
                                  ? (isSelected ? 1.4 : AppStyle.wHairline)
                                  : (isSelected ? 2.0 : 1.0),
                            ),
                            borderRadius: BorderRadius.circular(
                                AppStyle.isModern ? AppStyle.rMd : 10),
                            boxShadow: isSelected
                                ? (AppStyle.isModern
                                    ? AppStyle.e2
                                    : [
                                        BoxShadow(
                                          color: data.border,
                                          offset: const Offset(2, 2),
                                          blurRadius: 0,
                                        ),
                                      ])
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                data.emoji,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                data.name,
                                style: TextStyle(
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
                      return SizedBox(
                        width: 108,
                        height: 64,
                        child: card,
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
                                width: AppStyle.isModern
                                    ? (isSelected ? 1.4 : AppStyle.wHairline)
                                    : (isSelected ? 2.2 : 1.2),
                              ),
                              borderRadius: BorderRadius.circular(
                                  AppStyle.isModern ? 14 : 12),
                              boxShadow: isSelected
                                  ? (AppStyle.isModern
                                      ? AppStyle.e2
                                      : [
                                          BoxShadow(
                                            color: data.shadowColor,
                                            offset: const Offset(2, 2),
                                            blurRadius: 0,
                                          ),
                                        ])
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
                                      // v3.10：此预览只渲染**内置 bundled** 主题
                                      // （当前全为 PNG，无动图资源），因此保持
                                      // Image.asset。若将来引入动图内置主题，
                                      // 需改用 AnimatedBackgroundImage 并传
                                      // degradeToStaticFrame: true（R5 缩略预览）。
                                      child: Image.asset(
                                        data.backgroundImagePath!,
                                        fit: BoxFit.cover,
                                        // 取景对齐跟随主题配置（如樱花 top 露头部）
                                        alignment: data.backgroundImage
                                                    .alignment ==
                                                BackgroundImageAlignment.top
                                            ? Alignment.topCenter
                                            : Alignment.center,
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
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 18 / 13,
                          color: AppColors.placeholderText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // v3.0 P1：原占位按钮替换为可用入口
                  // 点击直接打开文件选择器，上传后立即应用为当前主题背景
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
                                  fontSize: 11,
                                  color: AppColors.secondaryText,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            InteractiveWrapper(
                              onTap: _onAdjustBackgroundPosition,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                child: Text(
                                  '调整位置',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.infoBlue,
                                  ),
                                ),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「自定义设计」独立项目卡（2026-09-13 外观栏重排）：
  /// 主题设计器入口 + 我的主题（用户自定义主题 CRUD / 导入）。
  Widget _buildCustomDesignCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
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
                () => _customDesignExpanded = !_customDesignExpanded),
            hoverScale: 1.0,
            hoverOffset: Offset.zero,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  Icon(Icons.design_services_rounded,
                      size: 20, color: AppColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自定义设计',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 24 / 16,
                            color: AppColors.primaryText,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '主题设计器 · 我的主题',
                          style: TextStyle(
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
                    turns: _customDesignExpanded ? 0.5 : 0,
                    child: Icon(Icons.expand_more,
                        size: 20, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: _customDesignExpanded
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
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: AppColors.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // v3.0 P4：我的主题列表区（用户自定义主题 CRUD，空状态自动隐藏）
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
        // v3.10：改用 custom + 显式扩展名。Windows 端 `FileType.image` 的过滤器
        // 是写死的 `*.bmp;*.gif;*.jpeg;*.jpg;*.png`
        // （file_picker 8.3.7 file_picker_windows.dart:230），**不含 webp** ——
        // 不改的话新增的 webp 支持在"选文件"这一步就够不着。
        type: FileType.custom,
        allowedExtensions: BackgroundMediaInspector.allowedExtensions,
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
      // v3.10：越限由 BackgroundMediaRejectedException 精确回显；
      // 时长/帧率超建议值只提示不拒绝。
      final bgConfig = await ThemeStorage.uploadBackgroundImage(
        sourcePath,
        overlayOpacity: 0.25,
        onWarnings: (warnings) {
          if (mounted) AppSnackBar.warning(context, warnings.join('；'));
        },
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
    } on BackgroundMediaRejectedException catch (e) {
      // v3.10：门槛拒绝，文案已精确到维度（体积/分辨率/帧数/伪装）
      if (mounted) {
        AppSnackBar.error(context, e.message);
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '背景上传失败: $e');
      }
    }
  }

  // v3.9：自由调整当前自定义背景图的位置/缩放（2026-09-13 外观栏重排）。
  // 复用主题设计器的背景图编辑器（Figma 式拖拽缩放）；当前主题已是用户主题时
  // 原地更新（applyCustomTheme 同 id 直接通知刷新），否则新建用户主题。
  Future<void> _onAdjustBackgroundPosition() async {
    try {
      final current = AppThemeManager.instance.current;
      if (current.backgroundImage.source != BackgroundImageSource.file) {
        return; // 仅用户上传的背景支持自由调整
      }
      final result = await BackgroundImageEditorDialog.show(
        context: context,
        config: current.backgroundImage,
      );
      if (result == null) return; // 用户取消
      if (!mounted) return;

      final CTThemeData newData;
      if (current.isUserTheme) {
        // 用户主题：原地更新背景配置
        newData = current.withBackgroundImage(result);
      } else {
        // 内置主题兜底：新建用户主题（不覆盖内置定义）
        newData = current
            .asUserThemeCopy(
              newId: ThemeStorage.newThemeId(),
              name: '${current.name} · 位置调整',
              emoji: current.emoji,
              description: '调整背景图位置的主题',
            )
            .withBackgroundImage(result);
      }
      await ThemeStorage.saveUserTheme(newData);
      await AppThemeManager.instance.applyCustomTheme(newData);

      if (mounted) {
        AppSnackBar.success(context, '已应用背景图位置');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, '调整背景位置失败: $e');
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

      // ★ 本地账号体系：本地账户头像写本地（local_account_avatar_b64），
      // 不写云端缓存 key（user_avatar_base64）、不上传服务器。
      if (_user?.isLocalAccount ?? false) {
        await LocalAccountService.updateAvatar(file.bytes!);
        if (!mounted) return;
        setState(() {
          _isUploadingAvatar = false;
          _tempAvatarBytes = file.bytes!;
          _tempAvatarFileName = file.name;
          _avatarUrl = null;
          _saveMessage = null;
        });
        return;
      }

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

/// 右下角尺寸调整手柄的斜线纹样（经典 Windows 调整手柄样式）。
class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = AppColors.secondaryText.withOpacity(0.55)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width - 5, 8),
      Offset(8, size.height - 5),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - 5, 13),
      Offset(13, size.height - 5),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter oldDelegate) => false;
}
