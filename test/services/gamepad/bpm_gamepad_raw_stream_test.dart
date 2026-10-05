import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 1 原始输入流单测。
///
/// 覆盖：按键按下/抬起边缘、扳机阈值边缘、基线帧不广播、
/// 每帧快照、断连/换设备/销毁时的 onReset、监听者移除。
/// 语义回调（onConfirm 等）必须**不受影响**。
class _FakeBackend implements BpmGamepadBackend {
  _FakeBackend(this.name);

  @override
  final String name;

  /// 返回一个空闲帧（packet 恒定 → 无按键边缘），
  /// 让 [BpmGamepadService.pollWithBackendForTest] 真正走到「基线/重建基线」分支。
  @override
  GamepadFrame? poll() => const GamepadFrame(packetNumber: 1, buttons: 0);

  @override
  String get sourceKey => name;

  @override
  void dispose() {}
}

/// 收集原始事件的记录器
///
/// [BpmGamepadRawListener] 的成员是**函数字段**（const 数据类），
/// 因此这里也用字段实现（构造器里绑定行为），而不是方法。
class _RawRecorder implements BpmGamepadRawListener {
  _RawRecorder() {
    onButton = (button, down) =>
        buttons.add('${down ? '+' : '-'}${button.name}');
    onFrame = frames.add;
    onReset = () => resets++;
  }

  final List<String> buttons = <String>[];
  final List<GamepadFrame> frames = <GamepadFrame>[];
  int resets = 0;

  @override
  void Function(GamepadRawButton button, bool down)? onButton;

  @override
  void Function(GamepadFrame frame)? onFrame;

  @override
  void Function()? onReset;
}

