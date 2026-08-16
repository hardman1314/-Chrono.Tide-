import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import '../core/path_helper.dart';
import 'local_game_registry.dart';
import 'game_data_format.dart';
import 'process_cleanup_service.dart';
import 'app_state.dart';

/// 系统托盘服务 —— 隐形管家的核心
///
/// 职责：
/// - 常驻系统托盘，提供快速操作入口
/// - 左键单击托盘图标 → 显示/隐藏主窗口
/// - 右键单击托盘图标 → 弹出上下文菜单
/// - 菜单包含：最近游玩快速启动、打开主程序、退出
class TrayService with ChangeNotifier {
  static final TrayService _instance = TrayService._internal();
  static TrayService get instance => _instance;

  TrayService._internal();

  final SystemTray _systemTray = SystemTray();
  bool _initialized = false;
  bool _isWindowVisible = true;
  Timer? _menuRefreshDebounce;

  bool get isInitialized => _initialized;
  bool get isWindowVisible => _isWindowVisible;

  /// 初始化系统托盘
  Future<void> init() async {
    if (_initialized) return;

    try {
      // 同步窗口可见状态：静默模式下窗口不可见
      _isWindowVisible = !isSilentMode;

      // 查找图标路径
      String iconPath = _resolveIconPath();

      await _systemTray.initSystemTray(
        title: "Chrono Tide",
        iconPath: iconPath,
        toolTip: "Chrono Tide - 本地游戏管理器",
      );

      await _buildMenu();

      // 注册托盘事件处理
      _systemTray.registerSystemTrayEventHandler((eventName) {
        debugPrint('[TRAY] 事件: $eventName');
        if (eventName == kSystemTrayEventClick) {
          // 左键单击 → 切换窗口可见性
          _toggleWindowVisibility();
        } else if (eventName == kSystemTrayEventRightClick) {
          // 右键单击 → 弹出菜单
          _systemTray.popUpContextMenu();
        }
      });

      // ★ 优化B：游戏退出时发送 Toast 通知
      LocalGameRegistry.instance.onGameSessionEnded =
          (gameTitle, sessionSeconds) {
        final duration = GameDataFormat.formatPlayTime(sessionSeconds);
        showNotification('游戏已退出', '$gameTitle | 本次游玩: $duration');
        // 游戏退出后刷新菜单（最近游玩列表变化）
        refreshMenu();
      };

      // ★ 优化D：监听游戏库变化，动态刷新托盘菜单
      LocalGameRegistry.instance.addListener(_onGameLibraryChanged);

      _initialized = true;
      debugPrint('[TRAY] ✅ 系统托盘初始化成功');
    } catch (e) {
      debugPrint('[TRAY] ❌ 初始化失败: $e');
      // 降级：静默模式下托盘不可用，必须显示窗口否则用户无法操作
      if (isSilentMode) {
        debugPrint('[TRAY] ⚠️ 静默模式下托盘失败，强制显示窗口作为降级');
        userRequestedWindow = true;
        isSilentMode = false;
        try {
          await windowManager.setSkipTaskbar(false);
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
    }
  }

  /// 游戏库变化时的回调（带防抖，避免频繁刷新）
  void _onGameLibraryChanged() {
    _menuRefreshDebounce?.cancel();
    _menuRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
      refreshMenu();
    });
  }

  /// 解析图标路径
  String _resolveIconPath() {
    // 尝试多个可能的图标位置
    final candidates = [
      '${PathHelper.exeDir}\\data\\flutter_assets\\assets\\images\\app_icon.ico',
      '${PathHelper.exeDir}\\assets\\images\\app_icon.ico',
      '${PathHelper.exeDir}\\app_icon.ico',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        debugPrint('[TRAY] 图标路径: $path');
        return path;
      }
    }

