import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_size_text/auto_size_text.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../widgets/library_context_menu.dart';
import '../widgets/game_detail_dialog.dart';
import '../widgets/exe_selector_dialog.dart';
import '../widgets/save_backup_dialog.dart';
import '../utils/game_config_manager.dart';

enum _DragMode { swap, insertBefore, insertAfter }

class LibraryPage extends StatefulWidget {
  final VoidCallback onGoDiscover;
  final ValueChanged<String>? onLaunchGame;
  final ValueChanged<String>? onToggleMark;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onRefresh;

  const LibraryPage({
    super.key,
    required this.onGoDiscover,
    this.onLaunchGame,
    this.onToggleMark,
    this.onDelete,
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
  int? _draggingIndex;
  int? _originalIndex;
  Offset _dragPosition = Offset.zero;
  int _hoverIndex = -1;
  bool _goDiscoverHovered = false;
  List<LibraryGame> _games = [];
  Timer? _longPressTimer;
  static const Duration _dragDelay = Duration(milliseconds: 300);
  Offset _dragAnchor = Offset.zero;
  final GlobalKey _gridKey = GlobalKey();
  Rect? _gridBounds;
  late final AnimationController _liftAnimation;
  final Map<String, String> _localeModes = {};

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

  bool get _isDragging => _draggingIndex != null;

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
    _refreshFromDisk();
    ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
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

  Future<void> _refreshFromDisk() async {
    await LocalGameRegistry.instance.scan();
    _loadGames();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshFromDisk();
  }

  void _loadGames() {
    final games = LocalGameRegistry.instance.allGames;
    _applyCustomOrder(games);
  }

  Future<void> _loadLocaleModes() async {
    for (final game in _games) {
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null && data.localeMode.isNotEmpty) {
          _localeModes[game.title] = data.localeMode;
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
          _syncCardKeys();
        });
        debugPrint('[LIBRARY] ✅ 已应用自定义排序 (${orderedGames.length}个)');
        _loadLocaleModes();
      } else {
        setState(() {
          _games = games;
          _syncCardKeys();
        });
        _loadLocaleModes();
      }
    } catch (e) {
      debugPrint('[LIBRARY] ⚠️ 应用自定义排序失败: $e');
      setState(() {
        _games = games;
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
    ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _contextMenuOverlay?.remove();
    _dragOverlay?.remove();
    _liftAnimation.dispose();
    _insertPreviewCurve.dispose();
    _insertPreviewAnim.dispose();
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
            onLocaleModeChanged: (mode) {
              _localeModes[game.title] = mode;
            },
          );
        },
        onSelectExe: () {
          debugPrint('[LIBRARY] 右键选择启动程序: ${game.title}');
          _dismissContextMenu();
          _showChangeExeSelector(game);
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
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _gridBounds = box.paintBounds.shift(box.localToGlobal(Offset.zero));

    // 缓存实际卡片尺寸
    final dragCardKey = _cardKeys[index];
    final dragCardBox =
        dragCardKey.currentContext?.findRenderObject() as RenderBox?;
    if (dragCardBox != null) {
      _cachedCardSize = dragCardBox.size;
    }

    // 缓存所有卡片位置（拖拽期间用缓存做检测，避免视觉变化导致 GlobalKey 失效引发闪烁）
    _cachedCardRects = {};
    for (int i = 0; i < _games.length; i++) {
      final key = _cardKeys[i];
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        _cachedCardRects[i] = renderBox.paintBounds
            .shift(renderBox.localToGlobal(Offset.zero));
      }
    }

    setState(() {
      _draggingIndex = index;
      _originalIndex = index;
      _hoverIndex = -1;
      _dragAnchor = localPos;
      _dragPosition = globalPos;
      _dragMode = _DragMode.swap;
      _insertIndex = -1;
    });

    _showDragOverlay();
    _liftAnimation.forward(from: 0);
  }

