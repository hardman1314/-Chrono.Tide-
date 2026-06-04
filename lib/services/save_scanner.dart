import 'dart:io';
import 'package:path/path.dart' as path;

import 'save_manifest.dart';

/// 检测到的存档文件信息
class DetectedSaveFile {
  /// 完整路径
  final String filePath;

  /// 文件/目录大小（字节）
  final int size;

  /// 最后修改时间
  final DateTime lastModified;

  /// 是否为目录（目录型存档）
  final bool isDirectory;

  /// 标签：save（存档）或 config（配置）
  final String tag;

  const DetectedSaveFile({
    required this.filePath,
    required this.size,
    required this.lastModified,
    required this.isDirectory,
    this.tag = 'save',
  });

  @override
  String toString() =>
      'DetectedSaveFile($filePath, tag=$tag, isDir=$isDirectory, size=$size)';
}

/// 路径占位符展开时用于标记"在当前平台跳过"的哨兵值
const String _skipMarker = '__SKIP__';

/// 存档路径扫描引擎
///
/// 负责将清单中的占位符路径展开为实际路径，并扫描文件系统
/// 找到匹配的存档文件/目录。无清单条目时使用通用模式自动检测。
class SaveScanner {
  // ==================== 占位符展开 ====================

  /// 展开路径中的占位符，返回展开后的路径列表。
  ///
  /// 某些占位符（如 `<storeUserId>`）可能产生多个候选路径（通配符），
  /// 因此返回值为列表。若占位符在当前平台不适用，返回空列表。
  ///
  /// [pattern]    含占位符的路径模板
  /// [gameName]   游戏名称
  /// [installDir] 游戏安装目录（即 <base>）
  /// [manifestEntry] 清单条目（可选，提供 storeGameId 等）
  static List<String> expandPlaceholders(
    String pattern, {
    required String gameName,
    required String installDir,
    ManifestGame? manifestEntry,
  }) {
    // 先做单值替换，再处理多值占位符
    var result = pattern;

    // --- Windows 系统目录 ---
    result = result.replaceAll('<winAppData>', _winAppData());
    result = result.replaceAll('<winLocalAppData>', _winLocalAppData());
    result = result.replaceAll('<winLocalAppDataLow>', _winLocalAppDataLow());
    result = result.replaceAll('<winDocuments>', _winDocuments());
    result = result.replaceAll('<winPublic>', _winPublic());
    result = result.replaceAll('<winProgramData>', _winProgramData());
    result = result.replaceAll('<winDir>', _winDir());

    // --- 通用占位符 ---
    result = result.replaceAll('<home>', _homeDir());
    result = result.replaceAll('<osUserName>', _osUserName());

    // --- 游戏相关占位符 ---
    // <root> = 游戏库根目录（installDir 的父目录）
    final rootDir = path.dirname(installDir);
    result = result.replaceAll('<root>', rootDir);

    // <game> = 游戏文件夹名
    final gameFolder = path.basename(installDir);
    result = result.replaceAll('<game>', gameFolder);

    // <base> = 完整游戏安装路径
    result = result.replaceAll('<base>', installDir);

    // <storeGameId> = 商店游戏 ID（如 Steam App ID）
    final storeGameId = manifestEntry?.steam.id?.toString() ?? '';
    result = result.replaceAll('<storeGameId>', storeGameId);

    // --- Linux/XDG 占位符（Windows 上跳过） ---
    if (result.contains('<xdgData>')) return const [];
    if (result.contains('<xdgConfig>')) return const [];

    // --- 多值占位符：<storeUserId> 展开为通配符 ---
    if (result.contains('<storeUserId>')) {
      // 将 <storeUserId> 替换为 * 通配符，后续 glob 匹配时处理
      result = result.replaceAll('<storeUserId>', '*');
    }

    // 如果包含跳过标记，返回空
    if (result.contains(_skipMarker)) return const [];

    return [result];
  }

  // ==================== 系统路径获取 ====================

  /// %APPDATA% (Roaming)
  static String _winAppData() {
    final env = Platform.environment['APPDATA'];
    if (env != null && env.isNotEmpty) return env;
    return path.join(_homeDir(), 'AppData', 'Roaming');
  }

  /// %LOCALAPPDATA% (Local)
  static String _winLocalAppData() {
    final env = Platform.environment['LOCALAPPDATA'];
    if (env != null && env.isNotEmpty) return env;
    return path.join(_homeDir(), 'AppData', 'Local');
  }

  /// %LOCALAPPDATA%Low (LocalLow)
  static String _winLocalAppDataLow() {
    return path.join(_homeDir(), 'AppData', 'LocalLow');
  }

  /// 用户文档文件夹
  static String _winDocuments() {
    final env = Platform.environment['USERPROFILE'];
    if (env != null && env.isNotEmpty) {
      return path.join(env, 'Documents');
    }
    return path.join(_homeDir(), 'Documents');
  }

  /// C:\Users\Public
  static String _winPublic() {
    return r'C:\Users\Public';
  }

