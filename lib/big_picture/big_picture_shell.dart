import 'package:flutter/material.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_resolver.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/sidebar.dart' show NavPage;
import '../widgets/app_snack_bar.dart';
import '../widgets/launch_manager_dialog.dart';
import '../modules/auth/user_model.dart';
import '../services/local_game_registry.dart';
import '../services/game_launch_service.dart';
import 'big_picture_manager.dart';
import 'focus/bpm_shortcuts.dart';
import 'widgets/big_picture_nav_bar.dart';
import 'widgets/big_picture_action_sheet.dart';
import 'pages/big_picture_home.dart';
import 'pages/big_picture_detail.dart';
import 'pages/big_picture_library_page.dart';
import 'pages/big_picture_discover.dart';
import 'pages/big_picture_join.dart';

/// BPM (大屏模式) 外壳容器
///
/// 取代桌面模式的 `CustomTitleBar + Sidebar + Content` 结构,
/// 提供全屏化布局: 左侧大尺寸导航栏 + 右侧内容区。
///
/// 顶层仍嵌套 [CustomTitleBar] 以复用窗口控制逻辑 (拖动/最小化/最大化/关闭),
/// 但 BPM 内部使用全屏布局,导航与内容均放大 1.6 倍。
///
/// 状态管理:
/// - `_currentPage`: 当前激活的导航页 (Home/Library/Discover/Join)
/// - `_selectedGame` + `_showDetailPage`: 详情页跳转状态
///
/// 页面切换通过 setState 模式 (与桌面 MainContainer 一致),不引入 Navigator 路由。
class BigPictureShell extends StatefulWidget {
  /// 当前登录用户 (供首页头部显示)
  final UserModel? currentUser;

  /// 游戏启动回调 (透传自 [MainContainer])
  final ValueChanged<String>? onLaunchGame;

  /// 标记切换回调 (透传自 [MainContainer])
  final void Function(String)? onToggleMark;

  /// 游戏删除回调 (透传自 [MainContainer])
  final ValueChanged<String>? onDelete;

  /// 退出 BPM 模式回调
  final VoidCallback? onExitBpm;

  const BigPictureShell({
    super.key,
    this.currentUser,
    this.onLaunchGame,
    this.onToggleMark,
    this.onDelete,
    this.onExitBpm,
  });

  @override
  State<BigPictureShell> createState() => _BigPictureShellState();
}

class _BigPictureShellState extends State<BigPictureShell> {
  NavPage _currentPage = NavPage.home;
  LibraryGame? _selectedGame;
  bool _showDetailPage = false;

  /// ★ H11: UI 层双重启动保护标志
  /// 防止用户在 BPM 模式下快速双击/多次点击导致多次调用 resolveUserChoice（异步），
  /// 与 GameLaunchService._isLaunching 互为防御纵深：
  /// - UI 层拦截：避免 resolveUserChoice 重复执行 + 避免重复弹 SnackBar
  /// - Service 层拦截：作为最终保险，跨页面/跨模式也生效
  bool _isLaunching = false;

  /// Library 页搜索框的焦点节点 (供 Ctrl+F 聚焦)
  /// 通过 [BigPictureLibraryPage.focusSearchNode] 暴露给 Shell
  final FocusNode _librarySearchFocus = FocusNode();

  @override
  void dispose() {
    _librarySearchFocus.dispose();
    super.dispose();
  }

  void _onPageChanged(NavPage page) {
    setState(() {
      _currentPage = page;
      _showDetailPage = false;
    });
  }

  /// ESC: 详情页返回; 否则退出 BPM
  void _onEscape() {
    if (_showDetailPage) {
      _onDetailBack();
    } else {
      BigPictureManager.instance.exit();
    }
  }

  /// Ctrl+F: 聚焦 Library 页搜索框
  void _onFocusSearch() {
    if (_currentPage == NavPage.library && !_showDetailPage) {
      _librarySearchFocus.requestFocus();
    }
  }

  void _onGameTap(LibraryGame game) {
    setState(() {
      _selectedGame = game;
      _showDetailPage = true;
    });
  }

  void _onDetailBack() {
    setState(() {
      _showDetailPage = false;
    });
  }

  /// 启动游戏 (双击卡片 / 详情页启动按钮 / 动作表启动)
  ///
  /// 走 [GameLaunchService] 共享服务,与桌面模式行为一致:
  /// 1. resolveUserChoice → 获取已保存的 exe 路径
  /// 2. 无路径时提示用户先在桌面模式选择
  /// 3. executeLaunch → 执行启动 (含 magpie/locale/普通三种模式)
  /// 4. 失败时通过 AppSnackBar 反馈
  ///
  /// ★ H11: UI 层双重启动保护
  /// resolveUserChoice 和 executeLaunch 都是异步操作，快速双击会导致
  /// 两次 resolveUserChoice 并行执行。UI 层提前拦截可避免重复磁盘 I/O
  /// 和重复弹 SnackBar。GameLaunchService._isLaunching 作为最终兜底。
  Future<void> _launchGame(LibraryGame game) async {
    if (_isLaunching) {
      debugPrint('[LAUNCH] ⏭️ BPM UI 层拦截：上一次启动仍在进行中');
      return;
    }
    _isLaunching = true;
    try {
      final exePath =
          await GameLaunchService.instance.resolveUserChoice(game.title);
      if (exePath == null) {
        if (mounted) {
          AppSnackBar.warning(context, '请先在桌面模式选择启动程序 (右键 → 启动管理)');
        }
        return;
      }
      final result =
          await GameLaunchService.instance.executeLaunch(game, exePath);
      if (!result.success && mounted) {
        AppSnackBar.error(context, result.error ?? '无法启动游戏');
      }
      if (mounted) setState(() {});
    } finally {
      _isLaunching = false;
    }
  }

