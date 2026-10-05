import 'dart:convert' show JsonEncoder;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/path_helper.dart';
import 'migration_markers.dart';

/// 迁移单元状态。
enum MigrationStatus { success, skipped, failed }

class MigrationUnitResult {
  final String id;
  final MigrationStatus status;
  final String message;
  const MigrationUnitResult(this.id, this.status, this.message);

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status.name,
        'message': message,
        'time': DateTime.now().toIso8601String(),
      };
}

class MigrationResult {
  final List<MigrationUnitResult> units = [];
  void add(String id, MigrationStatus status, String message) =>
      units.add(MigrationUnitResult(id, status, message));

  Map<String, dynamic> toJson() => {
        'migratedAt': DateTime.now().toIso8601String(),
        'units': units.map((u) => u.toJson()).toList(),
      };
}

/// 便携化存储迁移编排器。
///
/// 将老用户在系统 C 盘的数据无感迁移到软件安装目录。
///
/// 时序（见 main.dart `_initializePortableStorage`）：
/// 1. [migratePrefsFile] —— Phase A，store 替换前调用，整文件复制旧 prefs → 新位置
/// 2. 替换 `SharedPreferencesStorePlatform.instance` 为 PortableSharedPreferencesStore
/// 3. [run] —— Phase B，迁移 game_configs / user_themes / user_backgrounds / image_cache
///
/// 设计原则：
/// - 幂等：每单元用 prefs 标志位防重复（直接读写文件，不经 SharedPreferences API）
/// - 复制非移动：先复制校验，通过后才删旧，校验失败保留旧数据
/// - 中断恢复：`.migrating` 标记 + 文件数校验，崩溃后下次启动重试
/// - 失败不阻断启动：每步 try-catch，失败仅记录日志
class MigrationOrchestrator {
  /// 图片缓存迁移阈值：旧缓存 ≥ 此值则跳过复制直接删旧（可重建，懒加载无感）。
  static const int _imageCacheSkipThreshold = 200 * 1024 * 1024; // 200 MB

  // ==================== Phase A：prefs 文件迁移 ====================

  /// 在 store 替换前调用：新 prefs 文件不存在且旧文件存在时，整文件复制。
  /// 新文件已存在则跳过（保证幂等、不覆盖已迁移/正在使用的数据）。
  static Future<void> migratePrefsFile() async {
    try {
      final newFile = File(PathHelper.prefsFilePath);
      if (newFile.existsSync()) return; // 已迁移或已存在
      final oldFile = await _legacyPrefsFile();
      if (oldFile == null || !oldFile.existsSync()) return; // 无旧数据
      if (!newFile.parent.existsSync()) {
        newFile.parent.createSync(recursive: true);
      }
      await oldFile.copy(newFile.path);
      debugPrint(
          '[MIGRATION] prefs 文件已迁移: ${oldFile.path} -> ${newFile.path}');
    } catch (e) {
      debugPrint('[MIGRATION] prefs 文件迁移失败(忽略，将以新位置空启动): $e');
    }
  }

  // ==================== Phase B：其余单元迁移 ====================

  /// 迁移其余存储单元。须在 store 替换后调用。
  /// [deleteOldAfterMigration] 为 true 时，校验通过后删除 C 盘旧数据。
  static Future<MigrationResult> run({
    bool deleteOldAfterMigration = true,
  }) async {
    final result = MigrationResult();
    final prefsFile = File(PathHelper.prefsFilePath);

    try {
      // game_configs
      await _migrateDirUnit(
        unitId: 'game_configs',
        oldDir: await _legacyGameConfigsDir(),
        newDir: Directory(PathHelper.gameConfigsDir),
        deleteOld: deleteOldAfterMigration,
        prefsFile: prefsFile,
        result: result,
      );

      // user_themes
      await _migrateDirUnit(
        unitId: 'user_themes',
        oldDir: await _legacyUserThemesDir(),
        newDir: Directory(PathHelper.userThemesDir),
        deleteOld: deleteOldAfterMigration,
        prefsFile: prefsFile,
        result: result,
      );

      // user_backgrounds
      await _migrateDirUnit(
        unitId: 'user_backgrounds',
        oldDir: await _legacyUserBackgroundsDir(),
        newDir: Directory(PathHelper.userBackgroundsDir),
        deleteOld: deleteOldAfterMigration,
        prefsFile: prefsFile,
        result: result,
      );

      // image_cache（特殊：dir + 元数据文件，可重建）
      await _migrateImageCacheUnit(
        prefsFile: prefsFile,
        deleteOld: deleteOldAfterMigration,
        result: result,
      );
    } catch (e, stack) {
      debugPrint('[MIGRATION] 迁移编排异常: $e\n$stack');
      result.add('orchestrator', MigrationStatus.failed, '$e');
    }

    await _writeMigrationLog(result);
    return result;
  }

  // ==================== 目录单元迁移 ====================

