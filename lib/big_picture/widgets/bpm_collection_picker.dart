import 'package:flutter/material.dart';

import '../../services/collection_service.dart';
import '../../services/local_game_registry.dart';
import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';

/// BPM 收藏夹成员选择弹窗（手柄 / 触屏通用）
///
/// 桌面版「加入收藏夹」由库页右键菜单提供；BPM 里必须同样可达 ——
/// 从「我的库」海报卡右上角快捷按钮、以及【X 动作菜单 → 加入收藏夹】进入，
/// 否则「手柄覆盖鼠标全部操作」不成立。
///
/// 手柄可达性：弹窗内是标准可聚焦控件，方向键由 shell 的模态分支驱动
/// （`inDirection` + 自动补焦），A 激活 —— 无需额外插桩。
class BpmCollectionPicker {
  BpmCollectionPicker._();

  /// 弹出某部作品的收藏夹多选弹窗
  static Future<void> show(BuildContext context, LibraryGame game) {
    return showDialog<void>(
      context: context,
      barrierColor: BpmColors.scrimStrong.withOpacity(0.7),
      builder: (_) => _BpmCollectionPickerDialog(game: game),
    );
  }
}

class _BpmCollectionPickerDialog extends StatefulWidget {
  final LibraryGame game;

  const _BpmCollectionPickerDialog({required this.game});

  @override
  State<_BpmCollectionPickerDialog> createState() =>
      _BpmCollectionPickerDialogState();
}

class _BpmCollectionPickerDialogState
    extends State<_BpmCollectionPickerDialog> {
  List<GameCollection> get _collections =>
      CollectionService.instance.collections;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: BpmColors.deepPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: BpmColors.cherryRoseBorder),
      ),
      title: Text(
        '${widget.game.title} · 收藏夹',
        style: TextStyle(
          fontFamily: AppStyles.zhDecorativeFont,
          fontSize: 20,
          color: BpmColors.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 320,
        child: _collections.isEmpty
            ? Text(
                '还没有收藏夹，先在工具栏新建一个。',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 13,
                  color: BpmColors.textMuted,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: _collections.map((c) {
                  final isMember = widget.game.collectionIds.contains(c.id);
                  return CheckboxListTile(
                    value: isMember,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: BpmColors.cherryRose,
                    checkboxShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    title: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: Color(c.colorValue),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.name,
                            style: TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 14,
                              color: BpmColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    onChanged: (v) async {
                      await LocalGameRegistry.instance
                          .setGameCollection(widget.game, c.id, v ?? false);
                      if (mounted) setState(() {});
                    },
                  );
                }).toList(),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            '完成',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              color: BpmColors.mistBlue,
            ),
          ),
        ),
      ],
    );
  }
}