  /// 标记切换 (动作表触发)
  void _toggleMark(LibraryGame game) {
    LocalGameRegistry.instance.toggleMark(game.title);
    widget.onToggleMark?.call(game.title);
    setState(() {});
  }

  /// 打开启动管理对话框 (动作表触发)
  Future<void> _openLaunchManager(LibraryGame game) async {
    await LaunchManagerDialog.show(
      context: context,
      gameTitle: game.title,
      gameDirectory: game.directoryPath,
      metaDataDir: game.metaDataDir,
      onExeSelected: (_) {},
    );
    if (mounted) setState(() {});
  }

  /// 删除游戏 (动作表触发,由 MainContainer 处理确认对话框)
  void _deleteGame(LibraryGame game) {
    widget.onDelete?.call(game.title);
    setState(() {});
  }

  /// 长按游戏卡片 → 弹出动作表
  void _showActionSheet(LibraryGame game) {
    BigPictureActionSheet.show(
      context: context,
      gameTitle: game.title,
      onLaunch: () => _launchGame(game),
      onToggleMark: () => _toggleMark(game),
      onLaunchManager: () => _openLaunchManager(game),
      onDelete: () => _deleteGame(game),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomTitleBar(
      child: BpmShortcuts(
        onToggleBpm: () => BigPictureManager.instance.toggle(),
        onEscape: _onEscape,
        onFocusSearch: _onFocusSearch,
        child: AnimatedBuilder(
          animation: AppThemeManager.instance,
          builder: (context, _) {
            final themeData = AppThemeManager.instance.current;
            return Stack(
              fit: StackFit.expand,
              children: [
                // 主题背景层 (与 MainContainer 一致)
                // v3.0 P1：使用 BackgroundImageResolver 统一渲染
                if (themeData.hasBackgroundImage)
                  Positioned.fill(
                    child: BackgroundImageResolver(
                      config: themeData.backgroundImage,
                      overlayColor: themeData.background,
                    ),
                  ),

                // 主体: 左导航 (独立焦点域) + 右内容 (独立焦点域)
                // Tab 在两个 group 间切换; 方向键在各 group 内导航
                Row(
                  children: [
                    FocusTraversalGroup(
                      child: BigPictureNavBar(
                        currentPage: _currentPage,
                        onPageChanged: _onPageChanged,
                        onExitBpm: widget.onExitBpm ??
                            () => BigPictureManager.instance.exit(),
                      ),
                    ),
                    Expanded(
                      child: FocusTraversalGroup(
                        child: _buildCurrentPage(),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 当前页面内容
  ///
  /// 优先级: 详情页 > 当前导航页
  /// - 详情页: 单击卡片后进入,显示游戏完整信息
  /// - Home: 首页 (最近/收藏/全部)
  /// - Library: 游戏库 (搜索/排序/网格)
  /// - Discover: 发现页 (可下载游戏列表)
  /// - Join: 入库页 (拖拽导入)
  ///
  /// 用 [AnimatedSwitcher] 包裹,实现页面切换 200ms fade 过渡。
  Widget _buildCurrentPage() {
    // 通过 key 区分不同页面,触发 AnimatedSwitcher 切换
    final pageKey = ValueKey(
      _showDetailPage ? 'detail_${_selectedGame?.title}' : 'page_$_currentPage',
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: KeyedSubtree(
        key: pageKey,
        child: _buildPageContent(),
      ),
    );
  }

  Widget _buildPageContent() {
    if (_showDetailPage && _selectedGame != null) {
      return BigPictureDetail(
        game: _selectedGame!,
        onBack: _onDetailBack,
        onLaunchComplete: () => setState(() {}),
      );
    }

    switch (_currentPage) {
      case NavPage.home:
        return BigPictureHome(
          onGameTap: _onGameTap,
          onGameLaunch: _launchGame,
          onGameLongPress: _showActionSheet,
          onViewAll: () => _onPageChanged(NavPage.library),
          onGoToAdd: () => _onPageChanged(NavPage.join),
          onGoToDiscover: () => _onPageChanged(NavPage.discover),
        );
      case NavPage.library:
        return BigPictureLibraryPage(
          onGameTap: _onGameTap,
          onGameLaunch: _launchGame,
          onGameLongPress: _showActionSheet,
          searchFocusNode: _librarySearchFocus,
        );
      case NavPage.discover:
        return const BigPictureDiscover();
      case NavPage.join:
        return BigPictureJoin(
          onGameAdded: () => setState(() {}),
        );
    }
  }
}
