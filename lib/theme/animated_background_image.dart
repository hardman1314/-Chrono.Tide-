import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// v3.10 动态背景（GIF）渲染基础设施
///
/// 本文件是**动图背景的唯一渲染出口**，只做两件事：
/// 1. [FirstFrameFileImage]：只解码第一帧的 provider（静态降级用）；
/// 2. [AnimatedBackgroundImage]：动图 / 静态降级的渲染 Widget。
///
/// 🔴 **全局单解码实例约定**（方案 §4.2，Phase 0 V4 实测）
/// `ImageCache` 以 provider key 区分。三个共用渲染点
/// （`custom_title_bar` / `big_picture_shell` / `editor_preview_builder`）
/// 必须使用**完全相同形态**的 provider（同 path + 同 scale）才能命中同一个
/// `ImageStreamCompleter` —— 即只存在一个解码器，播放进度天然同步。
/// 因此动图分支的 provider **一律经本文件构造**：
/// - **不传 `cacheWidth`**：Phase 0 V2/V2b/W2 实测 `cacheWidth`/`ResizeImage`
///   对多帧图**不生效**（请求 100，实际仍按原尺寸解码），而且会把 provider
///   变成 `ResizeImage` 形态，与其它渲染点分裂成各自一个解码器；
/// - 不允许调用点自行拼装 provider。
///
/// ⚠️ 已知代价（选型 A 的固有上限）：零依赖原生 `Image` 没有暂停 / seek /
/// 只播一次 / 限帧的公开 API —— GIF 会按其自身帧延迟无限循环播放。
/// 性能策略只能是「上传门槛卡住 + 运行时降级」，不能靠播放时调速。
class FirstFrameFileImage extends FileImage {
  /// 与 [FileImage] 同 key 语义（`file.path` + `scale`），
  /// 因此同名静态首帧实例之间会共享同一个 completer。
  const FirstFrameFileImage(super.file, {super.scale});

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadFirstFrame(key, decode));
  }

  /// 只取第一帧。多帧图的其余帧压根不解码，也不参与调度。
  ///
  /// 与 `FileImage._loadAsync`（`flutter/lib/src/painting/image_provider.dart:1478`）
  /// 保持同样的空文件语义；`dart:ui` 明确 `FrameInfo.image` 归调用方所有，
  /// 因此拿到首帧后可以立即释放 codec（框架自身的
  /// `MultiFrameImageStreamCompleter` 则把 codec 交给 GC）。
  Future<ImageInfo> _loadFirstFrame(
    FileImage key,
    ImageDecoderCallback decode,
  ) async {
    final int lengthInBytes = await key.file.length();
    if (lengthInBytes == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('${key.file} 为空文件，无法作为图片解码');
    }
    final ui.ImmutableBuffer buffer = key.file.runtimeType == File
        ? await ui.ImmutableBuffer.fromFilePath(key.file.path)
        : await ui.ImmutableBuffer.fromUint8List(await key.file.readAsBytes());

    final ui.Codec codec = await decode(buffer);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image, scale: key.scale);
    } finally {
      codec.dispose();
    }
  }

  @override
  String toString() => 'FirstFrameFileImage("${file.path}")';
}

/// 动图背景渲染 Widget（也承担「降级为静态首帧」的那一半）。
///
/// 命中任一条降级规则时传 `degradeToStaticFrame: true`：
/// - R1 动图 + 高斯模糊（`blurSigma > 0`）：Phase 0 V5/W7 实测全屏模糊逐帧重
///   栅格化，sigma 20 时 raster p95 尖峰达基线 8.2 倍；
/// - R4 全局「减少动效」开关（若启用）；
/// - R5 背景图编辑器：定位用途，动图只会干扰拖拽。
class AnimatedBackgroundImage extends StatelessWidget {
  const AnimatedBackgroundImage({
    super.key,
    required this.file,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.degradeToStaticFrame = false,
    this.errorBuilder,
  });

  final File file;
  final BoxFit fit;
  final Alignment alignment;

  /// 是否强制只显示静态首帧（R1 / R4 / R5）
  final bool degradeToStaticFrame;

  final ImageErrorWidgetBuilder? errorBuilder;

  /// 🔴 动图 provider 的**唯一构造点**（见类文档「全局单解码实例约定」）。
  ///
  /// `staticFrame == false` 时返回裸 `FileImage`（不带 `cacheWidth`），
  /// 保证三个渲染点取到同一个 key、共享同一个解码器。
  static ImageProvider providerFor(File file, {bool staticFrame = false}) =>
      staticFrame ? FirstFrameFileImage(file) : FileImage(file);

  @override
  Widget build(BuildContext context) {
    return Image(
      image: providerFor(file, staticFrame: degradeToStaticFrame),
      fit: fit,
      alignment: alignment,
      // 动图不经过 ResizeImage 降采样，绘制时按原始像素缩放：
      // 用 low 档（Image 默认 medium）换更低的每帧采样开销。
      filterQuality: FilterQuality.low,
      // 换 provider 时保留旧帧，避免解码空档闪白
      gaplessPlayback: true,
      errorBuilder: errorBuilder,
    );
  }
}
