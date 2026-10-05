import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../../theme/app_colors.dart';
import '../../../models/watch_folder.dart';
import '../../../services/watch_folder_service.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/nsfw/nsfw_image.dart';
import '../../../widgets/app_snack_bar.dart';

/// 智能导入区UI组件
///
/// 在添加页右侧 SwipeSwitcher 中作为第三种导入模式显示。
/// 包含：监控路径管理、导入设置、发现队列、忽略列表管理。
///
/// 设计目标：解放用户双手 — 用户指定目标文件夹后，
/// 系统实时监测该文件夹及其子目录，自动发现、抓取元数据并入库。
///
/// 发现队列卡片与左侧表单联动（对齐批量导入体验）：
/// - 点击就绪/失败状态的卡片 → 数据同步到左侧表单
/// - 用户在表单中编辑 → 点卡片 ✓ 入库时自动保存编辑
/// - ✓ 入库（完整字段）/ ✗ 忽略 / ↻ 重试失败
class SmartImportSection extends StatefulWidget {
  final VoidCallback? onGameAdded;

  /// 点击卡片选中时回调（JoinPage 将候选数据同步到左侧表单）
  final void Function(ImportCandidate candidate)? onCandidateSelected;

  /// 将左侧表单编辑保存回候选（切换选中 / 入库前调用）
  final void Function(ImportCandidate candidate)? onSaveFormEdits;

  /// 重置左侧表单（选中的候选被移除后调用）
  final VoidCallback? onFormReset;

  const SmartImportSection({
    super.key,
    this.onGameAdded,
    this.onCandidateSelected,
    this.onSaveFormEdits,
    this.onFormReset,
  });

  @override
  State<SmartImportSection> createState() => _SmartImportSectionState();
}

class _SmartImportSectionState extends State<SmartImportSection> {
  /// 当前展开的忽略列表面板（null=不展开）
  bool _showIgnoredPanel = false;

  /// 当前展开排除规则编辑的路径（null=不展开）
  String? _editingExcludePath;

  /// 排除规则编辑控制器
  late TextEditingController _excludeController;

  /// 上一帧是否存在选中的候选（用于检测选中候选被移除）
  bool _hadSelection = false;

  /// ★ IMP-11（2026-09-12 导入审查）：入库进行中标志（防双击/并发重复入库）。
  /// 旧实现无守卫，快速双击"全部入库"会对同一批候选各跑一遍 importCandidate，
  /// 重复写 game.json 并重复注册库条目。
  bool _isConfirming = false;

  @override
  void initState() {
    super.initState();
    _excludeController = TextEditingController();
    _hadSelection =
        WatchFolderService.instance.selectedCandidate != null;
    WatchFolderService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    WatchFolderService.instance.removeListener(_onChanged);
    _excludeController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // 检测选中的候选被移除（入库/忽略/自动入库后）→ 重置左侧表单
    final selected = WatchFolderService.instance.selectedCandidate;
    if (selected == null && _hadSelection) {
      _hadSelection = false;
      widget.onFormReset?.call();
    } else if (selected != null) {
      _hadSelection = true;
    }
    setState(() {});
  }

