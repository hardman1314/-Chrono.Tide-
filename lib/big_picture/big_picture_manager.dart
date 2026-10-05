import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:ui' show Color;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../theme/app_theme_manager.dart';
import 'big_picture_theme.dart';

/// 全屏切换函数类型 (用于测试注入)
typedef SetFullScreenHandler = Future<void> Function(bool fullscreen);

/// 大屏模式 (Big Picture Mode / BPM) 全局状态管理器
///
/// 仿 [AppThemeManager] 的单例 ChangeNotifier 模式,通过 [isActive] 标志驱动
/// [MainContainer] 在桌面外壳与 [BigPictureShell] 之间切换。
///
/// 进入 BPM 时会自动将窗口置为全屏;退出时恢复窗口模式。
///
/// v3.5: **模式持久化** —— 进入/退出会写入 SharedPreferences
/// (`bpm_mode_enabled`),启动时 [restoreFromPrefs] 恢复上次模式。
/// 用户要求「退出软件后重进能恢复上次的大屏模式」,因此不再是
/// 「每次启动默认桌面模式」。
class BigPictureManager extends ChangeNotifier {
  BigPictureManager._();
  static final BigPictureManager instance = BigPictureManager._();

  /// 模式持久化键
  static const String prefKey = 'bpm_mode_enabled';

  /// ★ 入场「幕布升起」时长（2026-10-03 桌面⇄BPM 切换动画）。
  ///
  /// 桌面 → BPM 的过渡分两段：① 幕布（主题底色实心层）在桌面内容之上快速
  /// 升起、把桌面吞没；② 幕布揭开，露出已完成「镜头推近」落座的大屏外壳。
  /// 本值 = 第一段时长，同时也是**全屏切换的推迟量** —— 窗口尺寸变化刻意压后
  /// 到幕布升起之后再下发，否则用户会先看到桌面内容被拉伸铺满显示器的那几帧
  /// （旧实现「切换生硬」的根因之一）。与 `MainContainer` 的入场动画第一段
  /// 共用本常量，避免两处魔数漂移。
  static const Duration enterCurtainRise = Duration(milliseconds: 150);

  bool _isActive = false;

  /// 本次入场的「窗口已完成全屏」完成信号（无入场在途时为 null）。
  ///
  /// `MainContainer` 用它作入场动画**第二段的闸门**：幕布升起后必须等窗口真正
  /// 完成全屏，才开始「揭开 + 落座」，否则尺寸变化的抖动会正好落在用户可见的
  /// 揭开阶段。`enter()` 在 finally 中保证 complete，绝不悬置。
  Future<void>? get enterWindowSync => _enterWindowSync;
  Future<void>? _enterWindowSync;

  /// 🔴 启动恢复专用门闩 ①：`MainContainer` 已挂载并加上监听。
  ///
  /// 没有它时序上是竞态：`restoreFromPrefs` 在首帧后 200ms 就可能触发 `enter()`
  /// → `notifyListeners()`，而 `MainContainer` 要等 `_checkAuthState()`（异步）
  /// 完成后才挂载、才在 `initState` 里 addListener —— 若 auth 更慢，这次通知
  /// **无人接收**，入场动画协程从未启动；MainContainer 之后挂载时控制器已是
  /// 稳态 1.0，直接渲染 BPM 界面 ⇒ 用户看到的「没有动画、闪现进界面」。
  /// 由 `MainContainer.initState` 调用 [signalShellReady] 解闩。
  final Completer<void> _shellReady = Completer<void>();

  /// 🔴 启动恢复专用门闩 ②：入场动画已完整播完（稳态落位）。
  ///
  /// `main.dart` 的 `_initPostFirstFrame` 在 `restoreFromPrefs()` **之后**紧跟着
  /// 一串重活（`ManifestService.init()` 在主 isolate 同步解析 16.7MB YAML，
  /// 自述 0.3~1.5s；其后还有 VNDB 字典、截图扫描等）。`enter()` 本身不等动画
  /// 播完就返回 —— 不设这道闩的话，手柄描出动画恰好与 YAML 解析同窗竞争
  /// UI 线程，帧被成批饿死 ⇒ 动画「闪现、不完整」。由 `MainContainer` 在
  /// `_runBpmEnter` 收尾时调用 [signalEnterAnimationDone] 解闩；等待方一律带
  /// 超时兜底，任何一环失灵都不会悬置启动初始化。
  Completer<void> _enterAnimationDone = Completer<void>();

