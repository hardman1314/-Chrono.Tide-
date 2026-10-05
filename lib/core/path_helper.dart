import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';

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

  /// 仅供单元测试：将 exeDir 指向临时目录，隔离磁盘写入
  ///
  /// 必须在任何路径 getter 被解析之前调用（因为 exeDir 首次访问后即缓存）。
  /// 传 null 可还原为自动解析。
  static set exeDirOverride(String? value) => _exeDir = value;

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

  // --- SDL3 手柄输入库 ---
  static String get sdl3Dir => path.join(runtimeDir, 'sdl3');
  static String get sdl3DllPath => path.join(sdl3Dir, 'SDL3.dll');

  // --- OpenList 文件服务器 ---
  static String get openlistDir => path.join(runtimeDir, 'openlist');
  static String get openlistExePath => path.join(openlistDir, 'openlist.exe');
  static String get openlistDataZipPath => path.join(openlistDir, 'data.zip');
  static String get openlistDataDir => path.join(openlistDir, 'data');
  static String get openlistConfigPath =>
      path.join(openlistDataDir, 'config.json');

  /// 新流程对接标记（0 字节文件）：`pair()` 成功后写入。
  /// 存在 = 该 OpenList 是用户通过应用内「对接」下载的新流程资产，
  /// 更新/迁移必须保留；缺失（但有 openlist.exe）= 旧版安装包硬内置遗留。
  static String get openlistProvisionMarkerPath =>
      path.join(openlistDir, '.provisioned');

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

  /// 游戏手柄适配的每游戏映射配置（独立文件，不触碰 game.json ⇒ 零 schema 迁移面）
  ///
  /// 键用 ADR-011 的稳定主键 game_id（UUID v4），不用 directoryPath（会被目录迁移改变）。
  static String get gamepadProfilesFilePath =>
      path.join(dataDir, 'gamepad_profiles.json');

  /// 手柄适配会话日志（原生层生命周期证据，排查断连用）
  static String get gamepadLogFilePath =>
      path.join(logsDir, 'gamepad_adaptation.log');

  static String get gameConfigsDir => path.join(dataDir, 'game_configs');
  static String get userThemesDir => path.join(dataDir, 'user_themes');
  static String get userBackgroundsDir =>
      path.join(dataDir, 'user_backgrounds');
  static String get imageCacheDir => path.join(dataDir, 'cache', 'images');

  // --- NSFW 局部检测（v2）---
  /// ONNX 模型释放目录：模型从 assets 释放到此处后由 worker isolate 读取。
  static String get modelsDir => path.join(dataDir, 'models');

  /// 图片级检测结果缓存（key → bbox 列表），见
  /// `docs/DEV/features/nsfw_filter_implementation_plan.md` §4.3。
  static String get nsfwDetectionsFilePath =>
      path.join(dataDir, 'cache', 'nsfw_detections.json');
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
  ///
  /// ⚠️ 2026-09-26 NAS 适配：**网络位置（UNC / 映射网络驱动器）请勿调用本 getter**
  /// —— 盘离线时 `existsSync` / `createSync` 会同步阻塞在 SMB 超时上（数十秒），
  /// 而它通常在 `runApp` 之前求值。数据落点判定请用带超时的异步
  /// [isPortableWritable]；`main.dart` 已对网络位置短路，不会走到这里。
  static bool get isPortableWritableSync {
    if (_portableWritable != null) return _portableWritable!;
    return _probePortableWritableSync();
  }

  static bool _probePortableWritableSync() {
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

  /// 网络位置的写探针超时（建目录 + 写 + 删，各一次 SMB 往返）
  static const Duration _networkProbeTimeout = Duration(seconds: 8);

  /// 异步探针：真实写探针 + 超时，结果缓存复用。
  ///
  /// 本地安装目录复用同步探针（与旧行为逐字一致）。
  ///
  /// ★ 2026-09-26 NAS 适配：网络位置改走**带超时的异步探针** ——
  /// ① 不在 UI isolate 上同步等待 SMB；② 盘离线 / 共享只读时如实返回 false，
  /// 让便携存储正确降级到系统目录（旧实现只有同步探针，离线时会先卡住
  /// 数十秒、再由异常降级）。
  static Future<bool> isPortableWritable() async {
    if (_portableWritable != null) return _portableWritable!;
    if (!NetworkPath.isNetwork(dataDir)) {
      return _probePortableWritableSync();
    }
    try {
      _portableWritable = await _probePortableWritableAsync()
          .timeout(_networkProbeTimeout, onTimeout: () => false);
    } catch (_) {
      _portableWritable = false;
    }
    return _portableWritable!;
  }

  /// 异步写探针。超时被外层截断后，本函数仍会在 IO 返回时清理测试文件。
  static Future<bool> _probePortableWritableAsync() async {
    File? probe;
    try {
      final dir = Directory(dataDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      probe = File(path.join(dataDir, '.writable_test'));
      await probe.writeAsString('probe', flush: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (probe != null && await probe.exists()) await probe.delete();
      } catch (_) {}
    }
  }

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
        // ★ 2026-09-26 NAS 适配：改用异步 exists()，避免网络位置（UNC / 映射盘）
        // 上的同步往返阻塞 UI isolate。
        if (!await dir.exists()) await dir.create(recursive: true);
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

  // ========== 归属判定（删除前的安全闸门） ==========
  /// 判断 [filePath] 是否位于应用自己管理的目录内。
  ///
  /// 用途：删除临时文件（如批量入库的封面缓存）前的守卫。
  /// 表单选封面（join_controller.pickCover）保存的是用户磁盘上原图的**绝对路径**，
  /// 该路径又可在单游戏表单与批量列表之间互传；
  /// 若不加判断直接 delete，会删掉用户桌面/图片目录里的原文件且不可恢复。
  ///
  /// 因此：**不在应用自有目录内的一律不删**。
  /// 代价是应用缓存内产生的临时封面可能残留（磁盘缓慢增长），
  /// 远优于删除用户文件。
  ///
  /// 比较使用 [PathNormalizer.forCompare]：绝对化 → 统一分隔符 → 折叠 `..`
  /// → 小写（Windows 不区分大小写）→ 去尾部斜杠，避免大小写/分隔符差异导致误判。
  static bool isInsideAppStorage(String filePath) {
    if (filePath.isEmpty) return false;
    final target = PathNormalizer.forCompare(filePath);
    if (target.isEmpty) return false;

    final roots = <String>[
      exeDir, // 覆盖 downloads / Games / logs / data 及其全部子目录
      dataDir, // 显式列出以防 exeDir 解析异常
      imageCacheDir,
      portableTmpDir,
      Directory.systemTemp.path, // CoverDownloadService 下载的封面落在系统 temp
    ];

    for (final root in roots) {
      final normalizedRoot = PathNormalizer.forCompare(root);
      if (normalizedRoot.isEmpty) continue;
      if (target == normalizedRoot || target.startsWith('$normalizedRoot\\')) {
        return true;
      }
    }
    return false;
  }
}