  /// 添加监控文件夹
  Future<void> _addWatchFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要监控的游戏文件夹',
    );
    if (result == null) return;

    final success = await WatchFolderService.instance.addWatchFolder(result);
    if (!mounted) return;
    AppSnackBar.show(
      context,
      success ? NoticeLevel.success : NoticeLevel.error,
      success ? '已添加监控路径，开始扫描...' : '添加失败，路径不存在或已添加',
    );

    // 添加后立即扫描一次
    if (success) {
      await WatchFolderService.instance.scanAllNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildWatchFoldersCard(),
          const SizedBox(height: 12),
          _buildSettingsCard(),
          const SizedBox(height: 12),
          _buildCandidatesCard(),
          const SizedBox(height: 12),
          _buildIgnoredCard(),
        ],
      ),
    );
  }

  // ==================== 监控文件夹列表卡片 ====================

  Widget _buildWatchFoldersCard() {
    final service = WatchFolderService.instance;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 16, color: AppColors.titleBrown),
              const SizedBox(width: 6),
              Text(
                '监控文件夹',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleBrown,
                ),
              ),
              const Spacer(),
              // 扫描状态指示
              if (service.isScanning)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.titleBrown),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '扫描中 ${service.scanProcessedDirs}/${service.scanTotalDirs}',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              InkWell(
                onTap: _addWatchFolder,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border, width: 1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 12, color: AppColors.titleBrown),
                      const SizedBox(width: 3),
                      Text(
                        '添加',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.titleBrown,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (service.watchFolders.isEmpty)
            _buildEmptyHint('暂无监控路径，点击"添加"选择要监控的游戏文件夹\n系统会自动监测新游戏并入库')
          else
            ...service.watchFolders.map(_buildWatchFolderItem),
        ],
      ),
    );
  }

  /// 单个监控路径项
  Widget _buildWatchFolderItem(WatchFolder folder) {
    final pathExists = Directory(folder.path).existsSync();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 启用开关（紧凑自绘，避免 Switch 被裁剪）
              // 修复:扩大点击区域至 36x24，设置 opaque 行为
              // 修复:重新启用时触发即时扫描，与添加操作逻辑一致
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  final wasEnabled = folder.enabled;
                  await WatchFolderService.instance
                      .toggleFolderEnabled(folder.path);
                  // 刚刚从禁用切为启用 → 触发即时扫描（与添加操作一致）
                  if (!wasEnabled) {
                    await WatchFolderService.instance.scanAllNow();
                  }
                },
                child: SizedBox(
                  width: 36,
                  height: 24,
                  child: Center(
                    child: Container(
                      width: 26,
                      height: 15,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: folder.enabled
                              ? AppColors.successGreen
                              : AppColors.secondaryText.withOpacity(0.4),
                          width: 1,
                        ),
                        color: folder.enabled
                            ? AppColors.successGreen.withOpacity(0.2)
                            : Colors.transparent,
                      ),
                      alignment: folder.enabled
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      padding: const EdgeInsets.all(2),
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: folder.enabled
                              ? AppColors.successGreen
                              : AppColors.secondaryText.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 路径状态图标
              Icon(
                pathExists ? Icons.check_circle : Icons.error_outline,
                size: 12,
                color:
                    pathExists ? AppColors.successGreen : AppColors.dangerRed,
              ),
              const SizedBox(width: 4),
              // 路径
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: folder.enabled
                            ? AppColors.primaryText
                            : AppColors.secondaryText,
                      ),
                    ),
                    Row(
                      children: [
                        if (folder.gameCount > 0)
                          Text(
                            '${folder.gameCount}个游戏',
                            style: TextStyle(
                              fontSize: 9,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        if (folder.gameCount > 0 && folder.lastScanAt != null)
                          Text(' · ',
                              style: TextStyle(
                                  fontSize: 9, color: AppColors.secondaryText)),
                        if (folder.lastScanAt != null)
                          Text(
                            '上次扫描 ${_formatTime(folder.lastScanAt!)}',
                            style: TextStyle(
                              fontSize: 9,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        if (!pathExists)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              '路径失效',
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.dangerRed,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // 排除规则编辑按钮（修复:扩大点击区域至 32x32 + 透明背景使整区域可点击）
              InkWell(
                onTap: () => _toggleExcludeEditor(folder),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  color: Colors.transparent,
                  child: Icon(Icons.tune,
                      size: 16, color: AppColors.secondaryText),
                ),
              ),
              // 删除按钮（修复:扩大点击区域至 32x32 + 透明背景使整区域可点击）
              InkWell(
                onTap: () => _removeWatchFolder(folder),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  color: Colors.transparent,
                  child: Icon(Icons.close,
                      size: 16, color: AppColors.secondaryText),
                ),
              ),
            ],
          ),
          // 排除规则编辑面板
          if (_editingExcludePath == folder.path) _buildExcludeEditor(folder),
        ],
      ),
    );
  }

  /// 排除规则编辑面板
  Widget _buildExcludeEditor(WatchFolder folder) {
    // 修复:不再在 build 中重置 _excludeController.text，
    // 否则扫描期间每 500ms 重建会覆盖用户正在输入的内容。
    // 控制器文本仅在 _toggleExcludeEditor 打开编辑器时设置一次。
    return Container(
      margin: const EdgeInsets.only(top: 4, left: 32),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.4),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: AppColors.border.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '排除目录关键词（逗号分隔，含此关键词的子目录不扫描）',
            style: TextStyle(fontSize: 10, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _excludeController,
            style: TextStyle(fontSize: 11, color: AppColors.primaryText),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: AppColors.border),
              ),
              hintText: 'patch, save, config...',
              hintStyle:
                  TextStyle(fontSize: 10, color: AppColors.secondaryText),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _editingExcludePath = null;
                  });
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    '取消',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.secondaryText),
                  ),
                ),
              ),
              InkWell(
                onTap: () async {
                  final patterns = _excludeController.text
                      .split(',')
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toList();
                  await WatchFolderService.instance
                      .updateExcludePatterns(folder.path, patterns);
                  if (mounted) {
                    setState(() {
                      _editingExcludePath = null;
                    });
                    AppSnackBar.info(
                      context,
                      patterns.isEmpty ? '已清空排除规则' : '排除规则已更新',
                      duration: const Duration(seconds: 2),
                    );
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.titleBrown.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    '保存',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.titleBrown,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _toggleExcludeEditor(WatchFolder folder) {
    setState(() {
      if (_editingExcludePath == folder.path) {
        // 关闭编辑器
        _editingExcludePath = null;
      } else {
        // 打开编辑器：仅在此处设置一次控制器文本，避免 build 期间反复覆盖
        _editingExcludePath = folder.path;
        _excludeController.text = folder.excludePatterns.join(', ');
      }
    });
  }

  // ==================== 导入设置卡片 ====================

  Widget _buildSettingsCard() {
    final service = WatchFolderService.instance;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 16, color: AppColors.titleBrown),
              const SizedBox(width: 6),
              Text(
                '导入设置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleBrown,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 导入模式
          _buildSettingRow(
            label: '发现新游戏时',
            child: Row(
              children: [
                _buildModeRadio(
                  label: '通知确认',
                  value: AutoImportMode.confirm,
                  groupValue: service.importMode,
                  onChanged: service.setImportMode,
                ),
                const SizedBox(width: 12),
                _buildModeRadio(
                  label: '自动入库',
                  value: AutoImportMode.silent,
                  groupValue: service.importMode,
                  onChanged: service.setImportMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 标题锁定
          _buildSettingRow(
            label: '锁定识别标题',
            child: Row(
              children: [
                Switch(
                  value: service.lockTitle,
                  onChanged: service.setLockTitle,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '防止元数据抓取覆盖游戏名称',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 扫描间隔
          _buildSettingRow(
            label: '扫描间隔',
            child: DropdownButton<int>(
              value: service.intervalMinutes,
              underline: const SizedBox.shrink(),
              isDense: true,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.primaryText,
              ),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1分钟')),
                DropdownMenuItem(value: 5, child: Text('5分钟')),
                DropdownMenuItem(value: 10, child: Text('10分钟')),
                DropdownMenuItem(value: 30, child: Text('30分钟')),
              ],
              onChanged: (v) {
                if (v != null) service.setIntervalMinutes(v);
              },
            ),
          ),
          const SizedBox(height: 8),
          // 置信度阈值
          _buildSettingRow(
            label: '识别灵敏度',
            child: DropdownButton<double>(
              value: _nearestThreshold(service.confidenceThreshold),
              underline: const SizedBox.shrink(),
              isDense: true,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.primaryText,
              ),
              items: const [
                DropdownMenuItem(value: 0.15, child: Text('宽松（多识别）')),
                DropdownMenuItem(value: 0.30, child: Text('标准')),
                DropdownMenuItem(value: 0.50, child: Text('严格（少误判）')),
              ],
              onChanged: (v) {
                if (v != null) service.setConfidenceThreshold(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  double _nearestThreshold(double value) {
    const options = [0.15, 0.30, 0.50];
    double nearest = options[0];
    double minDiff = (value - options[0]).abs();
    for (final opt in options) {
      final diff = (value - opt).abs();
      if (diff < minDiff) {
        minDiff = diff;
        nearest = opt;
      }
    }
    return nearest;
  }

  // ==================== 发现队列卡片 ====================

  Widget _buildCandidatesCard() {
    final service = WatchFolderService.instance;
    final candidates = service.candidates;
    final failedCount = candidates
        .where((c) => c.taskStatus == CandidateTaskStatus.failed)
        .length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.playlist_add_check,
                  size: 16, color: AppColors.titleBrown),
              const SizedBox(width: 6),
              Text(
                '发现队列',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleBrown,
                ),
              ),
              if (candidates.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.titleBrown.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${candidates.length}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleBrown,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              // 批量操作按钮
              if (candidates.isNotEmpty) ...[
                if (failedCount > 0) ...[
                  InkWell(
                    onTap: () => WatchFolderService.instance.retryAllFailed(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.titleBrown.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: AppColors.titleBrown.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh,
                              size: 11, color: AppColors.titleBrown),
                          const SizedBox(width: 2),
                          Text(
                            '重试失败($failedCount)',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.titleBrown,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                InkWell(
                  // ★ IMP-11: 入库进行中禁用，防双击触发并发入库
                  onTap: _isConfirming ? null : () => _confirmAllCandidates(),
                  child: Opacity(
                    opacity: _isConfirming ? 0.5 : 1.0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.successGreen.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: AppColors.successGreen.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.done_all,
                              size: 11, color: AppColors.successGreen),
                          const SizedBox(width: 2),
                          Text(
                            '全部入库',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.successGreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => _ignoreAllCandidates(),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      border:
                          Border.all(color: AppColors.border.withOpacity(0.5)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.clear_all,
                            size: 11, color: AppColors.secondaryText),
                        const SizedBox(width: 2),
                        Text(
                          '全部忽略',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              // 立即扫描按钮
              InkWell(
                onTap: service.isScanning
                    ? null
                    : () => WatchFolderService.instance.scanAllNow(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border, width: 1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh,
                          size: 12, color: AppColors.titleBrown),
                      const SizedBox(width: 3),
                      Text(
                        '立即扫描',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.titleBrown,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 扫描进度条
          if (service.isScanning && service.scanTotalDirs > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: service.scanProgress,
                      minHeight: 3,
                      backgroundColor: AppColors.border.withOpacity(0.3),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(AppColors.titleBrown),
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (service.currentScanPath.isNotEmpty)
                    Text(
                      '当前: ${service.currentScanPath.split(RegExp(r'[/\\]')).last}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: AppColors.secondaryText.withOpacity(0.8),
                      ),
                    ),
                ],
              ),
            ),
          if (candidates.isEmpty && !service.isScanning)
            _buildEmptyHint('暂无发现的候选游戏\n将游戏放入监控文件夹后会自动出现在这里')
          else if (candidates.isEmpty && service.isScanning)
            _buildEmptyHint('正在扫描中...')
          else
            // ★ P0-1（2026-09-16 稳定性审计）：候选列表**虚拟化**。
            // 旧实现 `...candidates.map(_buildCandidateItem)` 在
            // SingleChildScrollView + Column 内一次性构建全部条目：
            // 2000 条时每次 notifyListeners（入队/富化完成/进度）都要构建并布局
            // 2000 个卡片 → UI 线程饱和、窗口"未响应"（大规模导入卡死主因之一）。
            // 现改为固定可视高度内用 ListView.builder 惰性构建（只渲染视口项），
            // 卡片外观与交互完全不变。
            SizedBox(
              height: _listViewportHeight(context),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: candidates.length,
                itemBuilder: (context, index) =>
                    _buildCandidateItem(candidates[index]),
              ),
            ),
        ],
      ),
    );
  }

  /// 长列表可视区高度（★ P0-1）
  ///
  /// 取屏幕高度的 55%，并限制在 [260, 640]，保证虚拟化视口内可容纳
  /// 约 5–10 个候选卡片，同时不撑破页面。
  double _listViewportHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.55).clamp(260.0, 640.0);

  /// 单个候选游戏卡片（富卡片：封面 + 状态徽章 + 排重警告 + 表单联动）
  Widget _buildCandidateItem(ImportCandidate candidate) {
    final service = WatchFolderService.instance;
    final isSelected =
        service.selectedCandidate?.dirPath == candidate.dirPath;
    final status = candidate.taskStatus;
    // 待处理/处理中不可选中（元数据未就绪，避免表单联动竞态）
    final selectable =
        status == CandidateTaskStatus.ready ||
            status == CandidateTaskStatus.failed;
    final confidenceColor = _confidenceColor(candidate.confidence);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: selectable ? () => _selectCandidate(candidate) : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? AppColors.titleBrown
                  : AppColors.border.withOpacity(0.5),
              width: isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(4),
            color: isSelected
                ? AppColors.titleBrown.withOpacity(0.05)
                : Colors.transparent,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面缩略图
              _buildCoverThumb(candidate),
              const SizedBox(width: 8),
              // 信息区
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题 + 状态徽章
                    Row(
                      children: [
                        if (service.lockTitle)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Icon(Icons.lock,
                                size: 10,
                                color:
                                    AppColors.titleBrown.withOpacity(0.7)),
                          ),
                        Expanded(
                          child: Text(
                            candidate.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        _buildStatusBadge(candidate),
                      ],
                    ),
                    const SizedBox(height: 3),
                    // 识别度徽章 + 引擎 + 元数据源
                    // 注意：识别度是"文件夹名匹配游戏名"的把握度（固定值），
                    // 不是导入进度——富化进度看状态徽章（识别中→就绪）。
                    // 用徽章样式展示避免被误读为进度条。
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: confidenceColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(2),
                            border:
                                Border.all(color: confidenceColor.withOpacity(0.4)),
                          ),
                          child: Text(
                            '识别度 ${(candidate.confidence * 100).toInt()}%',
                            style: TextStyle(
                              fontSize: 9,
                              color: confidenceColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (candidate.engineType != 'unknown') ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.titleBrown.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              candidate.engineType,
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.titleBrown,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                        if (candidate.metadataSource.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              candidate.metadataSource,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    // 路径
                    Text(
                      candidate.dirPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: AppColors.secondaryText.withOpacity(0.7),
                        fontFamily: 'monospace',
                      ),
                    ),
                    // 硬重复警告
                    if (candidate.isHardDuplicate)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.content_copy,
                                size: 10, color: AppColors.dangerRed),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                '库中已有此游戏（${candidate.duplicateWarning ?? '源ID冲突'}）',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: AppColors.dangerRed,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    // 软重复警告
                    else if (candidate.duplicateWarning != null &&
                        candidate.duplicateWarning!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber,
                                size: 10, color: AppColors.starGold),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                candidate.duplicateWarning!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: AppColors.starGold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // 失败原因
                    if (status == CandidateTaskStatus.failed &&
                        candidate.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          candidate.errorMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: AppColors.dangerRed.withOpacity(0.8),
                          ),
                        ),
                      ),
                    // 数据不全提示（2026-10-03）：封面/简介任一缺失，
                    // 全部入库时会被拦截保留在队列，需补全或重试
                    if (status == CandidateTaskStatus.ready &&
                        candidate.missingCoreFields.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '数据不全: 缺${candidate.missingCoreFields.join('、')}，'
                          '补全后入库或点重试',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: AppColors.starGold,
                          ),
                        ),
                      ),
                    // 选中提示
                    if (isSelected)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '左侧表单可编辑，✓ 入库时自动保存',
                          style: TextStyle(
                            fontSize: 9,
                            color: AppColors.titleBrown.withOpacity(0.8),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 操作按钮列
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 入库（就绪/失败可强制入库；待处理/处理中禁用）
                  InkWell(
                    onTap: selectable ? () => _confirmCandidate(candidate) : null,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      color: Colors.transparent,
                      child: Icon(
                        Icons.check,
                        size: 17,
                        color: selectable
                            ? AppColors.successGreen
                            : AppColors.secondaryText.withOpacity(0.3),
                      ),
                    ),
                  ),
                  // 重试（仅失败状态）
                  if (status == CandidateTaskStatus.failed)
                    InkWell(
                      onTap: () =>
                          WatchFolderService.instance.retryCandidate(candidate),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 28,
                        height: 24,
                        alignment: Alignment.center,
                        color: Colors.transparent,
                        child: Icon(Icons.refresh,
                            size: 14, color: AppColors.titleBrown),
                      ),
                    ),
                  // 忽略
                  InkWell(
                    onTap: () => _ignoreCandidate(candidate),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 28,
                      height: 24,
                      alignment: Alignment.center,
                      color: Colors.transparent,
                      child: Icon(Icons.close,
                          size: 16, color: AppColors.secondaryText),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面缩略图（本地临时文件 → 占位图标）
  Widget _buildCoverThumb(ImportCandidate candidate) {
    final coverPath = candidate.coverFilePath;
    final hasLocalCover =
        coverPath != null && File(coverPath).existsSync();
    return Container(
      width: 34,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: AppColors.border.withOpacity(0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasLocalCover
          ? NsfwImage.file(
              coverPath,
              contentKind: NsfwContentKind.cover,
              fit: BoxFit.cover,
              child: Image.file(
                File(coverPath),
                fit: BoxFit.cover,
                // ★ 性能优化：卡片封面限宽解码
                cacheWidth: 480,
                errorBuilder: (_, __, ___) => _buildCoverPlaceholder(),
              ),
            )
          : _buildCoverPlaceholder(),
    );
  }

  Widget _buildCoverPlaceholder() {
    return Center(
      child: Icon(Icons.image_outlined,
          size: 14, color: AppColors.secondaryText.withOpacity(0.5)),
    );
  }

  /// 状态徽章
  Widget _buildStatusBadge(ImportCandidate candidate) {
    switch (candidate.taskStatus) {
      case CandidateTaskStatus.pending:
        return _statusChip('待处理', AppColors.secondaryText);
      case CandidateTaskStatus.processing:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(
                strokeWidth: 1.2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.titleBrown),
              ),
            ),
            const SizedBox(width: 3),
            _statusChip('识别中', AppColors.titleBrown),
          ],
        );
      case CandidateTaskStatus.ready:
        return _statusChip('就绪', AppColors.successGreen);
      case CandidateTaskStatus.failed:
        return _statusChip('失败', AppColors.dangerRed);
    }
  }

  Widget _statusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _confidenceColor(double confidence) {
    if (confidence >= 0.7) return AppColors.successGreen;
    if (confidence >= 0.4) return AppColors.titleBrown;
    return AppColors.secondaryText;
  }

  // ==================== 表单联动 ====================

  /// 选中候选 → 同步到左侧表单（切换选中前先保存上一个的编辑）
  void _selectCandidate(ImportCandidate candidate) {
    final service = WatchFolderService.instance;
    final previous = service.selectedCandidate;
    if (previous != null && previous.dirPath != candidate.dirPath) {
      widget.onSaveFormEdits?.call(previous);
    }
    service.selectCandidate(candidate.dirPath);
    widget.onCandidateSelected?.call(candidate);
  }

  // ==================== 忽略列表卡片 ====================

  Widget _buildIgnoredCard() {
    final service = WatchFolderService.instance;
    final ignored = service.ignoredPaths.toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _showIgnoredPanel = !_showIgnoredPanel;
              });
            },
            child: Row(
              children: [
                Icon(
                  _showIgnoredPanel ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: AppColors.titleBrown,
                ),
                const SizedBox(width: 4),
                Icon(Icons.block, size: 14, color: AppColors.secondaryText),
                const SizedBox(width: 6),
                Text(
                  '忽略列表',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.titleBrown,
                  ),
                ),
                if (ignored.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.secondaryText.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${ignored.length}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                if (ignored.isNotEmpty && _showIgnoredPanel)
                  InkWell(
                    onTap: () => _clearIgnored(),
                    child: Text(
                      '清空',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.dangerRed,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_showIgnoredPanel) ...[
            const SizedBox(height: 8),
            if (ignored.isEmpty)
              _buildEmptyHint('暂无忽略的游戏')
            else
              // ★ P0-1：忽略列表同样虚拟化（路径可能上千条）
              SizedBox(
                height: _listViewportHeight(context) * 0.6,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: ignored.length,
                  itemBuilder: (context, index) =>
                      _buildIgnoredItem(ignored[index]),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildIgnoredItem(String path) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path.split(RegExp(r'[/\\]')).last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.secondaryText,
              ),
            ),
          ),
          InkWell(
            onTap: () => _unignorePath(path),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.restore, size: 12, color: AppColors.titleBrown),
                  const SizedBox(width: 2),
                  Text(
                    '恢复',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.titleBrown,
                      fontWeight: FontWeight.w600,
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

  // ==================== 操作处理 ====================

  /// 移除监控文件夹（带确认对话框 + 操作反馈）
  Future<void> _removeWatchFolder(WatchFolder folder) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: '移除监控路径',
      message: '确定要停止监控此文件夹吗？',
      hint: '已入库的游戏不会受到影响，但此文件夹将不再自动检测新游戏。',
      confirmText: '移除',
      isDanger: true,
    );
    if (!context.mounted || !confirmed) return;
    await WatchFolderService.instance.removeWatchFolder(folder.path);
    if (mounted) {
      AppSnackBar.success(
        context,
        '已移除监控路径',
        duration: Duration(seconds: 2),
      );
    }
  }

  Future<void> _confirmCandidate(ImportCandidate candidate) async {
    // ★ IMP-11: 入库重入守卫（服务层还有一道互斥）
    if (_isConfirming) return;
    setState(() => _isConfirming = true);
    try {
      final service = WatchFolderService.instance;
      // 若选中的正是该候选，先保存左侧表单的编辑
      if (service.selectedCandidate?.dirPath == candidate.dirPath) {
        widget.onSaveFormEdits?.call(candidate);
      }
      final success = await service.confirmCandidate(candidate);
      if (success && mounted) {
        widget.onGameAdded?.call();
        AppSnackBar.success(
          context,
          '已入库: ${candidate.title}',
          duration: const Duration(seconds: 2),
        );
      } else if (mounted) {
        AppSnackBar.error(
          context,
          '入库失败: ${candidate.title}',
        );
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  Future<void> _confirmAllCandidates() async {
    // ★ IMP-11: 入库重入守卫
    if (_isConfirming) return;
    setState(() => _isConfirming = true);
    try {
      final service = WatchFolderService.instance;
      // 入库前保存当前选中候选的表单编辑
      final selected = service.selectedCandidate;
      if (selected != null) {
        widget.onSaveFormEdits?.call(selected);
      }
      // ★ IMP-16（2026-09-12 导入审查）：分母改为"本次实际尝试数"
      //（ready 且非硬重复），与 WatchFolderService.confirmAllCandidates 的处理集合
      // 一致。旧实现用 actionableCandidates（ready + failed）作分母，
      // 提示"3/8 成功"会让用户误以为那 5 个失败项已被处理。
      final count = service.candidates
          .where((c) =>
              c.taskStatus == CandidateTaskStatus.ready &&
              !c.isHardDuplicate)
          .length;
      final successCount = await service.confirmAllCandidates();
      // 数据完整性闸口（2026-10-03）：被拦截保留的数据不全候选数，
      // 用于在结果提示中说明「成功数 < 就绪数」的原因
      final incompleteLeft = service.candidates
          .where((c) =>
              c.taskStatus == CandidateTaskStatus.ready &&
              !c.isHardDuplicate &&
              c.missingCoreFields.isNotEmpty)
          .length;
      if (mounted) {
        widget.onGameAdded?.call();
        AppSnackBar.show(
          context,
          count == 0
              ? NoticeLevel.warning
              : (successCount >= count
                  ? NoticeLevel.success
                  : NoticeLevel.warning),
          count == 0
              ? '没有就绪的候选可入库（失败项请逐个重试或强制入库）'
              : '批量入库完成: $successCount/$count 成功'
                  '${incompleteLeft > 0 ? '，$incompleteLeft 款数据不全已保留（补全后再次全部入库）' : ''}',
        );
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  Future<void> _ignoreCandidate(ImportCandidate candidate) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: '忽略此游戏',
      message: '确定要忽略「${candidate.title}」吗？',
      hint: '忽略后将不再显示此游戏。可在下方"忽略列表"中恢复。',
      confirmText: '忽略',
      isDanger: true,
    );
    if (!context.mounted || !confirmed) return;
    await WatchFolderService.instance.ignoreCandidate(candidate);
  }

  Future<void> _ignoreAllCandidates() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: '忽略全部候选',
      message:
          '确定要忽略当前队列中的所有 ${WatchFolderService.instance.candidates.length} 个游戏吗？',
      hint: '可在下方"忽略列表"中逐一恢复。',
      confirmText: '全部忽略',
      isDanger: true,
    );
    if (!context.mounted || !confirmed) return;
    await WatchFolderService.instance.ignoreAllCandidates();
  }

  Future<void> _unignorePath(String path) async {
    await WatchFolderService.instance.unignorePath(path);
    if (mounted) {
      AppSnackBar.info(
        context,
        '已恢复，将在下次扫描时重新评估',
        duration: Duration(seconds: 2),
      );
    }
  }

  Future<void> _clearIgnored() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: '清空忽略列表',
      message: '确定要清空所有忽略记录吗？',
      hint: '清空后，所有被忽略的目录将在下次扫描时重新评估。',
      confirmText: '清空',
      isDanger: true,
    );
    if (!context.mounted || !confirmed) return;
    await WatchFolderService.instance.clearIgnored();
  }

  // ==================== 通用组件 ====================

  /// 设置行
  Widget _buildSettingRow({required String label, required Widget child}) {
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.secondaryText,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  /// 模式单选按钮
  Widget _buildModeRadio({
    required String label,
    required AutoImportMode value,
    required AutoImportMode groupValue,
    required ValueChanged<AutoImportMode> onChanged,
  }) {
    final isSelected = value == groupValue;
    return InkWell(
      onTap: () => onChanged(value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 14,
            color: isSelected ? AppColors.titleBrown : AppColors.secondaryText,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color:
                  isSelected ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
        ],
      ),
    );
  }

  /// 空提示
  Widget _buildEmptyHint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.secondaryText.withOpacity(0.7),
            height: 1.5,
          ),
        ),
      ),
    );
  }

  /// 统一卡片样式
  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: AppColors.background.withOpacity(0.6),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.border.withOpacity(0.5), width: 1),
    );
  }

  /// 格式化时间
  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${time.month}/${time.day}';
  }
}
