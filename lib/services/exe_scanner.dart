import 'dart:io';
import 'package:flutter/foundation.dart';

/// UX-26: 共享的有界 exe 扫描工具
///
/// 此前 `ExeSelectorDialog` 与 `LaunchManagerDialog` 各自独立实现 exe 扫描逻辑，
/// 且 `ExeSelectorDialog` 使用无界 `dir.list(recursive: true)`，遇到大型游戏目录
/// （如包含大量资源文件的 GAL 游戏）可能长时间卡死。
///
/// 现统一为单一实现：递归深度受限（默认 3 层）、结果数量受限（默认 200），
/// 两个对话框均调用此函数，消除重复代码并杜绝无界扫描的卡死风险。
class ExeScanner {
  ExeScanner._();

  /// 排除的关键字——匹配到这些子串的 exe 视为非启动程序（安装器/卸载器等）
  static const excludeKeywords = ['unins', 'install', 'setup', 'uninstall'];

  /// 有界递归扫描 exe 文件。
  ///
  /// [root] 扫描根目录
  /// [maxDepth] 最大递归深度（1 = 仅当前目录）
  /// [maxCount] 最大返回数量，达到即停止扫描
  static Future<List<File>> scanBounded(
    Directory root, {
    int maxDepth = 3,
    int maxCount = 200,
  }) async {
    final result = <File>[];

    Future<void> scanDir(Directory dir, int depth) async {
      if (depth > maxDepth || result.length >= maxCount) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (result.length >= maxCount) return;
          if (entity is File) {
            // 🔴 排除关键字只对文件名匹配，禁止用完整路径——
            // 目录名含 "Install Patch"/"Setup" 等字样时（galgame 收藏极常见），
            // 全路径匹配会把目录下所有 exe 误杀成 0 个程序（2026-09-13 用户实锤）
            final fileName =
                entity.path.replaceAll('\\', '/').split('/').last.toLowerCase();
            if (fileName.endsWith('.exe') &&
                !excludeKeywords.any((kw) => fileName.contains(kw))) {
              result.add(entity);
            }
          } else if (entity is Directory) {
            await scanDir(entity, depth + 1);
          }
        }
      } catch (e) {
        // 权限不足等错误，跳过该子目录
        debugPrint('[EXE_SCAN] 跳过子目录: ${dir.path} -> $e');
      }
    }

    await scanDir(root, 1);
    return result;
  }
}
