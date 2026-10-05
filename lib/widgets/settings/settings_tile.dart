import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_styles.dart';

/// 警告态文字色（"未就绪 / 未开启" 一类提示）。
///
/// TODO(theme): `AppColors` 目前无 `warning` 语义令牌，而 `lib/theme/` 属稳定区，
/// 暂在本文件用局部常量规避。待批准后下沉为 `AppColors.warning` 并替换此处引用。
const Color kSettingsWarning = Color(0xFFE57373);

/// 通用设置行。
///
/// 替代此前 `settings_modal.dart` 中 9 张卡片各自手写的 `Row + Text + 控件`，
/// 统一行高、圆角、间距与 hover 反馈，并全部走设计令牌。
///
/// 本组件**不持有任何业务状态、不调用任何 service**，数据由调用方传入。
class SettingsTile extends StatefulWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.iconBackground,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
  });

  /// 行标题。
  final String title;

  /// 左侧图标；为 null 时不渲染图标容器（用于无图标的纯文本行）。
  final IconData? icon;

  /// 图标颜色。
  final Color? iconColor;

  /// 图标容器背景色。
  final Color? iconBackground;

  /// 标题下方的一行说明/状态文案。
  final String? subtitle;

  /// 副标题颜色；为 null 时用 `AppColors.secondaryText`。
  /// 警告态请传 [kSettingsWarning]。
  final Color? subtitleColor;

  /// 行尾控件（Switch / 按钮 / 路径选择等）。
  final Widget? trailing;

  /// 整行点击回调；为 null 时视为禁用态，不响应 hover。
  final VoidCallback? onTap;

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.onTap != null;
    final bool hasSubtitle =
        widget.subtitle != null && widget.subtitle!.isNotEmpty;
    final double height = hasSubtitle ? 68 : 56;

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: interactive ? (_) => setState(() => _hovered = true) : null,
      onExit: interactive ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          height: height,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.cardHoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: widget.iconBackground ?? AppColors.background,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: widget.iconColor ?? AppColors.secondaryText,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppStyles.titleSmall,
                    ),
                    if (hasSubtitle) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppStyles.bodySmall.copyWith(
                          color: widget.subtitleColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.md),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
