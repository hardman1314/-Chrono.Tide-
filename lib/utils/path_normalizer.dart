import 'dart:io';
import 'package:path/path.dart' as p;

/// 统一路径规范化工具。
///
/// 解决三类排重失效：
/// 1. 分隔符混合（/ 与 \）
/// 2. 冗余段（..、.、双斜杠、尾部斜杠）
/// 3. 大小写差异（Windows 不区分大小写）
/// 4. 符号链接（可选解析，需路径存在）
///
/// 项目原有三套规范化逻辑并存且互不兼容：
/// - `batch_import_controller._normalizePath`：只小写不处理 `..`
/// - `auto_import_pipeline.isAlreadyImported`：`p.normalize` 处理 `..` 但不小写
/// - `watch_folder_service`：`p.normalize`，同上不小写
/// 这导致跨管线排重失效。本类统一到单一实现，所有调用方改用本类。
class PathNormalizer {
  PathNormalizer._();

  /// 规范化用于「比较」的路径。
  ///
  /// 步骤：绝对化 → 统一为 \ → 折叠冗余段 → 小写 → 去尾部斜杠。
  /// 不解析符号链接（路径可能已不存在）。
  static String forCompare(String path) {
    if (path.isEmpty) return '';
    var abs = p.isAbsolute(path) ? path : p.absolute(path);
    var n = p.normalize(abs.replaceAll('/', '\\'));
    n = n.toLowerCase();
    // 去尾部斜杠，但保留根 "C:\\"
    if (n.length > 3 && n.endsWith('\\')) {
      n = n.substring(0, n.length - 1);
    }
    return n;
  }

  /// 规范化用于「持久化存储」的路径。
  ///
  /// 与 [forCompare] 相同，但**不小写**（保留可读性），可选解析符号链接。
  /// 写入 game.json 的 directory_path 应使用此方法。
  /// 解析符号链接仅在路径存在时进行，失败时静默保留原值。
  static String forStore(String path, {bool resolveSymlinks = false}) {
    if (path.isEmpty) return '';
    var p2 = p.isAbsolute(path) ? path : p.absolute(path);
    if (resolveSymlinks) {
      try {
        final dir = Directory(p2);
        if (dir.existsSync()) {
          p2 = dir.resolveSymbolicLinksSync();
        }
      } catch (_) {
        // 路径不存在或解析失败，保留原值
      }
    }
    var n = p.normalize(p2.replaceAll('/', '\\'));
    if (n.length > 3 && n.endsWith('\\')) {
      n = n.substring(0, n.length - 1);
    }
    return n; // 注意：不小写，保留可读性
  }

  /// 计算相对深度，兼容混合分隔符。
  ///
  /// 替代旧代码 `subDirPath.split('\\').length - rootPath.split('\\').length`，
  /// 该旧实现若 `rootPath` 用 `/` 而 `subDirPath` 用 `\` 会算错深度。
  ///
  /// 返回 `childPath` 相对于 `rootPath` 的深度差；
  /// 若 `childPath` 不是 `rootPath` 的后代，返回 -1。
  static int depthOf(String childPath, String rootPath) {
    final child = p.split(p.normalize(childPath.replaceAll('/', '\\')));
    final root = p.split(p.normalize(rootPath.replaceAll('/', '\\')));
    if (child.length < root.length) return -1;
    for (var i = 0; i < root.length; i++) {
      if (child[i].toLowerCase() != root[i].toLowerCase()) return -1;
    }
    return child.length - root.length;
  }

  /// 判断 `child` 是否为 `parent` 的（直接或间接）子目录。
  ///
  /// 替代旧 `_isSubdirectory` 的 `startsWith` 原始比较。
  /// 旧比较未规范化会导致 `D:\Games` 误判为 `D:\Game` 的子目录。
  static bool isSubdirectory(String parent, String child) {
    final np = forCompare(parent);
    final nc = forCompare(child);
    return nc.length > np.length && nc.startsWith(np + '\\');
  }
}
