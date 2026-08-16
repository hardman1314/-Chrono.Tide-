import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'modules/auth/auth_service.dart';
import 'pages/login/login_page.dart';
import 'pages/register/register_page.dart';
import 'main_container.dart';
import 'services/openlist_service.dart';
import 'services/interrupt_cleanup.dart';
import 'services/process_cleanup_service.dart';
import 'services/local_game_registry.dart';
import 'services/game_launch_service.dart';
import 'services/game_data_format.dart';
import 'services/metadata_fetcher.dart';
import 'services/discover_metadata_service.dart';
import 'services/screenshot_fetch_service.dart';
import 'services/user_cache_service.dart';
import 'services/network_status_service.dart';
import 'services/game_data_migration.dart';
import 'services/magpie_service.dart';
import 'services/manifest_service.dart';
import 'services/update/update_service.dart';
import 'services/update/update_models.dart';
import 'services/tray_service.dart';
import 'services/app_state.dart';
import 'services/watch_folder_service.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/update_dialog.dart';
import 'theme/app_theme_manager.dart';
import 'theme/app_colors.dart';

import 'app_log_helper.dart';
import 'core/path_helper.dart';
import 'core/portable_shared_preferences_store.dart';
import 'services/storage/migration_orchestrator.dart';
import 'services/storage/log_rotation_service.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// 单实例锁文件路径
/// 优先存放在安装目录 data/lock/（便携化，不占系统盘）；
/// 安装目录只读（如 Program Files）时回退系统临时目录。
final String _lockFilePath = PathHelper.isPortableWritableSync
    ? PathHelper.lockFilePath
    : '${Directory.systemTemp.path}/chrono_tide_instance.lock';

/// 启动请求文件目录（用于快捷方式启动时与已运行实例通信）
/// 与锁文件同目录策略，保证多实例间通信路径一致。
final String _launchRequestDir = PathHelper.isPortableWritableSync
    ? PathHelper.launchRequestDir
    : '${Directory.systemTemp.path}/chrono_tide_launch_requests';

/// 保持锁文件句柄打开，防止被其他进程抢占
RandomAccessFile? _instanceLockHandle;

/// 检查指定 PID 是否仍在运行（Windows: tasklist）
bool _isProcessAlive(int processId) {
  if (processId <= 0) return false;
  try {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'PID eq $processId', '/NH'],
    );
    final output = result.stdout.toString();
    // tasklist 在进程不存在时输出 "信息: 没有运行的任务匹配指定标准"（中文系统）
    // 或 "INFO: No tasks are running which match the specified criteria."（英文系统）
    // 进程存在时输出格式为 "chrono_tide.exe  12345 Console  ..."
    if (output.contains('No tasks') || output.contains('没有运行')) {
      return false;
    }
    // 检查输出中是否包含该 PID（使用字符串插值构造正则，注意 \b 需要转义）
    return output.contains(RegExp('\\b$processId\\b'));
  } catch (_) {
    // tasklist 执行失败时，保守起见认为进程可能存活
    return true;
  }
}

/// 从锁文件内容中解析 PID
/// 锁文件格式: "ChronoTide | PID: 12345 | Locked at: 2026-..."
int _parsePidFromLockFile(String content) {
  final match = RegExp(r'PID:\s*(\d+)').firstMatch(content);
  if (match == null) return -1;
  return int.tryParse(match.group(1)!) ?? -1;
}

