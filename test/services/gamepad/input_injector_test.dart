import 'dart:io';

import 'package:chrono_tide/services/gamepad/input_injector.dart';
import 'package:flutter_test/flutter_test.dart';

// Phase 1 注入层单测。
//
// ⚠️ 本文件**绝不真的调用 SendInput**（那会把按键打到用户当前窗口）。
//    所有行为测试都走 FakeSink；只有「结构体布局」这类纯静态量才触碰生产实现。

class RecordedCall {
  RecordedCall(this.kind, this.args);

  final String kind;
  final Map<String, Object?> args;

  @override
  String toString() => '$kind$args';
}

class FakeSink implements SyntheticInputSink {
  FakeSink({this.isAvailable = true});

  @override
  bool isAvailable;

  final List<RecordedCall> calls = <RecordedCall>[];

  List<RecordedCall> get keyCalls => calls.where((c) => c.kind == 'key').toList();

  @override
  int sendKey(int vk, {required bool down, bool scanCode = false}) {
    calls.add(RecordedCall('key', {'vk': vk, 'down': down, 'scanCode': scanCode}));
    return 1;
  }

  @override
  int scanCodeFor(int vk) {
    calls.add(RecordedCall('scan', {'vk': vk}));
    return 0x1C; // 假值：Enter 的扫描码
  }

  @override
  int sendMouseMoveAbsolute(int normalizedX, int normalizedY) {
    calls.add(RecordedCall('move', {'x': normalizedX, 'y': normalizedY}));
    return 1;
  }

  @override
  int sendMouseRelativeMove(int dx, int dy) {
    calls.add(RecordedCall('move_rel', {'dx': dx, 'dy': dy}));
    return 1;
  }

  @override
  int sendMouseWheel(int delta) {
    calls.add(RecordedCall('wheel', {'delta': delta}));
    return 1;
  }

  @override
  int sendMouseButton({required bool down, bool right = false}) {
    calls.add(RecordedCall('btn', {'down': down, 'right': right}));
    return 1;
  }
}

class FakeForeground implements ForegroundChecker {
  FakeForeground({this.isAvailable = true, this.pid});

  @override
  bool isAvailable;

  int? pid;

  @override
  int? foregroundPid() => pid;
}

