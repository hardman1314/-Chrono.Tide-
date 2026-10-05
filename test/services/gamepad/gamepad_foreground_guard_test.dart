// 手柄适配 —— 目录级前台守卫（GamepadForegroundGuard）单测
//
// 背景（2026-09-27 真机）：启动器型游戏（白色相簿2 launcher→真游戏）的
// bestPid 与真前台 pid 不同，纯 pid 比对守卫把全部注入拦截 —— 表现为
// 「进游戏后手柄完全无法操作」。守卫放宽为「pid 匹配 或 前台 exe 在
// 游戏目录内」，本文件锁定判定逻辑。
//
// exe 路径的真实查询（OpenProcess + QueryFullProcessImageNameW）是 FFI，
// 不在单测范围（真机验证）；这里测纯函数与 guard 的 pid 归一分支。
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/gamepad/gamepad_adaptation_session.dart';
import 'package:chrono_tide/services/gamepad/input_injector.dart';

/// 假前台 checker：可编程 pid / 可编程 exe 能力（exe 能力模拟「查不到」）
class _FakeForegroundChecker implements ForegroundChecker {
  _FakeForegroundChecker(this.pid);

  int? pid;

  @override
  bool get isAvailable => true;

  @override
  int? foregroundPid() => pid;
}

void main() {
  group('GamepadForegroundGuard.exePathInsideGameDir（纯函数）', () {
    test('同目录 exe 放行（正斜杠/大小写/尾分隔符归一）', () {
      expect(
        GamepadForegroundGuard.exePathInsideGameDir(
            'D:/Games/WA2/gc.exe', 'D:\\Games\\WA2\\'),
        isTrue,
      );
      expect(
        GamepadForegroundGuard.exePathInsideGameDir(
            'd:\\games\\wa2\\launcher.exe', 'D:/Games/WA2'),
        isTrue,
      );
    });

    test('子目录 exe 放行（游戏目录的子进程）', () {
      expect(
        GamepadForegroundGuard.exePathInsideGameDir(
            'D:\\Games\\WA2\\bin\\game.exe', 'D:\\Games\\WA2'),
        isTrue,
      );
    });

    test('目录外 exe 拦截', () {
      expect(
        GamepadForegroundGuard.exePathInsideGameDir(
            'C:\\Windows\\explorer.exe', 'D:\\Games\\WA2'),
        isFalse,
      );
    });

    test('🔴 前缀相似目录不误判（Foo vs FooBar）', () {
      expect(
        GamepadForegroundGuard.exePathInsideGameDir(
            'D:\\Games\\FooBar\\game.exe', 'D:\\Games\\Foo'),
        isFalse,
      );
    });

    test('空目录 / 空 exe → 拦截（退化为纯 pid 比对）', () {
      expect(GamepadForegroundGuard.exePathInsideGameDir('', 'D:\\G'), isFalse);
      expect(
          GamepadForegroundGuard.exePathInsideGameDir('D:\\G\\a.exe', ''),
          isFalse);
    });
  });

  group('GamepadForegroundGuard.wrap pid 归一', () {
    const targetPid = 36176;

    test('gameDirectoryPath 为空 → 原样透传 inner（纯 pid 比对）', () {
      final inner = _FakeForegroundChecker(12345);
      final wrapped = GamepadForegroundGuard.wrap(
        inner: inner,
        targetPid: targetPid,
        gameDirectoryPath: '',
      );
      expect(identical(wrapped, inner), isTrue);
    });

    test('inner 为 null（非 Windows）→ 返回 null', () {
      expect(
        GamepadForegroundGuard.wrap(
            inner: null, targetPid: targetPid, gameDirectoryPath: 'D:\\G'),
        isNull,
      );
    });

    test('pid 精确匹配 → 放行（返回 targetPid）', () {
      final wrapped = GamepadForegroundGuard.wrap(
        inner: _FakeForegroundChecker(targetPid),
        targetPid: targetPid,
        gameDirectoryPath: 'D:\\Games\\WA2',
      )!;
      expect(wrapped.foregroundPid(), targetPid);
    });

    test('🔴 假 checker 查不到 exe + pid 不匹配 → 照实返回（拦截，不放大注入面）',
        () {
      // _FakeForegroundChecker 不是 User32ForegroundChecker → exe 查询为 null
      final wrapped = GamepadForegroundGuard.wrap(
        inner: _FakeForegroundChecker(999),
        targetPid: targetPid,
        gameDirectoryPath: 'D:\\Games\\WA2',
      )!;
      expect(wrapped.foregroundPid(), 999);
    });

    test('前台窗口不存在（null pid）→ 照实返回 null', () {
      final wrapped = GamepadForegroundGuard.wrap(
        inner: _FakeForegroundChecker(null),
        targetPid: targetPid,
        gameDirectoryPath: 'D:\\Games\\WA2',
      )!;
      expect(wrapped.foregroundPid(), isNull);
    });
  });
}
