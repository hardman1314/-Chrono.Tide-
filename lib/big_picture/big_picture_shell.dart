import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/background_image_resolver.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/launch_manager_dialog.dart';
import '../widgets/save_backup_dialog.dart';
import '../services/manifest_service.dart';
import '../modules/auth/user_model.dart';
import '../services/local_game_registry.dart';
import '../services/game_launch_service.dart';
import '../services/game_data_format.dart';
import '../pages/join_page.dart';
import '../pages/join/batch_import_controller.dart';
import '../pages/join/widgets/swipe_switcher.dart' show ImportMode;
import '../widgets/nsfw/nsfw_image.dart';
import 'big_picture_manager.dart';
import 'big_picture_theme.dart';
import 'bpm_theme_controller.dart';
import 'services/bpm_system_status.dart';
import 'focus/bpm_shortcuts.dart';
import 'focus/bpm_zone_focus_controller.dart';
import 'widgets/big_picture_nav_bar.dart';
import 'widgets/bpm_focus_domain.dart';
import 'widgets/bpm_focus_zone.dart';
import 'widgets/bpm_virtual_keyboard.dart';
import 'widgets/big_picture_action_sheet.dart';
import 'widgets/bpm_interactive_wrapper.dart';
import 'widgets/bpm_key_cap.dart';
import 'widgets/bpm_page_switch_hint.dart';
import 'widgets/bpm_trigger_page_hint.dart';
import 'widgets/bpm_collection_picker.dart';
import 'widgets/bpm_context_menu.dart';
import 'pages/bpm_game_detail_page.dart';
import 'widgets/bpm_game_edit_dialog.dart';
import 'widgets/bpm_backdrop_tuner.dart';
import 'services/bpm_play_history.dart';
import 'services/bpm_backdrop_media.dart';
import 'services/bpm_backdrop_media_controller.dart';
import 'services/bpm_gamepad_service.dart';
import '../services/bpm_guide_preference.dart';
import 'services/bpm_ime_bridge.dart';
import 'services/bpm_sdl3_backend.dart';
import '../services/gamepad/gamepad_adaptation_coordinator.dart';
import '../widgets/gamepad/gamepad_launch_dialogs.dart';
import 'services/bpm_dinput_backend.dart';
import '../services/soft_keyboard_launcher.dart';
import 'widgets/bpm_background_manager.dart';
import 'widgets/bpm_import_mode_sheet.dart';
import 'widgets/bpm_op_video_layer.dart';
import 'widgets/bpm_smart_cover_image.dart';
import 'widgets/bpm_top_bar.dart';
import 'widgets/bpm_exit_sheet.dart';
import 'pages/big_picture_home.dart';
import 'pages/big_picture_library_page.dart';

/// BPM (大屏模式) 外壳容器 — v3 Cinema 重构
///
/// 借鉴 gal-launcher 项目 Cinema 主题的舞台式布局:
/// - 全屏 backdrop 层: 当前舞台焦点游戏封面铺满 + 多向渐变遮罩
/// - 左侧竖排 rail 导航: 玻璃质感按钮列 (主页/我的库/添加游戏/退出)
/// - 右侧 stage: 页面内容 (主页 hero 舞台 + shelf / 我的库海报墙 / 详情页)
///
/// 大屏模式 v3 起定位为**本地模式**: 仅管理本地游戏库,
/// 不再提供探索页 (云端下载) 入口; `big_picture_discover.dart` 保留但不再引用。
///
/// 状态管理:
/// - `_currentPage`: 0 = 主页, 1 = 我的库
/// - `_stageGame`: 舞台焦点游戏 (驱动 backdrop 与主页 hero 舞台)
/// - `_panelGame`: 右侧滑出详情面板的游戏 (null = 关闭;v3.2 gal-launcher 式)
/// - `_bpmBatchController`: BPM 持久批量控制器 (页面切换不丢批量队列,对齐桌面)
/// - `_zf`: v3.10 分层板块焦点状态机 (一级 3 板块 / 页面二级板块 / 两级模式)
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

  /// v3.5: 打开用户面板 (头部栏用户按钮入口)
  ///
  /// 由 [MainContainer] 注入, 与桌面模式右下角用户按钮**完全同源**
  /// (同一 Overlay 宿主、同一 [UserProfileModal]、同一设置/充值入口),
  /// 因此大屏模式下也能直接进设置/充值/退出登录。
  final VoidCallback? onOpenUserPanel;

  const BigPictureShell({
    super.key,
    this.currentUser,
    this.onLaunchGame,
    this.onToggleMark,
    this.onDelete,
    this.onExitBpm,
    this.onOpenUserPanel,
  });

  @override
  State<BigPictureShell> createState() => _BigPictureShellState();
}

