/// 手柄映射编辑器的按键捕获（Phase 3）
///
/// - [GamepadButtonRecorder]：临时创建 SDL 后端 + 服务，捕获**下一个按下的
///   手柄按键**（按下即捕获并自动停止；BPM 服务同时轮询互不影响，读取无竞争）；
/// - [GamepadKeyboardRecorder]：`GetAsyncKeyState` 轮询捕获下一个按下的键盘键
///   （不走 Flutter 焦点，避免对话框抢焦点导致捕获不到；跳过鼠标键）。
///
/// 两者都是「一次性」语义：捕获成功或调用 [stop] 后释放全部资源。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../big_picture/services/bpm_gamepad_service.dart';
import '../../big_picture/services/bpm_sdl3_backend.dart';
import 'gamepad_profile.dart';

/// 手柄按键录制器（一次性）
class GamepadButtonRecorder {
  GamepadButtonRecorder._(this._backend, this._service);

  final BpmGamepadBackend _backend;
  final BpmGamepadService _service;
  bool _stopped = false;

  /// 开始录制；捕获到下一个按下的手柄键后回调 [onCaptured] 并自动停止。
  /// 返回 null = 本机没有可用手柄后端（调用方提示用户）。
  static GamepadButtonRecorder? start({
    required void Function(GamepadSource source) onCaptured,
    String? sdl3DllPath,
  }) {
    final backend = Sdl3Backend.tryCreate(dllPath: sdl3DllPath);
    if (backend == null) return null;
    final service = BpmGamepadService(
      backends: [backend],
      callbacks: const BpmGamepadCallbacks(),
    );
    final recorder = GamepadButtonRecorder._(backend, service);
    service.addRawListener(BpmGamepadRawListener(
      onButton: (button, down) {
        if (!down || recorder._stopped) return;
        final source = GamepadSource.fromRawButton(button);
        if (source == null) return;
        recorder.stop();
        onCaptured(source);
      },
    ));
    service.start();
    return recorder;
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _service.dispose();
    _backend.dispose();
  }
}

/// 键盘按键录制器（一次性）：GetAsyncKeyState 轮询，捕获下一个按下的键
class GamepadKeyboardRecorder {
  GamepadKeyboardRecorder._(this._onCaptured) {
    _timer = Timer.periodic(const Duration(milliseconds: 16), _poll);
  }

  final void Function(int vk) _onCaptured;
  late final Timer _timer;
  bool _stopped = false;

  static DynamicLibrary? _user32;

  /// 开始录制；捕获到下一个按下的键（VK 码）后回调并自动停止。
  /// 返回 null = 非 Windows 或 user32 不可用。
  static GamepadKeyboardRecorder? start({
    required void Function(int vk) onCaptured,
  }) {
    if (!Platform.isWindows) return null;
    try {
      _user32 ??= DynamicLibrary.open('user32.dll');
    } catch (_) {
      return null;
    }
    return GamepadKeyboardRecorder._(onCaptured);
  }

  void _poll(Timer _) {
    if (_stopped) return;
    final getState = _user32!.lookupFunction<Int16 Function(Uint32),
        int Function(int)>('GetAsyncKeyState');
    for (var vk = 0x08; vk <= 0xFE; vk++) {
      // 跳过鼠标键（VK 1/2/4/5/6）
      if (vk == 1 || vk == 2 || vk == 4 || vk == 5 || vk == 6) continue;
      if (getState(vk) & 0x8000 != 0) {
        _stopped = true;
        _timer.cancel();
        _onCaptured(vk);
        return;
      }
    }
  }

  void stop() {
    _stopped = true;
    _timer.cancel();
  }
}

/// 诊断输出（编辑器内错误提示用）
void gamepadRecorderLog(Object message) => debugPrint('[GAMEPAD-REC] $message');
