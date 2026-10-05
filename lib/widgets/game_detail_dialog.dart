import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../core/path_helper.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../theme/app_style.dart';
import '../services/game_data_format.dart';
import '../services/game_storage_state_controller.dart';
import '../services/game_launch_service.dart';
import '../services/locale_service.dart';
import '../services/path_validator.dart';
import '../services/local_game_registry.dart';
import '../services/company_alias_store.dart'; // ★ 会社归一化（v4）：company_id 解析
import '../services/company_alias_pending.dart'; // ★ 会社归一化（v4）：命中后清理待审漏斗
import '../services/game_move_service.dart';
import '../services/registry_path_scanner.dart';
import '../utils/game_config_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/file_size_service.dart';
import '../services/magpie_service.dart';
import '../services/metadata_fetcher.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart' show SourceType;
import '../services/screenshot_fetch_service.dart';
import '../services/cover_download_service.dart';
import 'screenshot_carousel.dart';
import 'interactive_wrapper.dart';
import 'app_dialog.dart';
import 'cover_gallery_overlay.dart';
import 'nsfw/nsfw_image.dart';
import 'app_snack_bar.dart';
import '../services/manifest_service.dart';
import 'game_data_dialog.dart';

class GameDetailDialog extends StatefulWidget {
  final String directoryPath;
  final VoidCallback? onLaunchGame;
  final ValueChanged<String>? onLocaleModeChanged;
  final ValueChanged<String>? onUpscalingModeChanged;
  final String initialLocaleMode;
  final String initialUpscalingMode;

  const GameDetailDialog({
    super.key,
    required this.directoryPath,
    this.onLaunchGame,
    this.onLocaleModeChanged,
    this.onUpscalingModeChanged,
    this.initialLocaleMode = 'none',
    this.initialUpscalingMode = 'none',
  });

  static Future<void> show({
    required BuildContext context,
    required String directoryPath,
    VoidCallback? onLaunchGame,
    ValueChanged<String>? onLocaleModeChanged,
    ValueChanged<String>? onUpscalingModeChanged,
    String initialLocaleMode = 'none',
    String initialUpscalingMode = 'none',
  }) async {
    await showAppDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => GameDetailDialog(
        directoryPath: directoryPath,
        onLaunchGame: onLaunchGame,
        onLocaleModeChanged: onLocaleModeChanged,
        onUpscalingModeChanged: onUpscalingModeChanged,
        initialLocaleMode: initialLocaleMode,
        initialUpscalingMode: initialUpscalingMode,
      ),
    );
  }

  @override
  State<GameDetailDialog> createState() => _GameDetailDialogState();
}

