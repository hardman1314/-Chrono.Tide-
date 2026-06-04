import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/backend_config.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../widgets/sidebar.dart';
import '../widgets/floating_user_button.dart';
import '../widgets/floating_task_button.dart';
import '../widgets/auth_modal.dart';
import '../widgets/user_profile_modal.dart';
import '../widgets/settings_modal.dart';
import '../widgets/payment_modal.dart';
import '../pages/library_page.dart';
import '../pages/discover_page.dart';
import '../pages/join_page.dart';
import '../pages/game_detail_page.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import '../services/local_game_registry.dart';
import '../services/user_cache_service.dart';
import '../pages/install_center_page.dart';
import '../pages/join/batch_import_controller.dart';

class MainContainer extends StatefulWidget {
  final VoidCallback? onLogout;
  final bool isLocalMode;
  const MainContainer({super.key, this.onLogout, this.isLocalMode = false});

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  NavPage _currentPage = NavPage.library;
  GameCardData? _selectedGame;
  bool _showDetailPage = false;
  bool _isLoggedIn = true;
  UserModel? _currentUser;
  OverlayEntry? _authOverlay;
  OverlayEntry? _settingsOverlay;
  OverlayEntry? _paymentOverlay;
  OverlayEntry? _installCenterOverlay;
  bool _isSidebarCollapsed = false;

  // 后台持久化的批量导入控制器（整个应用生命周期内保持不变）
  late BatchImportController _batchImportController;

