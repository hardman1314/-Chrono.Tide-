import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/services/motion_preference.dart';

/// v3.10 R4 全局「减少动效」偏好 —— 读写往返与通知语义
///
/// 覆盖范围说明（诚实标注）：
/// - 本文件只测偏好本身（默认值 / 持久化 / 幂等 / 通知时序 / 测试钩子）。
/// - **不测**「开关切换后背景层真的换成静态首帧」——那需要 `ThemeStorage`
///   落盘 + `ImageProvider` 真实解码，而 flutter_tester 的假 async 环境无法
///   驱动解码调度（`dev_probe/RESULTS.md` §7，Phase 0 已踩过）。
///   渲染侧接线按项目惯例列入真机走查
///   （`docs/DEV/features/animated_background_implementation_plan.md` §11）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kKey = 'reduce_motion_background';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MotionPreference.resetForTest();
  });

  tearDown(MotionPreference.resetForTest);

  group('默认值（对存量用户零行为变化）', () {
    test('未设置过 prefs → false，且 loaded 置位', () async {
      await MotionPreference.instance.load();
      expect(MotionPreference.instance.reduceMotion, isFalse);
      expect(MotionPreference.instance.loaded, isTrue);
    });
  });

  group('读写往返', () {
    test('setReduceMotion(true) 落到 prefs，重建单例后能读回', () async {
      await MotionPreference.instance.load();
      await MotionPreference.instance.setReduceMotion(true);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kKey), isTrue);

      MotionPreference.resetForTest();
      await MotionPreference.instance.load();
      expect(MotionPreference.instance.reduceMotion, isTrue);
    });

    test('prefs 已有 true → load 后即为 true（升级用户沿用旧值）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{kKey: true});
      await MotionPreference.instance.load();
      expect(MotionPreference.instance.reduceMotion, isTrue);
    });
  });

  group('通知语义', () {
    test('load 完成时通知一次', () async {
      int n = 0;
      MotionPreference.instance.addListener(() => n++);
      await MotionPreference.instance.load();
      expect(n, 1);
    });

    test('重复 load 幂等：不重读、不重复通知', () async {
      await MotionPreference.instance.load();
      int n = 0;
      MotionPreference.instance.addListener(() => n++);
      await MotionPreference.instance.load();
      expect(n, 0);
    });

    test('setReduceMotion 只在值真正变化时通知', () async {
      await MotionPreference.instance.load();
      int n = 0;
      MotionPreference.instance.addListener(() => n++);

      await MotionPreference.instance.setReduceMotion(false); // 与当前值相同
      expect(n, 0);

      await MotionPreference.instance.setReduceMotion(true);
      expect(n, 1);

      await MotionPreference.instance.setReduceMotion(true); // 再设同值
      expect(n, 1);
    });

    test('通知发生在落盘之前：回调里读到的已是新值', () async {
      // 背景层的降级判定在 setState 时同步读取 reduceMotion，
      // 若通知晚于写盘，开关会因为写盘 await 而出现"点了一下没反应"的观感。
      await MotionPreference.instance.load();
      bool? valueSeenInNotify;
      MotionPreference.instance.addListener(() {
        valueSeenInNotify = MotionPreference.instance.reduceMotion;
      });
      await MotionPreference.instance.setReduceMotion(true);
      expect(valueSeenInNotify, isTrue);
    });
  });

  group('测试钩子', () {
    test('seedForTest 绕过 prefs 并通知', () async {
      int n = 0;
      MotionPreference.instance.addListener(() => n++);
      MotionPreference.instance.seedForTest(reduceMotion: true);

      expect(MotionPreference.instance.reduceMotion, isTrue);
      expect(MotionPreference.instance.loaded, isTrue);
      expect(n, 1);
    });

    test('resetForTest 后 load 重新读 prefs（不吃旧缓存）', () async {
      await MotionPreference.instance.load();
      await MotionPreference.instance.setReduceMotion(true);

      MotionPreference.resetForTest();
      SharedPreferences.setMockInitialValues(<String, Object>{kKey: false});
      await MotionPreference.instance.load();
      expect(MotionPreference.instance.reduceMotion, isFalse);
    });
  });
}