class _GameDetailDialogState extends State<GameDetailDialog>
    with TickerProviderStateMixin {
  String _title = '';
  String _gameId = '';
  // 副标题：与主标题共同构成标题系统（通常为日文原版标题）
  String _subtitle = '';
  String _description = '';
  List<String> _tags = [];
  String _source = '';
  String _installedAt = '';
  String _coverFile = '';
  String _gameDirectoryPath = '';
  String _launchPath = '';
  String _metaDataDir = ''; // 元数据目录路径，标题修改后可能变更
  int _playTime = 0;
  PlayStatus _playStatus = PlayStatus.notStarted;
  bool _isLoading = true;
  bool _statusDropdownOpen = false;
  bool _localeAvailable = false;
  String _localeMode = 'none';
  String _developer = '';
  String _firstOpenedAt = '';
  String _lastOpenedAt = '';
  Timer? _playTimeRefreshTimer;

  // ===== 探索页对齐元数据（2026-10-04，仅详情窗口展示）=====
  // 发售日（「开发日期」行）/ 评分 / 评分人数 / 预计游玩时长（分钟）
  String _releaseDate = '';
  double _rating = 0;
  int _ratingCount = 0;
  int _estimatedMinutes = 0;
  bool _isBackfillingMetadata = false;

  bool _isEditing = false;
  bool _launchHovered = false;
  bool _openDirHovered = false;
  bool _editHovered = false;
  bool _saveHovered = false;
  bool _cancelHovered = false;
  bool _launchMenuOpen = false;
  bool _scrapeHovered = false;
  bool _backupHovered = false;

  // 目录行下拉菜单 overlay（更换游戏目录 / 移动游戏位置）
  OverlayEntry? _directoryMenuOverlay;

  // Field locks
  bool _titleLocked = false;
  bool _descLocked = false;
  bool _tagsLocked = false;
  bool _developerLocked = false;
  bool _coverLocked = false;
  bool _screenshotLocked = false;

  // Metadata fetch state
  bool _isScraping = false;
  List<Map<String, dynamic>> _scrapeResults = [];
  Map<String, dynamic>? _selectedScrapeResult;
  bool _scrapePanelOpen = false;

  /// ★ 启动请求防重入标志（替代旧的 _isLaunching）
  /// 仅用于拦截同一次点击引发的重复启动，不再承载任何"启动中"UI 状态。
  bool _launchRequested = false;

  bool _magpieAvailable = false;
  String _upscalingMode = 'none'; // 'none' | 'magpie'

  String _directorySize = '';
  bool _isCalculatingSize = false;

  // ---- 存储状态（方案 §7 Phase 4）----
  /// 用户可见状态文案（'已封装' / '已打包'）；空串 = normal，不显示该行
  String _storageStateLabel = '';
  String _archiveSize = '';
  bool _isCalcArchiveSize = false;
  List<String> _screenshotFiles = [];

  // 标签栏横向滚动控制器（支持滚轮/拖拽横向滚动）
  final ScrollController _tagsScrollController = ScrollController();

  // 编辑态截图列表横向滚动控制器（滚轮/拖拽/箭头横向滚动）
  final ScrollController _editShotsScrollController = ScrollController();
  bool _shotsCanScroll = false; // 截图是否溢出（需要横滚/箭头）
  bool _shotsAtStart = true; // 已滚到最左
  bool _shotsAtEnd = false; // 已滚到最右

  // 元数据匹配面板横向滚动控制器（滚轮/拖拽横向滚动）
  final ScrollController _scrapeScrollController = ScrollController();

  late AnimationController _menuController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _tagsController = TextEditingController();
  final _developerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _localeMode = widget.initialLocaleMode;
    _upscalingMode = widget.initialUpscalingMode;
    _loadGameData();
    _checkLocaleAvailability();

    _menuController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _menuController, curve: Curves.easeInOut),
    );

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _menuController, curve: Curves.easeOut),
    );

    _checkMagpieAvailability();
    MagpieService.instance.addListener(_onMagpieStateChanged);

    // 定时刷新游玩时长（游戏运行中时实时更新显示）
    _playTimeRefreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshPlayTime(),
    );

    // 编辑态截图列表滚动状态同步（箭头显隐/可用性）
    _editShotsScrollController.addListener(_syncShotScrollState);
  }

  @override
  void dispose() {
    _playTimeRefreshTimer?.cancel();
    _directoryMenuOverlay?.remove();
    _directoryMenuOverlay = null;
    MagpieService.instance.removeListener(_onMagpieStateChanged);
    _titleController.dispose();
    _descController.dispose();
    _tagsController.dispose();
    _developerController.dispose();
    _menuController.dispose();
    _tagsScrollController.dispose();
    _editShotsScrollController.dispose();
    _scrapeScrollController.dispose();
    super.dispose();
  }

  Future<void> _checkLocaleAvailability() async {
    final available = await LocaleService.isLocaleAvailable();
    if (mounted) setState(() => _localeAvailable = available);
  }

  Future<void> _checkMagpieAvailability() async {
    final available = await MagpieService.instance.isAvailable();
    if (mounted) setState(() => _magpieAvailable = available);
  }

  void _onMagpieStateChanged() {
    if (!mounted) return;
    setState(() {
      _magpieAvailable = false;
    });
    _checkMagpieAvailability();
  }

  Future<void> _calculateDirectorySize() async {
    if (_gameDirectoryPath.isEmpty) return;

    setState(() => _isCalculatingSize = true);

    try {
      final sizeBytes = await FileSizePrefetchService.calculateDirectorySize(
          _gameDirectoryPath);

      if (mounted) {
        setState(() {
          _directorySize = FileSizePrefetchService.formatBytes(sizeBytes);
          _isCalculatingSize = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isCalculatingSize = false);
    }
  }

  /// 归档体积（仅封装/打包态）。归档库是纯 .7z 文件目录，遍历开销远小于本体，
  /// 详情窗口单实例只算一次，可接受（方案 §7 Phase 4）。
  Future<void> _calculateArchiveSize(String archiveDir) async {
    if (archiveDir.isEmpty) return;
    if (mounted) setState(() => _isCalcArchiveSize = true);
    try {
      final sizeBytes =
          await FileSizePrefetchService.calculateDirectorySize(archiveDir);
      if (!mounted) return;
      setState(() {
        _archiveSize = FileSizePrefetchService.formatBytes(sizeBytes);
        _isCalcArchiveSize = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isCalcArchiveSize = false);
    }
  }

  Future<void> _loadGameData() async {
    try {
      // 确保 _metaDataDir 在读取前已初始化
      if (_metaDataDir.isEmpty) {
        _metaDataDir = widget.directoryPath;
      }
      final data = await GameDataFormat.readGameJson(_metaDataDir);
      if (data != null && mounted) {
        setState(() {
          _title = data.title;
          _subtitle = data.subtitle;
          _description = data.description;
          _tags = List.from(data.tags);
          _source = data.source;
          _installedAt = data.installedAt;
          _coverFile = data.coverFile;
          _gameDirectoryPath = data.directoryPath.isNotEmpty
              ? data.directoryPath
              : widget.directoryPath;
          _launchPath = data.launchPath;
          _metaDataDir = widget.directoryPath;
          _playTime = data.playTime;
          final ps = data.playStatus;
          switch (ps) {
            case 'in_progress':
              _playStatus = PlayStatus.inProgress;
              break;
            case 'dropped':
              _playStatus = PlayStatus.dropped;
              break;
            case 'completed':
              _playStatus = PlayStatus.completed;
              break;
            default:
              // 未设置状态时：有游玩记录→游玩中，无记录→未入坑
              _playStatus = data.playTime > 0
                  ? PlayStatus.inProgress
                  : PlayStatus.notStarted;
              break;
          }
          if (data.localeMode.isNotEmpty) _localeMode = data.localeMode;
          if (data.upscalingMode.isNotEmpty) {
            _upscalingMode = data.upscalingMode;
          }
          _developer = data.developer;
          _gameId = data.gameId; // 钥匙统一：GameDataDialog 按稳定主键定位条目
          _firstOpenedAt = data.firstOpenedAt;
          _lastOpenedAt = data.lastOpenedAt;
          // 探索页对齐元数据（老文件无键 → 默认值）
          _releaseDate = data.releaseDate;
          _rating = data.rating;
          _ratingCount = data.ratingCount;
          _estimatedMinutes = data.estimatedMinutes;
          // 存储状态（Phase 4）：'已封装'/'已打包' 才显示，normal → 空串
          _storageStateLabel =
              GameStorageState.fromWire(data.storageState).hasArchive
                  ? GameStorageState.fromWire(data.storageState).label
                  : '';
          _isLoading = false;
          // 加载截图
          _screenshotFiles = GameDataFormat.findScreenshotFiles(_metaDataDir);
        });
        _titleController.text = data.title;
        _descController.text = data.description;
        _tagsController.text = data.tags.join(', ');
        _developerController.text = data.developer;
        _calculateDirectorySize();
        // 探索页对齐元数据懒回填（缺字段时后台 VNDB 单源抓取，不阻塞 UI）
        _maybeBackfillExternalMetadata();
        if (GameStorageState.fromWire(data.storageState).hasArchive) {
          _calculateArchiveSize(data.archiveDir);
        }
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 重新加载截图（截图区域中央刷新图标点击时调用）
  ///
  /// 走 backfill 流程：已有本地截图则仅刷新文件列表；
  /// 缺失则按 MIX 截图优先级抓取 URL 并入队后台下载，
  /// 下载完成后轮播组件通过 ScreenshotFetchService 监听自动更新
  Future<void> _reloadScreenshots() async {
    await ScreenshotFetchService.instance
        .backfillGameScreenshots(_title);
    if (!mounted) return;
    setState(() {
      _screenshotFiles = GameDataFormat.findScreenshotFiles(_metaDataDir);
    });
  }

  /// 定时刷新游玩时长和状态
  ///
  /// ★ 优先从内存读取（实时性更好，_writePlayTimeDirect 每30秒同步内存），
  /// 内存读取失败时回退到 game.json 文件读取。
  /// ★ 修复：移除 playTime > 0 前置条件——游戏刚启动的前 30s 内
  /// 内存中 playTime 可能为 0，但不应跳过内存读取回退到文件读取
  /// （文件此时也是 0，且文件 I/O 会增加不必要的开销）。
  Future<void> _refreshPlayTime() async {
    if (!mounted) return;
    try {
      // ★ 优先从内存读取（_writePlayTimeDirect 写入成功后会同步内存）
      final game = LocalGameRegistry.instance.getGameByTitle(_title);
      if (game != null) {
        if (mounted) {
          setState(() {
            _playTime = game.playTime;
            _lastOpenedAt = game.lastOpenedAt;
          });
        }
        return;
      }

      // 内存中未找到游戏时回退到文件读取
      final data = await GameDataFormat.readGameJson(_metaDataDir);
      if (data != null && mounted) {
        setState(() {
          _playTime = data.playTime;
          _lastOpenedAt = data.lastOpenedAt;
          // 同步游玩状态
          final ps = data.playStatus;
          switch (ps) {
            case 'in_progress':
              _playStatus = PlayStatus.inProgress;
              break;
            case 'dropped':
              _playStatus = PlayStatus.dropped;
              break;
            case 'completed':
              _playStatus = PlayStatus.completed;
              break;
            default:
              _playStatus = data.playTime > 0
                  ? PlayStatus.inProgress
                  : PlayStatus.notStarted;
          }
        });
      }
    } catch (_) {}
  }

  /// 统一启动入口：无提示窗口，点击后直接启动游戏
  ///
  /// ★ 修复（2026-08-30）：启动提示窗口残留 + 点击窗口周边空白卡死
  ///
  /// 旧实现的问题：
  /// 1. 打开 `_isLaunching` → 用 `_buildLoadingOverlay` 覆盖整个详情窗口
  ///    （"正在超分启动游戏..."），先空转约 1.2s 假进度；
  /// 2. 超分模式**绕过 [GameLaunchService]** 直接 `await`
  ///    [MagpieService.startGameWithUpscaling]。该链路内部含多段
  ///    PowerShell / tasklist 等待（最坏 10s + 18s 以上），一旦超时或
  ///    被杀软挂起，await 永不返回 → 覆盖层与详情窗口永久压在软件窗口
  ///    上方，表现为"游戏已启动但提示窗口不关闭"；
  /// 3. 此时用户点击窗口周边空白（barrier）关闭 → 路由已开始 pop，但
  ///    await 返回后代码仍在"已失活但仍 mounted"的 Element 上执行
  ///    `setState` 与 `Navigator.pop` → 路由栈错乱、重复 pop 掉下方
  ///    路由，主窗口失去响应（卡死）。
  ///
  /// 新实现与主页 / 库页双击 / BPM 详情页**完全一致**：
  /// 持久化启动模式 → 关闭详情窗口 → 由 [widget.onLaunchGame] 触发
  /// [GameLaunchService.executeLaunch] 完成真正的启动，
  /// 普通 / 转区 / 超分分支由 game.json 中的模式决定。
  /// 全程不显示任何进度条或提示窗口，也不再重复实现超分启动逻辑。
  Future<void> _performLaunch() async {
    if (!mounted || _launchRequested) return;
    _launchRequested = true;

    // 启动时自动切换：未入坑 → 游玩中（与旧行为保持一致）
    if (_playStatus == PlayStatus.notStarted) {
      await _setPlayStatus(PlayStatus.inProgress);
    }
    if (!mounted) return;

    // 先关闭详情窗口，再触发启动：
    // 保证启动流程（尤其超分的 Magpie 链路）耗时期间，详情窗口不会
    // 以模态形式压在软件窗口上方。pop 与回调严格分离，杜绝在失活
    // Element 上继续操作。
    _closeDialog();

    // pop 后 State 尚未 dispose（退出动画期间），此处仅读取 widget 字段，安全。
    widget.onLaunchGame?.call();
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _titleController.text = _title;
      _descController.text = _description;
      _tagsController.text = _tags.join(', ');
      _developerController.text = _developer;
      // Reset locks and scrape state
      // ★ 标题锁默认锁定：防止元数据抓取把标题覆盖成日文/英文等平台标题，
      //   用户需主动开锁才能修改标题（其他字段默认不锁）
      _titleLocked = true;
      _descLocked = false;
      _tagsLocked = false;
      _developerLocked = false;
      _coverLocked = false;
      _screenshotLocked = false;
      _isScraping = false;
      _scrapeResults = [];
      _selectedScrapeResult = null;
      _scrapePanelOpen = false;
    });
  }

  Future<void> _exitEditMode({bool save = false}) async {
    if (save) {
      // 数据验证：标题不可为空（标题是元数据目录/配置的键，空值会破坏定位）
      final newTitle = _titleController.text.trim();
      if (newTitle.isEmpty) {
        AppSnackBar.error(
          context,
          '保存失败：标题不能为空',
        );
        return;
      }
      // 标题包含文件系统非法字符时拒绝保存（标题用于目录名）
      if (RegExp(r'[\\/:*?"<>|]').hasMatch(newTitle)) {
        AppSnackBar.error(
          context,
          '保存失败：标题不能包含 \\ / : * ? " < > | 字符',
        );
        return;
      }
      final newDesc = _descController.text.trim();
      final newTagsText = _tagsController.text.trim();
      final newTags = newTagsText.isEmpty
          ? <String>[]
          : newTagsText
              .split(RegExp(r'[,\s，]+'))
              .where((t) => t.isNotEmpty)
              .toList();
      final newDeveloper = _developerController.text.trim();

      // ★ 会社归一化（v4）：详情页编辑会社也要解析 company_id —— 否则用户手改成
      //   「雪碧社」不会并入 sprite 组（要等下次 scan 的 backfill 才对齐）。
      //   与 LocalGameRegistry.setGameDeveloper 同口径：原文保留、未命中写 null。
      final newCompanyId = newDeveloper.isEmpty
          ? null
          : CompanyAliasStore.instanceOrNull?.resolve(newDeveloper)?.record.companyId;
      // 命中即清待审漏斗（幂等；未命中是空操作）
      if (newDeveloper.isNotEmpty) {
        await CompanyAliasPendingStore.instance
            .removeIfResolved(newDeveloper, newCompanyId);
      }

      // 先更新标题（可能重命名元数据文件夹，metaDataDir 会变）
      //
      // ★ 标题持久化必须校验结果：title_locked 锁定保护曾静默丢弃标题写入，
      //   导致"提示保存成功但标题实际未变"的假成功（2026-08-26 修复）
      var titlePersisted = true;
      if (newTitle != _title) {
        // ★ P0-2：启动路径已收敛到 game.json.launch_path（相对 directoryPath），
        //   改标题既不改变 directoryPath、也不改变 launch_path ——
        //   因此**不再需要**任何"配置跟着标题搬家"的迁移补丁（这正是
        //   历史上"改标题后启动程序变回默认"的根源）。
        //   这里只做一件事：把历史存储里可能还留着的旧值搬进 game.json 并清掉，
        //   否则启动时仍会用旧标题的遗留值当兜底。
        try {
          await GameLaunchService.instance.resolveUserChoice(_title);
        } catch (e) {
          debugPrint('[EDIT] ⚠️ 启动路径历史存储迁移失败（不阻塞改名）: $e');
        }

        final renamed = await LocalGameRegistry.instance
            .updateGameTitle(_title, newTitle);
        if (!renamed) {
          // 注册表未命中（极端情况）：直接强制写入 game.json，确保标题落盘
          titlePersisted = await GameDataFormat.updateGameJson(
            _metaDataDir,
            {'title': newTitle, 'title_locked': false},
            forceTitle: true,
          );
        }
      }

      // 获取更新后的 metaDataDir（标题变更后可能已改变）
      final updatedGame = LocalGameRegistry.instance.getGameByTitle(newTitle);
      final currentMetaDataDir = updatedGame?.metaDataDir ?? _metaDataDir;

      // 更新其他字段到（可能已变更的）元数据目录
      final fieldsPersisted = await GameDataFormat.updateGameJson(
        currentMetaDataDir,
        {
          'description': newDesc,
          'tags': newTags,
          'developer': newDeveloper,
          // 会社归一化解析结果（null = 未解析，与 developer 原文并存）
          'company_id': newCompanyId,
        },
      );

      // ★ 写入失败时如实报错并停留在编辑态，杜绝假成功提示
      if (!mounted) return;
      if (!titlePersisted || !fieldsPersisted) {
        AppSnackBar.error(
          context,
          '保存失败：数据写入磁盘失败，请重试',
        );
        return;
      }

      // ★ 响应式修复：同步 LocalGameRegistry 内存对象并广播变更。
      //   此前只写 game.json + 刷新弹窗自身，库页/主页/BPM 卡片在下次
      //   scan() 或重启前持续显示旧的描述/标签/会社（视图-模型不同步主因）。
      final regGame = LocalGameRegistry.instance.getGameByTitle(newTitle);
      if (regGame != null) {
        regGame.description = newDesc;
        regGame.tags = newTags;
        regGame.developer = newDeveloper;
        regGame.companyId = newCompanyId;
      }
      LocalGameRegistry.instance.notifyDataChanged();

      final titleChanged = newTitle != _title; // setState 前捕获（之后 _title 已更新）
      setState(() {
        _title = newTitle;
        _description = newDesc;
        _tags = newTags;
        _developer = newDeveloper;
        _metaDataDir = currentMetaDataDir; // 标题变更后 metaDataDir 可能已改变
        _isEditing = false;
        // Reset locks and scrape state
        _titleLocked = false;
        _descLocked = false;
        _tagsLocked = false;
        _developerLocked = false;
        _coverLocked = false;
        _screenshotLocked = false;
        _isScraping = false;
        _scrapeResults = [];
        _selectedScrapeResult = null;
        _scrapePanelOpen = false;
      });

      // 保存成功反馈（标题变更时提示新标题）
      if (mounted) {
        AppSnackBar.success(
          context,
          titleChanged ? '已保存: $newTitle' : '已保存',
          duration: const Duration(seconds: 2),
        );
      }
    } else {
      setState(() {
        _isEditing = false;
        // Reset locks and scrape state
        _titleLocked = false;
        _descLocked = false;
        _tagsLocked = false;
        _developerLocked = false;
        _coverLocked = false;
        _screenshotLocked = false;
        _isScraping = false;
        _scrapeResults = [];
        _selectedScrapeResult = null;
        _scrapePanelOpen = false;
      });
    }
  }

  /// 切换转区模式并持久化到 game.json
  ///
  /// ★ 返回 Future：启动前必须 await。[GameLaunchService.executeLaunch]
  /// 依据 game.json 决定本次走普通 / 转区 / 超分，若写入未完成就启动，
  /// 会出现"点了超分启动却按普通方式启动"的模式错配。
  Future<void> _setLocaleMode(String mode) async {
    if (mounted) setState(() => _localeMode = mode);
    widget.onLocaleModeChanged?.call(mode);
    await GameDataFormat.updateGameJson(_metaDataDir, {'locale_mode': mode});
  }

  /// 切换超分模式并持久化到 game.json（同 [_setLocaleMode]，启动前需 await）
  Future<void> _setUpscalingMode(String mode) async {
    if (mounted) setState(() => _upscalingMode = mode);
    widget.onUpscalingModeChanged?.call(mode);
    await GameDataFormat.updateGameJson(_metaDataDir, {'upscaling_mode': mode});
  }

  /// 目录行下拉菜单：在目录行右侧弹出"更换游戏目录 / 移动游戏位置"二选一菜单。
  /// 用 OverlayEntry 实现（参考 LibraryContextMenu 模式），点外部或选任一项即关闭。
  final GlobalKey _directoryRowKey = GlobalKey();

  void _showDirectoryActionMenu() {
    // 防重复打开：已打开则先关闭
    if (_directoryMenuOverlay != null) {
      _dismissDirectoryMenu();
      return;
    }

    final renderBox = _directoryRowKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (renderBox == null) return;

    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.sizeOf(context);

    const menuWidth = 180.0;
    const menuHeight = 96.0; // 2 项 × ~44 + 边框/分割线
    const margin = 8.0;

    // 锚点：目录行右下角，菜单向左下方展开
    double left = offset.dx + size.width - menuWidth;
    if (left < margin) left = margin;
    if (left + menuWidth > screenSize.width - margin) {
      left = screenSize.width - menuWidth - margin;
    }

    double top = offset.dy + size.height + 4;
    if (top + menuHeight > screenSize.height - margin) {
      // 底部放不下时上翻至行上方
      top = offset.dy - menuHeight - 4;
      if (top < margin) top = margin;
    }

    _directoryMenuOverlay = OverlayEntry(
      builder: (context) => _DirectoryActionMenu(
        left: left,
        top: top,
        onRelink: () {
          _dismissDirectoryMenu();
          _showRelinkLocationDialog();
        },
        onMove: () {
          _dismissDirectoryMenu();
          _showMoveLocationDialog();
        },
        onClose: _dismissDirectoryMenu,
      ),
    );
    Overlay.of(context).insert(_directoryMenuOverlay!);
    // 触发 chevron 图标方向刷新
    setState(() {});
  }

  void _dismissDirectoryMenu() {
    _directoryMenuOverlay?.remove();
    _directoryMenuOverlay = null;
    if (mounted) setState(() {});
  }

  Future<void> _showRelinkLocationDialog() async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RelinkLocationDialog(
        currentLocation: _gameDirectoryPath,
        gameTitle: _title,
      ),
    );

    // result 是用户选定的"新游戏目录本身"（不拼 title）
    if (result != null && result.isNotEmpty && result != _gameDirectoryPath) {
      try {
        final relinkResult =
            await LocalGameRegistry.instance.relinkGameLocation(
          gameTitle: _title,
          newDirectoryPath: result,
        );

        if (!relinkResult.success) {
          if (mounted) {
            AppSnackBar.error(
              context,
              '更换失败: ${relinkResult.errorMessage ?? '未知错误'}',
            );
          }
          return;
        }

        // 同步 GameConfigManager + SharedPreferences
        await _resyncLauncherConfig(_title);

        // 从注册表重读最新状态，刷新 UI
        final updatedGame = LocalGameRegistry.instance.getGameByTitle(_title);
        if (updatedGame != null && mounted) {
          setState(() {
            _gameDirectoryPath = updatedGame.directoryPath;
            _launchPath = updatedGame.launchPath;
          });
        }

        // 重算目录大小（用户挪到的目录可能大小不同）
        _calculateDirectorySize();

        if (mounted) {
          final detectedHint = relinkResult.wasDetected
              ? '（已自动选择启动程序，可在启动管理调整）'
              : '';
          AppSnackBar.info(
            context,
            '已更换游戏目录到: $result$detectedHint',
            duration: const Duration(seconds: 3),
          );
        }
      } catch (e) {
        if (mounted) {
          AppSnackBar.error(
            context,
            '更换失败: $e',
          );
        }
      }
    }
  }

  /// 移动游戏位置：真迁移语义（GameMoveService 五阶段事务）。
  ///
  /// 同卷 = 原子 rename（瞬时）；跨卷 = isolate 流式 copy + 逐文件校验，
  /// 校验通过后自动清理源目录（确认框已明示）。引用切换由
  /// [LocalGameRegistry.finalizeGameMove] 在服务内部完成。
  Future<void> _showMoveLocationDialog() async {
    // 前置守卫：游戏运行中禁止移动（文件占用 + 会话目录失效风险）
    final currentGame = LocalGameRegistry.instance.getGameByTitle(_title);
    if (currentGame != null &&
        LocalGameRegistry.instance.activeSessionDirs
            .contains(currentGame.metaDataDir)) {
      AppSnackBar.error(
        context,
        '游戏正在运行中，请先退出游戏再移动',
      );
      return;
    }

    // 启动残留提示：上次迁移未完成时如实告知（一次性消费，不阻断本次操作）
    final pendingMove = GameMoveService.instance.takeStartupPendingMove(_title);
    if (pendingMove != null && pendingMove.targetExists && mounted) {
      AppSnackBar.warning(
        context,
        '上次迁移未完成：源文件未受影响；残留目标目录 ${pendingMove.targetPath} 可手动删除',
        duration: const Duration(seconds: 6),
      );
    }

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _MoveLocationDialog(
        currentLocation: _gameDirectoryPath,
        gameTitle: _title,
        metaDataDir: _metaDataDir,
      ),
    );

    if (result == null || result.isEmpty || result == _gameDirectoryPath) {
      return;
    }
    if (GameMoveService.isMoving) {
      AppSnackBar.error(
        context,
        '已有迁移任务正在进行，请等待其完成',
      );
      return;
    }

    // 进度对话框（内部驱动迁移，完成后 pop(MoveResult)）
    final moveResult = await showDialog<MoveResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _MoveProgressDialog(
        gameTitle: _title,
        targetPath: result,
      ),
    );
    if (moveResult == null) return;

    // 刷新弹窗内状态（从注册表重读最新值）
    final updatedGame = LocalGameRegistry.instance.getGameByTitle(_title);
    if (updatedGame != null && mounted) {
      setState(() {
        _gameDirectoryPath = updatedGame.directoryPath;
        _launchPath = updatedGame.launchPath;
      });
    }
    _calculateDirectorySize();

    if (!mounted) return;
    switch (moveResult.status) {
      case MoveStatus.success:
        final viaRenameHint =
            moveResult.movedViaRename ? '（同盘瞬时完成）' : '';
        AppSnackBar.info(
          context,
          '游戏已移动到: $result$viaRenameHint',
          duration: const Duration(seconds: 3),
        );
        break;
      case MoveStatus.partial:
        final detail = <String>[
          if (moveResult.sourceLeftoverPath != null)
            '旧目录未能完全删除（可能被占用）: ${moveResult.sourceLeftoverPath}',
          ...moveResult.referenceWarnings,
        ].join('\n');
        AppSnackBar.warning(
          context,
          '移动完成，但有部分收尾未成功:\n$detail',
          duration: const Duration(seconds: 8),
        );
        break;
      case MoveStatus.failed:
        AppSnackBar.error(
          context,
          '移动失败: ${moveResult.errorMessage ?? '未知错误'}',
        );
        break;
    }
  }

  /// 校验/收敛启动路径（P0-2：唯一事实源 = game.json.launch_path）。
  ///
  /// **移动/更换游戏目录后共用**：`launch_path` 是相对 directoryPath 的相对路径，
  /// service 层的 relink 已经把它重算并写进了 game.json，所以这里真正要做的是
  /// 「在新位置重新验证一次」——失效就清空，让启动流程走自动检测。
  ///
  /// 旧实现把结果同时写进 GameConfigManager 与 prefs，那正是"三份事实"的来源；
  /// 现在不再向历史存储写任何东西，只做一次清理。
  Future<void> _resyncLauncherConfig(String gameTitle) async {
    try {
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      if (game == null) {
        debugPrint('[RESYNC] ⚠️ 未找到游戏: $gameTitle');
        return;
      }

      final absoluteLaunchPath = GameDataFormat.resolveLaunchPath(
          game.launchPath, game.directoryPath);

      if (absoluteLaunchPath.isNotEmpty) {
        debugPrint('[RESYNC] ✅ 启动路径有效: $absoluteLaunchPath');
      } else {
        // service 层 launchPath 在新目录无效（relink detector 失败 / 文件被改名）
        // 清空，让 launchGame 走自动检测
        if (game.launchPath.isNotEmpty) {
          await LocalGameRegistry.instance.updateLauncherPath(gameTitle, '');
        }
        debugPrint('[RESYNC] ⚠️ launchPath 在新目录无效，已清空，将走自动检测');
      }

      // 顺手清掉历史存储，避免遗留值在 launch_path 为空时复活
      final prefs = await SharedPreferences.getInstance();
      await GameConfigManager.instance.removeConfig(gameTitle);
      await prefs.remove('default_exe_$gameTitle');
    } catch (e) {
      debugPrint('[RESYNC] ⚠️ 收敛启动路径失败: $e');
    }
  }

  /// 游戏数据：存储状态（封装 / 解封）+ 归档管理 + 存档备份（方案 §7 Phase 2）。
  ///
  /// 按钮文案仍是「备份」（开发者 2026-10-02 拍板不改），但入口已从
  /// 单一的 `SaveBackupDialog` 升级为 `GameDataDialog` —— 后者 Tab 2 内嵌
  /// 同一个 `SaveBackupPanel`，原「存档备份」功能原样保留。
  void _openGameData() {
    // 数据未加载完成时 _title 为空，直接操作会写入无名目录 → 拦下
    if (_title.isEmpty) {
      AppSnackBar.info(context, '游戏数据加载中，请稍候再试');
      return;
    }
    GameDataDialog.show(
      context,
      gameName: _title,
      gameId: _gameId.isNotEmpty ? _gameId : null,
      installDir: _gameDirectoryPath.isNotEmpty
          ? _gameDirectoryPath
          : widget.directoryPath,
      manifestEntry: ManifestService.instance.lookup(_title),
    );
  }

  void _openDirectory() {
    String targetDir = '';

    // 优先使用 _gameDirectoryPath（游戏本体目录），移动后此值始终正确
    if (_gameDirectoryPath.isNotEmpty) {
      final dir = Directory(_gameDirectoryPath);
      if (dir.existsSync()) {
        targetDir = _gameDirectoryPath;
      }
    }

    // 如果游戏目录不存在，尝试通过启动程序路径找到其所在目录
    if (targetDir.isEmpty && _launchPath.isNotEmpty) {
      final resolvedExe =
          GameDataFormat.resolveLaunchPath(_launchPath, _gameDirectoryPath);
      if (resolvedExe.isNotEmpty) {
        final exeFile = File(resolvedExe);
        if (exeFile.existsSync()) {
          targetDir = exeFile.parent.path;
        }
      }
    }

    // 最终回退到元数据目录
    if (targetDir.isEmpty) targetDir = _metaDataDir;

    Process.start('explorer', [targetDir]);
  }

  Future<void> _setPlayStatus(PlayStatus status) async {
    if (_playStatus == status) return;
    // ★ 启动路径会在 await 之后继续操作 Navigator，此处必须先确认仍挂载，
    // 否则在详情窗口关闭动画期间调用 setState 会触发状态异常。
    if (!mounted) return;
    setState(() => _playStatus = status);
    final statusStr = status == PlayStatus.notStarted
        ? 'not_started'
        : status == PlayStatus.inProgress
            ? 'in_progress'
            : status == PlayStatus.dropped
                ? 'dropped'
                : 'completed';
    await GameDataFormat.setPlayStatus(_metaDataDir, statusStr);
    // ★ 响应式修复：同步 registry 内存对象 + 广播，库页/主页状态徽标即时刷新
    final regGame = LocalGameRegistry.instance.getGameByTitle(_title);
    if (regGame != null) {
      regGame.playStatus = status;
    }
    LocalGameRegistry.instance.notifyDataChanged();
  }

  /// 封面文件变更后失效 Flutter 图片解码缓存。
  ///
  /// ImageCache 以「文件路径」为解码缓存键（FileImage 与 ResizeImage 的
  /// 内层键都是路径+scale），同名覆盖（手动换封面固定存 cover.png）时
  /// 新内容会命中旧解码位图 —— 必须主动失效，否则库页/主页卡片持续
  /// 显示旧封面。FileImage 基键可精准 evict；经 ResizeImage（cacheWidth）
  /// 包装的键无法枚举全部解码宽度，用 clear() 保底。换封面为低频操作，
  /// 可见图一次性重新解码（毫秒级/张）的成本可接受。
  void _evictCoverImageCache(String? oldPath, String newPath) {
    final paths = <String>{
      if (oldPath != null && oldPath.isNotEmpty) oldPath,
      newPath,
    };
    for (final path in paths) {
      final f = File(path);
      if (f.existsSync()) {
        FileImage(f).evict();
      }
    }
    PaintingBinding.instance.imageCache.clear();
  }

  Future<void> _changeCoverImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final pickedFile = result.files.first;
        if (pickedFile.path != null) {
          final sourceFile = File(pickedFile.path!);

          if (!sourceFile.existsSync()) return;

          final targetDir = Directory(_metaDataDir);
          if (!targetDir.existsSync()) return;

          final coverFileName = 'cover.png';
          final targetPath = '$_metaDataDir/$coverFileName';
          final oldCoverFile = _coverFile; // 捕获旧封面文件名，供缓存失效

          await sourceFile.copy(targetPath);

          setState(() {
            _coverFile = coverFileName;
          });

          GameDataFormat.updateGameJson(_metaDataDir, {
            'cover_file': coverFileName,
          });

          // ★ 响应式修复：同步 registry 内存对象 + 失效解码缓存 + 广播，
          //   库页/主页/BPM 卡片无需滚动/切页即刷新封面
          final regGame = LocalGameRegistry.instance.getGameByTitle(_title);
          if (regGame != null) {
            regGame.coverUrl = targetPath;
          }
          _evictCoverImageCache(
            oldCoverFile.isNotEmpty ? '$_metaDataDir/$oldCoverFile' : null,
            targetPath,
          );
          LocalGameRegistry.instance.notifyDataChanged();

          AppSnackBar.info(
            context,
            '封面图已更新',
            duration: const Duration(seconds: 2),
          );
        }
      }
    } catch (e) {
      debugPrint('[GAME-DETAIL] 更换封面失败: $e');
      AppSnackBar.error(
        context,
        '更换封面失败: $e',
      );
    }
  }

  String get _displaySource {
    if (_source == 'download') return '探索安装';
    if (_source == 'local_import' || _source == 'batch_import') return '本地导入';
    return _source;
  }

  Future<void> _fetchMetadata() async {
    if (_isScraping) return;
    final query = _titleController.text.trim();
    if (query.isEmpty) {
      AppSnackBar.error(
        context,
        '请先输入游戏标题',
      );
      return;
    }

    setState(() {
      _isScraping = true;
      _scrapeResults = [];
      _selectedScrapeResult = null;
    });

    try {
      var results = await MetadataFetcher.fetchGame(query);

      // 主标题无结果 → 自动回退副标题重试（中文译名在数据源常无收录，
      // 日文原版标题往往能命中；副标题有效且与主标题不同时才回退）
      if (results.isEmpty &&
          _subtitle.trim().isNotEmpty &&
          _subtitle.trim() != query) {
        debugPrint(
            '[GAME-DETAIL] 主标题无元数据，回退副标题重试: "$query" → "${_subtitle.trim()}"');
        results = await MetadataFetcher.fetchGame(_subtitle.trim());
      }

      if (mounted) {
        setState(() {
          _isScraping = false;
          _scrapeResults = results;
          _scrapePanelOpen = results.isNotEmpty;
        });
        if (results.isEmpty) {
          AppSnackBar.info(
            context,
            '未找到匹配的元数据',
            duration: const Duration(seconds: 2),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isScraping = false);
        AppSnackBar.error(
          context,
          '元数据抓取失败: $e',
        );
      }
    }
  }

  void _applyScrapeResult(Map<String, dynamic> result) {
    final updatedFields = <String>[];
    final lockedFields = <String>[];

    // ★ 注册表引用必须在标题被覆盖前获取：getGameByTitle 按当前标题查找，
    // 若放在下方 Title 更新之后，用新标题查旧对象会返回 null，
    // 导致副标题无法同步到内存（库页搜索副标题失效）
    final registryGame = LocalGameRegistry.instance.getGameByTitle(_title);

    // Title
    if (!_titleLocked) {
      final name = result['game_name'] as String? ?? '';
      if (name.isNotEmpty) {
        // ★ 只更新输入框，不提前改内存 _title：_title 是"已持久化的标题"，
        // 保存时靠 newTitle != _title 判断是否需要改名迁移（含元数据文件夹重命名）。
        // 若在此提前改 _title，保存时会误判"标题未变化"而跳过持久化，
        // 导致抓取回填的标题在保存后丢失。
        _titleController.text = name;
        updatedFields.add('标题');
      }
    } else {
      lockedFields.add('标题');
    }

    // Subtitle（副标题：日文原版标题，不导入英文标题；与主标题相同时跳过）
    final originalTitle = (result['original_title'] as String?)?.trim() ?? '';
    if (originalTitle.isNotEmpty &&
        originalTitle != _titleController.text.trim()) {
      _subtitle = originalTitle;
      updatedFields.add('副标题');
      // 即时持久化到 game.json（与封面/截图的抓取持久化行为一致），
      // 并同步注册表内存数据，保证库页副标题搜索即时生效
      GameDataFormat.updateGameJson(_metaDataDir, {'subtitle': _subtitle});
      registryGame?.subtitle = _subtitle;
      // ★ 响应式修复：广播副标题变更，库页副标题展示/搜索即时生效
      LocalGameRegistry.instance.notifyDataChanged();
    }

    // Tags
    if (!_tagsLocked) {
      final tags = result['tags'] as List?;
      if (tags != null && tags.isNotEmpty) {
        final tagsText = tags.map((t) => t.toString()).join(', ');
        _tagsController.text = tagsText;
        _tags =
            tags.map((t) => t.toString()).where((t) => t.isNotEmpty).toList();
        updatedFields.add('标签');
      }
    } else {
      lockedFields.add('标签');
    }

    // Description
    if (!_descLocked) {
      final summary = result['summary'] as String? ?? '';
      if (summary.isNotEmpty) {
        _descController.text = summary;
        _description = summary;
        updatedFields.add('简介');
      }
    } else {
      lockedFields.add('简介');
    }

    // Developer
    if (!_developerLocked) {
      final developer = result['developer'] as String? ?? '';
      if (developer.isNotEmpty) {
        _developerController.text = developer;
        _developer = developer;
        updatedFields.add('会社');
      }
    } else {
      lockedFields.add('会社');
    }

    // Cover
    final coverUrl = result['cover_url'] as String? ?? '';
    if (!_coverLocked && coverUrl.isNotEmpty) {
      _downloadCoverFromUrl(coverUrl);
      updatedFields.add('封面');
    } else if (_coverLocked) {
      lockedFields.add('封面');
    }

    // ★ 2026-10-04 横幅封面：抓取结果透传 banner_url，下载落盘后写
    //   banner_file（BPM 背景 / 主页大图横幅优先）。失败静默（增强数据）。
    final bannerUrl = result['banner_url'] as String? ?? '';
    if (bannerUrl.startsWith('http')) {
      _downloadBannerFromUrl(bannerUrl);
      updatedFields.add('横幅');
    }

    // Screenshots
    final screenshotUrls = result['screenshot_urls'] as List? ?? [];
    if (!_screenshotLocked && screenshotUrls.isNotEmpty) {
      _downloadScreenshotsFromUrls(
          screenshotUrls.map((u) => u.toString()).toList());
      updatedFields.add('截图');
    } else if (_screenshotLocked) {
      lockedFields.add('截图');
    }

    setState(() {
      _selectedScrapeResult = result;
    });

    // Show snackbar
    final messages = <String>[];
    if (updatedFields.isNotEmpty) {
      messages.add('已更新: ${updatedFields.join(', ')}');
    }
    if (lockedFields.isNotEmpty) {
      messages.add('已锁定: ${lockedFields.join(', ')}');
    }
    if (messages.isNotEmpty) {
      AppSnackBar.info(
        context,
        messages.join(' | '),
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _downloadCoverFromUrl(String url) async {
    // Phase 3.1: 委托给统一的 CoverDownloadService
    // 原实现硬编码 'cover.png'，即使源图是 jpg/webp 也存为 png，扩展名与内容不符
    final oldCoverFile = _coverFile; // 捕获旧封面文件名，供缓存失效
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: _metaDataDir,
      coverUrl: url,
    );
    if (savedName != null) {
      setState(() {
        _coverFile = savedName;
      });
      await GameDataFormat.updateGameJson(
          _metaDataDir, {'cover_file': savedName});

      // ★ 响应式修复：同步 registry 内存对象 + 失效解码缓存 + 广播，
      //   库页/主页/BPM 卡片无需滚动/切页即刷新封面
      final regGame = LocalGameRegistry.instance.getGameByTitle(_title);
      if (regGame != null) {
        regGame.coverUrl = '$_metaDataDir/$savedName';
      }
      _evictCoverImageCache(
        oldCoverFile.isNotEmpty ? '$_metaDataDir/$oldCoverFile' : null,
        '$_metaDataDir/$savedName',
      );
      LocalGameRegistry.instance.notifyDataChanged();
    } else {
      debugPrint('[GAME-DETAIL] 封面下载失败: $url');
    }
  }

  /// ★ 2026-10-04：下载横幅封面并落盘（banner_*.{ext}），写 game.json
  /// `banner_file` + 同步 registry 内存对象。横幅是增强数据：失败只留日志。
  Future<void> _downloadBannerFromUrl(String url) async {
    // ★ 2026-10-05：downloadBanner 带宽高比校验（≥1.15），假横幅在此拒收
    final savedName = await CoverDownloadService.instance.downloadBanner(
      targetDir: _metaDataDir,
      bannerUrl: url,
    );
    if (savedName != null) {
      await GameDataFormat.updateGameJson(
          _metaDataDir, {'banner_file': savedName});

      final regGame = LocalGameRegistry.instance.getGameByTitle(_title);
      if (regGame != null) {
        regGame.bannerUrl = '$_metaDataDir/$savedName';
      }
      LocalGameRegistry.instance.notifyDataChanged();
      debugPrint('[GAME-DETAIL] ✅ 横幅封面已更新: $savedName');
    } else {
      debugPrint('[GAME-DETAIL] 横幅封面下载失败: $url');
    }
  }

  Future<void> _downloadScreenshotsFromUrls(List<String> urls) async {
    try {
      // 写入 screenshot_urls + 标记 pending 状态到 game.json
      await GameDataFormat.updateGameJson(_metaDataDir, {
        'screenshot_urls': urls,
        'screenshot_status': 'pending',
        'screenshot_retry_count': 0,
      });

      // 清空当前本地截图列表，触发"获取中"占位UI
      if (mounted) {
        setState(() {
          _screenshotFiles = [];
        });
      }

      // 通知 ScreenshotFetchService 异步下载截图
      ScreenshotFetchService.instance.enqueue(_title, _metaDataDir, urls);

      debugPrint(
          '[GAME-DETAIL] 截图已入队 ScreenshotFetchService: $_title | ${urls.length}张');
    } catch (e) {
      debugPrint('[GAME-DETAIL] 截图入队失败: $e');
    }
  }

  String get _formattedDate {
    if (_installedAt.isEmpty) return '-';
    try {
      final dt = DateTime.parse(_installedAt);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return _installedAt.substring(0, _installedAt.length.clamp(0, 10));
    }
  }

  String get _formattedPlayTime => GameDataFormat.formatPlayTime(_playTime);

  /// 发售日期（「开发日期」行）：格式化为 YYYY-MM-DD（与安装日期同口径）；
  /// 无数据返回空串（行保持原样，不额外占位）
  String get _formattedReleaseDate {
    if (_releaseDate.isEmpty) return '';
    try {
      final dt = DateTime.parse(_releaseDate);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return _releaseDate.substring(0, _releaseDate.length.clamp(0, 10));
    }
  }

  /// 格式化评分人数：1000+ → 1.0k（与探索页热度口径一致）
  String _formatRatingCount(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  /// 格式化预计游玩时长（分钟）：≥60 → 「X 小时」（小数仅保留非零一位），
  /// <60 → 「X 分钟」
  String get _formattedEstimatedTime {
    final minutes = _estimatedMinutes;
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes / 60;
    final text = hours == hours.roundToDouble()
        ? '${hours.toInt()}'
        : hours.toStringAsFixed(1);
    return '$text 小时';
  }

  /// 探索页对齐元数据懒回填（2026-10-04）
  ///
  /// 存量游戏 / 手动导入 / 云端安装入库时未写入评分、发售日、预计游玩时长，
  /// 首次打开详情窗口且四项全空时，后台用 VNDB 单源按标题（副标题回退）
  /// 抓取一次并写回 game.json。失败静默——下次打开会再试。
  /// 抓取结果走 MetadataFetcher 24h 磁盘缓存，重复打开零网络请求。
  Future<void> _maybeBackfillExternalMetadata() async {
    if (_isBackfillingMetadata) return;
    final hasAnyData = _releaseDate.isNotEmpty ||
        _rating > 0 ||
        _ratingCount > 0 ||
        _estimatedMinutes > 0;
    // 任一字段有值即视为已有数据（局部缺失不重抓，避免每次打开都联网）
    if (hasAnyData) return;
    final query = _title.trim();
    if (query.isEmpty) return;

    _isBackfillingMetadata = true;
    try {
      var results =
          await MetadataFetcher.fetchGame(query, preferredSource: SourceType.vndb);
      // 主标题无结果 → 副标题回退（中文译名常无收录，日文原版能命中）
      if (results.isEmpty &&
          _subtitle.trim().isNotEmpty &&
          _subtitle.trim() != query) {
        results = await MetadataFetcher.fetchGame(_subtitle.trim(),
            preferredSource: SourceType.vndb);
      }
      if (results.isEmpty || !mounted) return;
      final best = results.first;
      final releaseDate = best['release_date']?.toString() ?? '';
      final rating = (best['rating'] as num?)?.toDouble() ?? 0.0;
      final ratingCount = (best['vote_count'] as num?)?.toInt() ?? 0;
      final minutes = (best['length_minutes'] as num?)?.toInt() ?? 0;
      if (releaseDate.isEmpty && rating <= 0 && minutes <= 0) return;

      // 只写有效值，避免用空值覆盖（与云端回传 buildMetadataBody 同口径）
      final updates = <String, dynamic>{
        if (releaseDate.isNotEmpty) 'release_date': releaseDate,
        if (rating > 0) 'rating': rating,
        if (ratingCount > 0) 'rating_count': ratingCount,
        if (minutes > 0) 'estimated_minutes': minutes,
      };
      final ok = await GameDataFormat.updateGameJson(_metaDataDir, updates);
      debugPrint('[GAME-DETAIL] 元数据回填${ok ? '成功' : '失败'}: $query | $updates');
      if (!mounted || !ok) return;
      setState(() {
        if (releaseDate.isNotEmpty) _releaseDate = releaseDate;
        if (rating > 0) _rating = rating;
        if (ratingCount > 0) _ratingCount = ratingCount;
        if (minutes > 0) _estimatedMinutes = minutes;
      });
    } catch (e) {
      debugPrint('[GAME-DETAIL] ⚠️ 元数据回填失败: $e');
    } finally {
      _isBackfillingMetadata = false;
    }
  }

  Widget? _resolveCoverImage() {
    if (_coverFile.isNotEmpty) {
      final coverPath = '$_metaDataDir/${_coverFile}';
      final file = File(coverPath);
      if (file.existsSync()) {
        return NsfwImage.file(
          coverPath,
          contentKind: NsfwContentKind.cover,
          fit: BoxFit.cover,
          decodeWidth: 600, // 与 child 的 cacheWidth 一致，避免二次解码
          enableReveal: true, // 详情封面无自身点击语义，允许临时揭示
          child: Image.file(
            file,
            width: double.infinity,
            fit: BoxFit.cover,
            cacheWidth: 600, // ★ 性能优化：详情封面限宽解码
            errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
          ),
        );
      }
    }

    final altCover = GameDataFormat.findCoverFile(_metaDataDir);
    if (altCover != null) {
      return NsfwImage.file(
        altCover.path,
        contentKind: NsfwContentKind.cover,
        fit: BoxFit.cover,
        decodeWidth: 600,
        enableReveal: true,
        child: Image.file(
          altCover,
          width: double.infinity,
          fit: BoxFit.cover,
          cacheWidth: 600, // ★ 性能优化：详情封面限宽解码
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        ),
      );
    }
    return null;
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 56,
          color: AppColors.border.withOpacity(0.4),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GestureDetector(
        onTap: () {},
        behavior: HitTestBehavior.translucent,
        child: Container(
          width: 960,
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.90),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.border, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowColor,
                offset: Offset(4, 6),
                blurRadius: 12,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Material(
            color: Colors.transparent,
            child: Stack(
              children: [
                if (_isLoading)
                  Center(
                      child: CircularProgressIndicator(color: AppColors.border))
                else
                  _buildContent(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final coverImage = _resolveCoverImage();

    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildLeftPanel(coverImage),
              const SizedBox(width: 32),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(0, 28, 28, 28),
                  child: _buildRightPanel(),
                ),
              ),
            ],
          ),
        ),
        Positioned(top: 12, right: 12, child: _buildCloseButton()),
        if (_launchMenuOpen) _buildLaunchMenu(),
      ],
    );
  }

  /// 关闭详情窗口（带路由守卫，防止重复 pop 误伤下方页面路由）
  void _closeDialog() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) return;
    Navigator.of(context).pop();
  }

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        // ★ 守卫：连续点击关闭按钮时，第二次点击会落在"正在退出"的路由上，
        // 未加校验的 pop 会误弹掉下方的页面路由（与点击遮罩同理）。
        onTap: () => _closeDialog(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.placeholderCover,
            border: Border.all(color: AppColors.borderLight, width: 1),
          ),
          child: Icon(Icons.close_rounded, size: 16, color: AppColors.border),
        ),
      ),
    );
  }

  // ══ 封面管理浮层（2026-10-04，LunaBox 风格参照）══

  /// 封面管理入口按钮：查看态右下角 / 编辑态右上角
  Widget _buildCoverGalleryEntryButton() {
    return InteractiveWrapper(
      onTap: _openCoverGallery,
      hoverScale: 1.15,
      child: Tooltip(
        message: '封面管理：预览 / 上传 / 切换竖屏与横幅封面',
        waitDuration: const Duration(milliseconds: 500),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(
            Icons.photo_library_outlined,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  /// 打开封面管理浮层：扫描全部封面候选（canonical + covers/），
  /// 关闭后按是否发生过变更刷新本窗口封面显示。
  /// 2026-10-05：浮层改为纯相册（抓取入口移除）。
  Future<void> _openCoverGallery() async {
    final oldCoverPath =
        _coverFile.isNotEmpty ? '$_metaDataDir/$_coverFile' : null;
    var changed = false;

    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      barrierLabel: '封面管理',
      pageBuilder: (_, __, ___) => CoverGalleryOverlay(
        metaDataDir: _metaDataDir,
        gameTitle: _title,
        onSetVertical: (path) async {
          final ok = await _applyCoverRole(path, isBanner: false);
          if (ok) changed = true;
          return ok;
        },
        onSetBanner: (path) async {
          final ok = await _applyCoverRole(path, isBanner: true);
          if (ok) changed = true;
          return ok;
        },
        onUpload: () async {
          final n = await _uploadCoverImages();
          if (n > 0) changed = true;
          return n;
        },
        onDelete: (path) async {
          final ok = await _deleteCoverImage(path);
          if (ok) changed = true;
          return ok;
        },
      ),
    );
    if (!mounted) return;
    if (!changed) return;

    // 浮层内可能改过 cover_file：重读 json 同步显示，并清解码缓存
    try {
      final data = await GameDataFormat.readGameJson(_metaDataDir);
      if (mounted &&
          data != null &&
          data.coverFile.isNotEmpty &&
          data.coverFile != _coverFile) {
        setState(() => _coverFile = data.coverFile);
      }
    } catch (_) {}
    _evictCoverImageCache(oldCoverPath, '$_metaDataDir/$_coverFile');
  }

  /// 把 [sourcePath] 设为竖屏/横幅封面：复制为 `cover.{ext}` / `banner.{ext}`
  /// 并写 game.json（同口径复用 _downloadCoverFromUrl 的同步链：
  /// registry 内存对象 + 解码缓存失效 + 广播）。
  Future<bool> _applyCoverRole(String sourcePath, {required bool isBanner}) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync()) return false;
      final ext = sourcePath.split('.').last.toLowerCase();
      const validExts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
      final imgExt = validExts.contains(ext) ? ext : 'png';
      final baseName = isBanner ? 'banner' : 'cover';
      var destName = '$baseName.$imgExt';
      var destPath = '$_metaDataDir/$destName';

      // IMP-05 同款护栏：元数据目录在应用存储外时，cover.* / banner.* 可能
      // 是用户自带文件，覆盖即破坏 → 改用带时间戳的替代名（护数据，不拦意图）
      if (sourcePath != destPath &&
          !PathHelper.isInsideAppStorage(_metaDataDir) &&
          File(destPath).existsSync()) {
        destName =
            '${baseName}_custom_${DateTime.now().millisecondsSinceEpoch}.$imgExt';
        destPath = '$_metaDataDir/$destName';
      }

      final oldPath =
          (!isBanner && _coverFile.isNotEmpty) ? '$_metaDataDir/$_coverFile' : null;

      if (sourcePath != destPath) {
        await src.copy(destPath);
      }

      final ok = await GameDataFormat.updateGameJson(_metaDataDir,
          isBanner ? {'banner_file': destName} : {'cover_file': destName});
      if (!ok) return false;

      final regGame = LocalGameRegistry.instance.getGameByTitle(_title);
      if (regGame != null) {
        if (isBanner) {
          regGame.bannerUrl = destPath;
        } else {
          regGame.coverUrl = destPath;
        }
      }
      if (!isBanner && mounted) {
        setState(() => _coverFile = destName);
      }
      if (isBanner) {
        // 横幅同名覆盖时清解码缓存，BPM/主页立即可见新图
        final f = File(destPath);
        if (f.existsSync()) FileImage(f).evict();
        PaintingBinding.instance.imageCache.clear();
      } else {
        _evictCoverImageCache(
          (oldPath != null && oldPath != destPath) ? oldPath : null,
          destPath,
        );
      }
      LocalGameRegistry.instance.notifyDataChanged();
      debugPrint('[COVER-GALLERY] ✅ 已设为${isBanner ? '横幅' : '竖屏'}封面: $destName');
      return true;
    } catch (e) {
      debugPrint('[COVER-GALLERY] 设为封面失败: $e');
      return false;
    }
  }

  /// 上传自定义封面（多选）→ 复制到 covers/ 子目录。返回成功添加数量。
  Future<int> _uploadCoverImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return 0;

      final coversDir = Directory('$_metaDataDir/${GameDataFormat.coversDirName}');
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }

      final stamp = DateTime.now().millisecondsSinceEpoch;
      var added = 0;
      for (var i = 0; i < result.files.length; i++) {
        final f = result.files[i];
        if (f.path == null) continue;
        final ext = (f.extension != null && f.extension!.isNotEmpty)
            ? '.${f.extension}'
            : '.jpg';
        final dest = '${coversDir.path}/custom_${stamp}_$i$ext';
        try {
          await File(f.path!).copy(dest);
          added++;
        } catch (e) {
          debugPrint('[COVER-GALLERY] 自定义封面复制失败: ${f.path}, $e');
        }
      }
      debugPrint('[COVER-GALLERY] ✅ 已添加 $added 张自定义封面');
      return added;
    } catch (e) {
      debugPrint('[COVER-GALLERY] 上传封面异常: $e');
      return 0;
    }
  }

  /// 删除自定义封面：仅允许 covers/ 子目录内且位于应用存储中的文件。
  Future<bool> _deleteCoverImage(String path) async {
    try {
      final norm = path.replaceAll('\\', '/');
      final coversPrefix = '$_metaDataDir/${GameDataFormat.coversDirName}/'
          .replaceAll('\\', '/');
      if (!norm.startsWith(coversPrefix)) {
        debugPrint('[COVER-GALLERY] ⛔ 拒绝删除非 covers/ 文件: $path');
        return false;
      }
      if (!PathHelper.isInsideAppStorage(path)) {
        debugPrint('[COVER-GALLERY] ⛔ 应用存储外，拒绝删除: $path');
        return false;
      }
      final f = File(path);
      if (!f.existsSync()) return false;
      await f.delete();
      debugPrint('[COVER-GALLERY] ✅ 已删除自定义封面: $path');
      return true;
    } catch (e) {
      debugPrint('[COVER-GALLERY] 删除封面失败: $e');
      return false;
    }
  }

  Widget _buildLeftPanel(Widget? coverImage) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_isEditing)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _changeCoverImage,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        height: double.infinity,
                        color: AppColors.background,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: coverImage ?? _buildPlaceholderCover(),
                            ),
                            Positioned.fill(
                              child: Container(
                                color: Colors.black.withOpacity(0.3),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.photo_camera_rounded,
                                          size: 32, color: Colors.white),
                                      const SizedBox(height: 8),
                                      Text('点击更换封面',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white,
                                          )),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // 封面管理入口（编辑态右上角，2026-10-04）
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _buildCoverGalleryEntryButton(),
                            ),
                            // Cover lock button at top-left
                            Positioned(
                              top: 8,
                              left: 8,
                              child: InteractiveWrapper(
                                onTap: () => setState(
                                    () => _coverLocked = !_coverLocked),
                                hoverScale: 1.15,
                                child: Tooltip(
                                  message: _coverLocked
                                      ? '已锁定：抓取元数据时保留封面'
                                      : '未锁定：抓取元数据时会覆盖封面',
                                  waitDuration:
                                      const Duration(milliseconds: 500),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: _coverLocked
                                          ? Colors.black54
                                          : Colors.black26,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      _coverLocked
                                          ? Icons.lock
                                          : Icons.lock_open,
                                      size: 16,
                                      color: _coverLocked
                                          ? Colors.white
                                          : Colors.white60,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  SizedBox.expand(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        coverImage ?? _buildPlaceholderCover(),
                        // 封面管理入口（查看态右下角，2026-10-04）
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _buildCoverGalleryEntryButton(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSplitLaunchButton(),
                const SizedBox(height: 10),
                _buildFullWidthButton(
                  icon: Icons.folder_open_rounded,
                  label: '打开目录',
                  onTap: _openDirectory,
                  isHovered: _openDirHovered,
                  onHover: (v) => setState(() => _openDirHovered = v),
                ),
                const SizedBox(height: 10),
                _buildFullWidthButton(
                  icon: Icons.save_outlined,
                  label: '备份',
                  onTap: _openGameData,
                  isHovered: _backupHovered,
                  onHover: (v) => setState(() => _backupHovered = v),
                ),
                if (_isEditing) ...[
                  const SizedBox(height: 10),
                  _buildFullWidthButton(
                    icon: Icons.auto_awesome,
                    label: _isScraping ? '抓取中...' : '元数据抓取',
                    onTap: _isScraping ? () {} : _fetchMetadata,
                    isHovered: _scrapeHovered,
                    onHover: (v) => setState(() => _scrapeHovered = v),
                    iconColor: AppColors.brandBlue,
                  ),
                ],
                const SizedBox(height: 10),
                if (!_isEditing)
                  _buildFullWidthButton(
                    icon: Icons.edit_outlined,
                    label: '编辑',
                    onTap: _enterEditMode,
                    isHovered: _editHovered,
                    onHover: (v) => setState(() => _editHovered = v),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: _buildFullWidthButton(
                          icon: Icons.save_rounded,
                          label: '保存',
                          onTap: () => _exitEditMode(save: true),
                          isHovered: _saveHovered,
                          onHover: (v) => setState(() => _saveHovered = v),
                          hoverBg: AppColors.successBg,
                          iconColor: AppColors.successGreen,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildFullWidthButton(
                          icon: Icons.close_rounded,
                          label: '取消',
                          onTap: () => _exitEditMode(save: false),
                          isHovered: _cancelHovered,
                          onHover: (v) => setState(() => _cancelHovered = v),
                          hoverBg: AppColors.errorBg,
                          iconColor: AppColors.dangerRed,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitLaunchButton() {
    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _launchHovered = true),
            onExit: (_) {
              if (!_launchMenuOpen) setState(() => _launchHovered = false);
            },
            child: GestureDetector(
              onTap: () {
                _closeMenu();
                // 无提示启动：直接使用已持久化的转区/超分模式，
                // 由 GameLaunchService 统一执行（与库页双击完全一致）
                _performLaunch();
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _launchHovered || _launchMenuOpen
                      ? AppColors.placeholderCover
                      : (_localeMode == 'japanese'
                          ? AppColors.errorBg
                          : AppColors.background),
                  border: Border.all(
                    color: _launchMenuOpen
                        ? AppColors.border
                        : (_localeMode == 'japanese'
                            ? const Color(0xFFF48FB1)
                            : AppColors.borderLight),
                    width: _launchMenuOpen ? 1.5 : 1.2,
                  ),
                  borderRadius:
                      const BorderRadius.horizontal(left: Radius.circular(20)),
                  boxShadow: (_launchHovered || _launchMenuOpen)
                      ? [
                          BoxShadow(
                            color: AppColors.border.withOpacity(0.15),
                            offset: const Offset(0, 2),
                            blurRadius: 6,
                          )
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _localeMode == 'japanese'
                          ? Icons.language_rounded
                          : Icons.play_arrow_rounded,
                      size: 17,
                      color: _localeMode == 'japanese'
                          ? const Color(0xFFE91E63)
                          : AppColors.brandBlue,
                    ),
                    if (_upscalingMode == 'magpie')
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF7C4DFF).withOpacity(0.15),
                          border: Border.all(
                              color: const Color(0xFF7C4DFF), width: 1),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'M',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF7C4DFF),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      _localeMode == 'japanese' && _upscalingMode == 'magpie'
                          ? '🚀🌸 超分转区启动'
                          : (_upscalingMode == 'magpie'
                              ? '🚀 超分启动'
                              : (_localeMode == 'japanese'
                                  ? '🌸 转区启动'
                                  : '启动游戏')),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: _localeMode == 'japanese'
                            ? const Color(0xFFE91E63)
                            : AppColors.brandBlue,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _launchHovered = true),
          onExit: (_) {
            if (!_launchMenuOpen) setState(() => _launchHovered = false);
          },
          child: GestureDetector(
            onTapDown: (_) {
              setState(() {
                _launchMenuOpen = !_launchMenuOpen;
                if (_launchMenuOpen) {
                  _menuController.forward(from: 0);
                } else {
                  _menuController.reverse();
                }
              });
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _launchHovered || _launchMenuOpen
                    ? AppColors.placeholderCover
                    : (_localeMode == 'japanese'
                        ? AppColors.errorBg
                        : AppColors.background),
                border: Border.all(
                  color: _launchMenuOpen
                      ? AppColors.border
                      : (_localeMode == 'japanese'
                          ? const Color(0xFFF48FB1)
                          : AppColors.borderLight),
                  width: _launchMenuOpen ? 1.5 : 1.2,
                ),
                borderRadius:
                    const BorderRadius.horizontal(right: Radius.circular(20)),
                boxShadow: (_launchHovered || _launchMenuOpen)
                    ? [
                        BoxShadow(
                          color: AppColors.border.withOpacity(0.15),
                          offset: const Offset(0, 2),
                          blurRadius: 6,
                        )
                      ]
                    : null,
              ),
              child: Icon(
                _launchMenuOpen
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
                color: _launchHovered || _launchMenuOpen
                    ? AppColors.primaryText
                    : AppColors.brandBlue,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _closeMenu() {
    if (_launchMenuOpen) {
      setState(() {
        _launchMenuOpen = false;
        _launchHovered = false;
      });
      _menuController.reverse();
    }
  }

  Widget _buildLaunchMenu() {
    return Positioned(
      left: 16,
      bottom: 140,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: Container(
            constraints: const BoxConstraints(minWidth: 200),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(0, 8),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                ),
              ],
              border: Border.all(
                color: AppColors.placeholderCover,
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuItem(
                    icon: Icons.play_arrow_rounded,
                    label: '正常启动',
                    isSelected:
                        _localeMode == 'none' && _upscalingMode == 'none',
                    onTap: () async {
                      _closeMenu();
                      // ★ 必须 await 模式落盘：GameLaunchService 读 game.json 决策，
                      // 未落盘就启动会走错分支（库页双击路径同样依赖 game.json）
                      await _setLocaleMode('none');
                      await _setUpscalingMode('none');
                      await _performLaunch();
                    },
                    iconColor: AppColors.brandBlue,
                  ),
                  Divider(height: 1, color: AppColors.placeholderCover),
                  _buildMenuItem(
                    icon: Icons.language_rounded,
                    label: '日语转区启动',
                    isSelected:
                        _localeMode == 'japanese' && _upscalingMode == 'none',
                    onTap: () async {
                      _closeMenu();
                      await _setLocaleMode('japanese');
                      await _setUpscalingMode('none');
                      await _performLaunch();
                    },
                    iconColor: const Color(0xFFE91E63),
                    highlightColor: AppColors.errorBg,
                  ),
                  Divider(height: 1, color: AppColors.placeholderCover),
                  _buildMenuItem(
                    icon: Icons.auto_fix_high_rounded,
                    label: '超分启动',
                    isSelected:
                        _upscalingMode == 'magpie' && _localeMode == 'none',
                    onTap: () async {
                      _closeMenu();
                      await _setUpscalingMode('magpie');
                      await _setLocaleMode('none');
                      await _performLaunch();
                    },
                    iconColor: const Color(0xFF7C4DFF),
                    highlightColor: const Color(0xFFF3E5F5),
                  ),
                  Divider(height: 1, color: AppColors.placeholderCover),
                  _buildMenuItem(
                    icon: Icons.auto_fix_high_rounded,
                    label: '超分 + 转区启动',
                    isSelected:
                        _upscalingMode == 'magpie' && _localeMode == 'japanese',
                    onTap: () async {
                      _closeMenu();
                      await _setUpscalingMode('magpie');
                      await _setLocaleMode('japanese');
                      await _performLaunch();
                    },
                    iconColor: const Color(0xFF7C4DFF),
                    highlightColor: const Color(0xFFF3E5F5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required Color iconColor,
    Color? highlightColor,
  }) {
    bool isHovered = false;

    return StatefulBuilder(
      builder: (context, setLocalState) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setLocalState(() => isHovered = true),
          onExit: (_) => setLocalState(() => isHovered = false),
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: isSelected
                    ? (highlightColor ?? AppColors.successBg)
                    : (isHovered ? AppColors.background : AppColors.background),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: iconColor),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: iconColor,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: iconColor.withOpacity(0.15),
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: iconColor,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFullWidthButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isHovered,
    required ValueChanged<bool> onHover,
    Color? hoverBg,
    Color? iconColor,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isHovered
                ? (hoverBg ?? AppColors.placeholderCover)
                : AppColors.background,
            border: Border.all(
              color: isHovered ? AppColors.border : AppColors.borderLight,
              width: 1.2,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: isHovered
                ? [
                    BoxShadow(
                      color: AppColors.border.withOpacity(0.15),
                      offset: const Offset(0, 2),
                      blurRadius: 6,
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 17,
                  color: iconColor ??
                      (isHovered
                          ? AppColors.primaryText
                          : AppColors.brandBlue)),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: iconColor ??
                        (isHovered
                            ? AppColors.primaryText
                            : AppColors.brandBlue),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isEditing && _scrapeResults.isNotEmpty && _scrapePanelOpen) ...[
          _buildScrapeResultsPanel(),
          const SizedBox(height: 14),
        ],
        _buildTitleSection(),
        const SizedBox(height: 18),
        _buildMetaGrid(),
        const SizedBox(height: 14),
        if (_tags.isNotEmpty || _isEditing) _buildOptimizedTagsRow(),
        const SizedBox(height: 14),
        // 查看态：左简介 + 右截图 两列布局；编辑态：保持上下排列
        if (_isEditing) ...[
          _buildEditableScreenshotSection(),
          if (_description.isNotEmpty || _isEditing) ...[
            const SizedBox(height: 14),
            _buildDescription(),
          ],
        ] else ...[
          _buildDescriptionAndScreenshots(),
        ],
      ],
    );
  }

  // ==================== 编辑态：截图管理 ====================

  /// 编辑态截图区块：缩略图横排（带删除）+ 添加自定义截图
  ///
  /// - 删除：立即删除本地文件并同步 game.json 的 screenshot_files
  /// - 添加：file_picker 选择本地图片，复制到元数据目录 screenshots/
  ///   子目录后写入 screenshot_files
  /// - 浏览：鼠标滚轮（垂直轮映射为横向滚动）+ 按住拖拽 + 左右箭头，
  ///   截图上限 6 张，溢出时可横向滚动查看全部
  Widget _buildEditableScreenshotSection() {
    // 布局完成后同步箭头显隐状态（截图增删/进入编辑态后刷新）
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncShotScrollState());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('截图（${_screenshotFiles.length}/6张）',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                )),
            const SizedBox(width: 10),
            Text(
              '可直接删除或添加自定义截图，滚轮/箭头可横向浏览',
              style: TextStyle(
                  fontSize: 11.5, color: AppColors.secondaryText),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 118,
          child: Stack(
            children: [
              Positioned.fill(
                child: ScrollConfiguration(
                  // 允许鼠标按住拖拽横向滚动
                  behavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                    dragDevices: PointerDeviceKind.values.toSet(),
                  ),
                  child: Listener(
                    // 滚轮垂直滚动量映射为截图列表横向滚动（resolver 抢占，
                    // 防止外层详情竖向滚动容器抢走滚轮事件）
                    onPointerSignal: _onEditShotsPointerSignal,
                    child: ListView.builder(
                      controller: _editShotsScrollController,
                      scrollDirection: Axis.horizontal,
                      itemCount: _screenshotFiles.length + 1, // 末尾固定一个"添加"卡片
                      itemBuilder: (context, index) {
                        if (index == _screenshotFiles.length) {
                          return _buildAddScreenshotTile();
                        }
                        return _buildEditableScreenshotTile(index);
                      },
                    ),
                  ),
                ),
              ),
              // 左箭头：截图溢出且未滚到最左时显示
              if (_shotsCanScroll && !_shotsAtStart)
                Positioned(left: 0, top: 0, bottom: 0, child: _buildShotArrow(forward: false)),
              // 右箭头：截图溢出且未滚到最右时显示
              if (_shotsCanScroll && !_shotsAtEnd)
                Positioned(right: 0, top: 0, bottom: 0, child: _buildShotArrow(forward: true)),
            ],
          ),
        ),
      ],
    );
  }

  /// 编辑态截图列表左右箭头按钮（与查看态截图轮播的箭头风格一致）
  Widget _buildShotArrow({required bool forward}) {
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _scrollEditShots(forward: forward),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              shape: BoxShape.circle,
            ),
            child: Icon(
              forward ? Icons.chevron_right : Icons.chevron_left,
              size: 18,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// 箭头点击：横向滚动约两张截图的宽度
  void _scrollEditShots({required bool forward}) {
    if (!_editShotsScrollController.hasClients) return;
    final pos = _editShotsScrollController.position;
    const delta = 436.0; // 2 × (210 卡片宽 + 8 间距)
    final target = (pos.pixels + (forward ? delta : -delta))
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _editShotsScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 鼠标滚轮：垂直滚动量映射为截图列表横向滚动（注册 resolver 抢占消费）
  void _onEditShotsPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !_editShotsScrollController.hasClients) {
      return;
    }
    final position = _editShotsScrollController.position;
    // 截图未溢出：放行给外层详情竖向滚动
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    // 溢出时抢占本次滚轮事件，只滚动截图列表
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent e) {
        if (e is! PointerScrollEvent ||
            !_editShotsScrollController.hasClients) {
          return;
        }
        final pos = _editShotsScrollController.position;
        final target = (pos.pixels + e.scrollDelta.dy)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _editShotsScrollController.jumpTo(target);
      },
    );
  }

  /// 鼠标滚轮：垂直滚动量映射为元数据匹配面板横向滚动（注册 resolver 抢占消费）
  void _onScrapePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrapeScrollController.hasClients) {
      return;
    }
    final position = _scrapeScrollController.position;
    // 候选卡未溢出：无需横向滚动，放行给外层详情竖向滚动
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    // 溢出时抢占本次滚轮事件，只滚动候选列表
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent e) {
        if (e is! PointerScrollEvent || !_scrapeScrollController.hasClients) {
          return;
        }
        final pos = _scrapeScrollController.position;
        final target = (pos.pixels + e.scrollDelta.dy)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _scrapeScrollController.jumpTo(target);
      },
    );
  }

  /// 同步截图列表滚动状态（箭头显隐/可用性）
  void _syncShotScrollState() {
    if (!_editShotsScrollController.hasClients) {
      if (_shotsCanScroll) {
        if (mounted) {
          setState(() {
            _shotsCanScroll = false;
            _shotsAtStart = true;
            _shotsAtEnd = false;
          });
        }
      }
      return;
    }
    final pos = _editShotsScrollController.position;
    final canScroll = pos.maxScrollExtent > pos.minScrollExtent;
    final atStart = pos.pixels <= pos.minScrollExtent + 0.5;
    final atEnd = pos.pixels >= pos.maxScrollExtent - 0.5;
    if (canScroll != _shotsCanScroll ||
        atStart != _shotsAtStart ||
        atEnd != _shotsAtEnd) {
      if (mounted) {
        setState(() {
          _shotsCanScroll = canScroll;
          _shotsAtStart = atStart;
          _shotsAtEnd = atEnd;
        });
      }
    }
  }

  /// 单张截图卡片（悬停显示删除按钮）
  Widget _buildEditableScreenshotTile(int index) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 210,
              height: 118,
              child: NsfwImage.file(
                _screenshotFiles[index],
                width: 210,
                height: 118,
                child: Image.file(
                  File(_screenshotFiles[index]),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: AppColors.border.withOpacity(0.15),
                    child: const Center(
                        child: Icon(Icons.broken_image_outlined, size: 26)),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _deleteScreenshotAt(index),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "添加截图"卡片：选择本地图片导入
  Widget _buildAddScreenshotTile() {
    return SizedBox(
      width: 210,
      height: 118,
      child: Material(
        color: AppColors.border.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _addCustomScreenshots,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_photo_alternate_outlined, size: 26),
              const SizedBox(height: 4),
              Text('添加截图',
                  style: TextStyle(fontSize: 12, color: AppColors.secondaryText)),
            ],
          ),
        ),
      ),
    );
  }

  /// 删除指定截图：删文件 + 更新 game.json + 刷新内存列表
  Future<void> _deleteScreenshotAt(int index) async {
    if (index < 0 || index >= _screenshotFiles.length) return;
    final path = _screenshotFiles[index];
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[EDIT] 截图文件删除失败: $e');
    }

    final remaining = List<String>.from(_screenshotFiles)..removeAt(index);
    // game.json 存相对文件名（相对 metaDataDir）
    final relative = remaining
        .map((p) => p.startsWith('$_metaDataDir/')
            ? p.substring('$_metaDataDir/'.length)
            : p)
        .toList();
    await GameDataFormat.updateGameJson(_metaDataDir, {
      'screenshot_files': relative,
      if (relative.isEmpty) 'screenshot_status': 'completed',
    });
    // 同步注册表内存（库页截图来源）
    final registryGame = LocalGameRegistry.instance.getGameByTitle(_title);
    if (registryGame != null) {
      registryGame.screenshotStatus = 'completed';
    }
    if (mounted) setState(() => _screenshotFiles = remaining);
    debugPrint('[EDIT] ✅ 截图已删除: $path');
  }

  /// 添加自定义截图：file_picker 多选图片 → 复制到 screenshots/ → 持久化
  ///
  /// 截图上限 6 张（与库页截图展示上限一致），超出部分不导入并提示
  Future<void> _addCustomScreenshots() async {
    try {
      const maxScreenshots = 6;
      if (_screenshotFiles.length >= maxScreenshots) {
        AppSnackBar.info(
          context,
          '截图已达上限（6张），请先删除部分截图',
          duration: const Duration(seconds: 2),
        );
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final shotDir = Directory('$_metaDataDir/screenshots');
      if (!await shotDir.exists()) {
        await shotDir.create(recursive: true);
      }

      // 只导入上限内的数量
      final room = maxScreenshots - _screenshotFiles.length;
      final picked = result.files.take(room).toList();
      if (result.files.length > room && mounted) {
        AppSnackBar.info(
          context,
          '截图上限 6 张，已添加前 $room 张',
          duration: const Duration(seconds: 2),
        );
      }

      final added = <String>[];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < picked.length; i++) {
        final f = picked[i];
        if (f.path == null) continue;
        final ext = f.extension != null && f.extension!.isNotEmpty
            ? '.${f.extension}'
            : '.jpg';
        final dest = '${shotDir.path}/custom_${stamp}_$i$ext';
        try {
          await File(f.path!).copy(dest);
          added.add(dest);
        } catch (e) {
          debugPrint('[EDIT] 自定义截图复制失败: ${f.path}, $e');
        }
      }
      if (added.isEmpty) return;

      final updated = [..._screenshotFiles, ...added];
      final relative = updated
          .map((p) => p.startsWith('$_metaDataDir/')
              ? p.substring('$_metaDataDir/'.length)
              : p)
          .toList();
      await GameDataFormat.updateGameJson(_metaDataDir, {
        'screenshot_files': relative,
        'screenshot_status': 'completed',
      });
      final registryGame = LocalGameRegistry.instance.getGameByTitle(_title);
      if (registryGame != null) {
        registryGame.screenshotStatus = 'completed';
      }
      if (mounted) setState(() => _screenshotFiles = updated);
      debugPrint('[EDIT] ✅ 已添加 ${added.length} 张自定义截图');
    } catch (e) {
      debugPrint('[EDIT] 添加自定义截图异常: $e');
    }
  }

  /// 查看态：L 型百科式布局
  /// 简介文字环绕截图（像百科全书的插图排版）：
  /// - 截图右侧占半宽，其左侧竖排第一段简介文字
  /// - 截图底部分界线以下，剩余简介文字占满全宽（L 的底部横条）
  /// 截图支持双击看大图、悬停放大镜交互。
  Widget _buildDescriptionAndScreenshots() {
    final screenshotPanel = ScreenshotCarousel(
      paths: _screenshotFiles,
      isNetwork: false,
      gameTitle: _title.isNotEmpty ? _title : null,
      enableHoverZoom: true,
      onImageDoubleTap: _showScreenshotLightbox,
      onRefresh: _reloadScreenshots,
    );

    // 简介为空：截图占满整行
    if (_description.isEmpty) {
      return screenshotPanel;
    }

    final descStyle = TextStyle(
      fontSize: 13.5,
      color: AppColors.primaryText,
      height: 1.75,
    );
    const titleHeight = 21.0; // 「简介」标题行高（14px × 1.5）
    const titleGap = 8.0;

    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      const gap = 14.0;
      // 左右各占一半（5:5）
      final colWidth = (totalWidth - gap) / 2;
      // 截图为 16:9，按列宽计算实际渲染高度
      final shotHeight = colWidth * 9 / 16;
      // 多图时截图轮播底部有指示点行（点高 6 + 上间距 6 = 12）
      final indicatorExtra = _screenshotFiles.length > 1 ? 12.0 : 0.0;
      // 截图面板整体高度（图片 + 指示点）
      final panelHeight = shotHeight + indicatorExtra;
      // 竖排区可用文字高度 = 截图面板高 - 标题行 - 标题下间距
      final firstAreaHeight = panelHeight - titleHeight - titleGap;

      // 截图太矮放不下竖排文字 → 退化为上下结构
      if (firstAreaHeight < 24) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            screenshotPanel,
            const SizedBox(height: 14),
            _buildDescription(),
          ],
        );
      }

      final parts =
          _splitDescriptionForLShape(_description, colWidth, firstAreaHeight, descStyle);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('简介',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.secondaryText,
                        )),
                    const SizedBox(height: titleGap),
                    if (parts[0].isNotEmpty)
                      Text(parts[0], style: descStyle),
                  ],
                ),
              ),
              const SizedBox(width: gap),
              Expanded(child: screenshotPanel),
            ],
          ),
          // L 底部横条：截图下方的剩余文字，占满全宽
          if (parts[1].isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(parts[1], style: descStyle),
          ],
        ],
      );
    });
  }

  /// 按可用高度把简介切成两段，实现 L 型环绕排版
  /// 返回 [第一段（截图左侧竖排）, 第二段（截图下方全宽）]
  List<String> _splitDescriptionForLShape(
      String text, double width, double maxHeight, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    final lines = painter.computeLineMetrics();
    double usedHeight = 0;
    int fitLines = 0;
    for (final line in lines) {
      if (usedHeight + line.height <= maxHeight + 0.5) {
        usedHeight += line.height;
        fitLines++;
      } else {
        break;
      }
    }

    // 全部文字都放得下：只有竖排，无底部横条
    if (fitLines >= lines.length) return [text, ''];
    // 一行都放不下：全部放到底部横条
    if (fitLines == 0) return ['', text];

    // 取第 fitLines 行末尾的文本偏移
    final pos = painter.getPositionForOffset(Offset(width, usedHeight - 1));
    var end = pos.offset;
    if (end <= 0) return ['', text];
    if (end >= text.length) return [text, ''];
    return [text.substring(0, end), text.substring(end)];
  }

  /// 双击截图 → 弹出大图查看（Lightbox）
  void _showScreenshotLightbox(int index) {
    if (_screenshotFiles.isEmpty) return;
    showAppDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _ScreenshotLightbox(
        paths: _screenshotFiles,
        initialIndex: index,
      ),
    );
  }

  Widget _buildTitleSection() {
    if (_isEditing) {
      return Stack(
        children: [
          TextField(
            controller: _titleController,
            // ★ 标题锁默认锁定：锁定时只读，用户开锁后才能修改
            readOnly: _titleLocked,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              color: _titleLocked
                  ? AppColors.secondaryText.withOpacity(0.65)
                  : AppColors.titleBrown,
            ),
            decoration: InputDecoration(
              contentPadding: EdgeInsets.only(right: 32),
              isDense: true,
              border: InputBorder.none,
              hintText: _titleLocked ? '标题已锁定，点击右侧锁图标解锁' : '输入游戏标题',
              hintStyle: TextStyle(
                fontSize: 24,
                color: AppColors.placeholderText,
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: _buildFieldLockButton(
              isLocked: _titleLocked,
              onToggle: () => setState(() => _titleLocked = !_titleLocked),
              lockedTip: '标题已锁定：不可编辑，抓取元数据时保留标题（点击解锁）',
              unlockedTip: '标题未锁定：可编辑，抓取元数据时会覆盖标题（点击锁定）',
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _title.isNotEmpty ? _title : '未知游戏',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.2,
            color: AppColors.titleBrown,
          ),
        ),
        // 星级 + 评分人数：贴在标题系统最末行（与副标题平行、紧随其右），
        // 无副标题时该行仍保留（星级紧跟主标题下方），避免标题区高度跳动
        if (_subtitle.isNotEmpty || _hasRatingDisplay)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_subtitle.isNotEmpty)
                  Flexible(
                    child: Text(
                      _subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.secondaryText.withOpacity(0.85),
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (_hasRatingDisplay) ...[
                  if (_subtitle.isNotEmpty) const SizedBox(width: 10),
                  _buildRatingBadge(),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// 是否有可展示的评分数据（星级与评分人数共用判定）
  bool get _hasRatingDisplay => _rating > 0;

  /// 星级 + 评分人数徽标（副标题行尾）
  ///
  /// 尺寸对齐探索页元数据行（icon 13 / 文字 12）并略大：icon 15 / 文字 13，
  /// 图标与数字大小统一。评分人数缺失时只显示星级。
  Widget _buildRatingBadge() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.star_rounded, size: 15, color: AppColors.starGold),
        const SizedBox(width: 3),
        Text(
          _rating.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryText.withOpacity(0.85),
          ),
        ),
        if (_ratingCount > 0) ...[
          const SizedBox(width: 8),
          Icon(Icons.people_alt_rounded,
              size: 15, color: AppColors.secondaryText.withOpacity(0.55)),
          const SizedBox(width: 3),
          Text(
            _formatRatingCount(_ratingCount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetaGrid() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.placeholderCover),
      ),
      child: Column(
        children: [
          _metaRowWithRightWidget(
            leftLabel: '来源',
            leftValue: _displaySource,
            rightWidget: const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          _buildDateRow(),
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '目录',
            leftValue: _gameDirectoryPath,
            rightWidget: Icon(
              _directoryMenuOverlay != null
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.secondaryText,
            ),
            isClickable: true,
            onTap: _showDirectoryActionMenu,
            rowKey: _directoryRowKey,
          ),
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '占用空间',
            leftValue: _isCalculatingSize ? '计算中...' : _directorySize,
            rightWidget: _isCalculatingSize
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.secondaryText.withOpacity(0.5),
                      ),
                    ),
                  )
                : (_directorySize.isNotEmpty
                    ? Icon(Icons.sd_storage_rounded,
                        size: 16, color: AppColors.brandBlue)
                    : const SizedBox.shrink()),
          ),
          if (_developer.isNotEmpty || _isEditing) ...[
            const SizedBox(height: 10),
            _buildDeveloperRow(),
          ],
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '启动信息',
            leftValue: '',
            rightWidget: _buildLaunchInfoBadge(),
          ),
          // 存储状态行（Phase 4）：仅封装/打包态显示（normal 时信息量为零，不加行）
          if (_storageStateLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            _metaRowWithRightWidget(
              leftLabel: '存储状态',
              leftValue: _storageStateLabel,
              rightWidget: _isCalcArchiveSize
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.secondaryText.withOpacity(0.5),
                        ),
                      ),
                    )
                  : (_archiveSize.isNotEmpty
                      ? Text('归档 $_archiveSize',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.secondaryText,
                          ))
                      : const SizedBox.shrink()),
            ),
          ],
          // 游玩记录小框 - 嵌入在元数据框内部
          const SizedBox(height: 12),
          _buildPlayRecordSubBox(),
        ],
      ),
    );
  }

  /// 游玩记录紧凑小框 - 嵌入在元数据框内部
  Widget _buildPlayRecordSubBox() {
    final current = PlayStatus.values.firstWhere((s) => s == _playStatus);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: current.color.withOpacity(0.35), width: 1),
      ),
      child: Column(
        children: [
          // 第一行：状态 + 预计时长 | 时长
          Row(
            children: [
              // 游玩状态
              _buildPlayStatusDropdown(),
              const Spacer(),
              // 预计游玩时长（VNDB 多用户平均；无数据不占位）
              if (_estimatedMinutes > 0) ...[
                Text('预计时长',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.secondaryText.withOpacity(0.7),
                    )),
                const SizedBox(width: 6),
                Text(_formattedEstimatedTime,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText.withOpacity(0.7),
                    )),
                // 短竖直分隔线：预计时长 | 实际游玩时长
                const SizedBox(width: 10),
                Container(
                  width: 1,
                  height: 14,
                  color: AppColors.border.withOpacity(0.45),
                ),
                const SizedBox(width: 10),
              ],
              // 游玩时长
              Text('游玩时长',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.secondaryText.withOpacity(0.7),
                  )),
              const SizedBox(width: 6),
              Text(_formattedPlayTime,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _playTime > 0
                        ? AppColors.primaryText
                        : AppColors.secondaryText.withOpacity(0.4),
                  )),
            ],
          ),
          // 第二行：首次/最后打开时间（有记录时显示）
          if (_firstOpenedAt.isNotEmpty || _lastOpenedAt.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(
                height: 1, color: AppColors.placeholderCover.withOpacity(0.6)),
            const SizedBox(height: 6),
            Row(
              children: [
                if (_firstOpenedAt.isNotEmpty)
                  _buildCompactTimeInfo('首次', _firstOpenedAt),
                if (_firstOpenedAt.isNotEmpty && _lastOpenedAt.isNotEmpty)
                  const SizedBox(width: 16),
                if (_lastOpenedAt.isNotEmpty)
                  _buildCompactTimeInfo('最后', _lastOpenedAt),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 紧凑的时间标签
  Widget _buildCompactTimeInfo(String label, String isoString) {
    String formatted;
    try {
      final dt = DateTime.parse(isoString);
      formatted =
          '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      formatted = isoString;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.secondaryText.withOpacity(0.6),
            )),
        Text(formatted,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.primaryText.withOpacity(0.7),
            )),
      ],
    );
  }

  /// 日期行：有发售日时「开发日期 + 安装日期」同行并列（开发日期居左，
  /// 安装日期相应右移）；无发售日时保持原「安装日期」单行不变
  Widget _buildDateRow() {
    final devDate = _formattedReleaseDate;
    if (devDate.isEmpty) {
      return _metaRowWithRightWidget(
        leftLabel: '安装日期',
        leftValue: _formattedDate,
        rightWidget: const SizedBox.shrink(),
      );
    }
    final labelStyle = TextStyle(
      fontSize: 13,
      color: AppColors.secondaryText,
    );
    final valueStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w500,
      color: AppColors.primaryText,
    );
    return Row(
      children: [
        SizedBox(width: 64, child: Text('开发日期', style: labelStyle)),
        Expanded(
          child: Text(devDate,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle),
        ),
        const SizedBox(width: 16),
        SizedBox(width: 64, child: Text('安装日期', style: labelStyle)),
        Expanded(
          child: Text(_formattedDate,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle),
        ),
      ],
    );
  }

  Widget _metaRowWithRightWidget({
    required String leftLabel,
    required String leftValue,
    required Widget rightWidget,
    bool isClickable = false,
    VoidCallback? onTap,
    GlobalKey? rowKey,
  }) {
    final content = Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(leftLabel,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        if (leftValue.isNotEmpty)
          Expanded(
            child: Text(leftValue,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primaryText,
                )),
          )
        else
          Expanded(child: const SizedBox.shrink()),
        rightWidget,
      ],
    );

    if (isClickable && onTap != null) {
      return MouseRegion(
        key: rowKey,
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(
                color: AppColors.border.withOpacity(0.3),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: content,
          ),
        ),
      );
    }

    return content;
  }

  /// 下拉式游玩状态选择器
  /// 点击当前状态按钮展开4个选项，选中后自动收起
  Widget _buildPlayStatusDropdown() {
    final statuses = PlayStatus.values;

    final current = statuses.firstWhere((s) => s == _playStatus);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 当前状态按钮（点击展开/收起）
        GestureDetector(
          onTap: () =>
              setState(() => _statusDropdownOpen = !_statusDropdownOpen),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: current.color.withOpacity(0.1),
                border:
                    Border.all(color: current.color.withOpacity(0.6), width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(current.icon, size: 14, color: current.color),
                  SizedBox(width: 4),
                  Text(
                    current.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: current.color,
                    ),
                  ),
                  SizedBox(width: 3),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    turns: _statusDropdownOpen ? 0.5 : 0,
                    child:
                        Icon(Icons.expand_more, size: 14, color: current.color),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 展开的状态选项列表
        if (_statusDropdownOpen)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  offset: Offset(0, 2),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: statuses.map((s) {
                final isActive = s == _playStatus;
                return GestureDetector(
                  onTap: () {
                    _setPlayStatus(s);
                    setState(() => _statusDropdownOpen = false);
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 100,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: isActive
                            ? s.color.withOpacity(0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          if (isActive)
                            Icon(Icons.check_rounded, size: 14, color: s.color)
                          else
                            SizedBox(width: 14),
                          SizedBox(width: 6),
                          Icon(s.icon,
                              size: 13,
                              color:
                                  isActive ? s.color : AppColors.secondaryText),
                          SizedBox(width: 6),
                          Text(s.label,
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    isActive ? s.color : AppColors.primaryText,
                              )),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildLaunchInfoBadge() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 超分状态 Badge
        _buildUpscalingBadge(),
        const SizedBox(width: 8),
        // 转区状态 Badge（保持原有逻辑）
        _buildLocaleStatusBadge(),
      ],
    );
  }

  Widget _buildUpscalingBadge() {
    final isMagpie = _upscalingMode == 'magpie';
    final isAvailable = _magpieAvailable;

    return Tooltip(
      message: isMagpie
          ? '超分模式已开启，点击关闭'
          : (isAvailable ? '点击开启超分模式' : 'Magpie 未配置，请在偏好设置中配置'),
      preferBelow: true,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (!isAvailable) return;
            final newMode = isMagpie ? 'none' : 'magpie';
            _setUpscalingMode(newMode);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isMagpie
                  ? const Color(0xFFF3E5F5)
                  : (isAvailable
                      ? const Color(0xFFEEEEEE)
                      : const Color(0xFFFFF3E0)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isMagpie
                    ? const Color(0xFF7C4DFF)
                    : (isAvailable
                        ? AppColors.placeholderText
                        : const Color(0xFFFFCC80)),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isMagpie
                      ? Icons.check_circle_rounded
                      : (isAvailable
                          ? Icons.auto_fix_high_rounded
                          : Icons.warning_amber_rounded),
                  size: 13,
                  color: isMagpie
                      ? const Color(0xFF7C4DFF)
                      : (isAvailable
                          ? const Color(0xFF9E9E9E)
                          : const Color(0xFFEF6C00)),
                ),
                const SizedBox(width: 3),
                Text(
                  isMagpie ? '超分启动' : (isAvailable ? '普通启动' : '未配置'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: isMagpie
                        ? const Color(0xFF7C4DFF)
                        : (isAvailable
                            ? const Color(0xFF757575)
                            : const Color(0xFFEF6C00)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocaleStatusBadge() {
    final isJapanese = _localeMode == 'japanese';
    final hasEngine = _localeAvailable;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          final newMode = isJapanese ? 'none' : 'japanese';
          _setLocaleMode(newMode);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: isJapanese
                ? AppColors.errorBg
                : (hasEngine
                    ? const Color(0xFFEEEEEE)
                    : const Color(0xFFFFF3E0)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isJapanese
                  ? const Color(0xFFF48FB1)
                  : (hasEngine
                      ? AppColors.placeholderText
                      : const Color(0xFFFFCC80)),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isJapanese
                    ? Icons.check_circle_rounded
                    : (hasEngine
                        ? Icons.radio_button_unchecked_rounded
                        : Icons.warning_amber_rounded),
                size: 14,
                color: isJapanese
                    ? const Color(0xFFE91E63)
                    : (hasEngine
                        ? const Color(0xFF9E9E9E)
                        : const Color(0xFFEF6C00)),
              ),
              const SizedBox(width: 4),
              Text(
                isJapanese ? '日语环境' : (hasEngine ? '正常启动' : '引擎未安装'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isJapanese
                      ? const Color(0xFFE91E63)
                      : (hasEngine
                          ? const Color(0xFF757575)
                          : const Color(0xFFEF6C00)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 会社联想候选（Phase 3）：输入非空时从词典联想；排除与输入归一化
  /// 相同的标准名（已是命中结果，无需再建议）。数量限 6，防止拉长编辑区。
  List<CompanyRecord> get _developerSuggestions {
    if (!_isEditing) return const [];
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return const [];
    final query = _developerController.text.trim();
    if (query.isEmpty) return const [];
    final nq = CompanyAliasStore.normalize(query);
    return store
        .search(query, limit: 8)
        .where((r) => CompanyAliasStore.normalize(r.standardName) != nq)
        .take(6)
        .toList();
  }

  /// 联想候选 chip：展示「标准名（中文名）」，点击填入标准名。
  Widget _developerSuggestionChip(CompanyRecord rec) {
    final cn = rec.cnName;
    final label = (cn != null && cn != rec.standardName)
        ? '${rec.standardName}（$cn）'
        : rec.standardName;
    return GestureDetector(
      onTap: () {
        _developerController.text = rec.standardName;
        _developerController.selection = TextSelection.collapsed(
            offset: rec.standardName.length);
        setState(() {});
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.placeholderCover, width: 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeveloperRow() {
    if (_isEditing) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            child: Row(
              children: [
                Text('会社',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.secondaryText,
                    )),
                const SizedBox(width: 4),
                _buildFieldLockButton(
                  isLocked: _developerLocked,
                  onToggle: () =>
                      setState(() => _developerLocked = !_developerLocked),
                  lockedTip: '已锁定：抓取元数据时保留会社',
                  unlockedTip: '未锁定：抓取元数据时会覆盖会社',
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _developerController,
                  // ★ 会社归一化（Phase 3）：输入时实时联想词典会社
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primaryText,
                  ),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
                filled: true,
                fillColor: AppColors.background,
                hintText: '输入会社名称',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: AppColors.secondaryText.withOpacity(0.5),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.placeholderCover, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.placeholderCover, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.border, width: 1.5),
                ),
              ),
                ),
                // ★ 会社归一化（Phase 3）：词典联想候选——点击即把标准名
                //   填入输入框（保存时 resolve 必命中，分组即时归并）
                if (_developerSuggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final rec in _developerSuggestions)
                          _developerSuggestionChip(rec),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text('会社',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        Expanded(
          child: Text(_developer,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: AppColors.primaryText,
              )),
        ),
        SizedBox(
          width: 20,
          height: 20,
          child: Icon(Icons.business_rounded,
              size: 16, color: AppColors.brandBlue),
        ),
      ],
    );
  }

  Widget _buildOptimizedTagsRow() {
    if (_isEditing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('标签（逗号分隔）',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondaryText,
                  )),
              const SizedBox(width: 6),
              _buildFieldLockButton(
                isLocked: _tagsLocked,
                onToggle: () => setState(() => _tagsLocked = !_tagsLocked),
                lockedTip: '已锁定：抓取元数据时保留标签',
                unlockedTip: '未锁定：抓取元数据时会覆盖标签',
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _tagsController,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.primaryText,
            ),
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              isDense: true,
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide:
                    BorderSide(color: AppColors.placeholderCover, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide:
                    BorderSide(color: AppColors.placeholderCover, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide(color: AppColors.border, width: 1.5),
              ),
            ),
          ),
        ],
      );
    }

    // 单行方框标签栏：支持鼠标滚轮（垂直轮映射为横向滚动）与按住拖拽横向滚动。
    // 滚轮冲突处理：Listener 放在滚动内容最深处，通过 pointerSignalResolver
    // 抢占滚轮事件（第一个注册者胜出），阻止事件继续给外层详情竖向滚动区，
    // 避免"滚标签时整个详情页也跟着上下滚"；标签未溢出时放行给外层。
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        dragDevices: PointerDeviceKind.values.toSet(),
      ),
      child: SingleChildScrollView(
        controller: _tagsScrollController,
        scrollDirection: Axis.horizontal,
        child: Listener(
          onPointerSignal: _onTagsPointerSignal,
          child: Row(
            children: [
              for (var i = 0; i < _tags.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _buildTagChip(_tags[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 鼠标滚轮：垂直滚动量映射为标签栏横向滚动（注册 resolver 抢占消费）
  void _onTagsPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_tagsScrollController.hasClients) {
      return;
    }
    final position = _tagsScrollController.position;
    // 标签未溢出：无需横向滚动，放行给外层详情竖向滚动
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    // 溢出时抢占本次滚轮事件，只滚动标签栏
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent e) {
        if (e is! PointerScrollEvent || !_tagsScrollController.hasClients) {
          return;
        }
        final pos = _tagsScrollController.position;
        final target = (pos.pixels + e.scrollDelta.dy)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _tagsScrollController.jumpTo(target);
      },
    );
  }

  Widget _buildTagChip(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: AppColors.borderLight, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: AppColors.primaryText,
        ),
      ),
    );
  }

  Widget _buildFieldLockButton({
    required bool isLocked,
    required VoidCallback onToggle,
    required String lockedTip,
    required String unlockedTip,
  }) {
    return InteractiveWrapper(
      onTap: onToggle,
      hoverScale: 1.15,
      child: Tooltip(
        message: isLocked ? lockedTip : unlockedTip,
        waitDuration: const Duration(milliseconds: 500),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: isLocked
                ? AppColors.border.withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            isLocked ? Icons.lock : Icons.lock_open,
            size: 18,
            color: isLocked
                ? AppColors.border
                : AppColors.placeholderText.withOpacity(0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildScrapeResultsPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.brandBlue.withOpacity(0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: AppColors.brandBlue),
              const SizedBox(width: 8),
              Text('元数据匹配',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.brandBlue,
                  )),
              const Spacer(),
              InteractiveWrapper(
                onTap: () => setState(() {
                  _scrapeResults = [];
                  _selectedScrapeResult = null;
                  _scrapePanelOpen = false;
                }),
                hoverScale: 1.1,
                child: Icon(Icons.close_rounded,
                    size: 16, color: AppColors.secondaryText),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 🔴 桌面端 Flutter 默认 dragDevices 不含鼠标 → 横向列表按住拖不动；
          // 显式放开（与截图条/标签栏同款）。滚轮垂直滚动量由
          // _onScrapePointerSignal 映射为横向滚动（resolver 抢占，防止外层详情
          // 竖向滚动容器抢走滚轮事件）。
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: PointerDeviceKind.values.toSet(),
            ),
            child: Listener(
              onPointerSignal: _onScrapePointerSignal,
              child: SizedBox(
                height: 110,
                child: ListView.separated(
                  controller: _scrapeScrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: _scrapeResults.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final result = _scrapeResults[index];
                    final isSelected = _selectedScrapeResult == result;
                    return _buildScrapeResultCard(result, isSelected);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrapeResultCard(Map<String, dynamic> result, bool isSelected) {
    final platform = result['platform'] as String? ?? '';
    final gameName = result['game_name'] as String? ?? '';
    final releaseDate = result['release_date'] as String? ?? '';
    final coverUrl = result['cover_url'] as String? ?? '';

    return InteractiveWrapper(
      onTap: () => _applyScrapeResult(result),
      hoverScale: 1.03,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 180,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.brandBlue.withOpacity(0.08)
              : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                isSelected ? AppColors.brandBlue : AppColors.placeholderCover,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: coverUrl.isNotEmpty
                  ? NsfwImage.network(
                      coverUrl,
                      contentKind: NsfwContentKind.cover,
                      width: 50,
                      height: 70,
                      // 刮削候选图只走 CachedNetworkImage 磁盘缓存，
                      // 不经下载服务也不在全量扫描范围（§7.1 风险🟠4），
                      // 需在缓存落盘后按需补检
                      detectOnDemand: true,
                      child: CachedNetworkImage(
                        cacheManager: PortableImageCacheManager(),
                        imageUrl: coverUrl,
                        width: 50,
                        height: 70,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          width: 50,
                          height: 70,
                          color: AppColors.placeholderCover,
                          child: Icon(Icons.image_rounded,
                              size: 18, color: AppColors.border),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 50,
                          height: 70,
                          color: AppColors.placeholderCover,
                          child: Icon(Icons.broken_image_rounded,
                              size: 18, color: AppColors.border),
                        ),
                      ),
                    )
                  : Container(
                      width: 50,
                      height: 70,
                      color: AppColors.placeholderCover,
                      child: Icon(Icons.videogame_asset_rounded,
                          size: 18, color: AppColors.border),
                    ),
            ),
            const SizedBox(width: 10),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Platform badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.brandBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      platform.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandBlue,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    gameName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                      height: 1.3,
                    ),
                  ),
                  if (releaseDate.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      releaseDate,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescription() {
    if (_isEditing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('简介',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondaryText,
                  )),
              const SizedBox(width: 6),
              _buildFieldLockButton(
                isLocked: _descLocked,
                onToggle: () => setState(() => _descLocked = !_descLocked),
                lockedTip: '已锁定：抓取元数据时保留简介',
                unlockedTip: '未锁定：抓取元数据时会覆盖简介',
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descController,
            maxLines: 5,
            minLines: 3,
            style: TextStyle(
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75,
            ),
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.placeholderCover, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.placeholderCover, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.border, width: 1.5),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('简介',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 8),
        Text(_description,
            style: TextStyle(
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75,
            )),
      ],
    );
  }
}

/// 截图大图查看（Lightbox）
/// 双击截图后弹出：窗口 60% 尺寸居中的大图弹窗。
/// - 原图等比 contain 居中展示
/// - 左右箭头 / 键盘方向键翻页
/// - 关闭方式：右上角 × 按钮 / 双击大图 / ESC / 点击空白遮罩
/// - 双击大图只关闭本弹窗（不误关详情窗口）
class _ScreenshotLightbox extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;

  const _ScreenshotLightbox({
    required this.paths,
    required this.initialIndex,
  });

  @override
  State<_ScreenshotLightbox> createState() => _ScreenshotLightboxState();
}

class _ScreenshotLightboxState extends State<_ScreenshotLightbox> {
  late int _index;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.paths.length - 1);
  }

  /// 防重复关闭（双击等场景避免连续 pop 把详情窗口也关掉）
  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _go(int delta) {
    if (widget.paths.isEmpty) return;
    setState(() {
      _index = (_index + delta + widget.paths.length) % widget.paths.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasMultiple = widget.paths.length > 1;
    final path = widget.paths.isEmpty ? null : widget.paths[_index];
    final windowSize = MediaQuery.sizeOf(context);

    return Focus(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          if (hasMultiple) ...{
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
          },
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 白色半透明磨砂遮罩：背景高斯模糊 + 轻微白色蒙层，
            // 透明度高，可透出底下详情窗口的模糊轮廓，单击空白关闭
            GestureDetector(
              onTap: _close,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(color: Colors.white.withOpacity(0.15)),
              ),
            ),
            // 居中弹窗：窗口 60% 尺寸
            Center(
              child: Container(
                width: windowSize.width * 0.6,
                height: windowSize.height * 0.6,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 原图等比居中；双击关闭（注册 onDoubleTap，
                      // 双击不会拆成两次单击误触发穿透）
                      GestureDetector(
                        onDoubleTap: _close,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Center(
                            child: path == null
                                ? const Icon(Icons.image_not_supported_outlined,
                                    size: 48, color: Colors.white38)
                                : NsfwImage.file(
                                    path,
                                    fit: BoxFit.contain,
                                    // Center 内约束无界，必须显式给出槽位尺寸，
                                    // 否则组件拿不到几何信息会退化为整图模糊
                                    width: windowSize.width * 0.6,
                                    height: windowSize.height * 0.6,
                                    enableReveal: true,
                                    child: Image.file(
                                      File(path),
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.broken_image_outlined,
                                        size: 48,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      // 右上角关闭按钮
                      Positioned(
                        top: 10,
                        right: 10,
                        child: _buildCloseButton(),
                      ),
                      // 计数
                      if (hasMultiple)
                        Positioned(
                          bottom: 10,
                          right: 14,
                          child: Text(
                            '${_index + 1}/${widget.paths.length}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      // 左右翻页箭头
                      if (hasMultiple) ...[
                        Positioned(
                          left: 10,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildArrow(Icons.chevron_left, () => _go(-1)),
                          ),
                        ),
                        Positioned(
                          right: 10,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildArrow(Icons.chevron_right, () => _go(1)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _close,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _buildArrow(IconData icon, VoidCallback onPressed) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

class _MoveLocationDialog extends StatefulWidget {
  final String currentLocation;
  final String gameTitle;
  final String metaDataDir;

  const _MoveLocationDialog({
    required this.currentLocation,
    required this.gameTitle,
    required this.metaDataDir,
  });

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  String? _newLocation;
  bool _isBrowsing = false;
  bool _isMoving = false;
  String? _pathError;
  String? _spaceInfo;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.80,
        ),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadowColor,
              offset: const Offset(0, 6),
              blurRadius: 16,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: _buildContent(),
            ),
            const SizedBox(height: 24),
            _buildFooter(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.placeholderCover, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.drive_file_move_rounded,
              size: 24, color: AppColors.brandBlue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('移动游戏位置',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.secondaryText,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('当前位置',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.placeholderCover),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, size: 18, color: AppColors.border),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.currentLocation,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.primaryText,
                    )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text('目标位置',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: _newLocation != null
                      ? AppColors.background
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _pathError != null
                        ? AppColors.dangerRed
                        : (_newLocation != null
                            ? AppColors.brandBlue
                            : AppColors.placeholderCover),
                    width: _pathError != null ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                        _newLocation != null
                            ? Icons.check_circle_rounded
                            : Icons.folder_open_rounded,
                        size: 18,
                        color: _pathError != null
                            ? AppColors.dangerRed
                            : (_newLocation != null
                                ? AppColors.successGreen
                                : AppColors.placeholderText)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_newLocation ?? '点击右侧按钮选择新位置...',
                          style: TextStyle(
                            fontSize: 13,
                            color: _newLocation != null
                                ? AppColors.primaryText
                                : AppColors.secondaryText,
                          )),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildBrowseButton(),
          ],
        ),
        if (_pathError != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.errorBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.dangerRed.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 16, color: AppColors.dangerRed),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_pathError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.dangerRed,
                      )),
                ),
              ],
            ),
          ),
        ],
        if (_spaceInfo != null && _pathError == null) ...[
          const SizedBox(height: 8),
          Text(_spaceInfo!,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.successGreen,
              )),
        ],
        if (_newLocation != null && _newLocation != widget.currentLocation) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF90CAF9)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: const Color(0xFF1976D2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      '游戏文件将被移动到:\n$_newLocation\\${widget.gameTitle}\n\n'
                      '★ 移动完成后原目录将被删除（同盘瞬时完成；跨盘将逐文件校验通过后才删除）',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: const Color(0xFF1565C0),
                        height: 1.4,
                      )),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBrowseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isBrowsing ? null : _browseDirectory,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color:
                _isBrowsing ? AppColors.placeholderCover : AppColors.brandBlue,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandBlue.withOpacity(0.2),
                offset: const Offset(0, 2),
                blurRadius: 6,
              )
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isBrowsing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              else
                Icon(Icons.folder_rounded, size: 17, color: Colors.white),
              if (!_isBrowsing) const SizedBox(width: 6),
              if (!_isBrowsing)
                Text('浏览',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final canConfirm = _newLocation != null &&
        _newLocation!.isNotEmpty &&
        _newLocation != widget.currentLocation &&
        _pathError == null &&
        !_isMoving;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(null),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AppColors.placeholderCover, width: 1),
                  ),
                  child: Center(
                    child: Text('取消',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.secondaryText,
                        )),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: MouseRegion(
              cursor: canConfirm
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                onTap: canConfirm ? _confirmMove : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: canConfirm
                        ? AppColors.brandBlue
                        : AppColors.placeholderText,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: _isMoving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.move_down_rounded,
                                  size: 17, color: Colors.white),
                              const SizedBox(width: 8),
                              Text('确认移动',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  )),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _browseDirectory() async {
    setState(() {
      _isBrowsing = true;
      _pathError = null;
      _spaceInfo = null;
    });

    try {
      final result = await FilePicker.platform.getDirectoryPath();

      if (result != null && result.isNotEmpty) {
        final validation = PathValidator.validateCustomGameLocation(result);

        if (!validation.isValid) {
          setState(() {
            _newLocation = result;
            _pathError = validation.message;
          });
        } else {
          final diskSpace = await PathValidator.getDiskSpaceInfo(result);

          setState(() {
            _newLocation = result;
            _pathError = null;
            if (diskSpace.isAvailable) {
              _spaceInfo = '可用空间: ${_formatBytes(diskSpace.freeSpaceBytes)}';
            }
          });
        }
      }
    } catch (e) {
      debugPrint('[MOVE-DIALOG] 浏览目录失败: $e');
    } finally {
      if (mounted) setState(() => _isBrowsing = false);
    }
  }

  void _confirmMove() async {
    if (_newLocation == null ||
        _newLocation == widget.currentLocation ||
        _pathError != null ||
        _isMoving) return;

    setState(() => _isMoving = true);

    try {
      final targetFullPath = '$_newLocation\\${widget.gameTitle}';

      Navigator.of(context).pop(targetFullPath);
    } catch (e) {
      AppSnackBar.error(
        context,
        '准备移动失败: $e',
      );
      setState(() => _isMoving = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 更换游戏目录对话框：用户已在资源管理器里手动挪完文件夹，
/// 软件只改路径引用、不复制文件。与 [_MoveLocationDialog] 视觉骨架一致，
/// 但校验更严（目录必须存在）+ 选完后异步检查 .exe + 不显示磁盘空间 + 返回值不拼 title。
  /// 迁移进度对话框：订阅 [GameMoveService.progressNotifier]，内部驱动迁移，
/// 完成后 `pop(MoveResult)` 交回调用方处理结果展示。
/// 不可误关（barrierDismissible=false）；跨盘 copy 阶段提供取消（回滚由服务负责）。
class _MoveProgressDialog extends StatefulWidget {
  final String gameTitle;
  final String targetPath;

  const _MoveProgressDialog({
    required this.gameTitle,
    required this.targetPath,
  });

  @override
  State<_MoveProgressDialog> createState() => _MoveProgressDialogState();
}

class _MoveProgressDialogState extends State<_MoveProgressDialog> {
  /// 非 null = 迁移已结束，切换到完成页（含旧路径引用扫描入口）
  MoveResult? _result;

  bool _scanning = false;
  RegistryScanReport? _scanReport;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _startMove();
  }

  Future<void> _startMove() async {
    final result = await GameMoveService.instance.moveGame(
      gameTitle: widget.gameTitle,
      targetDirPath: widget.targetPath,
    );
    // 不立即 pop：切换到完成页，由用户点「完成」后再交回主流程
    if (mounted) {
      setState(() => _result = result);
    }
  }

  /// 只读扫描注册表中仍引用旧路径的字符串值（不自动改写，报告给用户自行处理）
  Future<void> _runRegistryScan() async {
    final source = _result?.sourcePath ?? '';
    if (source.isEmpty) return;
    setState(() {
      _scanning = true;
      _scanError = null;
      _scanReport = null;
    });
    try {
      final report = await RegistryPathScanner.scanOldPathReferences(
        oldPath: source,
      );
      if (mounted) {
        setState(() => _scanReport = report);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _scanError = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      }
    }
  }

  void _finishDialog() {
    Navigator.of(context).pop(_result);
  }

  String _phaseLabel(String phase) {
    switch (phase) {
      case 'moving':
        return '正在移动（同盘原子操作）...';
      case 'preparing':
        return '正在统计文件...';
      case 'copying':
        return '正在复制并逐文件校验...';
      case 'cleaning':
        return '校验通过，正在清理原目录...';
      case 'switching':
        return '正在更新引用与配置...';
      default:
        return '正在移动...';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    // 完成态：结果页（含注册表旧路径引用扫描入口）
    final done = _result;
    if (done != null) {
      return _buildDonePage(done);
    }
    return AnimatedBuilder(
      animation: GameMoveService.instance.progressNotifier,
      builder: (context, _) {
        final progress = GameMoveService.instance.progressNotifier.value;
        final phase = progress?.phase ?? 'moving';
        final copying = phase == 'copying';
        final fraction = progress?.fraction ?? 0.0;
        final currentFile = progress?.currentFile ?? '';
        final fileName =
            currentFile.isEmpty ? '' : currentFile.split('\\').last;

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(AppRadius.xl),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  offset: Offset(0, 8),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.move_down_rounded,
                        size: 20, color: AppColors.brandBlue),
                    const SizedBox(width: 10),
                    Text('正在移动游戏位置',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText,
                        )),
                  ],
                ),
                const SizedBox(height: 18),
                Text(_phaseLabel(phase),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: copying && progress!.totalBytes > 0 ? fraction : null,
                    minHeight: 6,
                    backgroundColor: AppColors.placeholderCover,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        AppColors.brandBlue),
                  ),
                ),
                const SizedBox(height: 10),
                if (copying && progress!.totalBytes > 0)
                  Text(
                    '${_formatBytes(progress.copiedBytes)} / ${_formatBytes(progress.totalBytes)}'
                    '${progress.totalFiles > 0 ? ' · ${progress.copiedFiles}/${progress.totalFiles} 个文件' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.secondaryText,
                    )),
                if (fileName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('当前文件: $fileName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.secondaryText,
                        )),
                  ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      // 仅复制阶段可取消（rename 瞬时完成；收尾阶段取消无意义）
                      onTap: copying
                          ? () => GameMoveService.instance.cancelCurrentMove()
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: copying
                              ? AppColors.dangerRed
                              : AppColors.placeholderCover,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          copying ? '取消移动' : '请稍候...',
                          style: TextStyle(
                            fontSize: 13,
                            color: copying
                                ? Colors.white
                                : AppColors.secondaryText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 完成页：迁移结果概要 + 注册表旧路径引用扫描（只读）+ 完成按钮
  Widget _buildDonePage(MoveResult result) {
    final bool success = result.status == MoveStatus.success;
    final bool partial = result.status == MoveStatus.partial;
    final bool failed = result.status == MoveStatus.failed;

    final IconData headIcon = failed
        ? Icons.error_outline_rounded
        : (partial ? Icons.warning_amber_rounded : Icons.check_circle_rounded);
    final Color headColor = failed
        ? AppColors.dangerRed
        : (partial ? AppColors.warningAmber : AppColors.successGreen);
    final String headText = failed
        ? '移动失败'
        : (partial ? '移动完成（部分收尾未成功）' : '移动完成');

    final detailLines = <String>[
      if (failed) ...[
        result.errorMessage ?? '未知错误',
      ] else ...[
        if (result.movedViaRename) '同盘原子移动，瞬时完成' else '跨盘逐文件校验通过',
        if (result.sourceLeftoverPath != null)
          '旧目录未能完全删除（可能被占用）: ${result.sourceLeftoverPath}',
        ...result.referenceWarnings,
      ],
    ];

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              offset: Offset(0, 8),
              blurRadius: 24,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(headIcon, size: 22, color: headColor),
                const SizedBox(width: 10),
                Text(headText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
              ],
            ),
            const SizedBox(height: 14),
            ...detailLines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(line,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppColors.secondaryText,
                    )),
              ),
            ),
            // 注册表扫描：仅迁移成功/部分成功时有意义（失败时旧路径仍有效）
            if (!failed) ...[
              const SizedBox(height: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _scanning ? null : _runRegistryScan,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: _scanning
                          ? AppColors.placeholderCover
                          : AppColors.brandBlue.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _scanning
                            ? Colors.transparent
                            : AppColors.brandBlue,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_scanning)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(Icons.search_rounded,
                              size: 16, color: AppColors.brandBlue),
                        const SizedBox(width: 8),
                        Text(
                          _scanning
                              ? '正在扫描注册表（只读，最多 30 秒）...'
                              : '扫描仍引用旧路径的注册表项',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.brandBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (_scanError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('扫描失败: $_scanError',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.dangerRed,
                    )),
              ),
            if (_scanReport != null) ...[
              const SizedBox(height: 10),
              if (!_scanReport!.available)
                Text('注册表扫描不可用: ${_scanReport!.error ?? '未知原因'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.warningAmber,
                    ))
              else if (_scanReport!.hits.isEmpty)
                Text('✔ 未发现仍引用旧路径的注册表项',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.successGreen,
                    ))
              else
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.placeholderCover),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _scanReport!.hits.length,
                      itemBuilder: (context, index) {
                        final hit = _scanReport!.hits[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${hit.displayPath} · ${hit.valueName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primaryText,
                                  )),
                              Text(hit.valueData,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.secondaryText,
                                  )),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              if (_scanReport!.truncated)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('⚠ 已达扫描上限，结果可能不完整',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.warningAmber,
                      )),
                ),
            ],
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _finishDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 9),
                    decoration: BoxDecoration(
                      color: AppColors.brandBlue,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('完成',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Colors.white,
                        )),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 更换游戏目录：用户已在资源管理器里手动挪完文件夹，软件只改路径引用、不复制文件。

