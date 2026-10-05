import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/motion_preference.dart';
import 'animated_background_image.dart';
import 'background_image_config.dart';
import 'theme_storage.dart';

/// v3.10：换图时 AnimatedSwitcher 的交叉淡入淡出时长。
///
/// 动图参与换图时缩到 120ms（R6）——300ms 期间新旧两个解码器同时活着，
/// 动画场景下等于双倍内存与 CPU 峰值（Phase 0 风险登记 P1）。
const Duration _kCrossFadeDuration = Duration(milliseconds: 300);
const Duration _kFastCrossFadeDuration = Duration(milliseconds: 120);

/// v3.0 P1：背景图渲染 Widget 工厂
///
/// 根据 [BackgroundImageConfig] 的 source 决定渲染方式：
/// - [BackgroundImageSource.bundled] → `Image.asset`
/// - [BackgroundImageSource.file] → `Image.file`（带降级处理）
/// - [BackgroundImageSource.none] → 空 SizedBox
///
/// 提供：
/// - 统一的模糊滤镜（ImageFiltered + sigma）
/// - 统一的遮罩透明度层（Color.withOpacity）
/// - 统一的 fit / alignment
/// - 错误降级：图片加载失败时返回空 SizedBox，不崩溃
class BackgroundImageResolver extends StatefulWidget {
  final BackgroundImageConfig config;

  /// 图片上层遮罩色（通常是主题背景色）
  final Color overlayColor;

  /// 是否启用模糊滤镜（编辑器预览时可关闭以提升性能）
  final bool enableBlur;

  const BackgroundImageResolver({
    super.key,
    required this.config,
    required this.overlayColor,
    this.enableBlur = true,
  });

  @override
  State<BackgroundImageResolver> createState() =>
      _BackgroundImageResolverState();
}

class _BackgroundImageResolverState extends State<BackgroundImageResolver> {
  String? _resolvedFilePath;
  bool _resolving = false;
  Object? _resolveError;

  /// v3.0 P7：图片原始像素尺寸（custom 模式渲染必需，归一化 offset 转 px）
  /// bundled 来源时通过 AssetImage.resolve 获取；file 来源时通过 FileImage.resolve。
  Size? _imageNaturalSize;

  /// v3.10 R6：本次过渡是否涉及动图（决定 120ms / 300ms）
  bool _fastTransition = false;

  /// v3.10 R7：旧动图背景的延迟释放定时器
  Timer? _evictTimer;

  @override
  void initState() {
    super.initState();
    _fastTransition = widget.config.isAnimated;
    // v3.10 R4：订阅全局「减少动效」开关，切换后无需重进页面即刻生效
    MotionPreference.instance.addListener(_onMotionPreferenceChanged);
    _resolveFilePath();
  }

  @override
  void dispose() {
    // 🔴 刻意**不**在这里 evict：页面切换 / State 重建也会走 dispose，
    // 在那里 evict 会让重新进入时重新解码（Phase 0 RESULTS §8 修订 3）。
    MotionPreference.instance.removeListener(_onMotionPreferenceChanged);
    _evictTimer?.cancel();
    super.dispose();
  }