  /// `MainContainer` 已挂载并监听（幂等，重复调用无害）。
  void signalShellReady() {
    if (!_shellReady.isCompleted) _shellReady.complete();
  }

  /// 本轮入场动画已播完/已跳过（幂等）。`enter()` 每轮重置，见其函数体。
  void signalEnterAnimationDone() {
    if (!_enterAnimationDone.isCompleted) _enterAnimationDone.complete();
  }

  /// 全屏切换 handler (生产环境用 windowManager,测试可通过 [setFullScreenHandler] 注入)
  SetFullScreenHandler _setFullScreenHandler = (fullscreen) async {
    await windowManager.setFullScreen(fullscreen);
    if (!fullscreen) return;
    // 🔴 修复「保持大屏模式重进 → 变窗口 / 左上角小窗」:
    // 本项目在 main.dart 用 setAsFrameless() 修 4K 白边,而 window_manager
    // 原生 SetFullScreen 在 is_frameless_ == true 时**只发 SC_MAXIMIZE**、
    // 跳过「改样式 + 铺满显示器」的分支 (见插件 window_manager.cpp 的
    // if (!is_frameless_))。SC_MAXIMIZE 对无边框窗口只最大化到工作区 →
    // 任务栏露出,表现为"最大化窗口"而非全屏。这里补刀铺屏。
    //
    // ⚠️ 旧补刀用 `PlatformDispatcher.displays.first.size`(逻辑像素) 走
    // windowManager.setBounds —— 该链路有两个不可靠环节: displays API 在
    // Windows 的上报语义不明,且 setBounds 在 native 侧会把值**乘以**
    // implicitView.devicePixelRatio 再 SetWindowPos (插件 window_manager.dart
    // getDevicePixelRatio + window_manager.cpp SetBounds)。两者不匹配时
    // (启动恢复场景 DPR 读到 1.0),窗口被按物理像素落到 (0,0),表现为
    // "卡在桌面左上角的小窗口"。
    //
    // 现改为 FFI 直读窗口所在显示器的**物理矩形**并 SetWindowPos 铺屏,
    // 与插件原生铺屏分支完全同源 (MonitorFromWindow + GetMonitorInfo +
    // SetWindowPos),零 DPR 换算。整段容错: 失败时退化为最大化状态,
    // 绝不让全屏切换抛出。
    try {
      if (!_fillWindowMonitor()) {
        debugPrint('[BPM] 全屏铺屏补刀未生效(保留最大化状态)');
      }
    } catch (e) {
      debugPrint('[BPM] 全屏铺屏补刀失败(保留最大化状态): $e');
    }
  };

  /// 当前是否处于大屏模式
  bool get isActive => _isActive;

  /// 测试注入: 替换全屏切换实现,避免在测试环境调用 windowManager
  @visibleForTesting
  void setFullScreenHandler(SetFullScreenHandler handler) {
    _setFullScreenHandler = handler;
  }

