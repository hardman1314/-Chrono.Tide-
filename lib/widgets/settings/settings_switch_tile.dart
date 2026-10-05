import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'settings_tile.dart';

/// 带开关的设置行。
///
/// 在 [SettingsTile] 基础上固化了开关的行尾控件与「启用/禁用」配色语义：
/// 开启态图标与开关走 `AppColors.successGreen`（替换原先硬编码的 `0xFF4CAF50`）。
///
/// 同样不持有业务状态，`onChanged` 由调用方接给对应 service。
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.statusText,
    this.warning = false,
    this.enabled = true,
  });

  final String title;

  /// 开关当前值。
  final bool value;

  /// 开关切换回调；[enabled] 为 false 时不会触发。
  final ValueChanged<bool> onChanged;

  final IconData? icon;

  /// 标题下方的状态文案（如「已开启 · 开机后自动启动」）。
  /// 与实现保持同步是调用方的责任——历史教训见方案 §2.3 的 NSFW 文案脱节问题。
  final String? statusText;

  /// true 时状态文案用警告色（如「模型未就绪」）。
  final bool warning;

  /// false 时开关禁用（依赖前置条件未满足的场景）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color accent = value ? AppColors.successGreen : AppColors.secondaryText;
    return SettingsTile(
      title: title,
      icon: icon,
      iconColor: accent,
      iconBackground:
          value ? AppColors.successGreen.withOpacity(0.1) : AppColors.background,
      subtitle: statusText,
      subtitleColor: warning ? kSettingsWarning : null,
      trailing: Switch.adaptive(
        value: value,
        activeColor: AppColors.successGreen,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}
