import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'core/backend_config.dart';
import 'modules/auth/auth_service.dart';
import 'pages/login/login_page.dart';
import 'pages/register/register_page.dart';
import 'main_container.dart';
import 'services/openlist_service.dart';
import 'services/interrupt_cleanup.dart';
import 'services/process_cleanup_service.dart';
import 'services/local_game_registry.dart';
import 'services/user_cache_service.dart';
import 'services/game_data_migration.dart';
import 'services/update/update_service.dart';
import 'services/update/update_models.dart';
import 'services/download_core.dart';
import 'services/extract_manager.dart';
import 'services/metadata_fetcher.dart';
import 'widgets/update_dialog.dart';
import 'widgets/exit_overlay.dart';
import 'theme/app_theme_manager.dart';
import 'theme/app_colors.dart';

import 'app_log_helper.dart';

/// 单实例锁文件路径
final String _lockFilePath = () {
  final tempDir = Directory.systemTemp;
  return '${tempDir.path}/chrono_tide_instance.lock';
}();

/// 保持锁文件句柄打开，防止被其他进程抢占
RandomAccessFile? _instanceLockHandle;

/// 获取单实例锁，返回 true 表示获取成功（可启动），false 表示已有实例运行
bool _acquireSingleInstanceLock() {
  try {
    final lockFile = File(_lockFilePath);

    // 以写入模式打开，保持句柄不关闭 → 文件被本进程锁定
    _instanceLockHandle = lockFile.openSync(mode: FileMode.write);

    // 尝试获取排他锁（OS级别，Windows下其他进程无法同时获取）
    _instanceLockHandle!.lockSync(FileLock.exclusive);

    // 写入当前进程信息用于调试
    final pidStr = pid.toString();
    final info =
        'ChronoTide | PID: $pidStr | Locked at: ${DateTime.now().toIso8601String()}';
    _instanceLockHandle!.writeStringSync(info);

    debugPrint('[INIT] ✅ 单实例锁获取成功 | PID: $pidStr');
    return true;
  } on FileSystemException catch (e) {
    debugPrint('[INIT] ❌ 单实例锁获取失败（已有实例运行中）: ${e.message}');
    _instanceLockHandle = null;
    return false;
  } catch (e) {
    debugPrint('[INIT] ⚠️ 单实例锁检查异常: $e');
    _instanceLockHandle = null;
    return false;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 单实例锁：防止重复启动
  if (!_acquireSingleInstanceLock()) {
    debugPrint('[INIT] 检测到已运行的实例，退出当前启动');
    exit(0);
  }

  await AppLogHelper.initLog();
  setupGlobalCatchError();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  // ─── 后端可用性检测 ───
  // 在其他初始化之前先检测后端是否可用
  await BackendConfig.checkAvailability();
  if (BackendConfig.isBackendAvailable) {
    debugPrint('[INIT] ✅ 后端服务可用，所有功能已启用');
  } else {
    debugPrint('[INIT] ⚠️ 后端服务不可用，仅启用本地功能');
  }

  try {
    await InterruptCleanup.startupScan();
  } catch (e) {
    debugPrint('[INIT] 启动扫描异常: $e');
  }
  try {
    await GameDataMigration.migrateAll();
  } catch (e) {
    debugPrint('[INIT] 数据迁移异常: $e');
  }
  try {
    await LocalGameRegistry.instance.scan();
  } catch (e) {
    debugPrint('[INIT] 游戏库初始化异常: $e');
  }
  await windowManager.ensureInitialized();
  await ProcessCleanupService.initialize();
  await AppThemeManager.instance.loadSavedTheme();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    center: true,
    backgroundColor: Color(0xFFFDFBF7),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    minimumSize: Size(960, 540),
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  await UserCacheService.init();
  runApp(const ChronoTideApp());
}

Future<void> _showUpdateDialogIfNeeded() async {
  // 后端不可用时跳过更新检查
  if (!BackendConfig.isBackendAvailable) return;

  final result = await UpdateService.instance.checkForUpdate(silent: false);
  if (result.result != UpdateResult.updateAvailable) return;
  if (result.versionInfo == null) return;
  final ctx = UpdateService.instance.appContext;
  if (ctx == null || !ctx.mounted) return;
  UpdateDialog.show(
    ctx,
    currentVersion: result.localVersion ?? '0.0.0',
    newVersion: result.versionInfo!.latestVersion,
    updateLog: result.versionInfo!.updateLog,
    downloadUrl: result.versionInfo!.downloadUrl,
  );
}

class ChronoTideApp extends StatefulWidget {
  const ChronoTideApp({super.key});

  @override
  State<ChronoTideApp> createState() => _ChronoTideAppState();
}

class _ChronoTideAppState extends State<ChronoTideApp> {
  bool _isCheckingAuth = true;
  bool _isLoggedIn = false;
  bool _isBackendUnavailable = false; // 后端不可用标记
  AuthPage _authPage = AuthPage.login;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _checkAuthState();
    WidgetsBinding.instance.endOfFrame.then((_) async {
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        _showUpdateDialogIfNeeded();
      }
    });
  }

  Future<void> _checkAuthState() async {
    // ─── 后端不可用：直接进入主界面（免登录） ───
    if (!BackendConfig.isBackendAvailable) {
      if (!mounted) return;
      setState(() {
        _isCheckingAuth = false;
        _isLoggedIn = false;
        _isBackendUnavailable = true;
      });
      debugPrint('[AUTH] 后端不可用，跳过登录，直接进入主界面（本地模式）');
      return;
    }

    // ─── 后端可用：正常认证流程 ───
    final isValid = await AuthService.checkAutoLogin();
    if (!mounted) return;
    setState(() {
      _isCheckingAuth = false;
      _isLoggedIn = isValid;
    });
    if (_isLoggedIn) {
      OpenListService.boot();
    }
  }

  void _onLoginSuccess() {
    setState(() => _isLoggedIn = true);
  }

  void _goToRegister() {
    setState(() => _authPage = AuthPage.register);
  }

  void _goToLogin() {
    setState(() => _authPage = AuthPage.login);
  }

  Future<void> _handleLogout() async {
    await AuthService.logout();
    setState(() {
      _isLoggedIn = false;
      _authPage = AuthPage.login;
    });
  }

  ThemeData _buildThemeData(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Mali',
      brightness: brightness,
      scaffoldBackgroundColor: AppColors.pageBackground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF8B7355),
        brightness: brightness,
      ),
      dialogBackgroundColor: AppColors.background,
      dividerColor: AppColors.borderLight,
      hintColor: AppColors.inputHint,
      primaryColor: AppColors.border,
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: AppColors.primaryText),
        bodyMedium: TextStyle(color: AppColors.primaryText),
        bodySmall: TextStyle(color: AppColors.secondaryText),
        labelLarge: TextStyle(color: AppColors.primaryText),
        labelMedium: TextStyle(color: AppColors.secondaryText),
        titleLarge: TextStyle(color: AppColors.primaryText),
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(color: AppColors.inputHint),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.borderLight),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.border),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppThemeManager.instance,
      builder: (context, _) {
        final theme = AppThemeManager.instance.current;
        return MaterialApp(
          title: 'Chrono Tide',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: _buildThemeData(Brightness.light),
          darkTheme: _buildThemeData(Brightness.dark),
          themeMode: theme.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.0)),
              child: Stack(
                children: [
                  child!,
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _GlobalTitleBar(),
                  ),
                ],
              ),
            );
          },
          home: Builder(
            builder: (context) {
              UpdateService.instance.appContext = context;
              return Scaffold(
                backgroundColor: AppColors.pageBackground,
                body: _buildBody(),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    if (_isCheckingAuth) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(height: 16),
            Text(
              '正在连接服务器...',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: AppColors.secondaryText),
            ),
          ],
        ),
      );
    }

    // ─── 后端不可用：直接进入主界面（本地模式） ───
    if (_isBackendUnavailable) {
      return MainContainer(
        onLogout: _handleLogout,
        isLocalMode: true, // 通知主容器处于本地模式
      );
    }

    if (_isLoggedIn) {
      return MainContainer(onLogout: _handleLogout);
    }
    switch (_authPage) {
      case AuthPage.login:
        return LoginPage(
            onLoginSuccess: _onLoginSuccess, onGoRegister: _goToRegister);
      case AuthPage.register:
        return RegisterPage(
            onRegisterSuccess: _onLoginSuccess, onGoLogin: _goToLogin);
    }
  }
}