  void _showDragOverlay() {
    if (_dragOverlay != null) return;
    if (_originalIndex == null || _originalIndex! >= _games.length) return;

    final game = _games[_originalIndex!];

    _dragOverlay = OverlayEntry(
      builder: (context) => _BuildDragOverlay(
        game: game,
        dragPosition: _dragPosition,
        dragAnchor: _dragAnchor,
        liftAnimation: _liftAnimation,
        isMarked: game.mark != GameMark.none,
        cardSize: _cachedCardSize,
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

  void _updateDrag(Offset globalPos) {
    if (_gridBounds == null || _draggingIndex == null) return;

    setState(() {
      _dragPosition = globalPos;
    });
    _updateDragOverlay();
    _updateHoverIndex(globalPos);
  }

  /// 使用缓存的卡片位置进行悬停检测
  /// 基于鼠标在卡片内的水平位置区分交换/插入模式：
  /// - 左 15% → 插入到该卡片前面（需停留 300ms）
  /// - 右 15% → 插入到该卡片后面（需停留 300ms）
  /// - 中间 70% → 交换（立即触发）
  void _updateHoverIndex(Offset globalPos) {
    if (_draggingIndex == null) return;

    int foundIndex = -1;
    _DragMode foundMode = _DragMode.swap;

    for (int i = 0; i < _games.length; i++) {
      if (i == _originalIndex) continue;

      final boxRect = _cachedCardRects[i];
      if (boxRect == null) continue;

      if (boxRect.contains(globalPos)) {
        foundIndex = i;

        // 根据鼠标在卡片内的水平位置判断模式
        final relativeX = (globalPos.dx - boxRect.left) / boxRect.width;
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

    if (foundIndex != -1) {
      if (foundMode == _DragMode.swap) {
        // 交换模式：立即触发，取消插入延迟计时器
        _insertDelayTimer?.cancel();
        _insertDelayTimer = null;
        _pendingInsertIndex = -1;

        final needUpdate = _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
        if (needUpdate) {
          setState(() {
            _hoverIndex = foundIndex;
            _dragMode = _DragMode.swap;
            _insertIndex = -1;
          });
          _insertPreviewAnim.reverse();
        }
      } else {
        // 插入模式：需要停留 300ms 才触发
        final pendingInsertIdx = foundMode == _DragMode.insertBefore
            ? foundIndex
            : foundIndex + 1;

        // 如果鼠标在同一张卡片的同一边缘区域移动，保持计时器
        if (_pendingInsertIndex != pendingInsertIdx ||
            _pendingInsertMode != foundMode) {
          // 切换了目标或模式，重新开始计时
          _insertDelayTimer?.cancel();

          // 先切换到交换模式作为过渡（立即反馈）
          final needUpdate = _hoverIndex != foundIndex || _dragMode != _DragMode.swap;
          if (needUpdate) {
            setState(() {
              _hoverIndex = foundIndex;
              _dragMode = _DragMode.swap;
              _insertIndex = -1;
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
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _insertPreviewAnim.reverse();

    if (_dragMode == _DragMode.swap &&
        _draggingIndex != null &&
        _hoverIndex != -1 &&
        _hoverIndex != _originalIndex) {
      // 模式 A：直接交换
      final reordered = List<LibraryGame>.from(_games);
      final temp = reordered[_originalIndex!];
      reordered[_originalIndex!] = reordered[_hoverIndex];
      reordered[_hoverIndex] = temp;
      _games = reordered;
      _saveGameOrder();
    } else if ((_dragMode == _DragMode.insertBefore ||
            _dragMode == _DragMode.insertAfter) &&
        _draggingIndex != null &&
        _insertIndex != -1) {
      // 模式 B：插入重排
      final reordered = List<LibraryGame>.from(_games);
      final item = reordered.removeAt(_originalIndex!);
      // 移除后索引可能变化，需要调整
      int targetIndex = _insertIndex;
      if (_originalIndex! < targetIndex) {
        targetIndex--;
      }
      targetIndex = targetIndex.clamp(0, reordered.length);
      reordered.insert(targetIndex, item);
      _games = reordered;
      _saveGameOrder();
    }

    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _draggingIndex = null;
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
      });
    });
  }

  void _cancelDrag() {
    _cancelLongPress();
    _insertDelayTimer?.cancel();
    _insertDelayTimer = null;
    _pendingInsertIndex = -1;
    _insertPreviewAnim.reverse();
    _liftAnimation.reverse().then((_) {
      _removeDragOverlay();
      setState(() {
        _draggingIndex = null;
        _originalIndex = null;
        _dragPosition = Offset.zero;
        _dragAnchor = Offset.zero;
        _hoverIndex = -1;
        _insertIndex = -1;
        _dragMode = _DragMode.swap;
        _gridBounds = null;
        _cachedCardSize = null;
        _cachedCardRects = {};
        _insertPreviewOffsets = {};
      });
    });
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
    print('[LAUNCH] ========== 双击启动: ${game.title} ==========');

    final exePath = await _resolveUserChoice(game.title);

    if (exePath != null) {
      await _executeLaunch(game, exePath);
    } else {
      print('[LAUNCH] 无已保存的启动程序，弹出选择器');
      _showExeSelector(game);
    }
  }

  Future<String?> _resolveUserChoice(String gameTitle) async {
    print('[LAUNCH] 查找用户保存的启动路径...');

    final configPath =
        await GameConfigManager.instance.getLaunchPath(gameTitle);
    if (configPath != null && configPath.isNotEmpty) {
      if (await File(configPath).exists()) {
        print('[LAUNCH] ✅ GameConfigManager命中: $configPath');
        return configPath;
      }
      print('[LAUNCH] ⚠️ GameConfigManager路径无效，清除');
      await GameConfigManager.instance.removeConfig(gameTitle);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final spPath = prefs.getString('default_exe_$gameTitle');
      if (spPath != null && spPath.isNotEmpty) {
        if (await File(spPath).exists()) {
          print('[LAUNCH] ✅ SharedPreferences命中(迁移): $spPath');
          await GameConfigManager.instance
              .migrateFromSharedPreferences(gameTitle, spPath);
          return spPath;
        }
        print('[LAUNCH] ⚠️ SP路径无效，清除');
        await prefs.remove('default_exe_$gameTitle');
      }
    } catch (e) {
      print('[LAUNCH] SP读取异常: $e');
    }

    return null;
  }

  Future<void> _executeLaunch(LibraryGame game, String exePath) async {
    print('[LAUNCH] 🚀 执行启动: ${game.title} -> $exePath');

    await _persistUserChoice(game.title, exePath);

    final localeMode = _localeModes[game.title] ?? 'none';
    print('[LAUNCH] 🌸 转区模式: $localeMode');

    final success = await LocalGameRegistry.instance
        .launchGame(game.title, forceExePath: exePath, localeMode: localeMode);

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法启动「${game.title}」'),
          duration: const Duration(seconds: 3),
          backgroundColor: const Color(0xFFC62828),
        ),
      );
    }
  }

  Future<void> _persistUserChoice(String gameTitle, String exePath) async {
    print('[LAUNCH] 💾 持久化用户选择(覆盖式写入)...');

    try {
      await GameConfigManager.instance.saveLaunchPath(gameTitle, exePath);
      print('[LAUNCH]   GameConfigManager: OK');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_exe_$gameTitle', exePath);
      print('[LAUNCH]   SharedPreferences: OK(旧值已覆盖)');
    } catch (e) {
      print('[LAUNCH]   持久化异常: $e');
    }

    try {
      await LocalGameRegistry.instance.updateLauncherPath(gameTitle, exePath);
      print('[LAUNCH]   LocalGameRegistry: OK');
    } catch (e) {
      print('[LAUNCH]   Registry更新异常: $e');
    }

    print('[LAUNCH] ✅ 用户选择已锁定: $exePath');
  }

  void _showExeSelector(LibraryGame game) {
    final currentLocale = _localeModes[game.title] ?? 'none';
    ExeSelectorDialog.show(
      context: context,
      gameDirectory: game.directoryPath,
      initialExePath: null,
      initialLocaleMode: currentLocale,
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
    );
  }

  void _showChangeExeSelector(LibraryGame game) async {
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
    ExeSelectorDialog.show(
      context: context,
      gameDirectory: game.directoryPath,
      initialExePath: displayExe,
      initialLocaleMode: currentLocale,
      onSelected: (selectedExe) async {
        await _persistUserChoice(game.title, selectedExe);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已更新「${game.title}」的启动程序（已设为默认）'),
            duration: const Duration(seconds: 2),
            backgroundColor: const Color(0xFF4A72A5),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.pageBackground,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Stack(
        children: [
          _buildGameGrid(),
          if (_games.isEmpty) _buildEmptyOverlay(),
        ],
      ),
    );
  }

  Widget _buildGameGrid() {
    if (_games.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GridView.builder(
            key: _gridKey,
            cacheExtent: 400,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 24,
              crossAxisSpacing: 24,
              childAspectRatio: 0.60,
            ),
            itemCount: _games.length,
            itemBuilder: (context, index) {
              final game = _games[index];
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
                // 交换模式：原位置 Ghost
                cardWidget = Opacity(
                  opacity: 0.3,
                  child: _BuildGhostCard(game: game),
                );
              } else if (isOriginalSlot && isInsertMode) {
                // 插入模式：拖拽卡片在目标位置显示为半透明+蓝色边框
                cardWidget = Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.selectedBlue, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Opacity(
                    opacity: 0.5,
                    child: _BuildGhostCard(game: game),
                  ),
                );
              } else if (isSwapTarget) {
                // 交换模式：蓝色高亮边框
                cardWidget = Stack(
                  children: [
                    _BuildGhostCard(game: game),
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: AppColors.selectedBlue, width: 2.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                );
              } else if (isInsertMode) {
                // 插入预览模式：卡片不可交互，但视觉正常
                cardWidget = IgnorePointer(
                  child: _BuildGhostCard(game: game),
                );
              } else {
                // 普通卡片
                cardWidget = Semantics(
                  label: '游戏: ${game.title}',
                  button: true,
                  child: _LibraryCardWidget(
                    key: _cardKeys[index],
                    game: game,
                    index: index,
                    isDragging: _isDragging,
                    onDoubleTap: () => _handleDoubleTap(game),
                    onSecondaryTapDown: (details) =>
                        _showContextMenu(context, game, details.globalPosition),
                    onPointerDown: (event) {
                      _longPressTimer = Timer(_dragDelay, () {
                        if (mounted) {
                          _startDrag(index, event.localPosition, event.position);
                        }
                      });
                    },
                    onPointerMove: (event) {
                      if (_longPressTimer != null && !_isDragging) {
                        final moveDist =
                            event.delta.dx.abs() + event.delta.dy.abs();
                        if (moveDist > 5) _cancelLongPress();
                      }
                      if (_isDragging) _updateDrag(event.position);
                    },
                    onPointerUp: () {
                      if (!_isDragging) {
                        _cancelLongPress();
                      } else {
                        _endDrag();
                      }
                    },
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

              return cardWidget;
            },
          );
        },
      ),
    );
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: const Color(0xFFE9E0D1),
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: const Color(0xFF8B7355).withOpacity(0.4),
        ),
      ),
    );
  }

  Widget _buildFallbackCover(LibraryGame game) {
    try {
      final coverFile = GameDataFormat.findCoverFile(game.pathForCover);
      if (coverFile != null) {
        return Image.file(
          coverFile,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        );
      }
    } catch (e) {}

    return _buildPlaceholderCover();
  }

  Widget _buildEmptyOverlay() {
    return Center(
      child: SizedBox(
        width: 320,
        height: 167,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Text(
                '库中没有游戏哦，快去探索游戏吧！',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 20,
                  height: 28 / 20,
                  color: Color(0xFFA08264),
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
                            ? const Color(0xFFF5E6D8)
                            : const Color(0xFFF0E6D2),
                        border: Border.all(
                          color: _goDiscoverHovered
                              ? const Color(0xFF8B7355)
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
                            : const [
                                BoxShadow(
                                  color: Color(0xFF5C4A3D),
                                  offset: Offset(2, 3),
                                  blurRadius: 0,
                                ),
                              ],
                      ),
                      child: const Text(
                        '出 发',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 24 / 16,
                          color: Color(0xFF5C4A3D),
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
  final VoidCallback onDoubleTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;
  final ValueChanged<PointerEvent> onPointerDown;
  final ValueChanged<PointerEvent> onPointerMove;
  final VoidCallback onPointerUp;

  const _LibraryCardWidget({
    super.key,
    required this.game,
    required this.index,
    required this.isDragging,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
  });

  @override
  State<_LibraryCardWidget> createState() => _LibraryCardWidgetState();
}

class _LibraryCardWidgetState extends State<_LibraryCardWidget>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _hoverController;
  Widget? _cachedCover;

  static const BoxShadow _normalShadow = BoxShadow(
    color: Color(0x0D8B7355),
    offset: Offset(2, 3),
    blurRadius: 5,
  );

  static const BoxShadow _hoverShadow = BoxShadow(
    color: Color(0x338B7355),
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
        oldWidget.game.coverUrl != widget.game.coverUrl ||
        oldWidget.game.mark != widget.game.mark) {
      _cachedCover = _resolveCover();
    }
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  Widget _resolveCover() {
    final game = widget.game;

    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return Image.file(
        File(game.coverUrl),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackCover(),
      );
    }
    return _buildFallbackCover();
  }

  Widget _buildFallbackCover() {
    try {
      final coverFile = GameDataFormat.findCoverFile(widget.game.pathForCover);
      if (coverFile != null) {
        return Image.file(
          coverFile,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        );
      }
    } catch (e) {}

    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: const Color(0xFFE9E0D1),
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: const Color(0xFF8B7355).withOpacity(0.4),
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
        border: Border.all(color: AppColors.border, width: 2),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [_hovered ? _hoverShadow : _normalShadow],
        color: AppColors.background,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _cachedCover ?? _buildPlaceholderCover()),
          if (isMarked)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                Icons.star_rounded,
                size: 20,
                color: const Color(0xFFD4A017),
                shadows: [
                  Shadow(color: Colors.white.withOpacity(0.8), blurRadius: 2),
                ],
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
                      fontSize: 10,
                      color: AppColors.secondaryText.withOpacity(0.6),
                      fontStyle: FontStyle.italic,
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
      onDoubleTap: widget.onDoubleTap,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      child: MouseRegion(
        cursor: widget.isDragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
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
          child: Listener(
            onPointerDown: widget.onPointerDown,
            onPointerMove: widget.onPointerMove,
            onPointerUp: (_) => widget.onPointerUp(),
            child: cardContent,
          ),
        ),
      ),
    );
  }
}

class _BuildGhostCard extends StatelessWidget {
  final LibraryGame game;

