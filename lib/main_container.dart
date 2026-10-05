import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_theme_manager.dart';
import '../widgets/sidebar.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/floating_user_button.dart';
import '../widgets/floating_task_button.dart';
import '../widgets/running_tasks_banner.dart';
import '../widgets/auth_modal.dart';
import '../widgets/user_profile_modal.dart';
import '../widgets/openlist/openlist_pair_dialog.dart';
import '../services/openlist_provision.dart';
import '../widgets/settings_modal.dart';
import '../widgets/payment_modal.dart';
import '../widgets/animated_overlay.dart';
import '../widgets/app_snack_bar.dart';
import '../pages/library_page.dart';
import '../pages/discover_page.dart';
import '../pages/explore_hall_page.dart';
import '../pages/join_page.dart';
import '../pages/home_page.dart';
import '../pages/game_detail_page.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/local_account_service.dart';
import '../modules/auth/user_model.dart';
import '../pages/login/local_account_setup_dialog.dart';
import '../services/local_game_registry.dart';
import '../services/game_launch_service.dart';
import '../services/game_data_format.dart';
import '../services/user_cache_service.dart';
import '../services/network_status_service.dart';
import '../pages/install_center_page.dart';
import '../pages/join/batch_import_controller.dart';
import '../pages/join/join_controller.dart';
import '../pages/join/widgets/archive_plan_dialog.dart';
import '../services/global_install_center.dart';
import '../services/extract_manager.dart' show ExtractDecisionResult;
import '../big_picture/big_picture_manager.dart';
import '../big_picture/big_picture_shell.dart';
import '../big_picture/big_picture_theme.dart';
import '../big_picture/widgets/bpm_enter_overlay.dart';

// ============ 桌面 ⇄ BPM 模式切换动画常量（2026-10-03） ============
//
// 入场三段（对齐 Steam 大屏切换的观感）：
//   ① 幕布升起：BPM 底色实心层在桌面内容之上快速合拢，把桌面「吞没」；
//      窗口的全屏切换也藏在这一段里（见 BigPictureManager.enter 时序注释）
//   ② 手柄图标描出：幕布中央由**两个光点从同一点出发、一左一右沿手柄轮廓
//      把整个手柄画出来**，合拢后整条边框再**向外柔光闪一下**收尾，作为大屏模式
//      的「加载」指示；「窗口全屏就绪」的闸门与这段动画**并行**，谁慢等谁 ——
//      用户原话：「让这之间有一个会动的东西，保证切换的流畅性，
//      不要让用户干看着黑屏」
//   ③ 幕布揭开 + 镜头推近：幕布淡出，同时大屏外壳从 1.06 回落 1.0 落座
// 出场**不做动画**（用户明确要求：返回桌面无需动画）：进度直达 1、一帧落座。
//
// 总时长 ≈ 150 + max(窗口切换, 540) + 300 ≈ 0.99s（旧方案 1.37s）。
// 540ms 的图标段内部再分给两件事：描出 0.03→0.78、柔光收尾 0.78→1.00（≈119ms）。
// 收尾柔光只是把「画完之后本来就要等的尾段」利用起来，**总时长不变**。
// 设计取舍、性能论证与后续可调项见 docs/DEV/features/bpm_mode_transition.md

/// 幕布升起时长 —— 与窗口全屏切换的推迟量同源（`BigPictureManager.enterCurtainRise`）
const Duration _kBpmCurtainRise = BigPictureManager.enterCurtainRise;

/// 幕布揭开 + 外壳落座时长
const Duration _kBpmReveal = Duration(milliseconds: 300);

/// 幕布升起结束时的进度值（**只是进度标记**，与两段时长的比例无关）。
/// 控制器先 0 → 本值（第一段），停在这里等窗口全屏就绪，再 → 1.0（第二段）。
const double _kBpmCurtainPeak = 0.25;

/// 外壳入场起始缩放（「镜头推近」幅度，越接近 1 越含蓄）
const double _kBpmEnterScale = 1.06;

/// 手柄图标动画时长（幕布合拢后启动，与「窗口全屏就绪」闸门并行）。
/// 图标动画本身就是大屏的「加载」指示，因此它的时长直接决定入场总时长。
/// ⚠️ 太短会「一晃而过」读不出形状，太长就是让用户白等 —— 540ms 是实测手感。
/// 这 540ms 内部包含两件事：轮廓描出（进度 0.03→0.78）+ 收尾柔光（0.78→1.00）。
const Duration _kBpmLogoDuration = Duration(milliseconds: 540);

class MainContainer extends StatefulWidget {
  final VoidCallback? onLogout;

  /// ★ 本地账号体系（docs/DEV/features/local_account_mode.md）：
  /// - [startInLocalMode]：以本地账户状态进入（云端视角 = 匿名只读）。
  /// - [showLocalSetupOnFirstFrame]：需求 2 —— 从登录窗口【以本地游客进入】
  ///   而来，首帧弹出基础信息填写窗口（名字必填/头像·简介可选）。
  /// - [onLocalSetupCompleted]：填写窗口完成后的回调（main.dart 清 pending 标志）。
  final bool startInLocalMode;
  final bool showLocalSetupOnFirstFrame;
  final VoidCallback? onLocalSetupCompleted;

  const MainContainer({
    super.key,
    this.onLogout,
    this.startInLocalMode = false,
    this.showLocalSetupOnFirstFrame = false,
    this.onLocalSetupCompleted,
  });

