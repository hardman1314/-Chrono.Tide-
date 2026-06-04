import 'dart:io';
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

  // ========== 辅助方法 ==========
  static String get rarLz4UnzipExePath =>
      path.join(toolsDir, 'rar_lz4_unzip.exe');

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