  const _BuildGhostCard({required this.game});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border, width: 2),
              borderRadius: BorderRadius.circular(4),
              color: AppColors.background,
            ),
            child: _buildCoverImage(),
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 22,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              game.title.isNotEmpty ? game.title : '未命名游戏',
              style: AppStyles.gameTitle.copyWith(fontSize: 18),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (game.developer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              game.developer,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                color: AppColors.secondaryText.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildCoverImage() {
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return Image.file(
        File(game.coverUrl),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    try {
      final coverFile = GameDataFormat.findCoverFile(game.pathForCover);
      if (coverFile != null) {
        return Image.file(
          coverFile,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        );
      }
    } catch (e) {}

    return Container(
      color: const Color(0xFFE9E0D1),
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: const Color(0xFF8B7355).withOpacity(0.4),
        ),
      ),
    );
  }
}

class _BuildDragOverlay extends StatelessWidget {
  final LibraryGame game;
  final Offset dragPosition;
  final Offset dragAnchor;
  final Animation<double> liftAnimation;
  final bool isMarked;
  final Size? cardSize;

  const _BuildDragOverlay({
    required this.game,
    required this.dragPosition,
    required this.dragAnchor,
    required this.liftAnimation,
    required this.isMarked,
    this.cardSize,
  });

