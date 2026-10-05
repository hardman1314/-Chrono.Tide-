/// BPM 虚拟键盘 → 系统 IME 桥（v3.21）。
///
/// 解决「手柄点自绘键盘只能输入英文字母，无法走搜狗拼音组词」：
///
/// 旧实现 `BpmVirtualKeyboard._type()` 直接改写 `TextEditingController`，
/// 绕过 IME 通道 —— 字符永远不经过输入法，只能直上屏。
///
/// 新链路：虚拟键盘的**字母 / 数字键**改用 Win32 `SendInput` 注入
/// **VK 码**（而非 KEYEVENTF_UNICODE）—— 注入键被系统当作硬件按键送达
/// 前台窗口（BPM 全屏即本进程）→ TSF/输入法（搜狗）先于 Flutter 引擎
/// 拦截 → 进入拼音组词 → 候选上屏到**仍然持有焦点的 TextField**
/// （shell `_openVirtualKeyboard` 保持输入框焦点不变，IME 客户端始终在线）。
///
/// 降级：系统当前是英文输入态时，VK 注入等价于直接输入字母 —— 与旧行为
/// 一致，无任何损失。
///
/// 🔴 注入豁免：shell `_onHardwareKeyEvent` 把任意键盘 KeyDown 视为
/// 「键鼠介入」并退出手柄模式；注入键会再次进入该通道形成自触发。
/// 发送时记录 [lastForwardAt]，shell 据此跳过转发窗口（[_forwardWindow]）
/// 内的键盘事件。数字键同样转发（组词态下 = 选第 N 候选词，原生体验）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Win32 按键注入 + 转发窗口。
abstract final class BpmImeBridge {
  /// SendInput 的 INPUT_KEYBOARD 类型码。
  static const int _inputKeyboard = 0;

  /// KEYEVENTF_KEYUP。
  static const int _keyeventfKeyUp = 0x0002;

  static const int _vkShift = 0x10;
  static const int _vkBack = 0x08;
  static const int _vkSpace = 0x20;

  /// 注入转发窗口：窗口期内的 HardwareKeyboard 事件被 shell 视为
  /// 「本桥注入」而非用户键鼠介入。
  static const Duration forwardWindow = Duration(milliseconds: 200);

  static DateTime? _lastForwardAt;

  /// 最近一次注入是否仍在转发窗口内（shell 豁免判定用）。
  static bool get isForwarding {
    final t = _lastForwardAt;
    if (t == null) return false;
    return DateTime.now().difference(t) < forwardWindow;
  }

  static bool get _available => Platform.isWindows;

  /// IME 转发是否可用（非 Windows 平台 false —— 调用方应回退直插）。
  static bool get isForwardingSupported => _available;

  // ============ 字符 → VK 映射 ============

  /// 该字符是否可经 VK 注入走 IME（字母 / 数字）。
  static bool isForwardable(String ch) {
    if (ch.length != 1) return false;
    final c = ch.toLowerCase().codeUnitAt(0);
    return (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);
  }

  /// 将一串字母/数字以 VK 按键注入（走系统输入法）。
  ///
  /// [shift] = 模拟 Shift 按住（英文大写；拼音组词不受影响）。
  /// 🔴 仅对**字母**生效 —— Shift+数字会变成符号（Shift+1='!'）。
  static void sendTextAsKeys(String text, {bool shift = false}) {
    if (!_available) return;
    for (final ch in text.split('')) {
      if (!isForwardable(ch)) continue;
      final c = ch.toLowerCase().codeUnitAt(0);
      final vk = c >= 0x61 ? (c - 0x61 + 0x41) : c; // a-z → VK_A..VK_Z
      final isLetter = vk >= 0x41 && vk <= 0x5A;
      _tapKey(vk, withShift: shift && isLetter);
    }
    _markForward();
  }

  /// 退格。组词态下由输入法解释为「删拼音字母」，正常态删字符 —— 均符合直觉。
  static void sendBackspace() {
    if (!_available) return;
    _tapKey(_vkBack);
    _markForward();
  }

  /// 空格。组词态下 = 确认当前候选词（搜狗等输入法的原生行为）。
  static void sendSpace() {
    if (!_available) return;
    _tapKey(_vkSpace);
    _markForward();
  }

  /// 轻拍 Shift —— 搜狗等常见中文输入法的默认「中/英」切换热键。
  static void sendShiftTap() {
    if (!_available) return;
    _raw(_vkShift, true);
    _raw(_vkShift, false);
    _markForward();
  }

  static void _tapKey(int vk, {bool withShift = false}) {
    if (withShift) _raw(_vkShift, true);
    _raw(vk, true);
    _raw(vk, false);
    if (withShift) _raw(_vkShift, false);
  }

  static void _markForward() => _lastForwardAt = DateTime.now();

  // ============ Win32 SendInput ============

  static void _raw(int vk, bool down) {
    final input = calloc<_Input>();
    input.ref.type = _inputKeyboard;
    input.ref.u.ki.wVk = vk;
    input.ref.u.ki.wScan = 0;
    input.ref.u.ki.dwFlags = down ? 0 : _keyeventfKeyUp;
    input.ref.u.ki.time = 0;
    input.ref.u.ki.dwExtraInfo = 0;
    try {
      _sendInput(1, input.cast<_Input>(), sizeOf<_Input>());
    } catch (_) {
      // FFI 失败静默降级（不影响 Flutter 侧任何功能）
    } finally {
      calloc.free(input);
    }
  }

  static int Function(int, Pointer<_Input>, int) get _sendInput =>
      _user32!
          .lookup<
              NativeFunction<Int32 Function(Uint32, Pointer<_Input>, Int32)>>(
              'SendInput')
          .asFunction();

  static DynamicLibrary? _user32;

  static DynamicLibrary? get user32 =>
      _user32 ??= DynamicLibrary.open('user32.dll');
}

// ============ Win32 结构体（x64 对齐由 ffi 自动处理） ============

final class _KEYBDINPUT extends Struct {
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class _MOUSEINPUT extends Struct {
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class _InputUnion extends Union {
  external _MOUSEINPUT mi;
  external _KEYBDINPUT ki;
}

final class _Input extends Struct {
  @Uint32()
  external int type;
  external _InputUnion u;
}
