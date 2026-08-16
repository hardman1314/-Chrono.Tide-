import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/locale_service.dart';
import '../services/magpie_service.dart';
import '../services/shortcut_service.dart';
import '../services/exe_scanner.dart';
import 'interactive_wrapper.dart';

class ExeSelectorDialog extends StatefulWidget {
  final String gameDirectory;
  final String? initialExePath;
  final String initialLocaleMode;
  final String initialUpscalingMode;
  final ValueChanged<String> onSelected;
  final ValueChanged<String>? onLocaleModeChanged;
  final ValueChanged<String>? onUpscalingModeChanged;
  final String? gameTitle;
  final String? metaDataDir;

  const ExeSelectorDialog({
    super.key,
    required this.gameDirectory,
    this.initialExePath,
    this.initialLocaleMode = 'none',
    this.initialUpscalingMode = 'none',
    required this.onSelected,
    this.onLocaleModeChanged,
    this.onUpscalingModeChanged,
    this.gameTitle,
    this.metaDataDir,
  });

  static Future<void> show({
    required BuildContext context,
    required String gameDirectory,
    String? initialExePath,
    String initialLocaleMode = 'none',
    String initialUpscalingMode = 'none',
    required ValueChanged<String> onSelected,
    ValueChanged<String>? onLocaleModeChanged,
    ValueChanged<String>? onUpscalingModeChanged,
    String? gameTitle,
    String? metaDataDir,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => ExeSelectorDialog(
        gameDirectory: gameDirectory,
        initialExePath: initialExePath,
        initialLocaleMode: initialLocaleMode,
        initialUpscalingMode: initialUpscalingMode,
        onSelected: onSelected,
        onLocaleModeChanged: onLocaleModeChanged,
        onUpscalingModeChanged: onUpscalingModeChanged,
        gameTitle: gameTitle,
        metaDataDir: metaDataDir,
      ),
    );
  }

  @override
  State<ExeSelectorDialog> createState() => _ExeSelectorDialogState();
}

class _ExeSelectorDialogState extends State<ExeSelectorDialog> {
  List<File> _exeFiles = [];
  File? _selectedFile;
  bool _isLoading = true;
  String _searchQuery = '';
  bool _localeEnabled = false;
  bool _upscalingEnabled = false;
  bool _localeAvailable = false;
  bool _magpieAvailable = false;
  bool _generateShortcut = false;

  @override
  void initState() {
    super.initState();
    _localeEnabled = widget.initialLocaleMode == 'japanese';
    _upscalingEnabled = widget.initialUpscalingMode == 'magpie';
    _scanForExecutables();
    _checkLocaleAvailability();
    _checkMagpieAvailability();
  }

  Future<void> _checkLocaleAvailability() async {
    final available = await LocaleService.isLocaleAvailable();
    if (mounted) setState(() => _localeAvailable = available);
  }

  Future<void> _checkMagpieAvailability() async {
    final available = await MagpieService.instance.isAvailable();
    if (mounted) setState(() => _magpieAvailable = available);
  }

