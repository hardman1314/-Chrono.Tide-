/// `NsfwDetectionService` 槽位调度并发测试（v2.1.5）。
///
/// ## 这个文件存在的理由
///
/// v2.1.4 把「未判定封面」从原图直显改为模糊预览后，单 isolate 串行推理
/// 的吞吐瓶颈被直接暴露成「库页/探索页全屏模糊迟迟不解除」（用户实测）：
/// 几百张封面 ~1-2s/张串行，积压 10 分钟以上。v2.1.5 改为 3 worker 并行
/// + 槽位调度（取到任务立即派发、不阻塞取后续任务）。
///
/// 真实推理依赖模型文件与 isolate，单测不可控；本文件用
/// [NsfwDetectionService.debugProcessOverride] 注入可控执行体，
/// 只验证**调度行为**：
/// 1. 并行度上限 = 3（槽位生效，不会无限并发）；
/// 2. 并行度下限 ≥ 2（确实并行了，不是改回串行）；
/// 3. 所有任务全部完成（completer 无泄漏）。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_service.dart';

NsfwDetection _ok() => NsfwDetection(
      imgW: 100,
      imgH: 100,
      detectedAtMs: 0,
      boxes: const <NsfwBox>[],
    );

void main() {
  setUp(() {
    NsfwDetectionService.resetForTest();
    NsfwDetectionService.debugProcessOverride = null;
  });

  tearDown(() {
    NsfwDetectionService.debugProcessOverride = null;
  });

  test('槽位调度：6 个任务并行度落在 [2,3] 区间且全部完成', () async {
    int inFlight = 0;
    int maxInFlight = 0;

    NsfwDetectionService.debugProcessOverride =
        (String key, String filePath) async {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      // 模拟推理耗时：3 槽位下 6 个任务约 2 波 ≈ 100ms+
      await Future<void>.delayed(const Duration(milliseconds: 50));
      inFlight--;
      return _ok();
    };

    final NsfwDetectionService svc = NsfwDetectionService.instance;
    final List<Future<NsfwDetection?>> futures = <Future<NsfwDetection?>>[
      for (int i = 0; i < 6; i++)
        svc.detectFile('C:\\lib\\game$i\\cover.jpg'),
    ];

    final List<NsfwDetection?> results = await Future.wait(futures);

    expect(results.length, 6, reason: '全部任务完成，completer 无泄漏');
    for (final NsfwDetection? r in results) {
      expect(r, isNotNull);
    }
    expect(maxInFlight, lessThanOrEqualTo(3),
        reason: '并行度不得超过 worker 槽位数（3）');
    expect(maxInFlight, greaterThanOrEqualTo(2),
        reason: '槽位调度必须真正并行——若退化为串行该断言失败');
  });

  test('槽位空出时高优先级先于剩余低优先级被派发', () async {
    final List<String> order = <String>[];
    NsfwDetectionService.debugProcessOverride =
        (String key, String filePath) async {
      order.add(key);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return _ok();
    };

    final NsfwDetectionService svc = NsfwDetectionService.instance;
    // 6 个 normal 占满并持续占用槽位，high 在队列非空时入队——
    // 第 4 波出队的必须是 high（优先队列语义），normal 4-6 靠后。
    final List<Future<NsfwDetection?>> futures = <Future<NsfwDetection?>>[
      for (int i = 0; i < 6; i++)
        svc.detectFile('C:\\lib\\n$i\\cover.jpg'),
    ];
    final Future<NsfwDetection?> high =
        svc.detectFile('C:\\lib\\vip\\cover.jpg', highPriority: true);
    futures.add(high);

    await Future.wait(futures);

    // 首批槽位数按实现常量推导（v2.1.14 起 worker 数是性能调参常量，
    // 硬编码 3 会在调参时假失败）
    final int slots = NsfwDetectionService.workerSlotsForTest;
    expect(order.length, 7);
    expect(
      order.take(slots).every((String k) => k.contains(r'n')),
      isTrue,
      reason: '首批 $slots 个槽位被先入队的 normal 占用',
    );
    expect(order[slots], contains('vip'),
        reason: '槽位一空出必须先取 high 队列——这是双优先级队列的回归守卫');
  });
}
