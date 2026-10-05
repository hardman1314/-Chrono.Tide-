import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../theme/animated_background_image.dart';
import '../theme/background_image_config.dart';
import '../theme/theme_storage.dart';
import 'animated_overlay.dart';
import 'app_snack_bar.dart';
import 'interactive_wrapper.dart';

/// v3.0 P7：背景图编辑器（Figma 风格拖拽 + 滚轮缩放）
///
/// 用户上传背景图后，可能图片比例与软件窗口（16:9）不匹配。
/// 此编辑器让用户在不修改原图的前提下，通过：
/// - **拖拽**：改变图片在画布中的位置（归一化 offset）
/// - **滚轮缩放**：以光标位置为锚点缩放图片（Figma/PS 风格）
/// - **滑块缩放**：底部滑块精确调整 100%-500%
///
/// 溢出画布的部分由 ClipRect 裁掉。画布比例 16:9，与主窗口 1280×720 /
/// EditorPreviewBuilder 一致，所见即所得。
///
/// 注入方式与 [NameDialog] / [ThemeEditorDialog] 完全相同：
/// `Overlay.of(context, rootOverlay: true).insert(entry)` + [AnimatedOverlay]，
/// 确保永远在最上层（叠加在 ThemeEditorDialog 之上）。
class BackgroundImageEditorDialog {
  BackgroundImageEditorDialog._();

  /// 显示编辑器，返回新的 [BackgroundImageConfig]（用户取消则返回 null）
  static Future<BackgroundImageConfig?> show({
    required BuildContext context,
    required BackgroundImageConfig config,
  }) {
    final completer = Completer<BackgroundImageConfig?>();
    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<AnimatedOverlayState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          if (entry.mounted) entry.remove();
          if (!completer.isCompleted) completer.complete(null);
        },
        barrierColor: Colors.black54,
        dismissOnBarrierTap: false,
        enableScale: true,
        alignment: Alignment.center,
        child: _EditorContent(
          initialConfig: config,
          onApply: (newConfig) {
            if (!completer.isCompleted) completer.complete(newConfig);
            key.currentState?.dismiss();
          },
          onCancel: () {
            if (!completer.isCompleted) completer.complete(null);
            key.currentState?.dismiss();
          },
        ),
      ),
    );
    overlay.insert(entry);
    return completer.future;
  }
}

class _EditorContent extends StatefulWidget {
  final BackgroundImageConfig initialConfig;
  final ValueChanged<BackgroundImageConfig> onApply;
  final VoidCallback onCancel;

  const _EditorContent({
    required this.initialConfig,
    required this.onApply,
    required this.onCancel,
  });

  @override
  State<_EditorContent> createState() => _EditorContentState();
}

class _EditorContentState extends State<_EditorContent> {
  /// 编辑中的变换状态（独立于 widget.initialConfig，应用时才提交）
  late double _scale;
  late double _offsetX;
  late double _offsetY;

  /// 拖拽临时状态
  Offset? _dragStartGlobal;
  double _dragStartOffsetX = 0.0;
  double _dragStartOffsetY = 0.0;

  /// 画布 RenderBox key（用于 global→local 转换 + 取尺寸）
  final GlobalKey _canvasKey = GlobalKey();

  /// 图片原始像素尺寸（异步加载，未就绪时画布显示 loading）
  Size? _imageNaturalSize;

  /// 图片文件路径（file 来源时异步解析）
  String? _filePath;

  /// Esc 键监听
  final FocusNode _focusNode = FocusNode();

  /// 缩放范围
  static const double _kMinScale = 1.0;
  static const double _kMaxScale = 5.0;
  static const double _kWheelZoomFactor = 1.15;

