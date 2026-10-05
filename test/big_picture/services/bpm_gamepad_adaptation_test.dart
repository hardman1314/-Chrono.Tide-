import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';

/// 假后端: 按序吐帧; 帧用尽后固定返回最后一帧 (末帧为 null 即模拟掉线)
class _FakeBackend implements BpmGamepadBackend {
  @override
  final String name;

  final List<GamepadFrame?> frames;
  int _i = 0;

  _FakeBackend(this.frames, {this.name = 'Fake'});

  @override
  String get sourceKey => name;

  @override
  GamepadFrame? poll() {
    if (frames.isEmpty) return null;
    if (_i >= frames.length) return frames.last;
    return frames[_i++];
  }

  @override
  void dispose() {}
}

/// 事件收集器
class _Events {
  final confirms = <int>[];
  final backs = <int>[];
  final contextMenus = <int>[];
  final marks = <int>[];
  final systemMenus = <int>[];
  final viewToggles = <int>[];
  final pageShifts = <int>[];
  final triggerShifts = <int>[];
  final connections = <bool>[];

  BpmGamepadCallbacks callbacks() => BpmGamepadCallbacks(
        onConfirm: () => confirms.add(1),
        onBack: () => backs.add(1),
        onContextMenu: () => contextMenus.add(1),
        onMark: () => marks.add(1),
        onSystemMenu: () => systemMenus.add(1),
        onViewToggle: () => viewToggles.add(1),
        onPageShift: pageShifts.add,
        onTriggerShift: triggerShifts.add,
        onConnectionChanged: connections.add,
      );
}

GamepadFrame _idle(int packet) =>
    GamepadFrame(packetNumber: packet, buttons: 0);

GamepadFrame _btn(int packet, int buttons) =>
    GamepadFrame(packetNumber: packet, buttons: buttons);

