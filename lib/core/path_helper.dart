import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class PathHelper {
  static String? _exeDir;

  static String get exeDir {
    _exeDir ??= _resolveExeDir();
    return _exeDir!;
  }

  static String _resolveExeDir() {
    final exePath = Platform.resolvedExecutable;
    return File(exePath).parent.path;
  }

  // ========== Runtime 目录（外置工具统一存放） ==========
  static String get runtimeDir => path.join(exeDir, 'runtime');

  // --- Locale Emulator (LE) 转区工具 ---
  static String get localeEmulatorDir =>
      path.join(runtimeDir, 'locale_emulator');
  static String get leProcPath => path.join(localeEmulatorDir, 'LEProc.exe');
  static String get loaderDllPath =>
      path.join(localeEmulatorDir, 'LoaderDll.dll');
  static String get localeEmulatorDllPath =>
      path.join(localeEmulatorDir, 'LocaleEmulator.dll');
  static String get leCommonLibraryPath =>
      path.join(localeEmulatorDir, 'LECommonLibrary.dll');
  static String get leConfigPath =>
      path.join(localeEmulatorDir, 'LEConfig.xml');
  static String get leLangDir => path.join(localeEmulatorDir, 'Lang');

  // --- OpenList 文件服务器 ---
  static String get openlistDir => path.join(runtimeDir, 'openlist');
  static String get openlistExePath => path.join(openlistDir, 'openlist.exe');
  static String get openlistDataZipPath => path.join(openlistDir, 'data.zip');
  static String get openlistDataDir => path.join(openlistDir, 'data');
  static String get openlistConfigPath =>
      path.join(openlistDataDir, 'config.json');

  // --- 内置工具 ---
  static String get toolsDir => path.join(runtimeDir, 'tools');
  static String get bundled7zPath => path.join(toolsDir, '7z.exe');

  // --- 后台服务 ---
  static String get scraperServicePath =>
      path.join(runtimeDir, 'scraper_service.exe');

  // ========== 应用数据目录（根级） ==========
  static String get downloadsDir => path.join(exeDir, 'downloads');
  static String get gamesDir => path.join(exeDir, 'Games');
  static String get logsDir => path.join(exeDir, 'logs');
  static String get dataDir => path.join(exeDir, 'data');

  // ========== 便携式存储子目录（统一置于 data/ 下，不污染安装根目录） ==========
  // 所有应用产生的缓存/数据/图片均存放于此，避免占用系统 C 盘。
  static String get prefsDir => path.join(dataDir, 'prefs');
  static String get prefsFilePath =>
      path.join(prefsDir, 'shared_preferences.json');
  static String get gameConfigsDir => path.join(dataDir, 'game_configs');
  static String get userThemesDir => path.join(dataDir, 'user_themes');
  static String get userBackgroundsDir =>
      path.join(dataDir, 'user_backgrounds');
  static String get imageCacheDir => path.join(dataDir, 'cache', 'images');
  static String get portableTmpDir => path.join(dataDir, 'tmp');
  static String get lockDir => path.join(dataDir, 'lock');
  static String get lockFilePath =>
      path.join(lockDir, 'chrono_tide_instance.lock');
  static String get launchRequestDir =>
      path.join(lockDir, 'chrono_tide_launch_requests');
  static String get migrationDir => path.join(dataDir, 'migration');

  // ========== 安装目录可写性探针 ==========
  // 装在只读位置（如 Program Files）时返回 false，所有便携存储降级回系统目录。
  static bool? _portableWritable;

  /// 同步探针：在 dataDir 下创建并删除测试文件，结果缓存复用。
  /// 供 main.dart 顶层（无法 await）解析锁文件路径使用。
  static bool get isPortableWritableSync {
    if (_portableWritable != null) return _portableWritable!;
    try {
      final dir = Directory(dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File(path.join(dataDir, '.writable_test'));
      probe.writeAsStringSync('probe');
      probe.deleteSync();
      _portableWritable = true;
    } catch (_) {
      _portableWritable = false;
    }
    return _portableWritable!;
  }

  /// 异步探针（复用同步结果，便于异步调用方使用）。
  static Future<bool> isPortableWritable() async => isPortableWritableSync;

  /// 创建所有便携子目录（每步独立 try-catch，失败仅 debugPrint 不抛错）。
  static Future<void> ensurePortableDirs() async {
    final dirs = [
      prefsDir,
      gameConfigsDir,
      userThemesDir,
      userBackgroundsDir,
      imageCacheDir,
      portableTmpDir,
      lockDir,
      launchRequestDir,
      migrationDir,
    ];
    for (final d in dirs) {
      try {
        final dir = Directory(d);
        if (!dir.existsSync()) await dir.create(recursive: true);
      } catch (e) {
        debugPrint('[PathHelper] 创建目录失败 $d: $e');
      }
    }
  }

  // ========== 辅助方法 ==========
  // .rar.lz4 解压：Dart 原生调用 bz.exe(Bandizip) 解 LZ4 外层 + UnRAR.exe 解 RAR 内层
  static String get bandizipExePath => path.join(toolsDir, 'bz.exe');
  static String get unrarExePath => path.join(toolsDir, 'UnRAR.exe');

  static String getDownloadFilePath(String fileName) {
    return path.join(downloadsDir, fileName);
  }

  static String getGameDir(String gameTitle) {
    final safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return path.join(gamesDir, safeName.isEmpty ? 'UnknownGame' : safeName);
  }

  static String getTempChunkPath(int chunkIndex) {
    return path.join(downloadsDir, '.chunk_$chunkIndex.tmp');
  }
}
