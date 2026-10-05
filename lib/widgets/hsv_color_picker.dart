import 'dart:async';
import 'package:flutter/material.dart';

/// v3.0 P3：自建 HSV 调色板（D1 决策）
///
/// 不引入 `flutter_colorpicker` 第三方依赖，避免安装包体积膨胀。
///
/// 结构：
/// - 2D SV picker（白色 → 饱和色，可拖动圆点同时改饱和度+明度）
/// - 色相条（水平滑块，0-360°）
/// - Alpha 滑块（0-100%）
/// - Hex 输入框 + 8 个 HSV 精确输入
///
/// 性能：
/// - RepaintBoundary 隔离重绘
/// - onChanged 高频触发，onChangeEnd 仅在松手/输入失焦时触发（用于入 undo 栈）
class HsvColorPicker extends StatefulWidget {
  /// 当前颜色
  final Color color;

  /// 拖动/输入过程中高频触发（不入 undo 栈）
  final ValueChanged<Color>? onChanged;

  /// 完整动作结束触发（入 undo 栈）
  final ValueChanged<Color>? onChangeEnd;

  /// 是否显示 Alpha 滑块（默认 true）
  final bool showAlpha;

  /// 是否显示 Hex 输入框（默认 true）
  final bool showHexInput;

  /// v3.0 P6 提色器：点击启动提色器（null 时不显示提色器按钮）
  final Future<void> Function()? onPickColor;

  const HsvColorPicker({
    super.key,
    required this.color,
    this.onChanged,
    this.onChangeEnd,
    this.showAlpha = true,
    this.showHexInput = true,
    this.onPickColor,
  });

  @override
  State<HsvColorPicker> createState() => _HsvColorPickerState();
}

class _HsvColorPickerState extends State<HsvColorPicker> {
  late HSVColor _hsv;
  late double _alpha;
  late TextEditingController _hexController;
  bool _isEditingHex = false;

