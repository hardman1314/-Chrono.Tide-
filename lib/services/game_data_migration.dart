import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'game_data_format.dart';
import '../core/path_helper.dart';

class GameDataMigration {
  static const String _migratedFlag = '.ct_migrated';

  static Future<int> migrateAll() async {
    debugPrint('[MIGRATION] ========== 开始数据格式迁移 ==========');

    final gamesDir = Directory(PathHelper.gamesDir);
    if (!await gamesDir.exists()) {
      debugPrint('[MIGRATION] Games目录不存在，无需迁移');
      return 0;
    }

    int migratedCount = 0;
    int skippedCount = 0;
    int failedCount = 0;

    try {
      final entities = await gamesDir.list(followLinks: false).toList();

      for (final entity in entities) {
        if (entity is! Directory) continue;

        final dirName = entity.path.split('/').last.split('\\').last;
        if (dirName.contains('_temp_layer_') || dirName.startsWith('.')) {
          continue;
        }

        final hasCtgame =
            await File('${entity.path}/${GameDataFormat.ctgameFileName}')
                .exists();
        final hasGameJson =
            await File('${entity.path}/${GameDataFormat.gameJsonFileName}')
                .exists();

        if (hasCtgame && hasGameJson) {
          skippedCount++;
          continue;
        }

        final oldInfoFile = File('${entity.path}/game_info.json');
        if (!await oldInfoFile.exists()) {
          continue;
        }

        try {
          final migrated = await _migrateSingleDir(entity.path);
          if (migrated) {
            migratedCount++;
            debugPrint('[MIGRATION] ✅ 迁移成功: $dirName');
          }
        } catch (e) {
          failedCount++;
          debugPrint('[MIGRATION] ❌ 迁移失败: $dirName | $e');
        }
      }
    } catch (e) {
      debugPrint('[MIGRATION] ❌ 迁移过程异常: $e');
    }

    debugPrint('[MIGRATION] ========== 迁移完成 ==========');
    debugPrint(
        '[MIGRATION] 迁移: $migratedCount | 跳过(已是新格式): $skippedCount | 失败: $failedCount');

    return migratedCount;
  }

  static Future<bool> _migrateSingleDir(String dirPath) async {
    final oldInfoFile = File('$dirPath/game_info.json');
    if (!await oldInfoFile.exists()) return false;

    final content = await oldInfoFile.readAsString();
    Map<String, dynamic> oldData;
    try {
      oldData = jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MIGRATION] ⚠️ JSON解析失败: $dirPath');
      return false;
    }

    final title =
        oldData['title'] as String? ?? dirPath.split('/').last.split('\\').last;
    final description = oldData['description'] as String? ?? '';
    final tags =
        (oldData['tags'] as List?)?.map((t) => t.toString()).toList() ?? [];
    final installedAt = oldData['installedAt'] as String? ?? '';
    final directoryPath = oldData['directoryPath'] as String? ?? dirPath;

    String launchPath = oldData['launchPath'] as String? ?? '';
    if (launchPath.isEmpty) {
      launchPath = oldData['launcherPath'] as String? ?? '';
    }

    if (launchPath.isNotEmpty) {
      launchPath = _convertToRelative(launchPath, dirPath);
    }

    String source = 'download';
    final oldSource = oldData['source'] as String?;
    if (oldSource == 'local_path' || oldSource == 'archive_extract') {
      source = 'local_import';
    }

    String? coverFilePath;
    final coverUrl = oldData['coverUrl'] as String? ?? '';

    if (coverUrl.startsWith('data:')) {
      coverFilePath = await _extractDataUriToCoverFile(coverUrl, dirPath);
    } else if (coverUrl.startsWith('http')) {
      coverFilePath = null;
    }

    final localCoverFile = _findLocalCoverFile(dirPath);
    if (coverFilePath == null && localCoverFile != null) {
      coverFilePath = localCoverFile;
    }

    await GameDataFormat.writeGameDir(
      targetDir: dirPath,
      title: title,
      description: description,
      tags: tags,
      coverFilePath: coverFilePath,
      coverUrl: coverUrl.startsWith('http') ? coverUrl : null,
      launchPath: launchPath,
      directoryPath: directoryPath,
      source: source,
    );

    if (installedAt.isNotEmpty) {
      await GameDataFormat.updateGameJson(
          dirPath, {'installed_at': installedAt});
    }

    try {
      final backupFile = File('$dirPath/game_info.json.bak');
      await oldInfoFile.rename(backupFile.path);
      debugPrint('[MIGRATION]   game_info.json → game_info.json.bak');
    } catch (e) {
      debugPrint('[MIGRATION]   ⚠️ 备份旧文件失败: $e');
    }

    return true;
  }

  static String _convertToRelative(String path, String baseDir) {
    if (path.isEmpty) return '';
    var normalized = path.replaceAll('/', '\\');
    var normalizedBase = baseDir.replaceAll('/', '\\');
    if (!normalizedBase.endsWith('\\')) {
      normalizedBase += '\\';
    }
    if (normalized.toLowerCase().startsWith(normalizedBase.toLowerCase())) {
      return normalized.substring(normalizedBase.length);
    }
    if (!normalized.contains('\\') && !normalized.contains('/')) {
      return normalized;
    }
    return path;
  }

  static Future<String?> _extractDataUriToCoverFile(
      String dataUri, String dirPath) async {
    try {
      final commaIndex = dataUri.indexOf(',');
      if (commaIndex == -1) return null;

      final header = dataUri.substring(0, commaIndex);
      final encodedData = dataUri.substring(commaIndex + 1);

      String ext = 'jpg';
      if (header.contains('image/png')) {
        ext = 'png';
      } else if (header.contains('image/gif')) {
        ext = 'gif';
      } else if (header.contains('image/webp')) {
        ext = 'webp';
      }

      List<int> bytes;
      if (header.contains('base64')) {
        try {
          bytes = base64Decode(encodedData);
        } catch (_) {
          final hexStr = encodedData.replaceAll(RegExp(r'\s'), '');
          if (hexStr.length % 2 != 0) return null;
          bytes = [];
          for (int i = 0; i < hexStr.length; i += 2) {
            final byteStr = hexStr.substring(i, i + 2);
            final byteVal = int.tryParse(byteStr, radix: 16);
            if (byteVal != null) {
              bytes.add(byteVal);
            }
          }
        }
      } else {
        final hexStr = encodedData.replaceAll(RegExp(r'\s'), '');
        if (hexStr.length % 2 != 0) return null;
        bytes = [];
        for (int i = 0; i < hexStr.length; i += 2) {
          final byteStr = hexStr.substring(i, i + 2);
          final byteVal = int.tryParse(byteStr, radix: 16);
          if (byteVal != null) {
            bytes.add(byteVal);
          }
        }
      }

      if (bytes.isEmpty) return null;

      final coverFileName = 'cover.$ext';
      final coverFile = File('$dirPath/$coverFileName');
      await coverFile.writeAsBytes(bytes);
      debugPrint(
          '[MIGRATION]   封面已从data URI提取: $coverFileName (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
      return coverFile.path;
    } catch (e) {
      debugPrint('[MIGRATION]   ⚠️ 提取data URI封面失败: $e');
      return null;
    }
  }

  static String? _findLocalCoverFile(String dirPath) {
    final candidates = [
      '$dirPath/local_cover.jpg',
      '$dirPath/local_cover.png',
      '$dirPath/cover.jpg',
      '$dirPath/cover.png',
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        return candidate;
      }
    }
    return null;
  }
}
