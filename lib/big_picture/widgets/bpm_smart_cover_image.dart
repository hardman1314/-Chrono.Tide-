import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// BPM 智能裁剪封面组件 (v3.2)
///
/// 解决「BoxFit.cover + Alignment.center 只截取封面中心区域」的问题:
/// 竖版封面横向铺满大屏 backdrop 时,中心裁剪经常把人物头部切掉。
///
/// 方案 (纯 Dart 显著性分析,零新依赖、零 ML 模型):
/// 1. 低分辨率解码 (~64px 宽) 取 RGBA 像素
/// 2. 计算逐像素梯度能量 (相邻像素差分 ≈ 细节/轮廓密度,即视觉显著区)
/// 3. 按 cover 裁剪方向 (图比容器"高"→竖直滑窗,"宽"→水平滑窗)
///    在能量曲线上滑动窗口取总和最大区域,竖直方向带**上偏加权**
///    (galgame 封面人物头部通常位于上半区,优先保脸)
/// 4. 输出 [Alignment] 交给 [Image.file] 的 alignment 显示
///
/// 结果按路径缓存;任何异常回退 [Alignment.center],绝不阻塞渲染
/// (首帧先居中显示,分析完成后再无级平移)。
class BpmSmartAlignedImage extends StatefulWidget {
  /// 本地图片路径
  final String path;

  /// 高清解码宽度 (透传给 [Image.file.cacheWidth])
  final int cacheWidth;

  /// 目标容器宽高比 (宽/高),决定 cover 裁剪方向
  final double targetAspect;

  final BoxFit fit;

  /// 手动对齐 (v3.3 背景调整器): 非空时**优先于**自动显著性分析,
  /// 由用户在调整器中拖动/缩放生成并持久化到 game.json
  final Alignment? manualAlign;

  const BpmSmartAlignedImage({
    super.key,
    required this.path,
    this.cacheWidth = 1920,
    required this.targetAspect,
    this.fit = BoxFit.cover,
    this.manualAlign,
  });

  /// 手动对齐变更后失效指定路径的分析缓存 (下次自动模式重建)
  static void evictAlignmentCache(String path) {
    _BpmSmartAlignedImageState.evictCache(path);
  }

  @override
  State<BpmSmartAlignedImage> createState() => _BpmSmartAlignedImageState();
}

class _BpmSmartAlignedImageState extends State<BpmSmartAlignedImage> {
  Alignment _alignment = Alignment.center;

  /// 分析结果缓存 (路径 → Alignment),上限防膨胀
  static final Map<String, Alignment> _cache = <String, Alignment>{};
  static const int _cacheLimit = 96;

  /// 已提交的分析请求 (防重复解码/重复 compute)
  static final Set<String> _pending = <String>{};

  /// 供 [BpmSmartAlignedImage.evictAlignmentCache] 转发 (缓存私有于此类)
  static void evictCache(String path) {
    _cache.remove(path);
    _pending.remove(path);
  }


  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(BpmSmartAlignedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _resolve();
  }

  Future<void> _resolve() async {
    final cached = _cache[widget.path];
    if (cached != null) {
      _apply(cached);
      return;
    }
    if (!_pending.add(widget.path)) return;

    try {
      final bytes = await File(widget.path).readAsBytes();
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: _probeWidth);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      codec.dispose();
      if (data == null || !mounted) {
        _pending.remove(widget.path);
        return;
      }

      final alignment = await compute(
        _computeAlignment,
        _CropParams(
          rgba: data.buffer.asUint8List(),
          width: image.width,
          height: image.height,
          targetAspect: widget.targetAspect,
        ),
      );
      if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
      _cache[widget.path] = alignment;
      _pending.remove(widget.path);
      if (mounted) _apply(alignment);
    } catch (_) {
      // 任何异常 (文件消失/解码失败/文件名含非法字符等) → 居中兜底,
      // 写入缓存避免同一张图反复重试。
      _cache[widget.path] = Alignment.center;
      _pending.remove(widget.path);
    }
  }

  void _apply(Alignment a) {
    if (mounted && a != _alignment) setState(() => _alignment = a);
  }

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(widget.path),
      fit: widget.fit,
      alignment: widget.manualAlign ?? _alignment,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