  static Future<void> _migrateDirUnit({
    required String unitId,
    required Directory? oldDir,
    required Directory newDir,
    required bool deleteOld,
    required File prefsFile,
    required MigrationResult result,
  }) async {
    try {
      if (MigrationMarkers.isFlagSet(prefsFile, unitId)) {
        result.add(unitId, MigrationStatus.skipped, '已迁移（标志命中）');
        return;
      }

      final oldExists = oldDir != null &&
          oldDir.existsSync() &&
          await _countFiles(oldDir) > 0;
      if (!oldExists) {
        await MigrationMarkers.injectFlag(prefsFile, unitId);
        result.add(unitId, MigrationStatus.skipped, '旧位置无数据');
        return;
      }

      final marker = File(p.join(newDir.path, '.migrating'));

      // 中断恢复：marker 残留 → 清空新位置重试
      if (marker.existsSync()) {
        await _clearDirectoryContents(newDir);
      } else if (newDir.existsSync() && await _countFiles(newDir) > 0) {
        // ★ P1-4d：新位置已有数据且无中断标记。
        // 旧实现无条件删旧目录并置标志——但新位置的数据可能来自无关来源
        // （手工拷贝配置、旧版残留、解压工具预生成），此时删旧 = 数据永久丢失。
        // 改为先比对文件数与总字节数，完全一致才认为"上次 copy 已完成"。
        // 大目录算总字节会变慢，但正确性优先于速度。
        final oldCount = await _countFiles(oldDir);
        final oldSize = await _dirSizeBytes(oldDir);
        final newCount = await _countFiles(newDir);
        final newSize = await _dirSizeBytes(newDir);

        if (oldCount == newCount && oldSize == newSize) {
          if (deleteOld) await _safeDeleteDir(oldDir);
          await MigrationMarkers.injectFlag(prefsFile, unitId);
          result.add(unitId, MigrationStatus.success, '新位置已有数据，补设标志');
        } else {
          // 内容不一致：保留旧目录 + 不置标志，交人工确认（下次启动仍会重试）
          debugPrint('[MIGRATION] ⚠️ $unitId 新位置已有数据但内容与旧位置不一致，'
              '保留旧目录待人工确认（旧: $oldCount 文件/${_fmtBytes(oldSize)}，'
              '新: $newCount 文件/${_fmtBytes(newSize)}）');
          result.add(
            unitId,
            MigrationStatus.failed,
            '新位置已有数据但内容不一致，已保留旧目录（旧: $oldCount 文件/${_fmtBytes(oldSize)}，新: $newCount 文件/${_fmtBytes(newSize)}）',
          );
        }
        return;
      }

      // 执行复制
      if (!newDir.existsSync()) newDir.createSync(recursive: true);
      marker.writeAsStringSync('migrating', flush: true);

      final oldCount = await _countFiles(oldDir);
      final oldSize = await _dirSizeBytes(oldDir);

      await _copyDirectory(oldDir, newDir);

      final newCount = await _countFiles(newDir);
      // 校验：文件数必须一致（复制是精确的）
      if (newCount != oldCount) {
        await _clearDirectoryContents(newDir);
        result.add(unitId, MigrationStatus.failed,
            '校验失败：文件数 $oldCount -> $newCount');
        return;
      }

      // 校验通过：删标记 → 删旧 → 设标志
      marker.deleteSync();
      if (deleteOld) await _safeDeleteDir(oldDir);
      await MigrationMarkers.injectFlag(prefsFile, unitId);
      result.add(unitId, MigrationStatus.success,
          '已迁移 $oldCount 文件 (${_fmtBytes(oldSize)})');
    } catch (e) {
      // 异常：保留 marker（下次清理重试），不删旧，不设标志
      result.add(unitId, MigrationStatus.failed, '$e');
    }
  }

  // ==================== 图片缓存单元迁移 ====================