  @override
  Widget build(BuildContext context) {
    final curvedAnimation = CurvedAnimation(
      parent: liftAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    // 动态获取卡片尺寸，fallback 到 GridView 的默认计算
    final double overlayWidth = cardSize?.width ?? 240.0;
    final double overlayHeight = cardSize?.height ?? (240.0 / 0.60);

    return Positioned(
      left: dragPosition.dx - dragAnchor.dx,
      top: dragPosition.dy - dragAnchor.dy,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: curvedAnimation,
          builder: (context, child) {
            final t = curvedAnimation.value;
            final scale = 1.02 + 0.03 * t;

            return Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: Opacity(
                opacity: 0.95,
                child: Container(
                  width: overlayWidth,
                  height: overlayHeight,
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: AppColors.selectedBlue, width: 2.5),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x668B7355),
                        offset: Offset(8 * t, 12 * t),
                        blurRadius: 20 + 15 * t,
                        spreadRadius: 3 * t,
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2 * t),
                        offset: Offset(4 * t, 6 * t),
                        blurRadius: 10 + 5 * t,
                      ),
                    ],
                    color: AppColors.background,
                  ),
                  child: _buildCardContent(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCardContent() {
    Widget content;

    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      content = Image.file(
        File(game.coverUrl),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackCover(),
      );
    } else {
      content = _buildFallbackCover();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: content),
              if (isMarked)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    Icons.star_rounded,
                    size: 20,
                    color: const Color(0xFFD4A017),
                    shadows: [
                      Shadow(
                          color: Colors.white.withOpacity(0.8),
                          blurRadius: 2),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 22,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              game.title.isNotEmpty ? game.title : '未命名游戏',
              style: AppStyles.gameTitle.copyWith(fontSize: 18),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (game.developer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              game.developer,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                color: AppColors.secondaryText.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildFallbackCover() {
    try {
      final coverFile = GameDataFormat.findCoverFile(game.pathForCover);
      if (coverFile != null) {
        return Image.file(
          coverFile,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        );
      }
    } catch (e) {}

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFFE9E0D1),
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 40,
          color: const Color(0xFF8B7355).withOpacity(0.4),
        ),
      ),
    );
  }
}
