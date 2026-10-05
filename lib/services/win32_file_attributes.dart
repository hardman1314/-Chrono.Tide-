import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════
// Win32 文件属性 FFI（★ P0-6，2026-09-16 稳定性/性能审计）
// ═══════════════════════════════════════════════════════════════

/// FILE_ATTRIBUTE_READONLY
const int _fileAttributeReadonly = 0x00000001;

/// FILE_ATTRIBUTE_HIDDEN
const int _fileAttributeHidden = 0x00000002;

/// INVALID_FILE_ATTRIBUTES
const int _invalidFileAttributes = 0xFFFFFFFF;

typedef _GetFileAttributesNative = Uint32 Function(Pointer<Utf16>);
typedef _GetFileAttributesDart = int Function(Pointer<Utf16>);
typedef _SetFileAttributesNative = Int32 Function(Pointer<Utf16>, Uint32);
typedef _SetFileAttributesDart = int Function(Pointer<Utf16>, int);

/// Win32 文件属性读写（零进程创建）
///
/// 背景：`.ctgame` 标记文件的写入需要"清只读/隐藏 → 写 → 设隐藏"三步。
/// 旧实现每步都 `Process.run('attrib', runInShell: true)` —— **每个游戏 2 次
/// 进程创建**（含 cmd shell），2000 条导入 = 4000 次进程创建（每次数十 ms +
/// 句柄开销），是入库阶段的确定性开销。
///
/// 本类用 FFI 直接调 kernel32 的 Get/SetFileAttributesW（项目已有 dart:ffi +
/// package:ffi 先例：win32_process_service / magpie / XInput）。
/// **失败时返回 false，调用方回退到原有 attrib 进程实现**（双保险，不改语义）。
class Win32FileAttributes {
  Win32FileAttributes._();

  static bool _initTried = false;
  static bool _available = false;
  static _GetFileAttributesDart? _getFileAttributes;
  static _SetFileAttributesDart? _setFileAttributes;

  /// 测试可见：FFI 是否可用
  @visibleForTesting
  static bool get isAvailable {
    _ensureInit();
    return _available;
  }

  static void _ensureInit() {
    if (_initTried) return;
    _initTried = true;
    if (!Platform.isWindows) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _getFileAttributes = kernel32.lookupFunction<_GetFileAttributesNative,
          _GetFileAttributesDart>('GetFileAttributesW');
      _setFileAttributes = kernel32.lookupFunction<_SetFileAttributesNative,
          _SetFileAttributesDart>('SetFileAttributesW');
      _available = true;
    } catch (e) {
      debugPrint('[WIN32-ATTR] FFI 初始化失败，回退 attrib 进程: $e');
      _available = false;
    }
  }

  /// 清除只读与隐藏属性（写文件前调用，避免只读文件写入失败）
  static bool clearReadOnlyHidden(String path) {
    _ensureInit();
    final get = _getFileAttributes;
    final set = _setFileAttributes;
    if (!_available || get == null || set == null) return false;
    final ptr = path.toNativeUtf16();
    try {
      final current = get(ptr);
      if (current == _invalidFileAttributes) return false;
      final cleared = current & ~_fileAttributeReadonly & ~_fileAttributeHidden;
      if (cleared == current) return true; // 无需变更
      return set(ptr, cleared) != 0;
    } catch (e) {
      debugPrint('[WIN32-ATTR] 清除属性失败: $e');
      return false;
    } finally {
      calloc.free(ptr);
    }
  }

  /// 设置隐藏属性
  static bool setHidden(String path) {
    _ensureInit();
    final get = _getFileAttributes;
    final set = _setFileAttributes;
    if (!_available || get == null || set == null) return false;
    final ptr = path.toNativeUtf16();
    try {
      final current = get(ptr);
      if (current == _invalidFileAttributes) return false;
      final withHidden = current | _fileAttributeHidden;
      if (withHidden == current) return true; // 已是隐藏
      return set(ptr, withHidden) != 0;
    } catch (e) {
      debugPrint('[WIN32-ATTR] 设置隐藏失败: $e');
      return false;
    } finally {
      calloc.free(ptr);
    }
  }
}
