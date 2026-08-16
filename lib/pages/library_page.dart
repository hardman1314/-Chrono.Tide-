import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_size_text/auto_size_text.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../theme/app_spacing.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/game_launch_service.dart';
import '../widgets/library_context_menu.dart';
import '../widgets/game_detail_dialog.dart';
import '../widgets/exe_selector_dialog.dart';
import '../widgets/save_backup_dialog.dart';
import '../services/manifest_service.dart';
import '../utils/game_config_manager.dart';
import '../services/shortcut_service.dart';
import '../widgets/launch_manager_dialog.dart';
import '../widgets/app_snack_bar.dart';
// UX-13: 拆分至独立组件文件
import '../widgets/library/panel_hover_builder.dart';
import '../widgets/library/library_ghost_card.dart';
import '../widgets/library/library_drag_overlay.dart';
import '../widgets/library/edit_mode_context_menu.dart';
import '../widgets/library/batch_shortcut_dialog.dart';

enum _DragMode { swap, insertBefore, insertAfter }

class LibraryPage extends StatefulWidget {
  final VoidCallback onGoDiscover;
  final ValueChanged<String>? onLaunchGame;
  final ValueChanged<String>? onToggleMark;
  final ValueChanged<String>? onDelete;
  final void Function(List<String> gameTitles, bool deleteLocalFiles)?
      onDeleteBatch;
  final VoidCallback? onRefresh;

  const LibraryPage({
    super.key,
    required this.onGoDiscover,
    this.onLaunchGame,
    this.onToggleMark,
    this.onDelete,
    this.onDeleteBatch,
    this.onRefresh,
  });

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with TickerProviderStateMixin {
  static const String _kGameOrderKey = 'library_game_order';

  OverlayEntry? _contextMenuOverlay;
  OverlayEntry? _dragOverlay;
  int? _originalIndex;
  Offset _dragPosition = Offset.zero;
  int _hoverIndex = -1;

  /// BUG-08: 记录当前 hover 目标的起始时间，用于停留确认（≥200ms 才执行交换）
  DateTime? _hoverStartTime;

  /// BUG-07: 防止全局 Listener 和卡片 Listener 双重调用 _endDrag/_cancelDrag
  bool _isEndingDrag = false;
  bool _goDiscoverHovered = false;
  List<LibraryGame> _games = [];
  // UX-18: 磁盘扫描期间显示加载指示器，避免空白
  bool _isScanning = false;
  Timer? _longPressTimer;
  static const Duration _dragDelay = Duration(milliseconds: 300);
  Offset _dragAnchor = Offset.zero;
  final GlobalKey _gridKey = GlobalKey();
  Rect? _gridBounds;
  late final AnimationController _liftAnimation;
  final Map<String, String> _localeModes = {};
  final Map<String, String> _upscalingModes = {};

  // --- 新增：双模式拖拽相关字段 ---
  _DragMode _dragMode = _DragMode.swap;
  int _insertIndex = -1;
  final List<GlobalKey> _cardKeys = [];
  Size? _cachedCardSize;
  Map<int, Rect> _cachedCardRects = {};
  late final AnimationController _insertPreviewAnim;
  late final CurvedAnimation _insertPreviewCurve;
  Map<int, Offset> _insertPreviewOffsets = {};
  Timer? _insertDelayTimer;
  int _pendingInsertIndex = -1;
  _DragMode _pendingInsertMode = _DragMode.swap;

  // --- 滚动支持 ---
  final ScrollController _scrollController = ScrollController();
  Timer? _autoScrollTimer;
  double _lastRecacheScrollOffset = 0;

  // --- 编辑模式 ---
  bool _isEditMode = false;
  final Set<String> _selectedGamePaths = {}; // 用 directoryPath 标识选中项
  OverlayEntry? _managementPanel;

  // --- 排序/筛选/布局 ---
  String _activeSort =
      ''; // 空=手动, 'recently_added', 'recently_played', 'play_time', 'play_status', 'marked_first'
  String _activeDeveloperFilter = ''; // 空=全部
  String _searchQuery = '';
  double _cardMaxExtent = 240; // 卡片最大宽度
  static const List<double> _layoutPresets = [160, 240, 340]; // 紧凑/舒适/宽松

  // --- UX-34: 封面路径异步预缓存，消除 build/initState 中的同步 I/O ---
  final Map<String, String?> _coverPathCache = {};

  // --- UX-34: 过滤排序结果缓存，避免每次 build 重复计算 O(n)+O(n log n) ---
  List<LibraryGame> _cachedFilteredGames = const [];
  int _filteredGamesHash = 0;

  // --- UX-34: 拖拽期间延迟注册表更新 ---
  bool _pendingRegistryUpdate = false;

  // --- 飞行动画（插入重排时卡片飞到目标位置） ---
  late final AnimationController _flyAnimation;
  Offset _flyFrom = Offset.zero;
  Offset _flyTo = Offset.zero;
  bool _isFlying = false;

  /// ★ H11: UI 层双重启动保护标志
  /// 防止用户快速双击导致多次调用 resolveUserChoice（异步）期间产生重复请求，
  /// 与 GameLaunchService._isLaunching 互为防御纵深：
  /// - UI 层拦截：避免 resolveUserChoice 重复执行 + 避免重复弹 SnackBar
  /// - Service 层拦截：作为最终保险，跨页面/跨模式也生效
  bool _isLaunching = false;

  bool get _isDragging => _originalIndex != null;

  List<LibraryGame> get _filteredAndSortedGames {
    // UX-34: 基于输入哈希缓存结果，避免每次 build 重复计算 O(n)+O(n log n)
    final hash = Object.hash(
      _games.length,
      _activeSort,
      _activeDeveloperFilter,
      _searchQuery,
      // 手动排序模式下，_games 引用变化即需重算
      _activeSort.isEmpty ? _gamesIdentity : 0,
    );
    if (hash != _filteredGamesHash) {
      _filteredGamesHash = hash;
      _cachedFilteredGames = _computeFilteredAndSortedGames();
    }
    return _cachedFilteredGames;
  }

  /// UX-34: _games 列表身份标识（手动排序时用于检测列表变化）
  int _gamesIdentity = 0;

  List<LibraryGame> _computeFilteredAndSortedGames() {
    var result = List<LibraryGame>.from(_games);

    // 搜索过滤
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result
          .where((g) =>
              g.title.toLowerCase().contains(q) ||
              g.developer.toLowerCase().contains(q))
          .toList();
    }

    // 会社筛选
    if (_activeDeveloperFilter.isNotEmpty) {
      if (_activeDeveloperFilter == '__none__') {
        result = result.where((g) => g.developer.isEmpty).toList();
      } else {
        result =
            result.where((g) => g.developer == _activeDeveloperFilter).toList();
      }
    }

    // 排序
    switch (_activeSort) {
      case 'recently_added':
        result.sort((a, b) => b.installedAt.compareTo(a.installedAt));
        break;
      case 'recently_played':
        result.sort((a, b) => b.playTime.compareTo(a.playTime));
        break;
      case 'play_time':
        result.sort((a, b) => b.playTime.compareTo(a.playTime));
        break;
      case 'play_status':
        const order = [
          PlayStatus.inProgress,
          PlayStatus.notStarted,
          PlayStatus.dropped,
          PlayStatus.completed
        ];
        result.sort((a, b) =>
            order.indexOf(a.playStatus).compareTo(order.indexOf(b.playStatus)));
        break;
      case 'marked_first':
        result.sort((a, b) {
          final aMarked = a.mark != GameMark.none ? 0 : 1;
          final bMarked = b.mark != GameMark.none ? 0 : 1;
          return aMarked.compareTo(bMarked);
        });
        break;
    }

    return result;
  }

  Set<String> get _allDevelopers {
    final devs =
        _games.map((g) => g.developer).where((d) => d.isNotEmpty).toSet();
    return devs;
  }

  void _toggleEditMode() {
    setState(() {
      _isEditMode = !_isEditMode;
      if (!_isEditMode) {
        _selectedGamePaths.clear();
        _dismissManagementPanel();
      }
    });
  }