  /// ★ 启动时同步注入的侧边栏初始收起状态（由 main.dart 在 runApp 前赋值）。
  /// 避免首帧渲染展开态后再异步动画收起导致的「抽搐」。
  static bool initialSidebarCollapsed = false;

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer>
    with TickerProviderStateMixin {
  NavPage _currentPage = NavPage.home;
  GameCardData? _selectedGame;
  bool _showDetailPage = false;

  /// 探索详情页返回栈：栈底为从探索页进入的游戏，
  /// 系列内跳转时逐层压入，返回按钮逐级回退，清空后回到探索页
  final List<GameCardData> _detailGameStack = [];
  /// ★ 本地账号体系：是否处于「本地状态」（本地账户身份，云端匿名只读）。
  /// 登录成功后置 false；退出登录/云端会话失效后，若存在本地账户则重新
  /// 置 true（二分支，见 _onLogout/_handleCloudSessionLost）。
  /// 云端是否已登录由 [_currentUser]（非 local 且非空）推导。
  late bool _isLocalMode = widget.startInLocalMode;

  /// 本地态经用户窗口【登录】转为在线后，自动重开用户窗口展示账号资料。
  bool _reopenUserOverlayAfterLogin = false;

  UserModel? _currentUser;
  OverlayEntry? _authOverlay;

  /// 设置窗口是否以 Navigator 路由形式打开（2026-10-04 路由化，见
  /// _showSettingsOverlay 注释；防重复打开守卫，pop 后由 showDialog.then 复位）。
  bool _settingsRouteOpen = false;
  OverlayEntry? _paymentOverlay;
  // ★ 2026-10-05 遮挡修复：安装中心不再用根 Overlay 的 OverlayEntry 挂载。
  //   框架级根因（flutter navigator.dart:4429 + overlay.dart:754）：Navigator
  //   每次路由 flush 都会 rearrange 自己的路由 entries，并把**不在路由清单里
  //   的外来 entry（安装中心）整体插回最顶层**——导致后弹的决策/报错弹窗
  //   永远被盖住、必须先关安装中心才能操作。改为挂在本壳 Stack 顶层：
  //   盖住普通页面/浮动件（同 Stack 内更晚），又天然位于 Navigator 弹窗
  //   route 之下（弹窗在父级根 Overlay），层级关系由框架保证。
  bool _installCenterVisible = false;
  // UX-03: 各弹窗动画包装器的 key，用于触发退场动画
  // 每次 show 时新建 key，避免快速重开导致 GlobalKey 冲突
  GlobalKey<AnimatedOverlayState>? _authOverlayKey;
  GlobalKey<AnimatedOverlayState>? _paymentOverlayKey;
  GlobalKey<AnimatedOverlayState>? _installCenterOverlayKey;
  bool _isSidebarCollapsed = MainContainer.initialSidebarCollapsed;

  // ============ 桌面 ⇄ BPM 模式切换动画状态（2026-10-03） ============

  /// 入场进度：0 = 幕布未起；[_kBpmCurtainPeak] = 幕布全盖（窗口在此时刻切全屏）；
  /// 1 = 大屏稳态。**出场直接置 1**，跳过全部过渡层（无动画，零额外延迟）。
  late final AnimationController _bpmEnter = AnimationController(
    vsync: this,
    duration: _kBpmCurtainRise, // 仅作兜底时长；实际由两段 animateTo 分别驱动
    value: 1.0,
  );

  /// 手柄图标动画控制器：幕布合拢后启动，与「窗口完成全屏」的闸门**并行**，
  /// 谁慢等谁，两者都完成才揭开。稳态置 1.0（图标层不绘制，不占图层）。
  late final AnimationController _bpmLogo = AnimationController(
    vsync: this,
    duration: _kBpmLogoDuration,
    value: 1.0,
  );

  /// 入场动画的「代号」：每次模式翻转 +1，在途的 [_runBpmEnter] 发现代号变了
  /// 就立刻收工。
  ///
  /// 🔴 必须有这道闸：`animateTo` 的 TickerFuture 在被打断时**主 future 永不
  /// 完成**（ticker.dart `Ticker.stop(canceled: true)` 只 complete 掉 orCancel
  /// 那一路），所以「退出 → 立刻再进入」时，上一轮挂起的协程会在新的一轮里被
  /// 唤醒；只看 `isActive` 的话此时它已是 true，旧协程会把新入场的幕布阶段直接
  /// 跳过。
  int _bpmRunId = 0;

  /// 入场幕布期（跨过峰值前）桌面外壳是否仍留在下层。
  /// 桌面在下层被幕布吞没 → 峰值时卸载（连同其页面状态），卸载帧被不透明幕布盖住。
  ///
  /// 🔴 初值必须是 **false**：本字段只在「入场动画第一段」期间为 true，若初值为
  /// true 且 `MainContainer` 恰好在 BPM 态下被重建（BPM 内退出登录 → 重新登录，
  /// `BigPictureManager.isActive` 仍是 true），桌面外壳会被永久挂在 BPM 外壳背后
  /// （白占内存 + 其氛围层呼吸/任务横幅定时器继续跑）。桌面态不依赖本字段
  /// （`showDesktop = !isActive || _showDesktopDuringEnter`），故初值 false 无损。
  bool _showDesktopDuringEnter = false;

  /// 本次入场幕布取色（进入瞬间取一次，避免逐帧读主题）。
  ///
  /// 取 **BPM 自己的底色**而非桌面主题色：幕布揭开后露出的是 BPM 外壳，若幕布
  /// 用桌面主题色，浅色桌面 → 深色大屏之间会闪一下；用 BPM 底色则全程同色，
  /// 且视觉上读作「进入大屏的黑色画布」（参考 Steam 大屏切换）。
  Color _bpmCurtainColor = BpmColors.deepBase;

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

    // ★ 桌面 ⇄ BPM 模式切换动画：模式翻转驱动「入场过渡 / 出场直达」
    BigPictureManager.instance.addListener(_onBpmModeChanged);

    // ★ 解压流水线（join_unpack_install_center_pipeline.md §C2）：本地压缩包
    //   任务由安装中心执行，其执行期决策弹窗与确认入库窗在此注入——
    //   服务层不持 BuildContext，弹窗统一由壳层提供。
    _bindUnpackPipelineHooks();

    // ★ 启动恢复门闩①：本壳已挂载并监听 → 启动恢复的 enter() 现在可以安全
    //   下发（此前 restoreFromPrefs 若在 auth 完成前触发，notifyListeners 无人
    //   接收，入场动画协程根本不启动 —— 见 big_picture_manager.dart 门闩注释）。
    BigPictureManager.instance.signalShellReady();
    // 防御：若挂载时已处于 BPM 态（如极早恢复 + auth 竞态兜底路径），不存在
    // 「即将开播的入场动画」，直接把门闩②也放行，别让启动初始化干等。
    if (BigPictureManager.instance.isActive) {
      BigPictureManager.instance.signalEnterAnimationDone();
    }

    _loadCurrentUser();
    _loadSidebarState();

    // ★ OpenList 旧内置迁移（2026-10-04）：旧版安装包硬内置的 runtime/openlist
    //   在升级后清除，要求用户走新流程重新对接；新流程对接用户有标记，不受影响。
    //   fire-and-forget，失败只留日志不阻断启动（详见 openlist_provision.dart）。
    OpenListProvision.migrateLegacyIfNeeded();

    // ★ 需求 2：本地游客首帧弹出基础信息填写窗口（不可关闭，完成即注册）。
    if (widget.showLocalSetupOnFirstFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        LocalAccountSetupDialog.show(
          context,
          onCreated: (user) {
            if (!mounted) return;
            setState(() => _currentUser = user);
            widget.onLocalSetupCompleted?.call();
            AppSnackBar.success(context, '欢迎，${user.name}！已以本地身份进入');
          },
        );
      });
    }
  }

  @override
  void dispose() {
    // 切壳动画：先摘监听再销毁控制器（控制器销毁会取消在途动画，_runBpmEnter
    // 里对 animateTo 走 .orCancel + `on TickerCanceled` 的分支即为此准备）
    BigPictureManager.instance.removeListener(_onBpmModeChanged);
    _bpmEnter.dispose();
    _bpmLogo.dispose();
    NetworkStatusService.instance.removeListener(_onNetworkChanged);
    AuthService.onForceLogout = null;
    _unbindUnpackPipelineHooks();
    super.dispose();
  }

  /// ★ 解压流水线：安装中心本地解压任务的弹窗钩子注入（§C2）。
  ///
  /// 五类执行期决策（password/strategy/ambiguity/body/corrupt）弹窗迁移自
  /// join_page 的 decisionProvider 样板；确认入库窗（最终文件夹名 + 删源包
  /// 勾选）复用 showExtractFinishDialog，把 UI 层 ExtractFinishDecision 转
  /// 服务层 UnpackFinishOutcome。弹窗挂本壳 context（root Navigator），
  /// 服务层 await 期间任务停在 awaitingConfirmation 相位、队列不推进。
  void _bindUnpackPipelineHooks() {
    final center = GlobalInstallCenter.instance;
    center.onUnpackDecisionRequest = (request) async {
      if (!mounted) return null;
      switch (request.kind) {
        case 'password':
          final pw = await showPasswordInputDialog(
            context,
            layerIndex: request.layerIndex,
            archiveName: request.archiveFile.split('/').last.split('\\').last,
            format: request.format,
            triedCount: request.triedCount,
          );
          if (pw == null) return null;
          return ExtractDecisionResult(password: pw);
        case 'strategy':
          return showStrategyDecisionDialog(context, request: request);
        case 'ambiguity':
          return showAmbiguityDecisionDialog(context, request: request);
        case 'body':
          return showBodyNotFoundDialog(context, request: request);
        case 'corrupt':
          return showCorruptDecisionDialog(context, request: request);
        default:
          return null;
      }
    };
    center.onUnpackFinishConfirm = (
        {required InstallTask task,
        required String extractedDir,
        required String sourceArchivePath}) async {
      if (!mounted) return null;
      final decision = await showExtractFinishDialog(
        context,
        extractedDir: extractedDir,
        sourceArchivePath: sourceArchivePath,
      );
      if (decision == null) return null;
      return UnpackFinishOutcome(
        finalDirName: decision.finalDirName,
        deleteSourceArchive: decision.deleteSourceArchive,
      );
    };
    center.onUnpackImportCompleted = (title) {
      if (!mounted) return;
      AppSnackBar.success(context, '《$title》解压入库完成');
    };
    center.onUnpackImportCancelled = (message) {
      if (!mounted) return;
      AppSnackBar.warning(context, message);
    };
    // ★ 2026-10-05 流程语义修正（解压完成≠入库）：确认窗点完「完成」后
    //   解压流程即结束，不再自动入库。把解压产物目录放进 JoinPage 的静态
    //   信箱（JoinController.pendingExtractedDir），切到添加页由用户自行
    //   填数据、自行点确认入库。
    center.onUnpackReadyForManualImport = (extractedDir, suggestedName) {
      if (!mounted) return;
      JoinController.pendingExtractedDir.value = extractedDir;
      setState(() => _currentPage = NavPage.join);
      AppSnackBar.success(
          context, '解压完成，已带回添加页（$suggestedName），请审核数据后确认入库');
    };
  }

  /// 解绑解压流水线弹窗钩子（壳销毁后服务层不得再触达本壳 context）
  void _unbindUnpackPipelineHooks() {
    final center = GlobalInstallCenter.instance;
    center.onUnpackDecisionRequest = null;
    center.onUnpackFinishConfirm = null;
    center.onUnpackImportCompleted = null;
    center.onUnpackImportCancelled = null;
    center.onUnpackReadyForManualImport = null;
    // 清空信箱，防止销毁后残留值被下次会话误消费
    JoinController.pendingExtractedDir.value = null;
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
  /// （AuthService.verifyTokenInBackground 内部已先调 logout() 清凭据。）
  void _onForceLogout() {
    if (!mounted) return;
    AppSnackBar.warning(context, '登录已过期，请重新登录');
    _handleCloudSessionLost();
  }

  /// ★ 云端会话失效 —— 与退出登录同二分支：
  /// 存在本地账户 → 落回本地态继续使用；无 → 通知外层回登录窗口。
  Future<void> _handleCloudSessionLost() async {
    _closeAuthOverlay();
    if (!mounted) return;
    if (await LocalAccountService.exists) {
      setState(() {
        _isLocalMode = true;
      });
      await _loadCurrentUser();
    } else {
      setState(() {
        _isLocalMode = false;
        _currentUser = null;
      });
      widget.onLogout?.call();
    }
  }

  /// ★ 网络恢复后的同步：后台刷新 token + 重新加载用户信息。
  /// DiscoverPage 自身监听 NetworkStatusService，会自动刷新游戏列表。
  Future<void> _syncAfterRecovery() async {
    await AuthService.verifyTokenInBackground();
    await _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    debugPrint('[AUTH] MainContainer: 加载当前用户信息...');
    // ★ 本地账号体系：本地状态下身份来自 LocalAccountService
    // （与云端凭据隔离；云端视角 = 匿名，不产生任何带 token 请求）。
    if (_isLocalMode) {
      final local = LocalAccountService.load();
      if (!mounted) return;
      setState(() => _currentUser = local);
      return;
    }
    final user = await AuthService.getCurrentUser();
    if (mounted) {
      setState(() {
        _currentUser = user;
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
      _detailGameStack.clear();
    });
  }

  void _onGoDiscover() {
    setState(() => _currentPage = NavPage.discover);
  }

  void _onGameTap(GameCardData game) {
    setState(() {
      _selectedGame = game;
      _showDetailPage = true;
      // 从探索页进入：重置返回栈
      _detailGameStack
        ..clear()
        ..add(game);
    });
  }

  void _onDetailBack() {
    setState(() {
      if (_detailGameStack.length > 1) {
        // 系列内跳转产生了层级：逐级回退到上一个游戏
        _detailGameStack.removeLast();
        _selectedGame = _detailGameStack.last;
      } else {
        // 栈底（或栈空）：回到探索页
        _showDetailPage = false;
        _detailGameStack.clear();
      }
    });
  }

  /// 分级首级「列表」：直接回探索页游戏列表（清空整个导航栈），
  /// 不做逐级回退——首页语义
  void _onBackToList() {
    setState(() {
      _showDetailPage = false;
      _detailGameStack.clear();
    });
  }

  /// 系列内跳转：浏览器式历史管理
  ///
  /// **历史折叠（forward-collapse）**：目标作品已在返回栈中 →
  /// 截断栈到该位置（跳回去），而不是追加重复记录。
  /// 这消灭了"两部作品互相点击导致 A,B,A,B 无限压栈、
  /// 返回键逐级回退打转"的循环问题——同一作品在栈中永远只有一份。
  /// 新作品才真正压栈，返回按钮逐级回退一层。
  void _onNavigateToGameFromDetail(
      String gameId, String title, String coverUrl) {
    debugPrint('[DETAIL] 系列内跳转 → $title ($gameId)');
    setState(() {
      final existingIdx =
          _detailGameStack.indexWhere((g) => g.id == gameId);
      if (existingIdx >= 0) {
        // 已在栈中：截断到该位置（面包屑回跳也走这里）
        _detailGameStack.removeRange(
            existingIdx + 1, _detailGameStack.length);
        _selectedGame = _detailGameStack.last;
      } else {
        // 新作品：压栈
        _selectedGame = GameCardData(
          id: gameId,
          title: title,
          coverPath: coverUrl,
        );
        _detailGameStack.add(_selectedGame!);
      }
      _showDetailPage = true;
    });
  }

  void _onGoToLibraryFromDetail() {
    debugPrint('[DETAIL] 前往库中查看（仅跳转，不触发入库）');
    setState(() {
      _showDetailPage = false;
      _detailGameStack.clear();
      _currentPage = NavPage.library;
    });
  }

  void _onFloatingTaskTap() {
    debugPrint('[ACTION] 悬浮按钮点击 → 打开全局安装中心');
    _showInstallCenter();
  }

  void _showInstallCenter() {
    if (_installCenterVisible) return;
    final key = GlobalKey<AnimatedOverlayState>();
    _installCenterOverlayKey = key;
    setState(() => _installCenterVisible = true);
  }

  void _closeInstallCenter() {
    if (!_installCenterVisible) return;
    final key = _installCenterOverlayKey;
    _installCenterOverlayKey = null;
    key?.currentState?.dismiss();
  }

  /// AnimatedOverlay 退场动画完成后的复位（Stack 槽位消失）
  void _onInstallCenterDismissed() {
    if (!mounted) return;
    setState(() {
      _installCenterVisible = false;
      _installCenterOverlayKey = null;
    });
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
    // ★ IMP-01 数据安全护栏（2026-09-12 导入审查）：本地导入游戏的"本体目录"
    // 就是用户自己的文件夹（位于应用目录之外），护栏会拒绝删除。
    // 此处取出路径与可删除性，用于确认框如实提示与结果回执。
    final String bodyPath = LocalGameRegistry.instance.gameBodyPath(gameTitle);
    final bool bodyDeletable =
        LocalGameRegistry.instance.canDeleteGameBody(gameTitle);

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
                  fontSize: 13,
                  color: deleteLocalFiles
                      ? AppColors.dangerRed
                      : AppColors.primaryText,
                  height: 1.5,
                ),
              ),
              // ★ IMP-01: 勾选删除且本体在应用目录之外时，明确告知"应用不会删除它"
              if (deleteLocalFiles && !bodyDeletable && bodyPath.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '注意：本游戏为本地导入，本体目录在应用目录之外：\n$bodyPath\n'
                  '出于安全考虑，应用不会删除该目录，需你手动处理。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.dangerRed,
                    height: 1.5,
                  ),
                ),
              ],
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

      // ★ IMP-01: 记录已移除但本体被护栏跳过的路径（位于应用目录之外）
      final skipped = shouldDeleteFiles
          ? LocalGameRegistry.instance.skippedBodyPaths
          : const <String>[];

      if (mounted) {
        if (success && skipped.isNotEmpty) {
          AppSnackBar.warning(context,
              '已从库中移除「$gameTitle」，但本地文件未删除（位于应用目录之外）：${skipped.first}\n请手动处理。');
        } else if (success) {
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
    // ★ IMP-01: 被护栏跳过删除的本体路径（位于应用目录之外）
    final List<String> skippedBodyPaths = [];

    for (final title in gameTitles) {
      bool success;
      if (deleteLocalFiles) {
        success = await LocalGameRegistry.instance.deleteGame(title);
        if (success) {
          skippedBodyPaths.addAll(LocalGameRegistry.instance.skippedBodyPaths);
        }
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
      if (failCount == 0 && skippedBodyPaths.isNotEmpty) {
        // ★ IMP-01: 记录已移除，但受护栏保护的本体目录未删除 → 如实告知
        AppSnackBar.warning(context,
            '已移除 $successCount 个游戏记录，其中 ${skippedBodyPaths.length} 个本地文件未删除（位于应用目录之外），请手动处理。');
      } else if (failCount == 0) {
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

  /// ★ 本地账号体系：用户按钮总是弹用户窗口（UserProfileModal 双态），
  /// 不再「未登录弹 AuthModal」。本地态窗口内提供【登录】按钮（onLogin），
  /// 点击后关闭用户窗口并打开登录浮层。
  void _showAuthOverlay() {
    // 🔴 对接流程进行中禁止用户窗口弹回顶层（2026-10-03）：用户窗口是
    // root Overlay 顶层 entry，恒在一切路由之上（09-27 设置窗口同坑先例），
    // 250ms 关窗间隙内若被重新拉起，会把随后的对接窗口重新盖住。
    if (_pairInFlight) return;
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
        child: _buildProfileModal(),
      ),
    );
    _authOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  bool _pairInFlight = false;

  /// 「对接 / 更新对接」（2026-10-03 层级修复）：用户窗口点对接按钮后，
  /// 组件内直接 showDialog 的对接窗口会被钉顶的用户窗口完全遮挡。
  /// 沿「登录按钮」同款模式（main_container.dart:886-889 同源先例）：
  /// 关用户窗口 → 等退场 entry 移除 → 弹对接窗口（此时无钉顶 entry，
  /// 正常居于最上）→ 结束后重开用户窗口（重开实例 initState 自动重新
  /// 探测对接状态，「更新对接」语义无需额外回传）。
  Future<void> _handleOpenPair(bool isUpdate) async {
    if (_pairInFlight) return;
    _pairInFlight = true;
    _closeAuthOverlay();
    // 等退场动画结束（reverseDuration 200ms）再弹，避免残影挡住 dialog 首帧
    await Future.delayed(const Duration(milliseconds: 250));
    try {
      if (mounted) {
        await OpenListPairDialog.show(context, isUpdate: isUpdate);
      }
    } finally {
      _pairInFlight = false;
      if (mounted) _showAuthOverlay();
    }
  }

  /// 打开登录/注册浮层（AuthModal）。与用户窗口共用同一 Overlay 槽位；
  /// 若用户窗口正打开则先关闭（退场动画期间短暂并存，onDismissed 有
  /// 槽位守卫，不会误清新 entry）。
  void _showLoginOverlay() {
    _closeAuthOverlay();
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
        child: _buildAuthModal(),
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

  Future<void> _onLoginSuccess() async {
    debugPrint('[ACTION] 登录成功回调 → 设置登录态，加载用户数据');
    final reopen = _reopenUserOverlayAfterLogin;
    _reopenUserOverlayAfterLogin = false;
    setState(() {
      _isLocalMode = false; // 本地 → 在线；本地资料保留（不删 local_account_*）
    });
    // v1.4：先等用户资料就位，再延时重开用户窗口 —— OverlayEntry 的
    // builder 是一次性快照，不随 MainContainer.setState 重建；此前未
    // await 就重开，350ms 时云端资料多半还在路上，浮层定格在旧本地
    // 资料，而右下角按钮（普通树内，随 setState 刷新）已是登录态，
    // 出现「按钮已登录、窗口还是本地身份」的割裂（真机报告）。
    await _loadCurrentUser();
    if (!mounted) return;
    // 本地态经用户窗口【登录】而来：登录浮层关闭后自动重开用户窗口，
    // 让用户立即看到自己的账号资料。350ms > 登录浮层退场动画 200ms，
    // 保证 _authOverlay 槽位已由 onDismissed 清空。
    if (reopen) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) _showAuthOverlay();
      });
    }
  }

  /// ★ 退出登录（用户主动）—— 二分支（需求 5）：
  /// 存在本地账户 → 回到本地态继续使用（软件不退出）；
  /// 无本地账户 → 通知外层回登录窗口（现状行为）。
  Future<void> _onLogout() async {
    debugPrint('[ACTION] 用户点击退出登录');
    _closeAuthOverlay();
    await AuthService.logout();
    if (!mounted) return;
    if (await LocalAccountService.exists) {
      setState(() {
        _isLocalMode = true;
      });
      await _loadCurrentUser();
      AppSnackBar.info(context, '已退出账号，正以本地身份使用');
    } else {
      setState(() {
        _isLocalMode = false;
        _currentUser = null;
      });
      widget.onLogout?.call();
    }
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
      onLogout: () {
        _onLogout();
      },
      onOpenSettings: _showSettingsOverlay,
      onCharge: _showPaymentOverlay,
      // 2026-10-03 层级修复：对接窗口改由宿主编排（关用户窗口→弹窗→重开），
      // 组件内 showDialog 会被钉顶的用户窗口遮挡，见 _handleOpenPair。
      onOpenPair: _handleOpenPair,
      onOpenBigPicture: () {
        _closeAuthOverlay();
        BigPictureManager.instance.toggle();
      },
      user: _currentUser,
      // 需求 5：本地账户的用户窗口显示【登录】；点击转登录浮层，
      // 登录成功后自动重开用户窗口（_reopenUserOverlayAfterLogin）。
      onLogin: () {
        _reopenUserOverlayAfterLogin = true;
        _showLoginOverlay();
      },
    );
  }

  void _showSettingsOverlay() {
    _closeAuthOverlay();
    if (_settingsRouteOpen) return;
    _settingsRouteOpen = true;
    // 🔴 桌面/BPM 统一走 Navigator 路由（2026-09-27 先修 BPM 分支：钉顶
    // OverlayEntry 版设置窗口把 Dropdown 等路由层内容压在下面——root
    // Overlay 的顶层 entry 恒在一切路由之上）。2026-10-04 桌面分支同样
    // 中招且暴露面更大：设置窗口内部的弹层（手柄映射的预设编辑器、
    // 默认预设 DropdownButton、命名/删除确认框等）全部被自身遮挡。
    // 设置窗自身不再钉顶、改与内部弹层同层叠放，后 push 的路由恒在
    // 设置之上，遮挡从根上消除。
    final inBpm = BigPictureManager.instance.isActive;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.transparent,
        child: SettingsModal(
          onClose: () => Navigator.of(context, rootNavigator: true).pop(),
          onBack: inBpm ? null : _settingsBackToProfile,
          onAvatarChanged: _loadCurrentUser,
        ),
      ),
    ).then((_) {
      _settingsRouteOpen = false;
    });
  }

  void _closeSettingsOverlay() {
    if (!_settingsRouteOpen) return;
    Navigator.of(context, rootNavigator: true).pop();
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
    // 详情页是**覆盖层**而非替换：底层页面保持在树中（Offstage 保活，
    // 不绘制不参与命中测试）。此前直接替换整个页面树，导致
    // ExploreHallPage 连同其内部「大厅↔探索库」子视图状态被整体卸载——
    // 「大厅→探索库→详情→返回」会跳回大厅（State 重建回到初始值），
    // 且月历选中日/焦点轮播/滚动位置全部丢失、免责弹窗重复弹出。
    // （2026-09-12 修复）
    final showDetail = _showDetailPage && _selectedGame != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: showDetail, child: _buildBasePage()),
        if (showDetail)
          // key 绑定游戏 id：系列内跳转换游戏时强制重建 State，
          // 确保 Loading/截图/系列数据等全部按新游戏重新加载
          KeyedSubtree(
            key: ValueKey('detail_${_selectedGame!.id}'),
            child: GameDetailPage(
              gameId: _selectedGame!.id,
              onBack: _onDetailBack,
              onBackToList: _onBackToList,
              onGoToLibrary: _onGoToLibraryFromDetail,
              onNavigateToGame: _onNavigateToGameFromDetail,
              // 导航分级：栈深 > 1 时返回按钮显示上一级作品名
              backTargetLabel: _detailGameStack.length > 1
                  ? _detailGameStack[_detailGameStack.length - 2].title
                  : null,
              // 面包屑：导航路径快照（栈内容），供分级可视化与直接回跳
              navBreadcrumb: [
                for (final g in _detailGameStack)
                  (id: g.id, title: g.title, coverUrl: g.coverPath),
              ],
            ),
          ),
      ],
    );
  }

  /// 不含详情覆盖层的基础页（按侧边栏当前项）
  Widget _buildBasePage() {
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
          onDelete: _onDeleteGame,
          onDeleteBatch: _onDeleteBatchGame,
          onRefresh: () {
            debugPrint('[LIBRARY] 删除后强制刷新库页');
            setState(() {});
          },
        );
      case NavPage.discover:
        // 探索大厅：默认首界面；原探索库页整体保留，由大厅按钮进入
        return ExploreHallPage(
          onGameTap: _onGameTap,
          onLaunchGame: _onLaunchGame,
        );
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

  // ============ 桌面 ⇄ BPM 切换动画（2026-10-03，替换旧 420ms AnimatedSwitcher） ============

  /// 模式翻转回调：入场起三段式过渡；出场直达稳态（无动画）
  ///
  /// `BigPictureManager.enter()` 保证「通知」先于全屏切换下发，因此这里画出的
  /// 第一帧幕布正好盖住随后到来的窗口尺寸变化。
  void _onBpmModeChanged() {
    if (!mounted) return;
    _bpmRunId++; // 作废在途的上一轮入场（见 _bpmRunId 注释）
    if (BigPictureManager.instance.isActive) {
      _showDesktopDuringEnter = true;
      _bpmCurtainColor = BpmColors.deepBase;
      _bpmEnter.value = 0.0; // 幕布未起（顺带中止可能残留的上一段动画）
      _bpmLogo.value = 0.0; // 图标未点亮
      _runBpmEnter(_bpmRunId);
    } else {
      // ★ 出场无动画：进度直达稳态，桌面当帧落座、零额外延迟
      _showDesktopDuringEnter = false;
      _bpmEnter.value = 1.0;
      _bpmLogo.value = 1.0; // 图标层随 reveal=1 一并退场，不留残影
      // 出场直达稳态 = 没有「即将开播的入场动画」在跑，把启动恢复的
      // 动画门闩也放行（幂等；正常入场路径由 _runBpmEnter 收尾发信号）
      BigPictureManager.instance.signalEnterAnimationDone();
    }
  }

  /// 入场三段式：① 幕布升起 → ② 手柄图标点亮（与窗口全屏就绪并行）
  /// → ③ 幕布揭开 + 外壳落座
  ///
  /// ⚠️ 对 `animateTo` 必须走 `.orCancel`：TickerFuture 被取消时**主 future
  /// 永不完成**（ticker.dart `stop(canceled: true)` 只 complete orCancel 那一路），
  /// 直接 await 会让本协程永久挂起、`on TickerCanceled` 变成死代码。
  Future<void> _runBpmEnter(int runId) async {
    /// 本轮是否已作废（模式又翻转 / 已销毁）
    bool stale() => !mounted || runId != _bpmRunId;

    try {
      await _bpmEnter
          .animateTo(
            _kBpmCurtainPeak,
            duration: _kBpmCurtainRise,
            curve: Curves.linear, // 形状由 _curtainAlpha/_bpmEnterScale 各自成形
          )
          .orCancel;
    } on TickerCanceled {
      return; // 被出场/销毁打断：不碰已可能被 dispose 的控制器
    }
    if (stale() || !BigPictureManager.instance.isActive) return;

    // 幕布已全盖：此刻卸载桌面外壳（连同其页面状态），卸载帧不可见
    setState(() => _showDesktopDuringEnter = false);

    // ★ 第二段：手柄图标点亮。与「窗口全屏就绪」闸门**并行**，谁慢等谁 ——
    //   图标动画就是大屏的加载指示，窗口若更快也应让动画完整播完（否则一晃而过）。
    final logoWatch = Stopwatch()..start();
    _bpmLogo.forward(from: 0);
    final sync = BigPictureManager.instance.enterWindowSync;
    if (sync != null) {
      // 兜底超时：闸门万一未释放（原生调用卡死），过渡不能永远停在幕布上
      await sync.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    final remain = _kBpmLogoDuration - logoWatch.elapsed;
    if (remain > Duration.zero) await Future<void>.delayed(remain);
    if (stale() || !BigPictureManager.instance.isActive) return;

    // ★ 第三段：揭开 + 落座
    try {
      await _bpmEnter
          .animateTo(1.0, duration: _kBpmReveal, curve: Curves.linear)
          .orCancel;
    } on TickerCanceled {
      // 已由出场/销毁接管，无需处理
    } finally {
      // ★ 启动恢复门闩②：动画已播完（或被出场接管 = 直达稳态），通知
      //   restoreFromPrefs 放行启动重活（YAML 解析等不得在动画期间抢线程）。
      //   放 finally：上面任何提前 return / 取消路径都不会漏发信号。
      BigPictureManager.instance.signalEnterAnimationDone();
    }
  }

  /// 幕布透明度：先升满吞没桌面，再揭开露出大屏；稳态返回 0（不建该层）
  double _curtainAlpha(double v) {
    if (v >= 1.0) return 0.0;
    if (v <= _kBpmCurtainPeak) {
      return Curves.easeIn.transform(v / _kBpmCurtainPeak);
    }
    final t = (v - _kBpmCurtainPeak) / (1.0 - _kBpmCurtainPeak);
    return 1.0 - Curves.easeOutCubic.transform(t);
  }

  /// 外壳「镜头推近」缩放：起始 1.06 → 稳态 1.0。
  ///
  /// 曲线取 **easeInOutCubic**（而非揭开幕布用的 easeOutCubic）：开头缓 ⇒
  /// 幕布还盖着时几乎不动、揭开过半才开始明显回落落座，首尾都不突兀。
  ///
  /// 🔴 稳态必须返回**精确 1.0** —— `RenderTransform` 对恒等矩阵走平移快路径
  /// （proxy_box.dart:2538 `getAsTranslation`），稳态因此零图层开销、不模糊。
  double _bpmEnterScale(double v) {
    if (v <= _kBpmCurtainPeak) return _kBpmEnterScale;
    if (v >= 1.0) return 1.0;
    final t = (v - _kBpmCurtainPeak) / (1.0 - _kBpmCurtainPeak);
    return _kBpmEnterScale -
        (_kBpmEnterScale - 1.0) * Curves.easeInOutCubic.transform(t);
  }

  @override
  Widget build(BuildContext context) {
    // 顶层监听 BigPictureManager：模式翻转 → 重建外壳。
    // 入场动画的逐帧重建收在 `_buildBpmTransition` 内部，不牵连桌面外壳。
    return AnimatedBuilder(
      animation: BigPictureManager.instance,
      builder: (context, _) => _buildModeRoot(),
    );
  }

  /// 模式根：**结构恒定**（永远是一个 Stack），只有内容随模式/动画变化。
  ///
  /// 槽位 0 = 桌面外壳；槽位 1 = BPM 外壳 + 入场过渡层。
  /// 🔴 槽位 0 必须始终存在（BPM 态退化为零尺寸占位）：否则桌面被卸载的那一刻
  ///    BPM 外壳会从 index 1 滑到 index 0，element 身份断裂 → 整个大屏外壳被
  ///    重建（书架归位、焦点/手柄/背景媒体服务重启），动画尾部会炸出卡顿。
  Widget _buildModeRoot() {
    final isActive = BigPictureManager.instance.isActive;
    final showDesktop = !isActive || _showDesktopDuringEnter;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showDesktop) _buildDesktopShell() else const SizedBox.shrink(),
        if (isActive)
          AnimatedBuilder(
            // 逐帧重建的只有外层那几层包装：外壳走 child 复用，
            // 图标走自带 RepaintBoundary 的独立画布
            animation: Listenable.merge([_bpmEnter, _bpmLogo]),
            child: _buildBpmShell(),
            builder: (context, child) => _buildBpmTransition(child!),
          ),
      ],
    );
  }

  /// BPM 外壳（参数与旧 build 内联构造完全一致）
  Widget _buildBpmShell() {
    return BigPictureShell(
      currentUser: _currentUser,
      onLaunchGame: _onLaunchGame,
      onToggleMark: _onToggleGameMark,
      onDelete: _onDeleteGame,
      onExitBpm: () => BigPictureManager.instance.exit(),
      // v3.5: 头部栏用户按钮 → 与桌面右下角用户按钮同一个 Overlay 宿主
      onOpenUserPanel: _onUserTap,
    );
  }

  /// BPM 层：外壳 + 入场过渡（幕布 / 手柄图标 / 镜头推近）
  ///
  /// 🔴 槽位恒定：外壳永远在 index 0（包在恒存的 Offstage + Transform 里），
  ///    幕布与手柄图标是可增删的**尾随**槽位 —— 动画结束时不重建外壳（一旦重建，
  ///    大屏界面会重跑 initState：手柄/焦点/背景媒体全部重启，且页面归位首页）。
  Widget _buildBpmTransition(Widget shell) {
    final v = _bpmEnter.value;
    final alpha = _curtainAlpha(v);
    // 揭开进度 0..1：0 = 幕布未开始揭开（含升起阶段），1 = 完全揭开
    final reveal = ((v - _kBpmCurtainPeak) / (1.0 - _kBpmCurtainPeak))
        .clamp(0.0, 1.0)
        .toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        // 槽位 0：外壳本体。幕布全盖之前 Offstage —— 状态照常建立（initState
        // 里的服务启动、库数据预热都在这一段完成），但不绘制：幕布尚未合拢时
        // 屏幕上必须是「桌面被吞没」，而不是提前露脸的大屏外壳。
        Offstage(
          offstage: v < _kBpmCurtainPeak,
          child: Transform.scale(
            scale: _bpmEnterScale(v),
            alignment: Alignment.center,
            // ★ RepaintBoundary：落座期间外壳的绘制命令被缓存，每帧只更新变换
            //   矩阵（缩放交给合成器），不再逐帧重跑整棵大屏界面的 paint ——
            //   这是入场动画能跑满帧的关键，与桌面外壳同一手法。
            child: RepaintBoundary(child: shell),
          ),
        ),
        // 槽位 1：幕布 —— BPM 底色实心层，先吞没桌面、后揭开大屏。
        // 用色值 alpha 而非 Opacity 包树：实心层改色零离屏开销（无 saveLayer）。
        // 实心层同时吞掉过渡期内的点击（RenderColoredBox 命中即止），
        // 避免半透明阶段误触桌面/大屏按钮。
        if (alpha > 0)
          Positioned.fill(
            child: ColoredBox(
              color: _bpmCurtainColor.withOpacity(alpha),
            ),
          ),
        // 槽位 2：手柄图标（大屏的「加载」指示）—— 光点沿轮廓游走点亮手柄。
        // 只在过渡期间存在：稳态（reveal=1）与出场（图标进度=1 且 reveal=1）
        // 都取不到，组树里不留常驻图层。图标自带 RepaintBoundary，
        // 逐帧重绘的只此一块画布，不牵连下面的大屏外壳。
        if (_bpmLogo.value > 0.0001 && reveal < 1.0)
          BpmEnterOverlay(progress: _bpmLogo.value, reveal: reveal),
      ],
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
                      // 侧边栏通知气泡一键入库后刷新库页（与 JoinPage.onGameAdded 同源）
                      onGameAdded: () {
                        debugPrint('[ADD] 通知气泡入库成功 → 刷新库页');
                        setState(() {});
                      },
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
                              // v3.9 Aurora：氛围层——仅 aurora 档渲染（静态冷光洗 +
                              // 辉光团，深色 90s 微呼吸）。置于内容之上、悬浮件之下，
                              // IgnorePointer 保证零交互干扰，RepaintBoundary 隔离重绘。
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: RepaintBoundary(
                                    child: _AmbientLayer(),
                                  ),
                                ),
                              ),
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
                              // ★ 游戏运行任务状态横幅
                              // 挂在内容区 Stack（而非外层含侧边栏的 Stack），
                              // 使横幅相对内容区居中，不会被侧边栏推偏。
                              // 用 Positioned 而非 Align：本 Stack 是 fit:expand，
                              // non-positioned child 会被拉伸到全屏并拦截点击
                              // （即 817-828 行记录过的"白屏"问题）。
                              // 无任务时组件内部返回 SizedBox.shrink()，零尺寸不占位。
                              const Positioned(
                                top: 10,
                                left: 0,
                                right: 0,
                                child: Center(child: RunningTasksBanner()),
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
              // ★ 2026-10-05 遮挡修复：安装中心层挂在本 Stack 顶层——
              //   盖住普通页面/浮动件，又天然位于根 Navigator 的弹窗 route
              //   之下（决策/报错弹窗不再被安装中心挡住，无需先关它）。
              //   框架级根因与迁移理由见 _installCenterVisible 字段注释。
              if (_installCenterVisible && _installCenterOverlayKey != null)
                Positioned.fill(
                  child: AnimatedOverlay(
                    key: _installCenterOverlayKey,
                    // InstallCenterPage 自带黑色遮罩，此处不再叠加遮罩
                    barrierColor: Colors.transparent,
                    dismissOnBarrierTap: false,
                    enableScale: true,
                    onDismissed: _onInstallCenterDismissed,
                    child: InstallCenterPage(
                      onClose: _closeInstallCenter,
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

/// v3.9 Aurora：桌面内容区氛围层（设计语言「极光」，方案 §2.3）。
///
/// 仅 aurora 档且主题无背景图时渲染，其余情况 SizedBox.shrink 零开销：
/// - 顶部冷光洗：强调色 4% → 0 的纵向渐变（高 220px）；
/// - 两团极淡辉光：信息蓝 2%（右上）+ 强调色 2.5%（左下），自边缘渗入；
/// - 深色主题辉光以 90s 周期在 0.55~1.0 间极缓呼吸，浅色恒静态（零动画）。
///
/// 父级 Stack 位于 AnimatedBuilder(AppThemeManager) 内，主题切换即重建本组件，
/// didUpdateWidget 据此启停呼吸控制器。
class _AmbientLayer extends StatefulWidget {
  const _AmbientLayer();

  @override
  State<_AmbientLayer> createState() => _AmbientLayerState();
}

class _AmbientLayerState extends State<_AmbientLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 90),
  );

  bool get _shouldBreath => AppStyle.isModern && AppColors.isDark;

  @override
  void initState() {
    super.initState();
    if (_shouldBreath) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _AmbientLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldBreath && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!_shouldBreath && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppThemeManager.colors;
    if (!AppStyle.isModern || theme.hasBackgroundImage) {
      return const SizedBox.shrink();
    }
    final accent = theme.selectedAccent;
    final info = theme.infoBlue;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final glowSize = w * 0.5;
      return Stack(
        children: [
          // 顶部冷光洗
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 220,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent.withAlpha(10), accent.withAlpha(0)],
                ),
              ),
            ),
          ),
          // 辉光团（右上：信息蓝 / 左下：强调色；深色随呼吸起伏）
          Positioned(
            right: -glowSize * 0.18,
            top: -glowSize * 0.12,
            child: _glowBlob(size: glowSize, color: info.withAlpha(5)),
          ),
          Positioned(
            left: -glowSize * 0.15,
            bottom: -glowSize * 0.20,
            child: _glowBlob(size: glowSize * 1.1, color: accent.withAlpha(6)),
          ),
        ],
      );
    });
  }

  Widget _glowBlob({required double size, required Color color}) {
    final blob = SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withAlpha(0)]),
        ),
      ),
    );
    if (!_shouldBreath) return blob;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_breath.value);
        return Opacity(opacity: 0.55 + 0.45 * t, child: blob);
      },
    );
  }
}