  /// v3.10 R4：全局「减少动效」开关被切换。
  ///
  /// 只重建背景层（本 State 的子树），不波及页面其它部分；也不需要重走
  /// [_resolveFilePath]——路径与图片尺寸都与播放与否无关。
  ///
  /// 切到「减少动效」时顺手 [释放](_scheduleEvictIfAnimated)旧的多帧缓存条目：
  /// provider 换成 `FirstFrameFileImage` 后，旧的多帧 completer 会因失去监听
  /// 而自行停表（`image_stream.dart:1118-1122`），evict 只是把常驻的解码内存
  /// 也一并清掉（Phase 0 V6/W4 实测 ImageCache 只按首帧计费，动图真实内存
  /// 对它不可见，不主动清就会一直挂着）。
  void _onMotionPreferenceChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.config.isAnimated && MotionPreference.instance.reduceMotion) {
      _scheduleEvictIfAnimated(widget.config, _resolvedFilePath);
    }
  }

  @override
  void didUpdateWidget(BackgroundImageResolver oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFilename = oldWidget.config.filename;
    final newFilename = widget.config.filename;
    final oldSource = oldWidget.config.source;
    final newSource = widget.config.source;

    // v3.10 R6：换图前后任一侧是动图 → 缩短交叉淡入淡出
    _fastTransition =
        widget.config.isAnimated || oldWidget.config.isAnimated;

    // 源/文件名变化时重新解析路径 + 尺寸
    if (oldFilename != newFilename || oldSource != newSource) {
      // v3.10 R7：先登记旧动图背景的延迟释放，再解析新图
      // （此时 _resolvedFilePath 仍是旧值，必须此刻捕获）
      _scheduleEvictIfAnimated(oldWidget.config, _resolvedFilePath);
      _resolveFilePath();
    }
    // 同一图片但 fit 切到 custom 时，若尺寸未就绪则补一次
    if (oldWidget.config.fit != BackgroundImageFit.custom &&
        widget.config.fit == BackgroundImageFit.custom &&
        _imageNaturalSize == null &&
        !_resolving) {
      _resolveFilePath();
    }
  }

  Future<void> _resolveFilePath() async {
    if (widget.config.source != BackgroundImageSource.file ||
        widget.config.filename == null) {
      setState(() {
        _resolvedFilePath = null;
        _resolveError = null;
        // bundled 模式下也需要解析尺寸（custom 模式时）
        _imageNaturalSize = null;
      });
      // bundled 模式异步解析尺寸
      if (widget.config.source == BackgroundImageSource.bundled &&
          widget.config.assetPath != null) {
        await _resolveNaturalSize(assetPath: widget.config.assetPath);
      }
      return;
    }

    // v3.0 P6-2：仅首次加载（无旧图可保留）时显示 loading 态；
    // 配置变更时保留旧图显示，避免切换主题时背景闪烁
    final isFirstLoad = _resolvedFilePath == null && !_resolving;
    if (isFirstLoad) {
      setState(() => _resolving = true);
    }

    try {
      final path =
          await ThemeStorage.getBackgroundPath(widget.config.filename);
      if (!mounted) return;

      // v3.0 P6-2：先 precache 新图再切换显示，确保新图已就绪
      // 旧图在此期间保持可见（_resolvedFilePath 未变），消除半加载闪烁
      if (path != null) {
        try {
          await precacheImage(FileImage(File(path)), context);
        } catch (e) {
          debugPrint('[BackgroundImageResolver] precacheImage 失败(忽略): $e');
        }
      }
      if (!mounted) return;

      setState(() {
        _resolvedFilePath = path;
        _resolving = false;
        _resolveError = path == null ? '背景图文件不存在' : null;
        _imageNaturalSize = null; // 重置，下面异步补
      });

      // v3.0 P7：异步解析图片原始尺寸（custom 模式必需）
      if (path != null) {
        await _resolveNaturalSize(filePath: path);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolveError = e;
        _resolving = false;
      });
    }
  }

  /// v3.0 P7：解析图片原始像素尺寸（custom 模式渲染必需）
  ///
  /// 用 ImageProvider.resolve 监听一次 ImageInfo，取 image.width/height。
  /// 解析失败时静默降级（_imageNaturalSize 保持 null，custom 模式降级 cover）。
  Future<void> _resolveNaturalSize({String? filePath, String? assetPath}) async {
    try {
      final ImageProvider provider;
      if (filePath != null) {
        provider = FileImage(File(filePath));
      } else if (assetPath != null) {
        provider = AssetImage(assetPath);
      } else {
        return;
      }
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
        _imageNaturalSize =
            Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
    } catch (e) {
      debugPrint('[BackgroundImageResolver] 解析图片尺寸失败(忽略,降级cover): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.config.hasImage;
    final fit = _boxFitFromConfig(widget.config.fit);
    final alignment = _alignmentFromConfig(widget.config.alignment);

    // v3.0 P6-1：AnimatedSwitcher 跨"有图/无图/换图"淡入淡出过渡
    // key 由 source + filename/assetPath 组成，变化时触发交叉淡入淡出
    // v3.10 R6：涉及动图时缩到 120ms（见 _kFastCrossFadeDuration）
    final imageKey = ValueKey<String>(hasImage
        ? '${widget.config.source}:${widget.config.filename ?? widget.config.assetPath ?? ''}'
        : 'none');

    return AnimatedSwitcher(
      duration:
          _fastTransition ? _kFastCrossFadeDuration : _kCrossFadeDuration,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: hasImage
          ? (widget.config.fit == BackgroundImageFit.custom
              ? _buildCustomImageStack(imageKey)
              : _buildImageStack(imageKey, fit, alignment))
          : SizedBox.shrink(key: imageKey),
    );
  }

  /// v3.10 R7：释放旧动图背景的解码器与缓存条目。
  ///
  /// - 只在**配置变更**时调用，且**延迟到过渡动画结束后**：过早 evict 会让
  ///   AnimatedSwitcher 正在淡出的旧图重新解码；
  /// - 静态图不走这里 —— 它们的条目由 ImageCache 的 LRU 正常回收；
  /// - 两种 provider 形态都要 evict：播放中是 `FileImage`，
  ///   命中 R1/R5 降级时是 `FirstFrameFileImage`（key 因 runtimeType 不同而不同）。
  void _scheduleEvictIfAnimated(
    BackgroundImageConfig oldConfig,
    String? oldPath,
  ) {
    if (!oldConfig.isAnimated || oldPath == null) return;
    _evictTimer?.cancel();
    _evictTimer = Timer(_kFastCrossFadeDuration, () {
      final file = File(oldPath);
      final cache = PaintingBinding.instance.imageCache;
      cache.evict(FileImage(file));
      cache.evict(FirstFrameFileImage(file));
    });
  }

  /// v3.10：动图渲染分支（含 R1 模糊降级 / R4 减少动效降级）。
  ///
  /// 🔴 provider 形态由 [AnimatedBackgroundImage] 统一构造，这里**不得**传
  /// `cacheWidth`：Phase 0 V2/V2b/W2 实测对多帧图无效，且会让 provider 变成
  /// `ResizeImage` 形态而使三个渲染点各自起一个解码器（V4）。
  Widget _buildAnimatedImage({
    required BoxFit fit,
    required Alignment alignment,
  }) {
    return AnimatedBackgroundImage(
      file: File(_resolvedFilePath!),
      fit: fit,
      alignment: alignment,
      // R1：动图 + 模糊 → 静态首帧。Phase 0 V5/W7 实测（1920×1053 全屏）：
      // 无模糊时动图只比静态贵 36%，σ8 贵 82%、σ20 贵 143%（p95 尖峰 8.2×），
      // 且代价随画布面积线性增长（最大化到 1440p 大概率领跌帧）。
      // R4：全局「减少动效」开关（作用范围仅动态背景图）→ 同样只渲染静态首帧。
      degradeToStaticFrame:
          MotionPreference.instance.reduceMotion ||
              (widget.enableBlur && widget.config.blurSigma > 0),
      errorBuilder: _errorBuilder,
    );
  }

  /// v3.0 P7：custom 模式渲染分支
  ///
  /// 用 LayoutBuilder 拿裁剪区尺寸 → 算 coverScale →
  /// 实际绘制尺寸 = imgSize * coverScale * scale → Positioned.fromRect 定位。
  /// 最外层 ClipRect 裁掉溢出部分（cover/contain 不需要，custom 必须）。
  /// 图片尺寸未就绪时降级为 cover（避免首帧空白）。
  Widget _buildCustomImageStack(Key key) {
    // 尺寸未就绪：降级为 cover
    if (_imageNaturalSize == null) {
      return _buildImageStack(key, BoxFit.cover, Alignment.center);
    }

    final imgW = _imageNaturalSize!.width;
    final imgH = _imageNaturalSize!.height;

    return LayoutBuilder(builder: (context, constraints) {
      final cropW = constraints.maxWidth;
      final cropH = constraints.maxHeight;
      if (cropW.isInfinite || cropH.isInfinite) {
        // 父级无界约束，降级 cover
        return _buildImageStack(key, BoxFit.cover, Alignment.center);
      }

      // cover 基准缩放：图片至少填满画布
      final coverScale = math.max(cropW / imgW, cropH / imgH);
      // 用户缩放（不允许 <1.0，防黑边）
      final userScale = widget.config.scale < 1.0 ? 1.0 : widget.config.scale;
      final drawW = imgW * coverScale * userScale;
      final drawH = imgH * coverScale * userScale;

      // 归一化 offset → 像素偏移（图片左上角坐标）
      // 边界约束：保证图片始终覆盖画布（防黑边）
      final maxOffX = (drawW - cropW) / 2;
      final maxOffY = (drawH - cropH) / 2;
      final pxOffsetX = (widget.config.offsetX * cropW).clamp(-maxOffX, maxOffX);
      final pxOffsetY = (widget.config.offsetY * cropH).clamp(-maxOffY, maxOffY);
      final imgLeft = (cropW - drawW) / 2 + pxOffsetX;
      final imgTop = (cropH - drawH) / 2 + pxOffsetY;

      Widget imageWidget;
      switch (widget.config.source) {
        case BackgroundImageSource.bundled:
          imageWidget = Image.asset(
            widget.config.assetPath!,
            fit: BoxFit.fill,
            errorBuilder: _errorBuilder,
          );
          break;
        case BackgroundImageSource.file:
          if (_resolving || _resolvedFilePath == null) {
            return SizedBox.shrink(key: key);
          }
          if (widget.config.isAnimated) {
            // v3.10：动图走专用分支（裸 FileImage，无 cacheWidth）
            imageWidget = _buildAnimatedImage(
              fit: BoxFit.fill,
              alignment: Alignment.center,
            );
          } else {
            imageWidget = Image.file(
              File(_resolvedFilePath!),
              fit: BoxFit.fill,
              // ★ 性能优化：全屏背景限宽解码（防高分辨率原图全量解码）。
              // 背景会被模糊/蒙层处理，1920 物理像素视觉无差异。
              cacheWidth: 1920,
              errorBuilder: _errorBuilder,
            );
          }
          break;
        case BackgroundImageSource.none:
          return SizedBox.shrink(key: key);
      }

      // 模糊滤镜
      if (widget.enableBlur && widget.config.blurSigma > 0) {
        imageWidget = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: widget.config.blurSigma,
            sigmaY: widget.config.blurSigma,
          ),
          child: imageWidget,
        );
      }

      return ClipRect(
        child: Stack(
          key: key,
          fit: StackFit.expand,
          children: [
            // 底层图片：用 Positioned.fromRect 精确定位
            Positioned.fromRect(
              rect: Rect.fromLTWH(imgLeft, imgTop, drawW, drawH),
              child: IgnorePointer(child: imageWidget),
            ),
            // 遮罩层（主题背景色 + 透明度）
            if (widget.config.overlayOpacity > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: widget.overlayColor
                        .withOpacity(widget.config.overlayOpacity),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  /// 构建图片 + 遮罩层 Stack（P6-1 抽取，供 AnimatedSwitcher 使用）
  Widget _buildImageStack(Key key, BoxFit fit, Alignment alignment) {
    Widget imageWidget;
    switch (widget.config.source) {
      case BackgroundImageSource.bundled:
        imageWidget = Image.asset(
          widget.config.assetPath!,
          fit: fit,
          alignment: alignment,
          errorBuilder: _errorBuilder,
        );
        break;
      case BackgroundImageSource.file:
        if (_resolving || _resolvedFilePath == null) {
          if (!_resolving) {
            debugPrint(
                '[BackgroundImageResolver] file 模式但路径解析失败: $_resolveError');
          }
          return SizedBox.shrink(key: key);
        }
        if (widget.config.isAnimated) {
          // v3.10：动图走专用分支（裸 FileImage，无 cacheWidth）
          imageWidget = _buildAnimatedImage(fit: fit, alignment: alignment);
        } else {
          imageWidget = Image.file(
            File(_resolvedFilePath!),
            fit: fit,
            alignment: alignment,
            // ★ 性能优化：全屏背景限宽解码（防高分辨率原图全量解码）
            cacheWidth: 1920,
            errorBuilder: _errorBuilder,
          );
        }
        break;
      case BackgroundImageSource.none:
        return SizedBox.shrink(key: key);
    }

    // 模糊滤镜
    if (widget.enableBlur && widget.config.blurSigma > 0) {
      imageWidget = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: widget.config.blurSigma,
          sigmaY: widget.config.blurSigma,
        ),
        child: imageWidget,
      );
    }

    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        // 底层图片
        Positioned.fill(child: IgnorePointer(child: imageWidget)),
        // 遮罩层（主题背景色 + 透明度）
        if (widget.config.overlayOpacity > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: widget.overlayColor
                    .withOpacity(widget.config.overlayOpacity),
              ),
            ),
          ),
      ],
    );
  }

  Widget _errorBuilder(
      BuildContext context, Object error, StackTrace? stackTrace) {
    debugPrint('[BackgroundImageResolver] 背景图加载失败: $error');
    return const SizedBox.shrink();
  }

  static BoxFit _boxFitFromConfig(BackgroundImageFit fit) {
    switch (fit) {
      case BackgroundImageFit.cover:
        return BoxFit.cover;
      case BackgroundImageFit.contain:
        return BoxFit.contain;
      case BackgroundImageFit.tile:
        return BoxFit.none;
      case BackgroundImageFit.custom:
        // custom 模式不应走此分支（build 方法已分流到 _buildCustomImageStack）
        // 兜底返回 cover，避免意外调用时崩溃
        return BoxFit.cover;
    }
  }

  static Alignment _alignmentFromConfig(BackgroundImageAlignment align) {
    switch (align) {
      case BackgroundImageAlignment.center:
        return Alignment.center;
      case BackgroundImageAlignment.top:
        return Alignment.topCenter;
      case BackgroundImageAlignment.bottom:
        return Alignment.bottomCenter;
      case BackgroundImageAlignment.left:
        return Alignment.centerLeft;
      case BackgroundImageAlignment.right:
        return Alignment.centerRight;
    }
  }
}