  /// 进入大屏模式
  ///
  /// 幂等: 重复调用不会触发副作用。
  ///
  /// ★ 时序（2026-10-03 切换动画改造，顺序即体验，勿随意调整）：
  /// ① `notifyListeners()` 立即切壳 —— `MainContainer` 收到后当帧起「幕布」，
  ///    桌面内容被主题底色吞没；
  /// ② 写模式偏好；
  /// ③ 等 `enterCurtainRise`（幕布升起）后才下发全屏切换 —— 窗口尺寸变化被
  ///    幕布完全盖住，用户看不到「桌面被拉伸到全屏」的数帧。
  ///
  /// 旧顺序为「写偏好 → 同步背景色 → 切全屏 → notify」，全屏切换期间屏幕上
  /// 仍是桌面外壳被拉伸铺满，随后才开始 420ms 淡入淡出：观感「先抖一下再硬切」，
  /// 即用户报告的「生硬、不连贯」。
  ///
  /// [persist] = false 用于启动恢复 (避免与已有记录反复写盘)。
  Future<void> enter({bool persist = true}) async {
    if (_isActive) return;
    _isActive = true;
    // 本轮入场动画门闩重置（上一轮的 done 信号不能串门）
    _enterAnimationDone = Completer<void>();

    final sync = Completer<void>();
    _enterWindowSync = sync.future;
    debugPrint('[BPM] 进入大屏模式');
    notifyListeners(); // ★ 必须先于全屏切换: 切壳 + 幕布起，窗口变化藏在幕后

    if (persist) await _savePref(true);
    try {
      // ★ 等幕布升起（`enterCurtainRise`）再下发全屏切换：窗口尺寸变化被幕布
      //   完全盖住，用户看不到「桌面被拉伸到全屏」的数帧。
      await Future<void>.delayed(enterCurtainRise);
      // 幕布升起期间用户又退出了（连点 / F11）：不要下发全屏切换，
      // 否则桌面态会被硬拉成全屏。finally 仍会释放闸门，入场动画早已退出。
      if (!_isActive) return;
      // 修复 4K 全屏黑/白边：全屏前同步窗口背景色。
      // ★ 传 BPM 底色而非桌面主题色：入场幕布用的就是 BPM 底色，全屏展开时
      //   露出的新区域必须同色，否则「浅色桌面主题 → 深色大屏」会闪一条白边。
      await _syncWindowBackground(BpmColors.deepBase);
      await _setFullScreenHandler(true);
    } catch (e) {
      debugPrint('[BPM] 全屏切换异常: $e');
    } finally {
      // 闸门必定释放：入场动画的揭开段在等它，悬置会让过渡卡在幕布上
      if (!sync.isCompleted) sync.complete();
    }
  }

  /// 退出大屏模式
  ///
  /// 幂等: 重复调用不会触发副作用。
  ///
  /// ★ 退出方向**不做动画**（用户明确要求「返回桌面不需要动画、但同样要丝滑」）：
  /// 先恢复窗口尺寸、再 `notifyListeners()` 切壳 —— 桌面外壳一出现就已是正确的
  /// 窗口尺寸；若反过来先切壳，桌面会先按全屏尺寸布局、再被窗口缩小重排一次，
  /// 反而多出一帧跳动。`MainContainer` 侧同时把入场进度直接置 1（跳过全部过渡
  /// 层），用户感知为「立即回到桌面」，零额外延迟。
  Future<void> exit({bool persist = true}) async {
    if (!_isActive) return;
    _isActive = false;
    if (persist) await _savePref(false);
    debugPrint('[BPM] 退出大屏模式');
    try {
      await _setFullScreenHandler(false);
      // 退出全屏后再次同步窗口背景色
      await _syncWindowBackground();
    } catch (e) {
      debugPrint('[BPM] 退出全屏异常: $e');
    }
    notifyListeners();
  }

  /// 切换大屏模式状态
  Future<void> toggle() async => _isActive ? exit() : enter();

  /// 最小化主窗口（BPM 侧唯一入口）。
  ///
  /// 🔴 **不能用 `windowManager.minimize()`** —— 插件在
  /// `window_manager.cpp:344` 里写着：
  /// ```cpp
  /// void WindowManager::Minimize() {
  ///   if (IsFullScreen()) {  // Like chromium, we don't want to minimize
  ///     return;              // fullscreen windows
  ///   }
  /// ```
  /// 而 BPM 全程处于 `setFullScreen(true)` 状态，于是插件的 minimize 是
  /// **空操作** —— 真机表现为「点了『最小化』什么都不发生」。
  ///
  /// 这里用与 [_fillWindowMonitor] 同源的 FFI 直调 `ShowWindow(SW_MINIMIZE)`
  /// 绕开该守卫。**刻意不碰插件的全屏标志**：窗口在系统层被最小化，而插件
  /// 与 BPM 的 `isActive` 状态都保持「全屏大屏模式」，从任务栏 / 托盘恢复后
  /// 得到的仍是原来那个全屏大屏窗口（无需重建状态）。
  ///
  /// 返回是否成功下发（拿不到窗口句柄 / 非 Windows 时为 false，调用方可据此提示）。
  static bool minimizeWindow() {
    if (!Platform.isWindows) {
      // 非 Windows 走插件默认实现（无全屏守卫的场景）
      windowManager.minimize();
      return true;
    }
    try {
      if (_showWindowMinimized()) return true;
    } catch (e) {
      debugPrint('[BPM] 最小化 FFI 失败(回落插件实现): $e');
    }
    // 兜底：若句柄拿不到（异常环境），仍试一次插件实现（窗口非全屏时有效）
    windowManager.minimize();
    return false;
  }

