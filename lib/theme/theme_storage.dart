import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../core/path_helper.dart';
import 'app_theme_manager.dart';
import 'background_image_config.dart';

/// v3.0 P0：主题存储层
///
/// 负责：
/// - 用户主题 JSON 文件的持久化（save / load / delete / rename）
/// - 用户上传背景图文件存储（upload / delete / getAbsolutePath）
/// - SharedPreferences 中激活主题 id 的读写
///
/// 文件布局：
/// - ${appSupportDir}/user_themes/{themeId}.json
/// - ${appSupportDir}/user_backgrounds/{bgUuid}.{ext}  (主图)
///
/// v3.0.1 修复：移除了原 _generateThumbnail 死代码（生成的 _thumb.png
/// 全应用无任何 UI 使用，仅浪费磁盘空间）。如需缩略图应在显示侧用
/// ResizeImage 懒加载。
///
/// 不在 P0 范围：
/// - `.cttheme` ZIP 打包/解包（P5）
/// - 主题列表 UI（P4）
class ThemeStorage {
  ThemeStorage._();

  static const _kPrefActiveThemeId = 'app_theme';
  static const _kPrefSchemaVersion = 'theme_schema_version';
  static const _kThemesSubdir = 'user_themes';
  static const _kBackgroundsSubdir = 'user_backgrounds';

  static final _uuid = const Uuid();

  // ============ 目录路径 ============

  static Future<Directory> _themesDir() async {
    // 优先便携目录（安装目录内），避免占用系统 C 盘
    if (await PathHelper.isPortableWritable()) {
      final dir = Directory(PathHelper.userThemesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    // 降级：原系统目录（安装目录只读时，行为同改造前）
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}\\$_kThemesSubdir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<Directory> _backgroundsDir() async {
    if (await PathHelper.isPortableWritable()) {
      final dir = Directory(PathHelper.userBackgroundsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}\\$_kBackgroundsSubdir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// v3.0 P5：公开 backgrounds 目录（供 CtThemePackage 导入时写入背景图）
  static Future<Directory> backgroundsDirectory() => _backgroundsDir();

  /// 生成新的主题 UUID
  static String newThemeId() => _uuid.v4();

  /// 生成新的背景图 UUID
  static String newBackgroundId() => _uuid.v4();

  // ============ 激活主题 id 读写（SharedPreferences） ============

  /// 读取激活主题 id
  /// 兼容老版本：值可能是 CTTheme 枚举 name（warmSun/darkNight/...）
  static Future<String?> loadActiveThemeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPrefActiveThemeId);
  }

  /// 保存激活主题 id
  static Future<void> saveActiveThemeId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefActiveThemeId, id);
  }

