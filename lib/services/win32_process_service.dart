// win32_process_service.dart
// Win32 进程操作 FFI 服务（借鉴 ReinaManager 的 windows.rs 架构）
//
// 通过 Dart FFI 直接调用 Windows kernel32.dll API：
// - CreateToolhelp32Snapshot + Process32FirstW/NextW → 进程枚举
// - OpenProcess + QueryFullProcessImageNameW → 进程 exe 路径查询
// - OpenProcess + GetExitCodeProcess → 进程存活检测
// - CloseHandle → 句柄清理
//
// 彻底消除追踪路径中的 PowerShell/tasklist 依赖，将进程检测从秒级降到毫秒级。
// 对应 ReinaManager src-tauri/src/game/monitor/windows.rs 中的 Win32 API 调用。

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════
// Win32 常量
// ═══════════════════════════════════════════════════════════════

/// TH32CS_SNAPPROCESS: 在进程快照中包含所有进程
const int _th32csSnapProcess = 0x00000002;

/// PROCESS_QUERY_LIMITED_INFORMATION: 最低权限查询进程信息（不需要管理员）
const int _processQueryLimitedInformation = 0x1000;

/// STILL_ACTIVE: 进程仍在运行的退出码
const int _stillActive = 259;

/// FALSE (用于 OpenProcess 的 bInheritHandle 参数)
const int _false = 0;

// ═══════════════════════════════════════════════════════════════
// FFI 类型定义
// ═══════════════════════════════════════════════════════════════

// --- CreateToolhelp32Snapshot ---
// HANDLE CreateToolhelp32Snapshot(DWORD dwFlags, DWORD th32ProcessID);
typedef _CreateToolhelp32SnapshotNative = Pointer<Void> Function(
    Uint32 dwFlags, Uint32 th32ProcessID);
typedef _CreateToolhelp32SnapshotDart = Pointer<Void> Function(
    int dwFlags, int th32ProcessID);

// --- Process32FirstW / Process32NextW ---
// BOOL Process32FirstW(HANDLE hSnapshot, LPPROCESSENTRY32W lppe);
// BOOL Process32NextW(HANDLE hSnapshot, LPPROCESSENTRY32W lppe);
typedef _Process32Native = Int32 Function(
    Pointer<Void> hSnapshot, Pointer<PROCESSENTRY32W> lppe);
typedef _Process32Dart = int Function(
    Pointer<Void> hSnapshot, Pointer<PROCESSENTRY32W> lppe);

// --- OpenProcess ---
// HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
typedef _OpenProcessNative = Pointer<Void> Function(
    Uint32 dwDesiredAccess, Int32 bInheritHandle, Uint32 dwProcessId);
typedef _OpenProcessDart = Pointer<Void> Function(
    int dwDesiredAccess, int bInheritHandle, int dwProcessId);

// --- QueryFullProcessImageNameW ---
// BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags,
//                                  LPWSTR lpExeName, PDWORD lpdwSize);
typedef _QueryFullProcessImageNameWNative = Int32 Function(
    Pointer<Void> hProcess, Uint32 dwFlags,
    Pointer<Utf16> lpExeName, Pointer<Uint32> lpdwSize);
typedef _QueryFullProcessImageNameWDart = int Function(
    Pointer<Void> hProcess, int dwFlags,
    Pointer<Utf16> lpExeName, Pointer<Uint32> lpdwSize);

// --- GetExitCodeProcess ---
// BOOL GetExitCodeProcess(HANDLE hProcess, LPDWORD lpExitCode);
typedef _GetExitCodeProcessNative = Int32 Function(
    Pointer<Void> hProcess, Pointer<Uint32> lpExitCode);
typedef _GetExitCodeProcessDart = int Function(
    Pointer<Void> hProcess, Pointer<Uint32> lpExitCode);

// --- CloseHandle ---
// BOOL CloseHandle(HANDLE hObject);
typedef _CloseHandleNative = Int32 Function(Pointer<Void> hObject);
typedef _CloseHandleDart = int Function(Pointer<Void> hObject);