class _RelinkLocationDialog extends StatefulWidget {
  final String currentLocation;
  final String gameTitle;

  const _RelinkLocationDialog({
    required this.currentLocation,
    required this.gameTitle,
  });

  @override
  State<_RelinkLocationDialog> createState() => _RelinkLocationDialogState();
}

class _RelinkLocationDialogState extends State<_RelinkLocationDialog> {
  String? _newLocation;
  bool _isBrowsing = false;
  bool _isCheckingExe = false;
  bool _isProcessing = false;
  String? _pathError;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.80,
        ),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadowColor,
              offset: const Offset(0, 6),
              blurRadius: 16,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: _buildContent(),
            ),
            const SizedBox(height: 24),
            _buildFooter(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.placeholderCover, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.link_rounded, size: 24, color: AppColors.brandBlue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('更换游戏目录',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.secondaryText,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('当前位置',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.placeholderCover),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, size: 18, color: AppColors.border),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.currentLocation,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.primaryText,
                    )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text('新位置',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _pathError != null
                        ? AppColors.dangerRed
                        : (_newLocation != null
                            ? AppColors.brandBlue
                            : AppColors.placeholderCover),
                    width: _pathError != null ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                        _isCheckingExe
                            ? Icons.hourglass_top_rounded
                            : (_newLocation != null
                                ? Icons.check_circle_rounded
                                : Icons.folder_open_rounded),
                        size: 18,
                        color: _pathError != null
                            ? AppColors.dangerRed
                            : (_newLocation != null
                                ? AppColors.successGreen
                                : AppColors.placeholderText)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_newLocation ?? '点击右侧按钮选择游戏当前所在文件夹...',
                          style: TextStyle(
                            fontSize: 13,
                            color: _newLocation != null
                                ? AppColors.primaryText
                                : AppColors.secondaryText,
                          )),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildBrowseButton(),
          ],
        ),
        if (_pathError != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.errorBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.dangerRed.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 16, color: AppColors.dangerRed),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_pathError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.dangerRed,
                      )),
                ),
              ],
            ),
          ),
        ],
        if (_newLocation != null &&
            _newLocation != widget.currentLocation &&
            _pathError == null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF90CAF9)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: const Color(0xFF1976D2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      '更换后软件将指向新目录，原有文件不会被复制或删除。\n请选择包含游戏 exe 的文件夹本身（不是它的上一级）。',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: const Color(0xFF1565C0),
                        height: 1.4,
                      )),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBrowseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isBrowsing ? null : _browseDirectory,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color:
                _isBrowsing ? AppColors.placeholderCover : AppColors.brandBlue,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandBlue.withOpacity(0.2),
                offset: const Offset(0, 2),
                blurRadius: 6,
              )
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isBrowsing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              else
                Icon(Icons.folder_rounded, size: 17, color: Colors.white),
              if (!_isBrowsing) const SizedBox(width: 6),
              if (!_isBrowsing)
                Text('浏览',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final canConfirm = _newLocation != null &&
        _newLocation!.isNotEmpty &&
        _newLocation != widget.currentLocation &&
        _pathError == null &&
        !_isCheckingExe &&
        !_isProcessing;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(null),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AppColors.placeholderCover, width: 1),
                  ),
                  child: Center(
                    child: Text('取消',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.secondaryText,
                        )),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: MouseRegion(
              cursor: canConfirm
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                onTap: canConfirm ? _confirmRelink : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: canConfirm
                        ? AppColors.brandBlue
                        : AppColors.placeholderText,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: _isProcessing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.link_rounded,
                                  size: 17, color: Colors.white),
                              const SizedBox(width: 8),
                              Text('确认更换',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  )),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _browseDirectory() async {
    setState(() {
      _isBrowsing = true;
      _pathError = null;
    });

    try {
      final result = await FilePicker.platform.getDirectoryPath();

      if (result != null && result.isNotEmpty) {
        // relink 用 validateExistingGameLocation：不创建目录，要求 existsSync
        final validation = PathValidator.validateExistingGameLocation(result);

        if (!validation.isValid) {
          setState(() {
            _newLocation = result;
            _pathError = validation.message;
          });
        } else {
          setState(() {
            _newLocation = result;
            _pathError = null;
          });
          // 选完目录后异步检查有无 .exe（UI 提示，不阻断 service 层兜底）
          await _checkExeExists(result);
        }
      }
    } catch (e) {
      debugPrint('[RELINK-DIALOG] 浏览目录失败: $e');
    } finally {
      if (mounted) setState(() => _isBrowsing = false);
    }
  }

  /// 异步检查目录内是否有 .exe 文件。无 exe 时显示红色错误阻断确认。
  /// 仅作 UI 提示，service 层 relinkGameLocation 仍以"目录存在"为准（detector 兜底）。
  Future<void> _checkExeExists(String dirPath) async {
    setState(() => _isCheckingExe = true);
    try {
      bool hasExe = false;
      final dir = Directory(dirPath);
      // 非递归扫描顶层 + 一级子目录（控制扫描成本）
      await for (final entity in dir.list(recursive: false, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
          hasExe = true;
          break;
        }
      }
      if (!hasExe) {
        // 顶层没有，再扫一级子目录
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
          if (entity is Directory) {
            try {
              await for (final sub in entity.list(recursive: false, followLinks: false)) {
                if (sub is File && sub.path.toLowerCase().endsWith('.exe')) {
                  hasExe = true;
                  break;
                }
              }
            } catch (_) {}
            if (hasExe) break;
          }
        }
      }

      if (mounted) {
        setState(() {
          if (!hasExe) {
            _pathError = '所选目录未找到任何 .exe 文件，请确认选的是游戏文件夹本身（不是它的上一级）';
          }
        });
      }
    } catch (e) {
      debugPrint('[RELINK-DIALOG] 检查 .exe 失败: $e');
    } finally {
      if (mounted) setState(() => _isCheckingExe = false);
    }
  }

  void _confirmRelink() async {
    if (_newLocation == null ||
        _newLocation == widget.currentLocation ||
        _pathError != null ||
        _isProcessing) return;

    setState(() => _isProcessing = true);

    // relink 返回值是用户选的目录本身（不拼 title）
    Navigator.of(context).pop(_newLocation);
  }
}

