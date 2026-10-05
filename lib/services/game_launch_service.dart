import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/magpie_service.dart';
import '../services/running_tasks_service.dart';
import '../services/shortcut_service.dart';
import '../services/auto_shortcut_preference.dart';
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
///
/// 🔴 P0-2（2026-09-19 数据层加固批 3）：启动 exe 路径的**唯一事实源是
/// `game.json` 的 `launch_path`**。历史上它同时存在三处——
/// A：`game.json.launch_path`（权威本体）
/// B：`data/game_configs/game_<标题>_config.json`（注释自称"主存储"）
/// C：prefs `default_exe_<标题>`
/// 而三个读取入口的优先级各不相同（[resolveUserChoice] 是 B→C，
/// 库页启动管理弹窗是 B→C 的另一套写法，BPM 又走前者），于是出现
/// 「改了启动程序却不生效」「改标题后旧配置变孤儿」这类工单。
/// 现在 B/C **只读兼容**（命中即一次性搬进 A 并删除自身），不再有任何写入方。
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

  /// 解析用户保存的启动 exe 路径（**唯一入口**，P0-2）
  ///
  /// 查询顺序:
  /// 1. `game.json.launch_path` —— 唯一事实源（相对 directoryPath 相对路径，
  ///    经 [GameDataFormat.resolveLaunchPath] 解析成真实绝对路径）
  /// 2. `data/game_configs/…_config.json` —— 历史存储，**只读兼容**，
  ///    命中即搬进 game.json 并删除旧文件
  /// 3. prefs `default_exe_<标题>` —— 历史存储，同上
  ///
  /// 命中失效记录时自动清理。返回 null 表示无可用路径，
  /// 调用方应弹出 exe 选择器。
  ///
  /// 🔴 所有需要"这个游戏该用哪个 exe 启动"的地方都必须走本方法，
  /// 不允许各自拼读取顺序——三套优先级正是 P0-2 的病根。
  Future<String?> resolveUserChoice(String gameTitle) async {
    debugPrint('[LAUNCH] 查找用户保存的启动路径...');

    // ① 唯一事实源：game.json.launch_path
    final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    if (game != null && game.launchPath.isNotEmpty) {
      final resolved = GameDataFormat.resolveLaunchPath(
          game.launchPath, game.directoryPath);
      if (resolved.isNotEmpty) {
        debugPrint('[LAUNCH] ✅ game.json 命中: $resolved');
        return resolved;
      }
      debugPrint('[LAUNCH] ⚠️ game.json 的 launch_path 已失效: ${game.launchPath}');
    }

    // ② 历史存储：配置文件（其 getLaunchPath 内部已做"文件不存在即清理"）
    final configPath =
        await GameConfigManager.instance.getLaunchPath(gameTitle);
    if (configPath != null && configPath.isNotEmpty) {
      debugPrint('[LAUNCH] ✅ GameConfigManager命中(迁移进 game.json): $configPath');
      await _adoptLegacyPath(gameTitle, configPath);
      return configPath;
    }

    // ③ 历史存储：prefs
    try {
      final prefs = await SharedPreferences.getInstance();
      final spPath = prefs.getString('default_exe_$gameTitle');
      if (spPath != null && spPath.isNotEmpty) {
        if (await File(spPath).exists()) {
          debugPrint('[LAUNCH] ✅ SharedPreferences命中(迁移进 game.json): $spPath');
          await _adoptLegacyPath(gameTitle, spPath);
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

  /// 把历史存储里找到的启动路径**一次性搬进 game.json**，然后清掉历史存储。
  ///
  /// 为什么删而不是留作兜底：两份事实迟早分叉——一旦用户在启动管理里
  /// 清空了 `launch_path`（"我要重选"），遗留值会作为兜底把过期的 exe
  /// 悄悄复活，表现为"清不掉"。宁可删掉，让"没有启动程序"是个明确状态。
  Future<void> _adoptLegacyPath(String gameTitle, String exePath) async {
    if (LocalGameRegistry.instance.getGameByTitle(gameTitle) != null) {
      try {
        await LocalGameRegistry.instance.updateLauncherPath(gameTitle, exePath);
      } catch (e) {
        debugPrint('[LAUNCH] ⚠️ 迁移 launch_path 进 game.json 失败: $e');
      }
    }
    await _removeLegacyStores(gameTitle);
  }

  /// 清理历史存储中的启动路径记录（P0-2 收敛后不再有任何写入方）
  Future<void> _removeLegacyStores(String gameTitle) async {
    try {
      await GameConfigManager.instance.removeConfig(gameTitle);
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 清理遗留配置文件失败: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('default_exe_$gameTitle');
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 清理遗留 prefs 记录失败: $e');
    }
  }

  /// 持久化用户选择的 exe 路径（P0-2：**只写** game.json.launch_path）
  ///
  /// 经 [LocalGameRegistry.updateLauncherPath] 落盘，顺带更新内存对象与
  /// 活跃会话的 exe 监控列表；同时清掉历史存储，避免遗留值复活。
  Future<void> persistUserChoice(String gameTitle, String exePath) async {
    debugPrint('[LAUNCH] 💾 持久化用户选择(覆盖式写入)...');

    try {
      await LocalGameRegistry.instance.updateLauncherPath(gameTitle, exePath);
      debugPrint('[LAUNCH]   game.json(launch_path): OK');
    } catch (e) {
      debugPrint('[LAUNCH]   game.json 写入异常: $e');
    }

    await _removeLegacyStores(gameTitle);
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
  ///
  /// 是否需要自动生成桌面快捷方式由全局偏好
  /// [AutoShortcutPreference]（设置窗口「游戏与启动 → 系统」）决定，
  /// 2026-09-27 起默认关闭。
  Future<LaunchResult> executeLaunch(
    LibraryGame game,
    String exePath,
  ) async {
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

    // ★ 运行任务横幅：登记任务（初始状态「正在启动」）
    // 放在启动锁获取之后，确保被防抖拦截的重复双击不会创建多余横幅；
    // 放在任何 await 之前，保证横幅在启动流程开始的同一帧就出现。
    RunningTasksService.instance.beginTask(game);

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
      final result = await _executeLaunchInternal(game, exePath);
      if (!result.success) {
        // 启动失败：横幅保留并展示具体原因，由用户手动关闭提示
        RunningTasksService.instance
            .markFailed(game.metaDataDir, result.error ?? '未知错误');
      }
      // ★ 启动成功时此处刻意不做任何事：横幅保持在「正在启动」，
      // 等 LocalGameRegistry 检测到游戏进程真正存活后，通过
      // onGameSessionConfirmed 回调切换为「运行中」并开始计时。
      // 这样「运行中」的判定与时长统计的进程检测共用同一套逻辑，不会出现
      // 「横幅说在运行、时长却没记」的口径分歧。
      return result;
    } catch (e) {
      debugPrint('[LAUNCH] ❌ 启动流程异常: $e');
      RunningTasksService.instance.markFailed(game.metaDataDir, '启动异常: $e');
      return LaunchResult.failure('启动异常: $e');
    } finally {
      safetyTimer.cancel();
      // ★ 仅当当前代际匹配时才释放锁，防止旧启动的 finally 释放新启动的锁
      if (_launchGeneration == myGeneration) {
        _isLaunching = false;
        final elapsed = DateTime.now().difference(launchStart).inMilliseconds;
        debugPrint('[LAUNCH] 🔓 启动锁已释放 (耗时: ${elapsed}ms, 代际: $myGeneration)');
      } else {
        debugPrint('[LAUNCH] ℹ️ 跳过锁释放（代际不匹配: $myGeneration != $_launchGeneration)');
      }
    }
  }

  Future<LaunchResult> _executeLaunchInternal(
    LibraryGame game,
    String exePath,
  ) async {
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
          // ★ 响应式修复：广播状态变更，库页/主页「游玩中」徽标即时刷新
          LocalGameRegistry.instance.notifyDataChanged();
        }
        // ★ H12: 后续步骤失败不阻塞，游戏已在运行
        await _safePostLaunch(
          game,
          exePath,
          localeMode,
          upscalingMode,
          isFirstLaunch,
        );
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
          await _safePostLaunch(
            game,
            exePath,
            localeMode,
            upscalingMode,
            isFirstLaunch,
          );
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
      await _safePostLaunch(
        game,
        exePath,
        localeMode,
        upscalingMode,
        isFirstLaunch,
      );
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
  /// 是否生成由全局偏好 [AutoShortcutPreference.enabled] 决定
  /// （设置窗口「游戏与启动 → 系统」，2026-09-27 起默认关闭）。
  /// 旧实现读取每游戏的 `game.json auto_create_shortcut` 字段，现已不再读取
  /// （字段保留、不删数据）。
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
    if (!AutoShortcutPreference.instance.enabled) {
      debugPrint('[LAUNCH] 全局设置未开启"首次启动自动生成"，跳过快捷方式创建: ${game.title}');
      return;
    }

    try {
      // custom_icon_path 优先作为快捷方式图标，否则用 exe 自带图标
      final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
      final customIconPath = jsonData?.customIconPath ?? '';

      await ShortcutService.instance.createShortcut(
        gameTitle: game.title,
        exePath: exePath,
        gameDirectory: game.directoryPath,
        customIconPath: customIconPath.isNotEmpty ? customIconPath : null,
        localeMode: localeMode,
        upscalingMode: upscalingMode,
      );
      debugPrint('[LAUNCH] ✅ 已生成桌面快捷方式: ${game.title}');
    } catch (e) {
      debugPrint('[LAUNCH] ⚠️ 自动生成快捷方式失败（不阻塞启动）: $e');
    }
  }
}
