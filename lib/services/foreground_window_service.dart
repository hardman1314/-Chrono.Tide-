// foreground_window_service.dart
// 前台窗口检测服务（借鉴 ReinaManager 的前台窗口 Hook 设计）
//
// 通过 Dart FFI 调用 Windows user32.dll API：
// - GetForegroundWindow() → 获取前台窗口句柄
// - GetWindowThreadProcessId(HWND, LPDWORD) → 获取窗口所属进程 PID
//
// 用于"精准模式（playtime）"时长统计——仅当游戏窗口在前台时才计时。
// 失败时返回 null，调用方应回退到宽松模式（elapsed）。

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'win32_process_service.dart';

// ═══════════════════════════════════════════════════════════════
// FFI 类型定义
// ═══════════════════════════════════════════════════════════════

// HWND 是指针类型（在 64 位 Windows 上是 8 字节）
typedef _GetForegroundWindowNative = Pointer<Void> Function();
typedef _GetForegroundWindowDart = Pointer<Void> Function();

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
    Pointer<Void> hwnd, Pointer<Uint32> lpdwProcessId);
typedef _GetWindowThreadProcessIdDart = int Function(
    Pointer<Void> hwnd, Pointer<Uint32> lpdwProcessId);

/// 前台窗口检测服务
///
/// 通过 Windows API 实时获取当前前台窗口的进程 PID，
/// 用于精准时长统计模式（仅前台时计时）。
class ForegroundWindowService {
  static DynamicLibrary? _user32;
  static _GetForegroundWindowDart? _getForegroundWindow;
  static _GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
  static bool _initialized = false;
  static bool _available = false;

  /// 初始化 FFI 绑定
  ///
  /// ★ Fix（2026-08-09 回退修复）：FFI 初始化失败时不设置 _initialized，
  /// 允许后续调用重试。旧实现在方法入口即置 _initialized=true，导致首次
  /// DynamicLibrary.open/lookupFunction 失败后永不重试——即便底层原因消失
  /// （如 user32.dll 延迟加载、临时句柄耗尽），FFI 也无法恢复，playtime 模式
  /// 会话整段零计时。仅在成功或非 Windows 平台（重试无意义）时置位。
  static void _initialize() {
    if (_initialized) return;

    if (!Platform.isWindows) {
      _available = false;
      _initialized = true; // 非 Windows：重试无意义，直接置位
      return;
    }

    try {
      _user32 = DynamicLibrary.open('user32.dll');
      _getForegroundWindow = _user32!
          .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
              'GetForegroundWindow');
      _getWindowThreadProcessId = _user32!.lookupFunction<
          _GetWindowThreadProcessIdNative,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
      _available = true;
      _initialized = true; // ★ 仅成功时置位，失败允许下次调用重试
      debugPrint('[FG-WINDOW] ✅ FFI 初始化成功（user32.dll）');
    } catch (e) {
      _available = false;
      // ★ 不设置 _initialized = true，允许后续调用重试
      debugPrint('[FG-WINDOW] ❌ FFI 初始化失败（将重试）: $e');
    }
  }

  /// 获取当前前台窗口的进程 PID
  ///
  /// 返回前台窗口的 PID，无前台窗口或失败时返回 null。
  /// 失败时调用方应回退到宽松模式（不依赖前台检测）。
  static int? getForegroundPid() {
    if (!_initialized) _initialize();
    if (!_available ||
        _getForegroundWindow == null ||
        _getWindowThreadProcessId == null) {
      return null;
    }

    try {
      final hwnd = _getForegroundWindow!();
      if (hwnd == nullptr || hwnd.address == 0) {
        return null; // 无前台窗口
      }

      final pidPtr = malloc<Uint32>();
      try {
        _getWindowThreadProcessId!(hwnd, pidPtr);
        final pid = pidPtr.value;
        return pid > 0 ? pid : null;
      } finally {
        malloc.free(pidPtr);
      }
    } catch (e) {
      debugPrint('[FG-WINDOW] ⚠️ 获取前台 PID 失败: $e');
      return null;
    }
  }

  /// PowerShell 回退节流：最近一次回退触发时间
  ///
  /// ★ P2-6：Process.runSync 会在 UI isolate 上同步阻塞（冷启 1-3s，杀软扫描 10s+），
  /// 而本方法由 500ms 定时器高频调用。FFI 对提权进程恒返回 null 时，
  /// 原逻辑每个 tick 都会拉起一次 PowerShell → UI 周期性冻结。
  /// 节流为 60s 最多一次：其余 tick 直接返回 null（仅表现为逃逸进程
  /// 检测短暂收窄，FFI 正常的用户完全不受影响）。
  static DateTime? _lastPsFallbackAt;
  static const Duration _psFallbackInterval = Duration(seconds: 60);

  /// 通过 PID 查询进程的 exe 完整路径
  ///
  /// 用于逃逸进程检测——前台进程不在候选集中时，
  /// 查询其 exe 路径，若在游戏目录下则加入候选集。
  ///
  /// ★ 重构：原实现使用 Process.runSync('powershell', ...) 同步阻塞事件循环
  /// （冷启动 1-3 秒，杀软扫描下 10 秒+）。现改为调用 Win32ProcessService
  /// 的 FFI 实现（OpenProcess + QueryFullProcessImageNameW），耗时 < 1ms。
  /// FFI 不可用时回退到 PowerShell（带 60s 节流，见 [_lastPsFallbackAt]）。
  static String? getProcessExePath(int pid) {
    if (pid <= 0) return null;

    // ★ 优先使用 FFI（毫秒级，不阻塞事件循环）
    if (Win32ProcessService.isAvailable) {
      final path = Win32ProcessService.getProcessExePath(pid);
      if (path != null) return path;
      // FFI 返回 null 可能是权限不足或进程不存在，尝试 PowerShell 回退
    }

    // ★ P2-6 节流：节流窗口内直接放弃回退，避免同步 PowerShell 冻结 UI
    final now = DateTime.now();
    final last = _lastPsFallbackAt;
    if (last != null && now.difference(last) < _psFallbackInterval) {
      return null;
    }
    _lastPsFallbackAt = now;

    // ★ 回退：PowerShell（仅 FFI 不可用/无权限时，60s 一次）
    try {
      final result = Process.runSync(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'try { (Get-Process -Id $pid -ErrorAction Stop).Path } catch { "" }',
        ],
      );
      final path = result.stdout.toString().trim();
      if (path.isEmpty) return null;
      return path;
    } catch (e) {
      return null;
    }
  }

  /// 判断路径是否为某目录的子路径（忽略大小写）
  ///
  /// 借鉴 ReinaManager is_sub_path_ignore_case 实现
  static bool isSubPath(String path, String baseDir) {
    if (path.isEmpty || baseDir.isEmpty) return false;

    final pathLower = path.toLowerCase();
    final baseLower = baseDir.toLowerCase();

    if (pathLower.length < baseLower.length) return false;
    if (!pathLower.startsWith(baseLower)) return false;
    if (pathLower.length == baseLower.length) return true;

    // 确保匹配边界是路径分隔符
    final nextChar = pathLower[baseLower.length];
    return nextChar == '\\' || nextChar == '/';
  }

  /// 检测 FFI 是否可用
  static bool get isAvailable {
    if (!_initialized) _initialize();
    return _available;
  }
}