/// 获取单实例锁，返回 true 表示获取成功（可启动），false 表示已有实例运行
///
/// 包含僵尸锁检测：如果锁文件存在但持有锁的进程已死亡（异常退出），
/// 会自动清理僵尸锁并重新获取，防止软件异常退出后无法再次启动
bool _acquireSingleInstanceLock() {
  final lockFile = File(_lockFilePath);

  // 步骤1：获取锁之前先检查僵尸锁（避免 FileMode.write 截断文件导致误判）
  // 仅当锁文件存在时才检查，避免首次启动的多余开销
  if (lockFile.existsSync()) {
    String? lockContent;
    try {
      lockContent = lockFile.readAsStringSync();
    } catch (_) {
      // 读取失败，忽略，后续获取锁时会处理
    }

    if (lockContent != null && lockContent.isNotEmpty) {
      final pidInLock = _parsePidFromLockFile(lockContent);
      if (pidInLock > 0 && pidInLock != pid) {
        if (!_isProcessAlive(pidInLock)) {
          // 僵尸锁：持有锁的进程已死亡，清理锁文件
          debugPrint('[INIT] 🧹 检测到僵尸锁（PID: $pidInLock 已死亡），清理中...');
          try {
            lockFile.deleteSync();
          } catch (_) {
            // 删除失败可能是因为文件被锁定（实际仍有活动进程），忽略
          }
        }
      }
    }
  }

  // 步骤2：尝试打开文件并获取独占锁
  try {
    _instanceLockHandle = lockFile.openSync(mode: FileMode.write);
    _instanceLockHandle!.lockSync(FileLock.exclusive);
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

/// 从命令行参数中解析 --launch-game 的值
String? _parseLaunchGameArg(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--launch-game=')) {
      String value = arg.substring('--launch-game='.length);
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      return value.isNotEmpty ? value : null;
    }
    if (arg == '--launch-game' && i + 1 < args.length) {
      String value = args[i + 1];
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      return value.isNotEmpty ? value : null;
    }
  }
  return null;
}

