import 'package:flutter/material.dart';

/// 背景图来源类型
enum BackgroundImageSource {
  /// 无背景图（纯色背景）
  none,

  /// 内置 bundled asset（特色主题用）
  bundled,

  /// 用户上传的图片文件
  file,
}

/// 背景图填充方式
enum BackgroundImageFit {
  cover,
  contain,
  tile,

  /// v3.0 P7：自由变换（缩放 + 偏移）
  ///
  /// 启用 [BackgroundImageConfig.scale]/[BackgroundImageConfig.offsetX]/
  /// [BackgroundImageConfig.offsetY] 三个字段，用户可在背景图编辑器中
  /// 拖拽 + 滚轮缩放定位图片，溢出部分由 ClipRect 裁掉。
  custom,
}

/// 背景图对齐方式
enum BackgroundImageAlignment {
  center,
  top,
  bottom,
  left,
  right,
}

/// 背景图配置值对象
///
/// v3.0 P0 重构：将原 CTThemeData 中散落的 `backgroundImagePath` (String?)
/// 与 `backgroundOverlayOpacity` (double) 收敛为统一配置对象。
///
/// 内置主题仍可 const 构造（bundled 来源 + assetPath）；
/// 用户主题通过 fromJson 在 runtime 构造（file 来源 + filename）。
@immutable
class BackgroundImageConfig {
  final BackgroundImageSource source;

  /// bundled 来源时为 asset 路径（如 'assets/images/themes/sakura.png'）
  /// file 来源时为 user_backgrounds 目录下的文件名（如 'bgUuid-1.png'）
  /// none 来源时为 null
  final String? assetPath;
  final String? filename;

  /// 遮罩透明度（0.0-1.0），背景色覆盖在图片上的浓度
  final double overlayOpacity;

  /// 高斯模糊 sigma（0.0-20.0），0 = 不模糊
  final double blurSigma;

  final BackgroundImageFit fit;
  final BackgroundImageAlignment alignment;

  /// v3.0 P7：custom 模式下，图片相对 cover 的缩放倍数。
  /// 1.0 = 刚好 cover（填满画布）；>1.0 = 放大（局部裁剪）；不允许 <1.0（会留黑边）。
  /// 非 custom 模式下此字段被忽略。
  final double scale;

  /// v3.0 P7：custom 模式下，图片中心相对画布中心的归一化偏移。
  /// 范围 [-1.0, 1.0]，1.0 = 偏移一个画布宽度/高度。
  /// 用归一化而非像素，便于跨窗口尺寸复用。
  /// 非 custom 模式下此字段被忽略。
  final double offsetX;
  final double offsetY;

  const BackgroundImageConfig({
    this.source = BackgroundImageSource.none,
    this.assetPath,
    this.filename,
    this.overlayOpacity = 0.30,
    this.blurSigma = 0.0,
    this.fit = BackgroundImageFit.cover,
    this.alignment = BackgroundImageAlignment.center,
    this.scale = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
  });

  /// 内置特色主题便捷构造（bundled asset）
  ///
  /// [alignment] 可选对齐（默认 center）——用于按图调整取景位置，
  /// 如樱花主题用 top 让人物头部入画（2026-09-13）。
  const BackgroundImageConfig.bundled(
    String this.assetPath, {
    this.overlayOpacity = 0.30,
    this.alignment = BackgroundImageAlignment.center,
  })  : source = BackgroundImageSource.bundled,
        filename = null,
        blurSigma = 0.0,
        fit = BackgroundImageFit.cover,
        scale = 1.0,
        offsetX = 0.0,
        offsetY = 0.0;

  /// 无背景图
  const BackgroundImageConfig.none()
      : source = BackgroundImageSource.none,
        assetPath = null,
        filename = null,
        overlayOpacity = 0.30,
        blurSigma = 0.0,
        fit = BackgroundImageFit.cover,
        alignment = BackgroundImageAlignment.center,
        scale = 1.0,
        offsetX = 0.0,
        offsetY = 0.0;

  bool get hasImage =>
      source != BackgroundImageSource.none &&
      ((source == BackgroundImageSource.bundled &&
          assetPath != null &&
          assetPath!.isNotEmpty) ||
          (source == BackgroundImageSource.file &&
              filename != null &&
              filename!.isNotEmpty));