  @override
  void initState() {
    super.initState();

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

  Future<void> _loadCurrentUser() async {
    debugPrint('[AUTH] MainContainer: 加载当前用户信息...');
    final user = await AuthService.getCurrentUser();
    if (mounted) {
      setState(() => _currentUser = user);
    }
    if (user != null && user.hasAvatar) {
      await UserCacheService.saveUserInfo(
        userId: user.id,
        name: user.name,
        bio: user.bio,
        avatarUrl: user.avatarUrl,
      );
    }
  }

  Future<void> _loadSidebarState() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('sidebar_collapsed');
    if (saved != null && mounted) {
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

    _installCenterOverlay = OverlayEntry(
      builder: (context) => InstallCenterPage(
        onClose: _closeInstallCenter,
      ),
    );
    Overlay.of(context).insert(_installCenterOverlay!);
  }

  void _closeInstallCenter() {
    _installCenterOverlay?.remove();
    _installCenterOverlay = null;
  }

  void _onLaunchGame(String gameTitle) async {
    final success = await LocalGameRegistry.instance.launchGame(gameTitle);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法启动游戏「$gameTitle」：未找到可执行文件'),
          duration: const Duration(seconds: 3),
        ),
      );
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
              fontFamily: 'Zhi Mang Xing',
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
                  fontFamily: 'Mali',
                  fontSize: 15,
                  color: const Color(0xFF6D5B4D),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                deleteLocalFiles
                    ? '⚠ 已勾选：将同时删除本地所有游戏文件，不可恢复。'
                    : '默认仅从库中移除记录，本地游戏文件保留不变。',
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13,
                  color: deleteLocalFiles
                      ? const Color(0xFFC0392B)
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
                              ? const Color(0xFFC0392B)
                              : AppColors.border,
                          width: 1.5,
                        ),
                        color: deleteLocalFiles
                            ? const Color(0xFFC0392B)
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
                          fontFamily: 'Mali',
                          fontSize: 14,
                          color: const Color(0xFF6D5B4D),
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
                  fontFamily: 'Mali',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF4A72A5),
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
                  fontFamily: 'Mali',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '已删除游戏「$gameTitle」${shouldDeleteFiles ? "（含本地文件）" : ""}'),
              duration: const Duration(seconds: 2),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('删除失败，请检查文件是否被占用'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        setState(() {});
      }
    });
  }

  void _onUserTap() {
    debugPrint('[ACTION] 用户点击右下角用户按钮');
    _showAuthOverlay();
  }

  void _showAuthOverlay() {
    if (_authOverlay != null) return;
    _authOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeAuthOverlay,
              child: Container(color: const Color(0x66000000)),
            ),
          ),
          Center(child: _isLoggedIn ? _buildProfileModal() : _buildAuthModal()),
        ],
      ),
    );
    Overlay.of(context).insert(_authOverlay!);
  }

  void _closeAuthOverlay() {
    _authOverlay?.remove();
    _authOverlay = null;
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
      user: _currentUser,
    );
  }

  void _showSettingsOverlay() {
    _closeAuthOverlay();
    if (_settingsOverlay != null) return;
    _settingsOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeSettingsOverlay,
              child: Container(color: const Color(0x66000000)),
            ),
          ),
          Center(
              child: SettingsModal(
                  onClose: _closeSettingsOverlay,
                  onBack: _settingsBackToProfile)),
        ],
      ),
    );
    Overlay.of(context).insert(_settingsOverlay!);
  }

  void _closeSettingsOverlay() {
    _settingsOverlay?.remove();
    _settingsOverlay = null;
  }

  void _settingsBackToProfile() {
    _closeSettingsOverlay();
    Future.delayed(const Duration(milliseconds: 100), () {
      _showAuthOverlay();
    });
  }

  void _showPaymentOverlay() {
    _closeAuthOverlay();
    if (_paymentOverlay != null) return;
    _paymentOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closePaymentOverlay,
              child: Container(color: const Color(0x66000000)),
            ),
          ),
          Center(
              child: PaymentModal(
                  onClose: _closePaymentOverlay, onBack: _closePaymentOverlay)),
        ],
      ),
    );
    Overlay.of(context).insert(_paymentOverlay!);
  }

  void _closePaymentOverlay() {
    _paymentOverlay?.remove();
    _paymentOverlay = null;
  }

  Widget _buildCurrentPage() {
    if (_showDetailPage && _selectedGame != null) {
      return GameDetailPage(
        gameId: _selectedGame!.id,
        onBack: _onDetailBack,
        onGoToLibrary: _onGoToLibraryFromDetail,
      );
    }

    // 如果是本地模式且选择了发现页，显示不可用提示
    if (widget.isLocalMode && _currentPage == NavPage.discover) {
      return _buildBackendUnavailableView();
    }

    switch (_currentPage) {
      case NavPage.library:
        return LibraryPage(
          onGoDiscover: _onGoDiscover,
          onLaunchGame: _onLaunchGame,
          onToggleMark: _onToggleGameMark,
          onDelete: _onDeleteGame,
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

  Widget _buildBackendUnavailableView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 24),
            Text(
              '在线功能暂不可用',
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              BackendConfig.unavailableMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 14,
                color: AppColors.secondaryText,
                height: 1.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sidebarWidth = _isSidebarCollapsed ? 71.0 : 224.0;

    return SizedBox.expand(
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
                    isLocalMode: widget.isLocalMode,
                  ),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: AppThemeManager.instance,
                      builder: (context, _) {
                        final themeData = AppThemeManager.instance.current;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (themeData.hasBackgroundImage)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Opacity(
                                    opacity: 0.85,
                                    child: Image.asset(
                                      themeData.backgroundImagePath!,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                        debugPrint(
                                            '[BG] 背景图加载失败: ${themeData.backgroundImagePath} | $error');
                                        return const SizedBox.shrink();
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            if (themeData.hasBackgroundImage)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [
                                          themeData.background.withOpacity(
                                              themeData
                                                  .backgroundOverlayOpacity),
                                          themeData.background.withOpacity(
                                              themeData
                                                      .backgroundOverlayOpacity *
                                                  0.6),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            _buildCurrentPage(),
                            FloatingUserButton(
                                onTap: _onUserTap, user: _currentUser),
                            FloatingTaskButton(onTap: _onFloatingTaskTap),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
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
            painter: SemicirclePainter(isLeft: isLeft),
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
                  weight: 700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
