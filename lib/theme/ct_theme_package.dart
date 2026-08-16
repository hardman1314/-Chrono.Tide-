import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'app_theme_manager.dart';
import 'background_image_config.dart';
import 'theme_storage.dart';

// v3.0.1 安全修复：path 包用于 basename() 剥离路径分隔符（防路径遍历）

/// v3.0 P5：.cttheme 主题包打包/解包
///
/// `.cttheme` 文件格式 = ZIP 压缩包：
/// - `theme.json`（CTThemeData.toJson，schemaVersion 1）
/// - `backgrounds/{filename}`（用户上传背景图，仅 file 来源时包含）
/// - `thumbnail.png`（主题卡片缩略图，可选，本期不生成）
///
/// **导出**：打包为 ZIP，扩展名 `.cttheme`
/// **导入**：解压 + schema 校验 + 生成新 UUID + 命名加"(导入)" + 复制背景图 + 写 JSON
///
/// 冲突策略（D 决策）：总是新 UUID 导入，命名加"(导入)"后缀，永不覆盖已有主题。
///
/// Schema 版本兼容：
/// - 导出时写入当前 schemaVersion
/// - 导入时校验：高于本版本拒绝；低于等于本版本尝试兼容（缺字段用 fromJson 默认值）
class CtThemePackage {
  CtThemePackage._();

  /// 当前支持的 schema 版本（与 CTThemeData.schemaVersion 一致）
  static const int kSupportedSchemaVersion = 1;

  /// ZIP 内 theme.json 的路径
  static const _kThemeJsonEntry = 'theme.json';

  /// ZIP 内背景图目录前缀
  static const _kBackgroundsPrefix = 'backgrounds/';

  /// v3.0.1 安全修复：.cttheme 文件大小上限（20 MB）
  ///
  /// 主题包本质是 theme.json + 一张背景图，正常体量 < 11 MB（10 MB 背景图上限）。
  /// 取 20 MB 留余量，超过此值视为异常（防止 ZIP 炸弹 / 拒绝服务）。
  static const int kMaxPackageSizeBytes = 20 * 1024 * 1024;

  /// v3.0.1 安全修复：单条 ZIP entry 大小上限（与 uploadBackgroundImage 一致）
  static const int kMaxEntrySizeBytes = 10 * 1024 * 1024;

  /// v3.0.1 安全修复：ZIP 内 entry 数量上限（防百万条目型 ZIP 炸弹）
  static const int kMaxEntryCount = 64;

  // ============ 导出 ============