  static Future<void> _migrateImageCacheUnit({
    required File prefsFile,
    required bool deleteOld,
    required MigrationResult result,
  }) async {
    const unitId = 'image_cache';
    try {
      if (MigrationMarkers.isFlagSet(prefsFile, unitId)) {
        result.add(unitId, MigrationStatus.skipped, '已迁移（标志命中）');
        return;
      }

      final oldFilesDir = await _legacyImageCacheFilesDir();
      final oldMetaFile = await _legacyImageCacheMetaFile();
      final oldFilesExist =
          oldFilesDir != null && oldFilesDir.existsSync() && await _countFiles(oldFilesDir) > 0;
      final oldMetaExist = oldMetaFile != null && oldMetaFile.existsSync();

      if (!oldFilesExist && !oldMetaExist) {
        await MigrationMarkers.injectFlag(prefsFile, unitId);
        result.add(unitId, MigrationStatus.skipped, '旧位置无数据');
        return;
      }

      final oldSize =
          oldFilesExist ? await _dirSizeBytes(oldFilesDir) : 0;

      // 超阈值：跳过复制，直接删旧（缓存可重建，懒加载无感）
      if (oldSize >= _imageCacheSkipThreshold) {
        if (deleteOld) {
          if (oldFilesExist) await _safeDeleteDir(oldFilesDir);
          if (oldMetaExist) await oldMetaFile.delete();
        }
        await MigrationMarkers.injectFlag(prefsFile, unitId);
        result.add(unitId, MigrationStatus.skipped,
            '旧缓存过大(${_fmtBytes(oldSize)})，已删除旧数据待重建');
        return;
      }

      // 正常复制：文件目录 + 元数据文件
      final newFilesDir = Directory(
          p.join(PathHelper.imageCacheDir, 'libCachedImageData'));
      final newMetaFile =
          File(p.join(PathHelper.imageCacheDir, 'libCachedImageData.json'));
      final marker = File(p.join(PathHelper.imageCacheDir, '.migrating'));

      if (marker.existsSync()) {
        if (newFilesDir.existsSync()) await _clearDirectoryContents(newFilesDir);
        if (newMetaFile.existsSync()) await newMetaFile.delete();
      }

      if (!newFilesDir.parent.existsSync()) {
        newFilesDir.parent.createSync(recursive: true);
      }
      marker.writeAsStringSync('migrating', flush: true);

      final oldCount = oldFilesExist ? await _countFiles(oldFilesDir) : 0;
      if (oldFilesExist) {
        if (!newFilesDir.existsSync()) newFilesDir.createSync(recursive: true);
        await _copyDirectory(oldFilesDir, newFilesDir);
      }
      if (oldMetaExist && !newMetaFile.existsSync()) {
        await oldMetaFile.copy(newMetaFile.path);
      }

      final newCount = await _countFiles(newFilesDir);
      if (oldFilesExist && newCount != oldCount) {
        if (newFilesDir.existsSync()) await _clearDirectoryContents(newFilesDir);
        if (newMetaFile.existsSync()) await newMetaFile.delete();
        marker.deleteSync();
        result.add(unitId, MigrationStatus.failed,
            '校验失败：文件数 $oldCount -> $newCount');
        return;
      }

      marker.deleteSync();
      if (deleteOld) {
        if (oldFilesExist) await _safeDeleteDir(oldFilesDir);
        if (oldMetaExist) await oldMetaFile.delete();
      }
      await MigrationMarkers.injectFlag(prefsFile, unitId);
      result.add(unitId, MigrationStatus.success,
          '已迁移 $newCount 文件 (${_fmtBytes(oldSize)})');
    } catch (e) {
      result.add(unitId, MigrationStatus.failed, '$e');
    }
  }

  // ==================== 旧路径解析（C 盘） ====================

  static Future<File?> _legacyPrefsFile() async {
    final base = await _safeAppSupportDir();
    if (base == null) return null;
    return File(p.join(base, 'shared_preferences.json'));
  }

  static Future<Directory?> _legacyGameConfigsDir() async {
    final base = await _safeAppSupportDir();
    if (base == null) return null;
    return Directory(p.join(base, 'ChronoTide', 'GameConfigs'));
  }

  static Future<Directory?> _legacyUserThemesDir() async {
    final base = await _safeAppSupportDir();
    if (base == null) return null;
    return Directory(p.join(base, 'user_themes'));
  }

  static Future<Directory?> _legacyUserBackgroundsDir() async {
    final base = await _safeAppSupportDir();
    if (base == null) return null;
    return Directory(p.join(base, 'user_backgrounds'));
  }

  static Future<Directory?> _legacyImageCacheFilesDir() async {
    final base = await _safeTempDir();
    if (base == null) return null;
    return Directory(p.join(base, 'libCachedImageData'));
  }

  static Future<File?> _legacyImageCacheMetaFile() async {
    final base = await _safeAppSupportDir();
    if (base == null) return null;
    return File(p.join(base, 'libCachedImageData.json'));
  }

  static Future<String?> _safeAppSupportDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _safeTempDir() async {
    try {
      final dir = await getTemporaryDirectory();
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  // ==================== 文件系统辅助 ====================

  static Future<void> _copyDirectory(Directory src, Directory dst) async {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    await for (final entity in src.list()) {
      if (entity is File) {
        await entity.copy(p.join(dst.path, p.basename(entity.path)));
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(dst.path, p.basename(entity.path))));
      }
    }
  }

  static Future<int> _countFiles(Directory dir) async {
    if (!dir.existsSync()) return 0;
    int count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && !p.basename(entity.path).startsWith('.migrating')) {
        count++;
      }
    }
    return count;
  }

  static Future<int> _dirSizeBytes(Directory dir) async {
    if (!dir.existsSync()) return 0;
    int size = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          size += await entity.length();
        } catch (_) {}
      }
    }
    return size;
  }

  static Future<void> _clearDirectoryContents(Directory dir) async {
    if (!dir.existsSync()) return;
    await for (final entity in dir.list()) {
      try {
        if (entity is File) {
          await entity.delete();
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  static Future<void> _safeDeleteDir(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[MIGRATION] 删除旧目录失败 ${dir.path}: $e');
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static Future<void> _writeMigrationLog(MigrationResult result) async {
    try {
      final logFile = File(p.join(PathHelper.migrationDir, 'migration_log.json'));
      if (!logFile.parent.existsSync()) {
        logFile.parent.createSync(recursive: true);
      }
      logFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(result.toJson()),
        flush: true,
      );
    } catch (e) {
      debugPrint('[MIGRATION] 写入迁移日志失败: $e');
    }
  }
}
