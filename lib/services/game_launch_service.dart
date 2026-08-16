import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/magpie_service.dart';
import '../services/shortcut_service.dart';
import '../utils/game_config_manager.dart';

/// 游戏启动结果
///
/// 由 [GameLaunchService.executeLaunch] 返回,供调用方决定如何反馈给用户。
class LaunchResult {
  /// 启动是否成功
  final bool success;

  /// 失败时的错误信息 (成功时为 null)
  final String? error;

  /// 从 game.json 解析出的转区模式 (供调用方更新内存缓存)
  final String localeMode;

  /// 从 game.json 解析出的超分模式 (供调用方更新内存缓存)
  final String upscalingMode;

  const LaunchResult({
    required this.success,
    this.error,
    this.localeMode = 'none',
    this.upscalingMode = 'none',
  });

  /// 启动成功便利构造
  const LaunchResult.success(
      {String localeMode = 'none', String upscalingMode = 'none'})
      : this(
          success: true,
          localeMode: localeMode,
          upscalingMode: upscalingMode,
        );

  /// 启动失败便利构造
  const LaunchResult.failure(String error) : this(success: false, error: error);
}

/// 游戏启动共享服务
///
/// 从 [LibraryPage] 抽取的启动逻辑,桌面模式与 BPM 共用,避免代码重复。
/// 不依赖 BuildContext,所有 UI 反馈通过返回值 [LaunchResult] 传递,
/// 由调用方自行决定如何提示用户 (SnackBar / AppSnackBar / 其他)。
///
/// 启动流程:
/// 1. [resolveUserChoice] → 解析已保存的 exe 路径
/// 2. [persistUserChoice] → 持久化用户选择的 exe 路径
/// 3. [executeLaunch] → 执行启动 (含 magpie / locale / 普通三种模式)
///
/// 典型用法:
/// ```dart
/// final exePath = await GameLaunchService.instance.resolveUserChoice(game.title);
/// if (exePath != null) {
///   final result = await GameLaunchService.instance.executeLaunch(game, exePath);
///   if (!result.success) AppSnackBar.error(context, result.error!);
/// } else {
///   _showExeSelector(game);  // 由调用方实现 UI
/// }
/// ```
class GameLaunchService {
  GameLaunchService._();
  static final GameLaunchService instance = GameLaunchService._();

  /// ★ C4: 双重启动保护标志，防止快速双击导致游戏被启动多次
  bool _isLaunching = false;

  /// ★ 安全阀：启动代际计数器，配合安全超时 Timer 使用
  /// 每次 executeLaunch 递增，确保旧启动的 finally 不会误释放新启动的锁
  int _launchGeneration = 0;

  /// ★ 安全阀：强制释放启动锁（供外部调试/恢复用）
  /// 当 _isLaunching 因 Process.run 挂起（杀软扫描、PowerShell 冷启动等）
  /// 而永久卡住时，调用此方法强制释放，允许用户重新启动游戏。
  void forceResetLaunchLock() {
    if (_isLaunching) {
      debugPrint('[LAUNCH] 🔓 forceResetLaunchLock: 强制释放启动锁');
      _isLaunching = false;
      _launchGeneration++; // 使任何待完成的安全 Timer 失效
    }
  }

  /// 解析用户保存的启动 exe 路径
  ///
  /// 查询顺序:
  /// 1. [GameConfigManager] (主存储)
  /// 2. [SharedPreferences] (旧版迁移兼容)
  ///
  /// 找到但路径无效时会自动清理失效记录。
  /// 返回 null 表示无可用路径,调用方应弹出 exe 选择器。
  Future<String?> resolveUserChoice(String gameTitle) async {
    debugPrint('[LAUNCH] 查找用户保存的启动路径...');

    final configPath =
        await GameConfigManager.instance.getLaunchPath(gameTitle);
    if (configPath != null && configPath.isNotEmpty) {
      if (await File(configPath).exists()) {
        debugPrint('[LAUNCH] ✅ GameConfigManager命中: $configPath');
        return configPath;
      }
      debugPrint('[LAUNCH] ⚠️ GameConfigManager路径无效，清除');
      await GameConfigManager.instance.removeConfig(gameTitle);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final spPath = prefs.getString('default_exe_$gameTitle');
      if (spPath != null && spPath.isNotEmpty) {
        if (await File(spPath).exists()) {
          debugPrint('[LAUNCH] ✅ SharedPreferences命中(迁移): $spPath');
          await GameConfigManager.instance
              .migrateFromSharedPreferences(gameTitle, spPath);
          return spPath;
        }
        debugPrint('[LAUNCH] ⚠️ SP路径无效，清除');
        await prefs.remove('default_exe_$gameTitle');
      }
    } catch (e) {
      debugPrint('[LAUNCH] SP读取异常: $e');
    }

    return null;
  }

