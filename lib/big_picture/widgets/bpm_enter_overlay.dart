import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../big_picture_theme.dart';

/// 大屏模式（BPM）入场过渡的「手柄图标」层 —— 复刻 Steam Big Picture 的加载动画。
///
/// 用户诉求：进入 BPM 时不要硬切。黑幕合拢后，画布中央由**两个光点从同一起点
/// 出发、一左一右沿手柄轮廓把整个手柄"画"出来**，作为大屏模式的加载指示。
///
/// 造型来自对 Steam 参考截图的**逐行扫描剖面**（`.workbuddy/probe_bpm_icon/`），
/// 不是凭感觉画的。关键实测值：
/// - 图标宽高比 **1.364**（旧实现 1.6，所以一直"又扁又圆"）；
/// - 顶边只占约 74% 宽，两侧斜向下外扩，最宽点在 y≈71% 处；
/// - 底中央是一段**浅 V 平台**，两个光点在此汇合收尾；
/// - 描边半高宽实测 ≈12px/304 ⇒ 约 8.4 设计单位（Steam 的线相当粗）。
/// 轮廓内**没有**十字键 / 摇杆 / 按键，只有上方一个小圆（Steam 键）。
///
/// 视觉分镜（`t` = 图标自身进度 0..1，随 `_bpmLogo` 控制器推进）：
///
/// | 子区间 | 画面 |
/// |---|---|
/// | 0.00 → 0.06 | 图标层整体淡入 |
/// | 0.00 → 0.18 | Steam 键小圆淡入（它是两个光点的起点参照） |
/// | 0.03 → 0.78 | 两个光点自顶中央出发，顺时针 / 逆时针各画一半，在底平台汇合 |
/// | 0.78 → 1.00 | **收尾柔光**：合拢瞬间整条边框向外发一次光、先快后慢散掉，描边本体同时轻微加粗 |
///
/// ⚠️ 描出段终点取 0.78（而不是更靠后）是为了给收尾柔光腾出 22% ≈ 119ms 的窗口——
/// 原来跑到 0.94 才合拢，只剩 32ms，闪不出任何可感知的东西。**总时长不变**。
/// 柔光**只向外**：用填充路径配 `BlurStyle.outer`（`blur(shape) - shape`），
/// 而不是给描边加模糊——后者是环带，外侧内侧会一起发光，手柄内部会被点亮。
///
/// 配色走 [BpmColors]（`textPrimary` 描边 / `cherryRose` 拖尾 / 亮核与柔光按明暗自适应），
/// 深/浅两套 BPM 调色板都可用；幕布底色同为 [BpmColors.deepBase]，进 BPM 全程无跳色。
/// ⚠️ 柔光色**不能**直接复用描边色：浅色调色板下幕布是白色（`#F1F8FF`）、主色是深蓝
/// （`#11395C`），拿主色做辉光会渗出深色阴影（读作"发黑"）而不是发光。
///
/// ⚠️ 本层只在入场过渡期间存在（幕布揭开时随 `reveal` 淡出），稳态不占图层。
class BpmEnterOverlay extends StatelessWidget {
  const BpmEnterOverlay({
    super.key,
    required this.progress,
    required this.reveal,
  });

  /// 图标自身动画进度 0..1（由 `_bpmLogo` 控制器驱动）
  final double progress;

  /// 幕布揭开进度 0..1（0 = 未揭开）。图标随揭开放大 + 淡出。
  final double reveal;

