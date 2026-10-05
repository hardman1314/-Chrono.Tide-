import 'dart:async';
import 'package:flutter/foundation.dart';

import 'local_game_registry.dart';
import 'gamepad/gamepad_adaptation_coordinator.dart';

/// 游戏运行任务的状态
///
/// 状态流转见 [RunningTasksService] 类注释。
enum RunningTaskStatus {
  /// 已发起启动，等待游戏进程被确认存活
  launching,

  /// 游戏进程确认运行，开始墙钟计时
  running,

  /// 用户点击「关闭游戏」，正在终止进程树
  closing,

  /// 游戏已退出或监控已解除，短暂展示本次总时长后淡出
  exiting,

  /// 启动失败，常驻展示错误直到用户手动关闭
  failed,
}

/// 单条游戏运行任务
///
/// 以 [metaDataDir] 作为唯一键：注册表侧一个游戏同时只可能有一个活跃会话，
/// 因此横幅上一个游戏也只会有一条任务。
class RunningTask {
  /// 游戏元数据目录（任务唯一键，与注册表会话的 key 一致）
  final String metaDataDir;

  /// 关联的游戏对象（持有引用，仅读取标题与封面路径）
  final LibraryGame game;

  /// 任务创建时刻（用户点击启动的时刻）
  final DateTime createdAt;

  RunningTaskStatus status;

  /// 墙钟计时起点（进程首次确认存活的时刻），null 表示尚未开始计时
  DateTime? runningSince;

  /// 进入 [RunningTaskStatus.exiting] 的时刻，用于淡出倒计时
  DateTime? exitedAt;

  /// 结束时的墙钟总秒数（进入 exiting 后不再变化）
  int finalSeconds;

  /// 启动失败的错误信息（仅 [RunningTaskStatus.failed] 时有值）
  String? errorMessage;

  /// 是否处于淡出中（UI 播放退场动画期间仍留在列表里）
  ///
  /// 由本服务在移除任务前置为 true，[fadeOutDuration] 后才真正从列表移除，
  /// 让横幅能平滑淡出而不是被瞬间抽掉。
  bool fading;

  RunningTask({
    required this.metaDataDir,
    required this.game,
  })  :         createdAt = DateTime.now(),
        status = RunningTaskStatus.launching,
        finalSeconds = 0,
        fading = false;

  String get title => game.title;

  /// 当前墙钟已运行秒数
  ///
  /// 口径说明（经确认的产品决策）：这里走**墙钟时间**——从进程确认存活起
  /// 一直累加，切后台也照走。它与统计页的 `play_time` 增量不是同一个数：
  /// 精准统计模式下切后台不计时，所以横幅数字通常会略大于统计增量。
  /// 这是刻意为之：横幅回答的是「这局开了多久」，统计回答的是「有效游玩多久」。
  int elapsedSeconds(DateTime now) {
    final since = runningSince;
    if (since == null) return 0;
    final end = exitedAt ?? now;
    final secs = end.difference(since).inSeconds;
    return secs < 0 ? 0 : secs;
  }
}

/// 游戏运行任务状态中枢
///
/// 为窗口顶部的【游戏运行任务状态横幅】提供数据：维护任务列表、驱动 1s 刷新、
/// 执行「解除监控」与「关闭游戏」两个操作。
///
/// ## 状态流转
/// ```
/// beginTask ─▶ launching ─确认进程存活─▶ running（开始墙钟计时）
///     │                       │
///     │                       ├─ 游戏内退出 ─▶ exiting（展示总时长）─5s─▶ 移除
///     │                       ├─ 点解除监控 ─▶ 定格落盘 ─▶ 移除
///     │                       └─ 点关闭游戏 ─▶ closing（终止进程）─▶ 移除
///     └─ 启动失败 ─▶ failed（常驻展示错误，需手动关闭）
/// ```
///
/// ## 两条关键设计约束
///
/// **1. 「进程确认存活」走回调，「会话消失」走轮询。**
/// 前者用 `LocalGameRegistry.onGameSessionConfirmed`（本次新增的专用回调，无占用冲突）；
/// 后者**不能**用 `onGameSessionEnded`——那是单一回调字段，已被 TrayService 占用，
/// 覆盖它会静默破坏托盘通知。因此会话消失改由 1s tick 对比
/// `LocalGameRegistry.activeSessionDirs` 判定，顺带也覆盖了「用户在外部直接杀掉
/// 游戏进程」这种不走回调的场景。
///
/// **2. 时长口径是墙钟，不是统计口径。**
/// 见 [RunningTask.elapsedSeconds] 的说明。
class RunningTasksService with ChangeNotifier {
  RunningTasksService._();
  static final RunningTasksService instance = RunningTasksService._();

