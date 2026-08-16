import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/theme_element_registry.dart';
import 'hsv_color_picker.dart';
import 'recent_colors_strip.dart';
import 'interactive_wrapper.dart';

/// v3.0 P3：颜色通道面板（填充/描边/文字色）
///
/// 根据当前选中的 [ThemeElementDescriptor] 显示对应的通道（fill/stroke/textColor）。
/// 每个通道包含：
/// - 标题 + 当前色值 + 眼睛图标（可见性切换）
/// - HSV 调色板（自建，D1 决策）
/// - Recent Colors（会话级，D2 决策）
class ColorChannelPanel extends StatelessWidget {
  /// 当前选中的元素
  final ThemeElementDescriptor element;

  /// 当前主题数据（编辑器预览状态）
  final CTThemeData themeData;

  /// 拖动/输入过程中高频触发（不入 undo 栈）
  final void Function(String tokenField, Color newColor) onColorChanged;

  /// 完整动作结束触发（入 undo 栈）
  final void Function(String tokenField, Color newColor) onColorChangeEnd;

  /// Recent Colors 管理器
  final RecentColorsManager recentColors;

  /// 通道可见性状态（key = tokenField）
  final Map<String, bool> channelVisibility;

  /// 切换通道可见性
  final void Function(String tokenField, bool visible) onToggleVisibility;

  /// v3.0 P6 提色器：启动提色器回调（null 时不显示提色器按钮）
  final Future<Color?> Function()? onPickColor;

  const ColorChannelPanel({
    super.key,
    required this.element,
    required this.themeData,
    required this.onColorChanged,
    required this.onColorChangeEnd,
    required this.recentColors,
    required this.channelVisibility,
    required this.onToggleVisibility,
    this.onPickColor,
  });

  @override
  Widget build(BuildContext context) {
    if (element.properties.isEmpty) {
      // 元素无颜色通道（如背景图）
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '此元素无颜色通道可调',
          style: TextStyle(
            color: AppColors.secondaryText,
            fontSize: 12,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final property in element.properties) ...[
            _buildChannelSection(property),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildChannelSection(ThemeProperty property) {
    final currentColor = _readColor(property.tokenField);
    final isVisible = channelVisibility[property.tokenField] ?? true;
    final recentKey =
        '${element.id}.${property.channel.name}.${property.tokenField}';
    final recentList = recentColors.getColors(recentKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 通道标题行
        Row(
          children: [
            // 当前色色块
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: isVisible ? currentColor : Colors.transparent,
                border: Border.all(
                  color: currentColor,
                  width: 1.0,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              property.displayName,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(width: 6),
            // Hex 值显示
            Text(
              _colorToHex(currentColor),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                color: AppColors.secondaryText,
              ),
            ),
            const Spacer(),
            // 眼睛图标
            InteractiveWrapper(
              onTap: () =>
                  onToggleVisibility(property.tokenField, !isVisible),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  isVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 14,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // HSV 调色板
        HsvColorPicker(
          color: currentColor,
          onChanged: (c) => onColorChanged(property.tokenField, c),
          onChangeEnd: (c) => onColorChangeEnd(property.tokenField, c),
          onPickColor: onPickColor != null
              ? () async {
                  final picked = await onPickColor!();
                  if (picked != null) {
                    onColorChanged(property.tokenField, picked);
                    onColorChangeEnd(property.tokenField, picked);
                  }
                }
              : null,
        ),
        // Recent Colors
        RecentColorsStrip(
          title: property.displayName,
          colors: recentList,
          currentColor: currentColor,
          onColorTap: (c) {
            onColorChanged(property.tokenField, c);
            onColorChangeEnd(property.tokenField, c);
          },
        ),
      ],
    );
  }

  Color _readColor(String tokenField) {
    final data = themeData;
    switch (tokenField) {
      case 'background':
        return data.background;
      case 'sidebarBackground':
        return data.sidebarBackground;
      case 'titleBarBackground':
        return data.titleBarBackground;
      case 'primaryText':
        return data.primaryText;
      case 'secondaryText':
        return data.secondaryText;
      case 'border':
        return data.border;
      case 'borderLight':
        return data.borderLight;
      case 'buttonBackground':
        return data.buttonBackground;
      case 'selectedAccent':
        return data.selectedAccent;
      case 'dangerRed':
        return data.dangerRed;
      case 'placeholderText':
        return data.placeholderText;
      case 'placeholderBg':
        return data.placeholderBg;
      case 'addCoverBg':
        return data.addCoverBg;
      case 'shadowColor':
        return data.shadowColor;
      case 'successGreen':
        return data.successGreen;
      case 'successBg':
        return data.successBg;
      case 'errorBg':
        return data.errorBg;
      case 'hoverCloseBg':
        return data.hoverCloseBg;
      case 'hoverCloseBorder':
        return data.hoverCloseBorder;
      case 'inputHint':
        return data.inputHint;
      case 'cardHoverBg':
        return data.cardHoverBg;
      case 'navActiveBg':
        return data.navActiveBg;
      case 'navActiveBorder':
        return data.navActiveBorder;
      case 'navInactiveBorder':
        return data.navInactiveBorder;
      case 'toggleBg':
        return data.toggleBg;
      case 'toggleBorder':
        return data.toggleBorder;
      case 'toggleIcon':
        return data.toggleIcon;
      case 'placeholderCover':
        return data.placeholderCover;
      case 'titleBrown':
        return data.titleBrown;
      case 'starGold':
        return data.starGold;
      case 'infoBlue':
        return data.infoBlue;
      case 'brandBlue':
        return data.brandBlue;
      case 'infoBg':
        return data.infoBg;
      case 'seedColor':
        return data.seedColor;
      default:
        return Colors.black;
    }
  }

  String _colorToHex(Color c) {
    final argb = c.value.toRadixString(16).padLeft(8, '0').toUpperCase();
    return '#$argb';
  }
}