void main() {
  // 便捷构造：递增 packet 保证 buttonsChanged 为真
  GamepadFrame f(int packet, {int buttons = 0, int lt = 0, int rt = 0,
      int lx = 0, int ly = 0, int rx = 0, int ry = 0}) =>
      GamepadFrame(
        packetNumber: packet,
        buttons: buttons,
        leftTrigger: lt,
        rightTrigger: rt,
        thumbLX: lx,
        thumbLY: ly,
        thumbRX: rx,
        thumbRY: ry,
      );

  group('原始按键边缘', () {
    test('A 按下 → 抬起，产生 +a / -a 两个事件', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1)); // 基线帧
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      svc.consumeFrameForTest(f(3));

      expect(rec.buttons, ['+a', '-a']);
      svc.dispose();
    });

    test('同时按 A+B、只松 B：只有 B 产生抬起事件', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a | XInputButtons.b));
      svc.consumeFrameForTest(f(3, buttons: XInputButtons.a));

      expect(rec.buttons, ['+a', '+b', '-b']);
      svc.dispose();
    });

    test('十字键同样走原始流', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.dpadDown));
      svc.consumeFrameForTest(f(3));

      expect(rec.buttons, ['+dpadDown', '-dpadDown']);
      svc.dispose();
    });

    test('packet 不变时不重复广播（XInput 空闲帧）', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a)); // packet 相同
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));

      expect(rec.buttons, ['+a'], reason: '按住期间 packet 不变, 不应连发');
      svc.dispose();
    });
  });

  group('扳机（模拟量阈值边缘）', () {
    test('LT 越过阈值 → 按下；回落 → 抬起', () {
      final rec = _RawRecorder();
      final semanticShifts = <int>[];
      final svc = BpmGamepadService(
        callbacks: BpmGamepadCallbacks(
          onTriggerShift: semanticShifts.add,
        ),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, lt: 200));
      svc.consumeFrameForTest(f(3, lt: 30));

      expect(rec.buttons, ['+leftTrigger', '-leftTrigger']);
      expect(semanticShifts, [-1], reason: '语义回调行为不变');
      svc.dispose();
    });

    test('未越过阈值不产生事件', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, lt: BpmGamepadService.triggerThreshold - 1));

      expect(rec.buttons, isEmpty);
      svc.dispose();
    });
  });

  group('基线帧与每帧快照', () {
    test('首个（基线）帧不广播按键，也不广播 onFrame', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1, buttons: XInputButtons.a, lx: 1234));

      expect(rec.buttons, isEmpty, reason: '基线帧只建立基线');
      expect(rec.frames, isEmpty);
      svc.dispose();
    });

    test('onFrame 每帧广播原始模拟量', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, lx: 100, ly: -200, rx: 300, ry: -400, lt: 9));

      expect(rec.frames.length, 1);
      expect(rec.frames.single.thumbLX, 100);
      expect(rec.frames.single.thumbLY, -200);
      expect(rec.frames.single.thumbRX, 300);
      expect(rec.frames.single.thumbRY, -400);
      expect(rec.frames.single.leftTrigger, 9);
      svc.dispose();
    });
  });

  group('onReset（按住态安全）', () {
    test('手柄断连 → onReset 恰好一次', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      expect(rec.resets, 0);

      for (var i = 0; i < 4; i++) {
        svc.consumeFrameForTest(null); // disconnectTicks = 4
      }

      expect(rec.resets, 1, reason: '断连必须通知消费方释放按住态');
      svc.dispose();
    });

    test('换设备（重建基线）→ onReset', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.pollWithBackendForTest(_FakeBackend('XInput'));
      svc.pollWithBackendForTest(_FakeBackend('DirectInput'));

      expect(rec.resets, 1, reason: '换数据源 → 重建基线 → 消费方释放按住态');
      svc.dispose();
    });

    test('服务销毁 → onReset（避免按键卡死）', () {
      final rec = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.dispose();

      expect(rec.resets, 1);
    });
  });

  group('多监听者与移除', () {
    test('两个监听者都收到；移除后不再收到', () {
      final a = _RawRecorder();
      final b = _RawRecorder();
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(a)..addRawListener(b);

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      expect(a.buttons, ['+a']);
      expect(b.buttons, ['+a']);

      svc.removeRawListener(b);
      svc.consumeFrameForTest(f(3));

      expect(a.buttons, ['+a', '-a']);
      expect(b.buttons, ['+a'], reason: '已移除的监听者不再收到事件');
      svc.dispose();
    });
  });

  group('语义回调不受影响（回归保护）', () {
    test('A/B/扳机的语义事件照常触发', () {
      var confirm = 0;
      var back = 0;
      final shifts = <int>[];
      final svc = BpmGamepadService(
        callbacks: BpmGamepadCallbacks(
          onConfirm: () => confirm++,
          onBack: () => back++,
          onTriggerShift: shifts.add,
        ),
      );

      svc.consumeFrameForTest(f(1));
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a | XInputButtons.b));
      svc.consumeFrameForTest(f(3, lt: 250));

      expect(confirm, 1);
      expect(back, 1);
      expect(shifts, [-1]);
      svc.dispose();
    });

    test('GamepadRawButton 位掩码与 XInputButtons 一致', () {
      expect(GamepadRawButton.a.mask, XInputButtons.a);
      expect(GamepadRawButton.b.mask, XInputButtons.b);
      expect(GamepadRawButton.x.mask, XInputButtons.x);
      expect(GamepadRawButton.y.mask, XInputButtons.y);
      expect(GamepadRawButton.start.mask, XInputButtons.start);
      expect(GamepadRawButton.back.mask, XInputButtons.back);
      expect(GamepadRawButton.leftShoulder.mask, XInputButtons.leftShoulder);
      expect(GamepadRawButton.rightShoulder.mask, XInputButtons.rightShoulder);
      expect(GamepadRawButton.dpadUp.mask, XInputButtons.dpadUp);
      expect(GamepadRawButton.dpadDown.mask, XInputButtons.dpadDown);
      expect(GamepadRawButton.dpadLeft.mask, XInputButtons.dpadLeft);
      expect(GamepadRawButton.dpadRight.mask, XInputButtons.dpadRight);
      // 扳机是模拟量, 不走位掩码
      expect(GamepadRawButton.leftTrigger.mask, 0);
      expect(GamepadRawButton.rightTrigger.mask, 0);
      // 14 个标识, 与 XInput 按钮面一致
      expect(GamepadRawButton.values.length, 16); // 新增 LS/RS
    });
  });

  group('VoidCallback 形参兼容性（编译期校验）', () {
    test('onReset 可直接接无参回调', () {
      var called = 0;
      void cb() => called++;
      final rec = BpmGamepadRawListener(onReset: cb);
      final svc = BpmGamepadService(
        callbacks: const BpmGamepadCallbacks(),
      )..addRawListener(rec);

      svc.consumeFrameForTest(f(1));
      svc.dispose();

      expect(called, 1);
    });
  });

  group('dispatchGate 互斥闸门（游戏会话期间 BPM 让路）', () {
    test('闸门关闭期间语义事件不派发', () {
      var gate = true;
      var confirm = 0;
      final svc = BpmGamepadService(
        callbacks: BpmGamepadCallbacks(onConfirm: () => confirm++),
      )..dispatchGate = () => gate;

      svc.consumeFrameForTest(f(1)); // 基线
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      expect(confirm, 0, reason: '闸门关着：A 按下不应触发 BPM 语义');
      svc.dispose();
    });

    test('闸门打开时不残留旧边缘（基线随闸门期间推进）', () {
      var gate = true;
      var confirm = 0;
      final svc = BpmGamepadService(
        callbacks: BpmGamepadCallbacks(onConfirm: () => confirm++),
      )..dispatchGate = () => gate;

      svc.consumeFrameForTest(f(1)); // 基线
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a)); // 闸门期间按下
      gate = false;
      svc.consumeFrameForTest(f(3, buttons: XInputButtons.a)); // 仍按住
      expect(confirm, 0, reason: '闸门期间的状态推进不应在打开瞬间补发边缘');
      svc.consumeFrameForTest(f(4)); // 松开
      svc.consumeFrameForTest(f(5, buttons: XInputButtons.a)); // 新的一次按下
      expect(confirm, 1, reason: '闸门打开后新按键恢复正常派发');
      svc.dispose();
    });
  });
}
