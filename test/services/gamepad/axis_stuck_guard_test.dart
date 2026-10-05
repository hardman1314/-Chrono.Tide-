// 手柄适配 —— 摇杆轴漂移免疫守卫（AxisStuckGuard）单测
//
// 背景（2026-09-27 真机）：盖世 G8+ 固件级轴值残留 —— 系统自带手柄光标
// 功能同样「大幅甩杆后光标持续单向漂移、断控无法恢复」。守卫以「波动
// 区间 + 大偏移持续」判定卡死冻结，以「回中位 / 反向大推」解锁；
// 本文件锁定状态机行为（防「放不掉的漂移」回归）。
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/gamepad/gamepad_adaptation_session.dart';

void main() {
  // G8+ 卡死形态：大幅甩杆后轴值停在大偏移（如 +20000），
  // 伴随 ±几十 LSB 的 ADC 抖动
  int stuckValue(int jitter) => 20000 + jitter;

  group('AxisStuckGuard 冻结判定', () {
    test('正常操作（帧间大变化）永不冻结', () {
      final g = AxisStuckGuard();
      for (var i = 0; i < 200; i++) {
        final v = (i % 2 == 0) ? 20000 : -20000; // 大幅来回
        expect(g.process(v, 0), isFalse, reason: '帧 $i');
      }
      expect(g.isFrozen, isFalse);
    });

    test('🔴 突变（甩杆）后恒值大偏移持续 30 帧 → 冻结', () {
      final g = AxisStuckGuard();
      expect(g.process(0, 0), isFalse, reason: '首帧建基线');
      expect(g.process(stuckValue(0), 0), isFalse,
          reason: '突变帧（单帧跳 20000 > 30%）标记嫌疑但不立即冻结');
      var frozenAt = -1;
      for (var i = 0; i < 100; i++) {
        if (g.process(stuckValue(0), 0)) {
          frozenAt = i;
          break;
        }
      }
      expect(frozenAt, 29, reason: '突变后定格累计 30 帧（~0.5s）触发（0 计下标 29）');
      expect(g.justEnteredFrozen, isTrue, reason: '进入冻结的帧给边沿通知');
    });

    test('🔴 按住摇杆匀速移光标（渐进入驻大偏移 + 定格）→ 永不冻结', () {
      final g = AxisStuckGuard();
      // 渐进：每帧 +2000（人手推杆速度），10 帧从 0 到 20000
      for (var v = 0; v <= 20000; v += 2000) {
        expect(g.process(v, 0), isFalse, reason: '渐进进入大偏移不标记嫌疑');
      }
      // 之后按住定格 100 帧 —— 合法操作，绝不冻结
      for (var i = 0; i < 100; i++) {
        expect(g.process(20000, 0), isFalse, reason: '帧 $i：按住移光标被误冻结');
      }
    });

    test('🔴 突变后轴值恢复活动（回弹/真实操作）→ 撤销嫌疑 → 定格不冻结', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0); // 突变（甩）
      g.process(14000, 0); // 回弹第一帧（6000 < 突变阈值 → 正常运动帧）
      g.process(8000, 0); // 回弹落定（6000）→ 进入定格的最后一跳非突变
      for (var i = 0; i < 60; i++) {
        expect(g.process(8000, 0), isFalse, reason: '分帧回弹后定格不冻结');
      }
    });

    test('🔴 甩杆突变 + 卡死值带 ADC 抖动（±100）同样冻结（区间判定）', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0); // 突变
      var frozen = false;
      for (var i = 0; i < 60; i++) {
        if (g.process(stuckValue(i % 3 * 100 - 100), 0)) {
          frozen = true;
          break;
        }
      }
      expect(frozen, isTrue);
    });

    test('小偏移（死区内）恒值不冻结（摇杆静置漂移是常态）', () {
      final g = AxisStuckGuard();
      for (var i = 0; i < 200; i++) {
        expect(g.process(800 + i % 3, 0), isFalse,
            reason: '死区内的小漂移不该触发冻结');
      }
    });
  });

  group('AxisStuckGuard 解锁条件', () {
    test('冻结后轴值微抖（±100）保持冻结（拒绝抖动解锁）', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0);
      for (var i = 0; i < 50; i++) {
        g.process(stuckValue(0), 0);
      }
      expect(g.isFrozen, isTrue);
      for (var i = 0; i < 50; i++) {
        g.process(stuckValue(i % 5 * 50), 0); // ±200 抖动 < unlockDelta
      }
      expect(g.isFrozen, isTrue, reason: '抖动不该解锁');
    });

    test('🔴 冻结后回中位 → 解锁，后续帧恢复正常消费', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0);
      for (var i = 0; i < 50; i++) {
        g.process(stuckValue(0), 0);
      }
      expect(g.isFrozen, isTrue);
      // 解锁帧本身返回 true（该帧轴值刚恢复，跳过）
      expect(g.process(0, 0), isTrue);
      expect(g.isFrozen, isFalse);
      expect(g.process(30000, 0), isFalse, reason: '解锁后正常操作不再冻结');
    });

    test('🔴 冻结后反向大推 → 立即解锁（卡死轴不会自己变号，反向一推即恢复）',
        () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0);
      for (var i = 0; i < 50; i++) {
        g.process(stuckValue(0), 0);
      }
      expect(g.isFrozen, isTrue);
      expect(g.process(-25000, 0), isTrue, reason: '解锁帧跳过');
      expect(g.isFrozen, isFalse);
      expect(g.process(-25000, 0), isFalse, reason: '反向操作正常消费');
    });

    test('Y 轴甩杆卡死同样触发（双轴联合判定）', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(0, stuckValue(0)); // Y 突变
      var frozen = false;
      for (var i = 0; i < 60; i++) {
        if (g.process(0, stuckValue(i % 2 * 80))) {
          frozen = true;
          break;
        }
      }
      expect(frozen, isTrue);
    });

    test('reset 清空全部状态（断连/换设备场景）', () {
      final g = AxisStuckGuard();
      g.process(0, 0);
      g.process(stuckValue(0), 0);
      for (var i = 0; i < 50; i++) {
        g.process(stuckValue(0), 0);
      }
      expect(g.isFrozen, isTrue);
      g.reset();
      expect(g.isFrozen, isFalse);
      expect(g.process(stuckValue(0), 0), isFalse, reason: '重置后重新累计');
    });
  });
}
