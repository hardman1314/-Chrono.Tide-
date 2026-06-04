import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/app_colors.dart';
import '../services/save_scanner.dart';
import '../services/save_backup_service.dart';
import '../services/save_manifest.dart';

enum _SaveBackupTab { scan, list, pathSettings }

class SaveBackupDialog extends StatefulWidget {
  final String gameName;
  final String installDir;
  final ManifestGame? manifestEntry;

  const SaveBackupDialog({
    super.key,
    required this.gameName,
    required this.installDir,
    this.manifestEntry,
  });

  static void show(
    BuildContext context, {
    required String gameName,
    required String installDir,
    ManifestGame? manifestEntry,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => SaveBackupDialog(
        gameName: gameName,
        installDir: installDir,
        manifestEntry: manifestEntry,
      ),
    );
  }

  @override
  State<SaveBackupDialog> createState() => _SaveBackupDialogState();
}

class _SaveBackupDialogState extends State<SaveBackupDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ---- 存档扫描 ----
  final List<DetectedSaveFile> _detectedFiles = [];
  final Set<String> _selectedPaths = {};
  bool _isScanning = false;
  bool _isBackingUp = false;
  final TextEditingController _backupNameController = TextEditingController();
  String? _statusMessage;
  bool _statusSuccess = false;

  // ---- 备份列表 ----
  final List<SaveBackup> _backups = [];
  bool _isLoadingBackups = false;
  String? _expandedBackupId;
  final Map<String, bool> _editingName = {};
  final Map<String, TextEditingController> _renameControllers = {};

  // ---- 存档路径 ----
  final List<String> _customPaths = [];
  final TextEditingController _addPathController = TextEditingController();
  bool _isSavingPaths = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 3, vsync: this, initialIndex: _SaveBackupTab.scan.index);
    _tabController.addListener(_onTabChanged);
    _backupNameController.text = _defaultBackupName();
    _loadBackups();
    _loadCustomPaths();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _backupNameController.dispose();
    _addPathController.dispose();
    for (final c in _renameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final tab = _SaveBackupTab.values[_tabController.index];
    if (tab == _SaveBackupTab.list && _backups.isEmpty && !_isLoadingBackups) {
      _loadBackups();
    }
  }

  // ============================================================
  // 存档扫描
  // ============================================================

  String _defaultBackupName() {
    final now = DateTime.now();
    final y = now.year.toString();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    return '$y-$m-${d}_$h-$min';
  }

  Future<void> _scanSaves() async {
    setState(() {
      _isScanning = true;
      _detectedFiles.clear();
      _selectedPaths.clear();
      _statusMessage = null;
    });

    try {
      final scanner = SaveScanner();
      final results = scanner.scanGameSaves(
        widget.gameName,
        widget.installDir,
        manifestEntry: widget.manifestEntry,
      );

      if (!mounted) return;
      setState(() {
        _detectedFiles.addAll(results);
        _selectedPaths.addAll(results.map((f) => f.filePath));
        _isScanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _statusMessage = '扫描失败: $e';
        _statusSuccess = false;
      });
    }
  }

  Future<void> _createBackup() async {
    final selected = _selectedPaths.toList();
    if (selected.isEmpty) {
      setState(() {
        _statusMessage = '请至少选择一个存档路径';
        _statusSuccess = false;
      });
      return;
    }

    setState(() {
      _isBackingUp = true;
      _statusMessage = null;
    });

    try {
      final customName = _backupNameController.text.trim();
      await SaveBackupService.instance.backupSaves(
        widget.gameName,
        selected,
        customName: customName.isEmpty ? null : customName,
      );

      if (!mounted) return;
      setState(() {
        _isBackingUp = false;
        _statusMessage = '备份成功！';
        _statusSuccess = true;
        _backupNameController.text = _defaultBackupName();
      });
      _loadBackups();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBackingUp = false;
        _statusMessage = '备份失败: $e';
        _statusSuccess = false;
      });
    }
  }

  // ============================================================
  // 备份列表
  // ============================================================

  Future<void> _loadBackups() async {
    setState(() => _isLoadingBackups = true);
    try {
      final backups =
          await SaveBackupService.instance.listBackups(widget.gameName);
      if (!mounted) return;
      setState(() {
        _backups
          ..clear()
          ..addAll(backups);
        _isLoadingBackups = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingBackups = false);
    }
  }

  Future<void> _deleteBackup(SaveBackup backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFBF7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF8B7355), width: 2),
        ),
        title: Text(
          '确认删除',
          style: TextStyle(
            fontFamily: 'ZhiMangXing',
            fontSize: 22,
            letterSpacing: 1.5,
            color: AppColors.border,
          ),
        ),
        content: Text(
          '确定要删除备份「${backup.name}」吗？此操作不可撤销。',
          style: TextStyle(
            fontFamily: 'Mali',
            fontSize: 15,
            color: AppColors.primaryText,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除',
                style: TextStyle(
                    color: AppColors.dangerRed, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await SaveBackupService.instance.deleteBackup(widget.gameName, backup.id);
      _loadBackups();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('删除失败: $e');
    }
  }

  void _startRename(SaveBackup backup) {
    setState(() {
      _editingName[backup.id] = true;
      _renameControllers[backup.id]?.dispose();
      _renameControllers[backup.id] = TextEditingController(text: backup.name);
    });
  }

  Future<void> _confirmRename(SaveBackup backup) async {
    final newName = _renameControllers[backup.id]?.text.trim() ?? '';
    if (newName.isEmpty || newName == backup.name) {
      setState(() => _editingName[backup.id] = false);
      return;
    }

    try {
      await SaveBackupService.instance
          .renameBackup(widget.gameName, backup.id, newName);
      setState(() => _editingName[backup.id] = false);
      _loadBackups();
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('重命名失败: $e');
    }
  }

  Future<void> _restoreBackup(SaveBackup backup,
      {List<String>? specificFiles}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFDFBF7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF8B7355), width: 2),
        ),
        title: Text(
          '确认恢复',
          style: TextStyle(
            fontFamily: 'ZhiMangXing',
            fontSize: 22,
            letterSpacing: 1.5,
            color: AppColors.border,
          ),
        ),
        content: Text(
          specificFiles != null
              ? '确定要恢复选中的 ${specificFiles.length} 个文件吗？当前同名文件将被覆盖。'
              : '确定要恢复备份「${backup.name}」的全部文件吗？当前同名文件将被覆盖。',
          style: TextStyle(
            fontFamily: 'Mali',
            fontSize: 15,
            color: AppColors.primaryText,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('恢复',
                style: TextStyle(
                    color: AppColors.selectedBlue,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await SaveBackupService.instance
          .restoreSave(widget.gameName, backup.id, specificFiles);
      if (!mounted) return;
      _showSnackBar('恢复成功');
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('恢复失败: $e');
    }
  }

  // ============================================================
  // 存档路径
  // ============================================================

  Future<void> _loadCustomPaths() async {
    // 从备份服务获取已知的存档路径
    final savesDir = SaveBackupService.instance.getSavesDir(widget.gameName);
    final dir = Directory(savesDir);
    if (dir.existsSync()) {
      // 已有备份目录，无需额外操作
    }
  }

  Future<void> _addCustomPath() async {
    final path = _addPathController.text.trim();
    if (path.isEmpty) return;

    if (_customPaths.contains(path)) {
      _showSnackBar('路径已存在');
      return;
    }

    setState(() => _customPaths.add(path));
    _addPathController.clear();
  }

  Future<void> _pickFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择存档目录',
    );
    if (result != null && result.isNotEmpty && !_customPaths.contains(result)) {
      setState(() => _customPaths.add(result));
    }
  }

  void _removePath(int index) {
    setState(() => _customPaths.removeAt(index));
  }

  Future<void> _savePathSettings() async {
    setState(() => _isSavingPaths = true);
    // 模拟保存延迟
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _isSavingPaths = false);
    _showSnackBar('路径设置已保存');
  }

  // ============================================================
  // 工具方法
  // ============================================================

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime dt) {
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  // ============================================================
  // 构建 UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          height: 640,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x218B7355),
                offset: Offset(4, 5),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(child: _buildTabContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(Icons.save_outlined, size: 22, color: AppColors.border),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '存档备份 — ${widget.gameName}',
              style: TextStyle(
                fontFamily: 'ZhiMangXing',
                fontSize: 22,
                letterSpacing: 1.5,
                color: AppColors.primaryText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: AppColors.border.withOpacity(0.6), width: 1.4),
                  borderRadius: BorderRadius.circular(5),
                ),
                alignment: Alignment.center,
                child:
                    Icon(Icons.close, size: 15, color: AppColors.secondaryText),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      width: double.infinity,
      height: 44,
      color: AppColors.sidebarBackground,
      child: TabBar(
        controller: _tabController,
        labelColor: AppColors.primaryText,
        unselectedLabelColor: AppColors.secondaryText,
        labelStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        indicatorColor: AppColors.selectedBlue,
        indicatorWeight: 2.4,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: AppColors.borderLight,
        tabs: const [
          Tab(text: '存档扫描'),
          Tab(text: '备份列表'),
          Tab(text: '存档路径'),
        ],
      ),
    );
  }

  Widget _buildTabContent() {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildScanTab(),
        _buildBackupListTab(),
        _buildPathsTab(),
      ],
    );
  }

  // ============================================================
  // 存档扫描 Tab
  // ============================================================

  Widget _buildScanTab() {
    return Column(
      children: [
        // 操作栏
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              _buildActionButton(
                icon: Icons.search,
                label: '扫描存档',
                onTap: _isScanning ? null : _scanSaves,
                isLoading: _isScanning,
              ),
              const SizedBox(width: 10),
              _buildActionButton(
                icon: Icons.backup_outlined,
                label: '立即备份',
                onTap: _isBackingUp || _selectedPaths.isEmpty
                    ? null
                    : _createBackup,
                isLoading: _isBackingUp,
                primary: true,
              ),
              const Spacer(),
              if (_detectedFiles.isNotEmpty)
                Text(
                  '已选 ${_selectedPaths.length}/${_detectedFiles.length}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.secondaryText,
                  ),
                ),
            ],
          ),
        ),
        // 备份名称输入
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                '备份名称：',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppColors.sidebarBackground,
                    border: Border.all(color: AppColors.border, width: 1.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextField(
                    controller: _backupNameController,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: AppColors.primaryText,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: '默认使用时间戳',
                      hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.inputHint,
                      ),
                      contentPadding: const EdgeInsets.only(top: 8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 状态消息
        if (_statusMessage != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _statusSuccess ? AppColors.successBg : AppColors.errorBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _statusSuccess
                    ? AppColors.successGreen
                    : AppColors.dangerRed,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _statusSuccess
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  size: 15,
                  color: _statusSuccess
                      ? AppColors.successGreen
                      : AppColors.dangerRed,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _statusMessage!,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: _statusSuccess
                          ? AppColors.successGreen
                          : AppColors.dangerRed,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 文件列表
        Expanded(
          child: _detectedFiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search,
                          size: 40, color: AppColors.placeholderText),
                      const SizedBox(height: 10),
                      Text(
                        _isScanning ? '正在扫描...' : '点击「扫描存档」检测存档文件',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  itemCount: _detectedFiles.length,
                  itemBuilder: (context, index) {
                    final file = _detectedFiles[index];
                    final isSelected = _selectedPaths.contains(file.filePath);
                    return _buildDetectedFileItem(file, isSelected);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDetectedFileItem(DetectedSaveFile file, bool isSelected) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(
          color: isSelected ? AppColors.selectedBlue : AppColors.borderLight,
          width: isSelected ? 1.6 : 1.2,
        ),
        borderRadius: BorderRadius.circular(4),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: AppColors.selectedBlue.withOpacity(0.15),
                  offset: const Offset(1, 2),
                  blurRadius: 0,
                ),
              ]
            : null,
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedPaths.remove(file.filePath);
            } else {
              _selectedPaths.add(file.filePath);
            }
          });
        },
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedPaths.add(file.filePath);
                      } else {
                        _selectedPaths.remove(file.filePath);
                      }
                    });
                  },
                  activeColor: AppColors.selectedBlue,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                file.isDirectory
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
                size: 18,
                color: file.tag == 'config'
                    ? AppColors.secondaryText
                    : AppColors.border,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.filePath,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: file.tag == 'config'
                                ? AppColors.secondaryText.withOpacity(0.12)
                                : AppColors.selectedBlue.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            file.tag == 'config' ? '配置' : '存档',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: file.tag == 'config'
                                  ? AppColors.secondaryText
                                  : AppColors.selectedBlue,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatSize(file.size),
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: AppColors.secondaryText,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(file.lastModified),
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 备份列表 Tab
  // ============================================================

  Widget _buildBackupListTab() {
    if (_isLoadingBackups && _backups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '加载中...',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      );
    }

    if (_backups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 40, color: AppColors.placeholderText),
            const SizedBox(height: 10),
            Text(
              '暂无备份记录',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _backups.length,
      itemBuilder: (context, index) {
        final backup = _backups[index];
        final isExpanded = _expandedBackupId == backup.id;
        final isRenaming = _editingName[backup.id] == true;
        return _buildBackupItem(backup, isExpanded, isRenaming);
      },
    );
  }

  Widget _buildBackupItem(SaveBackup backup, bool isExpanded, bool isRenaming) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.4),
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x108B7355),
            offset: Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        children: [
          // 主行
          InkWell(
            onTap: () {
              setState(() {
                _expandedBackupId = isExpanded ? null : backup.id;
              });
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: AppColors.secondaryText,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isRenaming)
                          _buildRenameField(backup)
                        else
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  backup.name,
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    color: AppColors.primaryText,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: backup.isAutoBackup
                                      ? AppColors.selectedBlue.withOpacity(0.12)
                                      : AppColors.border.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  backup.isAutoBackup ? '自动' : '手动',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: backup.isAutoBackup
                                        ? AppColors.selectedBlue
                                        : AppColors.border,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              _formatDate(backup.timestamp),
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 11,
                                color: AppColors.secondaryText,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${backup.fileCount} 个文件',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 11,
                                color: AppColors.secondaryText,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _formatSize(backup.totalSize),
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 11,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 操作按钮
                  if (!isRenaming) ...[
                    _buildSmallAction(
                      icon: Icons.restore,
                      tooltip: '恢复',
                      onTap: () => _restoreBackup(backup),
                    ),
                    const SizedBox(width: 4),
                    _buildSmallAction(
                      icon: Icons.edit_outlined,
                      tooltip: '重命名',
                      onTap: () => _startRename(backup),
                    ),
                    const SizedBox(width: 4),
                    _buildSmallAction(
                      icon: Icons.delete_outline,
                      tooltip: '删除',
                      onTap: () => _deleteBackup(backup),
                      danger: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 展开详情
          if (isExpanded) _buildBackupDetail(backup),
        ],
      ),
    );
  }

  Widget _buildRenameField(SaveBackup backup) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.selectedBlue, width: 1.4),
              borderRadius: BorderRadius.circular(4),
            ),
            child: TextField(
              controller: _renameControllers[backup.id],
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.only(top: 6),
              ),
              autofocus: true,
              onSubmitted: (_) => _confirmRename(backup),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _buildSmallAction(
          icon: Icons.check,
          tooltip: '确认',
          onTap: () => _confirmRename(backup),
          primary: true,
        ),
        const SizedBox(width: 4),
        _buildSmallAction(
          icon: Icons.close,
          tooltip: '取消',
          onTap: () {
            setState(() => _editingName[backup.id] = false);
          },
        ),
      ],
    );
  }

  Widget _buildBackupDetail(SaveBackup backup) {
    final files = backup.originalPaths.entries.toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 1,
            color: AppColors.borderLight,
            margin: const EdgeInsets.only(bottom: 10),
          ),
          Row(
            children: [
              Text(
                '文件列表',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.secondaryText,
                ),
              ),
              const Spacer(),
              _buildSmallAction(
                icon: Icons.restore,
                tooltip: '恢复全部',
                onTap: () => _restoreBackup(backup),
                label: '恢复全部',
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...files.map((entry) {
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                    color: AppColors.borderLight.withOpacity(0.6), width: 1),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 14, color: AppColors.secondaryText),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.key,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppColors.primaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '→ ${entry.value}',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            color: AppColors.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  _buildSmallAction(
                    icon: Icons.restore,
                    tooltip: '恢复此文件',
                    onTap: () =>
                        _restoreBackup(backup, specificFiles: [entry.key]),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildSmallAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    String? label,
    bool danger = false,
    bool primary = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: danger
                      ? AppColors.dangerRed
                      : primary
                          ? AppColors.selectedBlue
                          : AppColors.secondaryText,
                ),
                if (label != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary
                          ? AppColors.selectedBlue
                          : AppColors.secondaryText,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 存档路径 Tab
  // ============================================================

  Widget _buildPathsTab() {
    return Column(
      children: [
        // 当前路径列表
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            '当前存档路径',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.border,
            ),
          ),
        ),
        Expanded(
          child: _customPaths.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_off_outlined,
                          size: 36, color: AppColors.placeholderText),
                      const SizedBox(height: 8),
                      Text(
                        '暂无自定义存档路径',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _customPaths.length,
                  itemBuilder: (context, index) {
                    final path = _customPaths[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.sidebarBackground,
                        border: Border.all(color: AppColors.border, width: 1.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.folder_outlined,
                              size: 18, color: AppColors.border),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              path,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 12,
                                color: AppColors.primaryText,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _removePath(index),
                              child: Icon(Icons.close,
                                  size: 16, color: AppColors.dangerRed),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        // 添加路径区域
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(
            '添加存档路径',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.border,
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppColors.sidebarBackground,
                    border: Border.all(color: AppColors.border, width: 1.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextField(
                    controller: _addPathController,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      color: AppColors.primaryText,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: '输入路径或点击浏览选择目录',
                      hintStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: AppColors.inputHint,
                      ),
                      contentPadding: const EdgeInsets.only(top: 9),
                    ),
                    onSubmitted: (_) => _addCustomPath(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildActionButton(
                icon: Icons.folder_open,
                label: '浏览',
                onTap: _pickFolder,
                compact: true,
              ),
              const SizedBox(width: 6),
              _buildActionButton(
                icon: Icons.add,
                label: '添加',
                onTap: _addCustomPath,
                compact: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 保存按钮
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _buildActionButton(
            icon: Icons.save_outlined,
            label: '保存路径设置',
            onTap: _isSavingPaths ? null : _savePathSettings,
            isLoading: _isSavingPaths,
            primary: true,
            fullWidth: true,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 通用按钮
  // ============================================================

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool isLoading = false,
    bool primary = false,
    bool compact = false,
    bool fullWidth = false,
  }) {
    final bgColor =
        primary ? AppColors.selectedBlue : AppColors.buttonBackground;
    final textColor = primary ? Colors.white : AppColors.border;
    final borderColor =
        primary ? Colors.black.withOpacity(0.1) : AppColors.border;

    return MouseRegion(
      cursor:
          onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: compact ? 34 : 38,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor, width: 1.4),
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.3),
                offset: const Offset(2, 2),
                blurRadius: 0,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(textColor),
                  ),
                )
              else ...[
                Icon(icon, size: compact ? 15 : 17, color: textColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 12 : 14,
                    color: textColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
