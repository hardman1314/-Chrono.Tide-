import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/game_data_format.dart';
import '../services/locale_service.dart';
import '../services/path_validator.dart';
import '../services/local_game_registry.dart';
import '../utils/game_config_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/file_size_service.dart';
import '../services/magpie_service.dart';
import '../services/metadata_fetcher.dart';
import '../services/screenshot_fetch_service.dart';
import '../services/cover_download_service.dart';
import 'screenshot_carousel.dart';
import 'interactive_wrapper.dart';
import 'app_dialog.dart';

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

  bool _isEditing = false;
  bool _launchHovered = false;
  bool _openDirHovered = false;
  bool _editHovered = false;
  bool _saveHovered = false;
  bool _cancelHovered = false;
  bool _launchMenuOpen = false;
  bool _scrapeHovered = false;

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

  bool _isLaunching = false;
  String _launchStatus = '';
  double _launchProgress = 0.0;
  bool _tagsExpanded = false;

  bool _magpieAvailable = false;
  String _upscalingMode = 'none'; // 'none' | 'magpie'

  String _directorySize = '';
  bool _isCalculatingSize = false;
  List<String> _screenshotFiles = [];

  late AnimationController _loadingController;
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

    _loadingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

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
    _loadingController.dispose();
    _menuController.dispose();
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
          _firstOpenedAt = data.firstOpenedAt;
          _lastOpenedAt = data.lastOpenedAt;
          _isLoading = false;
          // 加载截图
          _screenshotFiles = GameDataFormat.findScreenshotFiles(_metaDataDir);
        });
        _titleController.text = data.title;
        _descController.text = data.description;
        _tagsController.text = data.tags.join(', ');
        _developerController.text = data.developer;
        _calculateDirectorySize();
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
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

  Future<void> _performLaunch(
      {bool useLocale = false, bool useUpscaling = false}) async {
    if (_isLaunching) return;

    // 启动时自动切换：未入坑 → 游玩中
    if (_playStatus == PlayStatus.notStarted) {
      _setPlayStatus(PlayStatus.inProgress);
    }

    // 根据持久化的模式决定是否使用超分/转区
    final shouldUpscale = useUpscaling || _upscalingMode == 'magpie';
    final shouldLocale = useLocale || _localeMode == 'japanese';

    setState(() {
      _isLaunching = true;
      String statusText = '正在启动游戏...';
      if (shouldUpscale && shouldLocale) {
        statusText = '正在超分转区启动游戏...';
      } else if (shouldUpscale) {
        statusText = '正在超分启动游戏...';
      } else if (shouldLocale) {
        statusText = '正在转区启动游戏...';
      }
      _launchStatus = statusText;
      _launchProgress = 0.0;
    });

    for (int i = 0; i <= 100; i += 10) {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      setState(() => _launchProgress = i / 100);
    }

    await Future.delayed(const Duration(milliseconds: 300));

    if (shouldUpscale && _launchPath.isNotEmpty) {
      final resolvedExe =
          GameDataFormat.resolveLaunchPath(_launchPath, _gameDirectoryPath);
      if (resolvedExe.isNotEmpty) {
        final success = await MagpieService.instance.startGameWithUpscaling(
          gameExePath: resolvedExe,
          gameTitle: _title,
          localeMode: shouldLocale ? 'japanese' : 'none',
        );

        if (mounted) {
          setState(() {
            _isLaunching = false;
            _launchProgress = 0.0;
          });
        }

        if (success) {
          // 注册游玩时长追踪会话（超分启动无法通过 launchGame 创建会话，需手动注册）
          // ★ 检查返回值：若失败，时长将不记录（游戏已启动，无法回退）
          final trackingOk =
              await LocalGameRegistry.instance.startPlayTimeTracking(
            _title,
            exePath: resolvedExe,
          );
          if (!trackingOk) {
            debugPrint('[DETAIL-DIALOG] ⚠️ 超分启动成功但会话注册失败，时长将不记录');
          }
          // 超分启动成功，游戏已由 MagpieService 启动
          // 只关闭弹窗，不再调用 onLaunchGame 避免重复启动
          if (mounted) {
            Navigator.of(context).pop();
          }
        } else if (MagpieService.instance.fallbackOnFail) {
          // 回退到普通启动：关闭弹窗，让 library_page 的 _executeLaunch 来启动
          if (shouldLocale) {
            _launchWithLocale();
          } else {
            _launchNormal();
          }
        }
        return;
      }
    }

    if (shouldLocale) {
      _launchWithLocale();
    } else {
      _launchNormal();
    }

    if (mounted) {
      setState(() {
        _isLaunching = false;
        _launchProgress = 0.0;
      });
    }
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _titleController.text = _title;
      _descController.text = _description;
      _tagsController.text = _tags.join(', ');
      _developerController.text = _developer;
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

  Future<void> _exitEditMode({bool save = false}) async {
    if (save) {
      final newTitle = _titleController.text.trim();
      final newDesc = _descController.text.trim();
      final newTagsText = _tagsController.text.trim();
      final newTags = newTagsText.isEmpty
          ? <String>[]
          : newTagsText
              .split(RegExp(r'[,\s，]+'))
              .where((t) => t.isNotEmpty)
              .toList();
      final newDeveloper = _developerController.text.trim();

      // 先更新标题（可能重命名元数据文件夹，metaDataDir 会变）
      if (newTitle != _title) {
        // 迁移 GameConfigManager 配置（配置文件名基于标题，标题变更后需迁移）
        try {
          final oldConfig =
              await GameConfigManager.instance.getLaunchPath(_title);
          if (oldConfig != null && oldConfig.isNotEmpty) {
            await GameConfigManager.instance
                .saveLaunchPath(newTitle, oldConfig);
            await GameConfigManager.instance.removeConfig(_title);
          }
          // 迁移 SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          final oldSpPath = prefs.getString('default_exe_$_title');
          if (oldSpPath != null && oldSpPath.isNotEmpty) {
            await prefs.setString('default_exe_$newTitle', oldSpPath);
            await prefs.remove('default_exe_$_title');
          }
        } catch (e) {
          debugPrint('[EDIT] ⚠️ 迁移启动配置失败: $e');
        }

        await LocalGameRegistry.instance.updateGameTitle(_title, newTitle);
      }

      // 获取更新后的 metaDataDir（标题变更后可能已改变）
      final updatedGame = LocalGameRegistry.instance.getGameByTitle(newTitle);
      final currentMetaDataDir = updatedGame?.metaDataDir ?? _metaDataDir;

      // 更新其他字段到（可能已变更的）元数据目录
      await GameDataFormat.updateGameJson(currentMetaDataDir, {
        'description': newDesc,
        'tags': newTags,
        'developer': newDeveloper,
      });

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

  void _launchNormal() {
    Navigator.of(context).pop();
    widget.onLaunchGame?.call();
  }

  void _launchWithLocale() {
    setState(() => _localeMode = 'japanese');
    widget.onLocaleModeChanged?.call('japanese');
    Navigator.of(context).pop();
    widget.onLaunchGame?.call();
  }

  void _setLocaleMode(String mode) {
    setState(() => _localeMode = mode);
    widget.onLocaleModeChanged?.call(mode);
    GameDataFormat.updateGameJson(_metaDataDir, {'locale_mode': mode});
  }

  void _setUpscalingMode(String mode) {
    setState(() => _upscalingMode = mode);
    widget.onUpscalingModeChanged?.call(mode);
    GameDataFormat.updateGameJson(_metaDataDir, {'upscaling_mode': mode});
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

  /// 更换游戏目录：用户已在资源管理器里手动挪完文件夹，软件只改路径引用、不复制文件。
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('更换失败: ${relinkResult.errorMessage ?? '未知错误'}'),
                duration: const Duration(seconds: 5),
                backgroundColor: AppColors.dangerRed,
              ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已更换游戏目录到: $result$detectedHint'),
              duration: const Duration(seconds: 3),
              backgroundColor: AppColors.infoBlue,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('更换失败: $e'),
              duration: const Duration(seconds: 5),
              backgroundColor: AppColors.dangerRed,
            ),
          );
        }
      }
    }
  }

  Future<void> _showMoveLocationDialog() async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _MoveLocationDialog(
        currentLocation: _gameDirectoryPath,
        gameTitle: _title,
        metaDataDir: _metaDataDir,
      ),
    );

    if (result != null && result.isNotEmpty && result != _gameDirectoryPath) {
      try {
        final newDir = Directory(result);
        if (!await newDir.exists()) {
          await newDir.create(recursive: true);
        }

        final currentDir = Directory(_gameDirectoryPath);
        if (await currentDir.exists()) {
          await for (final entity in currentDir.list()) {
            try {
              if (entity is File) {
                await entity.copy('$result/${entity.path.split('\\').last}');
              } else if (entity is Directory) {
                await _copyDirectory(
                    entity, '$result/${entity.path.split('\\').last}');
              }
            } catch (e) {
              debugPrint('[MOVE] 复制文件失败: ${entity.path} | $e');
            }
          }
        }

        setState(() {
          _gameDirectoryPath = result;
        });

        await LocalGameRegistry.instance.updateGameLocation(
          gameTitle: _title,
          newDirectoryPath: result,
        );

        // 同步 GameConfigManager + SharedPreferences（从注册表重读最新 launchPath）
        await _resyncLauncherConfig(_title);

        // 从注册表获取更新后的 launchPath，确保 dialog 状态与注册表一致
        final updatedGame = LocalGameRegistry.instance.getGameByTitle(_title);
        if (updatedGame != null && mounted) {
          setState(() {
            _launchPath = updatedGame.launchPath;
          });
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('游戏位置已更新到: $result'),
            duration: const Duration(seconds: 3),
            backgroundColor: AppColors.infoBlue,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('移动失败: $e'),
            duration: const Duration(seconds: 5),
            backgroundColor: AppColors.dangerRed,
          ),
        );
      }
    }
  }

  Future<void> _copyDirectory(Directory source, String targetPath) async {
    final targetDir = Directory(targetPath);
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    await for (final entity in source.list(recursive: true)) {
      final relativePath = entity.path.substring(source.path.length + 1);
      final newPath = '$targetPath\\$relativePath';

      if (entity is File) {
        final newFile = File(newPath);
        await newFile.parent.create(recursive: true);
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await Directory(newPath).create(recursive: true);
      }
    }
  }

  /// 同步 GameConfigManager 与 SharedPreferences 中的启动路径配置。
  ///
  /// **移动/更换游戏目录后共用**：从注册表重读 service 层最终写入的 launchPath
  /// （而非用旧 config 的 exeName），保证 relink 时 detector 切换了 exe 也能正确同步。
  Future<void> _resyncLauncherConfig(String gameTitle) async {
    try {
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      if (game == null) {
        debugPrint('[RESYNC] ⚠️ 未找到游戏: $gameTitle');
        return;
      }

      final absoluteLaunchPath = GameDataFormat.resolveLaunchPath(
          game.launchPath, game.directoryPath);
      final prefs = await SharedPreferences.getInstance();

      if (absoluteLaunchPath.isNotEmpty) {
        // service 层 launchPath 在磁盘上确实存在 → 同步到 GameConfigManager + prefs
        await GameConfigManager.instance.saveLaunchPath(
            gameTitle, absoluteLaunchPath);
        await prefs.setString('default_exe_$gameTitle', absoluteLaunchPath);
        debugPrint('[RESYNC] ✅ 已同步启动配置: $absoluteLaunchPath');
      } else {
        // service 层 launchPath 在新目录无效（relink detector 失败 / 文件被改名）
        // 清除旧配置，让 launchGame 走自动检测
        await GameConfigManager.instance.removeConfig(gameTitle);
        await prefs.remove('default_exe_$gameTitle');
        debugPrint('[RESYNC] ⚠️ launchPath 在新目录无效，已清除旧配置，将走自动检测');
      }
    } catch (e) {
      debugPrint('[RESYNC] ⚠️ 同步 GameConfigManager 失败: $e');
    }
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
    setState(() => _playStatus = status);
    final statusStr = status == PlayStatus.notStarted
        ? 'not_started'
        : status == PlayStatus.inProgress
            ? 'in_progress'
            : status == PlayStatus.dropped
                ? 'dropped'
                : 'completed';
    await GameDataFormat.setPlayStatus(_metaDataDir, statusStr);
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

          await sourceFile.copy(targetPath);

          setState(() {
            _coverFile = coverFileName;
          });

          GameDataFormat.updateGameJson(_metaDataDir, {
            'cover_file': coverFileName,
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('封面图已更新'),
              duration: const Duration(seconds: 2),
              backgroundColor: AppColors.infoBlue,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[GAME-DETAIL] 更换封面失败: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('更换封面失败: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: AppColors.dangerRed,
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请先输入游戏标题'),
          duration: const Duration(seconds: 2),
          backgroundColor: AppColors.dangerRed,
        ),
      );
      return;
    }

    setState(() {
      _isScraping = true;
      _scrapeResults = [];
      _selectedScrapeResult = null;
    });

    try {
      final results = await MetadataFetcher.fetchGame(query);
      if (mounted) {
        setState(() {
          _isScraping = false;
          _scrapeResults = results;
          _scrapePanelOpen = results.isNotEmpty;
        });
        if (results.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('未找到匹配的元数据'),
              duration: const Duration(seconds: 2),
              backgroundColor: AppColors.secondaryText,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isScraping = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('元数据抓取失败: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: AppColors.dangerRed,
          ),
        );
      }
    }
  }

  void _applyScrapeResult(Map<String, dynamic> result) {
    final updatedFields = <String>[];
    final lockedFields = <String>[];

    // Title
    if (!_titleLocked) {
      final name = result['game_name'] as String? ?? '';
      if (name.isNotEmpty) {
        _titleController.text = name;
        _title = name;
        updatedFields.add('标题');
      }
    } else {
      lockedFields.add('标题');
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(messages.join(' | ')),
          duration: const Duration(seconds: 3),
          backgroundColor: AppColors.infoBlue,
        ),
      );
    }
  }

  Future<void> _downloadCoverFromUrl(String url) async {
    // Phase 3.1: 委托给统一的 CoverDownloadService
    // 原实现硬编码 'cover.png'，即使源图是 jpg/webp 也存为 png，扩展名与内容不符
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
    } else {
      debugPrint('[GAME-DETAIL] 封面下载失败: $url');
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

  Widget? _resolveCoverImage() {
    if (_coverFile.isNotEmpty) {
      final coverPath = '$_metaDataDir/${_coverFile}';
      final file = File(coverPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        );
      }
    }

    final altCover = GameDataFormat.findCoverFile(_metaDataDir);
    if (altCover != null) {
      return Image.file(
        altCover,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
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

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background.withOpacity(0.95),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(0, 8),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _loadingController,
                  builder: (context, child) {
                    return Transform.rotate(
                      angle: _loadingController.value * 6.283,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(
                            colors: [
                              AppColors.brandBlue,
                              AppColors.brandBlue.withOpacity(0.3),
                            ],
                            stops: [
                              _loadingController.value,
                              _loadingController.value
                            ],
                          ),
                          border: Border.all(
                            color: AppColors.placeholderCover,
                            width: 3,
                          ),
                        ),
                        child: Icon(
                          _localeMode == 'japanese'
                              ? Icons.language_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          color: AppColors.brandBlue,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  _launchStatus,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.titleBrown,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _launchProgress,
                    backgroundColor: AppColors.placeholderCover,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _localeMode == 'japanese'
                          ? const Color(0xFFE91E63)
                          : AppColors.brandBlue,
                    ),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${(_launchProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
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
            borderRadius: BorderRadius.circular(14),
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
                if (_isLaunching) _buildLoadingOverlay(),
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

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
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
                                            fontFamily: 'Inter',
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white,
                                          )),
                                    ],
                                  ),
                                ),
                              ),
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
                    child: coverImage ?? _buildPlaceholderCover(),
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
                _performLaunch(useLocale: _localeMode == 'japanese');
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
                            fontFamily: 'Inter',
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
                        fontFamily: 'Inter',
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
                    onTap: () {
                      _closeMenu();
                      _setLocaleMode('none');
                      _setUpscalingMode('none');
                      _performLaunch();
                    },
                    iconColor: AppColors.brandBlue,
                  ),
                  Divider(height: 1, color: AppColors.placeholderCover),
                  _buildMenuItem(
                    icon: Icons.language_rounded,
                    label: '日语转区启动',
                    isSelected:
                        _localeMode == 'japanese' && _upscalingMode == 'none',
                    onTap: () {
                      _closeMenu();
                      _setLocaleMode('japanese');
                      _setUpscalingMode('none');
                      _performLaunch();
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
                    onTap: () {
                      _closeMenu();
                      _setUpscalingMode('magpie');
                      _setLocaleMode('none');
                      _performLaunch();
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
                    onTap: () {
                      _closeMenu();
                      _setUpscalingMode('magpie');
                      _setLocaleMode('japanese');
                      _performLaunch();
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
                        fontFamily: 'Inter',
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
                    fontFamily: 'Inter',
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
        ScreenshotCarousel(
          paths: _screenshotFiles,
          isNetwork: false,
          gameTitle: _title.isNotEmpty ? _title : null,
        ),
        if (_description.isNotEmpty || _isEditing) ...[
          const SizedBox(height: 14),
          _buildDescription(),
        ],
      ],
    );
  }

  Widget _buildTitleSection() {
    if (_isEditing) {
      return Stack(
        children: [
          TextField(
            controller: _titleController,
            style: TextStyle(
              fontFamily: 'ZhiMangXing',
              fontSize: 24,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              color: AppColors.titleBrown,
            ),
            decoration: InputDecoration(
              contentPadding: EdgeInsets.only(right: 32),
              isDense: true,
              border: InputBorder.none,
              hintText: '输入游戏标题',
              hintStyle: TextStyle(
                fontFamily: 'ZhiMangXing',
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
              lockedTip: '已锁定：抓取元数据时保留标题',
              unlockedTip: '未锁定：抓取元数据时会覆盖标题',
            ),
          ),
        ],
      );
    }
    return Text(
      _title.isNotEmpty ? _title : '未知游戏',
      style: TextStyle(
        fontFamily: 'ZhiMangXing',
        fontSize: 24,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.2,
        color: AppColors.titleBrown,
      ),
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
          _metaRowWithRightWidget(
            leftLabel: '安装日期',
            leftValue: _formattedDate,
            rightWidget: const SizedBox.shrink(),
          ),
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
          // 第一行：状态 + 时长
          Row(
            children: [
              // 游玩状态
              _buildPlayStatusDropdown(),
              const Spacer(),
              // 游玩时长
              Text('游玩时长',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: AppColors.secondaryText.withOpacity(0.7),
                  )),
              const SizedBox(width: 6),
              Text(_formattedPlayTime,
                  style: TextStyle(
                    fontFamily: 'Mali',
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
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.secondaryText.withOpacity(0.6),
            )),
        Text(formatted,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.primaryText.withOpacity(0.7),
            )),
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
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        if (leftValue.isNotEmpty)
          Expanded(
            child: Text(leftValue,
                style: TextStyle(
                  fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
                                fontFamily: 'Inter',
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
                    fontFamily: 'Inter',
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
                  fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
            child: TextField(
              controller: _developerController,
              style: TextStyle(
                fontFamily: 'Inter',
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
                  fontFamily: 'Inter',
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
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        Expanded(
          child: Text(_developer,
              style: TextStyle(
                fontFamily: 'Inter',
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
                    fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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

    final shouldShowExpand = _tags.length > 12;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              constraints: BoxConstraints(
                maxHeight: _tagsExpanded ? double.infinity : 120,
              ),
              child: shouldShowExpand && !_tagsExpanded
                  ? ClipRect(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _tags
                            .take(12)
                            .map((tag) => _buildTagChip(tag))
                            .toList(),
                      ),
                    )
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _tags.map((tag) => _buildTagChip(tag)).toList(),
                    ),
            );
          },
        ),
        if (shouldShowExpand)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => setState(() => _tagsExpanded = !_tagsExpanded),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.placeholderCover,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _tagsExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: AppColors.border,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _tagsExpanded ? '收起标签' : '展开全部 (${_tags.length}个)',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.border,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTagChip(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.placeholderCover,
        border: Border.all(color: AppColors.borderLight, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12.5,
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
                    fontFamily: 'Inter',
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
          SizedBox(
            height: 110,
            child: ListView.separated(
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
                  ? CachedNetworkImage(
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
                        fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
                        fontFamily: 'Inter',
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
                    fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 8),
        Text(_description,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75,
            )),
      ],
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
          borderRadius: BorderRadius.circular(14),
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
                      fontFamily: 'Inter',
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    style: TextStyle(
                      fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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
                            fontFamily: 'Inter',
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
                        fontFamily: 'Inter',
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
                fontFamily: 'Inter',
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
                  child: Text('游戏文件将被移动到:\n$_newLocation\\${widget.gameTitle}',
                      style: TextStyle(
                        fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
                          fontFamily: 'Inter',
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
                                    fontFamily: 'Inter',
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('准备移动失败: $e'),
        backgroundColor: AppColors.dangerRed,
      ));
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
          borderRadius: BorderRadius.circular(14),
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
                      fontFamily: 'Inter',
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    style: TextStyle(
                      fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
              fontFamily: 'Inter',
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
                            fontFamily: 'Inter',
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
                        fontFamily: 'Inter',
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
                        fontFamily: 'Inter',
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
                      fontFamily: 'Inter',
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
                          fontFamily: 'Inter',
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
                                    fontFamily: 'Inter',
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
                border: Border.all(color: AppColors.border, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border.withOpacity(0.13),
                    offset: const Offset(4, 5),
                    blurRadius: 0,
                  ),
                ],
                color: AppColors.background,
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
                      fontFamily: 'Inter',
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
