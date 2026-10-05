import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import 'hall_visuals.dart';

/// 探索大厅板块通用外壳：图标徽章标题行 + 墨线分隔 + 内容区
///
/// 卡面走 [HallDecor.card]（垂直微渐变 + 暖调描边 + 柔和投影），
/// 与设计稿「暖纸质感」统一；[icon] / [iconAccent] / [engCaption]
/// 为可选增强参数，旧调用（只传 title/child）完全兼容。
class HallSectionShell extends StatelessWidget {
  final String title;

  /// 标题右侧辅助说明（进度 / 统计），超长省略
  final String? subtitle;

  /// 标题右侧英文小字幕（Outfit 大写字距），杂志感层次
  final String? engCaption;

  /// 标题左侧图标徽章（配套 [iconAccent] 指定主题色）
  final IconData? icon;
  final Color? iconAccent;

  /// 标题行右侧动作区（按钮等）
  final Widget? trailing;
  final Widget child;

  const HallSectionShell({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.engCaption,
    this.icon,
    this.iconAccent,
    this.trailing,
  });

  static TextStyle get _titleStyle => TextStyle(
        fontFamily: AppStyles.zhDecorativeFont,
        fontSize: 16,
        height: 20 / 16,
        letterSpacing: 2,
        color: AppColors.primaryText,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: HallDecor.card,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                HallIconBadge(
                    icon: icon!, accent: iconAccent ?? AppColors.brandBlue),
                const SizedBox(width: 8),
              ],
              Text(title, style: _titleStyle),
              if (engCaption != null) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    engCaption!,
                    style: TextStyle(
                      fontFamily: AppStyles.enDecorativeFont,
                      fontSize: 8.5,
                      letterSpacing: 2,
                      color: AppColors.secondaryText.withOpacity(0.75),
                    ),
                  ),
                ),
              ],
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subtitle!,
                    style: AppStyles.microCaption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Expanded(child: SizedBox.shrink()),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 6),
          // 墨线分隔（暖调低透明度，浅色主题走 titleBrown）
          Container(
            height: 1,
            color: (AppColors.isDark ? Colors.white : AppColors.titleBrown)
                .withOpacity(0.07),
          ),
          const SizedBox(height: 7),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 板块空态提示（居中图标 + 一行说明）
class HallEmptyHint extends StatelessWidget {
  final String text;
  final IconData icon;

  const HallEmptyHint({
    super.key,
    required this.text,
    this.icon = Icons.inbox_rounded,
  });

  @override
  Widget build(BuildContext context) {
    // FittedBox scaleDown：小窗口（如 960×540 压测）下空间不足时整体
    // 等比缩小，杜绝空态溢出；空间充足时按自然尺寸渲染。
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.isDark
                    ? Colors.white.withOpacity(0.05)
                    : Colors.black.withOpacity(0.04),
              ),
              child: Icon(icon, size: 15, color: AppColors.placeholderText),
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: AppStyles.microCaption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
