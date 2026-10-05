
import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:chrono_tide/services/gamepad/gamepad_adaptation_session.dart';
import 'package:chrono_tide/services/gamepad/gamepad_profile.dart';
import 'package:chrono_tide/services/gamepad/input_injector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2 映射分发器 + 会话生命周期单测。
///
/// 全部走 FakeSink / FakeForeground / FakeBackend —— **绝不真注入**。
/// 覆盖：tap / hold / repeat 三种语义、未映射静默、mouse_move/wheel 跳过、
/// 前台守卫拦截、reset 安全阀、会话组装与停止。

class FakeSink implements SyntheticInputSink {
  final calls = <String>[];

  @override
  bool isAvailable = true;

  @override
  int sendKey(int vk, {required bool down, bool scanCode = false}) {
    calls.add('${down ? "+" : "-"}key$vk');
    return 1;
  }

  @override
  int scanCodeFor(int vk) => 0;

  @override
  int sendMouseMoveAbsolute(int normalizedX, int normalizedY) {
    calls.add('move');
    return 1;
  }

  @override
  @override
  int sendMouseRelativeMove(int dx, int dy) {
    calls.add('move $dx $dy');
    return 1;
  }

  @override
  int sendMouseWheel(int delta) {
    calls.add('wheel $delta');
    return 1;
  }

  int sendMouseButton({required bool down, bool right = false}) {
    calls.add('${down ? "+" : "-"}mouse${right ? "R" : "L"}');
    return 1;
  }

  int count(String c) => calls.where((x) => x == c).length;
}

class FakeForeground implements ForegroundChecker {
  FakeForeground({this.isAvailable = true, this.pid});

  @override
  bool isAvailable;

  int? pid;

  @override
  int? foregroundPid() => pid;
}

/// 按队列出帧的假后端（驱动服务层状态机）
class FakeBackend implements BpmGamepadBackend {
  FakeBackend(this._name);

  final String _name;
  final queue = <GamepadFrame?>[];
  bool disposed = false;

  @override
  String get name => _name;

  @override
  String get sourceKey => _name;

  @override
  GamepadFrame? poll() => queue.isEmpty ? null : queue.removeAt(0);

  @override
  void dispose() => disposed = true;

  void pushIdle(int packet) =>
      queue.add(GamepadFrame(packetNumber: packet, buttons: 0));

  void pushButtons(int packet, int buttons) =>
      queue.add(GamepadFrame(packetNumber: packet, buttons: buttons));
}

GamepadMappingDispatcher _dispatcher(
  FakeSink sink, {
  required Map<GamepadSource, GamepadMapping> mappings,
  int targetPid = 1,
  Duration repeatInitialDelay = const Duration(milliseconds: 10),
  Duration repeatInterval = const Duration(milliseconds: 10),
}) {
  final d = GamepadMappingDispatcher(
    sink: sink,
    foreground: FakeForeground(pid: targetPid),
    mappings: mappings,
    repeatInitialDelay: repeatInitialDelay,
    repeatInterval: repeatInterval,
    sleep: (d) async {},
  )..bindTargetPid(targetPid);
  return d;
}

