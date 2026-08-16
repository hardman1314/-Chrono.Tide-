import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/locale_service.dart';
import '../services/magpie_service.dart';
import '../services/shortcut_service.dart';
import '../services/icon_extractor_service.dart';
import '../services/game_data_format.dart';
import '../services/exe_scanner.dart';
import 'interactive_wrapper.dart';
import 'app_dialog.dart';

/// 启动管理对话框
///
/// 整合了三个核心功能：
/// 1. 启动程序选择（从游戏目录扫描 exe）
/// 2. 启动模式设置（转区 / 超分）
/// 3. 桌面快捷方式管理（创建/删除/图标自定义）
class LaunchManagerDialog extends StatefulWidget {
  final String gameTitle;
  final String gameDirectory;
  final String metaDataDir;
  final String? initialExePath;
  final String initialLocaleMode;
  final String initialUpscalingMode;
  final ValueChanged<String> onExeSelected;
  final ValueChanged<String>? onLocaleModeChanged;
  final ValueChanged<String>? onUpscalingModeChanged;

  const LaunchManagerDialog({
    super.key,
    required this.gameTitle,
    required this.gameDirectory,
    required this.metaDataDir,
    this.initialExePath,
    this.initialLocaleMode = 'none',
    this.initialUpscalingMode = 'none',
    required this.onExeSelected,
    this.onLocaleModeChanged,
    this.onUpscalingModeChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required String gameTitle,
    required String gameDirectory,
    required String metaDataDir,
    String? initialExePath,
    String initialLocaleMode = 'none',
    String initialUpscalingMode = 'none',
    required ValueChanged<String> onExeSelected,
    ValueChanged<String>? onLocaleModeChanged,
    ValueChanged<String>? onUpscalingModeChanged,
  }) async {
    await showAppDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => LaunchManagerDialog(
        gameTitle: gameTitle,
        gameDirectory: gameDirectory,
        metaDataDir: metaDataDir,
        initialExePath: initialExePath,
        initialLocaleMode: initialLocaleMode,
        initialUpscalingMode: initialUpscalingMode,
        onExeSelected: onExeSelected,
        onLocaleModeChanged: onLocaleModeChanged,
        onUpscalingModeChanged: onUpscalingModeChanged,
      ),
    );
  }

  @override
  State<LaunchManagerDialog> createState() => _LaunchManagerDialogState();
}

class _LaunchManagerDialogState extends State<LaunchManagerDialog> {
  // EXE 选择相关
  List<File> _exeFiles = [];
  File? _selectedFile;
  bool _isLoading = true;
  String _searchQuery = '';

  // 启动模式
  bool _localeEnabled = false;
  bool _upscalingEnabled = false;
  bool _localeAvailable = false;
  bool _magpieAvailable = false;

  // 快捷方式相关
  bool _hasShortcut = false;
  bool _isProcessingShortcut = false;
  // 首次启动自动生成快捷方式（默认开启，与 game.json auto_create_shortcut 字段绑定）
  bool _autoCreateShortcut = true;

  // 图标设置
  IconSource _iconSource = IconSource.exeDefault;

  @override
  void initState() {
    super.initState();
    _localeEnabled = widget.initialLocaleMode == 'japanese';
    _upscalingEnabled = widget.initialUpscalingMode == 'magpie';
    _scanForExecutables();
    _checkLocaleAvailability();
    _checkMagpieAvailability();
    _checkShortcutStatus();
  }

  Future<void> _checkLocaleAvailability() async {
    final available = await LocaleService.isLocaleAvailable();
    if (mounted) setState(() => _localeAvailable = available);
  }

  Future<void> _checkMagpieAvailability() async {
    final available = await MagpieService.instance.isAvailable();
    if (mounted) setState(() => _magpieAvailable = available);
  }