/// 侧边栏收起/展开半圆按钮（桌面模式）。
///
/// 造型（17×34 半圆 + chevron）是本项目 UI 的历史设计，原样保留；
/// 交互层适配（2026-09-11）：hover/按压渐亮、Tooltip + Semantics（UX-25，
/// 自 sidebar.dart 已删除的死代码 buildSemicircleToggle 移植并修正文案方向）、
/// 图标字重与显式命中区。静息态（t=0）颜色 lerp 恒等原色，观感不变。
class SidebarToggleWidget extends StatefulWidget {
  final bool isLeft;
  final VoidCallback onTap;

  const SidebarToggleWidget({
    super.key,
    required this.isLeft,
    required this.onTap,
  });

  @override
  State<SidebarToggleWidget> createState() => _SidebarToggleWidgetState();
}

class _SidebarToggleWidgetState extends State<SidebarToggleWidget> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // UX-25: Tooltip/Semantics 按点击后发生的动作描述
    // （isLeft=展开态 → chevron_left → 点击后收起）
    final action = widget.isLeft ? '收起侧边栏' : '展开侧边栏';
    final highlighted = _hovered || _pressed;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        // 与侧栏导航项一致：显式 opaque，保证 17×34 区域 hover/点击可靠
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // 按压显示同款渐亮（与导航项 onTapDown 复用 hover 视觉的模型一致）
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: Tooltip(
          message: action,
          waitDuration: const Duration(milliseconds: 400),
          child: Semantics(
            button: true,
            label: action,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: highlighted ? 1 : 0),
              duration: const Duration(milliseconds: 200),
              builder: (context, t, child) {
                return SizedBox(
                  width: 17,
                  height: 34,
                  child: CustomPaint(
                    painter: SemicirclePainter(
                      isLeft: widget.isLeft,
                      // BUG-05: 传入主题颜色，替代硬编码
                      // hover 渐亮：向 toggleIcon lerp（icon 是各主题中
                      // 对比度最高的颜色，自定义主题映射下同样成立）；
                      // SemicirclePainter 本体零改动，颜色本就参数化传入
                      fillColor: Color.lerp(
                          AppColors.toggleBg, AppColors.toggleIcon, 0.14 * t)!,
                      borderColor: Color.lerp(AppColors.toggleBorder,
                          AppColors.toggleIcon, 0.4 * t)!,
                      shadowColor: AppColors.shadowColor,
                    ),
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: widget.isLeft ? 4 : 0,
                          right: widget.isLeft ? 0 : 4,
                        ),
                        child: Icon(
                          widget.isLeft
                              ? Icons.chevron_left
                              : Icons.chevron_right,
                          size: 16,
                          // UX-25 死代码版本的既定字重
                          weight: 700,
                          color: AppColors.toggleIcon,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
