/// anime_dbrating 四级评分分类器后处理（v2.4 模型替换：YOLO 部位检测 → 全图评分）。
///
/// 模型：`deepghs/anime_dbrating` 的 `mobilenetv3_large_100_v0_ls0.2`
/// （16.8MB，ONNX，输入 [batch,3,384,384]，输出 [batch,4] **已是 softmax
/// 概率**——导出图内含 softmax 层，实测真 R18 封面 raw=[0.070,0.065,0.762,
/// 0.103]，min≥0、sum=1.000；标签顺序来自模型卡 meta.json：general /
/// sensitive / questionable / explicit）。
///
/// **判定分数 = P(questionable) + P(explicit)**：danbooru 语义里
/// questionable ≈ 擦边以上（性暗示姿势/体液等）、explicit ≈ R18 明确内容，
/// 两者相加即「用户标准下应打码的程度」。sensitive（内衣/泳装级擦边）
/// 计入健全侧，与用户「性感擦边 = 健全」的标准对齐。
///
/// **为什么敏感时输出全图合成框而不是分数字段：**
/// v2.2 起渲染层已「敏感即整图模糊」（局部马赛克退役，见
/// `NsfwImage._buildCensored`），不再消费具体 bbox；`NsfwImage` 以
/// `_boxes.isEmpty` 作为敏感信号。合成框复用既有 NsfwDetection 存储/
/// 通知/签名失效链路，**零 schema 变更、零渲染层改动**——这是模型替换
/// 而不是存储层重构的关键取舍。框坐标即原图边界，conf 即判定分数。
library;

import 'dart:math' as math;

import 'nsfw_box.dart';

class NsfwRatingPostprocess {
  NsfwRatingPostprocess._();

  /// 类别数，与 [NsfwBox.labelNames]（v2.4 起为 rating 标签）一致。
  static const int classCount = 4;

  /// 默认敏感判定阈值（唯一判定口径）。
  ///
  /// **0.648 = 用户 69 张参考集分离间隙中点**（2026-09-07 实测，384 输入、
  /// half 归一化、分数 P(q)+P(e)，**P 为模型原始概率输出直加**——校准与
  /// 判定必须同口径，勿二次 softmax，见 [_normalize4] 的事故记录）：
  /// - 健全 43 张最高分 **0.6287**（泳装/性感擦边类全部放行）；
  /// - 敏感 26 张次低分 **0.6680**（最低 0.2165 为 1 张结构性漏检，
  ///   "全裸但无露点"类，现役 YOLO 检测器同样检不出）；
  /// - T=0.648：**误报 0/43，召回 25/26**；
  /// - 对比旧口径（censor_detect_v1.0_n @0.360）：误报 1→0、召回 22→25，
  ///   且抓到旧模型完全漏掉的明确 R18 封面（实测库内 0.02 → 0.87）。
  /// - 库内 42 张封面实测：拦 6（真敏感 4 + 误拦 2；误拦为"内裤擦边封面"
  ///   与"强抱截图封面"，用户标准边界样本，阈值无法在不砍召回的情况下排除）。
  ///
  /// **不要再无数据调阈值**：往上走砍召回（0.65+ 开始丢敏感参考图），
  /// 往下走多误报（0.63 会拦健全参考图）。
  static const double defaultFlagThreshold = 0.648;

  /// 判定分数：softmax 后 questionable + explicit 两列之和。
  static double scoreOf(List<double> probs) => probs[2] + probs[3];

  /// 数值稳定版 softmax（减最大值防溢出）。
  static List<double> softmax(List<double> values) {
    if (values.length != classCount) {
      throw ArgumentError(
        '模型输出应为 $classCount 个 logits（general/sensitive/questionable/'
        'explicit），实际 ${values.length} 个。',
      );
    }
    final double m = values.reduce(math.max);
    final List<double> exps = values
        .map((double v) => math.exp(v - m))
        .toList(growable: false);
    final double sum = exps.fold(0.0, (double a, double b) => a + b);
    if (sum <= 0 || sum.isNaN) {
      throw StateError('softmax 分母异常: $sum');
    }
    return exps.map((double e) => e / sum).toList(growable: false);
  }

  /// 输出归一化：**先做概率自检，绝不一律 softmax**。
  ///
  /// deepghs 的 ONNX 导出图内已烧 softmax，输出直接是 4 类概率；若误对概率
  /// 再做一次 softmax，分布会被压平（实测真敏感图 q+e 0.86 → 0.60），全量
  /// 跌破阈值 0.648 —— 这正是 v2.1.12「NSFW 完全不工作」（缓存 403 条全部
  /// 错判健康、0 条带框）的根因。校准阈值 0.648 本就是按"概率直用"口径
  /// 测得的分离间隙中点，两者必须同口径。
  ///
  /// 兼容规则（与 python 校准脚本同口径）：全部 ≥0 且和≈1（±0.02）视为
  /// 概率直用；否则按 logits 过 softmax（兼容图内未烧 softmax 的导出变体）。
  static List<double> _normalize4(List<double> values) {
    final double sum = values.fold(0.0, (double a, double b) => a + b);
    final bool alreadyProb = values.every((double e) => e >= 0) &&
        (sum - 1.0).abs() <= 0.02;
    return alreadyProb ? values : softmax(values);
  }

  /// 从 ORT 输出解析分类分数并生成判定框列表。
  ///
  /// ORT 返回形状 [1,1,4] 或 [1,4] 的嵌套 List（概率或 logits，见
  /// [_normalize4]）；敏感（分数 ≥
  /// [threshold]）时返回**单个全图合成框**（label=2 questionable 占位，
  /// conf=判定分数），健全/入参异常尺寸返回空列表。
  static List<NsfwBox> decodeFromOrtValue(
    Object? value, {
    required double threshold,
    required int imgW,
    required int imgH,
  }) {
    final List<double>? logits = _flatten4(value);
    if (logits == null) {
      throw ArgumentError('模型输出不是预期的 [1, 4] logits：${value?.runtimeType}');
    }
    if (imgW <= 0 || imgH <= 0) return const <NsfwBox>[];
    final double score = scoreOf(_normalize4(logits));
    if (score < threshold) return const <NsfwBox>[];
    // 全图合成框：渲染层只看"框列表是否为空"，坐标与 label 均不参与绘制。
    return <NsfwBox>[
      NsfwBox(x0: 0, y0: 0, x1: imgW, y1: imgH, label: 2, conf: score),
    ];
  }

  /// 把 ORT 嵌套 List 折叠成长度 4 的 logits（兼容 [1,1,4] / [1,4] / [4]）。
  static List<double>? _flatten4(Object? value) {
    Object? cur = value;
    while (cur is List && cur.isNotEmpty && cur.first is List) {
      cur = cur.first;
    }
    if (cur is List &&
        cur.length == classCount &&
        cur.every((Object? e) => e is num)) {
      return cur.map((Object? e) => (e as num).toDouble()).toList(
            growable: false,
          );
    }
    return null;
  }
}