// ═══════════════════════════════════════════════════════════════
// PROCESSENTRY32W 结构体
// ═══════════════════════════════════════════════════════════════

/// Windows SDK PROCESSENTRY32W 结构体的 Dart FFI 映射
///
/// ★ 关键修复（2026-08-10）：th32DefaultHeapID 在 Windows SDK 中是 ULONG_PTR，
/// 在 64 位 Windows 上为 8 字节。旧实现声明为 @Uint32()（4 字节）+ @Packed(4)，
/// 导致结构体大小为 556 字节而非 Windows API 要求的 568 字节，
/// Process32FirstW 因 dwSize 不匹配返回 FALSE，enumerateProcesses() 恒返回空列表，
/// 所有游戏会话因检测不到进程而在 6s 内被终止（exit_reason='aborted'）。
///
/// 修复方案：
/// 1. th32DefaultHeapID 改用 IntPtr（指针大小整数：32位=4字节，64位=8字节）
/// 2. 移除 @Packed(4)，使用默认对齐（与 Windows SDK 默认 #pragma pack(8) 一致）
///
/// 修复后：sizeof = 568（x64）/ 556（x86），与 Windows API 完全一致。
/// 调用 Process32FirstW 前必须将 dwSize 设为 sizeOf<PROCESSENTRY32W>()。
final class PROCESSENTRY32W extends Struct {
  @Uint32() external int dwSize;
  @Uint32() external int cntUsage;
  @Uint32() external int th32ProcessID; // 进程 PID
  @IntPtr() external int th32DefaultHeapID; // ULONG_PTR（64位=8字节，32位=4字节）
  @Uint32() external int th32ModuleID;
  @Uint32() external int cntThreads;
  @Uint32() external int th32ParentProcessID; // 父进程 PID
  @Int32() external int pcPriClassBase;
  @Uint32() external int dwFlags;
  // szExeFile: WCHAR[260] — 进程可执行文件名（仅文件名，非完整路径）
  @Array.multi([260]) external Array<Uint16> szExeFile;
}

// ═══════════════════════════════════════════════════════════════
// 进程信息数据类
// ═══════════════════════════════════════════════════════════════

/// 进程信息（来自 ToolHelp 快照枚举）
class ProcessInfo {
  final int pid;
  final int parentPid;
  final String exeName; // 小写，含 .exe 后缀

  ProcessInfo(this.pid, this.parentPid, this.exeName);
}

// ═══════════════════════════════════════════════════════════════
// Win32ProcessService 主类
// ═══════════════════════════════════════════════════════════════

/// Win32 进程操作 FFI 服务
///
/// 通过 kernel32.dll 直接调用 Windows API 进行进程管理，
/// 彻底替代追踪路径中的 PowerShell/tasklist 依赖。
///
/// 对应 ReinaManager 的 src-tauri/src/game/monitor/windows.rs：
/// - enumerateProcesses() ← get_processes_in_directory 底层
/// - getProcessExePath()  ← get_process_executable_path
/// - isProcessAlive()     ← is_process_running
/// - getProcessesInDirectory() ← get_all_candidate_pids
class Win32ProcessService {
  static DynamicLibrary? _kernel32;
  static _CreateToolhelp32SnapshotDart? _createToolhelp32Snapshot;
  static _Process32Dart? _process32First;
  static _Process32Dart? _process32Next;
  static _OpenProcessDart? _openProcess;
  static _QueryFullProcessImageNameWDart? _queryFullProcessImageName;
  static _GetExitCodeProcessDart? _getExitCodeProcess;
  static _CloseHandleDart? _closeHandle;
  static bool _initialized = false;
  static bool _available = false;