  /// 启动时恢复上次的模式 (用户要求: 退出软件后重进回到上次模式)
  ///
  /// 读取失败 / 无记录 → 保持桌面模式 (与旧行为一致)。
  /// ⚠️ 必须在窗口 ready **之后** 调用: 内部会触发全屏切换,
  /// 过早调用在 4K/高 DPI 下会露出旧背景色边框。
  ///
  /// 🔴 2026-10-04 修复「恢复路径入场动画闪现/缺失」，本方法改为**两道门闩**：
  /// ① 等 `signalShellReady`（MainContainer 挂载并 addListener 之后）才 `enter()`
  ///    —— 否则 `notifyListeners` 可能无人接收，动画协程根本不启动；
  /// ② `enter()` 返回**不代表动画播完**（动画在 MainContainer 的协程里异步跑），
  ///    再等 `signalEnterAnimationDone` 才返回 —— 调用方（`main.dart` 的
  ///    `_initPostFirstFrame`）排在后面的重活（16.7MB YAML 解析等）因此全部
  ///    推迟到动画收尾之后，不会再把描出动画的帧成批饿死。
  /// 两道闩都带超时兜底：任何一环失灵（如停在登录页、MainContainer 迟迟不
  /// 挂载）都退化为旧行为（挂载后直接 BPM 稳态），绝不悬置启动初始化。
  Future<void> restoreFromPrefs() async {
    bool? saved;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getBool(prefKey);
    } catch (e) {
      debugPrint('[BPM] 读取模式记录失败(按桌面模式启动): $e');
      return;
    }
    if (saved != true) return;
    debugPrint('[BPM] 恢复上次的大屏模式（等 MainContainer 就绪…）');
    // 门闩 ①：等壳就绪（MainContainer.initState → signalShellReady）
    await _shellReady.future
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => debugPrint(
              '[BPM] ⚠️ 等 MainContainer 就绪超时(8s)，按旧时序继续恢复'),
        );
    await enter(persist: false);
    // 门闩 ②：等入场动画完整播完，再把启动重活放出来跑
    await _enterAnimationDone.future
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => debugPrint(
              '[BPM] ⚠️ 等入场动画完成超时(8s)，放行启动初始化'),
        );
    debugPrint('[BPM] 恢复入场动画已收尾，放行后续初始化');
  }

  /// 写入模式记录 (失败不影响主流程)
  Future<void> _savePref(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, enabled);
    } catch (e) {
      debugPrint('[BPM] 模式持久化失败: $e');
    }
  }

  /// 同步窗口背景色
  ///
  /// 修复 4K/高 DPI 下的视觉问题：
  /// - 全屏切换瞬间，窗口背景色可能与当前内容不一致
  /// - 在 4K 高 DPI 下，这个色差会被放大为明显的边框
  ///
  /// [color] 缺省取桌面主题底色（出场用）；**入场**由调用方显式传 BPM 底色，
  /// 与幕布同色，避免全屏展开时闪出异色边。
  Future<void> _syncWindowBackground([Color? color]) async {
    try {
      final windowBgColor =
          color ?? AppThemeManager.instance.current.background;
      await windowManager.setBackgroundColor(windowBgColor);
    } catch (e) {
      debugPrint('[BPM] 同步窗口背景色异常: $e');
    }
  }
}

