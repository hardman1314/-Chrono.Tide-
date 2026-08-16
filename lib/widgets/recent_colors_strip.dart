import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

/// v3.0 P3：最近颜色条（D2 决策：会话级）
///
/// 在编辑器会话内记录最近使用的 24 个颜色。
/// 关闭编辑器后清空，不持久化。
///
/// 每个颜色通道（fill/stroke/textColor）各自维护独立的 Recent Colors 列表。
class RecentColorsStrip extends StatefulWidget {
  /// 当前通道的所有最近颜色
  final List<Color> colors;

  /// 点击某个颜色
  final ValueChanged<Color> onColorTap;

  /// 当前正在编辑的颜色（用于高亮显示）
  final Color? currentColor;

  /// 通道标题（如"填充"/"描边"/"文字色"）
  final String title;

  const RecentColorsStrip({
    super.key,
    required this.colors,
    required this.onColorTap,
    this.currentColor,
    required this.title,
  });

  @override
  State<RecentColorsStrip> createState() => _RecentColorsStripState();
}

class _RecentColorsStripState extends State<RecentColorsStrip> {
  @override
  Widget build(BuildContext context) {
    if (widget.colors.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          '${widget.title} · 最近颜色',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColors.secondaryText,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.placeholderBg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.borderLight, width: 0.8),
          ),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: widget.colors.map((c) => _buildColorChip(c)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildColorChip(Color color) {
    final isCurrent = widget.currentColor != null &&
        widget.currentColor!.value == color.value;

    return InteractiveWrapper(
      onTap: () => widget.onColorTap(color),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isCurrent ? Colors.blue : Colors.black.withOpacity(0.2),
            width: isCurrent ? 2.0 : 0.8,
          ),
        ),
      ),
    );
  }
}

/// v3.0 P3：Recent Colors 管理器（会话级）
///
/// 每个通道维护独立列表，最多 24 色，FIFO 队列。
class RecentColorsManager {
  static const int _maxColors = 24;

  final Map<String, List<Color>> _byChannel = {};

  List<Color> getColors(String channelKey) {
    return List.unmodifiable(_byChannel[channelKey] ?? const []);
  }

  void addColor(String channelKey, Color color) {
    final list = _byChannel.putIfAbsent(channelKey, () => []);
    // 去重：若已存在则移除旧的
    list.removeWhere((c) => c.value == color.value);
    list.insert(0, color);
    // 限制 24 个
    if (list.length > _maxColors) {
      list.removeRange(_maxColors, list.length);
    }
  }

  void clear() {
    _byChannel.clear();
  }
}
