// BigPictureManager 单元测试
//
// 通过 setFullScreenHandler 注入伪实现,避免在测试环境调用 windowManager。
// 验证 enter/exit/toggle 的状态机与监听器通知行为。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/big_picture/big_picture_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late BigPictureManager manager;
  late List<bool> handlerCalls;

  setUp(() {
    manager = BigPictureManager.instance;
    handlerCalls = <bool>[];
    // 注入伪 handler: 记录调用参数,不调用 windowManager
    manager.setFullScreenHandler((fullscreen) async {
      handlerCalls.add(fullscreen);
    });
  });

  tearDown(() async {
    // 重置到桌面模式,避免影响下一个测试
    if (manager.isActive) {
      await manager.exit();
    }
    // 恢复默认 handler (避免 handler 持续泄漏到其他测试套件)
    manager.setFullScreenHandler((fullscreen) async {});
  });

  test('enter sets isActive=true and notifies listeners', () async {
    bool notified = false;
    manager.addListener(() => notified = true);

    expect(manager.isActive, isFalse);

    await manager.enter();

    expect(manager.isActive, isTrue);
    expect(notified, isTrue);
    expect(handlerCalls, [true]);
  });

  test('exit sets isActive=false and notifies listeners', () async {
    await manager.enter();
    expect(manager.isActive, isTrue);

    bool notified = false;
    manager.addListener(() => notified = true);

    await manager.exit();

    expect(manager.isActive, isFalse);
    expect(notified, isTrue);
    expect(handlerCalls, [true, false]);
  });

  test('toggle flips state from inactive to active', () async {
    expect(manager.isActive, isFalse);

    await manager.toggle();

    expect(manager.isActive, isTrue);
    expect(handlerCalls, [true]);
  });

  test('toggle flips state from active to inactive', () async {
    await manager.enter();
    handlerCalls.clear();

    await manager.toggle();

    expect(manager.isActive, isFalse);
    expect(handlerCalls, [false]);
  });

  test('enter when already active is no-op (idempotent)', () async {
    await manager.enter();
    handlerCalls.clear();
    bool notified = false;
    manager.addListener(() => notified = true);

    await manager.enter();

    expect(manager.isActive, isTrue);
    expect(handlerCalls, isEmpty); // handler 未被调用
    expect(notified, isFalse); // 监听器未被通知
  });

  test('exit when already inactive is no-op (idempotent)', () async {
    expect(manager.isActive, isFalse);
    bool notified = false;
    manager.addListener(() => notified = true);

    await manager.exit();

    expect(manager.isActive, isFalse);
    expect(handlerCalls, isEmpty);
    expect(notified, isFalse);
  });

  group('启动恢复门闩（2026-10-04 修复恢复路径动画闪现/缺失）', () {
    // ⚠️ 单例的 _shellReady 是 final Completer，一旦 signal 永久 completed
    // —— 依赖「未就绪」初态的用例必须排在 signalShellReady 的用例**之前**。
    setUp(() {
      SharedPreferences.setMockInitialValues(
          {BigPictureManager.prefKey: true});
    });

    test('restore 先到：等 signalShellReady 后才 enter（notify 不丢）', () async {
      // 不先 signal —— 模拟 auth 检查未完成、MainContainer 尚未挂载
      final restoring = manager.restoreFromPrefs();

      // 给事件循环若干拍：若门闩没生效，restore 早已跑完 enter
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(manager.isActive, isFalse, reason: '未就绪前不得下发 enter');
      expect(handlerCalls, isEmpty);

      // MainContainer 此刻才挂载
      manager.signalShellReady();

      // 动画协程收尾（监听器代播）
      void onNotify() {
        if (manager.isActive) {
          manager.signalEnterAnimationDone();
          manager.removeListener(onNotify);
        }
      }

      manager.addListener(onNotify);
      await restoring.timeout(const Duration(seconds: 5));

      expect(manager.isActive, isTrue);
      expect(handlerCalls, [true]);
    });

    test('门闩②：enter 返回≠动画播完，restore 等到 done 才返回', () async {
      // shellReady 已被上一用例解闩（幂等补 signal 无害）；本轮只测闩②
      manager.signalShellReady();
      var restoreDone = false;
      final restoring = manager.restoreFromPrefs();
      try {
        // 不 signal 门闩② —— restore 应悬在 enter 之后等待。
        // ⚠️ enter() 内部先等 enterCurtainRise(150ms) 才下发全屏 handler，
        //    此处只断言 isActive 翻转（enter 已下发），不断言 handler 序列。
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(manager.isActive, isTrue, reason: '门闩①已解，enter 已下发');

        // 动画未报完成 → restore 不得返回（后续初始化不得放行）
        unawaited(restoring.then((_) => restoreDone = true));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(restoreDone, isFalse,
            reason: '入场动画未报完成，restore 不得放行后续初始化');
      } finally {
        // 无论断言成败都必须让 restore 收尾，否则悬置协程会污染后续用例
        manager.signalEnterAnimationDone();
        await restoring.timeout(const Duration(seconds: 5));
        expect(restoreDone, isTrue);
      }
    });

    test('signalShellReady 先到：restore 立即 enter，不被 8s 超时拖住', () async {
      // MainContainer 先挂载（signal 先于 restore —— 正常时序）
      manager.signalShellReady();

      // 模拟 MainContainer 动画协程收尾：isActive 翻 true 后立刻解门闩②
      void onNotify() {
        if (manager.isActive) {
          manager.signalEnterAnimationDone();
          manager.removeListener(onNotify);
        }
      }

      manager.addListener(onNotify);

      final watch = Stopwatch()..start();
      await manager.restoreFromPrefs();
      watch.stop();

      expect(manager.isActive, isTrue);
      // 全屏下发过至少一次（放宽为 contains：悬置协程/tearDown 可能混入 false）
      expect(handlerCalls.contains(true), isTrue);
      // 若门闩失灵会等满 8s 超时；正常应远小于 5s
      expect(watch.elapsed.inSeconds, lessThan(5));
    });
  });
}
