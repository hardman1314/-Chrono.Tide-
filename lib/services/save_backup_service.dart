import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';

/// 存档备份数据类
class SaveBackup {
  /// 唯一标识（自动生成的UUID）
  final String id;

  /// 用户可见名称，默认为时间戳
  final String name;

  /// 备份创建时间
  final DateTime timestamp;

  /// 是否为自动备份
  final bool isAutoBackup;

  /// 备份相对路径 -> 原始绝对路径 的映射
  final Map<String, String> originalPaths;

  /// 备份文件数量
  final int fileCount;

  /// 备份总大小（字节）
  final int totalSize;

  const SaveBackup({
    required this.id,
    required this.name,
    required this.timestamp,
    required this.isAutoBackup,
    required this.originalPaths,
    required this.fileCount,
    required this.totalSize,
  });

  /// 从 backup.json 的 Map 反序列化
  factory SaveBackup.fromJson(Map<String, dynamic> json) {
    final filesRaw = json['files'] as Map<String, dynamic>? ?? {};
    final originalPaths = filesRaw.map((k, v) => MapEntry(k, v.toString()));

    return SaveBackup(
      id: json['id'] as String? ?? '',
      name: json['display_name'] as String? ?? json['name'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      isAutoBackup: json['is_auto_backup'] as bool? ?? false,
      originalPaths: originalPaths,
      fileCount: json['file_count'] as int? ?? 0,
      totalSize: json['total_size'] as int? ?? 0,
    );
  }

  /// 序列化为 backup.json 格式的 Map
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'display_name': name,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'is_auto_backup': isAutoBackup,
        'file_count': fileCount,
        'total_size': totalSize,
        'files': originalPaths,
      };
}

/// 存档备份与恢复服务（单例）
class SaveBackupService {
  SaveBackupService._();
  static final SaveBackupService instance = SaveBackupService._();

  static const String _metadataFileName = 'backup.json';
  static const Duration _autoBackupThreshold = Duration(minutes: 15);

  // ========== 路径工具 ==========

  /// 获取指定游戏的存档备份目录
  /// 返回: Games/{sanitizedGameName}/saves/
  String getSavesDir(String gameName) {
    final safeName = _sanitizeGameName(gameName);
    return p.join(PathHelper.gamesDir, safeName, 'saves');
  }

  // ========== 备份操作 ==========