/// 低清探测解码宽度 (能量分析用,足够表达轮廓即可)
const int _probeWidth = 64;

/// 跨 isolate 的裁剪分析参数
class _CropParams {
  final Uint8List rgba;
  final int width;
  final int height;
  final double targetAspect;

  const _CropParams({
    required this.rgba,
    required this.width,
    required this.height,
    required this.targetAspect,
  });
}

/// 纯函数: 显著性窗口分析 (在 compute isolate 中运行)
///
/// 返回 cover 显示模式下应使用的 [Alignment]。
Alignment _computeAlignment(_CropParams p) {
  try {
    final w = p.width, h = p.height;
    if (w <= 0 || h <= 0 || p.rgba.length < w * h * 4) {
      return Alignment.center;
    }

    // 灰度化
    final gray = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      gray[i] =
          ((p.rgba[o] * 299 + p.rgba[o + 1] * 587 + p.rgba[o + 2] * 114) ~/
              1000);
    }

    // 梯度能量 (右/下差分,近似轮廓密度)
    final energy = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        var e = 0.0;
        if (x + 1 < w) e += (gray[i] - gray[i + 1]).abs();
        if (y + 1 < h) e += (gray[i] - gray[i + w]).abs();
        energy[i] = e;
      }
    }

    final srcAspect = w / h;
    var xAlign = 0.0, yAlign = 0.0;

    if (srcAspect > p.targetAspect) {
      // 图更"宽" → 水平裁剪: 滑列窗口
      final winW = (h * p.targetAspect).round().clamp(1, w);
      if (winW < w) {
        xAlign = _bestWindowOffset(
          energy, w, h, true, winW, p.targetAspect,
        );
      }
    } else if (srcAspect < p.targetAspect) {
      // 图更"高" → 垂直裁剪: 滑行窗口 (带上偏加权,保人物头部/脸部)
      final winH = (w / p.targetAspect).round().clamp(1, h);
      if (winH < h) {
        yAlign = _bestWindowOffset(
          energy, w, h, false, winH, p.targetAspect,
        );
      }
    }
    // srcAspect == targetAspect → 无裁剪,居中

    return Alignment(xAlign.clamp(-1.0, 1.0), yAlign.clamp(-1.0, 1.0));
  } catch (_) {
    return Alignment.center;
  }
}

/// 在能量图上滑动窗口取显著度最高的窗口中心
///
/// [horizontal]=true 沿 x 滑动 (窗口宽 [winSize]),false 沿 y 滑动 (窗口高)。
/// 垂直方向带 30% 上偏加权 (galgame 封面构图人物偏上)。
double _bestWindowOffset(
  Float32List energy,
  int w,
  int h,
  bool horizontal,
  int winSize,
  double targetAspect,
) {
  final span = horizontal ? w : h;
  final cross = horizontal ? h : w;
  final maxStart = span - winSize;

  // 预聚合: 每条滑动的"线"上的能量和 (行和或列和)
  final line = Float32List(span);
  for (var a = 0; a < span; a++) {
    var s = 0.0;
    for (var b = 0; b < cross; b++) {
      s += horizontal ? energy[b * w + a] : energy[a * w + b];
    }
    line[a] = s;
  }

  // 滑动窗口 + 位置权重 (垂直方向顶部略优先)
  var bestStart = 0;
  var bestScore = double.negativeInfinity;
  var running = 0.0;
  for (var start = 0; start <= maxStart; start++) {
    if (start == 0) {
      for (var i = 0; i < winSize; i++) {
        running += line[i];
      }
    } else {
      running += line[start + winSize - 1] - line[start - 1];
    }
    if (running <= 0) continue;
    final center = (start + winSize / 2) / span; // 0(顶/左) → 1(底/右)
    final weight = horizontal
        ? 1.0
        : 1.0 + 0.30 * (1.0 - center); // 上偏
    final score = running * weight;
    if (score > bestScore) {
      bestScore = score;
      bestStart = start;
    }
  }

  final windowCenter = (bestStart + winSize / 2) / span; // 0 → 1
  final align = windowCenter * 2 - 1; // -1(顶/左) → 1(底/右)
  return horizontal ? align : align;
}
