import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/archive_compressor.dart';
import '../../services/archive_library_preference.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../interactive_wrapper.dart';

/// 设置页「归档库」卡片 —— 归档库位置 / 保留份数 / 压缩档位（方案 §7 Phase 4）。
///
/// 🔴 三项全部直连 [ArchiveLibraryPreference]（ChangeNotifier 单例）：
/// 用 AnimatedBuilder 监听，改值即刷新，本卡片不持有业务状态副本
/// （设置页已有同款先例：MotionPreference 的「减少动效」开关）。
///
/// 🔴 归档库路径**刻意不放 `path_helper`**（稳定区），常量在
/// [ArchiveLibraryPreference.defaultRootPath]（`<exeDir>/archives`）。
class ArchiveLibrarySettingsCard extends StatefulWidget {
  const ArchiveLibrarySettingsCard({super.key});

  @override
  State<ArchiveLibrarySettingsCard> createState() =>
      _ArchiveLibrarySettingsCardState();
}

class _ArchiveLibrarySettingsCardState
    extends State<ArchiveLibrarySettingsCard> {
  bool _busy = false;
  String? _message;
  bool _messageOk = false;

  ArchiveLibraryPreference get _prefs => ArchiveLibraryPreference.instance;

  @override
  void initState() {
    super.initState();
    // 设置页可能先于任何归档操作被打开 —— load 是幂等的，补一次保险
    _prefs.load();
  }

  void _showMessage(String msg, {required bool ok}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _messageOk = ok;
    });
  }

  Future<void> _pickRoot() async {
    if (_busy) return;
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择归档库位置',
    );
    if (result == null || result.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // setRootPath 内部含 validateRoot（拒绝 Games/ 与 downloads/ 内路径）
      final error = await _prefs.setRootPath(result.trim());
      if (!mounted) return;
      if (error != null) {
        _showMessage(error, ok: false);
      } else {
        _showMessage('归档库位置已更新。已有归档不会移动，仍可从各游戏的'
            '「备份」入口访问原位置。', ok: true);
      }
    } catch (e) {
      _showMessage('设置失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _prefs,
      builder: (context, _) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppStyle.isModern
              ? AppColors.buttonBackground
              : AppColors.sidebarBackground,
          border: AppStyle.isModern
              ? Border.all(
                  color: AppColors.borderLight, width: AppStyle.wHairline)
              : Border.all(color: AppColors.border, width: 1.6),
          boxShadow: AppStyle.isModern
              ? AppStyle.e1
              : [
                  BoxShadow(
                    color: AppColors.borderLight,
                    offset: const Offset(2, 2),
                    blurRadius: 0,
                  ),
                ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '归档库',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                height: 24 / 16,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '「保存游戏数据 / 打包」产出的归档存放位置，以及同一游戏保留几份归档。',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                height: 18 / 13,
                color: AppColors.secondaryText,
              ),
            ),
            const SizedBox(height: 16),

            // ---- 1. 归档库路径 ----
            _sectionLabel('位置'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.4),
              ),
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined,
                      size: 18, color: AppColors.border),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _prefs.rootPath,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        height: 18 / 13,
                        color: _prefs.configuredRootPath.isEmpty
                            ? AppColors.secondaryText.withOpacity(0.7)
                            : AppColors.primaryText,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_prefs.configuredRootPath.isEmpty)
                    Text(
                      '（默认，随应用目录）',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.placeholderText,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_message != null) ...[
              _buildFeedback(),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                InteractiveWrapper(
                  onTap: _busy ? null : _pickRoot,
                  cursor:
                      _busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.buttonBackground,
                      border:
                          Border.all(color: AppColors.borderLight, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.border,
                          offset: const Offset(2, 3),
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(18, 9, 18, 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_busy)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.border),
                            ),
                          )
                        else ...[
                          Icon(Icons.folder_open,
                              size: 16, color: AppColors.border),
                          const SizedBox(width: 6),
                          Text(
                            '更改位置...',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              height: 20 / 14,
                              color: AppColors.border,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ---- 2. 保留份数 ----
            _sectionLabel('保留份数'),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14),
                    ),
                    child: Slider(
                      value: _prefs.retention.toDouble(),
                      min: ArchiveLibraryPreference.minRetention.toDouble(),
                      max: ArchiveLibraryPreference.maxRetention.toDouble(),
                      divisions: ArchiveLibraryPreference.maxRetention -
                          ArchiveLibraryPreference.minRetention,
                      label: '${_prefs.retention} 份',
                      onChanged: (v) =>
                          _prefs.setRetention(v.round()),
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${_prefs.retention} 份',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.primaryText,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '同一游戏超出保留份数的最旧归档，会在下次「保存游戏数据 / 打包」完成后'
              '自动清理；归档库在应用目录之外时不会自动清理，请在游戏数据弹窗中手动删除。',
              style: TextStyle(
                fontSize: 12,
                height: 17 / 12,
                color: AppColors.secondaryText,
              ),
            ),
            const SizedBox(height: 20),

            // ---- 3. 压缩档位 ----
            _sectionLabel('压缩档位'),
            const SizedBox(height: 8),
            Row(
              children: [
                _levelChip(
                  level: ArchiveCompressionLevel.balanced,
                  title: '均衡',
                  desc: '推荐 · 速度与体积平衡',
                ),
                const SizedBox(width: 10),
                _levelChip(
                  level: ArchiveCompressionLevel.max,
                  title: '极限',
                  desc: '体积最小 · GB 级本体明显更慢',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: AppColors.secondaryText,
      ),
    );
  }

  Widget _buildFeedback() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _messageOk ? AppColors.successBg : AppColors.errorBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _messageOk ? AppColors.successGreen : AppColors.dangerRed,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _messageOk ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: _messageOk ? AppColors.successGreen : AppColors.dangerRed,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _message!,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: _messageOk ? AppColors.successGreen : AppColors.dangerRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _levelChip({
    required ArchiveCompressionLevel level,
    required String title,
    required String desc,
  }) {
    final selected = _prefs.compressionLevel == level;
    return Expanded(
      child: InteractiveWrapper(
        onTap: () => _prefs.setCompressionLevel(level),
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.selectedAccent : AppColors.background,
            border: Border.all(
              color: selected ? AppColors.selectedAccent : AppColors.border,
              width: 1.4,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: selected ? Colors.white : AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 15 / 11.5,
                  color: selected
                      ? Colors.white.withOpacity(0.85)
                      : AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