class _BigPictureShellState extends State<BigPictureShell>
    with WidgetsBindingObserver {
  /// 0 = 主页, 1 = 我的库
  int _currentPage = 0;

  /// 舞台焦点游戏 (Cinema selected): 驱动 backdrop 与主页 hero
  LibraryGame? _stageGame;

  /// BPM 背景 OP 视频状态机 (2026-09-27): 选中停留 3s → 封面淡出 →
  /// 视频在 UI 背后播放 → 播完淡出恢复。无视频的游戏行为与改动前完全一致。
  late final BpmBackdropMediaController _backdropMedia =
      BpmBackdropMediaController();

  /// 右侧滑出详情面板当前游戏 (null = 面板关闭)
  LibraryGame? _panelGame;

  /// 最后一次打开面板的游戏 (面板进出场动画期间仍需渲染)
  LibraryGame? _lastPanelGame;

  /// 二级详情「隐藏 UI」态 (2026-09-28): 供欣赏背景图 / OP 视频。
  ///
  /// 该态下面板整块淡出, 任意输入唤回。鼠标 / 键盘由详情页内部的唤回层
  /// 处理; **手柄必须由本 shell 处理** —— 手柄事件走 FFI 轮询, 不经过
  /// Flutter 键盘通道, 详情页侧收不到 (既有教训见 features 文档「询问框
  /// 手柄桥接」)。关闭 / 重开详情即复位。
  bool _detailUiHidden = false;

  /// v3.20: 隐藏 UI 前持有焦点的节点 —— 唤回时归还焦点而非跳回「游玩」。
  ///
  /// 隐藏期间详情主 UI 只是淡出（AnimatedOpacity），子树不卸载，节点始终
  /// 存活；唤回层卸载后经 [FocusNode.context] 判定仍挂载才归还，否则回退
  /// 面板入口 `_panelPrimaryNode`。
  FocusNode? _detailFocusBeforeHide;

  /// BPM 持久批量导入控制器 (对齐桌面 MainContainer._batchImportController:
  /// 传入 JoinPage 后,主页/库/导入页之间切换不丢批量队列)
  late final BatchImportController _bpmBatchController;

  /// ★ H11: UI 层双重启动保护标志
  /// 防止用户在 BPM 模式下快速双击/多次点击导致多次调用 resolveUserChoice（异步），
  /// 与 GameLaunchService._isLaunching 互为防御纵深。
  bool _isLaunching = false;

  /// Library 页搜索框的焦点节点 (供 Ctrl+F 聚焦)
  final FocusNode _librarySearchFocus = FocusNode();

  // ════ v3.10 分层板块焦点系统 (2026-09-20 重构; 取代 v3.8/v3.9 的双布尔层) ════
  ///
  /// 分工: [BpmGamepadService] 只做轮询 → 语义事件; [BpmZoneFocusController]
  /// 持三级状态机 (一级板块 / 二级板块 / 组件); 本 shell 只做两件事 ——
  /// ① 把状态转移结果落到焦点域内的组件 ([_focusZone]);
  /// ② 由 `nearestScope` 反查 primaryFocus 所属板块 ([BpmZoneFocusController
  ///    .zoneOfScope]); ③ 组件模式的方向移动交给框架的 `inDirection`
  ///    (它才是"几何筛选 + 空候选即边缘停"的正确实现)。
  ///
  /// 按键语义 (括号内为 PS / Switch 对应键):
  /// - **A (×/B)** = 板块模式 → 进入板块; 组件模式 → 激活当前控件。
  ///   面板开 → 先把焦点交给面板主启动按钮 (两段式, 与 v3.9 一致)。
  /// - **B (○/A)** = 层级回退: 组件模式 → 板块模式; 二级板块模式 → 一级板块
  ///   模式; 一级板块模式 → 不消费 (保持「B 不误退大屏」的既有约定)。
  ///   面板开 → 关面板 (锁定态先解锁并回锚点)。
  /// - **十字键/左摇杆** = 板块模式: 层级内切换板块 (**边界停, 不跨级**);
  ///   组件模式: 板块内移动 (**边缘停, 不跨板块** —— 规范第 4 条)。
  /// - **X (□/Y)** = 当前项动作菜单; **Y (△/X)** = 切换当前项标记/收藏。
  /// - **Start (Options/+)** = BPM 系统菜单; **Back (Create/−)** = 视图切换。
  /// - **LB/RB (L1/R1)** = 页面切换 (主页⇄库), 落点 = 新页卡片列表组件模式。
  /// - **LT/RT (L2/R2)** = 快速翻屏 (面板 / 焦点或高亮板块所在的滚动视图)。
  /// - **右摇杆** = 滚动轴流: 面板开滚面板; 组件模式滚焦点所在 Scrollable;
  ///   板块模式滚**当前高亮板块**的 Scrollable (两者都按**轴向匹配**)。
  ///
  /// 🔴 手柄与鼠标/键盘的边界: **板块模式只在手柄侧生效**。手柄在板块模式下
  /// 刻意不动焦点, 因此 [_onPrimaryFocusChanged] 收到焦点变化时必来自鼠标 /
  /// 键盘 / 程序化 requestFocus, 可安全地据此切回组件模式 —— 「保留原有鼠标
  /// 操作」由此获得结构性保证, 而不是靠口头约定。
  late final BpmGamepadService _gamepad = BpmGamepadService(
    backends: _createGamepadBackends(),
    callbacks: BpmGamepadCallbacks(
      onConfirm: _handleGamepadConfirm,
      onBack: _handleGamepadBack,
      onContextMenu: _handleGamepadContextMenu,
      onMark: _handleGamepadMark,
      onSystemMenu: _handleGamepadSystemMenu,
      onViewToggle: _handleGamepadViewToggle,
      onPageShift: _handleGamepadPageShift,
      onTriggerShift: _handleGamepadTriggerShift,
      onDirection: _handleGamepadDirection,
      onScroll: _handleGamepadScroll,
      onConnectionChanged: _handleGamepadConnectionChanged,
    ),
  )..dispatchGate =
      () {
        // 🔴 前台感知闸门（2026-09-27）：会话活跃**且游戏在前台**才让路。
        // 旧实现 = hasActiveSession（整个会话期间 BPM 都让路）→ 用户从游戏
        // Alt+Tab 回 Chrono Tide 后，注入守卫不放行、BPM 又不消费 —— 手柄
        // 两边都不工作（「切回软件手柄死区」）。
        final c = GamepadAdaptationCoordinator.instance;
        return c.hasActiveSession && c.isGameForeground;
      };

  /// 手柄后端优先级: SDL3 (跨厂商全覆盖, 自带映射库) → XInput (Xbox 系,
  /// 低延迟回退) → DirectInput (再回退)。皆不可用时列表为空, service 静默空转。
  static List<BpmGamepadBackend> _createGamepadBackends() {
    final backends = <BpmGamepadBackend>[];
    final sdl3 = Sdl3Backend.tryCreate();
    if (sdl3 != null) backends.add(sdl3);
    final xinput = XInputBackend.tryCreate();
    if (xinput != null) backends.add(xinput);
    final dinput = DInputBackend.tryCreate();
    if (dinput != null) backends.add(dinput);
    debugPrint(
      '[BPM][Gamepad] 已启用后端: '
      '${backends.isEmpty ? "无 (本机手柄能力不可用)" : backends.map((b) => b.name).join(" + ")}',
    );
    return backends;
  }

  // ════ v3.10 分层板块焦点系统 ════
  //
  // 三级状态机 (层级 / 模式 / 转移规则) 全在 [BpmZoneFocusController],
  // 本 shell 只负责把结果落到焦点上, 并用焦点组 key 反查焦点归属。

  /// 焦点状态机 (通过 [BpmZoneFocusScope] 注入子树)
  final BpmZoneFocusController _zf = BpmZoneFocusController();

  // ============ v3.19 自绘虚拟键盘 ============
  /// 系统键盘 (osk/TabTip) 是独立窗口，手柄输入到不了 → 自绘键盘 overlay。
  final GlobalKey<BpmVirtualKeyboardState> _vkKey =
      GlobalKey<BpmVirtualKeyboardState>();
  OverlayEntry? _vkOverlay;
  bool _vkVisible = false;
  TextEditingController? _vkTarget;

  /// 焦点落在可编辑控件 → 打开自绘虚拟键盘（手柄可直接导航键位）。
  void _openVirtualKeyboard() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return;
    final editable = ctx.findAncestorStateOfType<EditableTextState>();
    final controller = editable?.widget.controller;
    if (controller is! TextEditingController) return;
    _vkTarget = controller;
    if (_vkVisible) {
      _vkOverlay?.markNeedsBuild();
      return;
    }
    _vkVisible = true;
    _vkOverlay = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: BpmVirtualKeyboard(
          key: _vkKey,
          controller: _vkTarget!,
          onClose: _closeVirtualKeyboard,
          onSystemKeyboard: () => SoftKeyboardLauncher.show(),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_vkOverlay!);
  }

  /// 关闭虚拟键盘。焦点保持在输入框上：A 再按可重开键盘，
  /// B 再按才完整退出输入态（v3.18 的 [\_exitEditableFocus]）。
  void _closeVirtualKeyboard() {
    _vkOverlay?.remove();
    _vkOverlay = null;
    _vkVisible = false;
    _vkTarget = null;
    if (mounted) setState(() {});
  }

  /// 模态 (动作表 / 确认框 / 导入窗口 / 用户面板) 内使用的兜底遍历策略。
  ///
  /// 🔴 模态有各自的 FocusScope，不在任何板块焦点域内 → 板块内的策略取不到，
  /// 必须有一个**共享实例**兜底（策略内部有方向历史栈，每次新建实例会让
  /// 「反方向回到上一位置」失效）。
  final FocusTraversalPolicy _fallbackPolicy = ReadingOrderTraversalPolicy();

  /// v3.9 手柄: 库页当前聚焦的海报对应游戏
  /// (X=动作菜单 / Y=标记 的作用对象; 主页用 [_stageGame] 即可)
  LibraryGame? _libraryFocusedGame;

  /// 是否已收到过鼠标/键盘输入。
  ///
  /// 🔴 专治「启动期 autofocus 误判成用户操作」：首页 shelf 首卡的
  /// `autofocus` 会在首帧请求焦点, 若不加这道闸门, [_onPrimaryFocusChanged]
  /// 会把状态直接切到组件模式, 启动默认落点就不再是「左侧导航栏板块模式」
  /// （违反规范第 1 条）。
  bool _userInputSeen = false;

  /// v3.18 输入模式热判定 —— 手柄模式必须**依次**满足两点：
  /// ① 手柄已连接；② 手柄产生实际输入。任一步不满足 = 键鼠模式。
  bool _gamepadConnected = false;
  bool _gamepadInputMode = false;

  /// 详情面板锁定态 (面板打开后第一次 A = 把焦点交给面板内容)
  ///
  /// 面板是**覆盖式交互**, 不进板块状态机的层级 (状态机里只把 zone 记为
  /// panel, 关面板后自动恢复到打开前的层级)。
  bool _panelLocked = false;

  /// 面板锁定前焦点节点 (B 键退回时 requestFocus 回去)
  FocusNode? _panelAnchor;

  /// 面板内部操作入口节点 (面板 footer 主启动按钮)
  final FocusNode _panelPrimaryNode = FocusNode();

  /// 面板内容滚动控制器 (右摇杆在浏览态直接滚面板)
  final ScrollController _panelScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // v3.5: 头部栏系统状态区 (时间/电池) — 仅在 BPM 挂载期间刷新
    BpmSystemStatus.instance.start();
    // v3.8: 手柄轮询 (无手柄环境后端为 null,service 空转零开销)
    _gamepad.start();
    // 手柄适配 v2（2026-09-27）：单实例附加模式 —— 会话消费本服务的 raw 流，
    // 不再自建第二套后端（双实例互抢事件 + double-dispose 崩溃根因）。
    GamepadAdaptationCoordinator.instance.attachGamepadService(_gamepad);
    // v3.10: 监听焦点变化 (反查归属 → 鼠标/键盘介入时切回组件模式)。
    // 板块焦点域由各 [BpmFocusDomain] 自行登记, 无需在此手工注册。
    FocusManager.instance.addListener(_onPrimaryFocusChanged);
    // 键盘介入检测 (手柄走 FFI 轮询, 不经此通道 → 只对键鼠生效)
    HardwareKeyboard.instance.addHandler(_onHardwareKeyEvent);
    // v3.18: 鼠标/触摸介入检测（手柄走 FFI，不产生 pointer 事件）
    WidgetsBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
    // 背景 OP 视频：① 状态变化驱动 backdrop 重建；② 窗口生命周期暂停/恢复；
    // ③ 🔴 v3.11.1 修复：初始同步可播条件 —— 此前漏掉这一步，_canPlay 一直为
    //    false，导致刚进 BPM 时 OP 不播、切换游戏也无效，直到开一次详情或
    //    切一次库页才被 _onPageChanged/_dismissPanel 顺带修复。
    _backdropMedia.addListener(_onBackdropMediaChanged);
    WidgetsBinding.instance.addObserver(this);
    _syncBackdropPlayable();
    _bpmBatchController = BatchImportController(
      onGameAdded: () {
        if (mounted) setState(() {});
      },
      onError: (msg) {
        if (mounted) AppSnackBar.error(context, msg);
      },
      onSuccess: (msg) {
        if (mounted) AppSnackBar.success(context, msg);
      },
      onInfo: (msg) {
        if (mounted) AppSnackBar.info(context, msg);
      },
    );
  }

  @override
  void dispose() {
    BpmSystemStatus.instance.stop();
    FocusManager.instance.removeListener(_onPrimaryFocusChanged);
    HardwareKeyboard.instance.removeHandler(_onHardwareKeyEvent);
    WidgetsBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
    // v3.19: 虚拟键盘 overlay 挂在 rootOverlay，shell 销毁必须摘除
    _vkOverlay?.remove();
    _vkOverlay = null;
    _vkVisible = false;
    _zf.dispose();
    GamepadAdaptationCoordinator.instance.detachGamepadService();
    GamepadAdaptationCoordinator.instance.detach();
    _gamepad.dispose();
    _bpmBatchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _backdropMedia.removeListener(_onBackdropMediaChanged);
    _backdropMedia.dispose();
    _librarySearchFocus.dispose();
    _panelPrimaryNode.dispose();
    _panelScrollController.dispose();
    _detailMenuOpen.dispose();
    _categoryBoxOpen.dispose();
    super.dispose();
  }

  /// 点侧边栏底部按钮 → 弹出三选一 (退出大屏 / 关闭软件 / 最小化)
  ///
  /// 原系统标题栏退出与最小化能力全部迁到这里 (v3.5)。
  Future<void> _openExitSheet() async {
    if (_bpmModalDepth > 0) return;
    _bpmModalDepth++;
    try {
      await BpmExitSheet.show(context);
    } finally {
      _bpmModalDepth--;
    }
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
      _panelGame = null; // 切页自动收起面板
    });
    _syncBackdropPlayable(); // 离开主页 → 停播背景视频
    // v3.10 规范第 2 条: 进入页面后自动选中「游戏卡片列表」二级板块,
    // 并自动进入组件模式 (落点 = 该域上次落点, 否则域内第一个组件)。
    // v3.19: 焦点体系停用时（键鼠模式）只复位状态机、**不抢焦点** ——
    // 鼠标点 rail 切页不应把键盘焦点拽到卡片列表上。
    if (_zf.enabled) {
      _focusZone(_zf.landOnCardList(page: page));
    } else {
      _zf.landOnCardList(page: page);
    }
  }

  /// ESC: 详情面板开着 → 先收面板; 否则退出 BPM
  void _onEscape() {
    // 隐藏 UI 态：ESC 只唤回界面（不直接退出详情 / 大屏）
    if (_consumeDetailUiHiddenInput()) return;
    if (_panelGame != null) {
      _dismissPanel();
    } else {
      _exitBpm();
    }
  }

  /// 退出大屏模式 (优先用宿主注入的回调, 保证与 MainContainer 同步)
  void _exitBpm() {
    final cb = widget.onExitBpm;
    if (cb != null) {
      cb();
    } else {
      BigPictureManager.instance.exit();
    }
  }

  /// Ctrl+F: 聚焦我的库搜索框
  void _onFocusSearch() {
    if (_currentPage == 1) {
      _librarySearchFocus.requestFocus();
    }
  }

  /// 解析游戏封面路径 (优先 coverUrl, 回退 GameDataFormat 目录搜索)
  String? _resolveCoverPath(LibraryGame game) {
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return game.coverUrl;
    }
    try {
      return GameDataFormat.findCoverFile(game.pathForCover)?.path;
    } catch (_) {
      return null;
    }
  }

  void _onStageGameChanged(LibraryGame game) {
    if (_stageGame?.title == game.title &&
        _stageGame?.directoryPath == game.directoryPath) {
      return;
    }
    setState(() {
      _stageGame = game;
      _reloadBackdropAdj();
    });
    // OP 视频：换游戏 → 重新计时（同一游戏重复调用幂等，不会重置计时）
    _backdropMedia.onStageGameChanged(game);
    // v3.14：每游戏背景声音标记随换游戏即时生效（详情「声音」按钮写 game.json）
    _backdropMedia.applyGameMuted(BpmBackdropMedia.isGameMuted(game.metaDataDir));
  }

  /// v3.3: 舞台背景手动对齐缓存 (背景调整器写入 game.json 后刷新)
  BpmBackdropAdjustment? _backdropAdj;

  void _reloadBackdropAdj() {
    final g = _stageGame;
    _backdropAdj = (g == null || g.metaDataDir.isEmpty)
        ? null
        : BpmBackdropAdjustment.read(g.metaDataDir);
  }

  /// 背景媒体状态变化 → 重建 backdrop（视频淡入淡出、播放态遮罩切换）。
  void _onBackdropMediaChanged() {
    if (mounted) setState(() {});
  }

  /// 统一裁决「当前是否允许背景视频播放」：主页 **或二级详情打开期间**。
  ///
  /// 🔴 v3.11.1：详情面板**不再**计入可播条件 —— 面板开合与背景视频完全解耦，
  /// 视频只在「换游戏 / 离开主页 / 退出大屏」时停止。此前面板打开走 cancel
  /// （用户感知为「视频被强停恢复背景图」）、关闭后重计 3s 又重播，均为缺陷。
  /// 「我的库」页浏览时不播视频（那里没有底部栏选中语义，背景只是陪衬）。
  ///
  /// 🔴 v3.12（2026-09-28 用户拍板）：**二级详情打开期间也放行** —— 详情已是
  /// 全屏整页、整块背景就是这套 backdrop，不放行的话从「我的库」进详情后 OP
  /// 永远不播，只能看静态背景图（与「底层为全屏 OP 视频 / 艺术图」的需求冲突）。
  /// ⚠️ 这里用 `_panelGame` 而**不是** `_lastPanelGame`：后者含退场动画窗口，
  /// 会让视频在详情关闭后继续播下去，违背「库页浏览不播视频」的既有裁决。
  /// 本函数只在「页面切换 / 打开详情 / 关闭详情」时被调用，解耦逻辑本身未动。
  void _syncBackdropPlayable() {
    _backdropMedia.setCanPlay(_currentPage == 0 || _panelGame != null);
  }

  /// 窗口最小化 / 失焦 → 暂停背景视频（用户 2026-09-26 拍板「暂停」）；
  /// 恢复可见 → 仅当仍处于播放态时继续。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _backdropMedia.resumeForLifecycle();
    } else {
      _backdropMedia.pauseForLifecycle();
    }
  }

  /// backdrop 图片来源：**自定义背景展示图优先 → 横幅封面 → 竖向封面**。
  ///
  /// 自定义图与封面走同一套裁剪/缩放链路（[BpmSmartAlignedImage] +
  /// `bpm_backdrop_x/y/zoom`）—— 那些参数本就是「背景的位置控制」，
  /// 与图片来源无关（方案 §4.4）。
  ///
  /// ★ 2026-10-04 横幅封面：横版大图（game.json `banner_file`）与全屏背景
  ///   宽高比天然接近，只需轻微适配即可铺满，避免竖向封面破坏性放大裁切。
  ///   无横幅 → 原样回退竖向封面（行为与旧版完全一致）。
  String? _resolveBackdropPath(LibraryGame game) {
    final custom = BpmBackdropMedia.resolveSelectedImage(game.metaDataDir);
    if (custom != null && custom.isNotEmpty) return custom;
    final banner = _resolveBannerPath(game);
    if (banner != null) return banner;
    return _resolveCoverPath(game);
  }

  /// 解析横幅封面路径（优先内存 bannerUrl，回退 findBannerFile 磁盘探测）。
  ///
  /// 结构与 [_resolveCoverPath] 同构；探测失败 / 无横幅返回 null。
  String? _resolveBannerPath(LibraryGame game) {
    if (game.bannerUrl.isNotEmpty && File(game.bannerUrl).existsSync()) {
      return game.bannerUrl;
    }
    try {
      return GameDataFormat.findBannerFile(game.pathForCover)?.path;
    } catch (_) {
      return null;
    }
  }

  /// 打开二级游戏详情 (主页【详情】按钮 / 我的库左键单击 / 右键菜单「详情」)
  void _showGamePanel(LibraryGame game) {
    // v3.10: 面板打开期间状态机记为 (zone = panel, mode = component),
    // 收面板时自动恢复打开前的层级 —— 面板不进板块层级, 方向键由面板
    // 自身的 FocusTraversalGroup 隔离。
    _zf.openPanel();
    _panelLocked = false; // 面板开 = 先浏览态, 按 A 才进入内容操作
    _panelAnchor = null;
    _detailUiHidden = false;
    _detailFocusBeforeHide = null; // 重开详情：丢弃上一个会话的焦点记忆
    // 🔴 v3.22 键盘闭环修复：stage 区域在详情打开期间被 ExcludeFocus 撤出，
    // 不落焦的话键盘焦点会**悬空** → 方向键/Enter 全部失效。键鼠模式下把
    // 焦点交给面板「游玩」主按钮（进详情即可 Enter 启动 / 方向键浏览面板）。
    // 手柄模式**不动**：面板两段式锁定（第一次 A 才把焦点交给面板内容）的
    // 语义保持 —— 手柄路径焦点由 _handleGamepadConfirm 接管。
    if (!_gamepadInputMode) {
      _panelAnchor = FocusManager.instance.primaryFocus; // 关详情后焦点回触发卡片
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _panelGame == null) return;
        _panelPrimaryNode.requestFocus();
      });
    }
    setState(() {
      _panelGame = game;
      _lastPanelGame = game;
    });
    // 🔴 v3.12：二级详情是全屏整页，其背景 = 底层 stage backdrop —— 必须把
    // 舞台焦点游戏切到**正在看的这部**，否则从库页进详情会看到「别人的」背景
    // 与 OP 视频。`_onStageGameChanged` 自带同游戏幂等（标题 + 目录双比对），
    // 从主页进当前舞台游戏时不会重置 OP 计时。
    _onStageGameChanged(game);
    // 🔴 v3.12：详情是全屏整页、整块背景就是 backdrop —— 打开期间放行视频，
    // 否则从「我的库」进详情后 OP 永远不播。放在 `_onStageGameChanged` **之后**：
    // 换舞台游戏那步可能因 `_canPlay == false` 而不 arm，这里放行后才会起计时。
    _syncBackdropPlayable();
    // 🔴 v3.11.1：详情页开合本身**不再 cancel / 重播**视频（解耦逻辑未动）。
  }

  /// 设置二级详情「隐藏 UI」态（欣赏背景图 / OP 视频）。
  ///
  /// v3.20: 唤回时把焦点还给**隐藏前所在的按钮**（如「隐藏」「播放」），
  /// 替代旧的「一律回面板入口」—— 那会让用户感知为「点击后焦点被重置回
  /// 游玩」。仅当旧节点已销毁 / 不可聚焦（详情已关闭等）才回退入口。
  void _setDetailUiHidden(bool hidden) {
    if (_detailUiHidden == hidden) return;
    if (hidden) {
      // 同步捕获：包装器已先落焦点（requestFocusOnTap）→ 这里拿到的就是
      // 触发隐藏的那个按钮（手柄 A 激活时本就持有焦点，同样成立）。
      _detailFocusBeforeHide = FocusManager.instance.primaryFocus;
    }
    setState(() => _detailUiHidden = hidden);
    if (!hidden && _panelGame != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _panelGame == null) return;
        final prev = _detailFocusBeforeHide;
        _detailFocusBeforeHide = null;
        if (prev != null && prev.canRequestFocus && prev.context != null) {
          prev.requestFocus();
        } else {
          _panelPrimaryNode.requestFocus();
        }
      });
    }
  }

  /// 隐藏 UI 期间：任意手柄输入只做「唤回 UI」，不执行任何语义。
  ///
  /// 返回 true = 已消费，调用方直接 return。不拦截的话，隐藏状态下按 X/B/Start
  /// 会在**看不见的界面**上叠加动作表 / 退出面板 —— 用户感知为「软件卡死」。
  bool _consumeDetailUiHiddenInput() {
    if (!_detailUiHidden) return false;
    _setDetailUiHidden(false);
    return true;
  }

  void _dismissPanel() {
    _zf.closePanel();
    setState(() {
      _panelGame = null;
      _detailUiHidden = false;
    });
    _detailFocusBeforeHide = null; // 详情已关：焦点记忆随之失效
    // 🔴 v3.12：详情关闭 → 重新裁决可播性（`_panelGame` 已为 null）。从「我的库」
    // 进详情的那条链路会在这一步停播，回到 v3.11.1「库页浏览不播视频」的语义；
    // 关详情**不会**重播 / 重计 3 秒（解耦逻辑未动）。
    _syncBackdropPlayable();
    // 锁定态关面板: 焦点回到进入面板前的锚点 (海报卡片/舞台按钮)
    //
    // 🔴 必须放到 **post-frame**：此刻 rail/stage 的 `ExcludeFocus(excluding:)`
    //    还没随本次重建翻转（detailOpen 刚变 false），同步 requestFocus 会被
    //    「不可聚焦祖先」吞掉 → 焦点悬空 → 手柄 A「按了没反应」。
    // v3.22: 键鼠路径同样回锚（_showGamePanel 键鼠进详情时已记录触发卡片），
    // 否则关详情后键盘焦点悬空、方向键失效。锚点节点可能已销毁（如动作表
    // 项），必须带 canRequestFocus/context 防护。
    if (_panelAnchor != null && (_panelLocked || !_gamepadInputMode)) {
      final node = _panelAnchor!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            node.canRequestFocus &&
            node.context != null) {
          node.requestFocus();
        }
      });
    }
    _panelLocked = false;
    _panelAnchor = null;
  }

  /// 二级详情「⋯」拉出菜单的开合状态（v3.14：菜单改为**按钮旁拉出的面板**，
  /// 不再是路由弹窗 —— shell 必须知道它开着，才能让 B「只关菜单不关详情」、
  /// 让 A 直接激活菜单项而不走面板的两段式）。
  final ValueNotifier<bool> _detailMenuOpen = ValueNotifier(false);

  /// 库页分类匣面板开关（库页监听它收面板；手柄 B / LB-RB 在这里写 false）
  final ValueNotifier<bool> _categoryBoxOpen = ValueNotifier(false);

  /// 二级详情「声音」开关（v3.14）：写 game.json 的每游戏静音标记，
  /// 并对**当前正在播放**的背景视频即时生效。
  Future<void> _toggleDetailSound(LibraryGame game) async {
    final muted = !BpmBackdropMedia.isGameMuted(game.metaDataDir);
    final ok = await BpmBackdropMedia.setGameMuted(game.metaDataDir, muted);
    // 写盘失败 → 不同步内存态，避免「界面显示与实际播放不一致」
    if (!ok || !mounted) return;
    _backdropMedia.applyGameMuted(muted);
    setState(() {}); // 刷新按钮图标
    AppSnackBar.info(context, muted ? '已静音该游戏背景声音' : '已开启该游戏背景声音');
  }

  /// 详情「播放 OP」：**不收起详情**，直接原地重播（v3.14 用户拍板）。
  ///
  /// 不受「本会话该游戏已自动播过」的限制（那是自动播放的规则）。
  void _replayOpVideo(LibraryGame game) {
    // v3.14：**不再收起详情** —— 二级详情已是全屏整页、右侧就是露出背景的区域，
    // 原地重播即可（用户拍板）。静音状态也随每游戏标记即时生效。
    _backdropMedia.applyGameMuted(BpmBackdropMedia.isGameMuted(game.metaDataDir));
    _backdropMedia.replayFor(game.metaDataDir);
  }

  // ============ v3.8 手柄语义层 ============

  /// 映射弹窗挂载期间桥接的手柄按键（A=确认/保存，B=跳过/不保存）。
  ///
  /// 🔴 必须在 `_modalOpen` / `_bpmModalDepth` 判定**之前**调用 —— 弹窗本身
  /// 就是模态路由，走老路径 A 会被「模态吞键」吞掉，B 会误 pop 弹窗。
  bool _tryGamepadDialogRoute(_GamepadPromptButton button) {
    final confirm = GamepadDialogBridge.confirm;
    final dismiss = GamepadDialogBridge.dismiss;
    if (confirm == null || dismiss == null) return false;
    switch (button) {
      case _GamepadPromptButton.confirm:
        confirm();
      case _GamepadPromptButton.back:
      case _GamepadPromptButton.mark:
      case _GamepadPromptButton.systemMenu:
        dismiss();
    }
    return true;
  }

  /// A 键: 组件模式 → 激活当前控件 (等价 Enter); 板块模式 → 进入板块。
  ///
  /// 面板打开时保留 v3.9 的两段式: 第一次 A 把焦点交给面板主启动按钮,
  /// 第二次 A 才激活面板内控件。
  void _handleGamepadConfirm() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    // v3.19: 虚拟键盘打开 → A = 按下当前键位（键盘是最高层输入面）
    if (_vkVisible) {
      _vkKey.currentState?.pressSelected();
      return;
    }
    if (_tryGamepadDialogRoute(_GamepadPromptButton.confirm)) return;
    // v3.17: A 落在可编辑控件（搜索框 / 编辑窗输入框）= 唤起系统屏幕键盘。
    // 手柄没有文字输入通道；且 `_activateFocused` 的合成 Enter 对
    // EditableText 无响应（不处理 ActivateIntent）—— 旧实现按 A 毫无反馈，
    // 用户感知「搜索 / 编辑手柄没法用」。
    final focus = FocusManager.instance.primaryFocus;
    if (_isEditableFocus(focus)) {
      // v3.19: 自绘虚拟键盘（系统键盘是独立窗口，手柄到不了；自绘键盘
      // 活在 Flutter 树内，手柄焦点可直接导航。「系统键盘」入口保留在
      // 键盘 UI 上，需要中文 IME 时配合物理键盘使用）。
      _openVirtualKeyboard();
      return;
    }
    // v3.10.1: 模态打开 → 手柄只作用于模态。
    // 旧实现在动作表打开时按 X 会**再叠一层动作表**、按 A 会激活背后的卡片,
    // 真机表现为「越按越乱」。
    if (_modalOpen) {
      _ensureModalFocus();
      _activateFocused(FocusManager.instance.primaryFocus);
      return;
    }
    // 模态关闭动画期间：焦点仍停在正在被移除的弹窗控件上，此时激活会
    // 把刚关掉的面板重新打开（「越按越乱」）。窗口只有 250ms，吞掉即可。
    if (_bpmModalDepth > 0) return;
    if (_panelGame != null) {
      // v3.14: 拉出菜单开着 → A 直接激活菜单项（菜单在详情焦点域内，
      // 不走「两段式进入面板内容」，否则 A 会把焦点拽回主启动按钮）
      if (_detailMenuOpen.value) {
        _activateFocused(focus);
        return;
      }
      if (!_panelLocked) {
        _panelLocked = true;
        _panelAnchor = focus;
        // 面板内容操作入口 = footer 主启动按钮 (恒可见,无需 ensureVisible)
        _panelPrimaryNode.requestFocus();
        return;
      }
      _activateFocused(focus); // 锁定态 A = 激活面板内控件
      return;
    }
    if (_zf.isComponentMode) {
      if (focus != null) _activateFocused(focus);
      return;
    }
    // 板块模式: 落点由状态机决定 (一级 stage 只是下钻到二级板块层, 不动焦点)
    _focusZone(_zf.confirm());
  }

  /// B 键: 层级回退 —— 组件模式 → 板块模式 → 一级板块模式。
  ///
  /// 面板开: 锁定态先解锁并回锚点, 否则关面板。
  /// 一级板块模式: 状态机不消费 (保持「B 不误退大屏」的既有约定,
  /// 退出仍走 ESC / 侧栏)。
  void _handleGamepadBack() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    // v3.19: 虚拟键盘打开 → B 只关键盘（焦点仍在输入框，A 可重开；
    // 再按 B 才走完整退出输入态）。否则键盘/输入态无法分层退出。
    if (_vkVisible) {
      _closeVirtualKeyboard();
      return;
    }
    if (_tryGamepadDialogRoute(_GamepadPromptButton.back)) return;
    // v3.18: B 在输入框内 = **完整退出输入状态**（关软键盘 + 取消焦点 +
    // 恢复板块导航）。旧实现什么都不做：焦点仍停在 TextField，此后每一次 A
    // 都落进「唤键盘」分支（去抖内静默返回），真机表现为「A 键所有交互失效」。
    if (_exitEditableFocus()) return;
    // v3.10.1: 模态打开 → B 关掉它 (动作表 / 确认框 / 导入窗口 / 用户面板)
    if (_modalOpen) {
      _popTopModalRoute();
      return;
    }
    // 关闭动画期间：忽略，避免把下一条路由一起弹掉
    if (_bpmModalDepth > 0) return;
    // 分类匣面板开 → B 只关面板（页面监听器负责 closePanel + 焦点回锚）
    if (_categoryBoxOpen.value) {
      _categoryBoxOpen.value = false;
      return;
    }
    // v3.14: 拉出菜单开着 → B 只关菜单，不动详情
    if (_detailMenuOpen.value) {
      _detailMenuOpen.value = false;
      return;
    }
    if (_panelGame != null) {
      if (_panelLocked) {
        _panelLocked = false;
        _panelAnchor?.requestFocus();
        _panelAnchor = null;
        return;
      }
      _dismissPanel();
      return;
    }
    _zf.back();
  }

  /// LB/RB: 页面切换 (主页⇄库); 面板开着先收起。
  ///
  /// 模态打开时忽略 —— 否则会在模态背后偷偷切页。
  void _handleGamepadPageShift(int delta) {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_gamepadModalBlocked) return;
    // 分类匣面板开 → 切页前先收起（页面常驻，不收会跨页残留）
    if (_categoryBoxOpen.value) _categoryBoxOpen.value = false;
    if (_panelGame != null) _dismissPanel();
    _onPageChanged((_currentPage + delta + 2) % 2);
  }

  /// X/Y 键的作用对象: 详情面板 > 当前页焦点游戏。
  ///
  /// 「焦点在哪就作用在哪」—— 手柄没有鼠标指针, 若无此锚点, X/Y 会变成
  /// 「按了没反应」, 正是本次要修掉的体验断点。
  LibraryGame? get _gamepadTargetGame {
    if (_panelGame != null) return _panelGame;
    return _currentPage == 0 ? _stageGame : _libraryFocusedGame;
  }

  /// X: **启动**当前目标游戏（v3.14 用户拍板：移除「双击 A 启动」后改由 X 启动；
  /// 原「X = 动作菜单」在实机上会卡屏且入口已随主页右侧按钮区移除，
  /// 动作菜单仅保留鼠标长按入口）。
  void _handleGamepadContextMenu() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_gamepadModalBlocked) return; // 模态开 / 关闭动画中 → 不再叠加新弹窗
    final game = _gamepadTargetGame;
    if (game == null) return;
    _launchGame(game);
  }

  /// Y: 切换当前项标记/收藏
  void _handleGamepadMark() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_tryGamepadDialogRoute(_GamepadPromptButton.mark)) return;
    if (_gamepadModalBlocked) return;
    final game = _gamepadTargetGame;
    if (game == null) return;
    _toggleMark(game);
  }

  /// Start: BPM 系统菜单 (退出大屏 / 关闭软件 / 最小化)
  void _handleGamepadSystemMenu() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_tryGamepadDialogRoute(_GamepadPromptButton.systemMenu)) return;
    if (_gamepadModalBlocked) return;
    _openExitSheet();
  }

  /// Back(Select): 视图切换 (主页 ⇄ 我的库)
  void _handleGamepadViewToggle() {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    _handleGamepadPageShift(1);
  }

  /// LT/RT: 快速翻屏 (面板内容 / 焦点或高亮板块所在的滚动视图)
  void _handleGamepadTriggerShift(int delta) {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_panelGame != null && _panelScrollController.hasClients) {
      _pageScrollBy(_panelScrollController.position, delta);
      return;
    }
    final ctx = _gamepadScrollContext();
    if (ctx == null) return;
    final scrollable = Scrollable.maybeOf(ctx);
    if (scrollable == null) return;
    final pos = scrollable.position;
    if (!pos.hasContentDimensions) return;
    _pageScrollBy(pos, delta);
  }

  /// 按视口翻一屏 (留 10% 重叠, 避免刚好跳过一整行)
  void _pageScrollBy(ScrollPosition pos, int delta) {
    final step = pos.viewportDimension * 0.9 * delta;
    pos.jumpTo(
      (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// 连接状态变化: 让「手柄有没有被识别」这件事可见 (日志 + 一次性提示)
  /// （2026-09-27 v2：旧的「首次启动询问弹窗」链路已整体移除 —— 启停改为
  /// 启动前确认 + 主页手柄按钮，见 `_launchGame` 与 gamepad_launch_dialogs。）

  void _handleGamepadConnectionChanged(bool connected) {
    _gamepadConnected = connected;
    debugPrint('[BPM][Gamepad] 连接状态: ${connected ? "已连接" : "已断开"}');
    if (!mounted) return;
    if (connected) {
      // 🔴 v3.18: 仅「已连接」**不**进入手柄模式 —— 还差「实际输入」这一步，
      // 否则进 BPM 就默认按手柄处理（用户拍板的第 ① ② 顺序）。
      AppSnackBar.info(context, '手柄已连接（操作后自动切入手柄模式）');
    } else {
      _leaveGamepadMode();
      AppSnackBar.warning(context, '手柄已断开');
    }
  }

  /// 十字键/左摇杆:
  /// - **模态打开** → 在模态内移动 (打开时若无人持焦, 先补焦点);
  /// - **板块模式** → 层级内切换板块 (边界停, **不跨级**);
  /// - **组件模式** → 板块内移动 (**边缘停, 不跨板块** —— 规范第 4 条;
  ///   要换板块必须先按 B 退出组件模式)。
  ///
  /// 🔴 必须用 `FocusTraversalPolicy.inDirection`, 不能用
  /// `findFirstFocusInDirection` —— 后者在 Flutter 3.24.3 里**不做方向过滤**
  /// (把整个 scope 的可聚焦节点按前缘排序后取第一个), 真机实测:
  /// 从左侧栏按「下」会跳到屏幕最上方的顶部栏 (→ 永远选不中「我的库」),
  /// 在主页卡片列表按「左右」会跳到侧栏 (→ 换不了游戏)。这正是用户报的两个 BUG。
  void _handleGamepadDirection(TraversalDirection dir) {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    // v3.19: 虚拟键盘打开 → 方向键 = 键位导航（优先于一切模态/页面语义）
    if (_vkVisible) {
      _vkKey.currentState?.moveFocus(dir);
      return;
    }
    if (_modalOpen) {
      _moveFocusInModal(dir);
      return;
    }
    if (_zf.isZoneMode) {
      _zf.moveZone(dir);
      return;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return;
    _policyFor(focus).inDirection(focus, dir);
  }

  /// 右摇杆: 面板开 → 滚面板内容; 否则滚焦点所在 Scrollable。
  ///
  /// v3.9 修复**轴向错配**: 原实现把 dy 无差别喂给「最近的 Scrollable」,
  /// 而主页 shelf 是 `Axis.horizontal` —— 结果右摇杆上下推会把 shelf 左右
  /// 拽动, 水平推反而被整段丢弃。现在按主轴方向找**轴向匹配**的 Scrollable:
  /// 横推滚 shelf, 竖推滚网格/面板, 没有匹配轴向就不动。
  void _handleGamepadScroll(double dx, double dy) {
    if (!_noteGamepadActivity()) return; // v3.18 热判定闸门
    // 隐藏 UI 态：任意手柄键只做「唤回界面」，不执行语义（v3.12）
    if (_consumeDetailUiHiddenInput()) return;
    if (_panelGame != null && _panelScrollController.hasClients) {
      _jumpScrollBy(_panelScrollController, dy);
      return;
    }
    final ctx = _gamepadScrollContext();
    if (ctx == null) return;
    final horizontal = dx.abs() > dy.abs();
    final pos = _scrollPositionInAxis(ctx, horizontal);
    if (pos == null) return;
    final delta = horizontal ? dx : dy;
    pos.jumpTo(
      (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// 自 [context] 向上找**轴向匹配**且可滚动的 [ScrollPosition]。
  ///
  /// 横向 shelf 可能嵌在纵向容器里, 只认最近的 Scrollable 会让另一个轴向
  /// 永久失效; 这里逐级上溯, 并用 [identical] 跳过同一节点的重复命中。
  ScrollPosition? _scrollPositionInAxis(BuildContext context, bool horizontal) {
    final want = horizontal ? Axis.horizontal : Axis.vertical;
    ScrollPosition? found;
    ScrollPosition? previous;
    context.visitAncestorElements((element) {
      final scrollable = Scrollable.maybeOf(element);
      if (scrollable == null) return false;
      final pos = scrollable.position;
      if (identical(pos, previous)) return true; // 同一节点, 继续上溯
      previous = pos;
      if (pos.axis != want || !pos.hasContentDimensions) return true;
      found = pos;
      return false;
    });
    return found;
  }

  void _jumpScrollBy(ScrollController c, double dy) {
    if (!c.hasClients) return;
    final pos = c.position;
    final target =
        (pos.pixels + dy).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    c.jumpTo(target);
  }

  /// 手柄 A 键的「激活」: 先走节点 Enter 回调 (FocusGlow 处理
  /// BpmInteractiveWrapper.onSelect=onTap),未消费再试 ActivateIntent。
  void _activateFocused(FocusNode? focus) {
    if (focus == null || focus.context == null) return;
    final handler = focus.onKeyEvent;
    if (handler != null) {
      final result = handler(
        focus,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
          synthesized: true,
        ),
      );
      if (result == KeyEventResult.handled) return;
    }
    Actions.maybeInvoke(focus.context!, const ActivateIntent());
  }

  /// 退出输入框：关软键盘 + 取消焦点 + 恢复常规手柄导航。
  ///
  /// 返回 true 表示本次 B 已被「退出输入」消费（调用方应直接 return）。
  /// 弹窗内只退输入、不关弹窗 —— 否则改个标题误触 B 就把整个窗口关了。
  bool _exitEditableFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (!_isEditableFocus(focus)) return false;
    SoftKeyboardLauncher.hide();
    focus?.unfocus();
    if (_modalOpen) return true;
    // 焦点被取消后若仍停在「组件模式」，A 会因为没有焦点而无处激活 →
    // 退回板块模式，让 A 重新走「落焦到板块」链路。
    if (_zf.isComponentMode) _zf.back();
    return true;
  }

  // ============ v3.18 输入模式热判定 ============

  /// 手柄语义的统一闸门（每个手柄处理函数第一行调用）。
  ///
  /// 🔴 旧实现只要轮询服务在跑就消费手柄语义 = **进 BPM 默认判定为手柄操作**。
  /// 现按顺序要求：① 已连接；② 产生实际输入 —— 两点都满足才进手柄模式，
  /// 且首次输入**既切换模式也照常执行**（用户按下就得有反馈）。
  /// 热判定：断开连接 / 键鼠介入 → 立刻回键鼠模式并清理手柄导航残留。
  bool _noteGamepadActivity() {
    if (_gamepadInputMode) return true;
    if (!(_gamepadConnected || _gamepad.isConnected)) return false;
    _enterGamepadMode();
    return true;
  }

  void _enterGamepadMode() {
    _gamepadInputMode = true;
    // v3.19: 焦点体系（板块划分/板块高亮）只属于手柄模式 —— 首次真实
    // 手柄输入时才启用（旧实现 controller 一创建就是 zone 模式 = 进 BPM
    // 默认焦点模式，键鼠用户一进来就看到焦点区域划分，判定错误）。
    _zf.enableFocusMode();
    debugPrint('[BPM][InputMode] → 手柄模式（① 已连接 ② 实际输入）');
    if (mounted) AppSnackBar.info(context, '已切换为手柄操作');
  }

  /// 回到键鼠模式 + **清理手柄导航残留状态**（模式切换不留尾巴）：
  /// 拉出菜单收起 / 面板锁定解除 / 隐藏 UI 恢复 / 焦点退出板块模式 /
  /// 软键盘关闭。
  void _leaveGamepadMode() {
    if (!_gamepadInputMode) return;
    _gamepadInputMode = false;
    debugPrint('[BPM][InputMode] → 键鼠模式（清理手柄导航状态）');
    _detailMenuOpen.value = false;
    _panelLocked = false;
    _panelAnchor = null;
    // 隐藏 UI 是手柄观景功能：键鼠模式下必须恢复，否则屏幕上只剩背景，
    // 没有任何可点控件（真机「卡死」的另一种来源）。
    if (_detailUiHidden) _setDetailUiHidden(false);
    // v3.19: 焦点体系随手柄模式一起停用（板块高亮消失、组件环恢复常规）
    _zf.disableFocusMode();
    SoftKeyboardLauncher.hide();
    if (mounted) setState(() {});
  }

  /// 鼠标 / 触摸介入（手柄走 FFI 轮询，**不产生** pointer 事件 → 不会误切）。
  void _onPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) _onUserInputDetected();
  }

  /// 焦点是否落在可编辑文本控件（TextField / EditableText）上。
  ///
  /// TextField 把 focusNode 挂进 EditableText 内部的 Focus，沿祖先找
  /// [EditableTextState] 即可命中；兜底再看 context 自身的 widget
  /// （不同 Flutter 版本挂接位置有差异）。
  bool _isEditableFocus(FocusNode? node) {
    if (node == null || node.context == null) return false;
    final ctx = node.context!;
    return ctx.findAncestorStateOfType<EditableTextState>() != null ||
        ctx.widget is EditableText;
  }

  // ════ v3.10 分层板块焦点: 状态机接线 ════

  /// BPM 之上是否压着模态路由 (动作表 / 确认框 / 导入窗口 / 用户面板)。
  ///
  /// 🔴 模态打开时手柄必须**只作用于模态**: 否则 X 会不断叠加新的动作表、
  /// LB/RB 会在背后偷偷切页、A 会激活模态背后的卡片 —— 真机表现为
  /// 「按了没反应 / 越按越乱 / 像卡死」。
  bool get _modalOpen {
    final route = ModalRoute.of(context);
    return route != null && !route.isCurrent;
  }

  /// 本 shell 自己发起的模态**尚未收干净**的层数。
  ///
  /// 🔴 为什么 `_modalOpen` 不够（真机「连按 X 就卡死」的机理）：
  /// `Navigator.pop` 会**立刻**把该路由移出 history（于是本 shell 的
  /// `route.isCurrent` 马上回到 true），但 `showGeneralDialog` 的反向过渡
  /// 还要跑 250ms，弹窗 widget 这段时间仍在树上。这 250ms 的窗口里
  /// `_modalOpen == false` → 连按 X 会在**正在关闭**的弹窗上再叠一层，
  /// 快速连按就叠出多层全屏动作表（每层都含全屏遮罩 + 可滚动列表），
  /// 真机表现为卡死。
  ///
  /// 本计数在**打开时同步 +1**、`Future` 完成后 -1，完全不依赖 `ModalRoute`，
  /// 因此「同一个模态没关干净之前不许再开」是结构性的。
  int _bpmModalDepth = 0;

  /// 手柄侧是否应忽略「打开新模态 / 改变页面」类按键
  bool get _gamepadModalBlocked => _bpmModalDepth > 0 || _modalOpen;

  /// 关闭最上层的模态路由（带路由守卫）。
  ///
  /// 🔴 守卫不可省：仓库 `lib/widgets/app_dialog.dart` 已记录过一次同款事故 ——
  /// 无校验的连续 `pop` 会把**下一条路由**一起弹掉，路由栈错乱后主窗口
  /// 表现为卡死。这里用「本 shell 自己的 route 是否 current」判定上方是否
  /// 真的还有模态：不是 current 才 pop，且天然不可能弹掉 shell 自身所在路由。
  void _popTopModalRoute() {
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) return; // 上方已无模态
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    navigator.pop();
  }

  /// 焦点所属的遍历策略: 板块域内用该域自己的策略, 模态内用兜底策略。
  FocusTraversalPolicy _policyFor(FocusNode node) {
    final ctx = node.context;
    if (ctx == null) return _fallbackPolicy;
    return FocusTraversalGroup.maybeOf(ctx) ?? _fallbackPolicy;
  }

  /// 把焦点送进某个板块。
  ///
  /// 落点由控制器现算 (优先该域上次落焦的组件, 否则域内第一个可聚焦组件),
  /// 并经 `policy.requestFocusCallback` 落焦 —— 与框架 Tab / 方向键同源,
  /// **自带 `Scrollable.ensureVisible`**, 不会把焦点丢到视口外的卡片上。
  /// 域尚未挂载 (切页首帧 / 列表为空) 时下一帧重试一次。
  void _focusZone(BpmZoneId? zone) {
    if (zone == null) return;
    if (_zf.focusEntryOf(zone)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _zf.focusEntryOf(zone);
    });
  }

  /// 模态内若还没有任何控件持焦, 把焦点补到模态内第一个可聚焦控件。
  ///
  /// 没有这一步, 「打开确认框后方向键和 A 全都没反应」—— 因为焦点还停在
  /// 模态外的原控件上, 而模态有独立 FocusScope。
  void _ensureModalFocus() {
    var node = FocusManager.instance.primaryFocus;
    // 🔴 v3.17: 焦点若落在模态**之下**的页面里（isCurrent=false 表示上方
    // 还有模态），必须视作「模态内无焦点」—— 沿根作用域的持焦链下探到
    // 最深层作用域（= 顶层模态的 scope），从那里找第一个可聚焦控件。
    // 旧实现直接拿页面里的 scope 判「已有焦点」就 return，方向键 / A
    // 仍继续作用于看不见的页面（编辑弹窗「手柄不支持操作」的根因之一）。
    if (node != null && node.context != null) {
      final route = ModalRoute.of(node.context!);
      if (route != null && !route.isCurrent) node = null;
    }
    FocusScopeNode scope;
    if (node == null) {
      var cur = FocusManager.instance.rootScope;
      while (cur.focusedChild != null) {
        final FocusNode? next = cur.focusedChild;
        if (next is! FocusScopeNode) break;
        cur = next;
      }
      scope = cur;
    } else {
      final FocusScopeNode? s = node.nearestScope;
      if (s == null) return;
      scope = s;
    }
    if (scope.focusedChild != null) return;
    final policy = _policyFor(scope);
    final first = policy.findFirstFocus(scope, ignoreCurrentFocus: true);
    if (first == null || identical(first, scope)) return;
    policy.requestFocusCallback(first);
  }

  /// 模态内的方向移动
  void _moveFocusInModal(TraversalDirection dir) {
    _ensureModalFocus();
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return;
    _policyFor(current).inDirection(current, dir);
  }

  /// 焦点变化 → 若当前是板块模式, 说明这次变化来自鼠标 / 键盘 / 程序化调用
  /// (手柄在板块模式下刻意不动焦点), 于是切回组件模式, 焦点环随之恢复。
  void _onPrimaryFocusChanged() {
    if (!mounted) return;
    final node = FocusManager.instance.primaryFocus;
    final zone = _zf.zoneOfScope(node?.nearestScope);
    if (zone == null) return;
    // 🔴 `_userInputSeen` 闸门: 启动期 shelf 首卡的 autofocus 也会走到这里,
    //    不算用户操作, 不得据此切模式 (否则启动落点不再是 rail 板块模式)。
    if (!_zf.isPanelOpen && _zf.isZoneMode && _userInputSeen) {
      _zf.focusIntoZone(zone);
    }
  }

  /// 键盘事件 (任一键) → 视为键鼠介入。
  ///
  /// 永远返回 false, 不消费事件, 键盘原有行为（Tab / 方向键遍历）完全不变。
  ///
  /// 🔴 v3.21 豁免：虚拟键盘的 IME 转发（`BpmImeBridge.sendTextAsKeys`）
  /// 经 SendInput 注入的按键会再次进入本通道 —— 不豁免的话每打一个拼音
  /// 字母都会触发「键鼠介入」退出手柄模式，虚拟键盘的手柄导航当场失灵。
  bool _onHardwareKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && !BpmImeBridge.isForwarding) {
      _onUserInputDetected();
    }
    return false;
  }

  /// 鼠标 / 键盘一旦介入 → 退出板块选择模式（组件焦点环恢复、板块高亮让位）。
  ///
  /// 🔴 这是「保留原有鼠标操作」的机械保证：手柄刻意不经 pointer/keyboard
  /// 通道, 所以板块模式不会被手柄自己的操作打断, 也不会被误退出。
  void _onUserInputDetected() {
    _userInputSeen = true;
    // v3.18 热判定：键鼠一介入就回键鼠模式（并清理手柄导航残留）
    _leaveGamepadMode();
    if (_zf.isPanelOpen || !_zf.isZoneMode) return;
    final zone =
        _zf.zoneOfScope(FocusManager.instance.primaryFocus?.nearestScope);
    if (zone != null) {
      _zf.focusIntoZone(zone); // 连板块一起归位到焦点所在
    } else {
      _zf.exitZoneMode(); // 焦点不在任何板块 → 仅退出板块模式
    }
  }

  /// 右摇杆 / LT·RT 的滚动目标上下文。
  ///
  /// - 组件模式 → 当前焦点所在位置;
  /// - 板块模式 → **当前高亮板块内最近落焦的组件** —— 板块模式下刻意不动焦点,
  ///   若仍按 primaryFocus 找 Scrollable, 会滚到上一个板块去。
  BuildContext? _gamepadScrollContext() {
    if (_zf.isComponentMode) {
      return FocusManager.instance.primaryFocus?.context;
    }
    return _zf.entryFocusOf(_zf.zone)?.context;
  }

  /// 启动游戏 (hero 启动按钮 / 动作表触发)
  ///
  /// 走 [GameLaunchService] 共享服务,与桌面模式行为一致。
  /// ★ H11: UI 层双重启动保护。
  Future<void> _launchGame(LibraryGame game) async {
    if (_isLaunching) {
      debugPrint('[LAUNCH] ⏭️ BPM UI 层拦截：上一次启动仍在进行中');
      return;
    }
    _isLaunching = true;
    try {
      // v3.10.2: 启动链路（解析启动项 → Magpie 超分 / 转区）有可感知耗时，
      // 期间界面看起来"没反应"。先给一条即时反馈，避免用户误判为卡死而连按。
      if (mounted) AppSnackBar.info(context, '正在启动《${game.title}》…');
      var exePath =
          await GameLaunchService.instance.resolveUserChoice(game.title);
      if (exePath == null && mounted) {
        // 🔴 2026-09-27 用户拍板：BPM 内直接给启动程序选择面板（与桌面版
        // 同体验），不再要求「先去桌面模式设置」。
        await _openLaunchManager(game);
        exePath = await GameLaunchService.instance.resolveUserChoice(game.title);
        if (exePath == null) return; // 用户取消选择
      }
      if (!mounted) return;

      // 🔴 手柄映射启动决策（2026-09-28 用户澄清的最终语义）：
      // - **主页「手柄」面板已开启** = 该游戏默认使用手柄映射 → **不弹窗**
      //   直接映射启动（想常驻映射的游戏开一次即一劳永逸）；
      // - **未开启/未配置** → **每次启动都弹「手柄映射确认」**让用户当场
      //   决定（当场开启会记住，下次不再问；「本次不使用」不改开关）。
      final pref =
          await GamepadAdaptationCoordinator.instance.resolveLaunchPref(game.title);
      if (pref != null && !pref.enabled) {
        final options =
            await GamepadAdaptationCoordinator.instance.loadPresetOptions();
        final choice = await GamepadLaunchConfirmDialog.show(
          context,
          gameId: pref.gameId,
          gameTitle: pref.gameTitle,
          initialEnabled: pref.enabled,
          initialPresetId: pref.presetId,
          presetOptions: [
            for (final (id, label) in options) GamepadPresetOption(id, label),
          ],
        );
        if (choice == null) return; // 关闭弹窗 = 取消启动
        if (!choice.useMapping) {
          debugPrint('[LAUNCH] 本次不使用手柄映射: ${game.title}');
        }
      } else if (pref != null) {
        debugPrint('[LAUNCH] 手柄映射面板已开启，直接映射启动: ${game.title}');
      }

      final result =
          await GameLaunchService.instance.executeLaunch(game, exePath!);
      if (!result.success && mounted) {
        AppSnackBar.error(context, result.error ?? '无法启动游戏');
      } else if (result.success) {
        // v3.3: 游玩历史埋点 (启动时间 + 模式),供详情面板历史/次数统计
        final mode = result.upscalingMode == 'magpie'
            ? 'upscaling'
            : (result.localeMode == 'japanese' ? 'locale' : 'normal');
        await BpmPlayHistory.recordLaunch(game.metaDataDir, mode: mode);
      }
      if (mounted) setState(() {});
    } finally {
      _isLaunching = false;
    }
  }

  /// 标记切换 (动作表 / Y 键触发)
  ///
  /// 🔴 只能**切换一次**: 旧实现先自己调 `LocalGameRegistry.toggleMark`,
  /// 又调 `widget.onToggleMark`（MainContainer 内部同样调 `toggleMark`）——
  /// 两次互相抵消, 真机上表现为「Y 键按了没反应, 只是闪一下」。
  /// 现在统一交给宿主的回调, 没有回调时才自己兜底。
  void _toggleMark(LibraryGame game) {
    final callback = widget.onToggleMark;
    if (callback != null) {
      callback(game.title);
    } else {
      LocalGameRegistry.instance.toggleMark(game.title);
    }
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
    if (_panelGame?.title == game.title) _dismissPanel();
    widget.onDelete?.call(game.title);
    setState(() {});
  }

  /// 编辑游戏信息 (v3.3,BPM 主题编辑窗口)
  Future<void> _openGameEdit(LibraryGame game) async {
    await BpmGameEditDialog.show(context, game: game);
    if (mounted) setState(() {});
  }

  /// 背景图调整 (v3.3,拖动定位+缩放实时预览,保存后重建 backdrop)
  /// 背景管理窗口（v3.11.1）：背景图 / 背景视频的选择、上传、删除、命名，
  /// 「调整背景图位置」入口在窗口内部（复用 [BpmBackdropTuner]）。
  Future<void> _openBackgroundManager(LibraryGame game) async {
    await BpmBackgroundManagerDialog.show(
      context,
      game: game,
      onChanged: () {
        _reloadBackdropAdj();
        // 选中视频可能变了 → 停掉当前播放，按新选择重新计时
        _backdropMedia.refresh();
        if (mounted) setState(() {});
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _openBackdropTuner(LibraryGame game) async {
    await BpmBackdropTuner.show(
      context,
      title: game.title,
      metaDataDir: game.metaDataDir,
      // v3.11.1：预览图改为「当前所选背景图」（此前恒为封面，调参时对不上）
      imagePath: _resolveBackdropPath(game),
      onSaved: () {
        _reloadBackdropAdj();
        if (mounted) setState(() {});
      },
    );
    if (mounted) setState(() {});
  }

  /// 打开游戏安装目录 (v3.3)
  Future<void> _openGameDirectory(LibraryGame game) async {
    final dirPath = game.directoryPath;
    if (dirPath.isEmpty) {
      if (mounted) AppSnackBar.warning(context, '该游戏没有安装目录信息');
      return;
    }
    if (!Directory(dirPath).existsSync()) {
      if (mounted) AppSnackBar.warning(context, '游戏目录不存在: $dirPath');
      return;
    }
    await Process.start('explorer', [dirPath]);
  }

  /// 长按游戏卡片 / 手柄 X 键 → 弹出动作表
  ///
  /// 🔴 条目必须覆盖桌面右键菜单的全部能力（详情 / 启动管理 / 加入收藏夹 /
  /// 存档备份 / 删除），否则「手柄能完成鼠标的全部操作」不成立。
  void _showActionSheet(LibraryGame game) {
    if (_bpmModalDepth > 0) return; // 关闭动画期间不得叠加
    _bpmModalDepth++;
    BigPictureActionSheet.show(
      context: context,
      gameTitle: game.title,
      onDetails: () => _showGamePanel(game),
      onToggleMark: () => _toggleMark(game),
      onCollection: () => BpmCollectionPicker.show(context, game),
      onLaunchManager: () => _openLaunchManager(game),
      onBackup: () => SaveBackupDialog.show(
        context,
        gameName: game.title,
        installDir: game.directoryPath,
        manifestEntry: ManifestService.instance.lookup(game.title),
      ),
      onDelete: () => _deleteGame(game),
    ).whenComplete(() => _bpmModalDepth--);
  }

  @override
  Widget build(BuildContext context) {
    // v3.5: 移除系统标题栏 (CustomTitleBar)。
    // 大屏模式下窗口按钮毫无意义且与 Cinema 舞台突兀; 退出/最小化能力
    // 已迁至侧边栏底部按钮 → BpmExitSheet 三选一。
    final Widget shell = BpmInputModeScope(
      // v3.20: 输入模式热判定结论下发到引导类 UI（键帽图标自动切换）
      mode: _gamepadInputMode
          ? BpmInputMode.gamepad
          : BpmInputMode.keyboardMouse,
      child: BpmShortcuts(
      onToggleBpm: () => BigPictureManager.instance.toggle(),
      onEscape: _onEscape,
      onFocusSearch: _onFocusSearch,
      child: AnimatedBuilder(
        // 同时监听桌面主题与 BPM 自有主题 (深浅切换需整体重建)
        animation: Listenable.merge([
          AppThemeManager.instance,
          BpmThemeController.instance,
        ]),
        builder: (context, _) {
            // 🔴 v3.13（卡死根因修复）: 二级详情打开期间，rail / stage / 顶栏
            //    整体撤出绘制 —— 用户要求「进二级详情时侧边栏 / 底栏 / 顶栏都看不到」。
            //    🔴 必须绑 `_panelGame` 而**不是** `_lastPanelGame`：
            //    `_lastPanelGame` 在关闭后**永不清空**（它只为退场动画保留最后一部
            //    游戏），用它当开关会让 rail/stage/顶栏在关闭详情后**永远 offstage**
            //    —— 屏幕只剩背景层，鼠标点不到任何东西 = 「退出详情直接卡死」。
            //    改绑 `_panelGame` 后：关闭瞬间 rail/stage 即恢复绘制与可聚焦，
            //    详情页在其上淡出（观感反而是「UI 从详情底下浮现回来」）。
            final bool detailOpen = _panelGame != null;
            return Stack(
              fit: StackFit.expand,
              children: [
                // 1. Cinema backdrop 层: 舞台焦点游戏背景 + 渐变遮罩
                //    （二级详情期间它是整个页面的背景，故必须留在绘制队列里）
                _buildBackdrop(),

                // 2. 主体: 左 rail (独立焦点域) + 右 stage (独立焦点域)
                //
                // 🔴 v3.12: 二级详情期间整体撤出绘制。详情页自身只画左侧悬浮
                //    信息面板，其余区域是**透明**的（直接露出底层背景），因此
                //    rail / stage 若仍在绘制就会从透明区域透出来。
                //    用 Visibility(maintainState) 而非条件卸载 —— 区域内页面状态
                //    （库页滚动位置 / 搜索词）与焦点域注册必须原样保留；
                //    ExcludeFocus 保证不可见期间方向键 / Tab 不会把焦点移进去
                //    （同 v3.10.2 对关闭态面板的处理）。
                Visibility(
                  visible: !detailOpen,
                  maintainState: true,
                  child: ExcludeFocus(
                    excluding: detailOpen,
                    child: Row(
                      children: [
                        // ── 一级板块 ①: 左侧导航栏 ──
                        BpmFocusZone(
                          zone: BpmZoneId.rail,
                          // 左边不留外扩: rail 贴屏幕左缘, 负偏移会把左边框推到屏外
                          expand: const EdgeInsets.fromLTRB(0, 12, 4, 12),
                          child: BpmFocusDomain(
                            zone: BpmZoneId.rail,
                            child: BigPictureNavBar(
                              currentPage: _currentPage,
                              onPageChanged: _onPageChanged,
                              onAddGame: _openImportModeSheet,
                              onExitBpm: _openExitSheet,
                            ),
                          ),
                        ),
                        // ── 一级板块 ③: 中间主内容区 (A 进入后下钻为二级板块层) ──
                        Expanded(
                          child: BpmFocusZone(
                            zone: BpmZoneId.stage,
                            expand: const EdgeInsets.all(4),
                            child: BpmFocusDomain(
                              zone: BpmZoneId.stage,
                              child: _buildCurrentPage(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 3. 专属头部栏 (v3.5): 基本透明 + 横向 + 左中留白,
                //    右侧依次 主题切换 / 在线 / 系统状态 / 用户按钮
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  // ── 一级板块 ②: 顶部状态栏（二级详情期间同 rail 一起撤出绘制）──
                  child: Visibility(
                    visible: !detailOpen,
                    maintainState: true,
                    child: ExcludeFocus(
                      excluding: detailOpen,
                      child: BpmFocusZone(
                        zone: BpmZoneId.topBar,
                        expand: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                        child: BpmFocusDomain(
                          zone: BpmZoneId.topBar,
                          child: BpmTopBar(
                            user: widget.currentUser,
                            onOpenUserPanel: widget.onOpenUserPanel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 4. 面板外点击屏障 (v3.4 手感修复): 面板打开时点击浮窗
                //    以外任意区域即收起面板 — 对齐桌面 GameDetailDialog 的
                //    barrierDismissible 语义 (手势竞技场中屏障先注册先胜出,
                //    一次点击只关面板, 不穿透触发下层卡片动作)
                if (_panelGame != null)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _dismissPanel,
                      behavior: HitTestBehavior.translucent,
                    ),
                  ),

                // 4.5 v3.21 手柄切页引导 (LB/RB 主页⇄库页)。
                //     纯快捷键、界面无可见入口 → 手柄新手不可发现, 常驻提示。
                //     仅手柄模式渲染 (组件内部判定) + 受操作引导总开关控制;
                //     二级详情期间随主界面一起撤出 (detailOpen 条件)。
                if (!detailOpen)
                  const Positioned(top: 52, right: 14, child: BpmPageSwitchHint()),

                // 5. 二级游戏详情 (v3.13: **全屏整页**, 取代 v3.3 右侧滑出浮窗)
                //
                // 页面自身只画左缘暗色体积遮罩 + 浮动内容 —— 底层背景 / 遮罩复用
                // 第 1 项的 backdrop，rail / stage / 顶栏已随 `detailOpen` 撤出绘制。
                // 🔴 关闭态必须同时屏蔽焦点与指针 (v3.10.2 + v3.12): 关闭后
                // widget 仍在树上（靠淡出退场），不排除的话方向键能把焦点
                // 移进**看不见的面板**，点击也会被不可见按钮吃掉（真机表现为
                // 「按键作用在莫名其妙的地方」）。
                if (_lastPanelGame != null)
                  IgnorePointer(
                    ignoring: _panelGame == null,
                    child: ExcludeFocus(
                      excluding: _panelGame == null,
                      // 详情自带独立焦点域: 面板内方向移动不会窜到侧栏/卡片墙
                      child: BpmFocusDomain(
                        zone: BpmZoneId.panel,
                        child: BpmGameDetailPage(
                          key: ValueKey('detail_${_lastPanelGame!.title}'),
                          game: _lastPanelGame!,
                          visible: _panelGame != null,
                          uiHidden: _detailUiHidden,
                          onToggleUiHidden: () =>
                              _setDetailUiHidden(!_detailUiHidden),
                          primaryFocusNode: _panelPrimaryNode,
                          scrollController: _panelScrollController,
                          onLaunch: () => _launchGame(_lastPanelGame!),
                          // v3.14: 拉出菜单开合（B 键「只关菜单不关详情」需要）
                          menuOpen: _detailMenuOpen,
                          // v3.14: 每游戏背景声音开关（game.json，写完即时生效）
                          soundMuted: BpmBackdropMedia.isGameMuted(
                              _lastPanelGame!.metaDataDir),
                          onToggleSound: () =>
                              _toggleDetailSound(_lastPanelGame!),
                          onBackdropTune: () =>
                              _openBackgroundManager(_lastPanelGame!),
                          onOpenGamepadConfig: () =>
                              GamepadGameConfigDialog.showForTitle(
                                  context, _lastPanelGame!.title),
                          onEdit: () => _openGameEdit(_lastPanelGame!),
                          onOpenDirectory: () =>
                              _openGameDirectory(_lastPanelGame!),
                          onDelete: () => _deleteGame(_lastPanelGame!),
                          // 仅当该游戏有背景视频时才提供「播放」按钮
                          onReplayOp: BpmBackdropMedia.resolveSelectedVideo(
                                      _lastPanelGame!.metaDataDir) !=
                                  null
                              ? () => _replayOpVideo(_lastPanelGame!)
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            );
        },
      ),
    ),
    );
    // v3.10: 状态机注入 BPM 子树 —— FocusGlow 据此在板块模式下让出焦点环;
    // 根挂 Listener 捕获鼠标介入 (translucent: 不影响任何子组件命中测试)。
    // v3.21: 外层再包 BpmGuideScope（操作引导总开关）—— 引导类组件
    // （键帽角标/侧缘翻页提示/切页提示）经它短路退出；AnimatedBuilder
    // 监听偏好，设置页切换开关后整树立即生效。
    return BpmZoneFocusScope(
      controller: _zf,
      child: AnimatedBuilder(
        animation: BpmGuidePreference.instance,
        builder: (context, _) => BpmGuideScope(
          enabled: BpmGuidePreference.instance.enabled,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _onUserInputDetected(),
            child: shell,
          ),
        ),
      ),
    );
  }

  // ============ Cinema backdrop 层 ============

  /// 全屏背景: 优先舞台焦点游戏封面,回退全局主题背景图,再回退主题底
  ///
  /// v3.5 两项改造:
  /// 1. **清晰度**: 解码宽度由写死的 1920 改为按**物理分辨率**取,
  ///    2K/4K 全屏下不再因解码不足发虚;
  /// 2. **遮罩减负**: 纵横渐变强度整表下调 (原 0x6B/0xDB、0xC7/0x66/0x4D
  ///    过重,画面整体发灰发闷),改由调色板提供,深浅主题各自一套。
  ///    压暗只服务「rail 与文字可读性」,不再全屏蒙一层。
  Widget _buildBackdrop() {
    final themeData = AppThemeManager.instance.current;
    final stageGame = _stageGame;
    // 自定义背景展示图优先，否则回退封面（两者共用裁剪/缩放链路）
    final coverPath =
        stageGame != null ? _resolveBackdropPath(stageGame) : null;

    // 背景视频：图片层与视频层交叉淡入淡出。**无视频时 imageOpacity 恒为 1**，
    // 整棵背景树与改动前逐位一致（零回归）。
    final bool videoActive =
        _backdropMedia.state != BpmBackdropVideoState.idle;
    final double imageOpacity = videoActive ? _backdropMedia.imageOpacity : 1.0;

    // 按物理像素解码 (上限 4096,下限 1280 兜底)
    final double physicalWidth = View.of(context).physicalSize.width;
    final int decodeWidth = physicalWidth.clamp(1280.0, 4096.0).round();

    Widget? imageLayer;
    if (coverPath != null && coverPath.isNotEmpty) {
      // v3.2: 智能裁剪 — 显著性分析选择裁剪窗口 (保人物/脸部),不再中心截取
      final screenAspect = MediaQuery.sizeOf(context).aspectRatio;
      imageLayer = Positioned.fill(
        child: AnimatedOpacity(
          opacity: imageOpacity,
          duration: BpmBackdropMediaController.fadeDuration,
          curve: Curves.easeInOut,
          child: NsfwImage.file(
            coverPath,
            contentKind: NsfwContentKind.cover,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            decodeWidth: decodeWidth,
            child: Transform.scale(
              scale: _backdropAdj?.zoom ?? 1.0,
              alignment: _backdropAdj?.alignment ?? Alignment.center,
              child: BpmSmartAlignedImage(
                path: coverPath,
                cacheWidth: decodeWidth,
                targetAspect: screenAspect,
                manualAlign: _backdropAdj?.alignment,
              ),
            ),
          ),
        ),
      );
    } else if (themeData.hasBackgroundImage) {
      // 回退: 用户设置的全局主题背景图 (v3.0 P1 统一渲染)
      imageLayer = Positioned.fill(
        child: AnimatedOpacity(
          opacity: imageOpacity,
          duration: BpmBackdropMediaController.fadeDuration,
          curve: Curves.easeInOut,
          child: BackgroundImageResolver(
            config: themeData.backgroundImage,
            overlayColor: themeData.background,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 主题底渐变 (深色: 深夜蓝黑渐变微光; 浅色: 现代白渐变微光蓝)
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: BpmColors.baseGradientColors,
            ),
          ),
        ),
        if (imageLayer != null) imageLayer,
        // ── OP 视频层 (2026-09-27) ──
        // 位置: 图片层之上、遮罩之下 —— 视频在「背后播放」, hero/shelf 仍在其上。
        // 非播放态时 controller 为空 / opacity 为 0, 不产生任何视觉影响。
        if (videoActive)
          Positioned.fill(
            child: BpmOpVideoLayer(
              controller: _backdropMedia.controller,
              opacity: _backdropMedia.videoOpacity,
              duration: BpmBackdropMediaController.fadeDuration,
            ),
          ),
        // 微光层 (径向): 叠加在封面之上,给画面一层空气感
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.55, -0.72),
                  radius: 1.15,
                  colors: [
                    BpmColors.glowColor,
                    BpmColors.glowColor.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 纵向遮罩 (顶部压暗衬头部栏 + 底部收深衬 shelf)
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.22, 0.50, 1.0],
                // 播放态用更轻的遮罩 —— 视频要「尽可能清晰」(方案 §4.3)
                colors: _backdropMedia.isPlaying
                    ? BpmColors.backdropScrimVPlaying
                    : BpmColors.backdropScrimV,
              ),
            ),
          ),
        ),
        // 横向遮罩 (左侧压暗衬 rail + hero 文字)
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                stops: const [0.0, 0.28, 0.56, 1.0],
                colors: _backdropMedia.isPlaying
                    ? BpmColors.backdropScrimHPlaying
                    : BpmColors.backdropScrimH,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ============ stage 页面调度 ============

  /// 当前页面内容
  ///
  /// 优先级: 详情页 > 当前导航页
  /// 用 [AnimatedSwitcher] 包裹,实现页面切换 200ms fade 过渡。
  Widget _buildCurrentPage() {
    final pageKey = ValueKey('page_$_currentPage');
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
    switch (_currentPage) {
      case 0:
        return BigPictureHome(
          stageGame: _stageGame,
          onStageGameChanged: _onStageGameChanged,
          onGameLaunch: _launchGame,
          onShowDetailPanel: _showGamePanel,
          onGameLongPress: _showActionSheet,
          onAddGame: _openImportModeSheet,
        );
      case 1:
      default:
        return BigPictureLibraryPage(
          onShowDetailPanel: _showGamePanel,
          onGameLaunch: _launchGame,
          onGameLongPress: _showActionSheet,
          onLaunchManager: _openLaunchManager,
          onDeleteGame: _deleteGame,
          searchFocusNode: _librarySearchFocus,
          onGameFocused: (game) => _libraryFocusedGame = game,
          categoryBoxOpen: _categoryBoxOpen,
        );
    }
  }

  // ============ 添加游戏入口 ============

  /// 点击 rail「添加游戏」/ 空状态按钮 → 弹出导入模式选择 (单文件/批量) →
  /// 弹出导入窗口 (Cinema 外壳内嵌桌面 JoinPage)。
  ///
  /// v3.2: 导入定位为纯功能区,不再占据 stage 页面 — 所有组件窗口化。
  /// 导入实现复用桌面 JoinPage,元数据抓取辅助填充/表单联动/进度对话框
  /// 与桌面模式代码级同源;仅隐藏智能导入入口。
  Future<void> _openImportModeSheet() async {
    if (_bpmModalDepth > 0) return;
    _bpmModalDepth++;
    try {
      await _openImportModeSheetInner();
    } finally {
      _bpmModalDepth--;
    }
  }

  Future<void> _openImportModeSheetInner() async {
    final mode = await BpmImportModeSheet.show(context);
    if (mode == null || !mounted) return;
    final importMode =
        mode == BpmImportMode.batch ? ImportMode.batch : ImportMode.single;
    await showDialog<void>(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.72),
      builder: (_) => _BpmImportWindow(
        mode: importMode,
        batchController: _bpmBatchController,
        onGameAdded: () {
          debugPrint('[BPM][ADD] 入库成功 → 刷新库页/主页');
          setState(() {});
        },
      ),
    );
    if (mounted) setState(() {});
  }
}

/// BPM 导入窗口 (v3.2): Cinema 玻璃外壳 + 桌面 JoinPage 直嵌
///
/// 尺寸自适应: 大屏给足空间 (上限 1240x780),小窗口按屏幕收拢。
/// 关闭按钮/模式标题在顶部;JoinPage 的进度对话框走 root Overlay,不受窗口约束。
class _BpmImportWindow extends StatelessWidget {
  final ImportMode mode;
  final BatchImportController batchController;
  final VoidCallback onGameAdded;

  const _BpmImportWindow({
    required this.mode,
    required this.batchController,
    required this.onGameAdded,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 96).clamp(720.0, 1240.0);
    final height = (screen.height - 96).clamp(560.0, 780.0);
    final modeLabel = mode == ImportMode.batch ? '批量导入' : '单文件导入';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xF5101620),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: BpmColors.deepBase.withOpacity(0.72),
              blurRadius: 60,
              offset: const Offset(0, 26),
            ),
            BoxShadow(
              color: BpmColors.cherryRose.withOpacity(0.10),
              blurRadius: 34,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 窗口标题栏 (Cinema 风格)
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: BpmColors.deepBase.withOpacity(0.55),
                  border: Border(
                    bottom: BorderSide(
                        color: BpmColors.cherryRoseBorder, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: BpmColors.cherryRose,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: BpmColors.cherryRose.withOpacity(0.8),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '添加游戏 · $modeLabel',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                        color: BpmColors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    _WindowCloseButton(onClose: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
              // 桌面 JoinPage 直嵌 (单文件/批量/元数据抓取与桌面同源)
              // v3.5: 推入 BPM 调色板作用域,使内嵌内容与 BPM 主题一致
              Expanded(
                child: _BpmAppColorsScope(
                  child: JoinPage(
                    key: ValueKey('bpm_join_$mode'),
                    initialMode: mode,
                    enableSmartImport: false,
                    batchController: batchController,
                    onGameAdded: () {
                      onGameAdded();
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    },
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

/// [AppColors] 作用域覆盖容器 (v3.5)
///
/// 内嵌的桌面页面 (如 `JoinPage`) 有约 350 处 `AppColors.*` 引用,
/// 无法逐一改造。这里在挂载期间把当前 BPM 调色板推入 `AppColors` 的
/// 覆盖栈,卸载时弹出,从而在不动桌面代码的前提下让内容跟随 BPM 主题。
class _BpmAppColorsScope extends StatefulWidget {
  final Widget child;

  const _BpmAppColorsScope({required this.child});

  @override
  State<_BpmAppColorsScope> createState() => _BpmAppColorsScopeState();
}

class _BpmAppColorsScopeState extends State<_BpmAppColorsScope> {
  late final CTThemeData _data;

  @override
  void initState() {
    super.initState();
    _data = BpmThemeController.instance.palette.toCTThemeData();
    AppColors.pushOverride(_data);
  }

  @override
  void dispose() {
    AppColors.popOverride(_data);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 导入窗口右上角关闭按钮
class _WindowCloseButton extends StatelessWidget {
  final VoidCallback onClose;

  const _WindowCloseButton({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return BpmInteractiveWrapper(
      onTap: onClose,
      semanticsLabel: '关闭导入窗口',
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: BpmColors.panelGlass.withOpacity(0.6),
          shape: BoxShape.circle,
          border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
        ),
        child: Icon(Icons.close_rounded,
            size: 16, color: BpmColors.textSecondary),
      ),
    );
  }
}

/// 首启询问框的手柄桥接按键（仅 `_tryGamepadPromptRoute` 消费）
enum _GamepadPromptButton { confirm, back, mark, systemMenu }