  /// 退出后横幅保留时长，到点平滑淡出移除
  static const Duration exitBannerDuration = Duration(seconds: 5);

  /// 退场动画时长（与 UI 侧 AnimatedOpacity/AnimatedSlide 的 duration 保持一致）
  static const Duration fadeOutDuration = Duration(milliseconds: 320);

  // ═══ 仅供测试：可缩短的时间常量 ═══
  // 生产取值见上方 static const。测试里覆盖为毫秒级后，可以用很短的
  // 真实等待验证完整状态流转（启动→运行→退出→淡出→移除），
  // 而不必在单测里真等 5 秒以上。
  @visibleForTesting
  Duration debugTickInterval = const Duration(seconds: 1);

  @visibleForTesting
  Duration debugExitBannerDuration = exitBannerDuration;

  @visibleForTesting
  Duration debugLaunchTimeout = launchTimeout;

  /// 启动超时兜底：超过这个时长仍未确认进程存活，判定为启动失败
  ///
  /// 覆盖 Magpie 超分路径「游戏进程已起来但会话注册失败」这类极端情况
  /// （见 `game_launch_service.dart` 中 trackingOk == false 分支）：
  /// 没有会话就不会有 onGameSessionConfirmed 回调，横幅会永久停在
  /// 「正在启动…」。有了这个兜底，用户至少能看到明确提示而不是无限转圈。
  static const Duration launchTimeout = Duration(seconds: 60);

  final List<RunningTask> _tasks = [];

  /// 只读任务列表（自上而下的堆叠顺序即列表顺序）
  List<RunningTask> get tasks => List.unmodifiable(_tasks);

  Timer? _ticker;

  /// 正在执行 detach/kill 的任务键，防止连点重复触发进程操作
  final Set<String> _busy = <String>{};

  bool _initialized = false;

  /// 横幅「重要变化」事件计数。
  ///
  /// 收起横幅后用户看不到任务状态变化，本计数在以下事件发生时自增，
  /// 供收起态的「未读红点」判断是否有需要关注的更新：
  /// - 任务确认进程存活（切到 running）
  /// - 游戏内退出（切到 exiting）
  /// - 启动失败（markFailed 或启动超时兜底）
  ///
  /// 横幅组件持有一个「上次已读计数」([_CollapsedPill] 侧)，展开时刷新为
  /// 当前值；当 [bannerEventEpoch] 大于已读计数时显示红点。
  int _bannerEventEpoch = 0;

  /// 只读：当前重要变化事件计数
  int get bannerEventEpoch => _bannerEventEpoch;

  /// 触发一次「重要变化」事件计数自增（调用方负责 notifyListeners）
  void _bumpEvent() => _bannerEventEpoch++;

