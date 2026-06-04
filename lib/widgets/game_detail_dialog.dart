import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/app_colors.dart';
import '../services/game_data_format.dart';
import '../services/locale_service.dart';
import '../services/path_validator.dart';
import '../services/local_game_registry.dart';
import '../services/file_size_service.dart';

class GameDetailDialog extends StatefulWidget {
  final String directoryPath;
  final VoidCallback? onLaunchGame;
  final ValueChanged<String>? onLocaleModeChanged;
  final String initialLocaleMode;

  const GameDetailDialog({
    super.key,
    required this.directoryPath,
    this.onLaunchGame,
    this.onLocaleModeChanged,
    this.initialLocaleMode = 'none',
  });

  static Future<void> show({
    required BuildContext context,
    required String directoryPath,
    VoidCallback? onLaunchGame,
    ValueChanged<String>? onLocaleModeChanged,
    String initialLocaleMode = 'none',
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => GameDetailDialog(
        directoryPath: directoryPath,
        onLaunchGame: onLaunchGame,
        onLocaleModeChanged: onLocaleModeChanged,
        initialLocaleMode: initialLocaleMode,
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
  int _playTime = 0;
  bool _completed = false;
  bool _isLoading = true;
  bool _localeAvailable = false;
  String _localeMode = 'none';
  String _developer = '';

  bool _isEditing = false;
  bool _launchHovered = false;
  bool _openDirHovered = false;
  bool _editHovered = false;
  bool _saveHovered = false;
  bool _cancelHovered = false;
  bool _launchMenuOpen = false;

  bool _isLaunching = false;
  String _launchStatus = '';
  double _launchProgress = 0.0;
  bool _tagsExpanded = false;

  String _directorySize = '';
  bool _isCalculatingSize = false;

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
  }

  @override
  void dispose() {
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
      final data = await GameDataFormat.readGameJson(widget.directoryPath);
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
          _playTime = data.playTime;
          _completed = data.completed;
          if (data.localeMode.isNotEmpty) _localeMode = data.localeMode;
          _developer = data.developer;
          _isLoading = false;
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

  Future<void> _performLaunch({bool useLocale = false}) async {
    if (_isLaunching) return;

    setState(() {
      _isLaunching = true;
      _launchStatus = useLocale ? '🌸 正在转区启动游戏...' : '🎮 正在启动游戏...';
      _launchProgress = 0.0;
    });

    for (int i = 0; i <= 100; i += 10) {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      setState(() => _launchProgress = i / 100);
    }

    await Future.delayed(const Duration(milliseconds: 300));

    if (useLocale) {
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
    });
  }

  void _exitEditMode({bool save = false}) {
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

      GameDataFormat.updateGameJson(widget.directoryPath, {
        'title': newTitle,
        'description': newDesc,
        'tags': newTags,
        'developer': newDeveloper,
      });

      setState(() {
        _title = newTitle;
        _description = newDesc;
        _tags = newTags;
        _developer = newDeveloper;
        _isEditing = false;
      });
    } else {
      setState(() => _isEditing = false);
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
    GameDataFormat.updateGameJson(widget.directoryPath, {'locale_mode': mode});
  }

  Future<void> _showMoveLocationDialog() async {
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _MoveLocationDialog(
        currentLocation: _gameDirectoryPath,
        gameTitle: _title,
        metaDataDir: widget.directoryPath,
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

        await GameDataFormat.updateGameJson(widget.directoryPath, {
          'directory_path': result,
        });

        setState(() {
          _gameDirectoryPath = result;
        });

        LocalGameRegistry.instance.updateGameLocation(
          gameTitle: _title,
          newDirectoryPath: result,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('游戏位置已更新到: $result'),
            duration: const Duration(seconds: 3),
            backgroundColor: const Color(0xFF4A72A5),
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

  void _openDirectory() {
    String targetDir = '';

    if (_launchPath.isNotEmpty) {
      final resolvedExe =
          GameDataFormat.resolveLaunchPath(_launchPath, _gameDirectoryPath);
      if (resolvedExe.isNotEmpty) {
        final exeFile = File(resolvedExe);
        if (exeFile.existsSync()) {
          targetDir = exeFile.parent.path;
        } else {
          final exeDir = Directory(resolvedExe);
          if (exeDir.existsSync()) targetDir = resolvedExe;
        }
      }
    }

    if (targetDir.isEmpty && _gameDirectoryPath.isNotEmpty) {
      final dir = Directory(_gameDirectoryPath);
      if (dir.existsSync()) targetDir = _gameDirectoryPath;
    }
    if (targetDir.isEmpty) targetDir = widget.directoryPath;

    Process.start('explorer', [targetDir]);
  }

  Future<void> _toggleCompleted() async {
    final newValue = !_completed;
    await GameDataFormat.setCompleted(widget.directoryPath, newValue);
    setState(() => _completed = newValue);
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

          final targetDir = Directory(widget.directoryPath);
          if (!targetDir.existsSync()) return;

          final coverFileName = 'cover.png';
          final targetPath = '${widget.directoryPath}/$coverFileName';

          await sourceFile.copy(targetPath);

          setState(() {
            _coverFile = coverFileName;
          });

          GameDataFormat.updateGameJson(widget.directoryPath, {
            'cover_file': coverFileName,
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('封面图已更新'),
              duration: const Duration(seconds: 2),
              backgroundColor: const Color(0xFF4A72A5),
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
    if (_source == 'local_import') return '本地导入';
    return _source;
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
      final coverPath = '${widget.directoryPath}/${_coverFile}';
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

    final altCover = GameDataFormat.findCoverFile(widget.directoryPath);
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
      color: const Color(0xFFE9E0D1),
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 56,
          color: const Color(0xFF8B7355).withOpacity(0.4),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7).withOpacity(0.95),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x208B7355),
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
                              const Color(0xFF6B9EAD),
                              const Color(0xFF6B9EAD).withOpacity(0.3),
                            ],
                            stops: [
                              _loadingController.value,
                              _loadingController.value
                            ],
                          ),
                          border: Border.all(
                            color: const Color(0xFFE9E0D1),
                            width: 3,
                          ),
                        ),
                        child: Icon(
                          _localeMode == 'japanese'
                              ? Icons.language_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          color: const Color(0xFF6B9EAD),
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
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF5C4A3D),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _launchProgress,
                    backgroundColor: const Color(0xFFF0E6D2),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _localeMode == 'japanese'
                          ? const Color(0xFFE91E63)
                          : const Color(0xFF6B9EAD),
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
            color: const Color(0xFFFDFBF7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF8B7355), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0x208B7355),
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
            color: const Color(0xFFE9E0D1),
            border: Border.all(color: const Color(0xFFC4B89A), width: 1),
          ),
          child: Icon(Icons.close_rounded,
              size: 16, color: const Color(0xFF8B7355)),
        ),
      ),
    );
  }

  Widget _buildLeftPanel(Widget? coverImage) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFC4B89A), width: 1),
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
                        color: const Color(0xFFF9F5EE),
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
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          )),
                                    ],
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
                  (coverImage ?? _buildPlaceholderCover()),
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
                          hoverBg: const Color(0xFFE8F5E9),
                          iconColor: const Color(0xFF2E7D32),
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
                          hoverBg: const Color(0xFFFFEBEE),
                          iconColor: const Color(0xFFD4183D),
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
                      ? const Color(0xFFF0E6D2)
                      : (_localeMode == 'japanese'
                          ? const Color(0xFFFCE4EC)
                          : Colors.white),
                  border: Border.all(
                    color: _launchMenuOpen
                        ? AppColors.border
                        : (_localeMode == 'japanese'
                            ? const Color(0xFFF48FB1)
                            : const Color(0xFFD4C4A8)),
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
                          : const Color(0xFF6B9EAD),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _localeMode == 'japanese' ? '🌸 转区启动' : '启动游戏',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: _localeMode == 'japanese'
                            ? const Color(0xFFE91E63)
                            : const Color(0xFF6B9EAD),
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
                    ? const Color(0xFFF0E6D2)
                    : (_localeMode == 'japanese'
                        ? const Color(0xFFFCE4EC)
                        : Colors.white),
                border: Border.all(
                  color: _launchMenuOpen
                      ? AppColors.border
                      : (_localeMode == 'japanese'
                          ? const Color(0xFFF48FB1)
                          : const Color(0xFFD4C4A8)),
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
                    : const Color(0xFF6B9EAD),
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x308B7355),
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
                color: const Color(0xFFE9E0D1),
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
                    isSelected: _localeMode == 'none',
                    onTap: () {
                      _closeMenu();
                      _setLocaleMode('none');
                      _performLaunch(useLocale: false);
                    },
                    iconColor: const Color(0xFF6B9EAD),
                  ),
                  Divider(height: 1, color: const Color(0xFFF0E6D2)),
                  _buildMenuItem(
                    icon: Icons.language_rounded,
                    label: '日语转区启动',
                    isSelected: _localeMode == 'japanese',
                    onTap: () {
                      _closeMenu();
                      _setLocaleMode('japanese');
                      _performLaunch(useLocale: true);
                    },
                    iconColor: const Color(0xFFE91E63),
                    highlightColor: const Color(0xFFFCE4EC),
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
                    ? (highlightColor ?? const Color(0xFFE8F5E9))
                    : (isHovered ? const Color(0xFFFDFBF7) : Colors.white),
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
                            isSelected ? FontWeight.w700 : FontWeight.w600,
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
            color:
                isHovered ? (hoverBg ?? const Color(0xFFF0E6D2)) : Colors.white,
            border: Border.all(
              color: isHovered ? AppColors.border : const Color(0xFFD4C4A8),
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
                          : const Color(0xFF6B9EAD))),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: iconColor ??
                        (isHovered
                            ? AppColors.primaryText
                            : const Color(0xFF6B9EAD)),
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
        _buildTitleSection(),
        const SizedBox(height: 22),
        _buildMetaGrid(),
        const SizedBox(height: 18),
        if (_tags.isNotEmpty || _isEditing) _buildOptimizedTagsRow(),
        if (_description.isNotEmpty || _isEditing) ...[
          const SizedBox(height: 18),
          _buildDescription(),
        ],
      ],
    );
  }

  Widget _buildTitleSection() {
    if (_isEditing) {
      return TextField(
        controller: _titleController,
        style: TextStyle(
          fontFamily: 'Zhi Mang Xing',
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: const Color(0xFF5C4A3D),
        ),
        decoration: InputDecoration(
          contentPadding: EdgeInsets.zero,
          isDense: true,
          border: InputBorder.none,
          hintText: '输入游戏标题',
          hintStyle: TextStyle(
            fontFamily: 'Zhi Mang Xing',
            fontSize: 28,
            color: const Color(0xFFC4B3A1),
          ),
        ),
      );
    }
    return Text(
      _title.isNotEmpty ? _title : '未知游戏',
      style: TextStyle(
        fontFamily: 'Zhi Mang Xing',
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: const Color(0xFF5C4A3D),
      ),
    );
  }

  Widget _buildMetaGrid() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F5EE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE9E0D1)),
      ),
      child: Column(
        children: [
          _metaRowWithRightWidget(
            leftLabel: '来源',
            leftValue: _displaySource,
            rightWidget: _buildCompletedToggle(),
          ),
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '安装日期',
            leftValue: _formattedDate,
            rightWidget: _buildPlayTimeDisplay(),
          ),
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '目录',
            leftValue: _gameDirectoryPath,
            rightWidget: const SizedBox.shrink(),
            isClickable: true,
            onTap: _showMoveLocationDialog,
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
                        size: 16, color: const Color(0xFF6B9EAD))
                    : const SizedBox.shrink()),
          ),
          if (_developer.isNotEmpty || _isEditing) ...[
            const SizedBox(height: 10),
            _buildDeveloperRow(),
          ],
          const SizedBox(height: 10),
          _metaRowWithRightWidget(
            leftLabel: '转区',
            leftValue: '',
            rightWidget: _buildLocaleStatusBadge(),
          ),
        ],
      ),
    );
  }

  Widget _metaRowWithRightWidget({
    required String leftLabel,
    required String leftValue,
    required Widget rightWidget,
    bool isClickable = false,
    VoidCallback? onTap,
  }) {
    final content = Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(leftLabel,
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        if (leftValue.isNotEmpty)
          Expanded(
            child: Text(leftValue,
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
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

  Widget _buildCompletedToggle() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggleCompleted,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color:
                _completed ? const Color(0xFFE8F5E9) : const Color(0xFFEEEEEE),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _completed
                  ? const Color(0xFF81C784)
                  : const Color(0xFFBDBDBD),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _completed
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 14,
                color: _completed
                    ? const Color(0xFF388E3C)
                    : const Color(0xFF9E9E9E),
              ),
              const SizedBox(width: 4),
              Text(
                _completed ? '已通关' : '未通关',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: _completed
                      ? const Color(0xFF388E3C)
                      : const Color(0xFF757575),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayTimeDisplay() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('游玩时间',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: AppColors.secondaryText,
            )),
        Text(_formattedPlayTime,
            style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            )),
      ],
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
                ? const Color(0xFFFCE4EC)
                : (hasEngine
                    ? const Color(0xFFEEEEEE)
                    : const Color(0xFFFFF3E0)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isJapanese
                  ? const Color(0xFFF48FB1)
                  : (hasEngine
                      ? const Color(0xFFBDBDBD)
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
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
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
            child: Text('会社',
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13,
                  color: AppColors.secondaryText,
                )),
          ),
          Expanded(
            child: TextField(
              controller: _developerController,
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                hintText: '输入会社名称',
                hintStyle: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13,
                  color: AppColors.secondaryText.withOpacity(0.5),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: const Color(0xFFE9E0D1), width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: const Color(0xFFE9E0D1), width: 1),
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
                fontFamily: 'Mali',
                fontSize: 13,
                color: AppColors.secondaryText,
              )),
        ),
        Expanded(
          child: Text(_developer,
              style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryText,
              )),
        ),
        SizedBox(
          width: 20,
          height: 20,
          child: Icon(Icons.business_rounded,
              size: 16, color: const Color(0xFF6B9EAD)),
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
          Text('标签（逗号分隔）',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.secondaryText,
              )),
          const SizedBox(height: 6),
          TextField(
            controller: _tagsController,
            style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13,
              color: AppColors.primaryText,
            ),
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF9F5EE),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide:
                    BorderSide(color: const Color(0xFFE9E0D1), width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide:
                    BorderSide(color: const Color(0xFFE9E0D1), width: 1),
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
                    color: const Color(0xFFF9F5EE),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFE9E0D1),
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
                        color: const Color(0xFF8B7355),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _tagsExpanded ? '收起标签' : '展开全部 (${_tags.length}个)',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF8B7355),
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
        color: const Color(0xFFE9E0D1),
        border: Border.all(color: const Color(0xFFC4B89A), width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontFamily: 'Mali',
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.primaryText,
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
          Text('简介',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.secondaryText,
              )),
          const SizedBox(height: 8),
          TextField(
            controller: _descController,
            maxLines: 5,
            minLines: 3,
            style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75,
            ),
            decoration: InputDecoration(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF9F5EE),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: const Color(0xFFE9E0D1), width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: const Color(0xFFE9E0D1), width: 1),
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
              fontWeight: FontWeight.w700,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 8),
        Text(_description,
            style: TextStyle(
              fontFamily: 'Mali',
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
          color: const Color(0xFFFDFBF7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF8B7355), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: const Color(0x208B7355),
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
        color: const Color(0xFFF9F5EE),
        border: Border(
          bottom: BorderSide(color: const Color(0xFFE9E0D1), width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.drive_file_move_rounded,
              size: 24, color: const Color(0xFF6B9EAD)),
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
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    style: TextStyle(
                      fontFamily: 'Mali',
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
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryText,
            )),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE9E0D1)),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_rounded,
                  size: 18, color: const Color(0xFF8B7355)),
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
              fontWeight: FontWeight.w600,
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
                      ? Colors.white
                      : const Color(0xFFFAFAFA),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _pathError != null
                        ? AppColors.dangerRed
                        : (_newLocation != null
                            ? const Color(0xFF6B9EAD)
                            : const Color(0xFFE9E0D1)),
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
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFBDBDBD))),
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
              color: const Color(0xFFFFEBEE),
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
                color: const Color(0xFF4CAF50),
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
                _isBrowsing ? const Color(0xFFE9E0D1) : const Color(0xFF6B9EAD),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6B9EAD).withOpacity(0.2),
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
                      fontWeight: FontWeight.w600,
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: const Color(0xFFE9E0D1), width: 1),
                  ),
                  child: Center(
                    child: Text('取消',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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
                        ? const Color(0xFF6B9EAD)
                        : const Color(0xFFBDBDBD),
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
                                    fontWeight: FontWeight.w600,
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
