import 'dart:async';
import 'dart:io';

import 'package:chrono_tide/big_picture/services/bpm_dinput_backend.dart';
import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:chrono_tide/big_picture/services/bpm_sdl3_backend.dart';
import 'package:chrono_tide/services/gamepad/input_injector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 **硬件在环（HIL）手动用例** —— 手柄 A→Enter / B→Esc 注入真实游戏。
///
/// 这是 Phase 1 的最终验收：「按手柄 → 游戏推进对话」。
/// 需要真实手柄 + 真实游戏，**不会**在 CI / 全量测试里自动跑
/// （未设置 `CT_E2E_GAME` 时自动 skip，不影响全量基线）。
///
/// ## 推荐入口：双击 `dev_probe\手柄验收.bat`（已设好环境变量与本引导）
///
/// 手动执行（git-bash）：
/// ```sh
/// CT_E2E_GAME='E:\GAL\白色相簿2\WA2_chs.exe' \
///   ./flutter/bin/flutter.bat test \
///   test/services/gamepad/gamepad_e2e_manual_test.dart --reporter expanded
/// ```
///
/// 可选：`CT_E2E_SECONDS=<监听秒数>`（默认 420）。
///
/// ## 流程（用例会分阶段打印提示）
/// 1. 自动启动游戏；
/// 2. **你**：用鼠标点一下游戏窗口（等用例检测到游戏已在前台）；
/// 3. **你**：用鼠标进到能吃键盘的界面 —— WA2：标题点「开始游戏」，
///    然后**等序章自动播完**（约 2 分钟，这段自动播放、按手柄无效，不是坏了）；
/// 4. **你**：按手柄 **A** → 对话应推进；按 **B** → 应触发 Esc/菜单；
/// 5. 结束自动关闭游戏并打印汇总（`注入成功 N 次`，N>0 即链路通）。
///
/// ⚠️ 仅支持**直接启动**的游戏（PID = 启动进程）。需转区的游戏请先用
/// `localeMode` 验证可跑，再直接指到其主程序。
void main() {
  test('E2E 手动: 手柄 A→Enter / B→Esc 注入真实游戏', () async {
    final exe = Platform.environment['CT_E2E_GAME'] ??
        const String.fromEnvironment('CT_E2E_GAME');
    final listenSeconds =
        int.tryParse(Platform.environment['CT_E2E_SECONDS'] ?? '') ?? 420;

    if (!Platform.isWindows) {
      markTestSkipped('注入层仅支持 Windows');
      return;
    }
    if (exe.isEmpty) {
      markTestSkipped(
          '硬件在环手动用例 —— 设置 CT_E2E_GAME=<游戏exe路径> 后手动执行\n'
          '或直接双击 dev_probe\\手柄验收.bat');
      return;
    }
    if (!File(exe).existsSync()) {
      fail('游戏不存在: $exe');
    }

    // 后端优先级与 big_picture_shell.dart 的 _createGamepadBackends() 一致：
    // SDL3（跨厂商全覆盖）→ XInput → DirectInput。
    // 🔴 注意：SDL3 的默认路径基于 exe 目录解析，在 flutter test 环境
    // （resolvedExecutable=flutter_tester.exe）下解析不到，必须显式传仓库内路径。
    const sdl3Dll = r'D:\CTLIB\windows\runner\sdl3\SDL3.dll';
    final backends = <BpmGamepadBackend>[];
    final sdl3 = File(sdl3Dll).existsSync() ? Sdl3Backend.tryCreate(dllPath: sdl3Dll) : null;
    if (sdl3 != null) backends.add(sdl3);
    final xinput = XInputBackend.tryCreate();
    if (xinput != null) backends.add(xinput);
    final dinput = DInputBackend.tryCreate();
    if (dinput != null) backends.add(dinput);
    if (backends.isEmpty) {
      fail('本机没有任何可用手柄后端 (SDL3 / XInput / DInput)');
    }
    final backend = backends.first;
    stdout.writeln('[e2e] 可用后端: '
        '${backends.map((b) => b.name).join(" + ")}，将使用 ${backend.name}');
    final sink = SendInputSink.tryCreate();
    final checker = User32ForegroundChecker.tryCreate();
    if (sink == null || checker == null) fail('注入层初始化失败');

    void log(Object msg) => stdout.writeln('[e2e] $msg');

    final injected = <String>[];
    final blocked = <String>[];
    var frameCount = 0; // 服务层实际收到的帧数（诊断「轮询是否在跑」）
    var lastButtons = 0; // 最近一帧的按键掩码
    final injector = InputInjector(sink: sink, foreground: checker);
    final service = BpmGamepadService(
      backend: backend,
      callbacks: BpmGamepadCallbacks(
        onConnectionChanged: (connected) =>
            log(connected ? '>> 手柄已连接' : '>> 手柄已断开'),
      ),
    );

    service.addRawListener(BpmGamepadRawListener(
      onButton: (button, down) {
        if (!down) return;
        final int vk;
        switch (button) {
          case GamepadRawButton.a:
            vk = 0x0D; // Enter —— galgame 通行「推进」键
          case GamepadRawButton.b:
            vk = 0x1B; // Esc
          default:
            log('  （未映射: ${button.name}）');
            return;
        }
        unawaited(injector.tapKey(vk).then((r) {
          final tag = '${button.name}->vk$vk';
          if (r.isSent) {
            injected.add(tag);
            log('  注入 $tag  accepted=${r.accepted}');
          } else {
            blocked.add('$tag(${r.outcome.name})');
            log('  拦截 $tag -> ${r.outcome.name}'
                '${r.outcome == InjectionOutcome.foregroundMismatch ? "（游戏不在前台：点一下游戏窗口再按）" : ""}');
          }
        }));
      },
      onReset: () => log('  RESET（手柄断连/换设备，按住态已释放）'),
      onFrame: (f) {
        frameCount++;
        lastButtons = f.buttons;
      },
    ));

    log('');
    log('================================================================');
    log(' 启动游戏: $exe');
    log('================================================================');
    final proc = await Process.start(exe, const <String>[],
        workingDirectory: File(exe).parent.path);
    log('游戏 PID=${proc.pid}');
    injector.bindTargetPid(proc.pid);
    service.start();
    log('手柄轮询已启动（后端=${backend.name}，当前连接=${service.isConnected}）');
    if (!service.isConnected) {
      log('!! 手柄尚未连接 —— 请确认手柄已插好/已配对，再看上方是否打印「手柄已连接」');
    }
    log('');
    log('>>> 【第 1 步】用鼠标点一下游戏窗口，让它到前台（最多等 90 秒）...');
    final focusDeadline = DateTime.now().add(const Duration(seconds: 90));
    var focused = false;
    while (DateTime.now().isBefore(focusDeadline)) {
      if (checker.foregroundPid() == proc.pid) {
        focused = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    log(focused
        ? '>>> 游戏已在前台。'
        : '>>> !! 90 秒内未检测到游戏在前台（继续执行，但注入会被守卫拦截）');
    log('');
    log('>>> 【第 2 步】用鼠标进到能吃键盘的界面：');
    log('>>>    WA2 = 在标题画面点「开始游戏」，然后等序章自动播完');
    log('>>>    （序章约 2 分钟自动播放，这段按手柄无效，不是坏了）');
    log('');
    log('>>> 【第 3 步】看到对话文字后，按手柄 A -> 对话应推进；按 B -> 应弹菜单');
    log('>>> 监听 $listenSeconds 秒，期间每 30 秒报一次进度。');
    log('');

    unawaited(proc.exitCode.then((code) => log('!! 游戏进程退出，退出码 $code')));

    var left = listenSeconds;
    final progress = Timer.periodic(const Duration(seconds: 30), (_) {
      left -= 30;
      if (left <= 0) return;
      // 手动轮询两个后端做交叉对照：若这里能看到按键而服务层没事件 → 服务层问题；
      // 若这里也全 0 → 设备/读取层问题。
      final sdl3Btn = sdl3?.poll()?.buttons;
      final xiBtn = xinput?.poll()?.buttons;
      log('… 剩余 ${left}s | 连接=${service.isConnected} | 服务层帧 $frameCount | 最近按键 0x${lastButtons.toRadixString(16)}'
          ' | 手动轮询 SDL3=${sdl3Btn == null ? "null" : "0x${sdl3Btn.toRadixString(16)}"}'
          ' XInput=${xiBtn == null ? "null" : "0x${xiBtn.toRadixString(16)}"}'
          ' | 注入 ${injected.length} / 拦截 ${blocked.length}');
    });

    await Future<void>.delayed(Duration(seconds: listenSeconds));
    progress.cancel();

    service.dispose();
    for (final b in backends) {
      b.dispose();
    }
    sink.dispose();

    log('');
    log('================================================================');
    log(' 汇总：注入成功 ${injected.length} 次 / 被守卫拦截 ${blocked.length} 次'
        ' / 服务层共收到 $frameCount 帧');
    log(' 明细: ${injected.take(20).join(", ")}');
    if (blocked.isNotEmpty) {
      log(' 拦截明细: ${blocked.take(8).join(", ")}');
    }
    log('================================================================');

    await Process.run('taskkill', ['/F', '/PID', '${proc.pid}']);
    log('游戏已关闭');

    if (injected.isEmpty) {
      fail('没有一次注入成功 —— 请确认：① 手柄已连接（上方应有「手柄已连接」）；'
          '② 游戏窗口在前台；③ 按的是 A/B 键');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
