import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../widgets/sidebar.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/floating_user_button.dart';
import '../widgets/floating_task_button.dart';
import '../widgets/auth_modal.dart';
import '../widgets/user_profile_modal.dart';
import '../widgets/settings_modal.dart';
import '../widgets/payment_modal.dart';
import '../widgets/animated_overlay.dart';
import '../widgets/app_snack_bar.dart';
import '../pages/library_page.dart';
import '../pages/discover_page.dart';
import '../pages/join_page.dart';
import '../pages/home_page.dart';
import '../pages/game_detail_page.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import '../services/local_game_registry.dart';
import '../services/game_launch_service.dart';
import '../services/game_data_format.dart';
import '../services/user_cache_service.dart';
import '../services/network_status_service.dart';
import '../pages/install_center_page.dart';
import '../pages/join/batch_import_controller.dart';
import '../big_picture/big_picture_manager.dart';
import '../big_picture/big_picture_shell.dart';

class MainContainer extends StatefulWidget {
  final VoidCallback? onLogout;
  const MainContainer({super.key, this.onLogout});

  /// ★ 启动时同步注入的侧边栏初始收起状态（由 main.dart 在 runApp 前赋值）。
  /// 避免首帧渲染展开态后再异步动画收起导致的「抽搐」。
  static bool initialSidebarCollapsed = false;

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  NavPage _currentPage = NavPage.home;
  GameCardData? _selectedGame;
  bool _showDetailPage = false;
  bool _isLoggedIn = false;
  UserModel? _currentUser;
  OverlayEntry? _authOverlay;
  OverlayEntry? _settingsOverlay;
  OverlayEntry? _paymentOverlay;
  OverlayEntry? _installCenterOverlay;
  // UX-03: 各弹窗动画包装器的 key，用于触发退场动画
  // 每次 show 时新建 key，避免快速重开导致 GlobalKey 冲突
  GlobalKey<AnimatedOverlayState>? _authOverlayKey;
  GlobalKey<AnimatedOverlayState>? _settingsOverlayKey;
  GlobalKey<AnimatedOverlayState>? _paymentOverlayKey;
  GlobalKey<AnimatedOverlayState>? _installCenterOverlayKey;
  bool _isSidebarCollapsed = MainContainer.initialSidebarCollapsed;

  // 后台持久化的批量导入控制器（整个应用生命周期内保持不变）
  late BatchImportController _batchImportController;

  /// ★ 离线模式：记录上次网络状态，用于检测转换并显示 snackbar。
  bool? _wasOnline;

  @override
  void initState() {
    super.initState();

    // ★ 离线模式：监听网络状态转换 + 接管后台 401 强制登出
    _wasOnline = NetworkStatusService.instance.isOnline;
    NetworkStatusService.instance.addListener(_onNetworkChanged);
    AuthService.onForceLogout = _onForceLogout;

    // 初始化批量导入控制器（只创建一次，不会因页面切换而销毁）
    _batchImportController = BatchImportController(
      onGameAdded: () {
        debugPrint('[BATCH] 全局：游戏入库完成 → 刷新库页');
        setState(() {});
      },
      onError: (message) {
        debugPrint('[BATCH] 全局错误: $message');
        // 可以在这里添加全局错误提示（如Toast）
      },
      onSuccess: (message) {
        debugPrint('[BATCH] 全局成功: $message');
      },
      onInfo: (message) {
        debugPrint('[BATCH] 全局信息: $message');
      },
    );

    _loadCurrentUser();
    _loadSidebarState();
  }

  @override
  void dispose() {
    NetworkStatusService.instance.removeListener(_onNetworkChanged);
    AuthService.onForceLogout = null;
    super.dispose();
  }

  /// ★ 网络状态转换处理：跳过初始值；在线↔离线时显示 snackbar 并同步。
  void _onNetworkChanged() {
    if (!mounted) return;
    final online = NetworkStatusService.instance.isOnline;
    // 跳过初始值（initState 中已记录，首次回调视为初始）
    if (_wasOnline == null) {
      _wasOnline = online;
      return;
    }
    if (online == _wasOnline) return;

    if (online) {
      AppSnackBar.success(context, '网络已恢复');
      _syncAfterRecovery();
    } else {
      AppSnackBar.warning(context, '网络已断开，已切换到离线模式');
      // 离线时从本地缓存重新加载用户信息（getCurrentUser 会走离线路径）
      _loadCurrentUser();
    }
    _wasOnline = online;
    setState(() {}); // 触发重建（DiscoverPage/Sidebar 直接读 NetworkStatusService）
  }