  /// 初始化 FFI 绑定
  ///
  /// ★ 失败时不设置 _initialized，允许后续调用重试。
  /// 与 foreground_window_service.dart 的模式一致。
  static void _initialize() {
    if (_initialized) return;

    if (!Platform.isWindows) {
      _available = false;
      _initialized = true; // 非 Windows：重试无意义
      return;
    }

    try {
      _kernel32 = DynamicLibrary.open('kernel32.dll');

      _createToolhelp32Snapshot = _kernel32!
          .lookupFunction<_CreateToolhelp32SnapshotNative,
              _CreateToolhelp32SnapshotDart>('CreateToolhelp32Snapshot');

      _process32First = _kernel32!
          .lookupFunction<_Process32Native, _Process32Dart>('Process32FirstW');

      _process32Next = _kernel32!
          .lookupFunction<_Process32Native, _Process32Dart>('Process32NextW');

      _openProcess = _kernel32!
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');

      _queryFullProcessImageName = _kernel32!.lookupFunction<
              _QueryFullProcessImageNameWNative,
              _QueryFullProcessImageNameWDart>(
          'QueryFullProcessImageNameW');

      _getExitCodeProcess = _kernel32!.lookupFunction<
              _GetExitCodeProcessNative, _GetExitCodeProcessDart>(
          'GetExitCodeProcess');

      _closeHandle = _kernel32!
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

      _available = true;
      _initialized = true; // 仅成功时置位
      debugPrint('[WIN32-PROC] ✅ FFI 初始化成功（kernel32.dll）');
      debugPrint(
          '[WIN32-PROC]   PROCESSENTRY32W size = ${sizeOf<PROCESSENTRY32W>()} bytes');
    } catch (e) {
      _available = false;
      // 不设置 _initialized = true，允许后续调用重试
      debugPrint('[WIN32-PROC] ❌ FFI 初始化失败（将重试）: $e');
    }
  }

  /// 检测 FFI 是否可用
  static bool get isAvailable {
    if (!_initialized) _initialize();
    return _available;
  }

  // ═══════════════════════════════════════════════════════════════
  // 进程枚举
  // ═══════════════════════════════════════════════════════════════

  /// 枚举当前所有运行中的进程
  ///
  /// 使用 CreateToolhelp32Snapshot + Process32FirstW/NextW，
  /// 替代 `Process.run('tasklist', ...)`。
  ///
  /// 返回所有进程的 PID、父 PID 和 exe 名称列表。
  /// 失败时返回空列表（调用方应回退到 tasklist）。
  static List<ProcessInfo> enumerateProcesses() {
    if (!_initialized) _initialize();
    if (!_available || _createToolhelp32Snapshot == null) {
      return [];
    }

    final result = <ProcessInfo>[];
    Pointer<Void>? snapshot;

    try {
      // 创建进程快照
      snapshot = _createToolhelp32Snapshot!(_th32csSnapProcess, 0);
      if (snapshot == nullptr || snapshot.address == 0) {
        debugPrint('[WIN32-PROC] ⚠️ CreateToolhelp32Snapshot 返回空句柄');
        return [];
      }

      // 分配 PROCESSENTRY32W 结构体并设置 dwSize
      final entryPtr = malloc<PROCESSENTRY32W>();
      try {
        entryPtr.ref.dwSize = sizeOf<PROCESSENTRY32W>();

        // 遍历进程列表
        // ★ Process32FirstW 返回 0 表示失败（常见原因：dwSize 不匹配）
        if (_process32First!(snapshot, entryPtr) != 0) {
          do {
            final pid = entryPtr.ref.th32ProcessID;
            final parentPid = entryPtr.ref.th32ParentProcessID;
            // 从 szExeFile 数组提取 exe 名称
            final exeName = _exeNameFromEntry(entryPtr);

            if (pid > 0) {
              result.add(ProcessInfo(pid, parentPid, exeName));
            }
          } while (_process32Next!(snapshot, entryPtr) != 0);
        } else {
          // ★ 诊断日志：Process32FirstW 失败，记录 dwSize 帮助排查
          debugPrint(
              '[WIN32-PROC] ⚠️ Process32FirstW 失败 (dwSize=${entryPtr.ref.dwSize})，'
              '可能原因：结构体大小不匹配或快照无效');
        }
      } finally {
        malloc.free(entryPtr);
      }
    } catch (e) {
      debugPrint('[WIN32-PROC] ⚠️ enumerateProcesses 异常: $e');
    } finally {
      // 确保关闭快照句柄
      if (snapshot != null &&
          snapshot != nullptr &&
          snapshot.address != 0 &&
          _closeHandle != null) {
        _closeHandle!(snapshot);
      }
    }

    return result;
  }

