import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../../services/shortcut_service.dart';
import '../app_snack_bar.dart';

/// UX-13: 从 library_page.dart 抽取的批量快捷方式生成对话框。
///
/// 让用户勾选多个游戏并批量生成桌面快捷方式，
/// 显示已生成状态、批量选择/取消、处理中加载态。
class BatchShortcutDialog extends StatefulWidget {
  final List<LibraryGame> games;
  final Map<String, bool> shortcutStatus;
  final Set<String> initialSelected;

  const BatchShortcutDialog({
    super.key,
    required this.games,
    required this.shortcutStatus,
    required this.initialSelected,
  });

  @override
  State<BatchShortcutDialog> createState() => _BatchShortcutDialogState();
}

class _BatchShortcutDialogState extends State<BatchShortcutDialog> {
  late Set<String> _selected;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
  }

  void _toggleAll(bool select) {
    setState(() {
      if (select) {
        _selected = widget.games.map((g) => g.title).toSet();
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _generate() async {
    setState(() => _isProcessing = true);
    int success = 0;
    int fail = 0;
    final failedTitles = <String>[];

    for (final game in widget.games) {
      if (!_selected.contains(game.title)) continue;

      try {
        final exePath = GameDataFormat.resolveLaunchPath(
          game.launchPath,
          game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
        );

        if (exePath.isEmpty) {
          fail++;
          failedTitles.add(game.title);
          continue;
        }

        // 读取 game.json 的配置
        final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
        final localeMode = jsonData?.localeMode ?? 'none';
        final upscalingMode = jsonData?.upscalingMode ?? 'none';
        final customIconPath = jsonData?.customIconPath ?? '';

        final ok = await ShortcutService.instance.createShortcut(
          gameTitle: game.title,
          exePath: exePath,
          gameDirectory: game.directoryPath,
          customIconPath: customIconPath.isNotEmpty ? customIconPath : null,
          localeMode: localeMode,
          upscalingMode: upscalingMode,
        );

        if (ok) {
          success++;
        } else {
          fail++;
          failedTitles.add(game.title);
        }
      } catch (e) {
        debugPrint('[BATCH-SHORTCUT] ❌ 生成失败: ${game.title} -> $e');
        fail++;
        failedTitles.add(game.title);
      }
    }

    if (mounted) {
      setState(() => _isProcessing = false);
      final msg = fail > 0
          ? '批量生成完成: 成功 $success 个，失败 $fail 个'
              '${failedTitles.length <= 3 ? '（${failedTitles.join('、')}）' : ''}'
          : '批量生成完成: 成功 $success 个';
      AppSnackBar.show(
        context,
        fail > 0 ? NoticeLevel.warning : NoticeLevel.success,
        msg,
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 480,
        height: 520,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                border: Border(
                    bottom:
                        BorderSide(color: AppColors.border.withOpacity(0.2))),
              ),
              child: Row(
                children: [
                  Icon(Icons.desktop_windows_rounded,
                      size: 20, color: AppColors.primaryText.withOpacity(0.7)),
                  const SizedBox(width: 10),
                  Text('批量生成桌面快捷方式',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
            // 全选/取消全选
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () =>
                        _toggleAll(_selected.length < widget.games.length),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _selected.length == widget.games.length
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 18,
                          color: AppColors.primaryText,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _selected.length == widget.games.length
                              ? '取消全选'
                              : '全选未生成',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.primaryText),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text('已选 ${_selected.length} / ${widget.games.length}',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.secondaryText)),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border.withOpacity(0.2)),
            // 游戏列表
            Expanded(
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: widget.games.length,
                itemBuilder: (_, index) {
                  final game = widget.games[index];
                  final hasShortcut =
                      widget.shortcutStatus[game.title] ?? false;
                  final isSelected = _selected.contains(game.title);
                  return _buildGameItem(game, hasShortcut, isSelected);
                },
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(color: AppColors.border.withOpacity(0.2))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primaryText.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('取消',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryText)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap:
                        _isProcessing || _selected.isEmpty ? null : _generate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: _isProcessing || _selected.isEmpty
                            ? AppColors.primaryText.withOpacity(0.05)
                            : AppColors.primaryText,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _isProcessing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text('生成快捷方式',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _selected.isEmpty
                                      ? AppColors.secondaryText
                                      : Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameItem(LibraryGame game, bool hasShortcut, bool isSelected) {
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selected.remove(game.title);
          } else {
            _selected.add(game.title);
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryText.withOpacity(0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_off_rounded,
              size: 18,
              color:
                  isSelected ? AppColors.primaryText : AppColors.secondaryText,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(game.title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText)),
            ),
            if (hasShortcut)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.successGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('已生成',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.successGreen)),
              ),
          ],
        ),
      ),
    );
  }
}