  /// 导出主题为 .cttheme 文件
  ///
  /// [theme] 要导出的主题（通常为用户主题）
  /// [outputPath] 目标文件完整路径（应以 .cttheme 结尾）
  ///
  /// 若主题绑定 file 来源背景图，自动将其打包进 ZIP。
  static Future<void> exportToFile(
    CTThemeData theme,
    String outputPath,
  ) async {
    final archive = Archive();

    // 1. theme.json
    final themeJson = const JsonEncoder.withIndent('  ').convert(theme.toJson());
    final themeJsonBytes = utf8.encode(themeJson);
    archive.addFile(
        ArchiveFile(_kThemeJsonEntry, themeJsonBytes.length, themeJsonBytes));

    // 2. 背景图（仅 file 来源）
    if (theme.backgroundImage.source == BackgroundImageSource.file &&
        theme.backgroundImage.filename != null) {
      final bgPath =
          await ThemeStorage.getBackgroundPath(theme.backgroundImage.filename);
      if (bgPath != null) {
        final bytes = await File(bgPath).readAsBytes();
        final entryName =
            '$_kBackgroundsPrefix${theme.backgroundImage.filename}';
        archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
      }
    }

    // 3. 编码为 ZIP 并写入
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw StateError('ZIP 编码失败');
    }
    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(zipBytes, flush: true);
  }

  // ============ 导入 ============

  /// 从 .cttheme 文件导入主题
  ///
  /// 流程：
  /// 1. 文件大小校验（防 ZIP 炸弹）
  /// 2. 解压 ZIP，遍历校验每个 entry 的大小与数量
  /// 3. 读取 theme.json，校验 schemaVersion
  /// 4. 生成新 UUID + 命名加"(导入)"后缀
  /// 5. 若含背景图：扩展名白名单校验 → 复制到 user_backgrounds（新 bgUuid 文件名）
  /// 6. 持久化用户主题 JSON
  /// 7. 返回新 CTThemeData（未注册到 AppThemeManager，由调用方注册）
  ///
  /// v3.0.1 安全修复：原实现未校验包大小、未限制 entry 数量、未过滤扩展名，
  /// 存在路径遍历与 ZIP 炸弹风险。本版本统一加固：
  /// - 包大小 ≤ [kMaxPackageSizeBytes]
  /// - 单 entry ≤ [kMaxEntrySizeBytes]
  /// - entry 总数 ≤ [kMaxEntryCount]
  /// - 背景图扩展名必须命中 jpg/jpeg/png/gif 白名单
  /// - 文件名经 [ThemeStorage.extractExtensionSafe] 剥离路径分隔符
  static Future<CTThemeData> importFromFile(String inputPath) async {
    final file = File(inputPath);
    if (!file.existsSync()) {
      throw FileSystemException('主题包文件不存在', inputPath);
    }

    // 1. 文件大小校验（在解压前完成，防 ZIP 炸弹）
    final fileSize = await file.length();
    if (fileSize > kMaxPackageSizeBytes) {
      throw FormatException(
          '主题包过大: ${fileSize ~/ 1024 ~/ 1024} MB，上限 ${kMaxPackageSizeBytes ~/ 1024 ~/ 1024} MB');
    }

    // 2. 解压
    final zipBytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(zipBytes);

    // 3. entry 数量与单 entry 大小校验
    if (archive.length > kMaxEntryCount) {
      throw FormatException(
          '主题包内文件数过多: ${archive.length}，上限 $kMaxEntryCount');
    }
    for (final entry in archive) {
      if (entry.size > kMaxEntrySizeBytes) {
        throw FormatException(
            '主题包内文件 ${entry.name} 过大: ${entry.size ~/ 1024 ~/ 1024} MB');
      }
    }

    // 4. 读取 theme.json
    final themeJsonEntry = archive.findFile(_kThemeJsonEntry);
    if (themeJsonEntry == null) {
      throw FormatException('无效的主题包：缺少 theme.json');
    }
    final themeJsonStr = utf8.decode(themeJsonEntry.content as List<int>);
    final themeJson = jsonDecode(themeJsonStr) as Map<String, dynamic>;

    // 5. schema 版本校验
    final schemaVersion = (themeJson['schemaVersion'] as num?)?.toInt() ?? 0;
    if (schemaVersion > kSupportedSchemaVersion) {
      throw FormatException(
          '主题包 schema 版本 $schemaVersion 高于本应用支持的版本 $kSupportedSchemaVersion，请升级应用');
    }
    // 低于当前版本：依赖 CTThemeData.fromJson 的默认值兼容

    // 6. 解析为 CTThemeData
    final original = CTThemeData.fromJson(themeJson);

    // 7. 冲突策略：新 UUID + "(导入)"后缀
    final newId = ThemeStorage.newThemeId();
    var newName = original.name;
    if (!newName.endsWith('（导入）')) {
      newName = '$newName（导入）';
    }

    // 8. 处理背景图（若 ZIP 内含 backgrounds/ 文件）
    BackgroundImageConfig newBgConfig = original.backgroundImage;
    if (original.backgroundImage.source == BackgroundImageSource.file &&
        original.backgroundImage.filename != null) {
      // 8.1 截取纯文件名（防路径遍历：JSON 中的 filename 可能含 ../ 或绝对路径）
      final origFilename = p.basename(original.backgroundImage.filename!);
      final bgEntry = archive.findFile('$_kBackgroundsPrefix$origFilename');
      if (bgEntry != null) {
        // 8.2 扩展名白名单校验（防止写入非图片格式到 user_backgrounds）
        final ext = ThemeStorage.extractExtensionSafe(origFilename);
        ThemeStorage.validateImageExtension(ext);

        final newBgUuid = ThemeStorage.newBackgroundId();
        final newFilename = '$newBgUuid.$ext';
        final bgBytes = bgEntry.content as List<int>;

        // 8.3 二次校验：解压后字节数必须 ≤ 上限（防止解压炸弹）
        if (bgBytes.length > kMaxEntrySizeBytes) {
          throw FormatException('背景图解压后过大: ${bgBytes.length ~/ 1024 ~/ 1024} MB');
        }

        // 8.4 通过 ThemeStorage 的公开目录写入
        final dir = await ThemeStorage.backgroundsDirectory();
        final targetFile = File('${dir.path}\\$newFilename');
        await targetFile.writeAsBytes(bgBytes, flush: true);

        newBgConfig = BackgroundImageConfig(
          source: BackgroundImageSource.file,
          filename: newFilename,
          overlayOpacity: original.backgroundImage.overlayOpacity,
          blurSigma: original.backgroundImage.blurSigma,
          fit: original.backgroundImage.fit,
          alignment: original.backgroundImage.alignment,
          // v3.0 P7：同步复制 custom 模式字段（scale/offset），
          // 否则导入主题会丢失用户的背景图位置/缩放配置
          scale: original.backgroundImage.scale,
          offsetX: original.backgroundImage.offsetX,
          offsetY: original.backgroundImage.offsetY,
        );
      }
    }

    // 9. 构造新主题（新 UUID + source=user + 新名称 + 新背景图）
    final imported = original.asUserThemeCopy(
      newId: newId,
      name: newName,
      description: original.description,
    ).withBackgroundImage(newBgConfig);

    // 10. 持久化
    await ThemeStorage.saveUserTheme(imported);

    return imported;
  }

  /// 直接获取 backgrounds 目录（复用 ThemeStorage 逻辑，避免改其可见性）
  // 已移除：直接使用 ThemeStorage.backgroundsDirectory()
}
