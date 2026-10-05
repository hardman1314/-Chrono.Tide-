import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// v3.0 P6 提色器（Eyedropper）
///
/// 仿 Figma 提色器：截取预览区为图片，用户在图片上移动鼠标时显示放大镜，
/// 点击提取像素颜色。支持从背景图、UI 元素等任意位置取色。
///
/// 使用 `Overlay.of(rootOverlay: true).insert` 注入，确保层级正确。
class EyedropperOverlay {
  EyedropperOverlay._();

  /// 启动提色器，返回用户拾取的颜色（null 表示取消）
  ///
  /// [boundaryKey] 需要包裹预览区的 RepaintBoundary 的 GlobalKey
  static Future<Color?> pick({
    required BuildContext context,
    required GlobalKey boundaryKey,
  }) async {
    // 1. 捕获 RepaintBoundary
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;

    final image = await renderObject.toImage(pixelRatio: 1.0);

    // 2. 计算预览区在屏幕上的位置
    final transform = renderObject.getTransformTo(null);
    final translation = transform.getTranslation();
    final size = renderObject.size;
    final previewRect = Rect.fromLTWH(
      translation.x,
      translation.y,
      size.width,
      size.height,
    );

    // 3. 预读像素数据（一次性，后续同步读取）
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    // 4. 显示提色器 overlay
    if (!context.mounted) return null;

    final completer = Completer<Color?>();
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _EyedropperView(
        image: image,
        byteData: byteData,
        previewRect: previewRect,
        onPick: (color) {
          if (!completer.isCompleted) completer.complete(color);
          if (entry.mounted) entry.remove();
        },
        onCancel: () {
          if (!completer.isCompleted) completer.complete(null);
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
    return completer.future;
  }
}

/// 提色器视图：显示截取的预览图 + 放大镜 + 十字准星
class _EyedropperView extends StatefulWidget {
  final ui.Image image;
  final ByteData? byteData;
  final Rect previewRect;
  final ValueChanged<Color> onPick;
  final VoidCallback onCancel;

  const _EyedropperView({
    required this.image,
    required this.byteData,
    required this.previewRect,
    required this.onPick,
    required this.onCancel,
  });

  @override
  State<_EyedropperView> createState() => _EyedropperViewState();
}

class _EyedropperViewState extends State<_EyedropperView> {
  Offset? _cursorScreen;
  Color _currentColor = Colors.white;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    // v3.0 P6 修复：释放截取的 ui.Image，避免内存泄漏
    widget.image.dispose();
    super.dispose();
  }

  void _updateCursor(PointerEvent event) {
    final screenPos = event.position;
    final imgX = (screenPos.dx - widget.previewRect.left)
        .clamp(0.0, widget.previewRect.width - 1);
    final imgY = (screenPos.dy - widget.previewRect.top)
        .clamp(0.0, widget.previewRect.height - 1);

    setState(() {
      _cursorScreen = screenPos;
      _currentColor = _getPixelColor(imgX, imgY);
    });
  }

  Color _getPixelColor(double imgX, double imgY) {
    final data = widget.byteData;
    if (data == null) return Colors.white;

    final px = imgX.toInt().clamp(0, widget.image.width - 1);
    final py = imgY.toInt().clamp(0, widget.image.height - 1);
    final offset = (py * widget.image.width + px) * 4;

    if (offset + 3 >= data.lengthInBytes) return Colors.white;

    return Color.fromARGB(
      data.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
        }
      },
      child: Material(
        color: Colors.transparent,
        child: Listener(
          onPointerHover: _updateCursor,
          onPointerMove: _updateCursor,
          onPointerDown: (event) {
            _updateCursor(event);
            widget.onPick(_currentColor);
          },
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              // 全屏暗色遮罩
              Positioned.fill(
                child: Container(color: Colors.black54),
              ),
              // 预览区截取的图片（用 CustomPaint 绘制 ui.Image）
              Positioned.fromRect(
                rect: widget.previewRect,
                child: ClipRect(
                  child: CustomPaint(
                    painter: _ImagePainter(image: widget.image),
                    size: Size.infinite,
                  ),
                ),
              ),
              // 顶部提示栏
              Positioned(
                top: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border:
                          Border.all(color: AppColors.border, width: 1.2),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      '点击提取颜色  |  Esc 取消',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ),
              ),
              // 放大镜 + 颜色显示
              if (_cursorScreen != null) _buildMagnifier(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMagnifier() {
    const magnifierSize = 120.0;
    const zoom = 6.0;

    final imgX = (_cursorScreen!.dx - widget.previewRect.left)
        .clamp(0.0, widget.previewRect.width - 1);
    final imgY = (_cursorScreen!.dy - widget.previewRect.top)
        .clamp(0.0, widget.previewRect.height - 1);

    // 放大镜位置：鼠标右上方，避免遮挡取色点
    double magLeft = _cursorScreen!.dx + 20;
    double magTop = _cursorScreen!.dy - magnifierSize - 40;

    // 边界保护：防止放大镜超出屏幕
    final screenW = MediaQuery.of(context).size.width;
    if (magLeft + magnifierSize > screenW - 10) {
      magLeft = _cursorScreen!.dx - magnifierSize - 20;
    }
    if (magTop < 10) {
      magTop = _cursorScreen!.dy + 20;
    }

    return Positioned(
      left: magLeft,
      top: magTop,
      child: IgnorePointer(
        child: Container(
          width: magnifierSize,
          height: magnifierSize + 28,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              ClipRect(
                child: SizedBox(
                  width: magnifierSize,
                  height: magnifierSize,
                  child: CustomPaint(
                    painter: _MagnifierPainter(
                      image: widget.image,
                      center: Offset(imgX, imgY),
                      zoom: zoom,
                      size: magnifierSize,
                    ),
                  ),
                ),
              ),
              // 颜色信息条
              Container(
                width: magnifierSize,
                height: 26,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(6),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: _currentColor,
                        border: Border.all(
                            color: Colors.black26, width: 0.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '#${_colorToHex(_currentColor)}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 绘制截取的预览图
class _ImagePainter extends CustomPainter {
  final ui.Image image;
  const _ImagePainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) => false;
}

/// 放大镜画笔：从源图中截取鼠标附近区域放大绘制 + 十字准星
class _MagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset center;
  final double zoom;
  final double size;

  const _MagnifierPainter({
    required this.image,
    required this.center,
    required this.zoom,
    required this.size,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final srcSize = size / zoom;
    final srcRect = Rect.fromCenter(
      center: center,
      width: srcSize,
      height: srcSize,
    );
    final dstRect = Rect.fromLTWH(0, 0, size, size);

    // 背景填充（避免图片边缘外的透明区域）
    canvas.drawRect(dstRect, Paint()..color = const Color(0xFF333333));

    // 绘制放大图片
    canvas.drawImageRect(image, srcRect, dstRect, Paint());

    // 十字准星
    final crossPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cx = size / 2;
    final cy = size / 2;
    canvas.drawLine(Offset(0, cy), Offset(cx - 4, cy), crossPaint);
    canvas.drawLine(Offset(cx + 4, cy), Offset(size, cy), crossPaint);
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - 4), crossPaint);
    canvas.drawLine(Offset(cx, cy + 4), Offset(cx, size), crossPaint);

    // 中心像素高亮框
    final pixelRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: zoom,
      height: zoom,
    );
    canvas.drawRect(pixelRect, crossPaint..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _MagnifierPainter oldDelegate) =>
      center != oldDelegate.center;
}

String _colorToHex(Color c) {
  final r = c.red.toRadixString(16).padLeft(2, '0').toUpperCase();
  final g = c.green.toRadixString(16).padLeft(2, '0').toUpperCase();
  final b = c.blue.toRadixString(16).padLeft(2, '0').toUpperCase();
  return '$r$g$b';
}
