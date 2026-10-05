/// NSFW 局部检测数据模型。
///
/// 方案见 `docs/DEV/features/nsfw_filter_implementation_plan.md` §4.3。
///
/// 与 v1 的本质区别：v1 存的是「整个作品/整张图是否 NSFW」的单个等级值，
/// v2 存的是**一张图上若干个敏感部位的包围盒**，因此才能只糊局部而不动其余画面。
library;

import 'dart:math' as math;

/// 单个敏感部位包围盒。
///
/// 坐标为**原图像素坐标**，闭区间 `[x0, y0] – [x1, y1]`（与模型后处理的
/// `+1` 像素语义一致）。渲染时再按显示尺寸等比换算。
class NsfwBox {
  /// 模型输出的类别名，索引即 [label]。
  /// v2.4 起为 `anime_dbrating` 四级评分标签（模型卡 meta.json 顺序），
  /// 不要改动顺序。注意：判定敏感时写入的是**全图合成框**，label 固定取
  /// questionable(2) 占位，渲染层不消费该值。
  static const List<String> labelNames =
      <String>['general', 'sensitive', 'questionable', 'explicit'];

  final int x0;
  final int y0;
  final int x1;
  final int y1;

  /// 类别索引，取值 0..3，含义见 [labelNames]。
  final int label;

  /// 置信度，0..1。
  final double conf;

  const NsfwBox({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.label,
    required this.conf,
  });

  int get width => x1 - x0;
  int get height => y1 - y0;

  bool get isEmpty => width <= 0 || height <= 0;

  String get labelName =>
      (label >= 0 && label < labelNames.length) ? labelNames[label] : 'unknown';

  /// 按 [ratio] 比例向四周外扩，并裁剪回图片边界。
  ///
  /// 用于风险 R-2（局部马赛克后仍可辨轮廓）：模型框通常紧贴部位边缘，
  /// 适度外扩能让马赛克覆盖过渡区域，视觉上更彻底。
  /// [ratio] 为 0.2 表示宽高各放大 20%（左右/上下各 10%）。
  NsfwBox expanded(double ratio, {required int imgW, required int imgH}) {
    if (ratio <= 0) return this;
    final dx = (width * ratio / 2).round();
    final dy = (height * ratio / 2).round();
    return NsfwBox(
      x0: math.max(0, x0 - dx),
      y0: math.max(0, y0 - dy),
      x1: math.min(imgW, x1 + dx),
      y1: math.min(imgH, y1 + dy),
      label: label,
      conf: conf,
    );
  }

  /// 紧凑序列化：单字母键，7000 张图的缓存文件体积敏感。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'x0': x0,
        'y0': y0,
        'x1': x1,
        'y1': y1,
        'l': label,
        // 保留两位小数即可，避免 json 里出现 0.7412345886230469
        'c': double.parse(conf.toStringAsFixed(3)),
      };

  static NsfwBox? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final x0 = _asInt(raw['x0']);
    final y0 = _asInt(raw['y0']);
    final x1 = _asInt(raw['x1']);
    final y1 = _asInt(raw['y1']);
    if (x0 == null || y0 == null || x1 == null || y1 == null) return null;
    return NsfwBox(
      x0: x0,
      y0: y0,
      x1: x1,
      y1: y1,
      label: _asInt(raw['l']) ?? 0,
      conf: _asDouble(raw['c']) ?? 0.0,
    );
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _asDouble(Object? v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  String toString() =>
      'NsfwBox($labelName ${conf.toStringAsFixed(3)} [$x0,$y0,$x1,$y1])';

  @override
  bool operator ==(Object other) =>
      other is NsfwBox &&
      other.x0 == x0 &&
      other.y0 == y0 &&
      other.x1 == x1 &&
      other.y1 == y1 &&
      other.label == label &&
      other.conf == conf;

  @override
  int get hashCode => Object.hash(x0, y0, x1, y1, label, conf);
}

/// 一张图的完整检测结果，对应 `nsfw_detections.json` 里 `items` 的一个值。
///
/// 记录判定时的原图尺寸，是为了在渲染时校验坐标是否仍然适用
/// （例如用户替换了同名封面但尺寸变了，旧 bbox 就会错位）。
class NsfwDetection {
  /// 判定时的原图宽高（像素）。
  final int imgW;
  final int imgH;

  /// 判定时间戳（毫秒）。
  final int detectedAtMs;

  final List<NsfwBox> boxes;

  const NsfwDetection({
    required this.imgW,
    required this.imgH,
    required this.detectedAtMs,
    required this.boxes,
  });

  /// 空结果（健康图）。仍然要落盘，否则每次启动都会重扫一遍。
  factory NsfwDetection.clean({
    required int imgW,
    required int imgH,
    int? atMs,
  }) =>
      NsfwDetection(
        imgW: imgW,
        imgH: imgH,
        detectedAtMs: atMs ?? DateTime.now().millisecondsSinceEpoch,
        boxes: const <NsfwBox>[],
      );

  bool get hasNsfw => boxes.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'w': imgW,
        'h': imgH,
        't': detectedAtMs,
        'boxes': boxes.map((NsfwBox b) => b.toJson()).toList(growable: false),
      };

  static NsfwDetection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final w = NsfwBox._asInt(raw['w']);
    final h = NsfwBox._asInt(raw['h']);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    final rawBoxes = raw['boxes'];
    final boxes = <NsfwBox>[];
    if (rawBoxes is List) {
      for (final Object? item in rawBoxes) {
        final box = NsfwBox.fromJson(item);
        if (box != null && !box.isEmpty) boxes.add(box);
      }
    }
    return NsfwDetection(
      imgW: w,
      imgH: h,
      detectedAtMs: NsfwBox._asInt(raw['t']) ?? 0,
      boxes: boxes,
    );
  }

  @override
  String toString() =>
      'NsfwDetection(${imgW}x$imgH, ${boxes.length} box(es))';
}