  /// 创建存档备份
  ///
  /// [gameName] - 游戏名称
  /// [savePaths] - 需要备份的存档文件/目录的绝对路径列表
  /// [customName] - 自定义备份名称（如不提供则使用时间戳）
  /// [isAuto] - 是否为自动备份
  ///
  /// 返回创建的 SaveBackup 对象
  Future<SaveBackup> backupSaves(
    String gameName,
    List<String> savePaths, {
    String? customName,
    bool isAuto = false,
  }) async {
    final now = DateTime.now();
    final timestampName = _formatTimestamp(now);
    final backupFolderName = customName?.trim().isNotEmpty == true
        ? customName!.trim()
        : timestampName;
    final backupId = _generateUuid();

    // 创建备份目录
    final savesDir = getSavesDir(gameName);
    final backupDir = p.join(savesDir, backupFolderName);
    await Directory(backupDir).create(recursive: true);

    debugPrint('[SaveBackup] 开始备份 | 游戏: $gameName | 名称: $backupFolderName');

    // 收集所有需要备份的文件
    final filesToBackup = <String, String>{}; // 相对路径 -> 原始绝对路径
    int totalSize = 0;

    for (final savePath in savePaths) {
      final entity = FileSystemEntity.typeSync(savePath);
      if (entity == FileSystemEntityType.file) {
        final file = File(savePath);
        if (!file.existsSync()) {
          debugPrint('[SaveBackup] ⚠️ 文件不存在，跳过: $savePath');
          continue;
        }
        final relativePath = p.basename(savePath);
        final destPath = p.join(backupDir, relativePath);
        await _copyFileWithDirs(file, destPath);
        filesToBackup[relativePath] = savePath;
        totalSize += await file.length();
      } else if (entity == FileSystemEntityType.directory) {
        final dir = Directory(savePath);
        if (!dir.existsSync()) {
          debugPrint('[SaveBackup] ⚠️ 目录不存在，跳过: $savePath');
          continue;
        }
        // 遍历目录下所有文件，保留相对结构
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final relativeInside =
                p.relative(entity.path, from: savePath); // 相对于savePath的路径
            final relativePath =
                p.join(p.basename(savePath), relativeInside); // 保留目录名前缀
            final destPath = p.join(backupDir, relativePath);
            await _copyFileWithDirs(entity, destPath);
            filesToBackup[relativePath] = entity.path;
            totalSize += await entity.length();
          }
        }
      } else {
        debugPrint('[SaveBackup] ⚠️ 路径不存在，跳过: $savePath');
      }
    }

    // 构建 backup 元数据
    final backup = SaveBackup(
      id: backupId,
      name: backupFolderName,
      timestamp: now,
      isAutoBackup: isAuto,
      originalPaths: filesToBackup,
      fileCount: filesToBackup.length,
      totalSize: totalSize,
    );

    // 写入 backup.json
    final metadataPath = p.join(backupDir, _metadataFileName);
    final jsonContent =
        const JsonEncoder.withIndent('  ').convert(backup.toJson());
    await File(metadataPath).writeAsString(jsonContent, flush: true);

    debugPrint(
        '[SaveBackup] ✅ 备份完成 | 文件数: ${filesToBackup.length} | 总大小: ${_formatSize(totalSize)}');

    return backup;
  }

  /// 从备份恢复存档
  ///
  /// [gameName] - 游戏名称
  /// [backupId] - 备份ID
  /// [specificFiles] - 指定恢复的文件相对路径列表，为null时恢复全部
  Future<void> restoreSave(
    String gameName,
    String backupId,
    List<String>? specificFiles,
  ) async {
    final backup = await _findBackupById(gameName, backupId);
    if (backup == null) {
      throw StateError('未找到备份: $backupId');
    }

    final savesDir = getSavesDir(gameName);
    final backupDir = p.join(savesDir, backup.name);

    debugPrint('[SaveBackup] 开始恢复 | 游戏: $gameName | 备份: ${backup.name}');

    // 确定要恢复的文件
    final filesToRestore = specificFiles != null
        ? Map.fromEntries(backup.originalPaths.entries
            .where((e) => specificFiles.contains(e.key)))
        : backup.originalPaths;

    if (filesToRestore.isEmpty) {
      debugPrint('[SaveBackup] ⚠️ 没有需要恢复的文件');
      return;
    }

    int restoredCount = 0;
    for (final entry in filesToRestore.entries) {
      final relativePath = entry.key;
      final originalAbsPath = entry.value;

      final srcPath = p.join(backupDir, relativePath);
      final srcFile = File(srcPath);

      if (!srcFile.existsSync()) {
        debugPrint('[SaveBackup] ⚠️ 备份文件缺失，跳过: $relativePath');
        continue;
      }

      // 恢复到原始路径（覆盖已有文件）
      await _copyFileWithDirs(srcFile, originalAbsPath);
      restoredCount++;
    }

    debugPrint(
        '[SaveBackup] ✅ 恢复完成 | 已恢复: $restoredCount/${filesToRestore.length} 个文件');
  }

  /// 列出指定游戏的所有备份
  Future<List<SaveBackup>> listBackups(String gameName) async {
    final savesDir = getSavesDir(gameName);
    final savesDirectory = Directory(savesDir);

    if (!savesDirectory.existsSync()) {
      return [];
    }

    final backups = <SaveBackup>[];

    await for (final entity in savesDirectory.list()) {
      if (entity is! Directory) continue;

      final metadataPath = p.join(entity.path, _metadataFileName);
      final metadataFile = File(metadataPath);
      if (!metadataFile.existsSync()) continue;

      try {
        final content = await metadataFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        backups.add(SaveBackup.fromJson(json));
      } catch (e) {
        debugPrint('[SaveBackup] ⚠️ 解析备份元数据失败: ${entity.path} | $e');
      }
    }

    // 按时间倒序排列（最新的在前）
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  /// 删除指定备份
  Future<void> deleteBackup(String gameName, String backupId) async {
    final backup = await _findBackupById(gameName, backupId);
    if (backup == null) {
      throw StateError('未找到备份: $backupId');
    }

    final savesDir = getSavesDir(gameName);
    final backupDir = p.join(savesDir, backup.name);
    final dir = Directory(backupDir);

    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      debugPrint('[SaveBackup] ✅ 已删除备份: ${backup.name}');
    }
  }

  /// 重命名备份（修改显示名称）
  Future<void> renameBackup(
    String gameName,
    String backupId,
    String newName,
  ) async {
    final backup = await _findBackupById(gameName, backupId);
    if (backup == null) {
      throw StateError('未找到备份: $backupId');
    }

    final savesDir = getSavesDir(gameName);
    final oldDir = p.join(savesDir, backup.name);
    final newDir = p.join(savesDir, newName.trim());

    // 重命名文件夹
    final oldDirectory = Directory(oldDir);
    if (oldDirectory.existsSync()) {
      await oldDirectory.rename(newDir);
    }

    // 更新 backup.json 中的名称
    final metadataPath = p.join(newDir, _metadataFileName);
    final metadataFile = File(metadataPath);
    if (metadataFile.existsSync()) {
      try {
        final content = await metadataFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        json['name'] = newName.trim();
        json['display_name'] = newName.trim();
        final updatedContent = const JsonEncoder.withIndent('  ').convert(json);
        await metadataFile.writeAsString(updatedContent, flush: true);
      } catch (e) {
        debugPrint('[SaveBackup] ⚠️ 更新备份元数据失败: $e');
      }
    }

    debugPrint('[SaveBackup] ✅ 已重命名备份: ${backup.name} -> $newName');
  }

  /// 获取备份详情（完整文件列表）
  Future<SaveBackup?> getBackupDetails(String gameName, String backupId) async {
    return _findBackupById(gameName, backupId);
  }

  // ========== 自动备份逻辑 ==========

  /// 判断是否应该自动备份
  /// 游戏时长 >= 15 分钟时返回 true
  bool shouldAutoBackup(String gameName, Duration playDuration) {
    return playDuration >= _autoBackupThreshold;
  }

  /// 执行自动备份
  Future<SaveBackup> autoBackup(
    String gameName,
    List<String> savePaths,
  ) async {
    debugPrint('[SaveBackup] 🔄 执行自动备份 | 游戏: $gameName');
    return backupSaves(gameName, savePaths, isAuto: true);
  }

  // ========== 私有工具方法 ==========

  /// 清理游戏名称中的非法文件名字符
  String _sanitizeGameName(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return safe.isEmpty ? 'UnknownGame' : safe;
  }

  /// 格式化时间戳为文件夹名格式: 2024-01-15_14-30-25
  String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-${day}_$hour-$minute-$second';
  }

  /// 生成简单UUID（无外部依赖）
  String _generateUuid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = StringBuffer();
    for (int i = 0; i < 8; i++) {
      random.write((now + i * 2654435761)
          .toRadixString(16)
          .padLeft(4, '0')
          .substring(0, 4));
    }
    final hex = random.toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// 复制文件，自动创建目标目录
  Future<void> _copyFileWithDirs(File source, String destPath) async {
    final destFile = File(destPath);
    final destDir = destFile.parent;
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }
    await source.copy(destPath);
  }

  /// 根据备份ID查找备份对象
  Future<SaveBackup?> _findBackupById(String gameName, String backupId) async {
    final backups = await listBackups(gameName);
    try {
      return backups.firstWhere((b) => b.id == backupId);
    } catch (_) {
      return null;
    }
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}