  /// C:\ProgramData
  static String _winProgramData() {
    final env = Platform.environment['ProgramData'];
    if (env != null && env.isNotEmpty) return env;
    return r'C:\ProgramData';
  }

  /// C:\Windows
  static String _winDir() {
    final env =
        Platform.environment['SystemRoot'] ?? Platform.environment['windir'];
    if (env != null && env.isNotEmpty) return env;
    return r'C:\Windows';
  }

  /// 用户主目录
  static String _homeDir() {
    final env =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (env != null && env.isNotEmpty) return env;
    return Platform.environment['HOMEDRIVE'] != null
        ? '${Platform.environment['HOMEDRIVE']}${Platform.environment['HOMEPATH']}'
        : r'C:\Users\Default';
  }

  /// 当前 Windows 用户名
  static String _osUserName() {
    return Platform.environment['USERNAME'] ?? 'Unknown';
  }

  // ==================== 存档扫描 ====================

  /// 扫描游戏存档文件
  ///
  /// 如果提供了 [manifestEntry]，则按清单中定义的路径模式扫描；
  /// 否则使用通用模式自动检测。
  ///
  /// [gameName]     游戏名称
  /// [installDir]   游戏安装目录
  /// [manifestEntry] 清单条目（可选）
  ///
  /// 返回检测到的存档文件/目录列表
  List<DetectedSaveFile> scanGameSaves(
    String gameName,
    String installDir, {
    ManifestGame? manifestEntry,
  }) {
    if (manifestEntry != null) {
      return _scanFromManifest(gameName, installDir, manifestEntry);
    } else {
      return detectSavePaths(gameName, installDir);
    }
  }

  /// 根据清单条目扫描存档
  List<DetectedSaveFile> _scanFromManifest(
    String gameName,
    String installDir,
    ManifestGame manifestEntry,
  ) {
    final results = <DetectedSaveFile>[];

    // 扫描清单中定义的所有文件路径
    for (final entry in manifestEntry.files.entries) {
      final pathPattern = entry.key;
      final fileEntry = entry.value;

      // 确定标签：优先使用 save 标签
      final tag = fileEntry.tags.contains(ManifestTag.save) ? 'save' : 'config';

      final expanded = expandPlaceholders(
        pathPattern,
        gameName: gameName,
        installDir: installDir,
        manifestEntry: manifestEntry,
      );
      for (final p in expanded) {
        results.addAll(_resolveGlobAndCollect(p, tag: tag));
      }
    }

    return results;
  }

  /// 自动检测存档路径（无清单时的回退方案）
  ///
  /// 使用常见存档目录模式进行扫描
  List<DetectedSaveFile> detectSavePaths(String gameName, String installDir) {
    final results = <DetectedSaveFile>[];

    // 通用存档路径模式
    final savePatterns = <String>[
      // AppData/Roaming 下的游戏目录
      '<winAppData>/$gameName/',
      // AppData/Local 下的游戏目录
      '<winLocalAppData>/$gameName/',
      // 文档/My Games 下的游戏目录
      '<winDocuments>/My Games/$gameName/',
      // 游戏安装目录下的存档文件夹
      '<base>/save/',
      '<base>/saves/',
      '<base>/savedata/',
      '<base>/SaveData/',
      '<base>/Save/',
      // 游戏安装目录下的存档文件（glob 模式）
      '<base>/save*.dat',
      '<base>/save*.sav',
    ];

    for (final pattern in savePatterns) {
      final expanded = expandPlaceholders(
        pattern,
        gameName: gameName,
        installDir: installDir,
      );
      for (final p in expanded) {
        results.addAll(_resolveGlobAndCollect(p, tag: 'save'));
      }
    }

    // 通用配置路径模式
    final configPatterns = <String>[
      '<winAppData>/$gameName/',
      '<winLocalAppData>/$gameName/',
    ];

    for (final pattern in configPatterns) {
      final expanded = expandPlaceholders(
        pattern,
        gameName: gameName,
        installDir: installDir,
      );
      for (final p in expanded) {
        // 配置路径中已作为 save 扫描过的不再重复添加
        final found = _resolveGlobAndCollect(p, tag: 'config');
        for (final f in found) {
          if (!results.any((r) => r.filePath == f.filePath)) {
            results.add(f);
          }
        }
      }
    }

    return results;
  }

  // ==================== Glob 匹配与文件收集 ====================

  /// 解析路径中的 glob 模式，收集匹配的文件/目录
  ///
  /// [globPath] 可能包含通配符的路径（如 `C:\Users\*\AppData\save*.dat`）
  /// [tag]     标记为 save 或 config
  List<DetectedSaveFile> _resolveGlobAndCollect(String globPath,
      {required String tag}) {
    final results = <DetectedSaveFile>[];

    // 判断路径是否包含 glob 通配符
    if (_containsGlob(globPath)) {
      results.addAll(_expandGlob(globPath, tag: tag));
    } else {
      // 无通配符，直接检查路径是否存在
      final entity = _getFileSystemEntity(globPath);
      if (entity != null) {
        final detected = _entityToDetected(entity, tag: tag);
        if (detected != null) results.add(detected);
      }
    }

    return results;
  }