    // 回退：使用 Windows 默认应用图标
    debugPrint('[TRAY] 未找到图标文件，使用默认图标');
    return '${PathHelper.exeDir}\\chrono_tide.exe';
  }

  /// 构建托盘菜单
  Future<void> _buildMenu() async {
    final menu = Menu();

    // 获取最近游玩的游戏（按 lastOpenedAt 排序，取前 5 个）
    final recentGames = _getRecentGames();

    final menuItems = <MenuItemBase>[];

    // 最近游玩子菜单
    if (recentGames.isNotEmpty) {
      final submenuItems = recentGames.map((game) {
        return MenuItemLabel(
          label: game.title,
          onClicked: (_) => _launchGame(game.title),
        );
      }).toList();

      menuItems.add(SubMenu(
        label: '最近游玩',
        children: submenuItems,
      ));
      menuItems.add(MenuSeparator());
    }

    // 打开主程序
    menuItems.add(MenuItemLabel(
      label: '打开主程序',
      onClicked: (_) => _showWindow(),
    ));

    // 退出
    menuItems.add(MenuSeparator());
    menuItems.add(MenuItemLabel(
      label: '退出',
      onClicked: (_) => _exitApp(),
    ));

    await menu.buildFrom(menuItems);
    await _systemTray.setContextMenu(menu);
  }

  /// 刷新托盘菜单（当游戏库变化时调用）
  Future<void> refreshMenu() async {
    if (!_initialized) return;
    await _buildMenu();
  }

  /// 获取最近游玩的游戏列表
  List<LibraryGame> _getRecentGames() {
    final games = LocalGameRegistry.instance.allGames;
    final played = games.where((g) => g.lastOpenedAt.isNotEmpty).toList();
    played.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    return played.take(5).toList();
  }

  /// 切换窗口可见性
  Future<void> _toggleWindowVisibility() async {
    if (_isWindowVisible) {
      await windowManager.hide();
      _isWindowVisible = false;
    } else {
      await _showWindow();
    }
    notifyListeners();
  }

  /// 显示主窗口
  Future<void> _showWindow() async {
    // 通知主应用：用户主动请求显示窗口
    // 通过设置全局标志，阻止 onWindowFocus 重新隐藏窗口
    userRequestedWindow = true;
    isSilentMode = false;
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    _isWindowVisible = true;
    notifyListeners();
  }

  /// 隐藏主窗口
  Future<void> hideWindow() async {
    await windowManager.hide();
    userRequestedWindow = false;
    _isWindowVisible = false;
    notifyListeners();
  }

  /// 启动游戏
  Future<void> _launchGame(String title) async {
    debugPrint('[TRAY] 启动游戏: $title');
    await LocalGameRegistry.instance.launchGame(title);
    // 刷新菜单以更新最近游玩列表
    await refreshMenu();
  }

  /// 退出应用
  /// 与 CustomTitleBar.performCleanExit 保持一致的完整清理流程
  Future<void> _exitApp() async {
    debugPrint('[TRAY] 退出应用');

    // 1. 清理游戏会话监控（★ v3: 改为异步以写入会话记录到事实表）
    await LocalGameRegistry.instance.disposeAllSessions();

    // 2. 清理所有子进程（包括 OpenList、7z 等）
    try {
      await ProcessCleanupService.cleanupAll();
    } catch (e) {
      debugPrint('[TRAY] 进程清理异常: $e');
    }

    // 3. 销毁托盘
    try {
      dispose();
    } catch (e) {
      debugPrint('[TRAY] 托盘销毁异常: $e');
    }

    // 4. 销毁窗口并退出
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (e) {
      debugPrint('[TRAY] 窗口销毁异常: $e');
    }

    exit(0);
  }

  /// 显示 Windows Toast 通知
  ///
  /// [title] 通知标题
  /// [message] 通知内容
  /// 使用 PowerShell 调用 Windows Runtime API 显示 Toast 通知
  /// 依赖 main.cpp 中设置的 AppUserModelID: ChronoTide.App.v1
  Future<void> showNotification(String title, String message) async {
    if (!_initialized) return;
    try {
      // 转义单引号（PowerShell 单引号字符串）
      final escTitle = title.replaceAll("'", "''");
      final escMessage = message.replaceAll("'", "''");

      final psScript = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

\$template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$escTitle</text>
            <text>$escMessage</text>
        </binding>
    </visual>
</toast>
"@

\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
\$xml.LoadXml(\$template)
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('ChronoTide.App.v1').Show(\$toast)
''';

      await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psScript],
      );
      debugPrint('[TRAY] 🔔 通知已发送: $title');
    } catch (e) {
      debugPrint('[TRAY] ⚠️ 通知发送失败: $e');
    }
  }

  /// 销毁托盘
  void dispose() {
    _menuRefreshDebounce?.cancel();
    LocalGameRegistry.instance.removeListener(_onGameLibraryChanged);
    LocalGameRegistry.instance.onGameSessionEnded = null;
    _systemTray.destroy();
    _initialized = false;
  }
}