  /// v3.0 P6-1：onChanged 通知节流（避免高频拖动重建整个预览）
  /// 本地 setState 保持高频（指示器流畅），父级通知节流到 ~50ms (20fps)
  DateTime? _lastNotifyTime;
  Timer? _notifyTimer;
  static const Duration _kNotifyThrottle = Duration(milliseconds: 50);

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
    _alpha = widget.color.opacity;
    _hexController =
        TextEditingController(text: _colorToHex(widget.color));
  }

  @override
  void didUpdateWidget(HsvColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color && !_isEditingHex) {
      _hsv = HSVColor.fromColor(widget.color);
      _alpha = widget.color.opacity;
      _hexController.text = _colorToHex(widget.color);
    }
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _hexController.dispose();
    super.dispose();
  }

  Color get _current => _hsv.toColor().withOpacity(_alpha);

  /// v3.0 P6-1：节流通知父级（拖动中高频，但父级重建限制为 20fps）
  /// 首次立即通知；后续 50ms 内的变动合并，末尾用 timer 兜底交付最终值
  void _notifyChanged() {
    final now = DateTime.now();
    if (_lastNotifyTime == null ||
        now.difference(_lastNotifyTime!) >= _kNotifyThrottle) {
      _lastNotifyTime = now;
      _notifyTimer?.cancel();
      _notifyTimer = null;
      widget.onChanged?.call(_current);
    } else {
      // 兜底：确保拖动结束时最终值被交付（即便未触发 onChangeEnd）
      _notifyTimer?.cancel();
      _notifyTimer = Timer(_kNotifyThrottle, () {
        _lastNotifyTime = DateTime.now();
        widget.onChanged?.call(_current);
      });
    }
  }

  void _notifyChangeEnd() {
    // onChangeEnd 立即交付，取消挂起的节流 timer（避免重复通知）
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _lastNotifyTime = DateTime.now();
    widget.onChangeEnd?.call(_current);
  }

  void _updateFromSvPanel(Offset localPosition, Size size) {
    final dx = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final dy = (localPosition.dy / size.height).clamp(0.0, 1.0);
    setState(() {
      _hsv = _hsv.withSaturation(dx).withValue(1.0 - dy);
    });
    _notifyChanged();
  }

  void _updateFromHueBar(Offset localPosition, Size size) {
    final dx = (localPosition.dx / size.width).clamp(0.0, 1.0);
    setState(() {
      _hsv = _hsv.withHue(dx * 360);
    });
    _notifyChanged();
  }

  void _updateFromAlphaBar(Offset localPosition, Size size) {
    final dx = (localPosition.dx / size.width).clamp(0.0, 1.0);
    setState(() {
      _alpha = dx;
    });
    _notifyChanged();
  }

  void _onHexSubmitted(String value) {
    final parsed = _hexToColor(value);
    if (parsed != null) {
      setState(() {
        _hsv = HSVColor.fromColor(parsed);
        _alpha = parsed.opacity;
      });
      _notifyChanged();
      _notifyChangeEnd();
    } else {
      // 解析失败，恢复原值
      _hexController.text = _colorToHex(widget.color);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSvPanel(),
          const SizedBox(height: 8),
          _buildHueBar(),
          if (widget.showAlpha) ...[
            const SizedBox(height: 8),
            _buildAlphaBar(),
          ],
          if (widget.showHexInput) ...[
            const SizedBox(height: 10),
            _buildHexInput(),
          ],
        ],
      ),
    );
  }

  /// 2D SV panel（白色 → 饱和色，黑→明色）
  Widget _buildSvPanel() {
    final hueColor = _hsv.withSaturation(1).withValue(1).toColor();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = 180.0;
        final size = Size(width, height);
        // v3.0 P6 细节：click 光标提升可交互感
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onPanDown: (d) => _updateFromSvPanel(d.localPosition, size),
            onPanUpdate: (d) => _updateFromSvPanel(d.localPosition, size),
            onPanEnd: (_) => _notifyChangeEnd(),
            child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.black.withOpacity(0.1)),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.white,
                  hueColor,
                ],
              ),
            ),
            child: Stack(
              children: [
                // 黑色渐变覆盖（从上到下：透明 → 黑）
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                      ],
                    ),
                  ),
                ),
                // 圆点指示器
                Positioned(
                  left: (_hsv.saturation * width).clamp(0.0, width - 12) - 6,
                  top: ((1 - _hsv.value) * height).clamp(0.0, height - 12) - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _current,
                      border: Border.all(
                        color: Colors.white,
                        width: 2.0,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 2,
                          offset: Offset(0, 1),
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
      },
    );
  }

  /// 色相条
  Widget _buildHueBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final size = Size(width, 14.0);
        return GestureDetector(
          onPanDown: (d) => _updateFromHueBar(d.localPosition, size),
          onPanUpdate: (d) => _updateFromHueBar(d.localPosition, size),
          onPanEnd: (_) => _notifyChangeEnd(),
          child: Container(
            width: width,
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                  color: Colors.black.withOpacity(0.2), width: 0.8),
              gradient: LinearGradient(
                colors: [
                  const Color(0xFFFF0000),
                  const Color(0xFFFFFF00),
                  const Color(0xFF00FF00),
                  const Color(0xFF00FFFF),
                  const Color(0xFF0000FF),
                  const Color(0xFFFF00FF),
                  const Color(0xFFFF0000),
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: (_hsv.hue / 360 * width).clamp(0.0, width - 8) - 4,
                  top: -1,
                  child: Container(
                    width: 8,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                      border: Border.all(color: Colors.black54, width: 1),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 1,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Alpha 滑块（棋盘格背景 + 边框 + 位置指示器）
  Widget _buildAlphaBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final size = Size(width, 14.0);
        final baseColor = _hsv.toColor();
        return GestureDetector(
          onPanDown: (d) => _updateFromAlphaBar(d.localPosition, size),
          onPanUpdate: (d) => _updateFromAlphaBar(d.localPosition, size),
          onPanEnd: (_) => _notifyChangeEnd(),
          child: Container(
            width: width,
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              // v3.0 P6 修复：加边框，避免 alpha=0 时滑块不可见
              border: Border.all(
                  color: Colors.black.withOpacity(0.25), width: 0.8),
              // 棋盘格背景（CSS-like）
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  baseColor.withOpacity(0),
                  baseColor.withOpacity(1),
                ],
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 棋盘格背景
                Positioned.fill(
                  child: CustomPaint(painter: _CheckerboardPainter()),
                ),
                // v3.0 P6 修复：位置指示器（与色相条一致的白条）
                Positioned(
                  left: (_alpha * width).clamp(0.0, width - 8) - 4,
                  top: -1,
                  child: Container(
                    width: 8,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                      border:
                          Border.all(color: Colors.black54, width: 1),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 1,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Hex 输入框 + 当前颜色预览
  Widget _buildHexInput() {
    return Row(
      children: [
        // 当前颜色预览方块
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _current,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.black.withOpacity(0.2)),
          ),
        ),
        const SizedBox(width: 8),
        // Hex 输入框
        Expanded(
          child: TextField(
            controller: _hexController,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              labelText: 'Hex',
              labelStyle: const TextStyle(fontSize: 11),
            ),
            style: const TextStyle(
              fontSize: 12,
            ),
            onTap: () => _isEditingHex = true,
            onEditingComplete: () => _isEditingHex = false,
            onSubmitted: (v) {
              _isEditingHex = false;
              _onHexSubmitted(v);
            },
            onChanged: (v) {
              // 实时尝试解析但不更新状态（仅失焦/提交时更新）
            },
          ),
        ),
        const SizedBox(width: 8),
        // Alpha 百分比显示
        if (widget.showAlpha)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.05),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.black.withOpacity(0.1)),
            ),
            child: Text(
              '${(_alpha * 100).round()}%',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        // v3.0 P6 提色器按钮
        if (widget.onPickColor != null) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: '提色器：从预览区/背景图提取颜色',
            waitDuration: const Duration(milliseconds: 400),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onPickColor,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(4),
                    border:
                        Border.all(color: Colors.black.withOpacity(0.15)),
                  ),
                  child: Icon(
                    Icons.colorize_rounded,
                    size: 16,
                    color: Colors.black.withOpacity(0.6),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 棋盘格背景 painter（用于 alpha 滑块透明度可视化）
class _CheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cellSize = 4.0;
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.0); // 透明（仅用于覆盖）
    // 简化：直接绘制半透明白色棋盘
    for (var y = 0.0; y < size.height; y += cellSize) {
      for (var x = 0.0; x < size.width; x += cellSize) {
        final isWhite = ((x / cellSize).floor() + (y / cellSize).floor()) % 2 == 0;
        if (isWhite) {
          paint.color = Colors.white.withOpacity(0.3);
        } else {
          paint.color = Colors.black.withOpacity(0.0);
        }
        canvas.drawRect(
          Rect.fromLTWH(x, y, cellSize, cellSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 工具函数：Color → Hex 字符串
String _colorToHex(Color c) {
  final argb = c.value.toRadixString(16).padLeft(8, '0').toUpperCase();
  return '#$argb';
}

/// 工具函数：Hex 字符串 → Color
Color? _hexToColor(String hex) {
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length == 8) {
    final argb = int.tryParse(s, radix: 16);
    if (argb != null) return Color(argb);
  }
  return null;
}