  /// 持久化用户选择的 exe 路径
  ///
  /// 写入三处:
  /// 1. [GameConfigManager] (主存储)
  /// 2. [SharedPreferences] (兼容旧版)
  /// 3. [LocalGameRegistry] (内存+索引)
  Future<void> persistUserChoice(String gameTitle, String exePath) async {
    debugPrint('[LAUNCH] 💾 持久化用户选择(覆盖式写入)...');

    try {
      await GameConfigManager.instance.saveLaunchPath(gameTitle, exePath);
      debugPrint('[LAUNCH]   GameConfigManager: OK');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_exe_$gameTitle', exePath);
      debugPrint('[LAUNCH]   SharedPreferences: OK(旧值已覆盖)');
    } catch (e) {
      debugPrint('[LAUNCH]   持久化异常: $e');
    }

    try {
      await LocalGameRegistry.instance.updateLauncherPath(gameTitle, exePath);
      debugPrint('[LAUNCH]   LocalGameRegistry: OK');
    } catch (e) {
      debugPrint('[LAUNCH]   Registry更新异常: $e');
    }

    debugPrint('[LAUNCH] ✅ 用户选择已锁定: $exePath');
  }

  /// 执行游戏启动
  ///
  /// 完整流程:
  /// 1. 持久化 exe 路径
  /// 2. 读取 game.json 中的 locale_mode 和 upscaling_mode
  /// 3. 根据 upscaling_mode 选择启动方式:
  ///    - `magpie`: 走 [MagpieService.startGameWithUpscaling] (含回退到普通启动)
  ///    - 其他: 走 [LocalGameRegistry.launchGame]
  /// 4. 启动成功后更新游玩状态 (notStarted → inProgress) 与时间戳
  ///
  /// 不直接操作 UI,通过 [LaunchResult] 返回结果供调用方反馈。
  /// 调用方应在 await 完成后自行调用 setState() 刷新卡片状态。
  Future<LaunchResult> executeLaunch(LibraryGame game, String exePath) async {
    debugPrint('[LAUNCH] 执行启动: ${game.title} -> $exePath');

    // ★ C4: 双重启动保护，防止快速双击导致游戏被启动多次
    if (_isLaunching) {
      debugPrint('[LAUNCH] ⏭️ 上一次启动仍在进行中，跳过本次请求');
      return LaunchResult.failure('正在启动中，请稍候...');
    }
    _isLaunching = true;
    final myGeneration = ++_launchGeneration;
    final launchStart = DateTime.now();
    debugPrint('[LAUNCH] 🔒 启动锁已获取 (代际: $myGeneration)');

    // ★ 安全阀：120s 后强制释放启动锁，防止 Process.run 挂起
    // （杀软扫描、PowerShell 冷启动、cmd.exe 等待输入、WMI 查询卡死等）
    // 导致 _isLaunching 永久卡住，用户无法重新启动游戏。
    // 正常情况下 finally 会先执行并 cancel 此 Timer。
    // 使用代际计数器确保只有当前代的 Timer 才能释放锁，避免旧启动的
    // 安全 Timer 误释放新启动的锁。
    final safetyTimer = Timer(const Duration(seconds: 120), () {
      if (_launchGeneration == myGeneration && _isLaunching) {
        debugPrint(
            '[LAUNCH] ⚠️ 安全阀触发：启动超过120s，强制释放启动锁 (代际: $myGeneration)');
        _isLaunching = false;
      }
    });

    try {
      return await _executeLaunchInternal(game, exePath);
    } catch (e) {
      debugPrint('[LAUNCH] ❌ 启动流程异常: $e');
      return LaunchResult.failure('启动异常: $e');
    } finally {
      safetyTimer.cancel();
      // ★ 仅当当前代际匹配时才释放锁，防止旧启动的 finally 释放新启动的锁
      if (_launchGeneration == myGeneration) {
        _isLaunching = false;
        final elapsed = DateTime.now().difference(launchStart).inMilliseconds;
        debugPrint('[LAUNCH] 🔓 启动锁已释放 (耗时: ${elapsed}ms, 代际: $myGeneration)');
      } else {
        debugPrint('[LAUNCH] ℹ️ 跳过锁释放（代际不匹配: $myGeneration != $_launchGeneration）');
      }
    }
  }