  /// 判断路径是否包含 glob 通配符
  static bool _containsGlob(String p) {
    return p.contains('*') || p.contains('?');
  }

  /// 展开 glob 模式，返回匹配的文件/目录
  ///
  /// 处理路径中间的通配符（如 `<storeUserId>` 展开为 `*`）和
  /// 文件名部分的通配符（如 `save*.dat`）
  List<DetectedSaveFile> _expandGlob(String globPath, {required String tag}) {
    final results = <DetectedSaveFile>[];

    // 将路径拆分为目录部分和文件名部分
    final dirPart = path.dirname(globPath);
    final namePart = path.basename(globPath);

    // 先展开目录部分的通配符
    final expandedDirs = _expandDirGlob(dirPart);

    for (final dir in expandedDirs) {
      final dirEntity = Directory(dir);
      if (!dirEntity.existsSync()) continue;

      if (_containsGlob(namePart)) {
        // 文件名含通配符，遍历目录匹配
        try {
          final globRegex = _globToRegex(namePart);
          for (final entity in dirEntity.listSync()) {
            final baseName = path.basename(entity.path);
            if (globRegex.hasMatch(baseName)) {
              final detected = _entityToDetected(entity, tag: tag);
              if (detected != null) results.add(detected);
            }
          }
        } catch (_) {
          // 目录遍历失败，跳过
        }
      } else {
        // 文件名无通配符，直接拼接完整路径
        final fullPath = path.join(dir, namePart);
        final entity = _getFileSystemEntity(fullPath);
        if (entity != null) {
          final detected = _entityToDetected(entity, tag: tag);
          if (detected != null) results.add(detected);
        }
      }
    }

    return results;
  }

  /// 展开目录路径中的通配符
  ///
  /// 逐级处理路径中的 `*` 通配符，返回所有匹配的目录路径
  List<String> _expandDirGlob(String dirPath) {
    if (!_containsGlob(dirPath)) return [dirPath];

    final parts = path.split(dirPath);
    List<String> currentPaths = [parts.first];

    // 逐级展开通配符
    for (int i = 1; i < parts.length; i++) {
      final part = parts[i];
      final nextPaths = <String>[];

      if (_containsGlob(part)) {
        final globRegex = _globToRegex(part);
        for (final current in currentPaths) {
          final dir = Directory(current);
          if (!dir.existsSync()) continue;
          try {
            for (final entity in dir.listSync()) {
              if (entity is Directory) {
                final baseName = path.basename(entity.path);
                if (globRegex.hasMatch(baseName)) {
                  nextPaths.add(entity.path);
                }
              }
            }
          } catch (_) {
            // 权限不足等异常，跳过
          }
        }
      } else {
        for (final current in currentPaths) {
          nextPaths.add(path.join(current, part));
        }
      }

      currentPaths = nextPaths;
      if (currentPaths.isEmpty) break;
    }

    return currentPaths;
  }

  /// 将 glob 模式转换为正则表达式
  ///
  /// 支持 `*`（匹配非路径分隔符的任意字符）和 `?`（匹配单个字符）
  static RegExp _globToRegex(String pattern) {
    final buffer = StringBuffer('^');
    for (int i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      switch (ch) {
        case '*':
          buffer.write('[^\\\\/]*');
          break;
        case '?':
          buffer.write('[^\\\\/]');
          break;
        case '.':
          buffer.write('\\.');
          break;
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '+':
        case '^':
        case '\$':
        case '|':
        case '\\':
          buffer.write('\\');
          buffer.write(ch);
          break;
        default:
          buffer.write(ch);
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: false);
  }

  /// 获取文件系统实体（文件或目录），不存在则返回 null
  static FileSystemEntity? _getFileSystemEntity(String p) {
    if (Directory(p).existsSync()) return Directory(p);
    if (File(p).existsSync()) return File(p);
    return null;
  }

  /// 将文件系统实体转换为 DetectedSaveFile
  static DetectedSaveFile? _entityToDetected(FileSystemEntity entity,
      {required String tag}) {
    try {
      final stat = entity.statSync();
      final isDir = entity is Directory;

      // 目录大小时递归计算
      int size = stat.size;
      if (isDir) {
        size = _calcDirectorySize(entity);
      }

      return DetectedSaveFile(
        filePath: entity.path,
        size: size,
        lastModified: stat.modified,
        isDirectory: isDir,
        tag: tag,
      );
    } catch (_) {
      return null;
    }
  }

  /// 递归计算目录大小
  static int _calcDirectorySize(Directory dir) {
    int totalSize = 0;
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          try {
            totalSize += entity.lengthSync();
          } catch (_) {
            // 文件无法访问，跳过
          }
        }
      }
    } catch (_) {
      // 目录遍历失败，返回已统计的大小
    }
    return totalSize;
  }
}