  /// 从 PROCESSENTRY32W 的 szExeFile 数组提取 exe 名称（小写）
  static String _exeNameFromEntry(Pointer<PROCESSENTRY32W> entryPtr) {
    try {
      // 逐字符读取 szExeFile[WCHAR] 数组，截断到第一个 null
      final chars = <int>[];
      for (int i = 0; i < 260; i++) {
        final c = entryPtr.ref.szExeFile[i];
        if (c == 0) break;
        chars.add(c);
      }
      return String.fromCharCodes(chars).toLowerCase();
    } catch (_) {
      return '';
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 进程路径查询
  // ═══════════════════════════════════════════════════════════════

  /// 查询指定 PID 的进程 exe 完整路径
  ///
  /// 使用 OpenProcess + QueryFullProcessImageNameW，
  /// 替代 `Process.runSync('powershell', '(Get-Process -Id $pid).Path')`。
  ///
  /// 返回 exe 完整路径，失败（进程不存在/权限不足）时返回 null。
  /// 使用 PROCESS_QUERY_LIMITED_INFORMATION 权限（不需要管理员）。
  static String? getProcessExePath(int pid) {
    if (pid <= 0) return null;
    if (!_initialized) _initialize();
    if (!_available ||
        _openProcess == null ||
        _queryFullProcessImageName == null ||
        _closeHandle == null) {
      return null;
    }

    Pointer<Void>? handle;
    try {
      handle = _openProcess!(_processQueryLimitedInformation, _false, pid);
      if (handle == nullptr || handle.address == 0) {
        return null; // 进程不存在或无权限
      }

      // 分配缓冲区（32768 字符以支持长路径）
      // ★ Fix: Utf16 不是 SizedNativeType，不能直接 malloc<Utf16>，
      // 需先分配 Uint16 再 cast 为 Pointer<Utf16>
      const int bufferSize = 32768;
      final Pointer<Uint16> rawBuf = malloc<Uint16>(bufferSize);
      final bufferPtr = rawBuf.cast<Utf16>();
      final sizePtr = malloc<Uint32>();
      try {
        sizePtr.value = bufferSize;
        final success = _queryFullProcessImageName!(
            handle, 0, bufferPtr, sizePtr);

        if (success != 0 && sizePtr.value > 0) {
          return bufferPtr.toDartString();
        }
        return null;
      } finally {
        malloc.free(rawBuf);
        malloc.free(sizePtr);
      }
    } catch (e) {
      debugPrint('[WIN32-PROC] ⚠️ getProcessExePath($pid) 异常: $e');
      return null;
    } finally {
      if (handle != null &&
          handle != nullptr &&
          handle.address != 0 &&
          _closeHandle != null) {
        _closeHandle!(handle);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 进程存活检测
  // ═══════════════════════════════════════════════════════════════

  /// 检测指定 PID 的进程是否仍在运行
  ///
  /// 使用 OpenProcess + GetExitCodeProcess，
  /// 替代 `Process.run('tasklist', ['/FI', 'PID eq $pid'])`。
  ///
  /// 退出码为 STILL_ACTIVE (259) 时返回 true，否则 false。
  /// 对应 ReinaManager 的 is_process_running 函数。
  static bool isProcessAlive(int pid) {
    if (pid <= 0) return false;
    if (!_initialized) _initialize();
    if (!_available ||
        _openProcess == null ||
        _getExitCodeProcess == null ||
        _closeHandle == null) {
      return false;
    }

    Pointer<Void>? handle;
    try {
      handle = _openProcess!(_processQueryLimitedInformation, _false, pid);
      if (handle == nullptr || handle.address == 0) {
        return false; // 进程不存在或无权限
      }

      final exitCodePtr = malloc<Uint32>();
      try {
        final success = _getExitCodeProcess!(handle, exitCodePtr);
        if (success == 0) {
          return false; // GetExitCodeProcess 失败
        }
        return exitCodePtr.value == _stillActive;
      } finally {
        malloc.free(exitCodePtr);
      }
    } catch (e) {
      debugPrint('[WIN32-PROC] ⚠️ isProcessAlive($pid) 异常: $e');
      return false;
    } finally {
      if (handle != null &&
          handle != nullptr &&
          handle.address != 0 &&
          _closeHandle != null) {
        _closeHandle!(handle);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 目录内进程扫描
  // ═══════════════════════════════════════════════════════════════

  /// 获取指定目录下所有正在运行的进程 PID 集合
  ///
  /// 使用 enumerateProcesses 枚举所有进程，再通过 getProcessExePath
  /// 逐个检查 exe 路径是否在目标目录下。
  ///
  /// 替代 `Process.run('powershell', 'Get-CimInstance Win32_Process')`。
  /// 对应 ReinaManager 的 get_all_candidate_pids + get_processes_in_directory。
  ///
  /// 自动排除当前进程（管理器自身）的 PID。
  static Set<int> getProcessesInDirectory(String directory) {
    if (directory.isEmpty) return {};
    if (!_initialized) _initialize();
    if (!_available) return {};

    final managerPid = pid; // 当前进程 PID
    final result = <int>{};
    final normalizedDir = directory.toLowerCase().replaceAll('/', '\\');

    final processes = enumerateProcesses();
    if (processes.isEmpty) return {};

    for (final p in processes) {
      if (p.pid == managerPid) continue; // 排除管理器自身

      final exePath = getProcessExePath(p.pid);
      if (exePath == null) continue;

      final normalizedPath = exePath.toLowerCase().replaceAll('/', '\\');
      if (_isSubPath(normalizedPath, normalizedDir)) {
        result.add(p.pid);
      }
    }

    if (result.isNotEmpty) {
      debugPrint(
          '[WIN32-PROC] 📁 目录 "$directory" 下找到 ${result.length} 个进程: $result');
    }

    return result;
  }

  /// 判断路径是否为某目录的子路径（忽略大小写）
  ///
  /// 对应 ReinaManager 的 is_sub_path_ignore_case 函数。
  /// 注意：此方法假设输入路径已规范化（小写 + 反斜杠）。
  static bool _isSubPath(String path, String baseDir) {
    if (path.isEmpty || baseDir.isEmpty) return false;
    if (path.length < baseDir.length) return false;
    if (!path.startsWith(baseDir)) return false;
    if (path.length == baseDir.length) return true;

    // 确保匹配边界是路径分隔符
    final nextChar = path[baseDir.length];
    return nextChar == '\\' || nextChar == '/';
  }

  // ═══════════════════════════════════════════════════════════════
  // 批量存活检测（性能优化）
  // ═══════════════════════════════════════════════════════════════

  /// 一次性获取所有运行中进程的 PID 集合和名称→PID 映射
  ///
  /// 供 _checkActiveSessionsInternal 使用，替代 tasklist CSV 解析。
  /// 返回 (runningPids, runningNameToPids) 元组。
  static (Set<int>, Map<String, Set<int>>) getRunningProcessInfo() {
    final processes = enumerateProcesses();
    if (processes.isEmpty) {
      return (<int>{}, <String, Set<int>>{});
    }

    final runningPids = <int>{};
    final runningNameToPids = <String, Set<int>>{};

    for (final p in processes) {
      runningPids.add(p.pid);
      runningNameToPids.putIfAbsent(p.exeName, () => <int>{}).add(p.pid);
    }

    return (runningPids, runningNameToPids);
  }
}