  @override
  Widget build(BuildContext context) {
    final rv = reveal.clamp(0.0, 1.0);
    final t = progress.clamp(0.0, 1.0);

    // 揭开期淡出曲线与幕布**同一条**（`_curtainAlpha` 用 easeOutCubic）：
    // 若比幕布慢，图标会「悬浮」在已经露出的大屏界面上，读作残影 bug；
    // 同步溶解则读作「画布连图标一起化开」。
    final opacity = _fadeIn(t) * (1.0 - Curves.easeOutCubic.transform(rv));
    if (opacity <= 0.002) return const SizedBox.shrink();

    // 揭开期轻微放大：读作「图标更靠近镜头地被推走」，与外壳落座同向。
    final scale = 1.0 + 0.06 * Curves.easeOutCubic.transform(rv);

    return IgnorePointer(
      child: Center(
        child: LayoutBuilder(
          builder: (context, c) {
            final short = math.min(c.maxWidth, c.maxHeight);
            // w = 手柄的**视觉**宽度。画布比手柄大一圈（见 canvasW/canvasH），
            // 所以 SizedBox 的宽高要按 canvasW/boxW 等比放大，手柄仍在画布正中。
            final w = (short * 0.30).clamp(240.0, 520.0).toDouble();
            return Transform.scale(
              scale: scale,
              // ★ RepaintBoundary：光点逐帧重绘的是这一小块画布，不牵连大屏外壳
              child: RepaintBoundary(
                child: SizedBox(
                  width: w *
                      _SteamControllerPainter.canvasW /
                      _SteamControllerPainter.boxW,
                  height: w *
                      _SteamControllerPainter.canvasH /
                      _SteamControllerPainter.boxW,
                  child: CustomPaint(
                    painter: _SteamControllerPainter(
                      t: t,
                      opacity: opacity,
                      ink: BpmColors.textPrimary,
                      accent: BpmColors.cherryRose,
                      spark: BpmColors.isDark
                          ? const Color(0xFFFFFFFF)
                          : BpmColors.mistBlue,
                      // 柔光色按明暗分支：浅色调色板下幕布是白的，复用描边色会"发黑"
                      glow: BpmColors.isDark
                          ? BpmColors.textPrimary
                          : BpmColors.cherryRose,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 图标整体淡入：起步极快（幕布刚合拢就出现）
  static double _fadeIn(double t) {
    final v = (t / 0.06).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(v);
  }
}

/// Steam 手柄图标画笔。
///
/// 轮廓锚点 = 对参考截图的逐行扫描剖面（`.workbuddy/probe_bpm_icon/steam_shape.py`），
/// 相邻锚点间用 **Catmull-Rom 转三次贝塞尔**补成曲线 ⇒ 处处相切连续，不会出现棱角。
/// 设计盒 240 × 176，绘制时按实际宽度等比缩放。
class _SteamControllerPainter extends CustomPainter {
  _SteamControllerPainter({
    required this.t,
    required this.opacity,
    required this.ink,
    required this.accent,
    required this.spark,
    required this.glow,
  });

  final double t;
  final double opacity;
  final Color ink;
  final Color accent;
  final Color spark;

  /// 收尾柔光色。**不能**复用 [ink]：浅色调色板下幕布是白的、[ink] 是深蓝，
  /// 那样做出来的是"影子"而不是"光"。
  final Color glow;

  // ============ 设计盒 + 实测常量 ============
  static const double boxW = 240.0;
  static const double boxH = 176.0;

  /// 轮廓描边宽度（参考图半高宽实测 ≈12px/304 ⇒ 约 9.5，扣掉外发光取 8.4）
  static const double _stroke = 8.4;

  /// Steam 键小圆（参考图外接框实测圆心 (119.6, 38.5)，外半径 14.2）
  static const Offset _circleCenter = Offset(120.0, 38.5);
  static const double _circleRadius = 13.0;
  static const double _circleStroke = 4.4;

  // ============ 分镜子区间（改这里 = 改节奏） ============
  /// 两个光点出发 / 到位汇合。
  /// ⚠️ 走 `easeInOutSine` 而不是 `easeInOutCubic`：后者前重后轻，实测到 t=0.70
  /// 就已经画完 97%，最后三成时间在干等（预演时逐帧看图发现的）。
  /// ⚠️ 终点取 0.78 而不是更靠后：合拢之后要留出收尾柔光的窗口（0.78 → 1.00
  /// = 22% ≈ 119ms）。旧值 0.94 只剩 32ms，闪不出任何可感知的东西。
  static const double _traceFrom = 0.03;
  static const double _traceTo = 0.78;

  /// 小圆淡入
  static const double _circleIn = 0.18;

  /// 拖尾弧长（设计单位）与采样段数
  static const double _trailLength = 62.0;
  static const int _trailSteps = 18;

  /// 光点头部亮核半径
  static const double _headRadius = 3.8;

  // ============ 收尾柔光（轮廓合拢后向外发一次光） ============
  /// 区间：与"轮廓合拢"同刻起步，到图标段结束正好散尽
  static const double _glowFrom = _traceTo;
  static const double _glowTo = 1.0;

  /// 峰值透明度 —— 调这一个数就能改"闪"的强弱（实机观感定稿值）
  static const double _glowPeak = 0.68;

  /// 包络：前 30% 用 `easeOutCubic` 冲到峰值，后 70% 用 `(1-y)^1.7` 拖长散掉。
  /// 先快后慢才读作「闪」；反过来是「渐亮」，不像闪光。
  static const double _glowRiseEnd = 0.30;

  /// 扩散半径：σ 从 `_stroke × 0.9`（贴着轮廓）扩到 `_stroke × 3.2`（散开）
  static const double _glowBlurMin = 0.9;
  static const double _glowBlurMax = 3.2;

  /// 闪光期描边本体的加粗系数（读作"边缘自己亮了一下"，而不只是"背后亮了"）
  static const double _glowGain = 1.15;

  /// 画布四周留白（设计单位）＝ 最大模糊半径 × 3.3。
  ///
  /// 高斯尾部要 ≈3σ 才衰减到不可见；留少了边缘会残留可观强度（σ=26.9 时留 44
  /// 还剩约 26%），在浅色调色板上能看出一条淡淡的直角边。
  ///
  /// ⚠️ 辉光必须完整落在画布内，不能指望"绘制溢出 size 不会被裁"：
  /// `CustomPaint` 外面套了 `RepaintBoundary` / `Transform` 之后这个行为是不确定的
  /// （`PictureLayer` 的 bounds 按 size 估）。留白是确定性做法。
  static const double _glowMargin = _stroke * _glowBlurMax * 3.3; // ≈ 88.7

  /// 画布尺寸 = 手柄盒 + 四周留白；painter 里 translate 之后仍按手柄盒坐标绘制
  static const double canvasW = boxW + _glowMargin * 2; // ≈ 417.4
  static const double canvasH = boxH + _glowMargin * 2; // ≈ 353.4

  // ============ 轮廓锚点：顺时针，自顶部中央起 ============
  static const List<Offset> _anchors = <Offset>[
    Offset(120.0, 3.0),   // 顶中央 = 两个光点的出发点
    Offset(180.0, 6.5),
    Offset(205.0, 17.0),  // 右上圆角
    Offset(222.0, 45.0),
    Offset(233.0, 90.0),
    Offset(237.0, 125.0), // 右侧最宽
    Offset(234.0, 146.0),
    Offset(222.0, 167.0),
    Offset(204.0, 172.0), // 右握把底
    Offset(186.0, 161.0), // 右握把内缘上行
    Offset(172.0, 130.0),
    Offset(160.0, 120.0), // 平台右端
    Offset(110.0, 119.0), // 平台 —— 两个光点在此汇合
    Offset(88.0, 120.0),  // 平台左端
    Offset(64.0, 141.0),  // 左握把内缘下行
    Offset(44.0, 163.0),
    Offset(31.0, 171.0),  // 左握把底
    Offset(14.0, 161.0),
    Offset(5.0, 140.0),   // 左侧最宽
    Offset(3.0, 110.0),
    Offset(8.0, 62.0),
    Offset(17.0, 31.0),   // 左上圆角
    Offset(34.0, 14.0),   // 顶边左端
    Offset(76.0, 4.5),
  ];

  /// 闭合轮廓（Catmull-Rom，起点 = 顶中央 —— 两个光点必须从同一点出发）
  static final Path outline = _buildOutline();

  static Path _buildOutline() {
    final n = _anchors.length;
    final p = Path()..moveTo(_anchors[0].dx, _anchors[0].dy);
    for (var i = 0; i < n; i++) {
      final p0 = _anchors[(i - 1 + n) % n];
      final p1 = _anchors[i];
      final p2 = _anchors[(i + 1) % n];
      final p3 = _anchors[(i + 2) % n];
      // Catmull-Rom → 三次贝塞尔：控制点由相邻锚点的差分给出
      final c1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
      );
      final c2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
      );
      p.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return p..close();
  }

  /// 轮廓测量器 —— **只取一次并缓存**。
  ///
  /// 🔴 绝对不要写成「先 `metrics.isEmpty` 再 `metrics.first`」。
  /// `PathMetrics` **不记忆迭代**（引擎 `painting.dart:3198-3206`：`iterator` getter
  /// 每次都返回**同一个** `_PathMetricIterator` 实例），而 `isEmpty` 与 `first`
  /// 各自会消耗一次 `moveNext()`（Dart `Iterable` 默认实现，`iterable.dart:541/641`）。
  /// 手柄轮廓只有一条 contour ⇒ 第一次 `moveNext()` 返回 true、第二次返回 false
  /// ⇒ `.first` 抛 `StateError: No element`。
  ///
  /// 这个异常发生在 `paint()` 内部，会被 `SchedulerBinding._invokeFrameCallback`
  /// 捕获 ⇒ `compositeFrame()` 整帧跳过、画面停在上一帧。真机表现就是
  /// **「只有黑幕、没有任何动画、随后 BPM 直接跳出来」**（已踩过一次）。
  /// 以后要遍历多条 contour，用 `computeMetrics().toList()`。
  ///
  /// 缓存是安全的：`outline` 是 static final、构造后永不修改，测量结果因此恒有效；
  /// 顺带省掉每帧一次 native `PathMeasure` 分配。
  static final ui.PathMetric outlineMetric = outline.computeMetrics().first;

  /// 轮廓周长（设计单位，实测 ≈756）。两个光点各走一半弧长 ⇒ 线速度天然相同。
  static final double outlineLength = outlineMetric.length;

  static double _sub(double v, double a, double b) {
    if (v <= a) return 0.0;
    if (v >= b) return 1.0;
    return (v - a) / (b - a);
  }

  static Color _a(Color c, double o) =>
      c.withOpacity(o.clamp(0.0, 1.0).toDouble());

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.002) return;
    // ⚠️ 用缓存好的测量器。**不要**在这里 `computeMetrics()` 后接 `isEmpty` + `first`
    //    ——原因见 `outlineMetric` 的注释（那个写法会在 paint() 里抛异常、整帧不上屏）。
    final metric = outlineMetric;
    final total = outlineLength;
    if (total <= 0) return;

    canvas.save();
    // 画布比手柄盒大一圈：缩放按画布算，再把手柄盒的原点移到留白中心。
    // （先 scale 后 translate ⇒ translate 的 44 是**设计单位**，会一起被缩放）
    final s = size.width / canvasW;
    canvas.scale(s);
    canvas.translate(_glowMargin, _glowMargin);

    // ⓪ 收尾柔光：画在最底层，辉光从轮廓背后渗出来。
    //    返回值是包络强度，顺带给下面的描边一点加粗。
    final glowEnv = _paintGlow(canvas);

    // 绘制进度（两笔各走一半弧长；缓入缓出让起步/收尾不突兀）
    final travel = Curves.easeInOutSine.transform(
      _sub(t, _traceFrom, _traceTo),
    );
    final half = total * 0.5;
    final headFwd = travel * half; // 顺时针：顶中央 → 底平台
    final headBack = total - travel * half; // 逆时针：另一笔，同样到平台

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * (1.0 + (_glowGain - 1.0) * glowEnv)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _a(ink, opacity);

    // ① 两笔已画出的轮廓
    if (headFwd > 0.5) {
      canvas.drawPath(metric.extractPath(0.0, headFwd), strokePaint);
    }
    if (headBack < total - 0.5) {
      canvas.drawPath(metric.extractPath(headBack, total), strokePaint);
    }

    // ② 两个光点（拖尾 + 亮核）：两笔在底平台合拢后光点熄灭
    final headAlpha = 1.0 - _sub(t, _traceTo, math.min(1.0, _traceTo + 0.06));
    if (headAlpha > 0.01) {
      _paintHead(canvas, metric, headFwd, 1, headAlpha, total);
      _paintHead(canvas, metric, headBack, -1, headAlpha, total);
    }

    // ③ Steam 键小圆（它是"两个光点从同一点出发"的那个点）
    final ci = Curves.easeOutCubic.transform(_sub(t, 0.0, _circleIn));
    if (ci > 0.002) {
      canvas.drawCircle(
        _circleCenter,
        _circleRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _circleStroke
          ..color = _a(ink, 0.88 * ci * opacity),
      );
    }

    canvas.restore();
  }

  /// 收尾柔光：轮廓合拢后，整条边框**向外**发一次光，先快后慢地散掉。
  ///
  /// 实现要点：用**填充**路径配 `BlurStyle.outer`（语义 = `blur(shape) - shape`），
  /// 得到的是手柄形状**之外**的雾。若改用描边 + 模糊，环带的外侧**和内侧**都会发光，
  /// 手柄内部会被一起点亮，就不叫"向外发光"了。
  ///
  /// 返回包络强度 0..1（供描边加粗复用）；返回 0 表示当前帧不发光。
  double _paintGlow(Canvas canvas) {
    final gu = _sub(t, _glowFrom, _glowTo);
    if (gu <= 0.001 || gu >= 0.999) return 0.0;

    // 前段快升、后段拖长散掉 —— 先快后慢才像"闪"
    final env = gu <= _glowRiseEnd
        ? Curves.easeOutCubic.transform(gu / _glowRiseEnd)
        : math
              .pow(1.0 - (gu - _glowRiseEnd) / (1.0 - _glowRiseEnd), 1.7)
              .toDouble();
    final a = _glowPeak * env;
    if (a <= 0.004) return 0.0;

    // 扩散：σ 随进度一路变大，读作"光渗出来再散开"
    final spread = Curves.easeOutCubic.transform(gu);
    final sigma =
        _stroke * (_glowBlurMin + (_glowBlurMax - _glowBlurMin) * spread);

    Paint glowPaint(double alpha, double blur) => Paint()
      ..style = PaintingStyle.fill
      ..color = _a(glow, alpha * opacity)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.outer, blur);

    // 外层：宽、淡，负责"散开"
    canvas.drawPath(outline, glowPaint(a * 0.55, sigma));
    // 内层：窄、亮，负责"贴着边框亮起来"
    canvas.drawPath(outline, glowPaint(a, sigma * 0.45));
    return env;
  }

  /// 一个光点：从头部沿弧长往回采样 [_trailSteps] 段，宽度与透明度由亮到暗。
  ///
  /// [dir] = +1 表示该笔沿弧长增大的方向前进（拖尾在 s 减小侧），-1 反之。
  void _paintHead(
    Canvas canvas,
    ui.PathMetric metric,
    double headS,
    int dir,
    double alpha,
    double total,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.0;

    for (var i = 0; i < _trailSteps; i++) {
      final t0 = i / _trailSteps;
      final t1 = (i + 1) / _trailSteps;
      // tip 侧 t=0（头部，最亮最粗）→ tail 侧 t=1（尾端，渐隐）
      double at(double k) => (headS - dir * _trailLength * k).clamp(0.0, total);
      final s0 = at(t0);
      final s1 = at(t1);
      if ((s1 - s0).abs() < 0.05) continue;
      final a = math.pow(1.0 - t1, 1.6).toDouble();
      if (a <= 0.02) continue;
      final p0 = metric.getTangentForOffset(s0);
      final p1 = metric.getTangentForOffset(s1);
      if (p0 == null || p1 == null) continue;
      paint
        ..color = _a(accent, a * alpha * opacity)
        ..strokeWidth = 1.4 + 4.6 * (1.0 - t0);
      canvas.drawLine(p0.position, p1.position, paint);
    }

    final head = metric.getTangentForOffset(headS.clamp(0.0, total));
    if (head == null) return;
    // 头部外发光
    canvas.drawCircle(
      head.position,
      _headRadius * 2.1,
      Paint()
        ..color = _a(accent, 0.45 * alpha * opacity)
        ..maskFilter = const ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          _headRadius * 2.4,
        ),
    );
    // 头部亮核
    canvas.drawCircle(
      head.position,
      _headRadius,
      Paint()..color = _a(spark, 0.96 * alpha * opacity),
    );
  }

  @override
  bool shouldRepaint(_SteamControllerPainter old) =>
      old.t != t ||
      old.opacity != opacity ||
      old.ink != ink ||
      old.accent != accent ||
      old.spark != spark ||
      old.glow != glow;
}
