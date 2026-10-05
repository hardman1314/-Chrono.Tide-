import 'package:flutter/material.dart';
import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 导入模式 (v3.1 起移除智能导入,仅保留与桌面模式直接对接的单文件/批量)
enum BpmImportMode { single, batch }

/// BPM「添加游戏」导入模式选择弹窗 (v3 Cinema 风格)
///
/// 借鉴 Cinema 主题的玻璃胶囊美学: 居中大对话框,内含三个横向大选项卡,
/// 每个选项以二次元插画 (assets/bpm_import/) 为背景,底部渐变衬文字。
///
/// 使用方式:
/// ```dart
/// final mode = await BpmImportModeSheet.show(context);
/// ```
class BpmImportModeSheet extends StatelessWidget {
  const BpmImportModeSheet({super.key});

  /// 弹出模式选择,返回用户选择的模式 (点击遮罩/关闭按钮返回 null)
  static Future<BpmImportMode?> show(BuildContext context) {
    return showDialog<BpmImportMode>(
      context: context,
      barrierColor: BpmColors.scrimStrong.withOpacity(0.7),
      builder: (_) => const BpmImportModeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 720,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: BpmColors.deepPanel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: BpmColors.deepBase.withOpacity(0.8),
              blurRadius: 60,
              offset: const Offset(0, 24),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '添加游戏',
                  style: TextStyle(
                    fontFamily: AppStyles.zhDecorativeFont,
                    fontSize: 34,
                    fontWeight: FontWeight.w400,
                    color: BpmColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '选择一种导入方式',
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 16,
                      color: BpmColors.textMuted,
                    ),
                  ),
                ),
                const Spacer(),
                _closeButton(context),
              ],
            ),
            const SizedBox(height: 32),
            // 两个横向大选项卡 (v3.1 移除智能导入: 导入实现直接复用桌面 JoinPage)
            Row(
              children: const [
                Expanded(
                  child: _ModeCard(
                    mode: BpmImportMode.single,
                    asset: 'assets/bpm_import/mode_single.png',
                    title: '单文件导入',
                    subtitle: '一个游戏文件或文件夹',
                    detail: '适合手动逐个添加',
                  ),
                ),
                SizedBox(width: 20),
                Expanded(
                  child: _ModeCard(
                    mode: BpmImportMode.batch,
                    asset: 'assets/bpm_import/mode_batch.png',
                    title: '批量导入',
                    subtitle: '多个游戏一次性入库',
                    detail: '适合整理整个游戏目录',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _closeButton(BuildContext context) {
    return BpmInteractiveWrapper(
      onTap: () => Navigator.of(context).pop(),
      semanticsLabel: '关闭',
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: BpmColors.panelGlass,
          shape: BoxShape.circle,
          border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
        ),
        child: Icon(
          Icons.close_rounded,
          size: 22,
          color: BpmColors.textSecondary,
        ),
      ),
    );
  }
}

/// 单个导入模式选项卡 (插画背景 + 底部文字渐变衬层)
class _ModeCard extends StatelessWidget {
  final BpmImportMode mode;
  final String asset;
  final String title;
  final String subtitle;
  final String detail;

  const _ModeCard({
    required this.mode,
    required this.asset,
    required this.title,
    required this.subtitle,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return BpmInteractiveWrapper(
      focusScale: 1.03,
      hoverScale: 1.02,
      semanticsLabel: title,
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.of(context).pop(mode),
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 插画背景 (cover 铺满)
              Image.asset(
                asset,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, __, ___) =>
                    ColoredBox(color: BpmColors.deepPanel),
              ),
              // 底部文字渐变衬层
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 44, 20, 18),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 1.0],
                      colors: [Color(0x000C0F16), Color(0xE60C0F16)],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: AppStyles.zhDecorativeFont,
                          fontSize: 24,
                          fontWeight: FontWeight.w400,
                          color: BpmColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontFamily: AppStyles.uiFontFamily,
                          fontSize: 13,
                          color: BpmColors.mistBlue,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(
                          fontFamily: AppStyles.uiFontFamily,
                          fontSize: 12,
                          color: BpmColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
