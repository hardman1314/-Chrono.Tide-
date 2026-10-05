// 游戏运行任务状态横幅 —— 状态中枢单元测试
//
// 覆盖需求：
// 1. 启动任务创建后处于「正在启动」，进程确认存活后切「运行中」并开始计时
// 2. 游戏自行退出 → 短暂保留展示本次总时长 → 平滑淡出移除
// 3. 启动失败 → 常驻展示错误原因
// 4. 解除监控 → 放弃时长统计（调用 registry.stopTracking），游戏继续运行
// 5. 关闭游戏 → 终止进程（调用 registry.terminateGame）
// 6. 多游戏同时运行 → 多条任务独立计时、独立管控
//
// 说明：LocalGameRegistry 的所有依赖都通过 @visibleForTesting 钩子
// （debugActiveSessionDirsOverride / debugStopTrackingCalls / debugTerminateCalls）
// 打桩，测试不真正启动任何进程、不做任何游玩时长落盘。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/services/running_tasks_service.dart';

LibraryGame _game(String title, String metaDir) => LibraryGame(
      title: title,
      directoryPath: metaDir,
      metaDataDir: metaDir,
      installedAt: '',
    );

/// 让出事件循环，等待 ticker / 定时器推进
Future<void> _pump(Duration d) => Future<void>.delayed(d);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late LocalGameRegistry registry;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('ct_running_tasks_');
    // 必须在任何路径 getter 首次解析之前设置，否则不生效
    PathHelper.exeDirOverride = tmpDir.path;
  });

  tearDownAll(() async {
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  setUp(() {
    registry = LocalGameRegistry.instance;
    registry.debugActiveSessionDirsOverride = <String>{};
    registry.debugStopTrackingCalls.clear();
    registry.debugTerminateCalls.clear();
    RunningTasksService.resetForTest();

    // 缩短时间常量，用毫秒级等待验证完整流转
    final svc = RunningTasksService.instance;
    svc.debugTickInterval = const Duration(milliseconds: 50);
    svc.debugExitBannerDuration = const Duration(milliseconds: 200);
    svc.debugLaunchTimeout = const Duration(milliseconds: 150);
  });

  tearDown(() {
    registry.debugActiveSessionDirsOverride = null;
    registry.debugStopTrackingCalls.clear();
    registry.debugTerminateCalls.clear();
    RunningTasksService.resetForTest();
  });

  group('任务创建与运行中切换', () {
    test('beginTask 创建 launching 任务且尚未开始计时', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));

      expect(svc.tasks.length, 1);
      expect(svc.tasks.first.status, RunningTaskStatus.launching);
      expect(svc.tasks.first.title, '游戏A');
      // 未确认进程存活前不计时
      expect(svc.tasks.first.runningSince, isNull);
    });

    test('会话确认存活后切 running 并开始墙钟计时', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));

      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);

      final task = svc.tasks.first;
      expect(task.status, RunningTaskStatus.running);
      expect(task.runningSince, isNotNull);

      // 墙钟口径：按传入的 now 计算，切后台也照走
      final start = task.runningSince!;
      expect(task.elapsedSeconds(start.add(const Duration(seconds: 90))), 90);
      expect(
        task.elapsedSeconds(start.add(const Duration(hours: 1, minutes: 2))),
        3720,
      );
    });

    test('重复 beginTask 同一游戏不产生第二条任务', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      svc.beginTask(_game('游戏A', 'dir_a'));

      expect(svc.tasks.length, 1);
    });
  });

  group('游戏退出与淡出', () {
    test('会话消失 → exiting 展示本次时长 → 保留期后淡出移除', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      // 模拟进程已确认存活
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);
      expect(svc.tasks.first.status, RunningTaskStatus.running);

      // 模拟玩家在游戏内退出：注册表会话消失
      registry.debugActiveSessionDirsOverride = <String>{};
      await _pump(const Duration(milliseconds: 120));

      expect(svc.tasks.first.status, RunningTaskStatus.exiting);
      expect(svc.tasks.first.finalSeconds, greaterThanOrEqualTo(0));
      // 保留期内仍在列表（展示本次总时长）
      expect(svc.tasks, isNotEmpty);

      // 保留期满 → 进入淡出
      await _pump(const Duration(milliseconds: 300));
      expect(svc.tasks.firstOrNull?.fading, isTrue);

      // 退场动画结束 → 真正移除
      await _pump(
          RunningTasksService.fadeOutDuration + const Duration(milliseconds: 80));
      expect(svc.tasks, isEmpty);
    });

    test('墙钟时长在 exiting 后定格不再增长', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);

      registry.debugActiveSessionDirsOverride = <String>{};
      await _pump(const Duration(milliseconds: 120));

      final frozen = svc.tasks.first.finalSeconds;
      await _pump(const Duration(milliseconds: 100));
      expect(svc.tasks.first.finalSeconds, frozen);
    });
  });

  group('启动失败', () {
    test('markFailed 常驻展示错误原因', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));

      svc.markFailed('dir_a', '无法启动「游戏A」');

      expect(svc.tasks.first.status, RunningTaskStatus.failed);
      expect(svc.tasks.first.errorMessage, '无法启动「游戏A」');

      // 失败态不会因为会话不存在而被回收，需用户手动关闭
      await _pump(const Duration(milliseconds: 300));
      expect(svc.tasks, isNotEmpty);

      svc.dismiss('dir_a');
      await _pump(
          RunningTasksService.fadeOutDuration + const Duration(milliseconds: 80));
      expect(svc.tasks, isEmpty);
    });

    test('启动超时兜底：久未确认进程存活则判为失败', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));

      // 会话存在但进程始终没起来（Magpie 会话注册失败等场景）
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      await _pump(const Duration(milliseconds: 400));

      expect(svc.tasks.first.status, RunningTaskStatus.failed);
      expect(svc.tasks.first.errorMessage, contains('启动超时'));
    });
  });

  group('横幅内操作', () {
    test('解除监控 → 放弃时长统计并淡出移除', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);

      await svc.detach('dir_a');

      // 关键是确实调用了注册表的停止追踪，而不是只把横幅藏起来
      expect(registry.debugStopTrackingCalls, contains('dir_a'));
      expect(registry.debugTerminateCalls, isNot(contains('dir_a')));
      expect(svc.tasks.firstOrNull?.fading, isTrue);

      await _pump(
          RunningTasksService.fadeOutDuration + const Duration(milliseconds: 80));
      expect(svc.tasks, isEmpty);
    });

    test('关闭游戏 → 终止进程并淡出移除', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);

      await svc.kill('dir_a');

      expect(registry.debugTerminateCalls, contains('dir_a'));
      expect(svc.tasks.firstOrNull?.fading, isTrue);

      await _pump(
          RunningTasksService.fadeOutDuration + const Duration(milliseconds: 80));
      expect(svc.tasks, isEmpty);
    });

    test('解除监控期间连点不会重复触发进程操作', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);

      // 不等第一个完成就再点一次
      final first = svc.detach('dir_a');
      final second = svc.detach('dir_a');
      await Future.wait<void>([first, second]);

      expect(registry.debugStopTrackingCalls.where((d) => d == 'dir_a').length, 1);
    });
  });

  group('多游戏并行', () {
    test('多条任务独立计时、独立管控', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      svc.beginTask(_game('游戏B', 'dir_b'));

      registry.debugActiveSessionDirsOverride = {'dir_a', 'dir_b'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);
      registry.onGameSessionConfirmed?.call('游戏B', 'dir_b', null);
      expect(svc.tasks.length, 2);
      expect(
        svc.tasks.every((t) => t.status == RunningTaskStatus.running),
        isTrue,
      );

      // 只关掉 A，B 不受影响
      await svc.kill('dir_a');
      expect(registry.debugTerminateCalls, contains('dir_a'));
      expect(registry.debugTerminateCalls, isNot(contains('dir_b')));

      await _pump(
          RunningTasksService.fadeOutDuration + const Duration(milliseconds: 80));
      expect(svc.tasks.length, 1);
      expect(svc.tasks.first.title, '游戏B');
      expect(svc.tasks.first.status, RunningTaskStatus.running);

      // B 的会话仍在，不会被 A 的退出连带回收
      await _pump(const Duration(milliseconds: 300));
      expect(svc.tasks.length, 1);
      expect(svc.tasks.first.title, '游戏B');
    });
  });

  group('收起态未读提示（bannerEventEpoch）', () {
    test('初始为 0；新建任务不计数（数量已可见）', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      expect(svc.bannerEventEpoch, 0);
      svc.beginTask(_game('游戏A', 'dir_a'));
      expect(svc.bannerEventEpoch, 0);
    });

    test('确认进程存活（切 running）触发 +1', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);
      expect(svc.bannerEventEpoch, 1);
    });

    test('markFailed 触发 +1', () {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      svc.markFailed('dir_a', '无法启动');
      expect(svc.bannerEventEpoch, 1);
    });

    test('游戏内退出（tick 检测会话消失）触发 +1', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      registry.onGameSessionConfirmed?.call('游戏A', 'dir_a', null);
      final before = svc.bannerEventEpoch;
      expect(before, 1);

      registry.debugActiveSessionDirsOverride = <String>{};
      await _pump(const Duration(milliseconds: 120));
      expect(svc.bannerEventEpoch, before + 1);
    });

    test('启动超时兜底判失败触发 +1', () async {
      final svc = RunningTasksService.instance;
      svc.initialize();
      svc.beginTask(_game('游戏A', 'dir_a'));
      registry.debugActiveSessionDirsOverride = {'dir_a'};
      await _pump(const Duration(milliseconds: 400));
      expect(svc.bannerEventEpoch, 1);
    });
  });
}
