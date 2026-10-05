import 'dart:io';

/// 大目录文件系统遍历辅助（★ P0-7，2026-09-16 稳定性/性能审计）
///
/// 背景：多处使用 `dir.list(recursive: true).toList()` 做"统计 / 存在性检查"。
/// 大游戏目录（几十万~百万条目）会一次性物化全部 `FileSystemEntity`
/// （每条目 100+ 字节）→ 数百 MB~GB 内存峰值 → **OOM 原生崩溃（Dart 层不可捕获）**。
/// 这正是"导入 300GB 游戏时崩溃"的路径之一。
///
/// 本辅助统一改为**流式**遍历：内存 O(1)，存在性检查还能提前中断（更快）。
class FsScan {
  FsScan._();

  /// 递归统计文件数与目录数（流式，不物化）
  static Future<({int files, int dirs})> countRecursive(Directory dir) async {
    var files = 0;
    var dirs = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          files++;
        } else if (entity is Directory) {
          dirs++;
        }
      }
    } catch (_) {
      // 权限不足等：返回已统计部分（调用方按"可能不完整"处理）
    }
    return (files: files, dirs: dirs);
  }

  /// 递归判断是否存在满足条件的文件（**找到即中断**，不物化）
  ///
  /// [test] 接收小写化的完整路径。
  static Future<bool> containsFile(
    Directory dir,
    bool Function(String lowerPath) test,
  ) async {
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && test(entity.path.toLowerCase())) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 有界收集满足条件的文件完整路径（默认上限 200，防异常结构下失控）
  static Future<List<String>> collectFilePaths(
    Directory dir, {
    required bool Function(String lowerPath) test,
    int limit = 200,
  }) async {
    final out = <String>[];
    if (limit <= 0) return out;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (test(entity.path.toLowerCase())) {
          out.add(entity.path);
          if (out.length >= limit) break;
        }
      }
    } catch (_) {}
    return out;
  }
}