void main() {
  group('XInputBackend.selectSlot 多槽位仲裁 (v3.9 修复只读槽0)', () {
    test('无粘住槽时取首个有输入的槽', () {
      final slots = <GamepadFrame?>[
        _idle(1),
        _btn(2, XInputButtons.a),
        null,
        null,
      ];
      final r = XInputBackend.selectSlot((s) => slots[s], null);
      expect(r.activeSlot, 1);
      expect(r.frame!.buttons, XInputButtons.a);
    });

    test('槽0 连接但空闲时不会挡住真手柄 (切到有输入的槽2)', () {
      // 对应真机现象: slot0 是「占位却不报按键」的虚拟设备
      final slots = <GamepadFrame?>[
        _idle(5),
        null,
        _btn(7, XInputButtons.b),
        null,
      ];
      final r = XInputBackend.selectSlot((s) => slots[s], 0);
      expect(r.activeSlot, 2);
      expect(r.frame!.buttons, XInputButtons.b);
    });

    test('粘住槽有输入时固定用它 (不被其它槽抢焦)', () {
      final slots = <GamepadFrame?>[
        _btn(1, XInputButtons.a),
        _btn(1, XInputButtons.b),
        null,
        null,
      ];
      final r = XInputBackend.selectSlot((s) => slots[s], 0);
      expect(r.activeSlot, 0);
      expect(r.frame!.buttons, XInputButtons.a);
    });

    test('粘住槽掉线后回到扫描, 选中新的有输入槽', () {
      final slots = <GamepadFrame?>[
        null,
        null,
        _btn(9, XInputButtons.start),
        null,
      ];
      final r = XInputBackend.selectSlot((s) => slots[s], 0);
      expect(r.activeSlot, 2);
      expect(r.frame!.buttons, XInputButtons.start);
    });

    test('槽0 空闲且无其它输入 → 回落槽0 空闲帧 (仍算已连接)', () {
      final slots = <GamepadFrame?>[_idle(3), null, null, null];
      final r = XInputBackend.selectSlot((s) => slots[s], null);
      expect(r.activeSlot, 0);
      expect(r.frame, isNotNull);
      expect(r.frame!.buttons, 0);
    });

    test('无粘住槽且全部无输入 → 回落首个已连接槽', () {
      final slots = <GamepadFrame?>[null, _idle(4), null, null];
      final r = XInputBackend.selectSlot((s) => slots[s], null);
      expect(r.activeSlot, 1);
      expect(r.frame!.buttons, 0);
    });

    test('全部未连接 → frame 与 activeSlot 均为 null', () {
      final r = XInputBackend.selectSlot((s) => null, 0);
      expect(r.frame, isNull);
      expect(r.activeSlot, isNull);
    });
  });

  group('XInputBackend.frameHasActivity', () {
    test('按住任意键算有输入', () {
      expect(XInputBackend.frameHasActivity(_btn(1, XInputButtons.y)), isTrue);
    });

    test('摇杆越过死区算有输入', () {
      expect(
        XInputBackend.frameHasActivity(
          const GamepadFrame(packetNumber: 1, buttons: 0, thumbLX: 20000),
        ),
        isTrue,
      );
    });

    test('摇杆在死区内不算输入', () {
      expect(
        XInputBackend.frameHasActivity(
          const GamepadFrame(packetNumber: 1, buttons: 0, thumbLX: 3000),
        ),
        isFalse,
      );
    });

    test('扳机越过阈值算有输入', () {
      expect(
        XInputBackend.frameHasActivity(
          const GamepadFrame(packetNumber: 1, buttons: 0, rightTrigger: 200),
        ),
        isTrue,
      );
    });

    test('完全空闲不算输入', () {
      expect(XInputBackend.frameHasActivity(_idle(1)), isFalse);
    });
  });

  group('BpmGamepadService 多后端仲裁', () {
    test('前一个后端无数据时回退到下一个后端', () {
      final e = _Events();
      final s = BpmGamepadService(
        backends: <BpmGamepadBackend>[
          _FakeBackend(const [], name: 'A'),
          _FakeBackend(const [GamepadFrame(packetNumber: 1, buttons: 0)],
              name: 'B'),
        ],
        pollInterval: const Duration(milliseconds: 1),
        callbacks: e.callbacks(),
      );
      expect(s.isBackendAvailable, isTrue);
      s.pollOnceForTest();
      expect(e.connections, [true]);
      expect(s.activeBackendName, 'B');
      s.dispose();
    });

    test('活跃后端掉线后切到下一后端, 切换帧只建基线不误触发', () {
      final e = _Events();
      final a = _FakeBackend(<GamepadFrame?>[_idle(1), null], name: 'A');
      final b = _FakeBackend(<GamepadFrame?>[
        _btn(1, XInputButtons.a), // 切换帧 → 只建基线
        _idle(2), // 松手
        _btn(3, XInputButtons.a), // 再按 → 应当触发
      ], name: 'B');
      final s = BpmGamepadService(
        backends: <BpmGamepadBackend>[a, b],
        pollInterval: const Duration(milliseconds: 1),
        callbacks: e.callbacks(),
      );

      s.pollOnceForTest(); // A 建基线
      expect(e.connections, [true]);
      expect(e.confirms, isEmpty);

      s.pollOnceForTest(); // A 掉线 → 切到 B, 该帧只建基线
      expect(s.activeBackendName, 'B');
      expect(e.confirms, isEmpty, reason: '换设备首帧不得触发按钮边缘');

      s.pollOnceForTest(); // B 松手帧 (packet 变, 但无新按下)
      expect(e.confirms, isEmpty);

      s.pollOnceForTest(); // B 重新按下 A 键 → 触发
      expect(e.confirms.length, 1);
      s.dispose();
    });
  });

  group('扩展按键语义 (X / Y / Start / Back / LT / RT)', () {
    test('X/Y/Start/Back 各自触发一次对应语义', () {
      final e = _Events();
      final s = BpmGamepadService(
        backend: _FakeBackend(const []),
        pollInterval: const Duration(milliseconds: 1),
        callbacks: e.callbacks(),
      );
      s.consumeFrameForTest(_idle(1));
      s.consumeFrameForTest(_btn(2, XInputButtons.x));
      s.consumeFrameForTest(_idle(3));
      s.consumeFrameForTest(_btn(4, XInputButtons.y));
      s.consumeFrameForTest(_idle(5));
      s.consumeFrameForTest(_btn(6, XInputButtons.start));
      s.consumeFrameForTest(_idle(7));
      s.consumeFrameForTest(_btn(8, XInputButtons.back));

      expect(e.contextMenus.length, 1, reason: 'X → 动作菜单');
      expect(e.marks.length, 1, reason: 'Y → 标记');
      expect(e.systemMenus.length, 1, reason: 'Start → 系统菜单');
      expect(e.viewToggles.length, 1, reason: 'Back → 视图切换');
      expect(e.confirms, isEmpty);
      s.dispose();
    });

    test('LT/RT 越阈值各触发一次翻屏, 按住不重复', () {
      final e = _Events();
      final s = BpmGamepadService(
        backend: _FakeBackend(const []),
        pollInterval: const Duration(milliseconds: 1),
        callbacks: e.callbacks(),
      );
      s.consumeFrameForTest(_idle(1));
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 2, buttons: 0, rightTrigger: 255));
      for (var i = 0; i < 5; i++) {
        s.consumeFrameForTest(GamepadFrame(
            packetNumber: 3 + i, buttons: 0, rightTrigger: 255));
      }
      s.consumeFrameForTest(_idle(20));
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 21, buttons: 0, leftTrigger: 200));

      expect(e.triggerShifts, [1, -1]);
      s.dispose();
    });

    test('扳机在阈值之下不触发', () {
      final e = _Events();
      final s = BpmGamepadService(
        backend: _FakeBackend(const []),
        pollInterval: const Duration(milliseconds: 1),
        callbacks: e.callbacks(),
      );
      s.consumeFrameForTest(_idle(1));
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 2, buttons: 0, rightTrigger: 100));
      expect(e.triggerShifts, isEmpty);
      s.dispose();
    });
  });
}
