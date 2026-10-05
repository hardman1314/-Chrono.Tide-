// BpmEnterOverlay（BPM 入场「手柄图标」层）widget 测试
//
// 回归背景（真机踩到过，见 docs/DEV/features/bpm_mode_transition.md §6）：
//   painter 里曾写成
//     final metrics = outline.computeMetrics();
//     if (metrics.isEmpty) return;
//     final metric = metrics.first;
//   引擎的 PathMetrics **不记忆迭代**（sky_engine painting.dart:3205，`iterator`
//   getter 每次返回**同一个** `_PathMetricIterator` 实例），而 `isEmpty` 与 `first`
//   各自消耗一次 `moveNext()`（Dart core iterable.dart:541 / 641）⇒ 手柄轮廓只有
//   一条 contour，第二次 `moveNext()` 返回 false ⇒ `.first` 抛 `StateError: No element`。
//   异常发生在 paint() 内，被 SchedulerBinding._invokeFrameCallback 捕获 ⇒
//   compositeFrame() 整帧跳过 ⇒ 真机表现「幕布之后全黑、任何动画都没有」。
//
// 本测试用 `tester.takeException()` 把「绘制期异常」钉住：只要 paint() 里再抛任何
// 东西，下面任意一条都会失败。这是本仓库对「跑不了的渲染」唯一可行的自动化护栏。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/widgets/bpm_enter_overlay.dart';

void main() {
  Future<void> pumpOverlay(
    WidgetTester tester, {
    required double progress,
    required double reveal,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 1280,
            height: 720,
            child: BpmEnterOverlay(progress: progress, reveal: reveal),
          ),
        ),
      ),
    );
  }

  group('绘制期不抛异常（回归：PathMetrics 迭代被 isEmpty 消耗）', () {
    testWidgets('整个图标进度区间（淡入 / 描出 / 柔光 / 终态）', (tester) async {
      // 0.00 淡入起、0.06 淡入完、0.03~0.78 描出段、0.78~1.00 柔光段
      const probes = <double>[
        0.0, 0.01, 0.06, 0.2, 0.45, 0.7, 0.78, 0.85, 0.9, 0.95, 1.0,
      ];
      for (final t in probes) {
        await pumpOverlay(tester, progress: t, reveal: 0.0);
        expect(
          tester.takeException(),
          isNull,
          reason: 'progress=$t reveal=0.0 时 paint() 抛异常',
        );
      }
    });

    testWidgets('揭开段（reveal 0→1）逐帧绘制', (tester) async {
      for (final rv in <double>[0.0, 0.25, 0.5, 0.75, 0.99, 1.0]) {
        await pumpOverlay(tester, progress: 1.0, reveal: rv);
        expect(
          tester.takeException(),
          isNull,
          reason: 'progress=1.0 reveal=$rv 时 paint() 抛异常',
        );
      }
    });

    testWidgets('同一进度重复绘制（shouldRepaint 路径）', (tester) async {
      await pumpOverlay(tester, progress: 0.5, reveal: 0.0);
      await pumpOverlay(tester, progress: 0.5, reveal: 0.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('组树契约', () {
    testWidgets('progress=0 时整体透明 ⇒ 不建画布（稳态不占图层）', (tester) async {
      await pumpOverlay(tester, progress: 0.0, reveal: 0.0);
      expect(find.byType(CustomPaint), findsNothing);
    });

    testWidgets('描出中 ⇒ 存在一块自带 RepaintBoundary 的独立画布', (tester) async {
      await pumpOverlay(tester, progress: 0.5, reveal: 0.0);
      expect(find.byType(CustomPaint), findsOneWidget);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });

    testWidgets('reveal=1 ⇒ 图标层退场，不留残影', (tester) async {
      await pumpOverlay(tester, progress: 1.0, reveal: 1.0);
      expect(find.byType(CustomPaint), findsNothing);
    });

    testWidgets('画布比手柄盒大一圈（给收尾柔光留白），且宽高比 = canvasW/canvasH', (tester) async {
      await pumpOverlay(tester, progress: 0.5, reveal: 0.0);
      // w = (720 * 0.30).clamp(240, 520) = 240（720*0.3=216 ⇒ 触下限 240）
      const expectedW = 240.0;
      final box = tester.getSize(find.byType(CustomPaint));
      // 画布 = w * canvasW/boxW × w * canvasH/boxW，canvasW=boxW+2*margin、同 margin
      expect(box.width, greaterThan(expectedW));
      expect(box.width / box.height, closeTo(417.408 / 353.408, 0.01));
    });
  });
}