  Future<LaunchResult> _executeLaunchInternal(
      LibraryGame game, String exePath) async {
    // ★ 在任何时间戳更新之前捕获首次启动状态
    // 注意：startPlayTimeTracking 内部（local_game_registry.dart:1352-1354）
    // 会把 firstOpenedAt 设为当前时间，之后 _updateOpenedTimestamp 内的
    // firstOpenedAt.isEmpty 判断会失效，所以必须在此处先捕获标志。
    final isFirstLaunch = game.firstOpenedAt.isEmpty;

    await persistUserChoice(game.title, exePath);

    // 从 game.json 实时读取模式,而非依赖内存缓存,确保与磁盘数据一致
    String localeMode = 'none';
    String upscalingMode = 'none';
    try {
      final data = await GameDataFormat.readGameJson(game.metaDataDir);
      if (data != null) {
        if (data.localeMode.isNotEmpty) localeMode = data.localeMode;
        if (data.upscalingMode.isNotEmpty) upscalingMode = data.upscalingMode;
      }
    } catch (_) {}

    debugPrint('[LAUNCH] 转区模式: $localeMode');
    debugPrint('[LAUNCH] 超分模式: $upscalingMode');

    // 超分模式: 使用 MagpieService 启动
    if (upscalingMode == 'magpie') {
      final success = await MagpieService.instance.startGameWithUpscaling(
        gameExePath: exePath,
        gameTitle: game.title,
        localeMode: localeMode,
      );
      if (success) {
        // 注册游玩时长追踪会话 (超分启动无法通过 launchGame 创建会话,需手动注册)
        // ★ 检查返回值：若会话注册失败，游戏已启动但时长不会记录，
        // 需告知用户而非静默成功（旧实现返回 void，失败被吞掉）
        final trackingOk = await LocalGameRegistry.instance.startPlayTimeTracking(
          game.title,
          exePath: exePath,
        );
        if (!trackingOk) {
          debugPrint('[LAUNCH] ⚠️ Magpie 启动成功但会话注册失败（游戏未找到），时长将不记录');
        }
        // 更新游玩状态
        if (game.playStatus == PlayStatus.notStarted) {
          game.playStatus = PlayStatus.inProgress;
          GameDataFormat.setPlayStatus(game.metaDataDir, 'in_progress');
        }
        // ★ H12: 后续步骤失败不阻塞，游戏已在运行
        await _safePostLaunch(game, exePath, localeMode, upscalingMode, isFirstLaunch);
        return LaunchResult.success(
          localeMode: localeMode,
          upscalingMode: upscalingMode,
        );
      }

      // 启动失败处理
      if (MagpieService.instance.fallbackOnFail) {
        // 回退到普通启动
        debugPrint('[LAUNCH] Magpie 失败,回退到普通启动');
        final fallbackSuccess = await LocalGameRegistry.instance.launchGame(
          game.title,
          forceExePath: exePath,
          localeMode: localeMode,
          skipUpscaling: true, // ★ C5: 避免重复 Magpie 启动
        );
        if (fallbackSuccess) {
          // ★ H12: 后续步骤失败不阻塞，游戏已在运行
          await _safePostLaunch(game, exePath, localeMode, upscalingMode, isFirstLaunch);
          return LaunchResult.success(
            localeMode: localeMode,
            upscalingMode: upscalingMode,
          );
        }
        return LaunchResult.failure('无法启动「${game.title}」');
      }
      // 不允许回退,直接报错
      return LaunchResult.failure(
        '超分启动失败：${MagpieService.instance.errorMessage ?? "未知错误"}',
      );
    }

    // 普通启动 (含转区)
    final success = await LocalGameRegistry.instance.launchGame(
      game.title,
      forceExePath: exePath,
      localeMode: localeMode,
    );

    if (success) {
      // ★ H12: 后续步骤失败不阻塞，游戏已在运行
      await _safePostLaunch(game, exePath, localeMode, upscalingMode, isFirstLaunch);
      return LaunchResult.success(
        localeMode: localeMode,
        upscalingMode: upscalingMode,
      );
    }
    return LaunchResult.failure('无法启动「${game.title}」');
  }