  void _toggleCardSelection(LibraryGame game) {
    setState(() {
      if (_selectedGamePaths.contains(game.directoryPath)) {
        _selectedGamePaths.remove(game.directoryPath);
      } else {
        _selectedGamePaths.add(game.directoryPath);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedGamePaths.clear();
      _selectedGamePaths
          .addAll(_filteredAndSortedGames.map((g) => g.directoryPath));
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedGamePaths.clear();
    });
  }

  void _showManagementPanelAt(RenderBox buttonBox) {
    _dismissManagementPanel();

    final buttonPos = buttonBox.localToGlobal(Offset.zero);
    final buttonSize = buttonBox.size;

    _managementPanel = OverlayEntry(
      builder: (_) => _ManagementPanelWidget(
        position:
            Offset(buttonPos.dx - 260, buttonPos.dy + buttonSize.height + 8),
        searchQuery: _searchQuery,
        activeSort: _activeSort,
        activeDeveloperFilter: _activeDeveloperFilter,
        cardMaxExtent: _cardMaxExtent,
        developers: _allDevelopers.toList()..sort(),
        onSearchChanged: (q) {
          setState(() => _searchQuery = q);
          _savePanelSetting(_kSearchKey, q);
          _managementPanel?.markNeedsBuild();
        },
        onSortChanged: (s) {
          final newSort = _activeSort == s ? '' : s;
          setState(() => _activeSort = newSort);
          _savePanelSetting(_kSortKey, newSort);
          _managementPanel?.markNeedsBuild();
        },
        onDeveloperFilterChanged: (d) {
          final newFilter = _activeDeveloperFilter == d ? '' : d;
          setState(() => _activeDeveloperFilter = newFilter);
          _savePanelSetting(_kDevFilterKey, newFilter);
          _managementPanel?.markNeedsBuild();
        },
        onLayoutChanged: (v) {
          setState(() => _cardMaxExtent = v);
          _savePanelSetting(_kLayoutKey, v);
          _managementPanel?.markNeedsBuild();
        },
        onClose: _dismissManagementPanel,
      ),
    );
    Overlay.of(context).insert(_managementPanel!);
  }

  void _dismissManagementPanel() {
    _managementPanel?.remove();
    _managementPanel = null;
  }

  void _showEditModeContextMenu(
      BuildContext context, LibraryGame game, Offset position) {
    _dismissContextMenu();

    final hasSelection = _selectedGamePaths.isNotEmpty;
    final selectedGames = _games
        .where((g) => _selectedGamePaths.contains(g.directoryPath))
        .toList();

    _contextMenuOverlay = OverlayEntry(
      builder: (_) => EditModeContextMenu(
        position: position,
        hasSelection: hasSelection,
        onMark: hasSelection
            ? () {
                _dismissContextMenu();
                for (final g in selectedGames) {
                  widget.onToggleMark?.call(g.title);
                }
                setState(() {});
              }
            : null,
        onBlur: hasSelection
            ? () {
                _dismissContextMenu();
                for (final g in selectedGames) {
                  GameDataFormat.setBlurred(g.pathForCover, !g.isBlurred);
                  g.isBlurred = !g.isBlurred;
                }
                setState(() {});
              }
            : null,
        onPlayStatus: hasSelection
            ? () {
                _dismissContextMenu();
                _showPlayStatusMenu(context, selectedGames);
              }
            : null,
        onDelete: hasSelection
            ? () {
                _dismissContextMenu();
                _showBatchDeleteConfirm(selectedGames);
              }
            : null,
        onClose: _dismissContextMenu,
      ),
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  void _showBatchDeleteConfirm(List<LibraryGame> games) {
    bool deleteLocalFiles = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 1.5),
          ),
          title: Text(
            '确认删除',
            style: AppStyles.headlineSmall.copyWith(letterSpacing: 1.5),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '确定要将选中的 ${games.length} 个游戏从库中移除吗？',
                style: AppStyles.dialogBody.copyWith(height: 1.6),
              ),
              const SizedBox(height: AppSpacing.xs + 2),
              Text(
                deleteLocalFiles
                    ? '⚠ 已勾选：将同时删除本地所有游戏文件，不可恢复。'
                    : '默认仅从库中移除记录，本地游戏文件保留不变。',
                style: AppStyles.hintRegular.copyWith(
                  color: deleteLocalFiles
                      ? AppColors.dangerRed
                      : AppColors.primaryText,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: AppSpacing.md + 2),
              GestureDetector(
                onTap: () {
                  setDialogState(() {
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
                    const SizedBox(width: AppSpacing.sm + 2),
                    Flexible(
                      child: Text(
                        '同时删除本地游戏文件',
                        style: AppStyles.bodyMedium,
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
                style: AppStyles.labelLarge.copyWith(color: AppColors.infoBlue),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop('confirm');
              },
              child: Text(
                '确认删除',
                style:
                    AppStyles.labelLarge.copyWith(color: AppColors.dangerRed),
              ),
            ),
          ],
        ),
      ),
    ).then((result) async {
      if (result == null || result != 'confirm') return;

      final gameTitles = games.map((g) => g.title).toList();
      widget.onDeleteBatch?.call(gameTitles, deleteLocalFiles);

      _selectedGamePaths.clear();
      setState(() {});
    });
  }

  void _showPlayStatusMenu(BuildContext context, List<LibraryGame> games) {
    final statuses = PlayStatus.values;

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('设置游玩状态'),
        children: statuses
            .map((s) => SimpleDialogOption(
                  onPressed: () {
                    Navigator.pop(ctx);
                    for (final g in games) {
                      GameDataFormat.setPlayStatus(g.pathForCover, s.jsonKey);
                      g.playStatus = s;
                    }
                    setState(() {});
                  },
                  child: Row(children: [
                    Icon(s.icon, color: s.color, size: 20),
                    SizedBox(width: 12),
                    Text(s.label),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  /// 计算被拖动卡片的中心点（屏幕坐标）
  /// 用作位置判定的定位点，比鼠标位置更精准、更跟手
  Offset _cardCenter() {
    final w = _cachedCardSize?.width ?? 0;
    final h = _cachedCardSize?.height ?? 0;
    return Offset(
      _dragPosition.dx - _dragAnchor.dx + w / 2,
      _dragPosition.dy - _dragAnchor.dy + h / 2,
    );
  }

  @override
  void initState() {
    super.initState();
    _liftAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0.0,
    );
    _insertPreviewAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0.0,
    );
    _insertPreviewCurve = CurvedAnimation(
      parent: _insertPreviewAnim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _flyAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 0.0,
    );
    _flyAnimation.addListener(_onFlyUpdate);
    _loadPanelSettings();
    _refreshFromDisk();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
    ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
    _scrollController.addListener(_onScrollChanged);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isDragging) {
        _cancelDrag();
        return true;
      }
    }
    return false;
  }

  // --- 管理面板设置持久化 ---
  static const String _kSortKey = 'library_panel_sort';
  static const String _kDevFilterKey = 'library_panel_dev_filter';
  static const String _kSearchKey = 'library_panel_search';
  static const String _kLayoutKey = 'library_panel_layout';

  Future<void> _loadPanelSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _activeSort = prefs.getString(_kSortKey) ?? '';
      _activeDeveloperFilter = prefs.getString(_kDevFilterKey) ?? '';
      _searchQuery = prefs.getString(_kSearchKey) ?? '';
      _cardMaxExtent = prefs.getDouble(_kLayoutKey) ?? 240;
    });
  }