  /// ★ 后台 token 验证返回 401/403（token 被吊销）时的强制登出回调。
  void _onForceLogout() {
    if (!mounted) return;
    AppSnackBar.warning(context, '登录已过期，请重新登录');
    _onLogout();
  }

  /// ★ 网络恢复后的同步：后台刷新 token + 重新加载用户信息。
  /// DiscoverPage 自身监听 NetworkStatusService，会自动刷新游戏列表。
  Future<void> _syncAfterRecovery() async {
    await AuthService.verifyTokenInBackground();
    await _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    debugPrint('[AUTH] MainContainer: 加载当前用户信息...');
    final user = await AuthService.getCurrentUser();
    if (mounted) {
      setState(() {
        _currentUser = user;
        if (user != null) _isLoggedIn = true;
      });
    }
    if (user != null) {
      await UserCacheService.saveUserInfo(
        userId: user.id,
        name: user.name,
        bio: user.bio,
        avatarUrl: user.hasAvatar ? user.avatarUrl : null,
        avatarBytes: user.avatarBytes,
      );
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _loadSidebarState() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('sidebar_collapsed');
    // ★ 同值守卫：首帧已用 initialSidebarCollapsed 正确渲染，同值不 setState 避免动画
    if (saved != null && saved != _isSidebarCollapsed && mounted) {
      setState(() => _isSidebarCollapsed = saved);
    }
  }

  void _onToggleSidebar() async {
    final newValue = !_isSidebarCollapsed;
    setState(() => _isSidebarCollapsed = newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sidebar_collapsed', newValue);
  }

  void _onPageChanged(NavPage page) {
    setState(() {
      _currentPage = page;
      _showDetailPage = false;
    });
  }

  void _onGoDiscover() {
    setState(() => _currentPage = NavPage.discover);
  }

  void _onGameTap(GameCardData game) {
    setState(() {
      _selectedGame = game;
      _showDetailPage = true;
    });
  }

  void _onDetailBack() {
    setState(() => _showDetailPage = false);
  }

  void _onGoToLibraryFromDetail() {
    debugPrint('[DETAIL] 前往库中查看（仅跳转，不触发入库）');
    setState(() {
      _showDetailPage = false;
      _currentPage = NavPage.library;
    });
  }

  void _onFloatingTaskTap() {
    debugPrint('[ACTION] 悬浮按钮点击 → 打开全局安装中心');
    _showInstallCenter();
  }

  void _showInstallCenter() {
    if (_installCenterOverlay != null) return;
    final key = GlobalKey<AnimatedOverlayState>();
    _installCenterOverlayKey = key;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        // InstallCenterPage 自带黑色遮罩，此处不再叠加遮罩
        barrierColor: Colors.transparent,
        dismissOnBarrierTap: false,
        enableScale: true,
        onDismissed: () {
          entry.remove();
          if (_installCenterOverlay == entry) _installCenterOverlay = null;
          if (_installCenterOverlayKey == key) _installCenterOverlayKey = null;
        },
        child: InstallCenterPage(
          onClose: _closeInstallCenter,
        ),
      ),
    );
    _installCenterOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeInstallCenter() {
    final key = _installCenterOverlayKey;
    _installCenterOverlay = null;
    _installCenterOverlayKey = null;
    key?.currentState?.dismiss();
  }

  /// ★ 统一启动入口：所有非库页双击的启动方式（主页/BPM/详情窗口经主页）
  /// 都通过 GameLaunchService.executeLaunch，与库页双击完全等价，
  /// 确保 exe 路径持久化、超分/转区/时长统计/桌面快捷方式全部生效（RC3）
  void _onLaunchGame(String gameTitle) async {
    debugPrint('[LAUNCH] MainContainer._onLaunchGame: "$gameTitle"');

    // 1. 查找游戏（含 scan 容错重试）
    var game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    if (game == null) {
      try {
        await LocalGameRegistry.instance.scan();
      } catch (e) {
        debugPrint('[LAUNCH] scan 重试异常: $e');
      }
      game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    }
    if (game == null) {
      if (mounted) {
        AppSnackBar.error(context, '未找到游戏：$gameTitle');
      }
      return;
    }

    // 2. 解析 exe 路径（优先 GameConfigManager，回退到 game.json launch_path）
    var exePath = await GameLaunchService.instance.resolveUserChoice(gameTitle);
    if (exePath == null && game.launchPath.isNotEmpty) {
      final resolved =
          GameDataFormat.resolveLaunchPath(game.launchPath, game.directoryPath);
      if (resolved.isNotEmpty && File(resolved).existsSync()) {
        exePath = resolved;
        debugPrint('[LAUNCH] 回退使用 game.json launch_path: $exePath');
      }
    }

    // 3. 走统一启动路径（与库页双击等价）
    if (exePath != null) {
      final result =
          await GameLaunchService.instance.executeLaunch(game, exePath);
      if (!result.success && mounted) {
        AppSnackBar.error(context, result.error ?? '无法启动「${game.title}」');
      }
    } else {
      // 无可用 exe 路径：提示用户从库页选择
      if (mounted) {
        AppSnackBar.info(context, '请从游戏库中双击「${game.title}」选择启动程序');
      }
    }
  }

  void _onToggleGameMark(String gameTitle) {
    LocalGameRegistry.instance.toggleMark(gameTitle);
    setState(() {});
    debugPrint('[LIBRARY] 标记切换完成: $gameTitle');
  }

  void _onDeleteGame(String gameTitle) {
    bool deleteLocalFiles = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 1.5),
          ),
          title: Text(
            '确认删除',
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 22,
              letterSpacing: 1.5,
              color: AppColors.primaryText,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '确定要将《$gameTitle》从库中移除吗？',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  color: AppColors.primaryText,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                deleteLocalFiles
                    ? '⚠ 已勾选：将同时删除本地所有游戏文件，不可恢复。'
                    : '默认仅从库中移除记录，本地游戏文件保留不变。',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  color: deleteLocalFiles
                      ? AppColors.dangerRed
                      : AppColors.primaryText,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () {
                  setState(() {
                    deleteLocalFiles = !deleteLocalFiles;
                  });
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: deleteLocalFiles
                              ? AppColors.dangerRed
                              : AppColors.border,
                          width: 1.5,
                        ),
                        color: deleteLocalFiles
                            ? AppColors.dangerRed
                            : Colors.transparent,
                      ),
                      child: deleteLocalFiles
                          ? const Icon(Icons.check,
                              size: 14, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        '同时删除本地游戏文件',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          color: AppColors.primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                '取消',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.infoBlue,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop('confirm');
              },
              child: Text(
                '确认删除',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.dangerRed,
                ),
              ),
            ),
          ],
        ),
      ),
    ).then((result) async {
      if (result == null || result != 'confirm') return;
      final shouldDeleteFiles = deleteLocalFiles;

      bool success;
      if (shouldDeleteFiles) {
        success = await LocalGameRegistry.instance.deleteGame(gameTitle);
      } else {
        success =
            await LocalGameRegistry.instance.removeGameRecordOnly(gameTitle);
      }

      if (success) {
        debugPrint(
            '[删除] ${shouldDeleteFiles ? "已删除文件+数据" : "仅删除数据记录"}，调用setState()刷新库页');
      }
      if (mounted) {
        if (success) {
          AppSnackBar.success(context,
              '已删除游戏「$gameTitle」${shouldDeleteFiles ? "（含本地文件）" : ""}');
        } else {
          AppSnackBar.error(context, '删除失败，请检查文件是否被占用');
        }
        setState(() {});
      }
    });
  }

  void _onDeleteBatchGame(
      List<String> gameTitles, bool deleteLocalFiles) async {
    int successCount = 0;
    int failCount = 0;

    for (final title in gameTitles) {
      bool success;
      if (deleteLocalFiles) {
        success = await LocalGameRegistry.instance.deleteGame(title);
      } else {
        success = await LocalGameRegistry.instance.removeGameRecordOnly(title);
      }
      if (success) {
        successCount++;
      } else {
        failCount++;
      }
    }

    debugPrint(
        '[批量删除] 完成：${successCount}成功 ${failCount}失败，${deleteLocalFiles ? "含本地文件" : "仅记录"}');

    if (mounted) {
      if (failCount == 0) {
        AppSnackBar.success(context,
            '已删除 $successCount 个游戏${deleteLocalFiles ? "（含本地文件）" : ""}');
      } else {
        AppSnackBar.warning(
            context, '$successCount 个游戏删除成功，$failCount 个删除失败（请检查文件是否被占用）');
      }
      setState(() {});
    }
  }

  void _onUserTap() {
    debugPrint('[ACTION] 用户点击右下角用户按钮');
    _showAuthOverlay();
  }

  void _showAuthOverlay() {
    if (_authOverlay != null) return;
    final key = GlobalKey<AnimatedOverlayState>();
    _authOverlayKey = key;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          entry.remove();
          if (_authOverlay == entry) _authOverlay = null;
          if (_authOverlayKey == key) _authOverlayKey = null;
        },
        child: _isLoggedIn ? _buildProfileModal() : _buildAuthModal(),
      ),
    );
    _authOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeAuthOverlay() {
    final key = _authOverlayKey;
    _authOverlay = null;
    _authOverlayKey = null;
    key?.currentState?.dismiss();
  }

  void _onLoginSuccess() {
    debugPrint('[ACTION] 登录成功回调 → 设置登录态，加载用户数据');
    setState(() => _isLoggedIn = true);
    _loadCurrentUser();
  }

  void _onLogout() {
    debugPrint('[ACTION] 用户点击退出登录');
    _closeAuthOverlay();
    setState(() {
      _isLoggedIn = false;
      _currentUser = null;
    });
    widget.onLogout?.call();
  }

  Widget _buildAuthModal() {
    return AuthModal(
      onClose: _closeAuthOverlay,
      onLoginSuccess: _onLoginSuccess,
    );
  }

  Widget _buildProfileModal() {
    return UserProfileModal(
      onClose: _closeAuthOverlay,
      onLogout: _onLogout,
      onOpenSettings: _showSettingsOverlay,
      onCharge: _showPaymentOverlay,
      onOpenBigPicture: () {
        _closeAuthOverlay();
        BigPictureManager.instance.toggle();
      },
      user: _currentUser,
    );
  }

  void _showSettingsOverlay() {
    _closeAuthOverlay();
    if (_settingsOverlay != null) return;
    final key = GlobalKey<AnimatedOverlayState>();
    _settingsOverlayKey = key;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          entry.remove();
          if (_settingsOverlay == entry) _settingsOverlay = null;
          if (_settingsOverlayKey == key) _settingsOverlayKey = null;
        },
        child: SettingsModal(
            onClose: _closeSettingsOverlay,
            onBack: _settingsBackToProfile,
            onAvatarChanged: _loadCurrentUser),
      ),
    );
    _settingsOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeSettingsOverlay() {
    final key = _settingsOverlayKey;
    _settingsOverlay = null;
    _settingsOverlayKey = null;
    key?.currentState?.dismiss();
  }

  void _settingsBackToProfile() {
    _closeSettingsOverlay();
    // 等待退场动画(200ms)完成后再展示认证弹窗，避免两者同时出现
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _showAuthOverlay();
    });
  }

  void _showPaymentOverlay() {
    _closeAuthOverlay();
    if (_paymentOverlay != null) return;
    final key = GlobalKey<AnimatedOverlayState>();
    _paymentOverlayKey = key;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          entry.remove();
          if (_paymentOverlay == entry) _paymentOverlay = null;
          if (_paymentOverlayKey == key) _paymentOverlayKey = null;
        },
        child: PaymentModal(
            onClose: _closePaymentOverlay, onBack: _closePaymentOverlay),
      ),
    );
    _paymentOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closePaymentOverlay() {
    final key = _paymentOverlayKey;
    _paymentOverlay = null;
    _paymentOverlayKey = null;
    key?.currentState?.dismiss();
  }

  Widget _buildCurrentPage() {
    if (_showDetailPage && _selectedGame != null) {
      return GameDetailPage(
        gameId: _selectedGame!.id,
        onBack: _onDetailBack,
        onGoToLibrary: _onGoToLibraryFromDetail,
      );
    }

    switch (_currentPage) {
      case NavPage.home:
        return HomePage(
          onLaunchGame: _onLaunchGame,
          onGoToLibrary: () {
            setState(() => _currentPage = NavPage.library);
          },
          onToggleMark: _onToggleGameMark,
          onDelete: _onDeleteGame,
          onToggleBigPicture: () => BigPictureManager.instance.toggle(),
        );
      case NavPage.library:
        return LibraryPage(
          onGoDiscover: _onGoDiscover,
          onLaunchGame: _onLaunchGame,
          onToggleMark: _onToggleGameMark,
          onDelete: _onDeleteGame,
          onDeleteBatch: _onDeleteBatchGame,
          onRefresh: () {
            debugPrint('[LIBRARY] 删除后强制刷新库页');
            setState(() {});
          },
        );
      case NavPage.discover:
        return DiscoverPage(onGameTap: _onGameTap);
      case NavPage.join:
        return JoinPage(
          onGameAdded: () {
            debugPrint('[ADD] 入库成功 → 刷新库页');
            setState(() {});
          },
          // 传递全局持久化的批量导入控制器
          batchController: _batchImportController,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 顶层监听 BigPictureManager,根据模式切换外壳
    // AnimatedSwitcher 提供 250ms fade 过渡 (与 AppThemeManager 动画时长一致)
    return AnimatedBuilder(
      animation: BigPictureManager.instance,
      builder: (context, _) {
        final isActive = BigPictureManager.instance.isActive;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: KeyedSubtree(
            key: ValueKey(isActive ? 'bpm' : 'desktop'),
            child: isActive
                ? BigPictureShell(
                    currentUser: _currentUser,
                    onLaunchGame: _onLaunchGame,
                    onToggleMark: _onToggleGameMark,
                    onDelete: _onDeleteGame,
                    onExitBpm: () => BigPictureManager.instance.exit(),
                  )
                : _buildDesktopShell(),
          ),
        );
      },
    );
  }

  /// 桌面模式外壳 (原 build 逻辑)
  Widget _buildDesktopShell() {
    final sidebarWidth = _isSidebarCollapsed ? 71.0 : 224.0;

    return CustomTitleBar(
      child: SizedBox.expand(
        child: Container(
          clipBehavior: Clip.none,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RepaintBoundary(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Sidebar(
                      currentPage: _currentPage,
                      onPageChanged: _onPageChanged,
                      isCollapsed: _isSidebarCollapsed,
                      onToggle: _onToggleSidebar,
                    ),
                    Expanded(
                      child: AnimatedBuilder(
                        animation: AppThemeManager.instance,
                        builder: (context, _) {
                          // v3.0 P6 修复：背景图已移至 CustomTitleBar 全屏底层，
                          // 此处仅保留页面内容 + 悬浮按钮
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              _buildCurrentPage(),
                              FloatingUserButton(
                                  onTap: _onUserTap, user: _currentUser),
                              // [BugFix 白屏] 用 Positioned 包裹 FloatingTaskButton
                              // 原因:StackFit.expand 会让 non-positioned children 充满整个
                              // Stack;FloatingTaskButton.build 内部用了 AnimatedBuilder
                              // 包裹的 Positioned,而该 Positioned 找不到最近的 Stack 祖先
                              // (它在 AnimatedBuilder.builder 内部),导致 positioning 无效,
                              // 进而 RepaintBoundary 被 fit:expand 强制拉伸到整个内容区,
                              // 其内部的浅米色 Container (AppColors.background) 覆盖全屏
                              // 表现为"白屏"且拦截所有 hit test
                              // 现在:在 Stack 中直接用 Positioned 把 FloatingTaskButton
                              // 定位到 (left: 16, bottom: 16),作为 positioned child 不再
                              // 受 fit:expand 影响,FloatingTaskButton 内部继续用 RepaintBoundary
                              // + AnimatedBuilder + Opacity 即可
                              Positioned(
                                left: 16,
                                bottom: 16,
                                child: FloatingTaskButton(
                                    onTap: _onFloatingTaskTap),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // UX-08: 使用 AnimatedPositioned 实现侧边栏切换按钮的平滑过渡
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                left: sidebarWidth - (_isSidebarCollapsed ? 0 : 17),
                top: 0,
                bottom: 0,
                child: Center(
                  child: SidebarToggleWidget(
                    isLeft: !_isSidebarCollapsed,
                    onTap: _onToggleSidebar,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SidebarToggleWidget extends StatelessWidget {
  final bool isLeft;
  final VoidCallback onTap;

  const SidebarToggleWidget({
    super.key,
    required this.isLeft,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 17,
          height: 34,
          child: CustomPaint(
            painter: SemicirclePainter(
              isLeft: isLeft,
              // BUG-05: 传入主题颜色，替代硬编码
              fillColor: AppColors.toggleBg,
              borderColor: AppColors.toggleBorder,
              shadowColor: AppColors.shadowColor,
            ),
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(
                  left: isLeft ? 4 : 0,
                  right: isLeft ? 0 : 4,
                ),
                child: Icon(
                  isLeft ? Icons.chevron_left : Icons.chevron_right,
                  size: 16,
                  color: AppColors.toggleIcon,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