  Future<void> _scanForExecutables() async {
    try {
      final dir = Directory(widget.gameDirectory);
      if (!await dir.exists()) return;
      // UX-26: 改用共享的 ExeScanner 有界扫描，避免大型游戏目录无界递归卡死
      final exeFiles =
          await ExeScanner.scanBounded(dir, maxDepth: 3, maxCount: 200);

      if (mounted) {
        setState(() {
          _exeFiles = exeFiles
            ..sort(
                (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
          if (_exeFiles.isNotEmpty) {
            if (widget.initialExePath != null &&
                _exeFiles.any((f) => f.path == widget.initialExePath)) {
              _selectedFile =
                  _exeFiles.firstWhere((f) => f.path == widget.initialExePath);
            } else {
              _selectedFile = _exeFiles.first;
            }
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('扫描可执行文件失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<File> get _filteredExes {
    if (_searchQuery.isEmpty) return _exeFiles;
    final query = _searchQuery.toLowerCase();
    return _exeFiles
        .where((f) => f.path.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        height: 540,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.border.withOpacity(0.15),
              offset: Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading ? _buildLoading() : _buildContent(),
            ),
            _buildLocaleToggle(),
            Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            _buildUpscalingToggle(),
            Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            if (widget.gameTitle != null) _buildShortcutToggle(),
            if (widget.gameTitle != null)
              Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          Icon(Icons.settings_applications_rounded,
              size: 20, color: AppColors.primaryText.withOpacity(0.7)),
          SizedBox(width: 10),
          Text('选择启动程序',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText)),
          Spacer(),
          Text('${_filteredExes.length} 个程序',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: AppColors.secondaryText)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: TextStyle(fontFamily: 'Inter', fontSize: 13),
        decoration: InputDecoration(
          hintText: '搜索程序名...',
          hintStyle: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: AppColors.placeholderText),
          prefixIcon:
              Icon(Icons.search, size: 18, color: AppColors.secondaryText),
          isDense: true,
          filled: true,
          fillColor: AppColors.background,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final exes = _filteredExes;
    if (exes.isEmpty) return _buildEmpty();

    return Column(
      children: [
        _buildSearchBar(),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: exes.length,
            itemBuilder: (_, index) => _buildExeItem(exes[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildExeItem(File file) {
    final isSelected = file.path == _selectedFile?.path;
    final fileName = file.path.split('\\').last;
    final relativePath =
        file.path.replaceFirst('${widget.gameDirectory}\\', '');

    return InteractiveWrapper(
      onTap: () => setState(() => _selectedFile = file),
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 2),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryText.withOpacity(0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryText.withOpacity(0.3)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primaryText.withOpacity(0.1)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.play_arrow_rounded,
                  size: 16,
                  color: isSelected
                      ? AppColors.primaryText
                      : AppColors.secondaryText),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(fileName,
                      style: TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 13.5,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w600,
                          color: AppColors.primaryText)),
                  SizedBox(height: 2),
                  Text(relativePath,
                      style: TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 12,
                          color: AppColors.secondaryText)),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded,
                  size: 18, color: AppColors.primaryText.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _buildLocaleToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(Icons.language_rounded,
              size: 18,
              color: _localeEnabled
                  ? const Color(0xFFE91E63)
                  : AppColors.secondaryText),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('日语转区启动',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (!_localeAvailable && _localeEnabled)
                  Text('⚠ 未检测到转区引擎，请先安装 Locale Emulator',
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: const Color(0xFFE65100))),
              ],
            ),
          ),
          Switch.adaptive(
            value: _localeEnabled,
            activeColor: const Color(0xFFE91E63),
            onChanged: (value) {
              setState(() => _localeEnabled = value);
              widget.onLocaleModeChanged?.call(value ? 'japanese' : 'none');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUpscalingToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          Icon(Icons.auto_fix_high_rounded,
              size: 18,
              color: _upscalingEnabled
                  ? const Color(0xFF7C4DFF)
                  : AppColors.secondaryText),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('超分启动',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (!_magpieAvailable && _upscalingEnabled)
                  Text('⚠ 未检测到 Magpie，请在偏好设置中配置',
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: const Color(0xFFEF6C00))),
              ],
            ),
          ),
          Switch.adaptive(
            value: _upscalingEnabled,
            activeColor: const Color(0xFF7C4DFF),
            onChanged: (value) {
              setState(() => _upscalingEnabled = value);
              widget.onUpscalingModeChanged?.call(value ? 'magpie' : 'none');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Icon(Icons.desktop_windows_rounded,
              size: 18,
              color: _generateShortcut
                  ? AppColors.successGreen
                  : AppColors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('生成桌面快捷方式',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                Text('双击桌面图标即可直接启动游戏',
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11.5,
                        color: AppColors.secondaryText)),
              ],
            ),
          ),
          Switch.adaptive(
            value: _generateShortcut,
            activeColor: AppColors.successGreen,
            onChanged: (value) {
              setState(() => _generateShortcut = value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_rounded,
              size: 48, color: AppColors.secondaryText.withOpacity(0.3)),
          SizedBox(height: 12),
          Text('未找到可执行文件',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText)),
          SizedBox(height: 6),
          Text('请确认游戏目录是否正确',
              style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 12.5,
                  color: AppColors.secondaryText.withOpacity(0.7))),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(child: CircularProgressIndicator(color: AppColors.border));
  }

  Widget _buildFooter() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildButton('取消', () => Navigator.pop(context), isPrimary: false),
          SizedBox(width: 12),
          _buildButton('确定', _handleConfirm, isPrimary: true),
        ],
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback onTap,
      {required bool isPrimary}) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 9),
        decoration: BoxDecoration(
          color: isPrimary
              ? AppColors.primaryText
              : AppColors.primaryText.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isPrimary ? Colors.white : AppColors.primaryText)),
      ),
    );
  }

  void _handleConfirm() async {
    if (_selectedFile != null) {
      widget.onSelected(_selectedFile!.path);

      // 如果勾选了生成快捷方式，且有游戏标题信息
      if (_generateShortcut &&
          widget.gameTitle != null &&
          widget.gameTitle!.isNotEmpty) {
        await ShortcutService.instance.createShortcut(
          gameTitle: widget.gameTitle!,
          exePath: _selectedFile!.path,
          gameDirectory: widget.gameDirectory,
          localeMode: _localeEnabled ? 'japanese' : 'none',
          upscalingMode: _upscalingEnabled ? 'magpie' : 'none',
        );
      }
    }
    Navigator.of(context).pop();
  }
}