  Future<void> _savePanelSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    }
  }

  Future<void> _refreshFromDisk() async {
    // UX-18: 首次扫描（库为空）时显示加载指示器，避免空白
    final wasEmpty = _games.isEmpty;
    if (wasEmpty) setState(() => _isScanning = true);
    try {
      await LocalGameRegistry.instance.scan();
      _loadGames();
    } finally {
      if (wasEmpty && mounted) setState(() => _isScanning = false);
    }
  }

  /// 静默刷新：从磁盘重新读取数据并更新 UI，不重建整个页面
  /// 用于详情页修改后自动同步库页显示（游玩状态、标题、会社等）
  Future<void> _silentRefresh() async {
    await LocalGameRegistry.instance.scan();
    final games = LocalGameRegistry.instance.allGames;
    // UX-34: 静默刷新时清空封面缓存，重新解析（封面可能已变更）
    _coverPathCache.clear();
    await _applyCustomOrder(games);
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshFromDisk();
  }

  /// 当 LocalGameRegistry 数据变化时（如游玩时长实时更新），刷新UI
  void _onRegistryChanged() {
    if (!mounted) return;
    // UX-34: 拖拽期间延迟注册表更新，避免干扰交互
    if (_isDragging) {
      _pendingRegistryUpdate = true;
      return;
    }
    // UX-34: 区分通知类型——结构性变化需重新加载，游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      _loadGames();
    } else {
      // playTimeUpdate：游戏对象引用已被原地修改，仅需 setState 让 UI 反映新值
      setState(() {});
    }
  }

  /// UX-34: 异步预缓存所有封面路径，消除卡片 build/initState 中的同步 I/O
  Future<void> _resolveAllCoverPaths() async {
    for (final game in _games) {
      if (_coverPathCache.containsKey(game.directoryPath)) continue;
      String? resolved;
      if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
        resolved = game.coverUrl;
      } else {
        try {
          resolved = GameDataFormat.findCoverFile(game.pathForCover)?.path;
        } catch (_) {}
      }
      _coverPathCache[game.directoryPath] = resolved;
    }
    if (mounted) setState(() {});
  }

  void _loadGames() {
    final games = LocalGameRegistry.instance.allGames;
    _applyCustomOrder(games);
  }

  Future<void> _loadLaunchModes() async {
    for (final game in _games) {
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null) {
          if (data.localeMode.isNotEmpty) {
            _localeModes[game.title] = data.localeMode;
          }
          if (data.upscalingMode.isNotEmpty) {
            _upscalingModes[game.title] = data.upscalingMode;
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _applyCustomOrder(List<LibraryGame> games) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrder = prefs.getStringList(_kGameOrderKey);

      if (savedOrder != null && savedOrder.isNotEmpty) {
        final orderMap = <String, int>{};
        for (var i = 0; i < savedOrder.length; i++) {
          orderMap[savedOrder[i]] = i;
        }

        final orderedGames = List<LibraryGame>.from(games);
        orderedGames.sort((a, b) {
          final indexA = orderMap[a.directoryPath] ?? -1;
          final indexB = orderMap[b.directoryPath] ?? -1;
          return indexA.compareTo(indexB);
        });

        setState(() {
          _games = orderedGames;
          _gamesIdentity++; // UX-34: 手动排序缓存失效
          _syncCardKeys();
        });
        debugPrint('[LIBRARY] ✅ 已应用自定义排序 (${orderedGames.length}个)');
        _loadLaunchModes();
        _resolveAllCoverPaths(); // UX-34: 异步预缓存封面路径
      } else {
        setState(() {
          _games = games;
          _gamesIdentity++; // UX-34: 手动排序缓存失效
          _syncCardKeys();
        });
        _loadLaunchModes();
        _resolveAllCoverPaths(); // UX-34: 异步预缓存封面路径
      }
    } catch (e) {
      debugPrint('[LIBRARY] ⚠️ 应用自定义排序失败: $e');
      setState(() {
        _games = games;
        _gamesIdentity++; // UX-34: 手动排序缓存失效
        _syncCardKeys();
      });
    }
  }

  /// 保持 _cardKeys 列表与 _games 长度同步
  void _syncCardKeys() {
    while (_cardKeys.length < _games.length) {
      _cardKeys.add(GlobalKey());
    }
    if (_cardKeys.length > _games.length) {
      _cardKeys.removeRange(_games.length, _cardKeys.length);
    }
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isDragging) {
      _loadGames();
    }
  }

  @override
  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
    _scrollController.removeListener(_onScrollChanged);
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _autoScrollTimer?.cancel();
    _contextMenuOverlay?.remove();
    _dragOverlay?.remove();
    _managementPanel?.remove();
    _liftAnimation.dispose();
    _insertPreviewCurve.dispose();
    _insertPreviewAnim.dispose();
    _flyAnimation.removeListener(_onFlyUpdate);
    _flyAnimation.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _showContextMenu(
      BuildContext context, LibraryGame game, Offset position) {
    _dismissContextMenu();
    _contextMenuOverlay = OverlayEntry(
      builder: (_) => LibraryContextMenu(
        position: position,
        onDetails: () {
          debugPrint('[LIBRARY] 右键查看详情: ${game.title}');
          _dismissContextMenu();
          GameDetailDialog.show(
            context: context,
            directoryPath: game.pathForCover,
            onLaunchGame: () => _handleDoubleTap(game),
            initialLocaleMode: _localeModes[game.title] ?? 'none',
            initialUpscalingMode: _upscalingModes[game.title] ?? 'none',
            onLocaleModeChanged: (mode) {
              _localeModes[game.title] = mode;
            },
            onUpscalingModeChanged: (mode) {
              _upscalingModes[game.title] = mode;
            },
          ).then((_) => _silentRefresh());
        },
        onLaunchManager: () {
          debugPrint('[LIBRARY] 右键启动管理: ${game.title}');
          _dismissContextMenu();
          _showLaunchManager(game);
        },
        onMark: () {
          debugPrint('[LIBRARY] 右键标记切换: ${game.title}');
          widget.onToggleMark?.call(game.title);
          _dismissContextMenu();
          setState(() {});
        },
        onBackup: () {
          debugPrint('[LIBRARY] 右键存档备份: ${game.title}');
          _dismissContextMenu();
          SaveBackupDialog.show(
            context,
            gameName: game.title,
            installDir: game.directoryPath,
            manifestEntry: ManifestService.instance.lookup(game.title),
          );
        },
        onDelete: () {
          _dismissContextMenu();
          widget.onDelete?.call(game.title);
        },
        onClose: _dismissContextMenu,
      ),
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  void _dismissContextMenu() {
    _contextMenuOverlay?.remove();
    _contextMenuOverlay = null;
  }

  void _startDrag(int index, Offset localPos, Offset globalPos) {
    // UX-16: 强制清理上一次未完成的 cancel 动画，避免状态竞态
    // 若 _cancelDrag 的 reverse 动画尚未结束，_dragOverlay 仍存在，
    // 会导致新拖拽无法创建 overlay（_showDragOverlay 会提前 return）。
    if (_dragOverlay != null) {
      _liftAnimation.stop();
      _insertPreviewAnim.stop();
      _removeDragOverlay();
      _originalIndex = null;
      _hoverIndex = -1;
      _hoverStartTime = null;
      _insertIndex = -1;
      _dragMode = _DragMode.swap;
      _gridBounds = null;
      _cachedCardSize = null;
      _cachedCardRects = {};
      _insertPreviewOffsets = {};
      _isEndingDrag = false;
    }

    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _gridBounds = box.paintBounds.shift(box.localToGlobal(Offset.zero));

    // 缓存实际卡片尺寸（不含 padding）
    final dragCardKey = _cardKeys[index];
    final dragCardBox =
        dragCardKey.currentContext?.findRenderObject() as RenderBox?;
    if (dragCardBox != null) {
      _cachedCardSize = dragCardBox.size;
    }

    // 缓存所有卡片位置，向内收缩 8px 排除 padding 缓冲区
    _lastRecacheScrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0;
    _recacheCardRects();

    setState(() {
      _originalIndex = index;
      _hoverIndex = -1;
      _hoverStartTime = null; // BUG-08: 初始化停留时间
      _isEndingDrag = false; // BUG-07: 初始化防重入标志
      _dragAnchor = localPos;
      _dragPosition = globalPos;
      _dragMode = _DragMode.swap;
      _insertIndex = -1;
    });

    _showDragOverlay();
    _liftAnimation.forward(from: 0);
    _startAutoScroll();

    // UX-16: 拖拽开始时显示轻量提示，告知用户可拖回原位或按 ESC 取消
    AppSnackBar.info(
      context,
      '拖回原位取消 · ESC 退出',
      duration: const Duration(seconds: 1, milliseconds: 800),
    );
  }

  void _showDragOverlay() {
    if (_dragOverlay != null) return;
    if (_originalIndex == null || _originalIndex! >= _games.length) return;

    final game = _games[_originalIndex!];

    _dragOverlay = OverlayEntry(
      builder: (context) => LibraryDragOverlay(
        game: game,
        dragPosition: _dragPosition,
        dragAnchor: _dragAnchor,
        liftAnimation: _liftAnimation,
        isMarked: game.mark != GameMark.none,
        cardSize: _cachedCardSize,
        coverPath: _coverPathCache[game.directoryPath], // UX-34
      ),
    );

    Overlay.of(context).insert(_dragOverlay!);
  }

  void _updateDragOverlay() {
    _dragOverlay?.markNeedsBuild();
  }

  void _removeDragOverlay() {
    _dragOverlay?.remove();
    _dragOverlay = null;
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  /// UX-16: 拖拽插入位置的垂直指示线
  /// 在目标卡片左/右边缘显示一条蓝色高亮线，明确告知用户即将插入到此位置
  Positioned _buildInsertIndicator({required bool isBefore}) {
    return Positioned(
      left: isBefore ? -3 : null,
      right: isBefore ? null : -3,
      top: 0,
      bottom: 0,
      child: Container(
        width: 4,
        decoration: BoxDecoration(
          color: AppColors.selectedAccent,
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(
              color: AppColors.selectedAccent.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }

  /// 滚动位置变化时的回调
  /// 拖拽期间手动滚动（鼠标滚轮）或自动滚动都会触发
  /// 重新缓存卡片位置并更新悬停目标
  void _onScrollChanged() {
    if (!_isDragging) return;
    _recacheCardRects();
    _updateHoverIndex(_cardCenter());
  }

  /// 重新缓存所有卡片的屏幕位置
  /// 可见卡片：从 RenderObject 获取精确位置
  /// 离屏卡片：保留上次位置并按滚动偏移修正，确保插入预览计算不会因原位置不可视而失效
  void _recacheCardRects() {
    final double currentScrollOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    final double scrollDelta = currentScrollOffset - _lastRecacheScrollOffset;
    _lastRecacheScrollOffset = currentScrollOffset;

    final newRects = <int, Rect>{};
    for (int i = 0; i < _games.length; i++) {
      final key = _cardKeys[i];
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        // 可见卡片：使用 RenderObject 的精确屏幕位置
        newRects[i] =
            renderBox.paintBounds.shift(renderBox.localToGlobal(Offset.zero));
      } else if (_cachedCardRects.containsKey(i)) {
        // 离屏卡片：按滚动偏移修正上次已知位置
        // GridView 向下滚动时（offset 增大），卡片在屏幕上向上移动
        newRects[i] = _cachedCardRects[i]!.shift(Offset(0, -scrollDelta));
      }
    }
    _cachedCardRects = newRects;
  }

  /// 拖拽期间自动滚动：鼠标靠近 GridView 上下边缘时自动滚动
  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_isDragging || !_scrollController.hasClients) {
        _autoScrollTimer?.cancel();
        return;
      }
      if (_gridBounds == null) return;

      final mouseY = _dragPosition.dy;
      final gridTop = _gridBounds!.top;
      final gridBottom = _gridBounds!.bottom;
      const edgeSize = 60.0; // 边缘触发区域大小
      const maxSpeed = 12.0; // 最大滚动速度（px/50ms）

      double scrollDelta = 0;
      if (mouseY < gridTop + edgeSize && mouseY >= gridTop) {
        // 靠近上边缘，向上滚动
        final factor = 1.0 - (mouseY - gridTop) / edgeSize;
        scrollDelta = -maxSpeed * factor;
      } else if (mouseY > gridBottom - edgeSize && mouseY <= gridBottom) {
        // 靠近下边缘，向下滚动
        final factor = 1.0 - (gridBottom - mouseY) / edgeSize;
        scrollDelta = maxSpeed * factor;
      }

      if (scrollDelta != 0) {
        final newOffset = (_scrollController.offset + scrollDelta)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.jumpTo(newOffset);
        // 滚动监听器 _onScrollChanged 会自动处理缓存更新和悬停检测
      }
    });
  }

  void _updateDrag(Offset globalPos) {
    if (_gridBounds == null || _originalIndex == null) return;

    setState(() {
      _dragPosition = globalPos;
    });
    _updateDragOverlay();

    // 使用卡片中心点作为判定点，而非鼠标位置
    // 这样无论用户从卡片哪个位置按下，判定都跟手
    _updateHoverIndex(_cardCenter());
  }

  /// 使用缓存的卡片位置进行悬停检测
  /// 判定点为被拖动卡片的中心点（由调用方传入）
  /// 基于判定点在目标卡片内的水平位置区分交换/插入模式：
  /// - 左 15% → 插入到该卡片前面（需停留 300ms）
  /// - 右 15% → 插入到该卡片后面（需停留 300ms）
  /// - 中间 70% → 交换（立即触发）
  /// 如果判定点不在任何卡片内，则回退到距离最近的卡片（默认交换模式）
  void _updateHoverIndex(Offset point) {
    if (_originalIndex == null) return;

    int foundIndex = -1;
    _DragMode foundMode = _DragMode.swap;

    // BUG-08: 检测是否拖回原位 → 视为取消操作
    final origRect = _cachedCardRects[_originalIndex!];
    if (origRect != null && origRect.contains(point)) {
      // 拖回原位 → 标记为取消
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;
      if (_hoverIndex != _originalIndex || _dragMode != _DragMode.swap) {
        setState(() {
          _hoverIndex = _originalIndex!;
          _dragMode = _DragMode.swap;
          _insertIndex = -1;
          _hoverStartTime = DateTime.now();
        });
        _insertPreviewAnim.reverse();
      }
      return; // 拖回原位时不继续检测其他卡片
    }

    // 第一轮：检测判定点是否在某张卡片内部
    for (int i = 0; i < _games.length; i++) {
      if (i == _originalIndex) continue;

      final boxRect = _cachedCardRects[i];
      if (boxRect == null) continue;

      if (boxRect.contains(point)) {
        foundIndex = i;

        // 根据判定点在卡片内的水平位置判断模式
        final relativeX = (point.dx - boxRect.left) / boxRect.width;
        if (relativeX < 0.15) {
          foundMode = _DragMode.insertBefore;
        } else if (relativeX > 0.85) {
          foundMode = _DragMode.insertAfter;
        } else {
          foundMode = _DragMode.swap;
        }
        break;
      }
    }

    // 第二轮：判定点不在任何卡片内时，回退到距离最近的卡片
    // 这解决了卡片间距导致的"空隙"问题，确保判定始终精准
    if (foundIndex == -1 &&
        _gridBounds != null &&
        _gridBounds!.contains(point)) {
      double minDist = double.infinity;
      for (int i = 0; i < _games.length; i++) {
        if (i == _originalIndex) continue;

        final boxRect = _cachedCardRects[i];
        if (boxRect == null) continue;

        final dist = (point - boxRect.center).distance;
        if (dist < minDist) {
          minDist = dist;
          foundIndex = i;
          foundMode = _DragMode.swap; // 回退时默认交换模式
        }
      }
    }

    if (foundIndex != -1) {
      if (foundMode == _DragMode.swap) {
        // 交换模式：立即触发，取消插入延迟计时器
        _insertDelayTimer?.cancel();
        _insertDelayTimer = null;
        _pendingInsertIndex = -1;

        final needUpdate =
            _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
        if (needUpdate) {
          setState(() {
            _hoverIndex = foundIndex;
            _dragMode = _DragMode.swap;
            _insertIndex = -1;
            _hoverStartTime = DateTime.now(); // BUG-08: 记录停留起始时间
          });
          _insertPreviewAnim.reverse();
        }
      } else {
        // 插入模式：需要停留 300ms 才触发
        final pendingInsertIdx =
            foundMode == _DragMode.insertBefore ? foundIndex : foundIndex + 1;

        // 如果鼠标在同一张卡片的同一边缘区域移动，保持计时器
        if (_pendingInsertIndex != pendingInsertIdx ||
            _pendingInsertMode != foundMode) {
          // 切换了目标或模式，重新开始计时
          _insertDelayTimer?.cancel();

          // 先切换到交换模式作为过渡（立即反馈）
          final needUpdate =
              _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
          if (needUpdate) {
            setState(() {
              _hoverIndex = foundIndex;
              _dragMode = _DragMode.swap;
              _insertIndex = -1;
              _hoverStartTime = DateTime.now(); // BUG-08: 记录停留起始时间
            });
            _insertPreviewAnim.reverse();
          }

          _pendingInsertIndex = pendingInsertIdx;
          _pendingInsertMode = foundMode;

          _insertDelayTimer = Timer(const Duration(milliseconds: 300), () {
            if (!_isDragging) return;
            // 停留足够时间，激活插入模式
            // 先设置 _insertIndex，再计算偏移（_calculateInsertOffsets 依赖 _insertIndex）
            setState(() {
              _dragMode = foundMode;
              _insertIndex = pendingInsertIdx;
            });
            _insertPreviewOffsets = _calculateInsertOffsets();
            _insertPreviewAnim.forward();
          });
        }
        // 同一区域移动：不做任何变化，等待计时器
      }
    } else {
      // 鼠标不在任何卡片上
      _insertDelayTimer?.cancel();
      _insertDelayTimer = null;
      _pendingInsertIndex = -1;

      if (_hoverIndex != -1 || _insertIndex != -1) {
        setState(() {
          _hoverIndex = -1;
          _insertIndex = -1;
          _dragMode = _DragMode.swap;
          _hoverStartTime = null; // BUG-08: 重置停留时间
        });
        _insertPreviewAnim.reverse();
      }
    }
  }

  /// 计算插入重排后每个卡片的原始索引 → 预览索引映射
  Map<int, int> _calculatePreviewIndexMap() {
    if (_originalIndex == null || _insertIndex == -1) return {};

    final indexMap = <int, int>{};
    final origIdx = _originalIndex!;
    int targetIndex = _insertIndex;
    if (origIdx < targetIndex) targetIndex--;
    targetIndex = targetIndex.clamp(0, _games.length - 1);

    for (int i = 0; i < _games.length; i++) {
      if (i == origIdx) {
        indexMap[i] = targetIndex;
      } else if (origIdx < targetIndex) {
        // 向后插入：origIdx+1 到 targetIndex 的卡片前移一位
        if (i > origIdx && i <= targetIndex) {
          indexMap[i] = i - 1;
        } else {
          indexMap[i] = i;
        }
      } else {
        // 向前插入：targetIndex 到 origIdx-1 的卡片后移一位
        if (i >= targetIndex && i < origIdx) {
          indexMap[i] = i + 1;
        } else {
          indexMap[i] = i;
        }
      }
    }
    return indexMap;
  }

  /// 计算插入预览时每个卡片需要的像素偏移
  Map<int, Offset> _calculateInsertOffsets() {
    final indexMap = _calculatePreviewIndexMap();
    final offsets = <int, Offset>{};

    for (final entry in indexMap.entries) {
      final origIdx = entry.key;
      final previewIdx = entry.value;
      if (origIdx == previewIdx) continue;

      final fromRect = _cachedCardRects[origIdx];
      final toRect = _cachedCardRects[previewIdx];
      if (fromRect != null && toRect != null) {
        offsets[origIdx] = Offset(
          toRect.left - fromRect.left,
          toRect.top - fromRect.top,
        );
      }
    }
    return offsets;
  }

  void _endDrag() {
    // BUG-07: 防止全局 Listener 和卡片 Listener 双重调用
    if (_isEndingDrag) return;
    _isEndingDrag = true;

    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _autoScrollTimer?.cancel();
    _insertPreviewAnim.reverse();

    // BUG-08-1: 拖回原位或无目标 → 自动取消
    if (_hoverIndex == _originalIndex || _hoverIndex == -1) {
      _cancelDrag();
      return;
    }

    // BUG-08-2: 交换模式停留确认（≥200ms 才执行交换，快速滑过视为取消）
    if (_dragMode == _DragMode.swap) {
      final dwellTime = _hoverStartTime != null
          ? DateTime.now().difference(_hoverStartTime!)
          : Duration.zero;
      if (dwellTime < const Duration(milliseconds: 200)) {
        _cancelDrag();
        return;
      }
    }

    if (_dragMode == _DragMode.swap &&
        _originalIndex != null &&
        _hoverIndex != -1 &&
        _hoverIndex != _originalIndex) {
      // 模式 A：直接交换
      final reordered = List<LibraryGame>.from(_games);
      final temp = reordered[_originalIndex!];
      reordered[_originalIndex!] = reordered[_hoverIndex];
      reordered[_hoverIndex] = temp;
      _games = reordered;
      _gamesIdentity++; // UX-34: 手动排序缓存失效
      _saveGameOrder();
    } else if ((_dragMode == _DragMode.insertBefore ||
            _dragMode == _DragMode.insertAfter) &&
        _originalIndex != null &&
        _insertIndex != -1) {
      // 模式 B：插入重排
      final reordered = List<LibraryGame>.from(_games);
      final item = reordered.removeAt(_originalIndex!);
      int targetIndex = _insertIndex;
      if (_originalIndex! < targetIndex) {
        targetIndex--;
      }
      targetIndex = targetIndex.clamp(0, reordered.length);
      reordered.insert(targetIndex, item);
      _games = reordered;
      _gamesIdentity++; // UX-34: 手动排序缓存失效
      _saveGameOrder();

      // 插入重排：浮动卡片直接飞到目标位置，不回原位
      _animateOverlayToTarget(targetIndex);
      return; // 动画完成后会在回调中清理状态
    }

    // 交换模式或无效操作：浮动卡片回到原位
    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _hoverStartTime = null; // BUG-08: 清理停留时间
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
        _isEndingDrag = false; // BUG-07: 重置防重入标志
      });
      _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
    });
  }

  /// 飞行动画帧更新
  void _onFlyUpdate() {
    if (!_isFlying) return;
    final t = Curves.easeOutCubic.transform(_flyAnimation.value);
    _dragPosition = Offset.lerp(_flyFrom, _flyTo, t)!;
    _dragAnchor = Offset.zero;
    _updateDragOverlay();
  }

  /// 插入重排时：浮动卡片飞到目标位置
  void _animateOverlayToTarget(int targetIndex) {
    // 先 setState 更新网格（卡片已在目标位置），但浮动卡片仍显示
    setState(() {
      _hoverIndex = -1;
      _insertIndex = -1;
      _dragMode = _DragMode.swap;
      _insertPreviewOffsets = {};
    });

    // 等 build 完成后获取目标卡片的位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetKey = _cardKeys[targetIndex];
      final renderBox =
          targetKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize && _dragOverlay != null) {
        final targetPos = renderBox.localToGlobal(Offset.zero);

        // 启动飞行动画：从当前位置平滑飞到目标位置
        _flyFrom = _dragPosition - _dragAnchor;
        _flyTo = targetPos;
        _isFlying = true;
        _flyAnimation.forward(from: 0).then((_) {
          _isFlying = false;
          // 飞到目标后，缩小 + 淡出
          _liftAnimation.reverse().then((_) {
            _removeDragOverlay();
            setState(() {
              _originalIndex = null;
              _dragPosition = Offset.zero;
              _dragAnchor = Offset.zero;
              _gridBounds = null;
              _cachedCardSize = null;
              _cachedCardRects = {};
              _isEndingDrag = false; // BUG-07: 重置防重入标志
            });
            _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
          });
        });
      } else {
        // 无法获取目标位置，直接回原位
        _liftAnimation.reverse().then((_) {
          _removeDragOverlay();
          setState(() {
            _originalIndex = null;
            _dragPosition = Offset.zero;
            _dragAnchor = Offset.zero;
            _hoverIndex = -1;
            _hoverStartTime = null; // BUG-08: 清理停留时间
            _insertIndex = -1;
            _dragMode = _DragMode.swap;
            _gridBounds = null;
            _cachedCardSize = null;
            _cachedCardRects = {};
            _insertPreviewOffsets = {};
            _isEndingDrag = false; // BUG-07: 重置防重入标志
          });
          _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
        });
      }
    });
  }

  void _cancelDrag() {
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _autoScrollTimer?.cancel();
    _isFlying = false;
    _flyAnimation.stop();
    _insertPreviewAnim.reverse();
    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _hoverStartTime = null; // BUG-08: 清理停留时间
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
        _isEndingDrag = false; // BUG-07: 重置防重入标志
      });
      _processPendingRegistryUpdate(); // UX-34: 处理延迟的注册表更新
    });
  }

  /// UX-34: 拖拽结束后处理延迟的注册表更新
  void _processPendingRegistryUpdate() {
    if (_pendingRegistryUpdate) {
      _pendingRegistryUpdate = false;
      // 延迟到下一帧，避免与拖拽清理动画冲突
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onRegistryChanged();
      });
    }
  }

  Future<void> _saveGameOrder() async {
    try {
      final order = _games.map((g) => g.directoryPath).toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kGameOrderKey, order);
      debugPrint('[LIBRARY] ✅ 已保存游戏排序 (${order.length}个)');
    } catch (e) {
      debugPrint('[LIBRARY] ⚠️ 保存游戏排序失败: $e');
    }
  }

  void _handleDoubleTap(LibraryGame game) async {
    debugPrint('[LAUNCH] ========== 双击启动: ${game.title} ==========');

    // ★ H11: UI 层双重启动保护
    // resolveUserChoice 是异步操作，快速双击会导致两次 resolveUserChoice 并行执行，
    // 虽然最终都会被 GameLaunchService._isLaunching 拦截，但 UI 层提前拦截
    // 可避免重复执行磁盘 I/O 和重复弹 SnackBar，提升用户体验。
    if (_isLaunching) {
      debugPrint('[LAUNCH] ⏭️ UI 层拦截：上一次启动仍在进行中');
      return;
    }
    _isLaunching = true;
    try {
      final exePath =
          await GameLaunchService.instance.resolveUserChoice(game.title);

      if (exePath != null) {
        await _executeLaunch(game, exePath);
      } else {
        debugPrint('[LAUNCH] 无已保存的启动程序，弹出选择器');
        _showExeSelector(game);
      }
    } finally {
      _isLaunching = false;
    }
  }

  /// 转发到 [GameLaunchService.executeLaunch] 并处理 UI 反馈
  ///
  /// 保持原桌面模式行为: 启动成功 → setState 刷新卡片;失败 → SnackBar 提示。
  /// 同时同步更新 [_localeModes]/[_upscalingModes] 内存缓存。
  Future<void> _executeLaunch(LibraryGame game, String exePath) async {
    final result =
        await GameLaunchService.instance.executeLaunch(game, exePath);

    // 同步内存缓存 (供 ExeSelectorDialog 显示初始状态)
    _localeModes[game.title] = result.localeMode;
    _upscalingModes[game.title] = result.upscalingMode;

    if (!mounted) return;
    setState(() {}); // 同步卡片上的游玩状态显示

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.error ?? '无法启动「${game.title}」'),
          duration: const Duration(seconds: 3),
          backgroundColor: AppColors.dangerRed,
        ),
      );
    }
  }

  void _showExeSelector(LibraryGame game) {
    final currentLocale = _localeModes[game.title] ?? 'none';
    final currentUpscaling = _upscalingModes[game.title] ?? 'none';
    ExeSelectorDialog.show(
      context: context,
      gameDirectory: game.directoryPath,
      gameTitle: game.title,
      metaDataDir: game.metaDataDir,
      initialExePath: null,
      initialLocaleMode: currentLocale,
      initialUpscalingMode: currentUpscaling,
      onSelected: (selectedExe) async {
        await _executeLaunch(game, selectedExe);
      },
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'locale_mode': mode});
        }
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'upscaling_mode': mode});
        }
      },
    );
  }

  void _showLaunchManager(LibraryGame game) async {
    final currentPath =
        await GameConfigManager.instance.getLaunchPath(game.title);
    String? displayExe = currentPath;
    if (displayExe == null || displayExe.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        displayExe = prefs.getString('default_exe_${game.title}');
      } catch (_) {}
    }

    final currentLocale = _localeModes[game.title] ?? 'none';
    final currentUpscaling = _upscalingModes[game.title] ?? 'none';

    if (!mounted) return;

    await LaunchManagerDialog.show(
      context: context,
      gameTitle: game.title,
      gameDirectory: game.directoryPath,
      metaDataDir: game.metaDataDir,
      initialExePath: displayExe,
      initialLocaleMode: currentLocale,
      initialUpscalingMode: currentUpscaling,
      onExeSelected: (selectedExe) async {
        await GameLaunchService.instance
            .persistUserChoice(game.title, selectedExe);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已更新「${game.title}」的启动程序'),
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.infoBlue,
          ),
        );
      },
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'locale_mode': mode});
        }
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
        final gameData = LocalGameRegistry.instance.getGameByTitle(game.title);
        if (gameData != null) {
          GameDataFormat.updateGameJson(
              gameData.metaDataDir, {'upscaling_mode': mode});
        }
      },
    );

    if (mounted) _silentRefresh();
  }

  void _showBatchShortcutDialog([List<LibraryGame>? presetGames]) async {
    final games = presetGames ?? LocalGameRegistry.instance.allGames;
    final eligibleGames = games.where((g) => g.launchPath.isNotEmpty).toList();

    if (eligibleGames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有可生成快捷方式的游戏（需要先设置启动程序）'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // 预计算快捷方式状态
    final shortcutStatus = <String, bool>{};
    for (final game in eligibleGames) {
      shortcutStatus[game.title] =
          ShortcutService.instance.hasShortcut(game.title);
    }

    final selectedTitles = <String>{};
    for (final game in eligibleGames) {
      if (!shortcutStatus[game.title]!) {
        selectedTitles.add(game.title);
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => BatchShortcutDialog(
        games: eligibleGames,
        shortcutStatus: shortcutStatus,
        initialSelected: selectedTitles,
      ),
    );

    if (mounted) _silentRefresh();
  }

  @override
  Widget build(BuildContext context) {
    // BUG-07: 全局 Listener 捕获拖拽期间的指针事件
    // 解决拖拽开始后指针离开卡片区域导致事件丢失、拖拽卡死的问题
    return Listener(
      onPointerMove: _isDragging
          ? (event) {
              if (_isEndingDrag) return;
              _updateDrag(event.position);
            }
          : null,
      onPointerUp: _isDragging
          ? (event) {
              if (_isEndingDrag) return;
              _endDrag();
            }
          : null,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: AppColors.pageBackground,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        child: Stack(
          children: [
            _buildGameGrid(),
            // UX-18: 扫描期间显示加载遮罩，否则显示空状态遮罩
            if (_games.isEmpty)
              _isScanning ? _buildScanningOverlay() : _buildEmptyOverlay(),
            // 右上角管理按钮
            Positioned(
              top: 0,
              right: 0,
              child: _buildManageButton(),
            ),
            // 编辑模式底部操作栏
            if (_isEditMode && _selectedGamePaths.isNotEmpty)
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: _buildEditModeBar(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameGrid() {
    if (_games.isEmpty) return const SizedBox.shrink();

    final filteredGames = _filteredAndSortedGames;

    // 确保 _cardKeys 列表长度与 filteredGames 匹配
    while (_cardKeys.length < filteredGames.length) {
      _cardKeys.add(GlobalKey());
    }
    if (_cardKeys.length > filteredGames.length) {
      _cardKeys.removeRange(filteredGames.length, _cardKeys.length);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GridView.builder(
            key: _gridKey,
            controller: _scrollController,
            cacheExtent: 2000, // 性能优化: 增大预渲染区域，减少快速滑动时的白屏和卡片创建开销
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: _cardMaxExtent,
              mainAxisSpacing: 24,
              crossAxisSpacing: 24,
              childAspectRatio: 0.60,
            ),
            itemCount: filteredGames.length,
            itemBuilder: (context, index) {
              final game = filteredGames[index];
              final isOriginalSlot = _isDragging && _originalIndex == index;
              final isSwapTarget = _hoverIndex == index &&
                  _isDragging &&
                  _hoverIndex != _originalIndex &&
                  _dragMode == _DragMode.swap;
              final isInsertMode = _isDragging && _insertIndex != -1;

              // 计算该卡片的预览偏移（平滑动画）
              Offset targetOffset = Offset.zero;
              if (isInsertMode && _insertPreviewOffsets.containsKey(index)) {
                targetOffset = _insertPreviewOffsets[index]!;
              }

              Widget cardWidget;

              if (isOriginalSlot && !isInsertMode) {
                // BUG-08: 拖回原位时显示取消指示
                final isCancelHover = _hoverIndex == _originalIndex;
                cardWidget = Opacity(
                  opacity: isCancelHover ? 0.5 : 0.3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LibraryGhostCard(
                        game: game,
                        coverPath: _coverPathCache[game.directoryPath],
                      ),
                      if (isCancelHover)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: AppColors.dangerRed,
                                width: 2.5,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.dangerRed,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '松手取消',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primaryText,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              } else if (isOriginalSlot && isInsertMode) {
                // 插入模式：拖拽卡片在目标位置显示为半透明+蓝色边框
                cardWidget = Container(
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: AppColors.selectedAccent, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Opacity(
                    opacity: 0.5,
                    child: LibraryGhostCard(
                      game: game,
                      coverPath: _coverPathCache[game.directoryPath],
                    ),
                  ),
                );
              } else if (isSwapTarget) {
                // 交换模式：蓝色高亮边框
                // UX-16: 当 hover 在卡片边缘（pending insert）时，
                // 显示侧边插入指示线替代完整边框，明确两种模式区别
                final pendingBefore = _pendingInsertIndex != -1 &&
                    _pendingInsertMode == _DragMode.insertBefore;
                final pendingAfter = _pendingInsertIndex != -1 &&
                    _pendingInsertMode == _DragMode.insertAfter;
                cardWidget = Stack(
                  children: [
                    LibraryGhostCard(
                      game: game,
                      coverPath: _coverPathCache[game.directoryPath],
                    ),
                    if (!pendingBefore && !pendingAfter)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: AppColors.selectedAccent, width: 2.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    if (pendingBefore) _buildInsertIndicator(isBefore: true),
                    if (pendingAfter) _buildInsertIndicator(isBefore: false),
                  ],
                );
              } else if (isInsertMode) {
                // 插入预览模式：卡片不可交互，但视觉正常
                // UX-16: 在目标卡片边缘显示插入指示线
                final isInsertTarget = _hoverIndex == index;
                final showBefore =
                    isInsertTarget && _dragMode == _DragMode.insertBefore;
                final showAfter =
                    isInsertTarget && _dragMode == _DragMode.insertAfter;
                cardWidget = IgnorePointer(
                  child: Stack(
                    children: [
                      LibraryGhostCard(
                        game: game,
                        coverPath: _coverPathCache[game.directoryPath],
                      ),
                      if (showBefore) _buildInsertIndicator(isBefore: true),
                      if (showAfter) _buildInsertIndicator(isBefore: false),
                    ],
                  ),
                );
              } else {
                // 普通卡片
                final isSelected = _isEditMode &&
                    _selectedGamePaths.contains(game.directoryPath);
                cardWidget = Semantics(
                  label: '游戏: ${game.title}',
                  button: true,
                  child: _LibraryCardWidget(
                    key: _cardKeys.length > index ? _cardKeys[index] : null,
                    game: game,
                    index: index,
                    isDragging: _isDragging,
                    isSelected: isSelected,
                    isEditMode: _isEditMode,
                    isBlurred: game.isBlurred,
                    playStatus: game.playStatus,
                    coverPath: _coverPathCache[game.directoryPath], // UX-34
                    onDoubleTap:
                        _isEditMode ? null : () => _handleDoubleTap(game),
                    onTap:
                        _isEditMode ? () => _toggleCardSelection(game) : null,
                    onSecondaryTapDown: (details) => _isEditMode
                        ? _showEditModeContextMenu(
                            context, game, details.globalPosition)
                        : _showContextMenu(
                            context, game, details.globalPosition),
                    // BUG-07/08: 拖拽期间禁用其他卡片的 longPress 触发
                    onPointerDown: _activeSort.isEmpty && !_isDragging
                        ? (event) {
                            _longPressTimer = Timer(_dragDelay, () {
                              if (mounted) {
                                _startDrag(
                                    index, event.localPosition, event.position);
                              }
                            });
                          }
                        : null,
                    onPointerMove: _activeSort.isEmpty
                        ? (event) {
                            if (_longPressTimer != null && !_isDragging) {
                              final moveDist =
                                  event.delta.dx.abs() + event.delta.dy.abs();
                              if (moveDist > 5) _cancelLongPress();
                            }
                            // BUG-07: 仅在尚未被全局 Listener 处理时更新拖拽
                            if (_isDragging && !_isEndingDrag)
                              _updateDrag(event.position);
                          }
                        : null,
                    onPointerUp: _activeSort.isEmpty
                        ? () {
                            if (!_isDragging) {
                              _cancelLongPress();
                            } else if (!_isEndingDrag) {
                              // BUG-07: 防止与全局 Listener 双重调用
                              _endDrag();
                            }
                          }
                        : null,
                  ),
                );
              }

              // 应用平滑的预览偏移动画
              if (targetOffset != Offset.zero) {
                cardWidget = AnimatedBuilder(
                  animation: _insertPreviewCurve,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(
                        targetOffset.dx * _insertPreviewCurve.value,
                        targetOffset.dy * _insertPreviewCurve.value,
                      ),
                      child: child,
                    );
                  },
                  child: cardWidget,
                );
              }

              // 性能优化: 移除 TweenAnimationBuilder 入场动画
              // 原因: 快速滑动时大量卡片同时进入视口，每个都创建独立的
              // TweenAnimationBuilder 动画控制器，导致动画风暴 + 帧率骤降。
              // 动画过程中卡片半透明+缩放，视觉表现为"闪烁"和"不跟手"。
              // RepaintBoundary 仍保留，隔离每张卡片的重绘。
              return RepaintBoundary(
                child: cardWidget,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildManageButton() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 编辑模式下的面板按钮
        if (_isEditMode)
          Builder(builder: (btnContext) {
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  final box = btnContext.findRenderObject() as RenderBox?;
                  if (box != null) {
                    _showManagementPanelAt(box);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _managementPanel != null
                        ? AppColors.selectedAccent.withOpacity(0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.filter_list,
                    size: 20,
                    color: _managementPanel != null
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText,
                  ),
                ),
              ),
            );
          }),
        // 管理按钮（切换编辑模式）
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _toggleEditMode,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _isEditMode
                    ? AppColors.selectedAccent.withOpacity(0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isEditMode ? Icons.check_circle_outline : Icons.tune,
                    size: 20,
                    color: _isEditMode
                        ? AppColors.selectedAccent
                        : AppColors.secondaryText,
                  ),
                  if (_isEditMode) ...[
                    SizedBox(width: 6),
                    Text(
                      '管理',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.selectedAccent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditModeBar() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '已选 ${_selectedGamePaths.length} 项',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primaryText),
            ),
            SizedBox(width: 16),
            _editBarBtn(Icons.select_all, '全选', _selectAll),
            _editBarBtn(Icons.deselect, '取消', _deselectAll),
            SizedBox(width: 8),
            _editBarBtn(Icons.star_outline, '标记', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              for (final g in selectedGames) {
                widget.onToggleMark?.call(g.title);
              }
              setState(() {});
            }),
            _editBarBtn(Icons.blur_on, '模糊', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              for (final g in selectedGames) {
                GameDataFormat.setBlurred(g.pathForCover, !g.isBlurred);
                g.isBlurred = !g.isBlurred;
              }
              setState(() {});
            }),
            _editBarBtn(Icons.delete_outline, '删除', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              _showBatchDeleteConfirm(selectedGames);
            }),
            _editBarBtn(Icons.desktop_windows_outlined, '快捷方式', () {
              final selectedGames = _games
                  .where((g) => _selectedGamePaths.contains(g.directoryPath))
                  .toList();
              _showBatchShortcutDialog(selectedGames);
            }),
          ],
        ),
      ),
    );
  }

  Widget _editBarBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: AppColors.primaryText),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      color: AppColors.secondaryText)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: AppColors.border.withOpacity(0.4),
        ),
      ),
    );
  }

  /// UX-18: 磁盘扫描期间显示的加载遮罩
  Widget _buildScanningOverlay() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '正在扫描游戏库...',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyOverlay() {
    return Center(
      child: SizedBox(
        width: 320,
        height: 167,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Text(
                '库中没有游戏哦，快去探索游戏吧！',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 20,
                  height: 28 / 20,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
            Positioned(
              top: 116,
              left: 127,
              child: Semantics(
                label: '前往探索页面',
                button: true,
                child: GestureDetector(
                  onTap: widget.onGoDiscover,
                  onTapDown: (_) => setState(() => _goDiscoverHovered = true),
                  onTapUp: (_) => setState(() => _goDiscoverHovered = false),
                  onTapCancel: () => setState(() => _goDiscoverHovered = false),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _goDiscoverHovered = true),
                    onExit: (_) => setState(() => _goDiscoverHovered = false),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                      decoration: BoxDecoration(
                        color: _goDiscoverHovered
                            ? AppColors.cardHoverBg
                            : AppColors.placeholderCover,
                        border: Border.all(
                          color: _goDiscoverHovered
                              ? AppColors.border
                              : const Color(0x1A000000),
                          width: _goDiscoverHovered ? 2.2 : 2,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: _goDiscoverHovered
                            ? [
                                BoxShadow(
                                  color: const Color(0x408B7355),
                                  offset: const Offset(0, 3),
                                  blurRadius: 10,
                                ),
                              ]
                            : [
                                BoxShadow(
                                  color: AppColors.titleBrown,
                                  offset: Offset(2, 3),
                                  blurRadius: 0,
                                ),
                              ],
                      ),
                      child: Text(
                        '出 发',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 24 / 16,
                          color: AppColors.titleBrown,
                        ),
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
  }
}

class _LibraryCardWidget extends StatefulWidget {
  final LibraryGame game;
  final int index;
  final bool isDragging;
  final bool isSelected;
  final bool isEditMode;
  final bool isBlurred;
  final PlayStatus playStatus;

  /// UX-34: 预缓存的封面路径，避免 build/initState 中的同步 I/O
  final String? coverPath;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;
  final ValueChanged<PointerEvent>? onPointerDown;
  final ValueChanged<PointerEvent>? onPointerMove;
  final VoidCallback? onPointerUp;

  const _LibraryCardWidget({
    super.key,
    required this.game,
    required this.index,
    required this.isDragging,
    this.isSelected = false,
    this.isEditMode = false,
    this.isBlurred = false,
    this.playStatus = PlayStatus.notStarted,
    this.coverPath,
    this.onDoubleTap,
    this.onTap,
    required this.onSecondaryTapDown,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
  });

  @override
  State<_LibraryCardWidget> createState() => _LibraryCardWidgetState();
}

class _LibraryCardWidgetState extends State<_LibraryCardWidget>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _hoverController;
  Widget? _cachedCover;

  static BoxShadow _normalShadow = BoxShadow(
    color: AppColors.borderLight,
    offset: Offset(2, 3),
    blurRadius: 5,
  );

  static BoxShadow _hoverShadow = BoxShadow(
    color: AppColors.border.withOpacity(0.2),
    offset: Offset(2, 8),
    blurRadius: 16,
  );

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0.0,
    );
    _cachedCover = _resolveCover();
  }

  @override
  void didUpdateWidget(_LibraryCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.directoryPath != widget.game.directoryPath ||
        oldWidget.coverPath != widget.coverPath ||
        oldWidget.game.mark != widget.game.mark ||
        oldWidget.isBlurred != widget.isBlurred) {
      _cachedCover = _resolveCover();
    }
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  /// UX-34: 使用预缓存的 coverPath 构建封面，不再在 build/initState 中做同步 I/O
  /// 性能优化: 添加 cacheWidth/cacheHeight 避免全分辨率解码
  ///   - 封面图可能是 4K 分辨率（~30MB/张），但卡片只需 ~200×300 显示
  ///   - 不指定 cacheWidth/cacheHeight 时 Flutter 会解码全分辨率到内存
  ///   - 指定后 Flutter 只解码到目标尺寸，内存占用降 95%+，解码速度提升 10x+
  /// 性能优化: 简化淡入动画 300ms → 150ms，减少快速滑动时的动画叠加
  Widget _resolveCover() {
    final path = widget.coverPath;
    if (path != null && path.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // 底层占位符，图片加载期间可见
          _buildPlaceholderCover(),
          Image.file(
            File(path),
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            cacheWidth: 480, // 物理像素: 240px卡片 × 2x DPR = 480
            cacheHeight: 720, // 物理像素: 360px卡片 × 2x DPR = 720
            // 性能优化: 简化淡入动画，减少快速滑动时的动画叠加
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                opacity: frame == null ? 0.0 : 1.0,
                child: child,
              );
            },
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ],
      );
    }
    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: AppColors.border.withOpacity(0.4),
        ),
      ),
    );
  }

  void _onHoverEnter() {
    if (widget.isDragging) return;
    setState(() => _hovered = true);
    _hoverController.forward();
  }

  void _onHoverExit() {
    if (_hovered) {
      setState(() => _hovered = false);
      _hoverController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMarked = widget.game.mark != GameMark.none;

    final coverImage = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color:
              widget.isSelected ? AppColors.selectedAccent : AppColors.border,
          width: widget.isSelected ? 3 : 2,
        ),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [_hovered ? _hoverShadow : _normalShadow],
        color: AppColors.background,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: widget.isBlurred
                  ? ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: _cachedCover ?? _buildPlaceholderCover(),
                    )
                  : (_cachedCover ?? _buildPlaceholderCover()),
            ),
          ),
          // 游玩状态标识（左下角）
          Positioned(
            bottom: 6,
            left: 6,
            child: _buildPlayStatusBadge(widget.playStatus),
          ),
          // 星标（右上角）
          if (isMarked)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                Icons.star_rounded,
                size: 20,
                color: AppColors.starGold,
                shadows: [
                  Shadow(color: Colors.white.withOpacity(0.8), blurRadius: 2),
                ],
              ),
            ),
          // 编辑模式选中勾选（左上角，覆盖在状态标识位置上）
          if (widget.isEditMode)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? AppColors.selectedAccent
                      : Colors.white.withOpacity(0.7),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.isSelected
                        ? AppColors.selectedAccent
                        : AppColors.border,
                    width: 2,
                  ),
                ),
                child: widget.isSelected
                    ? Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );

    final cardContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: coverImage,
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 22,
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.only(left: 2),
            child: AutoSizeText(
              widget.game.title.isNotEmpty ? widget.game.title : '未命名游戏',
              style: AppStyles.gameTitle.copyWith(fontSize: 18),
              maxLines: 1,
              minFontSize: 10,
              stepGranularity: 0.5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        SizedBox(
          height: 18,
          child: widget.game.developer.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(left: 2, top: 2),
                  child: Text(
                    widget.game.developer,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: AppColors.secondaryText.withOpacity(0.8),
                      fontStyle: FontStyle.italic,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );

    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      child: MouseRegion(
        cursor: widget.isDragging
            ? SystemMouseCursors.grabbing
            : (widget.isEditMode
                ? SystemMouseCursors.click
                : SystemMouseCursors.grab),
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: AnimatedBuilder(
          animation: _hoverController,
          builder: (context, child) {
            final t = _hoverController.value;
            if (t == 0) return child!;
            return Transform.translate(
              offset: Offset(0, -4 * t),
              child: Transform.scale(
                scale: 1.0 + 0.025 * t,
                alignment: Alignment.center,
                child: child,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            clipBehavior: Clip.none,
            child: Listener(
              onPointerDown: widget.onPointerDown,
              onPointerMove: widget.onPointerMove,
              onPointerUp: widget.onPointerUp != null
                  ? (_) => widget.onPointerUp!()
                  : null,
              child: cardContent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayStatusBadge(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
                color: AppColors.secondaryText.withOpacity(0.6), width: 1.5),
          ),
        );
      case PlayStatus.inProgress:
        return Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 5)
            ],
          ),
        );
      case PlayStatus.dropped:
        return Container(
          padding: EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.9),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.exit_to_app, size: 13, color: Colors.white),
        );
      case PlayStatus.completed:
        return Container(
          padding: EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.starGold,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.emoji_events, size: 15, color: Colors.white),
        );
    }
  }
}

