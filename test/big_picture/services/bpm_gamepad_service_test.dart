import 'package:flutter/widgets.dart' show TraversalDirection;
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';

/// 假后端: 按序吐帧 (本测试主要走 consumeFrameForTest 直驱状态机,
/// 此类用于 pollWithBackendForTest 的冒烟断言)
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
  final pageShifts = <int>[];
  final directions = <TraversalDirection>[];
  final scrolls = <({double dx, double dy})>[];
  final connections = <bool>[];

  BpmGamepadCallbacks callbacks() => BpmGamepadCallbacks(
        onConfirm: () => confirms.add(1),
        onBack: () => backs.add(1),
        onPageShift: pageShifts.add,
        onDirection: directions.add,
        onScroll: (dx, dy) => scrolls.add((dx: dx, dy: dy)),
        onConnectionChanged: connections.add,
      );
}

BpmGamepadService _makeService(_Events e, {int disconnectTicks = 4}) {
  return BpmGamepadService(
    backend: _FakeBackend(const []),
    pollInterval: const Duration(milliseconds: 1),
    repeatInitialDelay: const Duration(milliseconds: 10),
    repeatInterval: const Duration(milliseconds: 3),
    disconnectTicks: disconnectTicks,
    callbacks: e.callbacks(),
  );
}