/// 全局标题栏组件
class _GlobalTitleBar extends StatefulWidget {
  @override
  State<_GlobalTitleBar> createState() => _GlobalTitleBarState();
}

class _GlobalTitleBarState extends State<_GlobalTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isHoveringMinimize = false;
  bool _isHoveringMaximize = false;
  bool _isHoveringClose = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initWindow();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initWindow() async {
    _isMaximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  Future<void> _onMinimize() async => await windowManager.minimize();

  Future<void> _onMaximize() async {
    if (_isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _onClose() async {
    final dlActive = DownloadCore.hasActiveTask;
    final extActive = ExtractManager.hasActiveTask;

    if (dlActive || extActive) {
      final ctx = context;
      if (!ctx.mounted) return;

      final taskName = extActive ? '解压' : '下载';
      final result = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFFFDFBF7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF8B7355), width: 2),
          ),
          title: Text(
            '正在$taskName',
            style: const TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 22,
              letterSpacing: 1.5,
              color: Color(0xFF8B7355),
            ),
          ),
          content: Text(
            '当前有任务正在进行，退出将取消$taskName\n并删除已产生的临时文件，确定要退出吗？',
            style: const TextStyle(
              fontFamily: 'Mali',
              fontSize: 15,
              color: Color(0xFF6D5B4D),
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                '继续$taskName',
                style: TextStyle(
                  color: Color(0xFF4A72A5),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                '确认退出',
                style: TextStyle(
                  color: Color(0xFFD4183D),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      );

      if (result != true) return;
    }

    await _performCleanupAndExit();
  }

  Future<void> _performCleanupAndExit() async {
    ExitOverlay.show(context);

    await Future.delayed(const Duration(milliseconds: 300));

    try {
      await ProcessCleanupService.cleanupAll();
    } catch (e) {
      debugPrint('[EXIT] ProcessCleanupService.cleanupAll error: $e');
    }

    try {
      MetadataFetcher.clearCache();
    } catch (e) {
      debugPrint('[EXIT] ⚠️ 清空缓存时出错: $e');
    }

    try {
      await InterruptCleanup.cleanupAll();
    } catch (e) {
      debugPrint('[EXIT] InterruptCleanup.cleanupAll error: $e');
    }

    try {
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[EXIT] windowManager.destroy error: $e');
    }

    await Future.delayed(const Duration(milliseconds: 800));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (details) => windowManager.startDragging(),
              onDoubleTap: _onMaximize,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.titleBarBackground,
                  border: Border(
                    bottom: BorderSide(color: AppColors.borderLight, width: 1),
                  ),
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.titleBarBackground,
              border: Border(
                bottom: BorderSide(color: AppColors.borderLight, width: 1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildWindowButton(
                  icon: Icons.horizontal_rule_rounded,
                  isHovered: _isHoveringMinimize,
                  onEnter: () => setState(() => _isHoveringMinimize = true),
                  onExit: () => setState(() => _isHoveringMinimize = false),
                  onTap: _onMinimize,
                ),
                _buildWindowButton(
                  icon: _isMaximized
                      ? Icons.copy_outlined
                      : Icons.crop_square_outlined,
                  isHovered: _isHoveringMaximize,
                  onEnter: () => setState(() => _isHoveringMaximize = true),
                  onExit: () => setState(() => _isHoveringMaximize = false),
                  onTap: _onMaximize,
                ),
                _buildWindowButton(
                  icon: Icons.close_rounded,
                  isHovered: _isHoveringClose,
                  onEnter: () => setState(() => _isHoveringClose = true),
                  onExit: () => setState(() => _isHoveringClose = false),
                  onTap: _onClose,
                  isClose: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowButton({
    required IconData icon,
    required bool isHovered,
    required VoidCallback onEnter,
    required VoidCallback onExit,
    required VoidCallback onTap,
    bool isClose = false,
  }) {
    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 40,
          alignment: Alignment.center,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26843500),
              color: isHovered
                  ? (isClose
                      ? const Color(0x1AD4183D)
                      : AppColors.buttonBackground.withOpacity(0.5))
                  : Colors.transparent,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 14,
              color: isClose && isHovered
                  ? AppColors.dangerRed
                  : const Color(0xFF666666),
            ),
          ),
        ),
      ),
    );
  }
}

enum AuthPage { login, register }