  /// ★ H12: 启动后的辅助步骤（时间戳/快捷方式），失败不阻塞启动结果
  Future<void> _safePostLaunch(
    LibraryGame game,
    String exePath,
    String localeMode,
    String upscalingMode,
    bool isFirstLaunch,
  ) async {
    try {
      await _updateOpenedTimestamp(game);
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 时间戳更新失败（不阻塞）: $e');
    }
    try {
      await _maybeCreateDesktopShortcut(
        game: game,
        exePath: exePath,
        localeMode: localeMode,
        upscalingMode: upscalingMode,
        isFirstLaunch: isFirstLaunch,
      );
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 快捷方式创建失败（不阻塞）: $e');
    }
  }

  /// 更新 last_opened_at / first_opened_at 时间戳
  Future<void> _updateOpenedTimestamp(LibraryGame game) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, dynamic>{'last_opened_at': now};
    if (game.firstOpenedAt.isEmpty) {
      game.firstOpenedAt = now;
      updates['first_opened_at'] = now;
    }
    try {
      await GameDataFormat.updateGameJson(game.metaDataDir, updates);
    } catch (e) {
      debugPrint('[LAUNCH] 时间戳更新异常: $e');
    }
  }

  /// 首次启动游戏时自动生成桌面快捷方式
  ///
  /// 仅在 [isFirstLaunch] 为 true 且桌面尚无 .lnk 时触发。
  /// 优先使用 game.json 中已有的 custom_icon_path，否则使用 exe 自带图标
  /// (避免阻塞做封面转 ico)。失败不阻塞启动流程，仅 debugPrint。
  ///
  /// 注意：[isFirstLaunch] 必须由调用方在 startPlayTimeTracking 之前捕获，
  /// 因为 startPlayTimeTracking 会写入 firstOpenedAt，导致之后判断失效。
  Future<void> _maybeCreateDesktopShortcut({
    required LibraryGame game,
    required String exePath,
    required String localeMode,
    required String upscalingMode,
    required bool isFirstLaunch,
  }) async {
    if (!isFirstLaunch) return;
    if (ShortcutService.instance.hasShortcut(game.title)) return;

    try {
      // 读取 game.json：auto_create_shortcut 控制是否自动生成（默认 true）
      // custom_icon_path 优先作为快捷方式图标，否则用 exe 自带图标
      final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
      final autoCreate = jsonData?.autoCreateShortcut ?? true;
      if (!autoCreate) {
        debugPrint('[LAUNCH] 用户已关闭"首次启动自动生成"，跳过快捷方式创建: ${game.title}');
        return;
      }
      final customIconPath = jsonData?.customIconPath ?? '';

      await ShortcutService.instance.createShortcut(
        gameTitle: game.title,
        exePath: exePath,
        gameDirectory: game.directoryPath,
        customIconPath: customIconPath.isNotEmpty ? customIconPath : null,
        localeMode: localeMode,
        upscalingMode: upscalingMode,
      );
      debugPrint('[LAUNCH] ✅ 首次启动已自动生成桌面快捷方式: ${game.title}');
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 自动生成快捷方式失败（不阻塞启动）: $e');
    }
  }
}