void main() {
  group('BpmGamepadService 状态机', () {
    test('首帧仅建立基线,不触发任何事件', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      expect(e.confirms, isEmpty);
      expect(e.directions, isEmpty);
      expect(e.connections, [true]);
      s.dispose();
    });

    test('A 键上升沿触发一次 confirm,长按 (packet 递增) 不重复', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 2, buttons: XInputButtons.a)); // 按下
      for (var i = 0; i < 12; i++) {
        s.consumeFrameForTest(GamepadFrame(
            packetNumber: 3 + i, buttons: XInputButtons.a)); // 按住
      }
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 99, buttons: 0));
      expect(e.confirms.length, 1);
      expect(e.backs, isEmpty);
      s.dispose();
    });

    test('B/LB/RB 分别映射 back 与 ±1 页切换', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 2, buttons: XInputButtons.b));
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 3, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 4, buttons: XInputButtons.rightShoulder));
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 5, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 6, buttons: XInputButtons.leftShoulder));
      expect(e.backs.length, 1);
      expect(e.pageShifts, [1, -1]);
      expect(e.confirms, isEmpty);
      s.dispose();
    });

    test('同一 packet 不重复触发按钮 edge', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      for (var i = 0; i < 8; i++) {
        // packet 恒为 2 (XInput: 状态无变化时 packet 不递增)
        s.consumeFrameForTest(const GamepadFrame(
            packetNumber: 2, buttons: XInputButtons.a));
      }
      expect(e.confirms.length, 1);
      s.dispose();
    });

    test('十字键首按 + initial 延迟后按 repeat 节奏重复', () {
      final e = _Events();
      final s = _makeService(e);
      // tick1: 基线
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      // tick2: dpadUp 按下 → 首按 fire
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 2, buttons: XInputButtons.dpadUp));
      // tick3..11: 按住 9 帧 (tick-since = 1..9 < initial 10) → 无 fire
      for (var i = 0; i < 9; i++) {
        s.consumeFrameForTest(GamepadFrame(
            packetNumber: 3 + i, buttons: XInputButtons.dpadUp));
      }
      expect(e.directions, [TraversalDirection.up]);
      // tick12: tick-since = 10 >= initial 10 → repeat#1
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 12, buttons: XInputButtons.dpadUp));
      expect(e.directions.length, 2);
      // tick13/14: 距上次 fire 1,2 < repeat 3 → 无
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 13, buttons: XInputButtons.dpadUp));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 14, buttons: XInputButtons.dpadUp));
      expect(e.directions.length, 2);
      // tick15: 距上次 fire 3 >= repeat 3 → repeat#2
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 15, buttons: XInputButtons.dpadUp));
      expect(e.directions.length, 3);
      s.dispose();
    });

    test('十字键松开即停止重复', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 2, buttons: XInputButtons.dpadUp));
      for (var i = 0; i < 20; i++) {
        s.consumeFrameForTest(GamepadFrame(
            packetNumber: 3 + i, buttons: XInputButtons.dpadUp));
      }
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 30, buttons: 0));
      final countAfterRelease = e.directions.length;
      for (var i = 0; i < 20; i++) {
        s.consumeFrameForTest(
            GamepadFrame(packetNumber: 40 + i, buttons: 0));
      }
      expect(e.directions.length, countAfterRelease);
      s.dispose();
    });

    test('左摇杆死区内不触发方向; 过死区按主轴方向', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      // 死区内
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 2, buttons: 0, thumbLX: 5000));
      expect(e.directions, isEmpty);
      // 右推过死区 (lx 主轴)
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 3, buttons: 0, thumbLX: 20000, thumbLY: 3000));
      expect(e.directions, [TraversalDirection.right]);
      // 上推 (XInput: sThumbLY **正 = 上**; |ly| > |lx| 取主轴)
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 4, buttons: 0, thumbLX: 1000, thumbLY: 24000));
      expect(e.directions.last, TraversalDirection.up);
      s.dispose();
    });

    test('🔴 摇杆竖直轴极性: 正 = 上 / 右 (与 XInput 规范及右摇杆同约定)', () {
      // v3.10.2 真机 BUG: 旧实现写成 `ly < 0 ? up : down`, 与 XInput 规范相反,
      // 也与同文件右摇杆「上推 ry>0」的约定相反 —— 用户报「向上拉动摇杆,
      // 界面里的效果却是向下」。这条用例把两个轴的极性一起锁死。
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));

      // 上推: ly 为正
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 2, buttons: 0, thumbLX: 0, thumbLY: 24000));
      expect(e.directions.last, TraversalDirection.up,
          reason: 'ly>0 必须是 up —— 反了会让整个上下导航颠倒');

      // 回中, 再下推: ly 为负
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 3, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 4, buttons: 0, thumbLX: 0, thumbLY: -24000));
      expect(e.directions.last, TraversalDirection.down);

      // 回中, 右推 / 左推
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 5, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 6, buttons: 0, thumbLX: 24000, thumbLY: 0));
      expect(e.directions.last, TraversalDirection.right);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 7, buttons: 0));
      s.consumeFrameForTest(const GamepadFrame(
          packetNumber: 8, buttons: 0, thumbLX: -24000, thumbLY: 0));
      expect(e.directions.last, TraversalDirection.left);
      s.dispose();
    });

    test('右摇杆滚动: 上推产生负 dy,死区无滚动', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 2, buttons: 0, thumbRY: 20000)); // 上推
      expect(e.scrolls.length, 1);
      expect(e.scrolls.first.dy, lessThan(0));
      expect(e.scrolls.first.dx, 0);
      final n = e.scrolls.first.dy;
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 3, buttons: 0, thumbRY: 3000)); // 死区
      expect(e.scrolls.length, 1);
      // 幅度线性: 更大幅度 → 更快滚动
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 4, buttons: 0, thumbRY: 30000));
      expect(e.scrolls.last.dy.abs(), greaterThan(n.abs()));
      s.dispose();
    });

    test('断连: 连续 null 判定断连,恢复连接后首帧重建基线', () {
      final e = _Events();
      final s = _makeService(e);
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 1, buttons: 0));
      expect(e.connections, [true]);
      s.consumeFrameForTest(null);
      s.consumeFrameForTest(null);
      s.consumeFrameForTest(null);
      expect(e.connections, [true]); // 未达阈值
      s.consumeFrameForTest(null); // 第 4 帧 → 断连
      expect(e.connections, [true, false]);
      // 恢复: 首帧仅建基线
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 50, buttons: XInputButtons.a));
      expect(e.connections, [true, false, true]);
      expect(e.confirms, isEmpty); // 基线帧不触发
      // 之后正常触发
      s.consumeFrameForTest(const GamepadFrame(packetNumber: 51, buttons: 0));
      s.consumeFrameForTest(
          const GamepadFrame(packetNumber: 52, buttons: XInputButtons.a));
      expect(e.confirms.length, 1);
      s.dispose();
    });

    test('pollWithBackendForTest 冒烟: 后端帧经 poll 管线触发事件', () {
      final e = _Events();
      final s = BpmGamepadService(
        pollInterval: const Duration(milliseconds: 1),
        repeatInitialDelay: const Duration(milliseconds: 10),
        repeatInterval: const Duration(milliseconds: 3),
        callbacks: e.callbacks(),
      );
      expect(s.isBackendAvailable, false);
      s.start(); // 无后端 → no-op,不建 Timer
      s.pollWithBackendForTest(_FakeBackend(const [
        GamepadFrame(packetNumber: 1, buttons: 0), // 基线
        GamepadFrame(packetNumber: 2, buttons: XInputButtons.a),
      ]));
      // poll 只走一帧 (基线建立),confirm 尚未触发
      expect(e.confirms, isEmpty);
      expect(e.connections, [true]);
      s.dispose();
    });

    test('无后端时 start 为 no-op', () {
      final e = _Events();
      final s = BpmGamepadService(callbacks: e.callbacks());
      s.start(); // 不应抛出
      expect(s.isBackendAvailable, false);
      s.dispose();
    });
  });
}