void main() {
  group('tap 语义', () {
    test('按下注入完整一次（down+up），抬起无动作', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.a: const GamepadMapping(
            source: GamepadSource.a,
            action: GamepadAction.key(13),
            mode: GamepadMappingMode.tap),
      });

      d.onButton(GamepadRawButton.a, true);
      await pumpEventQueue();
      expect(sink.calls, ['+key13', '-key13']);
      expect(d.injectedCount, 1);

      d.onButton(GamepadRawButton.a, false);
      await pumpEventQueue();
      expect(sink.calls.length, 2, reason: 'tap 抬起无动作');
    });

    test('连按两次 = 两次注入', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.a: const GamepadMapping(
            source: GamepadSource.a,
            action: GamepadAction.key(13),
            mode: GamepadMappingMode.tap),
      });

      d.onButton(GamepadRawButton.a, true);
      d.onButton(GamepadRawButton.a, false);
      d.onButton(GamepadRawButton.a, true);
      d.onButton(GamepadRawButton.a, false);
      await pumpEventQueue();

      expect(sink.count('+key13'), 2);
      expect(sink.count('-key13'), 2);
    });
  });

  group('hold 语义（galgame 的 Ctrl 快进）', () {
    test('按下只注入 down；抬起才注入 up', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.rb: const GamepadMapping(
            source: GamepadSource.rb,
            action: GamepadAction.key(17),
            mode: GamepadMappingMode.hold),
      });

      d.onButton(GamepadRawButton.rightShoulder, true);
      await pumpEventQueue();
      expect(sink.calls, ['+key17'], reason: '按住期间只应有 down');

      d.onButton(GamepadRawButton.rightShoulder, false);
      await pumpEventQueue();
      expect(sink.calls, ['+key17', '-key17']);
    });

    test('重复按下（未抬起时）不重复注入 down', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.rb: const GamepadMapping(
            source: GamepadSource.rb,
            action: GamepadAction.key(17),
            mode: GamepadMappingMode.hold),
      });

      d.onButton(GamepadRawButton.rightShoulder, true);
      d.onButton(GamepadRawButton.rightShoulder, true);
      d.onButton(GamepadRawButton.rightShoulder, true);
      await pumpEventQueue();

      expect(sink.count('+key17'), 1);
    });
  });

  group('repeat 语义（连发）', () {
    test('按住期间按间隔连发，抬起停止', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.y: const GamepadMapping(
            source: GamepadSource.y,
            action: GamepadAction.key(32),
            mode: GamepadMappingMode.repeat),
      });

      d.onButton(GamepadRawButton.y, true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final tapsWhileHeld = sink.count('+key32');
      expect(tapsWhileHeld, greaterThanOrEqualTo(3), reason: '连发应持续注入');

      d.onButton(GamepadRawButton.y, false);
      await pumpEventQueue(); // 先让在途 tap 的记录落账，再取基准
      final tapsAtRelease = sink.count('+key32');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(sink.count('+key32'), tapsAtRelease, reason: '抬起后连发停止');
    });
  });

  group('鼠标键映射', () {
    test('tap：按下注入鼠标左键 down+up', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.rt: const GamepadMapping(
            source: GamepadSource.rt,
            action: GamepadAction.mouseButton('left'),
            mode: GamepadMappingMode.tap),
      });

      d.onButton(GamepadRawButton.rightTrigger, true);
      await pumpEventQueue();
      expect(sink.calls, ['+mouseL', '-mouseL']);
    });

    test('hold：按下鼠标右键，抬起才释放', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.lt: const GamepadMapping(
            source: GamepadSource.lt,
            action: GamepadAction.mouseButton('right'),
            mode: GamepadMappingMode.hold),
      });

      d.onButton(GamepadRawButton.leftTrigger, true);
      await pumpEventQueue();
      expect(sink.calls, ['+mouseR']);

      d.onButton(GamepadRawButton.leftTrigger, false);
      await pumpEventQueue();
      expect(sink.calls, ['+mouseR', '-mouseR']);
    });
  });

  group('容错与守卫', () {
    test('未映射的按键静默忽略', () {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.a: const GamepadMapping(
            source: GamepadSource.a,
            action: GamepadAction.key(13),
            mode: GamepadMappingMode.tap),
      });

      d.onButton(GamepadRawButton.b, true);
      d.onButton(GamepadRawButton.start, true);
      d.onButton(GamepadRawButton.dpadUp, true);

      expect(sink.calls, isEmpty);
      expect(d.injectedCount, 0);
    });

    test('mouse_move / mouse_wheel 本期跳过（Phase 4 实现）', () {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.x: const GamepadMapping(
            source: GamepadSource.x,
            action: GamepadAction.mouseMove(),
            mode: GamepadMappingMode.tap),
        GamepadSource.y: const GamepadMapping(
            source: GamepadSource.y,
            action: GamepadAction.mouseWheel(),
            mode: GamepadMappingMode.tap),
      });

      d.onButton(GamepadRawButton.x, true);
      d.onButton(GamepadRawButton.y, true);

      expect(sink.calls, isEmpty);
      expect(d.skippedCount, 2);
    });

    test('🔴 前台守卫：目标不在前台时不注入（计数进 blocked）', () async {
      final sink = FakeSink();
      final d = GamepadMappingDispatcher(
        sink: sink,
        foreground: FakeForeground(pid: 999), // 与目标 1 不一致
        mappings: {
          GamepadSource.a: const GamepadMapping(
              source: GamepadSource.a,
              action: GamepadAction.key(13),
              mode: GamepadMappingMode.tap),
        },
      )..bindTargetPid(1);

      d.onButton(GamepadRawButton.a, true);
      await pumpEventQueue();

      expect(sink.calls, isEmpty, reason: '守卫必须早于任何 sink 调用');
      expect(d.blockedCount, 1);
      expect(d.injectedCount, 0);
    });
  });

  group('reset 安全阀', () {
    test('reset 释放按住的键与鼠标键，并停掉连发', () async {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.rb: const GamepadMapping(
            source: GamepadSource.rb,
            action: GamepadAction.key(17),
            mode: GamepadMappingMode.hold),
        GamepadSource.lt: const GamepadMapping(
            source: GamepadSource.lt,
            action: GamepadAction.mouseButton('right'),
            mode: GamepadMappingMode.hold),
        GamepadSource.y: const GamepadMapping(
            source: GamepadSource.y,
            action: GamepadAction.key(32),
            mode: GamepadMappingMode.repeat),
      });

      d.onButton(GamepadRawButton.rightShoulder, true);
      d.onButton(GamepadRawButton.leftTrigger, true);
      d.onButton(GamepadRawButton.y, true);
      await pumpEventQueue();
      final tapsAtReset = sink.count('+key32');

      d.reset();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sink.count('-key17'), 1, reason: '按住的 Ctrl 必须被释放');
      expect(sink.count('-mouseR'), 1, reason: '按住的鼠标右键必须被释放');
      expect(sink.count('+key32'), tapsAtReset, reason: '连发必须停止');
    });
  });

  group('会话生命周期', () {
    test('组装成功：后端名/设备/统计可用', () {
      final backend = FakeBackend('SDL3');
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(
          enabled: true,
          mappings: [
            GamepadMapping(
                source: GamepadSource.a,
                action: GamepadAction.key(13),
                mode: GamepadMappingMode.tap),
          ],
        ),
        backends: [backend],
        sink: FakeSink(),
        foreground: FakeForeground(pid: 42),
      );

      expect(session, isNotNull);
      expect(session!.isRunning, isTrue);
      expect(session.activeBackendName, 'SDL3');
      expect(session.targetPid, 42);
      session.stop();
    });

    test('profile.enabled=false → 不启动', () {
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(enabled: false),
        backends: [FakeBackend('X')],
        sink: FakeSink(),
        foreground: FakeForeground(pid: 42),
      );
      expect(session, isNull);
    });

    test('映射表为空 → 不启动', () {
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(enabled: true),
        backends: [FakeBackend('X')],
        sink: FakeSink(),
        foreground: FakeForeground(pid: 42),
      );
      expect(session, isNull);
    });

    test('后端列表为空 → 不启动', () {
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(
            enabled: true,
            mappings: [
              GamepadMapping(
                  source: GamepadSource.a,
                  action: GamepadAction.key(13),
                  mode: GamepadMappingMode.tap),
            ]),
        backends: const [],
        sink: FakeSink(),
        foreground: FakeForeground(pid: 42),
      );
      expect(session, isNull);
    });

    test('端到端（假后端）：帧进 → A 按下 → 注入 Enter', () async {
      final backend = FakeBackend('SDL3');
      final sink = FakeSink();
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(
            enabled: true,
            mappings: [
              GamepadMapping(
                  source: GamepadSource.a,
                  action: GamepadAction.key(13),
                  mode: GamepadMappingMode.tap),
            ]),
        backends: [backend],
        sink: sink,
        foreground: FakeForeground(pid: 42),
      );
      expect(session, isNotNull);

      // 帧 1 = 基线（连接），帧 2 = 按下 A，帧 3 = 抬起
      backend.pushIdle(1);
      backend.pushButtons(2, XInputButtons.a);
      backend.pushIdle(3);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();

      expect(sink.count('+key13'), 1, reason: 'A 按下应注入 Enter');
      expect(sink.count('-key13'), 1);
      expect(session!.injectedCount, 1);

      session.stop();
      expect(session.isRunning, isFalse);
      expect(backend.disposed, isTrue);
    });

    test('stop() 释放按住态（手柄断连安全阀）', () async {
      final backend = FakeBackend('SDL3');
      final sink = FakeSink();
      final session = GamepadAdaptationSession.tryStart(
        targetPid: 42,
        profile: const GamepadProfile(
            enabled: true,
            mappings: [
              GamepadMapping(
                  source: GamepadSource.rb,
                  action: GamepadAction.key(17),
                  mode: GamepadMappingMode.hold),
            ]),
        backends: [backend],
        sink: sink,
        foreground: FakeForeground(pid: 42),
      );

      backend.pushIdle(1);
      backend.pushButtons(2, XInputButtons.rightShoulder);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();
      expect(sink.count('+key17'), 1);

      session!.stop();
      expect(sink.count('-key17'), 1, reason: '停止会话必须释放按住的 Ctrl');
    });
  });
  group('轴响应曲线与光标/滚轮（Phase 3 新增）', () {
    test('axisResponse：死区裁剪 + 二次缓动', () {
      // 死区内 → 0
      expect(GamepadMappingDispatcher.axisResponse(0, 0.15), 0);
      expect(
          GamepadMappingDispatcher.axisResponse((0.15 * 32767).round(), 0.15),
          0);
      // 死区外单调递增，满偏 = 1
      final half =
          GamepadMappingDispatcher.axisResponse(16383, 0.15);
      final full = GamepadMappingDispatcher.axisResponse(32767, 0.15);
      expect(half, greaterThan(0));
      expect(half, lessThan(full));
      expect(full, closeTo(1.0, 0.001));
      // 二次曲线：半程响应 < 线性一半
      expect(half, lessThan(0.5));
    });

    test('cursorDeltaForFrame：正=上约定转鼠标 dy（取负）', () {
      // 上推（后端已取反 → thumbLY 为正）→ 鼠标 dy 应为负（上移）
      final (dx, dy) = GamepadMappingDispatcher.cursorDeltaForFrame(
          thumbLX: 0, thumbLY: 32767, deadzone: 0.15, sensitivity: 1.0);
      expect(dy, lessThan(0), reason: '上推光标上移（dy 负）');
      expect(dx, 0);
      // 右推 → dx 正
      final (dx2, dy2) = GamepadMappingDispatcher.cursorDeltaForFrame(
          thumbLX: 32767, thumbLY: 0, deadzone: 0.15, sensitivity: 1.0);
      expect(dx2, greaterThan(0));
      expect(dy2, 0);
    });

    test('dpad 光标步进：按下注入一次相对移动', () {
      final sink = FakeSink();
      final d = _dispatcher(sink, mappings: {
        GamepadSource.dpadUp: const GamepadMapping(
            source: GamepadSource.dpadUp,
            action: GamepadAction.mouseMove(direction: 'up', stepPixels: 24),
            mode: GamepadMappingMode.tap),
      });
      d.onButton(GamepadRawButton.dpadUp, true);
      expect(sink.calls.contains('move 0 -24'), isTrue, reason: 'dpad 步进注入相对移动');
    });
  });
}
