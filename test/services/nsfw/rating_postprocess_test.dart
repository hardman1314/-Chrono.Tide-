// `NsfwRatingPostprocess` 单元测试：softmax 数学、阈值判定、全图合成框与
// 防御性行为。模型替换（v2.4，YOLO → dbrating 分类器）后替代 yolo 后处理测试。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_rating_postprocess.dart';

/// 构造 logits [g,s,q,e]，使 P(q)+P(e) ≈ [target]（q=e 对称，g/s 压到 -6）。
List<double> logitsForScore(double target) {
  // g/s 固定 -6：score = b/(a+b)，a=exp(-6)、b=exp(x)
  // 令 b/(a+b)=target → x = ln(a) + ln(target/(1-target))
  final double x = -6.0 + _logit(target.clamp(0.001, 0.999));
  return <double>[-6.0, -6.0, x, x];
}

double _logit(double p) => math.log(p / (1.0 - p));

void main() {
  group('softmax', () {
    test('长度不符应抛 ArgumentError', () {
      expect(
        () => NsfwRatingPostprocess.softmax(<double>[1, 2, 3]),
        throwsArgumentError,
      );
    });

    test('logits 全相等应输出均匀分布', () {
      final List<double> p =
          NsfwRatingPostprocess.softmax(<double>[1, 1, 1, 1]);
      for (final double v in p) {
        expect(v, closeTo(0.25, 1e-9));
      }
    });

    test('大 logits 不溢出（数值稳定）', () {
      final List<double> p = NsfwRatingPostprocess.softmax(
          <double>[1000.0, 1001.0, 1002.0, 1003.0]);
      expect(p.reduce((double a, double b) => a + b), closeTo(1.0, 1e-9));
      expect(p[3], greaterThan(p[0]));
    });

    test('分明 logits 应接近 one-hot，q+e 分数趋近 1', () {
      final List<double> p =
          NsfwRatingPostprocess.softmax(<double>[-10, -10, 10, 10]);
      expect(NsfwRatingPostprocess.scoreOf(p), greaterThan(0.999));
    });
  });

  group('decodeFromOrtValue', () {
    test('敏感分数 → 单个全图合成框，conf=分数', () {
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<List<double>>>[
          <List<double>>[logitsForScore(0.90)]
        ],
        threshold: NsfwRatingPostprocess.defaultFlagThreshold,
        imgW: 800,
        imgH: 600,
      );
      expect(boxes, hasLength(1));
      expect(boxes.first.x0, 0);
      expect(boxes.first.y0, 0);
      expect(boxes.first.x1, 800);
      expect(boxes.first.y1, 600);
      expect(boxes.first.conf, inInclusiveRange(0.85, 1.0));
      expect(boxes.first.labelName, 'questionable');
    });

    test('健康分数 → 空列表', () {
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<List<double>>>[
          <List<double>>[logitsForScore(0.10)]
        ],
        threshold: NsfwRatingPostprocess.defaultFlagThreshold,
        imgW: 800,
        imgH: 600,
      );
      expect(boxes, isEmpty);
    });

    test('阈值边界：分数恰好等于阈值判敏感（>= 语义）', () {
      final List<double> logits = logitsForScore(0.648);
      final double score = NsfwRatingPostprocess.scoreOf(
          NsfwRatingPostprocess.softmax(logits));
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<List<double>>>[
          <List<double>>[logits]
        ],
        threshold: score,
        imgW: 100,
        imgH: 100,
      );
      expect(boxes, hasLength(1));
    });

    test('异常尺寸应返回空而不是崩溃', () {
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<List<double>>>[
          <List<double>>[logitsForScore(0.99)]
        ],
        threshold: 0.5,
        imgW: 0,
        imgH: 0,
      );
      expect(boxes, isEmpty);
    });

    test('形状不符应抛 ArgumentError（防模型换错）', () {
      expect(
        () => NsfwRatingPostprocess.decodeFromOrtValue(
          <double>[1.0, 2.0, 3.0, 4.0, 5.0], // 5 个标量：不是 4 分类
          threshold: 0.5,
          imgW: 100,
          imgH: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => NsfwRatingPostprocess.decodeFromOrtValue(
          null,
          threshold: 0.5,
          imgW: 100,
          imgH: 100,
        ),
        throwsArgumentError,
      );
    });

    test('兼容 [1,4] 与 [4] 两种扁平布局', () {
      final List<double> logits = logitsForScore(0.9);
      for (final Object? shape in <Object?>[
        <List<double>>[logits],
        logits,
      ]) {
        final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
          shape,
          threshold: 0.5,
          imgW: 10,
          imgH: 10,
        );
        expect(boxes, hasLength(1), reason: '布局 $shape 应能解析');
      }
    });
  });


  group('概率输出直用（v2.1.13 全量漏拦事故回归）', () {
    // anime_dbrating_mv3 导出图内已烧 softmax：对库内真 R18 封面（ママラブ！２）
    // 的实测原始输出。raw 全部 ≥0 且 sum=1.000 —— 是概率不是 logits。
    const List<double> realR18ProbOutput = <double>[
      0.0700, 0.0655, 0.7615, 0.1029,
    ];

    test('真 R18 实测输出必须命中（概率直用，conf=0.8644）', () {
      // 正确口径（概率直加）：0.7615+0.1029=0.8644 ≥ 0.648 → 敏感。
      // 事故口径（二次 softmax）：压平后 q+e=0.6029 < 0.648 → 漏拦。
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<double>>[realR18ProbOutput],
        threshold: NsfwRatingPostprocess.defaultFlagThreshold,
        imgW: 756,
        imgH: 1080,
      );
      expect(
        boxes,
        hasLength(1),
        reason: '概率输出被二次 softmax 压平即重现 v2.1.12 全量漏拦事故',
      );
      expect(boxes.first.conf, closeTo(0.8644, 0.001));
    });

    test('尖锐概率 [0,0,0.5,0.5]：直用=1.0 敏感；二次 softmax=0.62 漏拦', () {
      // 该用例精确区分两种口径：直用口径出框，二次 softmax 口径不出框。
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<double>>[<double>[0.0, 0.0, 0.5, 0.5]],
        threshold: NsfwRatingPostprocess.defaultFlagThreshold,
        imgW: 10,
        imgH: 10,
      );
      expect(boxes, hasLength(1));
    });

    test('浮点和 ≈1（±0.02 容差内）仍视为概率直用', () {
      final List<double> noisy = <double>[0.0700, 0.0655, 0.7616, 0.1030];
      assert((noisy.fold<double>(0, (a, b) => a + b) - 1.0).abs() < 0.02);
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<double>>[noisy],
        threshold: 0.5,
        imgW: 10,
        imgH: 10,
      );
      expect(boxes, hasLength(1), reason: '0.8646 ≥ 0.5 应直用命中');
    });

    test('含负数的 logits 输入仍走 softmax（兼容未烧 softmax 的变体）', () {
      final List<NsfwBox> boxes = NsfwRatingPostprocess.decodeFromOrtValue(
        <List<double>>[logitsForScore(0.9)],
        threshold: 0.5,
        imgW: 10,
        imgH: 10,
      );
      expect(boxes, hasLength(1));
    });
  });

  group('判定口径回归（默认阈值）', () {
    test('默认阈值 0.648 与校准记录一致', () {
      expect(NsfwRatingPostprocess.defaultFlagThreshold, 0.648);
    });

    test('labelNames 与模型 meta.json 标签顺序一致', () {
      expect(NsfwBox.labelNames,
          <String>['general', 'sensitive', 'questionable', 'explicit']);
    });
  });
}