/// 目录行下拉菜单：更换游戏目录 / 移动游戏位置。
/// 视觉规范参考 LibraryContextMenu：2px border + 硬边阴影 + 全屏点外关闭。
/// 坐标由调用方 [_showDirectoryActionMenu] 算好（含边界检测）后传入。
class _DirectoryActionMenu extends StatelessWidget {
  final double left;
  final double top;
  final VoidCallback onRelink;
  final VoidCallback onMove;
  final VoidCallback onClose;

  const _DirectoryActionMenu({
    required this.left,
    required this.top,
    required this.onRelink,
    required this.onMove,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 全屏透明层：点外部关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 180,
              decoration: BoxDecoration(
                // v3.9 Aurora：白卡面 + e3 浮层阴影 + 发丝边 + 大圆角
                border: AppStyle.isModern
                    ? Border.all(
                        color: AppColors.borderLight,
                        width: AppStyle.wHairline)
                    : Border.all(color: AppColors.border, width: 2),
                boxShadow: AppStyle.isModern
                    ? AppStyle.e3
                    : [
                        BoxShadow(
                          color: AppColors.border.withOpacity(0.13),
                          offset: const Offset(4, 5),
                          blurRadius: 0,
                        ),
                      ],
                color: AppStyle.isModern
                    ? AppColors.buttonBackground
                    : AppColors.background,
                borderRadius: AppStyle.isModern
                    ? BorderRadius.circular(AppStyle.rMd)
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuItem(
                    icon: Icons.link_rounded,
                    label: '更换游戏目录',
                    onTap: onRelink,
                    iconColor: AppColors.titleBrown,
                  ),
                  _buildMenuItem(
                    icon: Icons.drive_file_move_rounded,
                    label: '移动游戏位置',
                    onTap: onMove,
                    iconColor: AppColors.brandBlue,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color iconColor,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
