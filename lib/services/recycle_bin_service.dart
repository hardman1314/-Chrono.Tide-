/// 回收站服务 —— 把文件/目录移入 Windows 回收站（可恢复），而非永久删除。
///
/// 技术路径来自 Phase 0 已验证的探针（`dev_probe/phase0_recycle_probe.dart`）：
/// Dart FFI 直调 `shell32!SHFileOperationW(FO_DELETE | FOF_ALLOWUNDO)`，实测
/// ret=0、目录消失、`SHQueryRecycleBinW` 项数 +1。本文件把该路径提升为正式服务。
///
/// 🔴 设计约束（方案 §10 P0 / ADR-007 配套）：
/// - 删除本体这类**用户可见的破坏性动作**一律走本服务（可从回收站还原），
///   ⛔ 不用 `Directory.delete(recursive:)`，⛔ 不用 7z `-sdel`。
/// - 本文件**刻意不 import flutter**，纯 Dart + FFI，dev_probe 可直接加载实测。
/// - 仅 Windows（本项目本就是 Windows 桌面应用）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Win32 常量与结构（与 Phase 0 探针一致）
// ---------------------------------------------------------------------------

const int _foDelete = 0x0003;
const int _fofSilent = 0x0004;
const int _fofNoConfirmation = 0x0010;
const int _fofAllowUndo = 0x0040;
const int _fofNoConfirmMkdir = 0x0200;
const int _fofNoErrorUi = 0x0400;

final class _ShFileOpStructW extends Struct {
  external Pointer<Void> hwnd; // HWND
  @Uint32()
  external int wFunc; // UINT
  external Pointer<Uint16> pFrom; // PCZZWSTR（双 \0 结尾）
  external Pointer<Uint16> pTo; // PCZZWSTR
  @Uint16()
  external int fFlags; // FILEOP_FLAGS
  @Int32()
  external int fAnyOperationsAborted; // BOOL
  external Pointer<Void> hNameMappings; // LPVOID
  external Pointer<Uint16> lpszProgressTitle; // PCWSTR
}

typedef _ShFileOpNative = Int32 Function(Pointer<_ShFileOpStructW>);
typedef _ShFileOpDart = int Function(Pointer<_ShFileOpStructW>);

/// 操作结果：[ok] 为真表示实体已移入回收站。
class RecycleBinOutcome {
  final bool ok;

  /// `SHFileOperationW` 返回码（0 = 成功；未调用时为 -1）。
  final int code;

  /// 用户/系统中途放弃。
  final bool aborted;

  final String? error;

  const RecycleBinOutcome._(this.ok, this.code, this.aborted, this.error);

  @override
  String toString() =>
      'RecycleBinOutcome(ok=$ok, code=$code, aborted=$aborted, error=$error)';
}

/// 回收站操作（静态工具类）。
abstract final class RecycleBinService {
  /// 把 [path]（文件或目录）移入回收站。
  ///
  /// 返回的 [RecycleBinOutcome]：
  /// - ok=true   → 实体已进回收站（可还原）；
  /// - ok=false  → 失败原因在 [RecycleBinOutcome.error]，**调用方必须如实展示**，
  ///   且不得把「删除失败」静默吞掉（ADR-007）。
  ///
  /// 🔴 本服务不做任何路径归属判断 —— 「该不该删」是调用方（确认框 + 审计日志）
  ///    的责任，这里只负责「怎么删得可恢复」。
  static Future<RecycleBinOutcome> moveToRecycleBin(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return const RecycleBinOutcome._(false, -1, false, '路径为空');
    }
    final entity = FileSystemEntity.typeSync(trimmed);
    if (entity == FileSystemEntityType.notFound) {
      return RecycleBinOutcome._(false, -1, false, '目标不存在：$trimmed');
    }

    final shell32 = DynamicLibrary.open('shell32.dll');
    final shFileOp =
        shell32.lookupFunction<_ShFileOpNative, _ShFileOpDart>('SHFileOperationW');

    // pFrom 必须双 \0 结尾（PCZZWSTR）。
    final units = trimmed.codeUnits.toList()
      ..add(0)
      ..add(0);
    final pFrom = calloc<Uint16>(units.length);
    final op = calloc<_ShFileOpStructW>();
    try {
      for (var i = 0; i < units.length; i++) {
        pFrom[i] = units[i];
      }
      op.ref.hwnd = nullptr;
      op.ref.wFunc = _foDelete;
      op.ref.pFrom = pFrom;
      op.ref.pTo = Pointer<Uint16>.fromAddress(0);
      op.ref.fFlags = _fofAllowUndo |
          _fofNoConfirmation |
          _fofSilent |
          _fofNoErrorUi |
          _fofNoConfirmMkdir;
      op.ref.fAnyOperationsAborted = 0;
      op.ref.hNameMappings = nullptr;
      op.ref.lpszProgressTitle = Pointer<Uint16>.fromAddress(0);

      final code = shFileOp(op);
      final aborted = op.ref.fAnyOperationsAborted != 0;

      if (code != 0) {
        return RecycleBinOutcome._(
            false, code, aborted, 'SHFileOperationW 失败（code=$code）');
      }
      if (aborted) {
        return RecycleBinOutcome._(false, code, true, '操作被中止');
      }
      // shell 异步落盘给一点缓冲，再确认真的消失了。
      for (var i = 0; i < 10; i++) {
        if (FileSystemEntity.typeSync(trimmed) == FileSystemEntityType.notFound) {
          return const RecycleBinOutcome._(true, 0, false, null);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      return RecycleBinOutcome._(
          false, code, aborted, '调用返回成功，但目标仍存在于：$trimmed');
    } catch (e) {
      return RecycleBinOutcome._(false, -1, false, '回收站操作异常：$e');
    } finally {
      calloc.free(pFrom);
      calloc.free(op);
    }
  }
}