  Future<void> _checkShortcutStatus() async {
    final hasShortcut = ShortcutService.instance.hasShortcut(widget.gameTitle);
    final hasCustomIcon =
        IconExtractorService.instance.hasCustomIcon(widget.metaDataDir);

    // 读取 game.json 中的自定义图标路径与快捷方式路径
    final jsonData = await GameDataFormat.readGameJson(widget.metaDataDir);
    final customIconPath = jsonData?.customIconPath ?? '';
    final storedShortcutPath = jsonData?.shortcutPath ?? '';
    // 读取"首次启动自动生成"选项（默认 true，与 game.json 字段绑定）
    final autoCreateShortcut = jsonData?.autoCreateShortcut ?? true;

    // ★ 一致性修复：.lnk 不存在但 shortcut_path 非空 → 清空 shortcut_path
    // 触发场景：用户从文件资源管理器手动删除 .lnk，此时 game.json 字段已陈旧
    if (!hasShortcut && storedShortcutPath.isNotEmpty) {
      try {
        await GameDataFormat.updateGameJson(widget.metaDataDir, {
          'shortcut_path': '',
        });
        debugPrint('[SHORTCUT] 已清理陈旧的 shortcut_path: $storedShortcutPath');
      } catch (e) {
        debugPrint('[SHORTCUT] 清理 shortcut_path 异常: $e');
      }
    }

    if (mounted) {
      setState(() {
        _hasShortcut = hasShortcut;
        _autoCreateShortcut = autoCreateShortcut;
        _iconSource = (hasCustomIcon || customIconPath.isNotEmpty)
            ? IconSource.coverCustom
            : IconSource.exeDefault;
      });
    }
  }