  /// 绑定注册表回调并启动纳管逻辑
  ///
  /// 应在应用启动、注册表完成首次扫描之后调用一次。幂等。
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    LocalGameRegistry.instance.onGameSessionConfirmed = _onSessionConfirmed;
    syncFromRegistry();
    debugPrint('[RUNNING-TASKS] ✅ 运行任务服务已初始化');
  }

  /// 冷启动纳管：把注册表中已存在、但不是本会话发起的会话接管过来
  ///
  /// 覆盖两类场景：① 应用崩溃重启后 `recoverPendingSessions` 恢复的会话；
  /// ② 用户在软件未运行时手动启动的游戏、之后才打开软件。
  /// 这类任务的墙钟起点按会话已运行分钟数向前回推（分钟精度，误差可接受）。
  void syncFromRegistry() {
    final registry = LocalGameRegistry.instance;
    List<Map<String, dynamic>> infos;
    try {
      infos = registry.getActiveSessionsInfo();
    } catch (e) {
      debugPrint('[RUNNING-TASKS] ⚠️ 读取活跃会话失败: $e');
      return;
    }

    var added = 0;
    for (final info in infos) {
      final dir = info['metaDataDir'] as String?;
      if (dir == null || dir.isEmpty) continue;
      if (_tasks.any((t) => t.metaDataDir == dir)) continue;

      final title = info['gameTitle'] as String? ?? '';
      final game = title.isEmpty
          ? _findGameByMetaDir(dir)
          : LocalGameRegistry.instance.getGameByTitle(title);
      if (game == null) {
        debugPrint('[RUNNING-TASKS] ⚠️ 会话无对应游戏记录，跳过: $dir');
        continue;
      }

      final elapsedMin = (info['sessionDurationMin'] as int?) ?? 0;
      final task = RunningTask(metaDataDir: dir, game: game)
        ..status = RunningTaskStatus.running
        ..runningSince =
            DateTime.now().subtract(Duration(minutes: elapsedMin < 0 ? 0 : elapsedMin));
      _tasks.add(task);
      added++;
    }

    if (added > 0) {
      debugPrint('[RUNNING-TASKS] 🔄 已纳管 $added 个既有会话');
      _ensureTicker();
      notifyListeners();
    }
  }

  LibraryGame? _findGameByMetaDir(String metaDataDir) {
    try {
      return LocalGameRegistry.instance.allGames
          .firstWhere((g) => g.metaDataDir == metaDataDir);
    } catch (_) {
      return null;
    }
  }

  /// 发起一次启动任务（状态 = launching）
  ///
  /// 由 [GameLaunchService.executeLaunch] 在真正执行启动前调用。
  /// 若该游戏已有任务（例如重复双击启动），只把状态重置回 launching，
  /// 保留已有的计时基线——因为注册表侧的会话并未中断，累计时长仍在延续。
  void beginTask(LibraryGame game) {
    final existing = _find(game.metaDataDir);
    if (existing != null) {
      if (existing.status == RunningTaskStatus.failed) {
        existing.errorMessage = null;
      }
      existing.status = RunningTaskStatus.launching;
      _ensureTicker();
      notifyListeners();
      return;
    }

    _tasks.add(RunningTask(metaDataDir: game.metaDataDir, game: game));
    debugPrint('[RUNNING-TASKS] 🆕 任务已创建(launching): ${game.title}');
    _ensureTicker();
    notifyListeners();
  }

  /// 启动失败：常驻展示错误，直到用户手动关闭
  void markFailed(String metaDataDir, String error) {
    final task = _find(metaDataDir);
    if (task == null) return;
    task.status = RunningTaskStatus.failed;
    task.errorMessage = error;
    _bumpEvent();
    debugPrint('[RUNNING-TASKS] ❌ 任务失败: ${task.title} | $error');
    _ensureTicker();
    notifyListeners();
  }

  /// 注册表确认游戏进程已存活 → 切到 running 并开始墙钟计时
  void _onSessionConfirmed(
      String gameTitle, String metaDataDir, int? pid) {
    // 手柄适配协调器（gamepad_adaptation_coordinator.dart）：
    // 按会话启停手柄→键盘/鼠标映射。内部全 try-catch，绝不影响启动主流程。
    GamepadAdaptationCoordinator.instance.onSessionConfirmed(
        gameTitle: gameTitle, metaDataDir: metaDataDir, pid: pid);

    final task = _find(metaDataDir);
    if (task == null) {
      // 会话由外部路径创建（如崩溃恢复）但没有对应任务，补建一条
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      if (game == null) return;
      final created = RunningTask(metaDataDir: metaDataDir, game: game)
        ..status = RunningTaskStatus.running
        ..runningSince = DateTime.now();
      _tasks.add(created);
      _bumpEvent();
      _ensureTicker();
      notifyListeners();
      return;
    }
    if (task.status == RunningTaskStatus.running) return;
    task.status = RunningTaskStatus.running;
    task.runningSince ??= DateTime.now();
    _bumpEvent();
    debugPrint('[RUNNING-TASKS] ▶️ 任务运行中: ${task.title}');
    _ensureTicker();
    notifyListeners();
  }

  /// 解除监控：放弃时长统计，游戏继续独立运行
  ///
  /// 会话会以 exit_reason='manual' 正常落盘（已产生的时长不丢），
  /// 只是不再继续追踪。横幅随即移除。
  Future<void> detach(String metaDataDir) async {
    final task = _find(metaDataDir);
    if (task == null) return;
    if (!_busy.add(metaDataDir)) return;

    final seconds = task.elapsedSeconds(DateTime.now());
    task.status = RunningTaskStatus.exiting;
    task.exitedAt = DateTime.now();
    task.finalSeconds = seconds;
    notifyListeners();

    try {
      await LocalGameRegistry.instance.stopTracking(metaDataDir);
    } catch (e) {
      debugPrint('[RUNNING-TASKS] ⚠️ 解除监控异常: $e');
    } finally {
      _busy.remove(metaDataDir);
    }

    _scheduleFadeOut(metaDataDir);
    debugPrint('[RUNNING-TASKS] 🔓 已解除监控: ${task.title}');
  }

  /// 关闭游戏：终止游戏进程树，并结束时长追踪
  Future<void> kill(String metaDataDir) async {
    final task = _find(metaDataDir);
    if (task == null) return;
    if (!_busy.add(metaDataDir)) return;

    final seconds = task.elapsedSeconds(DateTime.now());
    task.status = RunningTaskStatus.closing;
    notifyListeners();

    try {
      await LocalGameRegistry.instance.terminateGame(metaDataDir);
    } catch (e) {
      debugPrint('[RUNNING-TASKS] ⚠️ 关闭游戏异常: $e');
    } finally {
      _busy.remove(metaDataDir);
    }

    task.finalSeconds = seconds;
    _scheduleFadeOut(metaDataDir);
    debugPrint('[RUNNING-TASKS] ⛔ 已关闭游戏: ${task.title}');
  }

  /// 手动关闭一条横幅（用于 failed 常驻提示，或提前收起 exiting 提示）
  void dismiss(String metaDataDir) {
    _scheduleFadeOut(metaDataDir);
  }

  /// 安排一条横幅淡出：先置 [RunningTask.fading] 让 UI 播放退场动画，
  /// [fadeOutDuration] 后才真正从列表移除
  ///
  /// 幂等：已在淡出中的任务重复调用不会叠加定时器。
  void _scheduleFadeOut(String metaDataDir) {
    final task = _find(metaDataDir);
    if (task == null || task.fading) {
      // 任务已不在列表（可能已被移除），仍需兜底清理
      if (task == null) _removeNow(metaDataDir);
      return;
    }
    task.fading = true;
    notifyListeners();
    Future<void>.delayed(fadeOutDuration, () => _removeNow(metaDataDir));
  }

  void _removeNow(String metaDataDir) {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.metaDataDir == metaDataDir);
    if (_tasks.length == before) return;
    _ensureTicker();
    notifyListeners();
  }

  RunningTask? _find(String metaDataDir) {
    for (final t in _tasks) {
      if (t.metaDataDir == metaDataDir) return t;
    }
    return null;
  }

  /// 1s 心跳：驱动时长刷新 + 检测会话消失 + 回收淡出到期的横幅
  ///
  /// 「会话消失」这里用轮询而非回调：`onGameSessionEnded` 是单一回调字段，
  /// 已被托盘服务占用，覆盖它会静默破坏托盘的退出通知。
  void _ensureTicker() {
    if (_tasks.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    if (_ticker != null && _ticker!.isActive) return;
    _ticker = Timer.periodic(debugTickInterval, (_) => _onTick());
  }

  void _onTick() {
    if (_tasks.isEmpty) {
      _ensureTicker();
      return;
    }

    final now = DateTime.now();
    Set<String> active;
    try {
      active = LocalGameRegistry.instance.activeSessionDirs;
    } catch (_) {
      active = <String>{};
    }

    final expired = <String>[];
    for (final task in _tasks) {
      // 淡出中的任务不再参与状态判定，等它自己的移除定时器生效
      if (task.fading) continue;

      // 0) 启动超时兜底 → 转失败提示，避免横幅永久停在「正在启动…」
      if (task.status == RunningTaskStatus.launching &&
          now.difference(task.createdAt) >= debugLaunchTimeout) {
        task.status = RunningTaskStatus.failed;
        task.errorMessage = '启动超时，未检测到游戏进程';
        _bumpEvent();
        debugPrint('[RUNNING-TASKS] ⏱️ 启动超时: ${task.title}');
        continue;
      }

      // 1) 会话已消失 → 游戏已退出，展示本次总时长
      //    closing 状态由 kill() 自己收尾，不在此处理，避免二次转换
      if ((task.status == RunningTaskStatus.running ||
              task.status == RunningTaskStatus.launching) &&
          !active.contains(task.metaDataDir)) {
        task.status = RunningTaskStatus.exiting;
        task.exitedAt = now;
        task.finalSeconds = task.elapsedSeconds(now);
        _bumpEvent();
        debugPrint(
            '[RUNNING-TASKS] 🚪 游戏已退出: ${task.title} | 本次 ${task.finalSeconds}s');
        continue;
      }

      // 2) exiting 保留期满 → 安排淡出回收
      if (task.status == RunningTaskStatus.exiting && task.exitedAt != null) {
        if (now.difference(task.exitedAt!) >= debugExitBannerDuration) {
          expired.add(task.metaDataDir);
        }
      }
    }

    for (final dir in expired) {
      _scheduleFadeOut(dir);
    }

    _ensureTicker();
    notifyListeners();
  }

  /// 仅供测试：重置为初始状态
  @visibleForTesting
  static void resetForTest() {
    instance._ticker?.cancel();
    instance._ticker = null;
    instance._tasks.clear();
    instance._busy.clear();
    instance._initialized = false;
    instance._bannerEventEpoch = 0;
  }
}