// --- 管理面板 ---
class _ManagementPanelWidget extends StatefulWidget {
  final Offset position;
  final String searchQuery;
  final String activeSort;
  final String activeDeveloperFilter;
  final double cardMaxExtent;
  final List<String> developers;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<String> onDeveloperFilterChanged;
  final ValueChanged<double> onLayoutChanged;
  final VoidCallback onClose;

  const _ManagementPanelWidget({
    required this.position,
    required this.searchQuery,
    required this.activeSort,
    required this.activeDeveloperFilter,
    required this.cardMaxExtent,
    required this.developers,
    required this.onSearchChanged,
    required this.onSortChanged,
    required this.onDeveloperFilterChanged,
    required this.onLayoutChanged,
    required this.onClose,
  });

  @override
  State<_ManagementPanelWidget> createState() => _ManagementPanelWidgetState();
}

class _ManagementPanelWidgetState extends State<_ManagementPanelWidget> {
  late TextEditingController _searchController;
  late TextEditingController _devSearchController;
  late FocusNode _searchFocusNode;
  String _devSearchQuery = '';
  bool _devListExpanded = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchQuery);
    _devSearchController = TextEditingController();
    _searchFocusNode = FocusNode();
    // 自动聚焦搜索框
    Future.microtask(() => _searchFocusNode.requestFocus());
  }

  @override
  void didUpdateWidget(covariant _ManagementPanelWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同步搜索框内容（父组件可能通过 markNeedsBuild 更新了 searchQuery）
    if (widget.searchQuery != _searchController.text) {
      _searchController.text = widget.searchQuery;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _devSearchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 点击外部关闭
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            behavior: HitTestBehavior.translucent,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 面板主体
        Positioned(
          left: widget.position.dx,
          top: widget.position.dy,
          child: Container(
            width: 280,
            constraints: BoxConstraints(maxHeight: 480),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 16,
                    offset: Offset(0, 4)),
              ],
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 搜索框
                  TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        color: AppColors.primaryText),
                    decoration: InputDecoration(
                      hintText: '搜索游戏...',
                      hintStyle: TextStyle(color: AppColors.placeholderText),
                      prefixIcon: Icon(Icons.search,
                          size: 18, color: AppColors.secondaryText),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.selectedAccent, width: 1.5),
                      ),
                      filled: true,
                      fillColor: AppColors.background,
                    ),
                    onChanged: widget.onSearchChanged,
                  ),
                  SizedBox(height: 16),

                  // 排序
                  Text('排序',
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText)),
                  SizedBox(height: 6),
                  _sortOption('recently_added', '最近添加', Icons.schedule),
                  _sortOption(
                      'recently_played', '最近游玩', Icons.play_circle_outline),
                  _sortOption('play_time', '游玩时长', Icons.timer_outlined),
                  _sortOption('play_status', '游玩状态', Icons.sports_esports),
                  _sortOption('marked_first', '标记优先', Icons.star_outline),
                  SizedBox(height: 14),

                  // 会社筛选
                  _buildDevFilterSection(),
                  SizedBox(height: 14),

                  // 卡片布局
                  Text('卡片布局',
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      _layoutBtn('紧凑', 160),
                      SizedBox(width: 8),
                      _layoutBtn('舒适', 240),
                      SizedBox(width: 8),
                      _layoutBtn('宽松', 340),
                    ],
                  ),
                  SizedBox(height: 8),
                  Slider(
                    value: widget.cardMaxExtent.clamp(140, 400),
                    min: 140,
                    max: 400,
                    divisions: 26,
                    activeColor: AppColors.selectedAccent,
                    inactiveColor: AppColors.borderLight,
                    onChanged: widget.onLayoutChanged,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDevFilterSection() {
    final allDevs = widget.developers;
    final filteredDevs = allDevs
        .where((d) =>
            _devSearchQuery.isEmpty ||
            d.toLowerCase().contains(_devSearchQuery.toLowerCase()))
        .toList();
    final hasMoreDevs = allDevs.length > 5;
    final showDevs = _devListExpanded || _devSearchQuery.isNotEmpty
        ? filteredDevs
        : filteredDevs.take(5).toList();
    final canExpand =
        hasMoreDevs && !_devListExpanded && _devSearchQuery.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（可点击展开/收起）
        GestureDetector(
          onTap: hasMoreDevs
              ? () => setState(() => _devListExpanded = !_devListExpanded)
              : null,
          child: MouseRegion(
            cursor: hasMoreDevs
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text('会社筛选',
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: AppColors.secondaryText)),
                  Spacer(),
                  if (hasMoreDevs)
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 200),
                      turns: _devListExpanded ? 0.5 : 0,
                      child: Icon(Icons.expand_more,
                          size: 16, color: AppColors.secondaryText),
                    ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: 6),
        // 会社搜索框（展开后或会社多时显示）
        if (hasMoreDevs)
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: TextField(
              controller: _devSearchController,
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: '搜索会社...',
                hintStyle:
                    TextStyle(color: AppColors.placeholderText, fontSize: 12),
                prefixIcon: Icon(Icons.search,
                    size: 14, color: AppColors.secondaryText),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      BorderSide(color: AppColors.selectedAccent, width: 1.5),
                ),
                filled: true,
                fillColor: AppColors.background,
              ),
              onChanged: (v) => setState(() => _devSearchQuery = v),
            ),
          ),
        // 会社列表（收起时只显示前5个）
        if (_devListExpanded ||
            allDevs.length <= 5 ||
            _devSearchQuery.isNotEmpty) ...[
          _devFilterOption('', '全部'),
          if (widget.developers.any((d) => d.isEmpty))
            _devFilterOption('__none__', '未分类'),
          ...showDevs.map((d) => _devFilterOption(d, d)),
        ] else ...[
          _devFilterOption('', '全部'),
          if (widget.developers.any((d) => d.isEmpty))
            _devFilterOption('__none__', '未分类'),
          ...allDevs.take(5).map((d) => _devFilterOption(d, d)),
        ],
        // 展开/收起按钮
        if (canExpand)
          GestureDetector(
            onTap: () => setState(() => _devListExpanded = true),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '展开全部 (${allDevs.length})',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: AppColors.selectedAccent,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sortOption(String key, String label, IconData icon) {
    final isActive = widget.activeSort == key;
    return PanelHoverBuilder(builder: (isHovered) {
      final showHighlight = isActive || isHovered;
      return GestureDetector(
        onTap: () => widget.onSortChanged(key),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.selectedAccent.withOpacity(0.12)
                  : isHovered
                      ? AppColors.selectedAccent.withOpacity(0.06)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.primaryText
                            : AppColors.secondaryText),
                SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: isActive
                          ? AppColors.selectedAccent
                          : AppColors.primaryText,
                      fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                    )),
                Spacer(),
                if (isActive)
                  Icon(Icons.check, size: 16, color: AppColors.selectedAccent),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _devFilterOption(String key, String label) {
    final isActive = widget.activeDeveloperFilter == key;
    return PanelHoverBuilder(builder: (isHovered) {
      return GestureDetector(
        onTap: () => widget.onDeveloperFilterChanged(key),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(vertical: 5, horizontal: 8),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.selectedAccent.withOpacity(0.12)
                  : isHovered
                      ? AppColors.selectedAccent.withOpacity(0.06)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: isActive
                      ? AppColors.selectedAccent
                      : isHovered
                          ? AppColors.primaryText
                          : AppColors.secondaryText,
                ),
                SizedBox(width: 6),
                Expanded(
                    child: Text(label,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: isActive
                              ? AppColors.selectedAccent
                              : AppColors.primaryText,
                          fontWeight:
                              isActive ? FontWeight.w500 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _layoutBtn(String label, double value) {
    final isActive = (widget.cardMaxExtent - value).abs() < 20;
    return Expanded(
      child: PanelHoverBuilder(builder: (isHovered) {
        return GestureDetector(
          onTap: () => widget.onLayoutChanged(value),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              padding: EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.selectedAccent.withOpacity(0.15)
                    : isHovered
                        ? AppColors.selectedAccent.withOpacity(0.06)
                        : Colors.transparent,
                border: Border.all(
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.selectedAccent.withOpacity(0.4)
                            : AppColors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: isActive
                        ? AppColors.selectedAccent
                        : isHovered
                            ? AppColors.primaryText
                            : AppColors.secondaryText,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                  )),
            ),
          ),
        );
      }),
    );
  }
}
