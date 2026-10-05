import 'dart:io';

import 'package:flutter/foundation.dart';

/// BPM 手柄文本输入适配（v3.17 引入 / v3.18 修启动与关闭）：
/// 把系统屏幕键盘作为手柄用户的文字输入通道。
///
/// 🔴 手柄事件走 FFI 轮询、不经 Flutter 键盘通道，TextField 对手柄天然零
/// 响应；手柄用户落焦到搜索框 / 编辑窗输入框后没有任何文字输入手段。
///
/// 方案：A 键落在可编辑控件上时（见 shell `_handleGamepadConfirm`）拉起
/// Windows 屏幕键盘；B 键离开输入框时（shell `_handleGamepadBack`）关闭它。
/// 软键盘键入的是真实系统按键事件，Flutter 侧 TextField 零改动即可收到文字。
///
/// v3.18 启动加固：实机 `Process.start('osk.exe')` 会失败（osk 属 UI Access
/// 进程，直接 spawn 常被 UIPI 挡下），改走 `cmd /c start`（ShellExecute 语义）
/// 为主路径，再逐级回落 TabTip。全部路径静默失败并 `debugPrint` 诊断，
/// 绝不打断主流程。
class SoftKeyboardLauncher {
  SoftKeyboardLauncher._();

  /// 测试钩子：widget 测试环境禁止真的拉起系统进程。
  @visibleForTesting
  static bool enabled = true;

  static const String _tabTip =
      r'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe';

  static DateTime _lastLaunch = DateTime.fromMillisecondsSinceEpoch(0);

  /// 拉起屏幕键盘。
  ///
  /// 返回值语义：**true = 键盘应当已经/正在呈现**（含 3s 去抖内的重复触发），
  /// false = 所有路径都失败（调用方可据此提示用户改用物理键盘）。
  static Future<bool> show() async {
    if (!enabled || !Platform.isWindows) return false;
    final now = DateTime.now();
    if (now.difference(_lastLaunch) < const Duration(seconds: 3)) return true;
    _lastLaunch = now;

    // ⓪ 最佳努力：拉起「触摸键盘和手写面板服务」（Win10+ 的 osk.exe 与
    //    TabTip 都依赖它；服务被禁用时进程能起但**界面不显示** —— 真机
    //    「按 A 唤不出键盘」的典型根因）。失败静默（多数情况服务本就在跑）。
    await _tryRun('sc', <String>['start', 'TabletInputService'], 'service');
    // ① osk 直接 spawn（**不依赖 cmd**：cmd 在部分环境会因管道资源不可用
    //    直接失败，见 `CreateFile failed 231`）
    if (await _tryStart('osk.exe', 'osk(direct)')) return true;
    // ② cmd /c start（ShellExecute 语义，规避 UIPI）
    if (await _tryRun(
        'cmd', <String>['/c', 'start', '', 'osk.exe'], 'osk(cmd)')) {
      return true;
    }
    // ③ 回落：Windows 10/11 触摸键盘 TabTip（系统组件，路径固定）
    if (await _tryStart(_tabTip, 'TabTip(direct)')) return true;
    if (await _tryRun(
        'cmd', <String>['/c', 'start', '', _tabTip], 'TabTip(cmd)')) {
      return true;
    }
    debugPrint('[BPM][SoftKeyboard] 所有拉起路径均失败');
    return false;
  }

  /// 关闭屏幕键盘（B 键退出输入框 / 模式切换时调用）。
  ///
  /// 火后即忘：kill 失败（键盘本来没开）不影响任何后续交互。
  static Future<void> hide() async {
    if (!enabled || !Platform.isWindows) return;
    for (final name in <String>['osk.exe', 'TabTip.exe']) {
      try {
        await Process.run('taskkill', <String>['/IM', name, '/F']);
      } catch (e) {
        debugPrint('[BPM][SoftKeyboard] 关闭 $name 失败: $e');
      }
    }
  }

  static Future<bool> _tryRun(
    String exe,
    List<String> args,
    String tag,
  ) async {
    try {
      final result = await Process.run(exe, args);
      debugPrint('[BPM][SoftKeyboard] $tag exit=${result.exitCode}');
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[BPM][SoftKeyboard] $tag 异常: $e');
      return false;
    }
  }

  static Future<bool> _tryStart(String exe, String tag) async {
    try {
      await Process.start(exe, const <String>[],
          mode: ProcessStartMode.detached);
      debugPrint('[BPM][SoftKeyboard] $tag 已启动');
      return true;
    } catch (e) {
      debugPrint('[BPM][SoftKeyboard] $tag 异常: $e');
      return false;
    }
  }
}