  @override
  void initState() {
    super.initState();
    _scale = widget.initialConfig.scale < _kMinScale
        ? _kMinScale
        : widget.initialConfig.scale;
    _offsetX = widget.initialConfig.offsetX;
    _offsetY = widget.initialConfig.offsetY;
    _loadImageInfo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 加载图片原始尺寸 + 文件路径
  Future<void> _loadImageInfo() async {
    try {
      String? path;
      if (widget.initialConfig.source == BackgroundImageSource.file &&
          widget.initialConfig.filename != null) {
        path = await ThemeStorage.getBackgroundPath(
            widget.initialConfig.filename);
      } else if (widget.initialConfig.source == BackgroundImageSource.bundled &&
          widget.initialConfig.assetPath != null) {
        path = widget.initialConfig.assetPath;
      }
      if (!mounted || path == null) return;

      // v3.10 R5：编辑器是定位/构图用途 —— 动图只会持续重绘并干扰拖拽，
      // 且此处与渲染分支共用同一 provider key，改静态首帧后不会多起解码器。
      final ImageProvider provider;
      if (widget.initialConfig.source == BackgroundImageSource.file) {
        provider = AnimatedBackgroundImage.providerFor(
          File(path),
          staticFrame: widget.initialConfig.isAnimated,
        );
      } else {
        provider = AssetImage(path);
      }

      // 先 precache 提升体验
      try {
        await precacheImage(provider, context);
      } catch (e) {
        debugPrint('[BgEditor] precacheImage 失败(忽略): $e');
      }
      if (!mounted) return;

      final stream = provider.resolve(const ImageConfiguration());
      final completer = Completer<ImageInfo>();
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (!completer.isCompleted) completer.complete(info);
        stream.removeListener(listener);
      }, onError: (err, stack) {
        if (!completer.isCompleted) completer.completeError(err);
        stream.removeListener(listener);
      });
      stream.addListener(listener);
      final info = await completer.future;
      if (!mounted) return;

      setState(() {
        _filePath = path;
        _imageNaturalSize =
            Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
    } catch (e) {
      debugPrint('[BgEditor] 加载图片信息失败: $e');
      if (mounted) {
        AppSnackBar.error(context, '背景图加载失败: $e');
        widget.onCancel();
      }
    }
  }

  // ============ 边界约束 ============

  /// 当前状态下 X 方向允许的最大归一化 offset（保证图片覆盖画布，防黑边）
  double _maxOffsetXFor(double scale, Size canvasSize, Size imgSize) {
    final coverScale =
        math.max(canvasSize.width / imgSize.width, canvasSize.height / imgSize.height);
    final drawW = imgSize.width * coverScale * scale;
    final halfExtra = (drawW - canvasSize.width) / 2;
    return halfExtra > 0 ? halfExtra / canvasSize.width : 0.0;
  }

  double _maxOffsetYFor(double scale, Size canvasSize, Size imgSize) {
    final coverScale =
        math.max(canvasSize.width / imgSize.width, canvasSize.height / imgSize.height);
    final drawH = imgSize.height * coverScale * scale;
    final halfExtra = (drawH - canvasSize.height) / 2;
    return halfExtra > 0 ? halfExtra / canvasSize.height : 0.0;
  }

  /// 获取画布当前尺寸（从 RenderBox）
  Size? get _canvasSize {
    final ro = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return ro?.size;
  }

  // ============ 滚轮缩放（光标位置为锚点） ============

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_imageNaturalSize == null) return;
    final canvasSize = _canvasSize;
    if (canvasSize == null) return;

    // 1. 滚轮方向 → 缩放因子（向下滚 = 缩小）
    final scrollDelta = event.scrollDelta.dy;
    final factor = scrollDelta > 0 ? 1 / _kWheelZoomFactor : _kWheelZoomFactor;
    final newScale = (_scale * factor).clamp(_kMinScale, _kMaxScale);
    if ((newScale - _scale).abs() < 0.001) return;

    // 2. 光标在画布坐标系中的位置
    final canvasBox =
        _canvasKey.currentContext!.findRenderObject() as RenderBox;
    final cursor = canvasBox.globalToLocal(event.position);
    final mx = cursor.dx, my = cursor.dy;

