import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/save_manifest.dart';
import 'save_backup_panel.dart';

/// 「存档备份」对话框 —— 外层框体的**薄包装**（方案 §7 Phase 2）。
///
/// 业务内容已抽到 [SaveBackupPanel]（见 `save_backup_panel.dart`），本类只负责：
/// 对话框尺寸（560×640）、标题栏（含关闭按钮）、背景遮罩。
///
/// 🔴 `show()` 签名与行为**保持不变**，现有调用点零改动：
///   - `big_picture/big_picture_shell.dart`（BPM 大屏游戏详情菜单）
///   - `big_picture/pages/big_picture_library_page.dart`（BPM 大屏库页）
///   - `game_detail_dialog.dart`：Phase 2 起**已改指向** `GameDataDialog`
///     （桌面详情窗口），不再走本入口。
///
/// 保留本类是为了「只想看存档备份」的场景仍能一键直达，不必先开 `GameDataDialog`；
/// 同时**避免动 BPM 侧已稳定的调用点**（项目决策：BPM 只做只读展示与最小改动）。
class SaveBackupDialog extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          height: 640,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowColor,
                offset: const Offset(4, 5),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              _buildHeader(context),
              Expanded(
                child: SaveBackupPanel(
                  gameName: gameName,
                  installDir: installDir,
                  manifestEntry: manifestEntry,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
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
              '存档备份 — $gameName',
              style: TextStyle(
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
}