  /// 读取 schema 版本
  static Future<int> loadSchemaVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kPrefSchemaVersion) ?? 0;
  }

  /// 保存 schema 版本
  static Future<void> saveSchemaVersion(int version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefSchemaVersion, version);
  }

  // ============ 用户主题 JSON 持久化 ============

  /// 保存用户主题到 JSON 文件（事务性写入：先 .tmp 再 rename）
  static Future<void> saveUserTheme(CTThemeData theme) async {
    if (theme.source != CTThemeSource.user) {
      throw ArgumentError('仅可保存用户主题, 内置主题不可写入');
    }
    final dir = await _themesDir();
    final targetPath = '${dir.path}\\${theme.id}.json';
    final tmpPath = '$targetPath.tmp';

    final jsonStr = const JsonEncoder.withIndent('  ').convert(theme.toJson());
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(jsonStr, flush: true);

    final targetFile = File(targetPath);
    if (targetFile.existsSync()) {
      await targetFile.delete();
    }
    await tmpFile.rename(targetPath);
  }

  /// 加载所有用户主题
  /// 在 isolate 中执行 JSON 解析以避免阻塞主线程
  ///
  /// v3.0.1 修复：原外层 try-catch 会捕获 listSync 抛错并静默返回空列表，
  /// 用户主题"消失"且无任何提示。本版本区分两种错误场景：
  /// - 目录不可访问：返回空列表 + debugPrint（应用仍可启动）
  /// - 单个文件解析失败：跳过该文件，加载其余主题（在 _parseThemeFiles 内处理）
  static Future<List<CTThemeData>> loadAllUserThemes() async {
    final Directory dir;
    try {
      dir = await _themesDir();
    } catch (e) {
      debugPrint('[ThemeStorage] user_themes 目录不可访问: $e');
      return [];
    }

    if (!dir.existsSync()) return [];

    final List<File> files;
    try {
      files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') && !f.path.endsWith('.tmp'))
          .toList();
    } catch (e) {
      debugPrint('[ThemeStorage] 列举 user_themes 失败: $e');
      return [];
    }

    if (files.isEmpty) return [];

    try {
      // 将文件路径列表传给 isolate
      final paths = files.map((f) => f.path).toList();
      final results = await compute(_parseThemeFiles, paths);
      final valid = results.whereType<CTThemeData>().toList();
      if (valid.length < paths.length) {
        debugPrint(
            '[ThemeStorage] ${paths.length - valid.length} 个用户主题解析失败（已跳过）');
      }
      return valid;
    } catch (e) {
      debugPrint('[ThemeStorage] isolate 解析用户主题失败: $e');
      return [];
    }
  }

  /// 删除用户主题 JSON 文件
  static Future<void> deleteUserTheme(String themeId) async {
    final dir = await _themesDir();
    final file = File('${dir.path}\\$themeId.json');
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// v3.0 P4：删除用户主题（含 JSON + 关联背景图文件）
  /// [theme] 完整主题数据（用于读取其背景图 filename）
  static Future<void> deleteUserThemeWithBackground(CTThemeData theme) async {
    await deleteUserTheme(theme.id);
    // 若主题绑定了用户上传背景图（file 来源），一并删除
    if (theme.backgroundImage.source == BackgroundImageSource.file &&
        theme.backgroundImage.filename != null) {
      await deleteBackgroundImage(theme.backgroundImage.filename);
    }
  }

  /// v3.0 P4：复制用户主题（生成新 UUID + "(副本)" 后缀）
  /// 返回新的 CTThemeData（未持久化，调用方需 saveUserTheme）
  static CTThemeData duplicateUserTheme(CTThemeData source) {
    final newId = newThemeId();
    return source.asUserThemeCopy(
      newId: newId,
      name: '${source.name}（副本）',
      description: source.description,
    );
  }

  /// v3.0 P4：持久化复制用户主题（duplicate + save + register）
  /// 返回新主题数据
  static Future<CTThemeData> duplicateAndSave(CTThemeData source) async {
    final copy = duplicateUserTheme(source);
    await saveUserTheme(copy);
    return copy;
  }

  /// 检查用户主题是否存在
  static Future<bool> userThemeExists(String themeId) async {
    final dir = await _themesDir();
    final file = File('${dir.path}\\$themeId.json');
    return file.existsSync();
  }

  // isolate 顶层函数
  static List<CTThemeData?> _parseThemeFiles(List<String> paths) {
    return paths.map((path) {
      try {
        final file = File(path);
        final jsonStr = file.readAsStringSync();
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        return CTThemeData.fromJson(json);
      } catch (e) {
        debugPrint('[ThemeStorage] 解析主题文件失败 $path: $e');
        return null;
      }
    }).toList();
  }

  // ============ 用户背景图文件存储 ============

  /// 上传背景图：复制源文件到 user_backgrounds 目录
  /// 返回 BackgroundImageConfig（source=file, filename=bgUuid.ext）
  ///
  /// 文件大小限制：10 MB
  /// 支持格式：jpg/jpeg/png/gif
  static Future<BackgroundImageConfig> uploadBackgroundImage(
    String sourcePath, {
    double overlayOpacity = 0.30,
    double blurSigma = 0.0,
  }) async {
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      throw FileSystemException('源文件不存在', sourcePath);
    }

    final stat = await sourceFile.length();
    const maxSize = 10 * 1024 * 1024; // 10 MB
    if (stat > maxSize) {
      throw ArgumentError('背景图大小不可超过 10MB, 当前: ${stat ~/ 1024}KB');
    }

    final ext = _extractExtension(sourcePath);
    _validateImageExtension(ext);

    final bgUuid = newBackgroundId();
    final filename = '$bgUuid.$ext';

    final dir = await _backgroundsDir();
    final targetFile = File('${dir.path}\\$filename');
    await sourceFile.copy(targetFile.path);

    // v3.0.1 修复：移除原 _generateThumbnail 调用。
    // 原实现仅复制原文件作为"缩略图"，但全应用无任何 UI 读取 _thumb.png 文件，
    // 属于死代码且造成磁盘空间浪费（每张背景图实际存两份相同大文件）。
    // 如未来 UI 需要缩略图，应直接在显示侧用 ResizeImage(cached) 懒加载，
    // 而非在存储时预先生成。详见 P6 性能优化文档。

    return BackgroundImageConfig(
      source: BackgroundImageSource.file,
      filename: filename,
      overlayOpacity: overlayOpacity,
      blurSigma: blurSigma,
    );
  }

  /// 获取背景图绝对路径
  static Future<String?> getBackgroundPath(String? filename) async {
    if (filename == null || filename.isEmpty) return null;
    final dir = await _backgroundsDir();
    final file = File('${dir.path}\\$filename');
    return file.existsSync() ? file.path : null;
  }

  /// 删除背景图文件
  ///
  /// v3.0.1 修复：移除原"删除缩略图"逻辑（_generateThumbnail 已被删除，
  /// 不再有 _thumb.png 文件需要清理）。保留方法签名向后兼容。
  static Future<void> deleteBackgroundImage(String? filename) async {
    if (filename == null || filename.isEmpty) return;
    final dir = await _backgroundsDir();
    final file = File('${dir.path}\\$filename');
    if (file.existsSync()) await file.delete();

    // 兼容旧版本：清理可能存在的旧 _thumb.png 文件（升级前生成的）
    final bgUuid = filename.split('.').first;
    final legacyThumb = File('${dir.path}\\${bgUuid}_thumb.png');
    if (legacyThumb.existsSync()) {
      try {
        await legacyThumb.delete();
      } catch (e) {
        debugPrint('[ThemeStorage] 清理旧缩略图失败(忽略): $e');
      }
    }
  }

  /// 检查背景图文件是否存在
  static Future<bool> backgroundExists(String? filename) async {
    if (filename == null || filename.isEmpty) return false;
    final dir = await _backgroundsDir();
    return File('${dir.path}\\$filename').existsSync();
  }

  /// v3.0.1 安全修复：从路径/文件名提取扩展名
  ///
  /// 与 P0 实现的差异：
  /// - 使用 [p.basename] 截取纯文件名，剥离任何路径分隔符（防止路径遍历）
  /// - 严格校验扩展名仅含字母数字（防止 `..`、`/`、`\\` 等被注入到目标路径）
  /// - 公开为静态方法，供 [CtThemePackage] 导入未信任 ZIP 时复用
  ///
  /// [pathOrFilename] 可为完整路径或纯文件名（来自用户上传或 ZIP 内 JSON）
  /// 返回小写扩展名（无点）。无合法扩展名时返回 'png' 作为默认值。
  static String extractExtensionSafe(String pathOrFilename) {
    // 1. 截取 basename，剥离路径分隔符（路径遍历防护）
    final basename = p.basename(pathOrFilename);
    final dot = basename.lastIndexOf('.');
    if (dot < 0 || dot == basename.length - 1) return 'png';
    final ext = basename.substring(dot + 1).toLowerCase();
    // 2. 严格校验：仅允许 1~5 位字母数字（jpg/jpeg/png/gif/webp 等）
    if (!RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) return 'png';
    return ext;
  }

  /// v3.0.1 安全修复：扩展名白名单校验（用于导入流程，限制可写入磁盘的格式）
  static void validateImageExtension(String ext) {
    const allowed = ['jpg', 'jpeg', 'png', 'gif'];
    if (!allowed.contains(ext)) {
      throw ArgumentError('不支持的图片格式: $ext (仅支持 jpg/jpeg/png/gif)');
    }
  }

  static String _extractExtension(String path) => extractExtensionSafe(path);

  static void _validateImageExtension(String ext) =>
      validateImageExtension(ext);

  // ============ 背景图文件读取辅助 ============

  /// 同步读取背景图文件字节（用于 isolate 中加载）
  static Future<Uint8List?> readBackgroundBytes(String? filename) async {
    final path = await getBackgroundPath(filename);
    if (path == null) return null;
    try {
      return File(path).readAsBytes();
    } catch (e) {
      debugPrint('[ThemeStorage] 读取背景图失败: $e');
      return null;
    }
  }
}