    // 3. 当前光标在图片中的归一化位置（缩放时保持不变）
    final imgW = _imageNaturalSize!.width;
    final imgH = _imageNaturalSize!.height;
    final coverScale =
        math.max(canvasSize.width / imgW, canvasSize.height / imgH);
    final drawW = imgW * coverScale * _scale;
    final drawH = imgH * coverScale * _scale;
    final imgLeft = (canvasSize.width - drawW) / 2 + _offsetX * canvasSize.width;
    final imgTop = (canvasSize.height - drawH) / 2 + _offsetY * canvasSize.height;
    final nx = (mx - imgLeft) / drawW;
    final ny = (my - imgTop) / drawH;

    // 4. 反推新位置（保持 nx, ny 不变）
    final newDrawW = imgW * coverScale * newScale;
    final newDrawH = imgH * coverScale * newScale;
    final newImgLeft = mx - nx * newDrawW;
    final newImgTop = my - ny * newDrawH;

    // 5. 转回归一化 offset
    var newOffsetX = (newImgLeft - (canvasSize.width - newDrawW) / 2) / canvasSize.width;
    var newOffsetY = (newImgTop - (canvasSize.height - newDrawH) / 2) / canvasSize.height;

    // 6. 边界约束
    final maxX = _maxOffsetXFor(newScale, canvasSize, _imageNaturalSize!);
    final maxY = _maxOffsetYFor(newScale, canvasSize, _imageNaturalSize!);
    newOffsetX = newOffsetX.clamp(-maxX, maxX);
    newOffsetY = newOffsetY.clamp(-maxY, maxY);