void main() {
  group('FFI 结构体布局（x64 应与 Win32 C 定义一致）', () {
    test('INPUT = 40B / KEYBDINPUT = 24B / MOUSEINPUT = 32B', () {
      if (!Platform.isWindows) return; // 仅在 Windows 上断言
      // 40 = type(4) + padding(4) + union(32)
      expect(SendInputSink.debugInputStructSize, 40);
      // 24 = wVk(2)+wScan(2)+dwFlags(4)+time(4)+ULONG_PTR(8) → 对齐到 8
      expect(SendInputSink.debugKeybdInputSize, 24);
      // 32 = 4×4 + ULONG_PTR(8) → 对齐到 8
      expect(SendInputSink.debugMouseInputSize, 32);
    });
  });

  group('前台守卫（P0 安全闸门）', () {
    test('未绑定目标 → noTarget，且一次注入都不发', () async {
      final sink = FakeSink();
      final fg = FakeForeground(pid: 42);
      final injector = InputInjector(sink: sink, foreground: fg);

      final r = await injector.tapKey(0x0D);

      expect(r.outcome, InjectionOutcome.noTarget);
      expect(r.accepted, 0);
      expect(sink.calls, isEmpty, reason: '守卫必须早于任何 sink 调用');
    });

    test('目标不在前台 → foregroundMismatch，且一次注入都不发（防按键外泄）', () async {
      final sink = FakeSink();
      final fg = FakeForeground(pid: 42);
      final injector = InputInjector(sink: sink, foreground: fg)
        ..bindTargetPid(777);

      final r = await injector.tapKey(0x0D);

      expect(r.outcome, InjectionOutcome.foregroundMismatch);
      expect(r.accepted, 0);
      expect(sink.calls, isEmpty, reason: '不在前台时绝不能注入到别的窗口');
    });

    test('平台不支持 → unsupported', () async {
      final sink = FakeSink(isAvailable: false);
      final fg = FakeForeground(pid: 42);
      final injector = InputInjector(sink: sink, foreground: fg)
        ..bindTargetPid(42);

      final r = await injector.tapKey(0x0D);

      expect(r.outcome, InjectionOutcome.unsupported);
      expect(sink.calls, isEmpty);
    });

    test('前台 PID 查询失败（null）→ 按不安全处理', () async {
      final sink = FakeSink();
      final fg = FakeForeground(pid: null);
      final injector = InputInjector(sink: sink, foreground: fg)
        ..bindTargetPid(42);

      final r = await injector.tapKey(0x0D);

      expect(r.outcome, InjectionOutcome.foregroundMismatch);
      expect(sink.calls, isEmpty);
    });

    test('目标在前台 → sent，accepted 累加 down+up', () async {
      final sink = FakeSink();
      final fg = FakeForeground(pid: 42);
      final injector = InputInjector(sink: sink, foreground: fg)
        ..bindTargetPid(42);

      final r = await injector.tapKey(0x0D);

      expect(r.outcome, InjectionOutcome.sent);
      expect(r.isSent, isTrue);
      expect(r.accepted, 2);
    });

    test('解绑后立即回到 noTarget', () async {
      final sink = FakeSink();
      final fg = FakeForeground(pid: 42);
      final injector = InputInjector(sink: sink, foreground: fg)
        ..bindTargetPid(42);
      expect((await injector.tapKey(0x0D)).isSent, isTrue);

      injector.bindTargetPid(null);

      expect((await injector.tapKey(0x0D)).outcome, InjectionOutcome.noTarget);
      expect(sink.keyCalls.length, 2, reason: '解绑后不应再新增按键调用');
    });
  });

  group('键盘注入', () {
    test('tapKey：先按下再抬起，顺序正确', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.tapKey(0x0D);

      expect(sink.keyCalls.map((c) => c.args['down']).toList(), [true, false]);
      expect(sink.keyCalls.every((c) => c.args['vk'] == 0x0D), isTrue);
      expect(sink.keyCalls.every((c) => c.args['scanCode'] == false), isTrue);
    });

    test('保持时长 = 配置值（默认 50ms）', () async {
      final sink = FakeSink();
      final sleeps = <Duration>[];
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
        hold: const Duration(milliseconds: 80),
        sleep: (d) async => sleeps.add(d),
      )..bindTargetPid(1);

      await injector.tapKey(0x0D);

      expect(sleeps, [const Duration(milliseconds: 80)]);
      expect(InputInjector.defaultHold, const Duration(milliseconds: 50));
    });

    test('scanCode 模式：down/up 都带 scanCode 标记', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.tapKey(0x41, scanCode: true);

      expect(sink.keyCalls.length, 2);
      expect(sink.keyCalls.every((c) => c.args['scanCode'] == true), isTrue);
    });

    test('holdKeyDown / releaseKey：用于「按住 Ctrl 快进」这类语义', () {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      expect(injector.holdKeyDown(0x11).isSent, isTrue);
      expect(injector.releaseKey(0x11).isSent, isTrue);

      expect(sink.keyCalls.map((c) => c.args['down']).toList(), [true, false]);
      expect(sink.keyCalls.every((c) => c.args['vk'] == 0x11), isTrue);
    });

    test('守卫不通过时 holdKeyDown 同样被拦（不会漏出按住态）', () {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 999),
      )..bindTargetPid(1);

      expect(injector.holdKeyDown(0x11).outcome, InjectionOutcome.foregroundMismatch);
      expect(sink.calls, isEmpty);
    });
  });

  group('鼠标注入', () {
    test('clickAt：归一化坐标映射到 0..65535', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.clickAt(0.5, 0.0);

      final move = sink.calls.firstWhere((c) => c.kind == 'move');
      expect(move.args['x'], 32768); // 0.5*65535 = 32767.5 → round = 32768
      expect(move.args['y'], 0);
    });

    test('clickAt：越界坐标被 clamp', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.clickAt(-3.0, 9.9);

      final move = sink.calls.firstWhere((c) => c.kind == 'move');
      expect(move.args['x'], 0);
      expect(move.args['y'], 65535);
    });

    test('clickAt：单击 = 一次 down+up；双击 = 两次', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.clickAt(0.5, 0.5);
      expect(sink.calls.where((c) => c.kind == 'btn').length, 2);

      sink.calls.clear();
      await injector.clickAt(0.5, 0.5, doubleClick: true);
      expect(sink.calls.where((c) => c.kind == 'btn').length, 4);
      expect(
        sink.calls.where((c) => c.kind == 'btn').map((c) => c.args['down']),
        [true, false, true, false],
      );
    });

    test('clickAt：右键使用 right 标记', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 1),
      )..bindTargetPid(1);

      await injector.clickAt(0.5, 0.5, right: true);

      final btns = sink.calls.where((c) => c.kind == 'btn');
      expect(btns.every((c) => c.args['right'] == true), isTrue);
    });

    test('clickAt：守卫不通过时不发任何鼠标事件', () async {
      final sink = FakeSink();
      final injector = InputInjector(
        sink: sink,
        foreground: FakeForeground(pid: 999),
      )..bindTargetPid(1);

      final r = await injector.clickAt(0.5, 0.5);

      expect(r.outcome, InjectionOutcome.foregroundMismatch);
      expect(sink.calls, isEmpty);
    });
  });

  group('可诊断性', () {
    test('isForegroundGuardPassing 反映真实判定', () {
      final fg = FakeForeground(pid: 7);
      final injector = InputInjector(sink: FakeSink(), foreground: fg);

      expect(injector.isForegroundGuardPassing, isFalse, reason: '未绑定目标');

      injector.bindTargetPid(7);
      expect(injector.isForegroundGuardPassing, isTrue);

      fg.pid = 8;
      expect(injector.isForegroundGuardPassing, isFalse);

      injector.bindTargetPid(null);
      expect(injector.targetPid, isNull);
    });
  });
}