  Future<void> _scanForExecutables() async {
    try {
      final dir = Directory(widget.gameDirectory);
      if (!await dir.exists()) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      // 限制扫描深度（3层）和数量（200个），避免大目录卡死
      // UX-26: 改用共享的 ExeScanner，消除与 ExeSelectorDialog 的重复实现
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

  /// 获取当前选中 exe 的解析路径
  String get _currentExePath => _selectedFile?.path ?? '';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 580,
        height: 640,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.border.withOpacity(0.15),
              offset: const Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading
                  ? _buildLoading()
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildExeSection(),
                          _buildDivider(),
                          _buildLaunchModeSection(),
                          _buildDivider(),
                          _buildShortcutSection(),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded,
              size: 20, color: AppColors.primaryText.withOpacity(0.7)),
          const SizedBox(width: 10),
          Text('启动管理',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText)),
          const SizedBox(width: 8),
          Text('· ${widget.gameTitle}',
              style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13,
                  color: AppColors.secondaryText)),
          const Spacer(),
          InteractiveWrapper(
            onTap: () => Navigator.pop(context),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 18, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 启动程序选择 ====================

  Widget _buildExeSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.folder_open_rounded,
            title: '启动程序选择',
            trailing: '${_filteredExes.length} 个程序',
          ),
          const SizedBox(height: 10),
          _buildSearchBar(),
          const SizedBox(height: 8),
          _exeFiles.isEmpty
              ? _buildEmptyExe()
              : SizedBox(
                  height: 180,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: _filteredExes.length,
                    itemBuilder: (_, index) =>
                        _buildExeItem(_filteredExes[index]),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      onChanged: (v) => setState(() => _searchQuery = v),
      style: const TextStyle(fontFamily: 'Inter', fontSize: 13),
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
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
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primaryText.withOpacity(0.1)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.play_arrow_rounded,
                  size: 15,
                  color: isSelected
                      ? AppColors.primaryText
                      : AppColors.secondaryText),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(fileName,
                      style: TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText)),
                  const SizedBox(height: 2),
                  Text(relativePath,
                      style: TextStyle(
                          fontFamily: 'Mali',
                          fontSize: 11.5,
                          color: AppColors.secondaryText)),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppColors.primaryText.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyExe() {
    return SizedBox(
      height: 100,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_rounded,
                size: 36, color: AppColors.secondaryText.withOpacity(0.3)),
            const SizedBox(height: 8),
            Text('未找到可执行文件',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.secondaryText)),
          ],
        ),
      ),
    );
  }

  // ==================== 启动模式 ====================

  Widget _buildLaunchModeSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.rocket_launch_rounded,
            title: '启动模式',
          ),
          const SizedBox(height: 8),
          _buildToggleRow(
            icon: Icons.language_rounded,
            iconColor: _localeEnabled ? const Color(0xFFE91E63) : null,
            title: '日语转区启动',
            subtitle:
                _localeAvailable ? '使用 Locale Emulator 以日区运行' : '⚠ 未检测到转区引擎',
            subtitleColor: !_localeAvailable ? const Color(0xFFE65100) : null,
            value: _localeEnabled,
            activeColor: const Color(0xFFE91E63),
            onChanged: (value) {
              setState(() => _localeEnabled = value);
              widget.onLocaleModeChanged?.call(value ? 'japanese' : 'none');
            },
          ),
          const SizedBox(height: 4),
          _buildToggleRow(
            icon: Icons.auto_fix_high_rounded,
            iconColor: _upscalingEnabled ? const Color(0xFF7C4DFF) : null,
            title: '超分启动',
            subtitle: _magpieAvailable ? '使用 Magpie 进行超分辨率缩放' : '⚠ 未检测到 Magpie',
            subtitleColor: !_magpieAvailable ? const Color(0xFFEF6C00) : null,
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

  Widget _buildToggleRow({
    required IconData icon,
    Color? iconColor,
    required String title,
    String? subtitle,
    Color? subtitleColor,
    required bool value,
    required Color activeColor,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor ?? AppColors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (subtitle != null)
                  Text(subtitle,
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11.5,
                          color: subtitleColor ?? AppColors.secondaryText)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: activeColor,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  // ==================== 桌面快捷方式 ====================

  Widget _buildShortcutSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.desktop_windows_rounded,
            title: '桌面快捷方式',
            trailing: _hasShortcut ? '✓ 已生成' : '未生成',
            trailingColor: _hasShortcut ? AppColors.successGreen : null,
          ),
          const SizedBox(height: 8),
          // ★ 首次启动自动生成开关（默认勾选，与 game.json auto_create_shortcut 字段绑定）
          // 只有勾选时，首次启动游戏才会自动生成桌面快捷方式
          _buildToggleRow(
            icon: Icons.auto_awesome_rounded,
            iconColor:
                _autoCreateShortcut ? AppColors.primaryText : null,
            title: '首次启动自动生成',
            subtitle: _autoCreateShortcut
                ? '首次启动游戏时自动创建桌面快捷方式'
                : '已关闭，需手动生成桌面快捷方式',
            value: _autoCreateShortcut,
            activeColor: AppColors.primaryText,
            onChanged: (value) async {
              setState(() => _autoCreateShortcut = value);
              try {
                await GameDataFormat.updateGameJson(widget.metaDataDir, {
                  'auto_create_shortcut': value,
                });
              } catch (e) {
                debugPrint('[SHORTCUT] 保存 auto_create_shortcut 异常: $e');
              }
            },
          ),
          const SizedBox(height: 6),
          // 图标设置
          if (_hasShortcut || _selectedFile != null) ...[
            Text('图标设置',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            _buildIconSourceOption(
              value: IconSource.exeDefault,
              title: '使用程序自带图标',
              subtitle: '从选中的 exe 文件提取图标',
            ),
            _buildIconSourceOption(
              value: IconSource.coverCustom,
              title: '使用封面图作为图标',
              subtitle: '从游戏封面裁剪中心区域生成图标',
            ),
            const SizedBox(height: 10),
          ],
          // 操作按钮
          Row(
            children: [
              if (_hasShortcut) ...[
                Expanded(
                  child: _buildActionButton(
                    label: '重新生成',
                    icon: Icons.refresh_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleCreateShortcut,
                    isPrimary: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildActionButton(
                    label: '删除快捷方式',
                    icon: Icons.delete_outline_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleDeleteShortcut,
                    isPrimary: false,
                    danger: true,
                  ),
                ),
              ] else
                Expanded(
                  child: _buildActionButton(
                    label: '生成桌面快捷方式',
                    icon: Icons.add_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleCreateShortcut,
                    isPrimary: true,
                  ),
                ),
            ],
          ),
          if (_isProcessingShortcut)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIconSourceOption({
    required IconSource value,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _iconSource == value;
    return InteractiveWrapper(
      onTap: () => setState(() => _iconSource = value),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryText.withOpacity(0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryText.withOpacity(0.25)
                : AppColors.border.withOpacity(0.15),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color:
                  isSelected ? AppColors.primaryText : AppColors.secondaryText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText)),
                  Text(subtitle,
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          color: AppColors.secondaryText)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 快捷方式操作 ====================

  /// 应用快捷方式设置（图标源处理 + 保存图标路径 + 创建 .lnk）
  ///
  /// 抽取自 [_handleCreateShortcut]，供创建/重新生成/保存时自动同步共用。
  /// 返回是否创建成功。
  Future<bool> _applyShortcut() async {
    String? customIconPath;

    // 如果选择使用封面图标，先生成 ico 文件
    if (_iconSource == IconSource.coverCustom) {
      final coverFile = GameDataFormat.findCoverFile(widget.metaDataDir);
      if (coverFile != null) {
        customIconPath =
            IconExtractorService.instance.getCustomIconPath(widget.metaDataDir);
        final success = await IconExtractorService.instance.convertCoverToIco(
          coverPath: coverFile.path,
          outputPath: customIconPath,
        );
        if (!success) {
          _showSnackBar('封面图标转换失败，将使用程序默认图标');
          customIconPath = null;
        }
      } else {
        _showSnackBar('未找到封面图片，将使用程序默认图标');
      }
    } else {
      // 使用程序图标，删除已有的自定义图标
      await IconExtractorService.instance.deleteCustomIcon(widget.metaDataDir);
    }

    // 保存图标路径到 game.json
    await GameDataFormat.updateGameJson(widget.metaDataDir, {
      'custom_icon_path': customIconPath ?? '',
    });

    // 创建快捷方式
    return ShortcutService.instance.createShortcut(
      gameTitle: widget.gameTitle,
      exePath: _currentExePath,
      gameDirectory: widget.gameDirectory,
      customIconPath: customIconPath,
      localeMode: _localeEnabled ? 'japanese' : 'none',
      upscalingMode: _upscalingEnabled ? 'magpie' : 'none',
    );
  }

  Future<void> _handleCreateShortcut() async {
    if (_currentExePath.isEmpty) {
      _showSnackBar('请先选择启动程序');
      return;
    }

    setState(() => _isProcessingShortcut = true);

    try {
      final success = await _applyShortcut();
      if (success) {
        setState(() {
          _hasShortcut = true;
        });
        _showSnackBar('桌面快捷方式已生成');
      } else {
        _showSnackBar('快捷方式创建失败');
      }
    } catch (e) {
      _showSnackBar('操作失败: $e');
    } finally {
      if (mounted) setState(() => _isProcessingShortcut = false);
    }
  }

  Future<void> _handleDeleteShortcut() async {
    setState(() => _isProcessingShortcut = true);

    try {
      final success =
          await ShortcutService.instance.deleteShortcut(widget.gameTitle);
      if (success) {
        // 同时删除自定义图标
        await IconExtractorService.instance
            .deleteCustomIcon(widget.metaDataDir);
        await GameDataFormat.updateGameJson(widget.metaDataDir, {
          'custom_icon_path': '',
        });

        setState(() {
          _hasShortcut = false;
          _iconSource = IconSource.exeDefault;
        });
        _showSnackBar('桌面快捷方式已删除');
      } else {
        _showSnackBar('未找到快捷方式');
      }
    } catch (e) {
      _showSnackBar('操作失败: $e');
    } finally {
      if (mounted) setState(() => _isProcessingShortcut = false);
    }
  }

  // ==================== 通用组件 ====================

  Widget _buildSectionTitle({
    required IconData icon,
    required String title,
    String? trailing,
    Color? trailingColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.secondaryText),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText)),
        const Spacer(),
        if (trailing != null)
          Text(trailing,
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: trailingColor ?? AppColors.secondaryText)),
      ],
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Divider(height: 1, color: AppColors.border.withOpacity(0.2)),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    required bool isPrimary,
    bool danger = false,
  }) {
    final isDisabled = onPressed == null;
    Color bgColor;
    Color textColor;

    if (isDisabled) {
      bgColor = AppColors.primaryText.withOpacity(0.05);
      textColor = AppColors.secondaryText.withOpacity(0.5);
    } else if (danger) {
      bgColor = AppColors.dangerRed.withOpacity(0.08);
      textColor = AppColors.dangerRed;
    } else if (isPrimary) {
      bgColor = AppColors.primaryText;
      textColor = Colors.white;
    } else {
      bgColor = AppColors.primaryText.withOpacity(0.08);
      textColor = AppColors.primaryText;
    }

    return InteractiveWrapper(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(child: CircularProgressIndicator(color: AppColors.border));
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildActionButton(
            label: '取消',
            icon: Icons.close_rounded,
            onPressed: () => Navigator.pop(context),
            isPrimary: false,
          ),
          const SizedBox(width: 12),
          _buildActionButton(
            label: '保存并关闭',
            icon: Icons.check_rounded,
            onPressed: _handleSave,
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  void _handleSave() {
    _handleSaveAsync();
  }

  /// 保存设置并关闭对话框
  ///
  /// 若桌面快捷方式已存在且 exe 路径或启动模式发生变化，会自动重新生成
  /// 快捷方式以保持同步（仅 SnackBar 提示，不打扰用户）。
  Future<void> _handleSaveAsync() async {
    final selectedExePath = _selectedFile?.path ?? '';

    // 检查 exe 路径或启动模式是否变化（与 widget 初始值对比）
    final exeChanged =
        selectedExePath.isNotEmpty && selectedExePath != widget.initialExePath;
    final localeChanged =
        (_localeEnabled ? 'japanese' : 'none') != widget.initialLocaleMode;
    final upscalingChanged =
        (_upscalingEnabled ? 'magpie' : 'none') != widget.initialUpscalingMode;
    final needsShortcutSync =
        _hasShortcut && (exeChanged || localeChanged || upscalingChanged);

    // 1. 通知父组件 exe 选择（原逻辑，保持同步执行）
    if (_selectedFile != null) {
      widget.onExeSelected(_selectedFile!.path);
    }

    // 2. 自动同步快捷方式（仅当已生成且关键属性变化时）
    if (needsShortcutSync && selectedExePath.isNotEmpty) {
      setState(() => _isProcessingShortcut = true);
      try {
        final success = await _applyShortcut();
        if (success) {
          _showSnackBar('桌面快捷方式已自动同步更新');
        } else {
          _showSnackBar('快捷方式同步失败，请手动点击"重新生成"');
        }
      } catch (e) {
        _showSnackBar('快捷方式同步失败: $e');
      } finally {
        if (mounted) setState(() => _isProcessingShortcut = false);
      }
    }

    if (mounted) Navigator.of(context).pop();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// 图标来源选项
enum IconSource {
  /// 使用 exe 自带图标
  exeDefault,

  /// 使用封面图裁剪生成
  coverCustom,
}