    setState(() {
      _scale = newScale;
      _offsetX = newOffsetX;
      _offsetY = newOffsetY;
    });
  }

  // ============ 拖拽 ============

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return; // 仅左键
    _dragStartGlobal = event.position;
    _dragStartOffsetX = _offsetX;
    _dragStartOffsetY = _offsetY;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragStartGlobal == null) return;
    final canvasSize = _canvasSize;
    if (canvasSize == null || _imageNaturalSize == null) return;
    final dx = event.position.dx - _dragStartGlobal!.dx;
    final dy = event.position.dy - _dragStartGlobal!.dy;
    final maxX = _maxOffsetXFor(_scale, canvasSize, _imageNaturalSize!);
    final maxY = _maxOffsetYFor(_scale, canvasSize, _imageNaturalSize!);
    setState(() {
      _offsetX = (_dragStartOffsetX + dx / canvasSize.width).clamp(-maxX, maxX);
      _offsetY = (_dragStartOffsetY + dy / canvasSize.height).clamp(-maxY, maxY);
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _dragStartGlobal = null;
  }

  // ============ 操作 ============

  void _onReset() {
    setState(() {
      _scale = 1.0;
      _offsetX = 0.0;
      _offsetY = 0.0;
    });
  }

  void _onApply() {
    final newConfig = widget.initialConfig.copyWith(
      fit: BackgroundImageFit.custom,
      scale: _scale,
      offsetX: _offsetX,
      offsetY: _offsetY,
    );
    widget.onApply(newConfig);
  }

  // ============ UI ============

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
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 960,
            height: 640,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.6),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(4, 6),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 12),
                Expanded(child: _buildCanvasArea()),
                const SizedBox(height: 12),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.crop_free_rounded,
              size: 18, color: AppColors.primaryText),
          const SizedBox(width: 8),
          Text(
            '调整背景图位置',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '滚轮缩放（以光标为锚点） · 拖拽移动 · Esc 取消',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.secondaryText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LayoutBuilder(builder: (ctx, constraints) {
        // 计算最大 16:9 画布尺寸（居中放置）
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final canvasW = math.min(maxW, maxH * 16 / 9);
        final canvasH = canvasW * 9 / 16;
        return Center(
          child: SizedBox(
            width: canvasW,
            height: canvasH,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // 棋盘格背景（标识"无图"区域，对比明显）
                color: AppColors.placeholderBg,
                border: Border.all(color: AppColors.border, width: 1.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Listener(
                  key: _canvasKey,
                  onPointerSignal: _onPointerSignal,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  behavior: HitTestBehavior.opaque,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: _buildCanvasContent(),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildCanvasContent() {
    if (_imageNaturalSize == null || _filePath == null) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.secondaryText),
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (ctx, c) {
      final cropW = c.maxWidth, cropH = c.maxHeight;
      final imgW = _imageNaturalSize!.width;
      final imgH = _imageNaturalSize!.height;
      final coverScale = math.max(cropW / imgW, cropH / imgH);
      final drawW = imgW * coverScale * _scale;
      final drawH = imgH * coverScale * _scale;
      final maxOffX = (drawW - cropW) / 2;
      final maxOffY = (drawH - cropH) / 2;
      final pxOffsetX = (_offsetX * cropW).clamp(-maxOffX, maxOffX);
      final pxOffsetY = (_offsetY * cropH).clamp(-maxOffY, maxOffY);
      final imgLeft = (cropW - drawW) / 2 + pxOffsetX;
      final imgTop = (cropH - drawH) / 2 + pxOffsetY;

      // v3.10 R5：同 _loadImageInfo —— 编辑器一律静态首帧
      final ImageProvider provider;
      if (widget.initialConfig.source == BackgroundImageSource.file) {
        provider = AnimatedBackgroundImage.providerFor(
          File(_filePath!),
          staticFrame: widget.initialConfig.isAnimated,
        );
      } else {
        provider = AssetImage(_filePath!);
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(
            rect: Rect.fromLTWH(imgLeft, imgTop, drawW, drawH),
            child: Image(
              image: provider,
              fit: BoxFit.fill,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          // 三分构图辅助线
          _buildRuleOfThirds(cropW, cropH),
        ],
      );
    });
  }

  /// 三分构图辅助线（半透明，辅助用户构图）
  Widget _buildRuleOfThirds(double w, double h) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RuleOfThirdsPainter(
          color: AppColors.primaryText.withOpacity(0.25),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderLight, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // 缩放百分比
          Text(
            '${(_scale * 100).round()}%',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(width: 12),
          // 缩放滑块
          SizedBox(
            width: 180,
            child: Slider(
              value: _scale,
              min: _kMinScale,
              max: _kMaxScale,
              divisions: 40, // 0.1 步进
              onChanged: (v) {
                final canvasSize = _canvasSize;
                if (canvasSize == null || _imageNaturalSize == null) {
                  setState(() => _scale = v);
                  return;
                }
                setState(() {
                  _scale = v;
                  // 滑块缩放时以画布中心为锚点（保持图片中心不动）
                  final maxX =
                      _maxOffsetXFor(v, canvasSize, _imageNaturalSize!);
                  final maxY =
                      _maxOffsetYFor(v, canvasSize, _imageNaturalSize!);
                  _offsetX = _offsetX.clamp(-maxX, maxX);
                  _offsetY = _offsetY.clamp(-maxY, maxY);
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          // 重置按钮
          InteractiveWrapper(
            onTap: _onReset,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                border: Border.all(color: AppColors.borderLight, width: 0.8),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                '重置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ),
          const Spacer(),
          // 取消
          InteractiveWrapper(
            onTap: widget.onCancel,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.buttonBackground,
                border: Border.all(color: AppColors.borderLight, width: 0.8),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                '取消',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 应用
          InteractiveWrapper(
            onTap: _onApply,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.selectedAccent,
                border: Border.all(color: AppColors.border, width: 0.8),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                '应用',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 三分构图辅助线画笔
class _RuleOfThirdsPainter extends CustomPainter {
  final Color color;
  const _RuleOfThirdsPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    // 两条竖线（1/3, 2/3）
    canvas.drawLine(Offset(size.width / 3, 0),
        Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0),
        Offset(size.width * 2 / 3, size.height), paint);
    // 两条横线
    canvas.drawLine(Offset(0, size.height / 3),
        Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3),
        Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(covariant _RuleOfThirdsPainter oldDelegate) =>
      color != oldDelegate.color;
}