  /// 兼容旧 CTThemeData.backgroundImagePath getter
  /// 返回 bundled asset 路径（仅 bundled 来源时有值）
  /// 注意：file 来源时返回 null，渲染层需通过 BackgroundImageResolver 统一处理
  String? get legacyAssetPath =>
      source == BackgroundImageSource.bundled ? assetPath : null;

  /// 兼容旧 CTThemeData.backgroundOverlayOpacity getter
  double get legacyOverlayOpacity => overlayOpacity;

  /// v3.10：是否为动态背景（GIF）。
  ///
  /// **派生值，不落盘** —— 不参与 [toJson] / [fromJson] / [==] / [hashCode]，
  /// 因此零 schema 变更、零迁移。之所以敢用扩展名判身份：背景文件在落盘前
  /// 已由 `BackgroundMediaInspector` 做**魔数 + 扩展名交叉校验**，
  /// 「内容 == 扩展名」是有保证的。
  ///
  /// 内置（bundled）主题当前全为 PNG，本期不引入动图内置资源，
  /// 故 bundled 分支恒为静态。
  bool get isAnimated =>
      source == BackgroundImageSource.file &&
      filename != null &&
      filename!.toLowerCase().endsWith('.gif');

  Map<String, dynamic> toJson() => {
    'source': source.name,
    if (assetPath != null) 'assetPath': assetPath,
    if (filename != null) 'filename': filename,
    'overlayOpacity': overlayOpacity,
    'blurSigma': blurSigma,
    'fit': fit.name,
    'alignment': alignment.name,
    // v3.0 P7：仅 custom 模式写入新字段，减少 JSON 体积
    if (fit == BackgroundImageFit.custom) ...{
      'scale': scale,
      'offsetX': offsetX,
      'offsetY': offsetY,
    },
  };

  factory BackgroundImageConfig.fromJson(Map<String, dynamic> json) {
    return BackgroundImageConfig(
      source: BackgroundImageSource.values.firstWhere(
            (e) => e.name == (json['source'] as String? ?? 'none'),
        orElse: () => BackgroundImageSource.none,
      ),
      assetPath: json['assetPath'] as String?,
      filename: json['filename'] as String?,
      overlayOpacity: (json['overlayOpacity'] as num?)?.toDouble() ?? 0.30,
      blurSigma: (json['blurSigma'] as num?)?.toDouble() ?? 0.0,
      fit: BackgroundImageFit.values.firstWhere(
            (e) => e.name == (json['fit'] as String? ?? 'cover'),
        orElse: () => BackgroundImageFit.cover,
      ),
      alignment: BackgroundImageAlignment.values.firstWhere(
            (e) => e.name == (json['alignment'] as String? ?? 'center'),
        orElse: () => BackgroundImageAlignment.center,
      ),
      // v3.0 P7：向后兼容——老 JSON 无此字段时用默认值 1.0/0.0/0.0
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0.0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0.0,
    );
  }

  BackgroundImageConfig copyWith({
    BackgroundImageSource? source,
    String? assetPath,
    String? filename,
    double? overlayOpacity,
    double? blurSigma,
    BackgroundImageFit? fit,
    BackgroundImageAlignment? alignment,
    double? scale,
    double? offsetX,
    double? offsetY,
  }) {
    return BackgroundImageConfig(
      source: source ?? this.source,
      assetPath: assetPath ?? this.assetPath,
      filename: filename ?? this.filename,
      overlayOpacity: overlayOpacity ?? this.overlayOpacity,
      blurSigma: blurSigma ?? this.blurSigma,
      fit: fit ?? this.fit,
      alignment: alignment ?? this.alignment,
      scale: scale ?? this.scale,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundImageConfig &&
          source == other.source &&
          assetPath == other.assetPath &&
          filename == other.filename &&
          overlayOpacity == other.overlayOpacity &&
          blurSigma == other.blurSigma &&
          fit == other.fit &&
          alignment == other.alignment &&
          scale == other.scale &&
          offsetX == other.offsetX &&
          offsetY == other.offsetY;

  @override
  int get hashCode => Object.hash(
        source,
        assetPath,
        filename,
        overlayOpacity,
        blurSigma,
        fit,
        alignment,
        scale,
        offsetX,
        offsetY,
      );
}