/// 写入启动请求文件（当已有实例运行时，通过文件通知已运行实例启动游戏）
/// 使用唯一文件名避免并发写入覆盖
void _writeLaunchRequest(String gameTitle) {
  try {
    final dir = Directory(_launchRequestDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final request = {
      'action': 'launch_game', // 标识请求类型，兼容 checkLaunchRequest 新逻辑
      'game_title': gameTitle,
      'timestamp': DateTime.now().toIso8601String(),
      'pid': pid,
    };
    // 使用 PID + 时间戳确保文件名唯一
    final fileName = 'req_${pid}_${DateTime.now().millisecondsSinceEpoch}.json';
    File('$_launchRequestDir/$fileName').writeAsStringSync(jsonEncode(request));
    debugPrint('[LAUNCH] ✅ 已写入启动请求文件: $gameTitle -> $fileName');
  } catch (e) {
    debugPrint('[LAUNCH] ❌ 写入启动请求文件失败: $e');
  }
}

/// 写入"显示窗口"请求文件（当已有实例运行时，通知已运行实例显示主窗口）
/// 用于双击桌面图标时恢复托盘隐藏的窗口
void _writeShowWindowRequest() {
  try {
    final dir = Directory(_launchRequestDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final request = {
      'action': 'show_window', // 显示窗口请求
      'timestamp': DateTime.now().toIso8601String(),
      'pid': pid,
    };
    final fileName =
        'show_${pid}_${DateTime.now().millisecondsSinceEpoch}.json';
    File('$_launchRequestDir/$fileName').writeAsStringSync(jsonEncode(request));
    debugPrint('[SHOW-WINDOW] ✅ 已写入显示窗口请求文件: $fileName');
  } catch (e) {
    debugPrint('[SHOW-WINDOW] ❌ 写入显示窗口请求文件失败: $e');
  }
}

/// 主题切换时动态更新窗口背景色
///
/// 修复 4K/高 DPI 下的视觉问题：
/// - 窗口背景色 (WindowOptions.backgroundColor) 在窗口创建时确定
/// - 切换暗色/亮色主题时，如果不更新窗口背景色，窗口边缘会露出旧主题色
/// - 在 4K + 高 DPI 缩放下，这个色差会被放大，显示为明显的白边/黑边
void _onThemeChangedForWindow() {
  try {
    final windowBgColor = AppThemeManager.instance.current.background;
    windowManager.setBackgroundColor(windowBgColor);
  } catch (e) {
    debugPrint('[WINDOW] 更新窗口背景色异常: $e');
  }
}

/// 检查并处理所有启动请求文件（供已运行实例调用）
/// 扫描请求目录，处理所有请求文件
/// 返回包含 action 和 game_title 的 Map：
///   - {'action': 'show_window'} —— 显示窗口请求
///   - {'action': 'launch_game', 'game_title': 'xxx'} —— 启动游戏请求
/// 旧格式（无 action 字段）默认按 launch_game 处理，保持向后兼容
Future<Map<String, dynamic>?> checkLaunchRequest() async {
  try {
    final dir = Directory(_launchRequestDir);
    if (!await dir.exists()) return null;

    final files = await dir.list().toList();
    if (files.isEmpty) return null;

    Map<String, dynamic>? lastRequest;

    for (final entity in files) {
      if (entity is! File) continue;
      try {
        final content = await entity.readAsString();
        // 先删除文件，再解析，避免解析失败导致无限重试
        await entity.delete();
        final data = jsonDecode(content) as Map<String, dynamic>;

        // 兼容旧格式：无 action 字段时默认为 launch_game
        final action = (data['action'] as String?) ?? 'launch_game';
        final gameTitle = data['game_title'] as String?;

        if (action == 'show_window') {
          // 显示窗口请求
          lastRequest = {'action': 'show_window'};
        } else if (gameTitle != null && gameTitle.isNotEmpty) {
          // 启动游戏请求
          lastRequest = {'action': 'launch_game', 'game_title': gameTitle};
        }
      } catch (e) {
        debugPrint('[LAUNCH] 处理请求文件异常，已删除: $e');
        try {
          await entity.delete();
        } catch (_) {}
      }
    }

    return lastRequest;
  } catch (e) {
    debugPrint('[LAUNCH] 检查启动请求文件异常: $e');
    return null;
  }
}

/// 从命令行参数中解析 --silent 标志
bool _parseSilentArg(List<String> args) {
  return args.any((arg) => arg == '--silent' || arg == '-s');
}

/// 便携化存储初始化：将 SharedPreferences 与缓存重定向到软件安装目录，
/// 并无感迁移老用户在系统 C 盘的数据。
///
/// 时序关键：必须在任何 `SharedPreferences.getInstance()` 调用之前完成
/// store 替换（首次 getInstance 会缓存 store 数据，之后再替换无效）。
/// 仅在安装目录可写时执行；只读目录降级为默认行为（数据存系统目录）。
///
/// 此函数须在单实例锁获取成功后调用，保证仅主实例执行迁移。
Future<void> _initializePortableStorage() async {
  try {
    if (!await PathHelper.isPortableWritable()) {
      debugPrint('[INIT] 安装目录不可写，便携化降级（数据存系统目录）');
      return;
    }
    await PathHelper.ensurePortableDirs();

    // Phase A：store 替换前迁移 prefs 文件（整文件复制，格式兼容）
    await MigrationOrchestrator.migratePrefsFile();

    // 替换 SharedPreferences 后端为便携式实现
    // 透明重定向全应用 SharedPreferences.getInstance() 调用点至安装目录
    SharedPreferencesStorePlatform.instance =
        PortableSharedPreferencesStore(File(PathHelper.prefsFilePath));
    debugPrint('[INIT] SharedPreferences 已重定向至 ${PathHelper.prefsFilePath}');

    // Phase B：迁移其余存储单元（游戏配置/主题/背景图/图片缓存），校验后删旧
    final result =
        await MigrationOrchestrator.run(deleteOldAfterMigration: true);
    for (final unit in result.units) {
      debugPrint(
          '[MIGRATION] ${unit.id}: ${unit.status.name} - ${unit.message}');
    }
  } catch (e, stack) {
    // 初始化失败不阻断启动，降级为默认存储行为
    debugPrint('[INIT] 便携化存储初始化异常(忽略，继续启动): $e\n$stack');
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 解析命令行参数
  final launchGameTitle = _parseLaunchGameArg(args);
  final isSilent = _parseSilentArg(args);
  // ★ 静默模式：仅开机自启（--silent）时静默
  // --launch-game 不触发静默模式，软件正常显示窗口后再启动游戏
  isSilentMode = isSilent;

  if (launchGameTitle != null) {
    debugPrint('[INIT] 🎮 检测到快捷启动请求: $launchGameTitle');

    // 尝试获取单实例锁
    if (!_acquireSingleInstanceLock()) {
      // 已有实例运行 → 写入启动请求文件并退出
      // 已运行实例会检测到请求文件，启动游戏并显示窗口
      debugPrint('[INIT] 已有实例运行，写入启动请求文件');
      _writeLaunchRequest(launchGameTitle);
      exit(0);
    }

    // 获取到锁 → 软件未运行，作为独立实例启动
    // ★ 关键改动：不再静默启动，软件正常显示窗口
    debugPrint('[INIT] 快捷启动：软件正常显示，初始化完成后自动启动游戏');
  } else {
    // 正常启动或静默启动
    if (!_acquireSingleInstanceLock()) {
      // ★ 已有实例运行 → 写入"显示窗口"请求文件并退出
      // 已运行实例的 _startLaunchRequestChecker 会检测到请求，
      // 将窗口从托盘隐藏状态恢复显示
      // （解决"托盘隐藏状态下双击桌面图标无响应"问题）
      debugPrint('[INIT] 检测到已运行的实例，写入显示窗口请求后退出');
      _writeShowWindowRequest();
      exit(0);
    }
  }

  // 便携化存储初始化（须在单实例锁获取后、首次 SharedPreferences 使用前）
  await _initializePortableStorage();

  // 以下为统一的完整初始化流程（无论是否快捷启动）
  await AppLogHelper.initLog();
  setupGlobalCatchError();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  try {
    await InterruptCleanup.startupScan();
  } catch (e) {
    debugPrint('[INIT] 启动扫描异常: $e');
  }
  // 启动时执行日志轮转,清理旧日志避免无限增长
  try {
    await LogRotationService.instance.rotateAll();
  } catch (e) {
    debugPrint('[INIT] 日志轮转异常: $e');
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
  // ★ v2: 加载追踪模式（playtime/elapsed），必须在启动游戏前
  try {
    await LocalGameRegistry.instance.loadTrackingMode();
  } catch (e) {
    debugPrint('[INIT] 加载追踪模式失败: $e');
  }
  // 扫描恢复未完成的截图下载任务（应用崩溃或异常退出后自动恢复）
  try {
    await ScreenshotFetchService.instance.scanPendingGames();
  } catch (e) {
    debugPrint('[INIT] 截图任务恢复异常: $e');
  }
  // ★ v2: 恢复未正常结束的游戏会话（应用崩溃后游戏仍在运行时）
  try {
    await LocalGameRegistry.instance.recoverPendingSessions();
  } catch (e) {
    debugPrint('[INIT] 会话恢复异常: $e');
  }
  await windowManager.ensureInitialized();
  await ProcessCleanupService.initialize();
  await AppThemeManager.instance.loadSavedTheme();

  // ★ 先初始化托盘，再设置窗口
  // 确保托盘在窗口隐藏前就已就绪，用户能立即看到托盘图标
  await TrayService.instance.init();
  debugPrint('[INIT] 托盘初始化完成，静默模式: $isSilentMode');

  // 修复 UX-33：窗口背景色从硬编码改为根据当前主题动态设置，避免切换暗色主题时白色闪烁
  final windowBgColor = AppThemeManager.instance.current.background;
  WindowOptions windowOptions = WindowOptions(
    size: const Size(1280, 720),
    center: true,
    backgroundColor: windowBgColor,
    skipTaskbar: isSilentMode,
    titleBarStyle: TitleBarStyle.hidden,
    minimumSize: const Size(960, 540),
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // 修复 4K/高 DPI 白边问题：完全移除 Windows 窗口边框 (WS_THICKFRAME)
    // titleBarStyle.hidden 只隐藏标题栏,不移除可调整大小的边框
    // 在 4K + 200% 缩放下,WS_THICKFRAME 边框会显示为 2-3px 的白色边
    await windowManager.setAsFrameless();
    if (isSilentMode) {
      // 静默模式：不显示窗口
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    } else {
      userRequestedWindow = true;
      await windowManager.show();
      await windowManager.focus();
    }
  });

  // 修复主题切换时窗口背景色不同步：监听主题变化,动态更新窗口背景色
  // 避免切换暗色/亮色主题时,窗口边缘露出旧主题色 (在 4K 高 DPI 下尤其明显)
  AppThemeManager.instance.addListener(_onThemeChangedForWindow);

  // 防止窗口关闭时直接退出（改为最小化到托盘）
  await windowManager.setPreventClose(true);

  await UserCacheService.init();
  // ★ 网络状态服务初始化（非阻塞：乐观默认在线，后台异步探测 /api/health）
  // 必须在 checkAutoLogin 之前完成，供其判断是否跳过后台 token 验证。
  await NetworkStatusService.instance.init();
  await MagpieService.instance.init();

  // ★ 存档清单服务初始化：加载 Ludusavi manifest（5万+ 游戏存档路径数据）
  // 本地 asset 加载，不依赖网络。失败时 ManifestService 内部降级为未就绪状态，
  // 存档扫描器会回退到通用检测，不影响应用启动。
  await ManifestService.instance.init();

  // ★ 同步注入侧边栏初始收起状态，避免首帧展开→异步收起的启动抽搐
  // （SharedPreferences 实例已由 UserCacheService.init 缓存，此处 await 即时返回）
  final _sidebarPrefs = await SharedPreferences.getInstance();
  MainContainer.initialSidebarCollapsed =
      _sidebarPrefs.getBool('sidebar_collapsed') ?? false;

  // ★ 修复：初始化元数据抓取器
  // 必须在应用启动时调用，否则 VNDB 大字典（~3000 条中文翻译）不会加载，
  // 导致 VNDB 英文标签只能用 ~200 条兜底表翻译，大量英文标签漏译。
  // 同时加载数据源配置、代理设置、磁盘缓存。
  try {
    await MetadataFetcher.init();
    debugPrint('[INIT] ✅ 元数据抓取器初始化完成（VNDB 字典 + 数据源 + 缓存）');
  } catch (e) {
    debugPrint('[INIT] ⚠️ 元数据抓取器初始化异常: $e');
  }

  // ★ 阶段3.4：初始化探索页元数据服务（7 天磁盘缓存）
  // 必须在 MetadataFetcher 之后调用：依赖其已加载的代理配置与数据源
  // 加载失败不阻塞启动，最坏情况是探索页/详情页不显示评分角标
  try {
    await DiscoverMetadataService.instance.init();
    debugPrint('[INIT] ✅ 探索页元数据服务初始化完成');
  } catch (e) {
    debugPrint('[INIT] ⚠️ 探索页元数据服务初始化异常: $e');
  }

  // 启动文件夹监控服务（智能自动导入）
  await WatchFolderService.instance.startAll();

  runApp(ChronoTideApp(pendingLaunchGame: launchGameTitle));
}

Future<void> _showUpdateDialogIfNeeded() async {
  // 清理上次更新遗留的安装包缓存（安装程序运行期间无法删除，需在新版本启动时延迟清理）
  await UpdateService.instance.cleanupOldInstallerCache();

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
  /// 快捷启动时待启动的游戏标题（通过 --launch-game 参数传入）
  /// 软件初始化完成后自动启动该游戏
  final String? pendingLaunchGame;

  const ChronoTideApp({super.key, this.pendingLaunchGame});

  @override
  State<ChronoTideApp> createState() => _ChronoTideAppState();
}

class _ChronoTideAppState extends State<ChronoTideApp> with WindowListener {
  bool _isCheckingAuth = true;
  bool _isLoggedIn = false;
  AuthPage _authPage = AuthPage.login;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  Timer? _launchRequestTimer;

  /// ★ M11: 快捷方式启动请求的并发保护标志
  /// 防止定时器 500ms 周期触发时，上一次 _launchGameByTitle 尚未完成就启动下一次。
  /// 与 GameLaunchService._isLaunching 互为防御纵深：
  /// - 本标志：避免 main.dart 层重复弹错误对话框（"正在启动中..."）
  /// - Service 层：作为最终保险，跨进程/跨页面也生效
  bool _isLaunching = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _checkAuthState();
    _startLaunchRequestChecker();
    WidgetsBinding.instance.endOfFrame.then((_) async {
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        _showUpdateDialogIfNeeded();
      }
      // ★ 快捷启动：软件初始化完成后自动启动游戏
      if (widget.pendingLaunchGame != null) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) {
          _launchPendingGame();
        }
      }
    });
  }

  /// 显示快捷启动失败的错误对话框
  ///
  /// 用户偏好详细的错误信息，因此对话框承载完整错误类型 + 技术细节 +
  /// 针对性建议，而非简短 SnackBar。冷启动期间也能用 navigatorKey 弹出。
  Future<void> _showLaunchErrorDialog(
      String gameTitle, String errorTitle, String detail) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) {
      debugPrint('[LAUNCH] ⚠️ 无法显示错误对话框: $errorTitle - $detail');
      return;
    }
    await showDialog<void>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.red, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text('快捷启动失败 · $gameTitle',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(errorTitle,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(detail,
                style: TextStyle(fontSize: 12.5, color: Colors.grey[700])),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 启动快捷方式请求的游戏（统一入口）
  ///
  /// 走 [GameLaunchService.executeLaunch] 与 UI 双击路径完全等价，
  /// 确保 exe 路径持久化、超分/转区/时长统计全部生效，失败时弹错误对话框。
  ///
  /// ★ M11: 并发保护
  /// 定时器 _startLaunchRequestChecker 每 500ms 触发一次，可能在上一次
  /// _launchGameByTitle 完成前再次触发（executeLaunch 含 await 耗时）。
  /// 通过 _isLaunching 标志避免并发执行，防止重复弹错误对话框。
  Future<void> _launchGameByTitle(String title) async {
    if (_isLaunching) {
      debugPrint('[INIT] ⏭️ 快捷启动保护：上一次启动仍在进行中，跳过 "$title"');
      return;
    }
    _isLaunching = true;
    try {
      await _launchGameByTitleInternal(title);
    } finally {
      _isLaunching = false;
    }
  }

  Future<void> _launchGameByTitleInternal(String title) async {
    debugPrint('[INIT] 🎮 开始启动快捷方式请求的游戏: "$title"');
    debugPrint('[INIT] 当前内存中游戏数量: ${LocalGameRegistry.instance.gameCount}');

    // 1. 查找游戏（含 scan 容错重试）
    var game = LocalGameRegistry.instance.getGameByTitle(title);
    if (game == null) {
      try {
        await LocalGameRegistry.instance.scan();
      } catch (e) {
        debugPrint('[INIT] scan 重试异常: $e');
      }
      game = LocalGameRegistry.instance.getGameByTitle(title);
    }
    if (game == null) {
      debugPrint('[INIT] ❌ 无法启动游戏: scan 后仍未找到游戏记录: "$title"');
      await _showLaunchErrorDialog(
        title,
        '游戏未找到',
        '在游戏库中未找到「$title」，可能已被移除或重命名。请打开软件后从游戏库中重新启动。',
      );
      return;
    }

    // 2. 解析 exe 路径（与 UI 路径一致：优先 GameConfigManager，回退到 game.json）
    var exePath = await GameLaunchService.instance.resolveUserChoice(title);
    if (exePath == null && game.launchPath.isNotEmpty) {
      final resolved =
          GameDataFormat.resolveLaunchPath(game.launchPath, game.directoryPath);
      if (await File(resolved).exists()) {
        exePath = resolved;
        debugPrint('[INIT] 回退使用 game.json launch_path: $exePath');
      }
    }
    if (exePath == null) {
      debugPrint('[INIT] ❌ 无法确定启动程序: "$title"');
      await _showLaunchErrorDialog(
        title,
        '无法确定启动程序',
        '未找到「$title」的启动 exe 路径。请打开软件，双击游戏卡片，通过"启动管理"对话框选择启动程序。',
      );
      return;
    }

    // 3. 走统一启动路径（与 UI 双击等价：含 persistUserChoice + 超分/转区/时长统计）
    try {
      final result =
          await GameLaunchService.instance.executeLaunch(game, exePath);
      if (result.success) {
        debugPrint('[INIT] ✅ 快捷启动游戏成功: $title');
      } else {
        debugPrint('[INIT] ❌ 快捷启动游戏失败: $title (${result.error})');
        await _showLaunchErrorDialog(
          title,
          '启动失败',
          result.error ?? '未知错误',
        );
      }
    } catch (e, stack) {
      debugPrint('[INIT] ❌ 快捷启动游戏异常: $e');
      debugPrint('[INIT] 堆栈: $stack');
      await _showLaunchErrorDialog(title, '启动异常', '$e');
    }
  }

  /// 启动快捷方式请求的游戏（来自命令行 --launch-game 参数）
  Future<void> _launchPendingGame() async {
    final title = widget.pendingLaunchGame;
    if (title == null) return;
    await _launchGameByTitle(title);
  }

  @override
  void dispose() {
    _launchRequestTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() async {
    // ★ 核心：拦截 Windows 焦点窃取
    // 当游戏退出时，Windows 会自动激活 z-order 中的下一个窗口（我们的隐藏窗口）
    // 如果用户没有主动请求显示窗口，立即重新隐藏
    if (isSilentMode && !userRequestedWindow) {
      debugPrint('[WINDOW] 拦截焦点窃取，重新隐藏窗口');
      await windowManager.hide();
      // hide 完成后再次检查，防止期间用户主动请求显示
      if (userRequestedWindow) {
        await windowManager.show();
        await windowManager.focus();
      }
    }
  }

  @override
  void onWindowClose() async {
    // 窗口关闭按钮的处理已由 CustomTitleBar._onClose 接管
    // 这里仅作为兜底：如果 preventClose 未生效，直接隐藏到托盘
    debugPrint('[WINDOW] onWindowClose 触发，隐藏到托盘');
    await windowManager.hide();
    userRequestedWindow = false;
    await TrayService.instance.hideWindow();
  }

  /// 定时检查启动请求文件（当用户通过桌面快捷方式启动时，
  /// 新实例会写入请求文件并退出，本实例检测到后启动对应游戏）
  ///
  /// 支持两种请求类型：
  ///   - show_window：显示窗口请求（双击桌面图标恢复托盘隐藏窗口）
  ///   - launch_game：启动游戏请求（通过游戏快捷方式启动）
  void _startLaunchRequestChecker() {
    _launchRequestTimer =
        Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      final request = await checkLaunchRequest();
      if (request == null || !mounted) return;

      final action = (request['action'] as String?) ?? 'launch_game';

      // ★ 两种请求都需要先确保窗口可见
      // 用户双击图标意味着要使用软件，不应让窗口继续隐藏
      if (isSilentMode || !userRequestedWindow) {
        userRequestedWindow = true;
        isSilentMode = false;
        try {
          await windowManager.setSkipTaskbar(false);
          await windowManager.show();
          await windowManager.focus();
          debugPrint('[LAUNCH] 📨 已显示主窗口 (action: $action)');
        } catch (e) {
          debugPrint('[LAUNCH] 显示窗口异常: $e');
        }
      }

      // 如果是游戏启动请求，继续启动游戏
      if (action == 'launch_game') {
        final gameTitle = request['game_title'] as String;
        debugPrint('[LAUNCH] 🎮 收到快捷启动请求: "$gameTitle"');
        debugPrint(
            '[LAUNCH] 当前内存中游戏数量: ${LocalGameRegistry.instance.gameCount}');
        await _launchGameByTitle(gameTitle);
      }
    });
  }

  Future<void> _checkAuthState() async {
    final isValid = await AuthService.checkAutoLogin();
    if (!mounted) return;
    setState(() {
      _isCheckingAuth = false;
      _isLoggedIn = isValid;
    });
    if (_isLoggedIn) {
      // OpenList 改为按需启动，不再登录后自动启动
      // 当用户需要下载游戏时，OpenListService.ensureRunning() 会自动启动
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
    final themeColors = AppThemeManager.colors;
    // 修复 BUG-01：使用当前主题的 seedColor 动态生成 ColorScheme，
    // 使 Material 组件（Switch/Slider/Chip/Tab/Dialog 等）外观随主题切换而变化。
    // 同时覆盖关键语义令牌，确保 Material 组件与自定义 AppColors 保持一致。
    final colorScheme = ColorScheme.fromSeed(
      seedColor: themeColors.seedColor,
      brightness: brightness,
    ).copyWith(
      primary: themeColors.selectedAccent,
      onPrimary: themeColors.primaryText,
      secondary: themeColors.border,
      onSecondary: themeColors.primaryText,
      surface: themeColors.background,
      onSurface: themeColors.primaryText,
      error: themeColors.dangerRed,
      onError: themeColors.primaryText,
      outline: themeColors.border,
      outlineVariant: themeColors.borderLight,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      brightness: brightness,
      scaffoldBackgroundColor: AppColors.pageBackground,
      colorScheme: colorScheme,
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
            // 修复 BUG-03：移除强制禁用文本缩放的硬编码 TextScaler.linear(1.0)，
            // 允许无障碍用户使用系统文字缩放。为防止布局错乱，限制最大缩放为 1.3 倍。
            final mediaQuery = MediaQuery.of(context);
            final clampedScale =
                mediaQuery.textScaler.scale(1.0).clamp(0.85, 1.3);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(clampedScale),
              ),
              child: child!,
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
      return CustomTitleBar(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(height: 16),
              Text(
                '正在加载...',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.secondaryText),
              ),
            ],
          ),
        ),
      );
    }
    if (_isLoggedIn) {
      return MainContainer(onLogout: _handleLogout);
    }
    switch (_authPage) {
      case AuthPage.login:
        return CustomTitleBar(
          child: LoginPage(
              onLoginSuccess: _onLoginSuccess, onGoRegister: _goToRegister),
        );
      case AuthPage.register:
        return CustomTitleBar(
          child: RegisterPage(
              onRegisterSuccess: _onLoginSuccess, onGoLogin: _goToLogin),
        );
    }
  }
}

enum AuthPage { login, register }