// ============ Win32 显示器物理铺屏 (全屏补刀,零 DPR 换算) ============
//
// 与插件原生铺屏分支 (window_manager.cpp SetFullScreen 的 !is_frameless_
// 路径) 完全同源: MonitorFromWindow(MONITOR_DEFAULTTONEAREST) +
// GetMonitorInfoW 取 rcMonitor 物理矩形 + SetWindowPos 铺满。
// 全部坐标为物理像素,不经过任何逻辑像素/DPR 换算,规避旧 setBounds
// 链路「逻辑值 × 运行期 DPR」的不确定性。
//
// 结构体布局 (与 Win32 C 定义一致,FFI 按平台 ABI 自动对齐):
//   typedef struct tagMONITORINFO {
//     DWORD cbSize;  RECT rcMonitor;  RECT rcWork;  DWORD dwFlags;
//   } MONITORINFO;

final class _Win32Rect extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

final class _Win32MonitorInfo extends ffi.Struct {
  @ffi.Int32()
  external int cbSize;

  external _Win32Rect rcMonitor;

  external _Win32Rect rcWork;

  @ffi.Uint32()
  external int dwFlags;
}

/// 最小化主窗口 (FFI)。返回是否成功下发。
///
/// `ShowWindow` 的返回值语义是「窗口此前是否可见」，不能当成功标志用，
/// 因此这里只以「拿到句柄 + 调用完成」为成功条件；句柄拿不到才返回 false。
bool _showWindowMinimized() {
  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final findWindowW = user32.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
      int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>(
    'FindWindowW',
  );
  final showWindow = user32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Int32),
      int Function(int, int)>(
    'ShowWindow',
  );

  const int swMinimize = 6; // SW_MINIMIZE

  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    final hwnd = findWindowW(className, ffi.nullptr);
    if (hwnd == 0) return false;
    showWindow(hwnd, swMinimize);
    return true;
  } finally {
    calloc.free(className);
  }
}

/// 将主窗口铺满其所在显示器 (物理像素)。返回是否成功。
///
/// 主窗口句柄经 `FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW")` 获取 —— 该类名
/// 由 runner 注册且全进程唯一 (windows/runner/win32_window.cpp:43)。
/// 任一环节失败返回 false,调用方退化为最大化状态 (不抛出)。
bool _fillWindowMonitor() {
  if (!Platform.isWindows) return false;
  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final findWindowW = user32.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
      int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>(
    'FindWindowW',
  );
  final monitorFromWindow = user32.lookupFunction<
      ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
      int Function(int, int)>(
    'MonitorFromWindow',
  );
  final getMonitorInfoW = user32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_Win32MonitorInfo>),
      int Function(int, ffi.Pointer<_Win32MonitorInfo>)>(
    'GetMonitorInfoW',
  );
  final setWindowPos = user32.lookupFunction<
      ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.Int32, ffi.Int32,
          ffi.Int32, ffi.Int32, ffi.Uint32),
      int Function(int, int, int, int, int, int, int)>(
    'SetWindowPos',
  );

  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    final hwnd = findWindowW(className, ffi.nullptr);
    if (hwnd == 0) return false;
    // MONITOR_DEFAULTTONEAREST
    final hmon = monitorFromWindow(hwnd, 2);
    if (hmon == 0) return false;
    final info = calloc<_Win32MonitorInfo>();
    try {
      info.ref.cbSize = ffi.sizeOf<_Win32MonitorInfo>();
      if (getMonitorInfoW(hmon, info) == 0) return false;
      final rc = info.ref.rcMonitor;
      // 与插件原生铺屏分支同一组 flags (window_manager.cpp:607)
      const int swpNoOwnerZOrder = 0x0200;
      const int swpFrameChanged = 0x0020;
      final ok = setWindowPos(
        hwnd,
        0, // HWND_TOP
        rc.left,
        rc.top,
        rc.right - rc.left,
        rc.bottom - rc.top,
        swpNoOwnerZOrder | swpFrameChanged,
      );
      return ok != 0;
    } finally {
      calloc.free(info);
    }
  } finally {
    calloc.free(className);
  }
}
