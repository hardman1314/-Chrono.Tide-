import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../services/install_path_preference.dart';
import '../services/local_game_registry.dart';
import '../services/path_validator.dart';
import 'package:file_picker/file_picker.dart';
import 'interactive_wrapper.dart';

enum InstallConfirmationResult { confirmed, cancelled }

class InstallConfirmationDialog extends StatefulWidget {
  final String gameTitle;
  final String? gameCoverUrl;
  final String? gameDescription;
  final List<String>? gameTags;
  final ValueChanged<String?> onPathChanged;

  const InstallConfirmationDialog({
    super.key,
    required this.gameTitle,
    this.gameCoverUrl,
    this.gameDescription,
    this.gameTags,
    required this.onPathChanged,
  });

  static Future<InstallConfirmationResult?> show({
    required BuildContext context,
    required String gameTitle,
    String? gameCoverUrl,
    String? gameDescription,
    List<String>? gameTags,
  }) async {
    String? selectedPath;

    final result = await showDialog<InstallConfirmationResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => InstallConfirmationDialog(
        gameTitle: gameTitle,
        gameCoverUrl: gameCoverUrl,
        gameDescription: gameDescription,
        gameTags: gameTags,
        onPathChanged: (path) {
          selectedPath = path;
        },
      ),
    );

    if (result == InstallConfirmationResult.confirmed) {
      if (selectedPath != null && selectedPath!.isNotEmpty) {
        await InstallPathPreference.instance.setLastUsedLocation(selectedPath);
      } else {
        await InstallPathPreference.instance.setLastUsedLocation(null);
      }
    }

    return result;
  }

  @override
  State<InstallConfirmationDialog> createState() =>
      _InstallConfirmationDialogState();
}

class _InstallConfirmationDialogState extends State<InstallConfirmationDialog> {
  String? _selectedLocation;
  bool _isLoadingPath = false;
  String? _pathValidationError;
  ValidationResult? _pathValidationResult;

  @override
  void initState() {
    super.initState();
    _loadDefaultPath();
  }

  Future<void> _loadDefaultPath() async {
    final defaultPath =
        await InstallPathPreference.instance.getDefaultGameLocation();

    if (!mounted) return;

    setState(() {
      _selectedLocation = defaultPath;
    });
  }

  Future<void> _browseLocation() async {
    setState(() {
      _isLoadingPath = true;
      _pathValidationError = null;
    });

    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择游戏存放位置',
      );

      if (!mounted) return;

      if (result != null) {
        final validation = PathValidator.validateCustomGameLocation(result);

        if (!mounted) return;

        if (validation.isValid) {
          setState(() {
            _selectedLocation = result;
            _pathValidationResult = validation;
            _pathValidationError = null;
          });
          widget.onPathChanged?.call(result);
        } else {
          setState(() {
            _selectedLocation = result;
            _pathValidationError = validation.message;
            _pathValidationResult = validation;
          });
        }
      }
    } catch (e) {
      debugPrint('[INSTALL-DIALOG] 选择目录失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPath = false;
        });
      }
    }
  }

  void _useDefaultLocation() {
    setState(() {
      _selectedLocation = null;
    });
    widget.onPathChanged?.call(null);
  }

  String _getFullPath() {
    if (_selectedLocation != null) {
      return '$_selectedLocation\\${widget.gameTitle}';
    }
    return '${LocalGameRegistry.gamesBaseDir}\\${widget.gameTitle}';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 580,
          constraints: const BoxConstraints(maxHeight: 700),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildGameInfoCard(),
                      const SizedBox(height: 24),
                      _buildLocationSelector(),
                      const SizedBox(height: 16),
                      _buildPathPreview(),
                    ],
                  ),
                ),
              ),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(Icons.download_outlined, size: 22, color: AppColors.border),
          const SizedBox(width: 12),
          Text(
            '确认安装',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 18,
              height: 26 / 18,
              color: AppColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameInfoCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.buttonBackground,
              border: Border.all(color: AppColors.border, width: 1.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.gameCoverUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      widget.gameCoverUrl!,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildDefaultIcon(),
                    ),
                  )
                : _buildDefaultIcon(),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.gameTitle,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    height: 24 / 17,
                    color: AppColors.primaryText,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.gameTags != null && widget.gameTags!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: widget.gameTags!
                        .take(3)
                        .map((tag) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.selectedBlue.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                tag,
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                  color: AppColors.selectedBlue,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultIcon() {
    return Center(
      child: Icon(Icons.videogame_asset_outlined,
          size: 32, color: AppColors.secondaryText.withOpacity(0.5)),
    );
  }

  Widget _buildLocationSelector() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 1.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 18, color: AppColors.secondaryText),
              const SizedBox(width: 8),
              Text(
                '游戏本体位置',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  height: 20 / 14,
                  color: AppColors.secondaryText,
                ),
              ),
              const Spacer(),
              Text(
                '可自定义',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w400,
                  fontSize: 11,
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: InteractiveWrapper(
                  onTap: _browseLocation,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border: Border.all(color: AppColors.border, width: 1.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        if (_isLoadingPath)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.border),
                            ),
                          )
                        else
                          Icon(Icons.folder_open,
                              size: 16, color: AppColors.border),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selectedLocation ?? LocalGameRegistry.gamesBaseDir,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                              height: 18 / 13,
                              color: _selectedLocation != null
                                  ? AppColors.primaryText
                                  : AppColors.secondaryText.withOpacity(0.6),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InteractiveWrapper(
                onTap: _useDefaultLocation,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    border: Border.all(
                        color: AppColors.border.withOpacity(0.3), width: 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '默认',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_pathValidationError != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE6EA),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: AppColors.dangerRed),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pathValidationError!,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        color: AppColors.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.help,
              child: Tooltip(
                message: '游戏资源文件(EXE、图像等)将存放在此处\n元数据(game.json等)固定存放在项目目录',
                child: Icon(
                  Icons.info_outline,
                  size: 15,
                  color: AppColors.secondaryText.withOpacity(0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathPreview() {
    final fullPath = _getFullPath();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border.withOpacity(0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '完整安装路径预览',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
              fontSize: 11,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            fullPath,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: AppColors.primaryText,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border, width: 1.4),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          InteractiveWrapper(
            onTap: () =>
                Navigator.pop(context, InstallConfirmationResult.cancelled),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.4),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                '取消',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          InteractiveWrapper(
            onTap: _pathValidationError != null
                ? null
                : () =>
                    Navigator.pop(context, InstallConfirmationResult.confirmed),
            cursor: _pathValidationError != null
                ? SystemMouseCursors.forbidden
                : SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 11),
              decoration: BoxDecoration(
                color: _pathValidationError != null
                    ? AppColors.secondaryText.withOpacity(0.3)
                    : AppColors.selectedBlue,
                border: Border.all(color: const Color(0x1A000000), width: 1.4),
                boxShadow: _pathValidationError != null
                    ? []
                    : [
                        BoxShadow(
                          color: AppColors.primaryText,
                          offset: const Offset(2, 2),
                          blurRadius: 0,
                        ),
                      ],
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download,
                      size: 16,
                      color: _pathValidationError != null
                          ? Colors.white54
                          : Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    '开始安装',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
