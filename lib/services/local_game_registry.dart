import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'game_launcher_detector.dart';
import 'game_data_format.dart';
import 'locale_service.dart';
import 'magpie_service.dart';
import 'save_scanner.dart';
import 'manifest_service.dart';
import 'save_backup_service.dart';
import 'shortcut_service.dart'; // ★ H7/H8: 快捷方式清理与更新
import 'foreground_window_service.dart'; // ★ v2: 前台窗口检测（FFI）
import 'win32_process_service.dart'; // ★ 重构: Win32 进程操作 FFI（替代 PowerShell/tasklist）
import 'game_launch_logger.dart'; // ★ 游戏启动流程日志
import 'package:shared_preferences/shared_preferences.dart'; // ★ v2: 追踪模式持久化
import '../core/path_helper.dart';

/// UX-34: 注册表变更原因，用于区分全量重建与轻量更新
/// - structural: 结构性变化（新增/删除/扫描/标题修改）→ 需要全量 rebuild
/// - playTimeUpdate: 仅游玩时长变化（30s 周期）→ 不触发全量 rebuild
enum RegistryChangeReason { structural, playTimeUpdate }

enum PlayStatus { notStarted, inProgress, dropped, completed }

extension PlayStatusUI on PlayStatus {
  IconData get icon {
    switch (this) {
      case PlayStatus.notStarted:
        return Icons.radio_button_unchecked;
      case PlayStatus.inProgress:
        return Icons.play_circle_outline;
      case PlayStatus.dropped:
        return Icons.exit_to_app;
      case PlayStatus.completed:
        return Icons.emoji_events;
    }
  }

  String get label {
    switch (this) {
      case PlayStatus.notStarted:
        return '未入坑';
      case PlayStatus.inProgress:
        return '游玩中';
      case PlayStatus.dropped:
        return '已弃坑';
      case PlayStatus.completed:
        return '已通关';
    }
  }

  String get jsonKey {
    switch (this) {
      case PlayStatus.notStarted:
        return 'not_started';
      case PlayStatus.inProgress:
        return 'in_progress';
      case PlayStatus.dropped:
        return 'dropped';
      case PlayStatus.completed:
        return 'completed';
    }
  }

  Color get color {
    switch (this) {
      case PlayStatus.notStarted:
        return Colors.grey;
      case PlayStatus.inProgress:
        return Colors.green;
      case PlayStatus.dropped:
        return Colors.orange;
      case PlayStatus.completed:
        return const Color(0xFFD4A017);
    }
  }
}

enum GameMark { none, star, favorite }

/// ★ v2 时长追踪模式（借鉴 ReinaManager TimeTrackingMode）
enum TimeTrackingMode {
  /// 精准模式：仅前台时间计时（playtime）
  /// 游戏窗口在前台时才累加时长，切出后停止计时
  playtime,

  /// 宽松模式：从启动到退出的墙钟时长（elapsed）
  /// 存活即累加，不依赖前台检测
  elapsed,
}

/// 游戏会话追踪信息（v2：全过程精准统计）
///
/// 时长追踪核心不变量：
///   accumulatedSeconds == 已成功写入磁盘的本会话秒数
///   pendingDelta == lastConfirmedAliveTime - lastSettledTime
///                   （已确认存活但未落盘的秒数，正常 ≤ 10s）
///
/// 时长只在"tasklist 成功 + 进程确认存活"时累加，彻底消除幽灵累加。
/// playtime 模式下还需 isForeground == true 才累加。
///
/// ★ 重构（基于 ReinaManager 架构）：
/// - 移除 isForeground/lastForegroundTime/lastBackgroundTime/lastConfirmedAliveTime
///   （前台状态迁移到 _ForegroundState 共享状态，由 500ms 前台定时器更新）
/// - launchedPid 合并到 bestPid
/// - FFI 存活检测是同步的，无需 lastConfirmedAliveTime
class _GameSession {
  final DateTime startTime;
  final String gameTitle; // 游戏标题
  final String metaDataDir; // 元数据目录（写入game.json用）
  final String directoryPath; // 游戏安装目录（逃逸进程检测+自动备份用）
  final String? primaryExe; // 用户启动的主 exe 名称（进程检测主指标）(C7)
  final Set<String> monitoredExes; // 需要监控的 exe 名称集合（子进程检测用）
  final TimeTrackingMode trackingMode; // ★ v2: 追踪模式

  // ═══ 时长累加状态（仅在确认存活时累加）═══
  DateTime lastSettledTime; // 上次已落盘的时间点
  int accumulatedSeconds; // 本次会话已落盘的总秒数

  // ═══ 进程检测状态 ═══
  int? bestPid; // ★ 重构: 主追踪 PID（合并自 launchedPid，对应 ReinaManager 的 process_id）
  Set<int> candidatePids; // ★ v2: 候选进程 PID 集合（解决启动器型游戏+逃逸进程）
  int missCount; // 连续未检测到进程的次数
  int consecutiveWriteFails; // 连续写入失败次数
  bool backupTriggered; // 是否已触发自动备份

  // ═══ ★ v3 阶段 2：会话事实表相关字段 ═══
  /// 会话唯一标识（UUID v4），用于持久化到 game.json 的 sessions 数组
  /// 保证每次会话都是一条独立、不可变的事实记录
  final String sessionId;

  /// 会话退出原因，用于审计和数据质量分析
  /// 取值：normal | crash | manual | app_shutdown | recovered | aborted
  /// - normal: 进程自然退出（missCount 达阈值）
  /// - crash: Chrono Tide 崩溃后由 recoverPendingSessions 恢复
  /// - manual: 用户手动停止
  /// - app_shutdown: 应用正常退出时结算
  /// - recovered: 崩溃恢复创建的会话
  /// - aborted: 误启动过滤（< 60s）
  String exitReason;

  _GameSession({
    required this.startTime,
    required this.gameTitle,
    required this.metaDataDir,
    required this.directoryPath,
    required this.monitoredExes,
    required this.trackingMode,
    this.bestPid,
    this.primaryExe,
    String? sessionId,
  })  : lastSettledTime = startTime,
        candidatePids = <int>{},
        missCount = 0,
        accumulatedSeconds = 0,
        consecutiveWriteFails = 0,
        backupTriggered = false,
        sessionId = sessionId ?? _generateSessionId(),
        exitReason = 'normal';

  /// 生成会话记录 Map（用于持久化到 game.json 的 sessions 数组）
  /// 调用方需在会话结束时设置 exitReason 后再调用此方法。
  Map<String, dynamic> toSessionRecord() {
    return {
      'session_id': sessionId,
      'start_time': startTime.toIso8601String(),
      'end_time': DateTime.now().toIso8601String(),
      'duration_seconds': accumulatedSeconds,
      'tracking_mode':
          trackingMode == TimeTrackingMode.playtime ? 'playtime' : 'elapsed',
      'exit_reason': exitReason,
    };
  }
}

/// ★ 重构: 前台状态共享类（从 _GameSession 分离）
///
/// 对应 ReinaManager 的 MonitorState（仅 is_foreground + best_pid 两个字段）。
/// 由 500ms 前台定时器更新，主监控定时器（2s）只读取。
/// 分离的原因：前台检测频率（500ms）远高于时长累加频率（2s），
/// 将前台状态放在独立对象中避免 _GameSession 被高频修改。
class _ForegroundState {
  final String gameDir; // 游戏目录（逃逸检测用）
  bool isForeground; // 当前游戏窗口是否在前台
  _ForegroundState(this.gameDir, Set<int> candidatePids) : isForeground = false;
}

/// 生成 UUID v4 格式的会话 ID
/// 不依赖第三方库，使用 dart:math Random + 时间戳保证唯一性
/// 格式：xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx（y ∈ {8,9,a,b}）
String _generateSessionId() {
  final rng = math.Random();
  // 生成 16 字节 = 32 hex 字符
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // 设置 version (4) 和 variant (8/9/a/b)
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xxxxxx
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}

class LibraryGame {
  String title;
  String directoryPath;
  String metaDataDir;
  String installedAt;
  String coverUrl;
  String description;
  List<String> tags;
  GameMark mark;
  String launchPath;
  String source;
  String developer;
  PlayStatus playStatus;
  int playTime;
  bool isBlurred;
  String firstOpenedAt;
  String lastOpenedAt;
  List<String> screenshotFiles;
  // ===== 截图异步抓取相关字段 =====
  // 原始截图URL列表（来自元数据源，用于后台下载）
  List<String> screenshotUrls;
  // 截图下载状态：pending | downloading | completed | failed
  String screenshotStatus;
  // 失败重试次数
  int screenshotRetryCount;
  // 元数据源（如 VNDB/Bangumi）与源内 ID，用于 ImportDedupIndex 源 ID 排重维度
  String metadataSource;
  String metadataSourceId;

  LibraryGame({
    required this.title,
    required this.directoryPath,
    required this.metaDataDir,
    required this.installedAt,
    this.coverUrl = '',
    this.description = '',
    this.tags = const [],
    this.mark = GameMark.none,
    this.launchPath = '',
    this.source = 'download',
    this.developer = '',
    this.playStatus = PlayStatus.notStarted,
    this.playTime = 0,
    this.isBlurred = false,
    this.firstOpenedAt = '',
    this.lastOpenedAt = '',
    this.screenshotFiles = const [],
    this.screenshotUrls = const [],
    this.screenshotStatus = 'completed',
    this.screenshotRetryCount = 0,
    this.metadataSource = '',
    this.metadataSourceId = '',
  });

  String get coverPath => coverUrl;

  String get pathForCover =>
      metaDataDir.isNotEmpty ? metaDataDir : directoryPath;

  String get playStatusString {
    switch (playStatus) {
      case PlayStatus.notStarted:
        return 'not_started';
      case PlayStatus.inProgress:
        return 'in_progress';
      case PlayStatus.dropped:
        return 'dropped';
      case PlayStatus.completed:
        return 'completed';
    }
  }
}

/// 更换游戏目录的结果
class RelinkResult {
  /// 是否成功
  final bool success;

  /// 新游戏目录路径
  final String newDirectoryPath;

  /// 最终写入 game.json 的 launchPath（相对新目录，或绝对路径）
  final String newLaunchPath;

  /// 是否触发了 GameLauncherDetector 自动检测（旧 launchPath 在新目录失效时为 true）
  final bool wasDetected;

  /// 失败时的错误信息
  final String? errorMessage;

  const RelinkResult({
    required this.success,
    required this.newDirectoryPath,
    required this.newLaunchPath,
    required this.wasDetected,
    this.errorMessage,
  });
}

class LocalGameRegistry extends ChangeNotifier {
  static final LocalGameRegistry _instance = LocalGameRegistry._internal();
  static LocalGameRegistry get instance => _instance;

  LocalGameRegistry._internal();

  static final String _gamesBaseDir = PathHelper.gamesDir;
  static String get gamesBaseDir => _gamesBaseDir;

  final Map<String, LibraryGame> _games = {};
  final Set<String> _installedTitles = {};

  /// UX-34: 最近一次变更原因，供监听方区分处理
  RegistryChangeReason _lastChangeReason = RegistryChangeReason.structural;
  RegistryChangeReason get lastChangeReason => _lastChangeReason;

  /// UX-34: 结构性变更通知（新增/删除/扫描/标题修改）
  void _notifyStructural() {
    _lastChangeReason = RegistryChangeReason.structural;
    notifyListeners();
  }

  /// UX-34: 游玩时长轻量更新通知（30s 周期，不触发全量 rebuild）
  void _notifyPlayTimeUpdate() {
    _lastChangeReason = RegistryChangeReason.playTimeUpdate;
    notifyListeners();
  }

  /// 截图下载完成后的轻量更新通知
  ///
  /// 由 ScreenshotFetchService 在截图下载完成后调用，
  /// 触发库页面/详情页刷新截图展示。
  /// 使用 structural 类型以确保截图区域重建。
  void notifyListenersForScreenshot() {
    _lastChangeReason = RegistryChangeReason.structural;
    notifyListeners();
  }

  /// 游戏被删除时的回调（供 ScreenshotFetchService 注册以清理进度）
  ///
  /// 避免循环依赖：LocalGameRegistry 不直接依赖 ScreenshotFetchService，
  /// 而是通过此回调让 ScreenshotFetchService 自行清理已删除游戏的进度。
  void Function(String gameTitle)? onGameRemoved;

  List<LibraryGame> get allGames {
    final list = _games.values.toList();
    list.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return list;
  }

  int get gameCount => _games.length;

  Map<String, LibraryGame> get gamesMap => Map.unmodifiable(_games);
  Set<String> get installedTitles => Set.unmodifiable(_installedTitles);

  bool isTitleInstalled(String title) {
    if (title.isEmpty) return false;
    // 通过 getGameByTitle 查找，兼容标题已被修改的情况
    return getGameByTitle(title) != null;
  }

  bool isGameIdInstalled(String gameId) {
    return _games.containsKey(gameId);
  }

  LibraryGame? getGameByTitle(String title) {
    if (title.isEmpty) return null;
    // 遍历查找：标题可能已被修改，safeName 不一定等于 dirName（_games 的 key）
    for (final game in _games.values) {
      if (game.title == title) return game;
    }
    // 回退：尝试用 safeName 直接索引（兼容标题未被修改的情况）
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return _games[safeName];
  }

  bool isMarked(String title) {
    final game = getGameByTitle(title);
    return game?.mark != GameMark.none;
  }

  void toggleMark(String title) {
    final game = getGameByTitle(title);
    if (game == null) return;

    final beforeLen = _games.length;
    game.mark = game.mark == GameMark.star ? GameMark.none : GameMark.star;
    final afterLen = _games.length;

    assert(
        beforeLen == afterLen, '[标记] ❌ 严重错误！标记后卡片数量变化: $beforeLen → $afterLen');

    debugPrint(
        '[标记] 已修改原对象: ${game.title}，标记状态: ${game.mark == GameMark.star}');

    _persistMarkToGameJson(game);
  }

  Future<void> _persistMarkToGameJson(LibraryGame game) async {
    try {
      final markStr = game.mark == GameMark.star
          ? 'star'
          : game.mark == GameMark.favorite
              ? 'favorite'
              : 'none';
      await GameDataFormat.updateGameJson(game.metaDataDir, {'mark': markStr});
    } catch (e) {
      debugPrint('[标记] ⚠️ 持久化标记失败: $e');
    }
  }

  void _removeByDirName(String dirName) {
    final exactMatch = _games.keys.firstWhere(
      (k) => k == dirName,
      orElse: () => '',
    );

    if (exactMatch.isNotEmpty) {
      _games.remove(exactMatch);
      _installedTitles.remove(exactMatch);
      debugPrint('[删除]   ✅ 精确移除: "$exactMatch"');
      _notifyStructural();
    } else {
      debugPrint('[删除]   ⚠️ 未找到精确匹配: "$dirName"');
    }
  }

  Future<int> refreshStaleEntries() async {
    int removedCount = 0;
    final staleKeys = <String>[];

    for (final entry in _games.entries.toList()) {
      final dir = Directory(entry.value.directoryPath);
      try {
        if (!await dir.exists()) {
          staleKeys.add(entry.key);
          continue;
        }

        final ctgameFile = File('${dir.path}/${GameDataFormat.ctgameFileName}');
        if (!await ctgameFile.exists()) {
          staleKeys.add(entry.key);
        }
      } catch (e) {
        staleKeys.add(entry.key);
      }
    }

    for (final key in staleKeys) {
      final game = _games[key];
      _games.remove(key);
      _installedTitles.remove(key);
      removedCount++;
      debugPrint(
          '[LOCAL-REGISTRY] 🗑️ 清除失效条目: ${game?.title ?? key} (磁盘文件已删除)');
    }

    if (removedCount > 0) {
      debugPrint(
          '[LOCAL-REGISTRY] 刷新完成: 清除 $removedCount 个失效条目, 剩余 ${_games.length} 个');
      _notifyStructural();
    }
    return removedCount;
  }

  Future<void> scan() async {
    debugPrint('[LOCAL-REGISTRY] ========== 开始智能增量扫描 ==========');
    debugPrint('[LOCAL-REGISTRY] 扫描目标目录: $_gamesBaseDir');
    debugPrint('[LOCAL-REGISTRY] 当前内存中已有: ${_games.length} 个游戏');

    try {
      final gamesDir = Directory(_gamesBaseDir);
      if (!await gamesDir.exists()) {
        debugPrint('[LOCAL-REGISTRY] ❌ 目录不存在: ${PathHelper.gamesDir}');
        try {
          await gamesDir.create(recursive: true);
        } catch (e) {}
        return;
      }

      final entities = await gamesDir.list(followLinks: false).toList();
      int dirCount = entities.where((e) => e is Directory).length;
      int foundCount = 0;
      int updatedCount = 0;
      int skipCount = 0;

      final scannedDirNames = <String>{};

      for (final entity in entities) {
        if (entity is! Directory) continue;

        final dirName = entity.path.split('/').last.split('\\').last;

        if (dirName.contains('_temp_layer_') || dirName.startsWith('.')) {
          skipCount++;
          continue;
        }

        scannedDirNames.add(dirName);

        // ★ H9: 每个游戏的处理独立 try-catch，避免单个坏文件中断整个扫描
        try {
          final hasCtgame =
              await File('${entity.path}/${GameDataFormat.ctgameFileName}')
                  .exists();

          if (!hasCtgame) {
            skipCount++;
            continue;
          }

          if (_games.containsKey(dirName)) {
            final existingGame = _games[dirName]!;

            final gameData = await GameDataFormat.readGameJson(entity.path);
            if (gameData != null) {
              existingGame.title =
                  gameData.title.isNotEmpty ? gameData.title : dirName;
              existingGame.description = gameData.description;
              existingGame.launchPath = gameData.launchPath;
              existingGame.source = gameData.source;
              existingGame.mark = _parseMark(gameData.mark);
              existingGame.developer = gameData.developer;
              existingGame.playStatus = _parsePlayStatus(gameData.playStatus);

              // ★ 活跃会话保护：游戏运行期间 scan() 不得覆盖正在累加的
              // playTime/firstOpenedAt/lastOpenedAt（RC2）
              final hasActiveSession =
                  _activeGameSessions.containsKey(existingGame.metaDataDir);
              if (!hasActiveSession) {
                existingGame.playTime = gameData.playTime;
                existingGame.firstOpenedAt = gameData.firstOpenedAt;
                existingGame.lastOpenedAt = gameData.lastOpenedAt;
              }

              existingGame.isBlurred = gameData.isBlurred;

              // 截图相关字段同步
              existingGame.screenshotFiles = gameData.screenshotFiles;
              existingGame.screenshotUrls = gameData.screenshotUrls;
              existingGame.screenshotStatus = gameData.screenshotStatus;
              existingGame.screenshotRetryCount = gameData.screenshotRetryCount;

              if (gameData.tags.isNotEmpty) {
                existingGame.tags = gameData.tags;
              }

              if (gameData.directoryPath.isNotEmpty) {
                existingGame.directoryPath = gameData.directoryPath;
              }

              final coverFile = GameDataFormat.findCoverFile(entity.path);
              if (coverFile != null) {
                existingGame.coverUrl = coverFile.path;
              }

              updatedCount++;
            }
            foundCount++;
            continue;
          }

          final gameData = await GameDataFormat.readGameJson(entity.path);
          if (gameData != null) {
            final coverFile = GameDataFormat.findCoverFile(entity.path);

            final game = LibraryGame(
              title: gameData.title.isNotEmpty ? gameData.title : dirName,
              directoryPath: gameData.directoryPath.isNotEmpty
                  ? gameData.directoryPath
                  : entity.path,
              metaDataDir: entity.path,
              installedAt: gameData.installedAt.isNotEmpty
                  ? gameData.installedAt
                  : DateTime.now().toIso8601String(),
              coverUrl: coverFile?.path ?? '',
              description: gameData.description,
              tags: gameData.tags,
              launchPath: gameData.launchPath,
              mark: _parseMark(gameData.mark),
              source: gameData.source,
              developer: gameData.developer,
              playStatus: _parsePlayStatus(gameData.playStatus),
              playTime: gameData.playTime,
              isBlurred: gameData.isBlurred,
              firstOpenedAt: gameData.firstOpenedAt,
              lastOpenedAt: gameData.lastOpenedAt,
              screenshotFiles: gameData.screenshotFiles,
              screenshotUrls: gameData.screenshotUrls,
              screenshotStatus: gameData.screenshotStatus,
              screenshotRetryCount: gameData.screenshotRetryCount,
              metadataSource: gameData.metadataSource,
              metadataSourceId: gameData.metadataSourceId,
            );

            _games[dirName] = game;
            _installedTitles.add(dirName);
            foundCount++;

            debugPrint(
                '[LOCAL-REGISTRY] ✅ 发现新游戏 [$foundCount]: $dirName | "${game.title}" | source=${game.source}');
          }
        } catch (e) {
          // ★ H9: 单个 game.json 异常不中断整个扫描
          debugPrint('[LOCAL-REGISTRY] ⚠️ 扫描 "$dirName" 时异常: $e，跳过');
        }
      }

      final staleKeys =
          _games.keys.where((k) => !scannedDirNames.contains(k)).toList();
      for (final key in staleKeys) {
        final game = _games[key];
        if (game == null) continue;
        final dir = Directory(game.directoryPath);
        if (!await dir.exists()) {
          _games.remove(key);
          _installedTitles.remove(key);
          // ★ H6: 清理已删除游戏的活跃会话（★ v3 阶段 4: 含定时器）
          _cleanupSession(game.metaDataDir);
          debugPrint(
              '[LOCAL-REGISTRY] 🗑️ 移除失效游戏: ${game?.title ?? key} (目录不存在)');
        }
      }

      debugPrint('[LOCAL-REGISTRY] ════════════════════════════════');
      debugPrint(
          '[LOCAL-REGISTRY] 扫描完成 | 子目录: $dirCount | 新增: $foundCount | 更新: $updatedCount | 清理失效: ${staleKeys.length} | 当前内存: ${_games.length}');
      debugPrint('[LOCAL-REGISTRY] ════════════════════════════════');
      if (foundCount > 0 || staleKeys.length > 0) {
        _notifyStructural();
      }
    } catch (e, stackTrace) {
      debugPrint('[LOCAL-REGISTRY] ❌ 扫描异常: $e');
    }

    debugPrint('[LOCAL-REGISTRY] ========== 智能增量扫描结束 ==========');
  }

  GameMark _parseMark(String markStr) {
    switch (markStr) {
      case 'star':
        return GameMark.star;
      case 'favorite':
        return GameMark.favorite;
      default:
        return GameMark.none;
    }
  }

  PlayStatus _parsePlayStatus(String statusStr) {
    switch (statusStr) {
      case 'in_progress':
        return PlayStatus.inProgress;
      case 'dropped':
        return PlayStatus.dropped;
      case 'completed':
        return PlayStatus.completed;
      default:
        return PlayStatus.notStarted;
    }
  }

  void registerExtractionComplete({
    required String gameTitle,
    required String directoryPath,
    String? coverUrl,
    String? description,
    List<String>? tags,
    String? launchPath,
    String? developer,
    String? playStatus,
    String? metadataSource,
    String? metadataSourceId,
  }) {
    final safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final metaDataDir = '${LocalGameRegistry.gamesBaseDir}/$safeName';

    if (coverUrl == null || coverUrl.isEmpty) {
      final detectedCover = GameDataFormat.findCoverFile(directoryPath);
      if (detectedCover != null) {
        coverUrl = detectedCover.path;
        debugPrint('[LOCAL-REGISTRY] 自动检测到封面: $coverUrl');
      }
    }

    if (_games.containsKey(safeName)) {
      debugPrint('[LOCAL-REGISTRY] 📝 游戏已存在于库中，原地更新信息: $gameTitle');
      final existing = _games[safeName]!;
      existing.title = gameTitle;
      existing.directoryPath = directoryPath;
      existing.metaDataDir = metaDataDir;
      existing.installedAt = DateTime.now().toIso8601String();
      if (coverUrl != null) existing.coverUrl = coverUrl;
      if (description != null) existing.description = description;
      if (tags != null) existing.tags = tags;
      if (launchPath != null && launchPath!.isNotEmpty) {
        existing.launchPath = launchPath!;
      }
      if (developer != null) existing.developer = developer!;
      // 元数据源：仅在传入非空值时覆盖，避免原地更新清空已有排重信息
      if (metadataSource != null && metadataSource!.isNotEmpty) {
        existing.metadataSource = metadataSource!;
      }
      if (metadataSourceId != null && metadataSourceId!.isNotEmpty) {
        existing.metadataSourceId = metadataSourceId!;
      }
    } else {
      final game = LibraryGame(
        title: gameTitle,
        directoryPath: directoryPath,
        metaDataDir: metaDataDir,
        installedAt: DateTime.now().toIso8601String(),
        coverUrl: coverUrl ?? '',
        description: description ?? '',
        tags: tags ?? [],
        launchPath: launchPath ?? '',
        developer: developer ?? '',
        playStatus: _parsePlayStatus(playStatus ?? 'not_started'),
        metadataSource: metadataSource ?? '',
        metadataSourceId: metadataSourceId ?? '',
      );
      _games[safeName] = game;
      _installedTitles.add(safeName);
      debugPrint(
          '[LOCAL-REGISTRY] 📝 注册新安装游戏到本地库: $gameTitle → $directoryPath');
    }
    _notifyStructural();
  }

  /// 更新活跃会话的监控exe列表（游戏位置或启动程序变更后调用）
  Future<void> refreshActiveSessionExes(String gameTitle) async {
    final game = getGameByTitle(gameTitle);
    if (game == null) return;

    final session = _activeGameSessions[game.metaDataDir];
    if (session == null) return;

    // 重新扫描游戏目录中的exe文件
    final newExes = await _scanGameExes(
      game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
      launchedExe:
          game.launchPath.isNotEmpty ? p.basename(game.launchPath) : null,
    );

    // 更新会话的monitoredExes
    session.monitoredExes.clear();
    session.monitoredExes.addAll(newExes);

    debugPrint('[PLAYTIME] 🔄 已刷新活跃会话监控列表: $gameTitle | exes: $newExes');
  }

  Future<void> updateLauncherPath(String title, String newLaunchPath) async {
    final game = getGameByTitle(title);
    if (game != null) {
      // 使用 directoryPath 作为相对路径基准，与 resolveLaunchPath 保持一致
      final relativePath = _toRelative(newLaunchPath, game.directoryPath);
      game.launchPath = relativePath.isNotEmpty ? relativePath : newLaunchPath;

      await GameDataFormat.updateGameJson(
          game.metaDataDir, {'launch_path': game.launchPath});

      // 刷新活跃会话的监控exe列表
      await refreshActiveSessionExes(title);

      debugPrint('[LOCAL-REGISTRY] ✅ 已更新启动路径: $title → ${game.launchPath}');
    } else {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新启动路径失败: 未找到游戏 $title');
    }
  }

  Future<void> updateGameLocation({
    required String gameTitle,
    required String newDirectoryPath,
  }) async {
    final game = getGameByTitle(gameTitle);
    if (game != null) {
      final oldDirectoryPath = game.directoryPath;

      // 重新计算 launchPath：不使用 resolveLaunchPath（它会检查文件是否存在，
      // 移动是复制而非剪切，旧文件仍存在会导致返回旧位置的绝对路径）
      if (game.launchPath.isNotEmpty) {
        // 直接构造旧绝对路径（不检查文件是否存在）
        String oldAbsoluteLaunchPath;
        if (p.isAbsolute(game.launchPath)) {
          oldAbsoluteLaunchPath = game.launchPath;
        } else {
          oldAbsoluteLaunchPath = p.join(oldDirectoryPath, game.launchPath);
        }

        // 从旧目录中提取相对部分
        final relativePart =
            _toRelative(oldAbsoluteLaunchPath, oldDirectoryPath);

        if (relativePart != oldAbsoluteLaunchPath) {
          // 启动程序在旧目录下，保留相对路径部分
          // （新目录结构相同，相对路径仍然有效）
          game.launchPath = relativePart;
        } else {
          // 启动程序不在旧目录下，尝试转为相对新目录的路径
          final newRelativePath =
              _toRelative(oldAbsoluteLaunchPath, newDirectoryPath);
          game.launchPath = newRelativePath.isNotEmpty
              ? newRelativePath
              : oldAbsoluteLaunchPath;
        }
      }

      game.directoryPath = newDirectoryPath;

      await GameDataFormat.updateGameJson(
        game.metaDataDir,
        {
          'directory_path': newDirectoryPath,
          'launch_path': game.launchPath,
        },
      );

      // 刷新活跃会话的监控exe列表
      await refreshActiveSessionExes(gameTitle);

      debugPrint('[LOCAL-REGISTRY] ✅ 已更新游戏位置: $gameTitle');
      debugPrint('[LOCAL-REGISTRY]   旧位置: $oldDirectoryPath');
      debugPrint('[LOCAL-REGISTRY]   新位置: $newDirectoryPath');
      debugPrint('[LOCAL-REGISTRY]   启动路径: ${game.launchPath}');
    } else {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新游戏位置失败: 未找到游戏 $gameTitle');
    }
  }

  String _toRelative(String absoluteOrRelativePath, String baseDir) {
    if (absoluteOrRelativePath.isEmpty) return '';
    var normalized = absoluteOrRelativePath.replaceAll('/', '\\');
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
    return absoluteOrRelativePath;
  }

  /// 更换游戏目录：用户已在资源管理器里手动挪完文件夹，软件只改路径引用、不复制文件。
  ///
  /// 与 [updateGameLocation] 的关键差异：
  /// - **新目录必须已存在**（relink 不创建目录）
  /// - 用 [GameDataFormat.resolveLaunchPath] 验证旧 launchPath 在新目录是否仍可用
  /// - 失效时调用 [GameLauncherDetector.detect] 兜底，找新目录里最大的 exe 设为新 launchPath
  /// - 返回 [RelinkResult]，让 UI 层知道是否触发了自动检测（提示用户可在启动管理调整）
  Future<RelinkResult> relinkGameLocation({
    required String gameTitle,
    required String newDirectoryPath,
  }) async {
    final game = getGameByTitle(gameTitle);
    if (game == null) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更换游戏目录失败: 未找到游戏 $gameTitle');
      return RelinkResult(
        success: false,
        newDirectoryPath: newDirectoryPath,
        newLaunchPath: '',
        wasDetected: false,
        errorMessage: '未找到游戏 $gameTitle',
      );
    }

    // ① 硬要求：新目录必须存在（relink 不创建目录）
    final newDir = Directory(newDirectoryPath);
    if (!await newDir.exists()) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更换游戏目录失败: 目录不存在 $newDirectoryPath');
      return RelinkResult(
        success: false,
        newDirectoryPath: newDirectoryPath,
        newLaunchPath: '',
        wasDetected: false,
        errorMessage: '目录不存在: $newDirectoryPath',
      );
    }

    final oldDirectoryPath = game.directoryPath;
    final oldLaunchPath = game.launchPath;
    String newLaunchPath = '';
    bool wasDetected = false;

    // ② 尝试复用旧 launchPath：提取相对旧目录的部分，在新目录用 resolveLaunchPath 验证
    if (oldLaunchPath.isNotEmpty) {
      String oldAbsoluteLaunchPath;
      if (p.isAbsolute(oldLaunchPath)) {
        oldAbsoluteLaunchPath = oldLaunchPath;
      } else {
        oldAbsoluteLaunchPath = p.join(oldDirectoryPath, oldLaunchPath);
      }

      final relativePart = _toRelative(oldAbsoluteLaunchPath, oldDirectoryPath);

      if (relativePart != oldAbsoluteLaunchPath) {
        // 启动器原本在游戏目录内 → 在新目录用同一相对路径解析
        final resolved =
            GameDataFormat.resolveLaunchPath(relativePart, newDirectoryPath);
        if (resolved.isNotEmpty) {
          newLaunchPath = relativePart; // 保留相对路径
          debugPrint('[LOCAL-REGISTRY] ✅ 旧 launchPath 在新目录仍可用: $newLaunchPath');
        }
      }
      // 若启动器在游戏目录外（absolute 路径，_toRelative 返回原值）→ 不复用，交给 detector
    }

    // ③ 旧 launchPath 在新目录不可用 → 跑 GameLauncherDetector 兜底
    if (newLaunchPath.isEmpty) {
      debugPrint('[LOCAL-REGISTRY] 🔍 旧 launchPath 在新目录失效，启动自动检测...');
      final detection = await GameLauncherDetector.detect(newDirectoryPath);
      if (detection.success && detection.launcherPath != null) {
        newLaunchPath = _toRelative(detection.launcherPath!, newDirectoryPath);
        if (newLaunchPath.isEmpty) {
          newLaunchPath = detection.launcherPath!;
        }
        wasDetected = true;
        debugPrint(
            '[LOCAL-REGISTRY] ✅ 自动检测到启动程序: ${detection.launcherPath} (relative=$newLaunchPath)');
      } else {
        debugPrint('[LOCAL-REGISTRY] ⚠️ 自动检测未找到启动程序，launchPath 置空，启动时再兜底');
      }
    }

    // ④ 写入 game 对象 + game.json
    game.directoryPath = newDirectoryPath;
    game.launchPath = newLaunchPath;

    await GameDataFormat.updateGameJson(
      game.metaDataDir,
      {
        'directory_path': newDirectoryPath,
        'launch_path': newLaunchPath,
      },
    );

    // ⑤ 刷新活跃会话监控（如有）
    await refreshActiveSessionExes(gameTitle);

    // ⑥ 不调 _notifyStructural —— 复用 move 流程的 then(_silentRefresh) 链路，
    //    库页在对话框关闭后自行刷新，避免对话框开着时触发库页 rebuild

    debugPrint('[LOCAL-REGISTRY] ✅ 更换游戏目录完成: $gameTitle');
    debugPrint('[LOCAL-REGISTRY]   旧目录: $oldDirectoryPath');
    debugPrint('[LOCAL-REGISTRY]   新目录: $newDirectoryPath');
    debugPrint(
        '[LOCAL-REGISTRY]   新 launchPath: $newLaunchPath (detected=$wasDetected)');

    return RelinkResult(
      success: true,
      newDirectoryPath: newDirectoryPath,
      newLaunchPath: newLaunchPath,
      wasDetected: wasDetected,
    );
  }

  /// 更新游戏标题（编辑模式下修改标题后调用）
  /// 同步更新：_games Map key、_installedTitles、元数据文件夹名、metaDataDir、活跃会话
  Future<void> updateGameTitle(String oldTitle, String newTitle) async {
    final game = getGameByTitle(oldTitle);
    if (game == null) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新标题失败: 未找到游戏 $oldTitle');
      return;
    }

    final newSafeName =
        newTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

    // 获取当前 _games 的 key（即 dirName）
    String? currentKey;
    for (final entry in _games.entries) {
      if (entry.value.metaDataDir == game.metaDataDir) {
        currentKey = entry.key;
        break;
      }
    }

    if (currentKey == null) return;

    // 更新 title 字段
    game.title = newTitle;

    // 如果新 safeName 与当前 key 不同，需要重命名元数据文件夹
    if (newSafeName != currentKey) {
      final oldMetaDataDir = game.metaDataDir;
      final newMetaDataDir = '${LocalGameRegistry.gamesBaseDir}/$newSafeName';
      bool renameSucceeded = false;

      // 重命名磁盘上的元数据文件夹
      try {
        final oldDir = Directory(oldMetaDataDir);
        if (await oldDir.exists()) {
          // 检查新名称是否已被占用
          final newDir = Directory(newMetaDataDir);
          if (await newDir.exists()) {
            debugPrint('[LOCAL-REGISTRY] ⚠️ 目标文件夹已存在，无法重命名: $newMetaDataDir');
          } else {
            await oldDir.rename(newMetaDataDir);
            game.metaDataDir = newMetaDataDir;
            renameSucceeded = true;
            debugPrint(
                '[LOCAL-REGISTRY] 📁 元数据文件夹已重命名: $oldMetaDataDir → $newMetaDataDir');
          }
        } else {
          debugPrint('[LOCAL-REGISTRY] ⚠️ 旧元数据目录不存在: $oldMetaDataDir');
        }
      } catch (e) {
        debugPrint('[LOCAL-REGISTRY] ⚠️ 重命名元数据文件夹失败: $e');
      }

      // 只有重命名成功时才更新 _games 的 key 和 _installedTitles
      // 否则 key 应该保持与磁盘目录名一致
      if (renameSucceeded) {
        _games.remove(currentKey);
        _games[newSafeName] = game;
        _installedTitles.remove(currentKey);
        _installedTitles.add(newSafeName);
      }
      // 如果重命名失败，_games 的 key 仍然是 currentKey（旧目录名）
      // game.title 已更新，getGameByTitle 仍能通过遍历找到

      // 更新活跃会话（metaDataDir 可能已变更）
      final session = _activeGameSessions.remove(oldMetaDataDir);
      // ★ v3 阶段 4: 取消旧的定时器，新会话会启动新定时器
      _foregroundCheckTimers[oldMetaDataDir]?.cancel();
      _foregroundCheckTimers.remove(oldMetaDataDir);
      // ★ 重构: 同时迁移前台状态共享 Map
      final fgState = _foregroundStates.remove(oldMetaDataDir);
      if (session != null) {
        // ★ v2: 迁移所有 v2 字段
        final newSession = _GameSession(
          startTime: session.startTime,
          gameTitle: newTitle,
          metaDataDir: game.metaDataDir,
          directoryPath: session.directoryPath, // ★ C6
          trackingMode: session.trackingMode, // ★ v2
          bestPid: session.bestPid, // ★ 重构: launchedPid → bestPid
          primaryExe: session.primaryExe, // ★ C7
          monitoredExes: session.monitoredExes,
        )
          ..accumulatedSeconds = session.accumulatedSeconds
          ..missCount = session.missCount
          ..backupTriggered = session.backupTriggered
          ..consecutiveWriteFails = session.consecutiveWriteFails
          ..lastSettledTime = session.lastSettledTime
          ..candidatePids = session.candidatePids;
        _activeGameSessions[game.metaDataDir] = newSession;
        // ★ 重构: 迁移前台状态到新 metaDataDir
        if (fgState != null) {
          _foregroundStates[game.metaDataDir] = fgState;
        }
        debugPrint('[LOCAL-REGISTRY] 📝 活跃会话已更新: $oldTitle → $newTitle');
      }
    }

    // 更新 game.json 中的标题
    await GameDataFormat.updateGameJson(game.metaDataDir, {
      'title': newTitle,
    });

    // ★ H8: 同步更新桌面快捷方式的 --launch-game 参数
    try {
      await ShortcutService.instance.updateShortcutTitle(oldTitle, newTitle);
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新桌面快捷方式失败: $e');
    }

    _notifyStructural();
    debugPrint('[LOCAL-REGISTRY] ✅ 已更新游戏标题: $oldTitle → $newTitle');
  }

  Future<bool> deleteGame(String title) async {
    final game = getGameByTitle(title);
    if (game == null) {
      debugPrint('[删除] ⚠️ 删除失败: 未找到游戏 | $title');
      return false;
    }

    final dirName = game.directoryPath.split('/').last.split('\\').last;
    final beforeLen = _games.length;
    final beforeTitlesLen = _installedTitles.length;

    debugPrint(
        '[删除] 开始彻底删除游戏: ${game.title} | 本体目录: $dirName | 元数据: ${game.metaDataDir}');

    try {
      // ★ H6: 清理活跃会话（★ v3 阶段 4: 含定时器）
      _cleanupSession(game.metaDataDir);

      // ★ H7: 删除桌面快捷方式
      try {
        await ShortcutService.instance.deleteShortcut(game.title);
      } catch (e) {
        debugPrint('[删除]   ⚠️ 删除快捷方式失败(可忽略): $e');
      }

      final bodyDir = Directory(game.directoryPath);
      if (await bodyDir.exists()) {
        try {
          await bodyDir.delete(recursive: true);
          debugPrint('[删除]   ✅ 已删除游戏本体: ${game.directoryPath}');
        } catch (e) {
          debugPrint('[删除]   ⚠️ 删除本体失败(可能已被手动删除): $e');
        }
      }

      final metaDir = Directory(game.metaDataDir);
      if (await metaDir.exists()) {
        try {
          await metaDir.delete(recursive: true);
          debugPrint('[删除]   ✅ 已删除元数据目录: ${game.metaDataDir}');
        } catch (e) {
          debugPrint('[删除]   ⚠️ 删除元数据失败: $e');

          try {
            final ctgameFile =
                File('${game.metaDataDir}/${GameDataFormat.ctgameFileName}');
            if (await ctgameFile.exists()) {
              await ctgameFile.delete();
            }

            final gameJsonFile =
                File('${game.metaDataDir}/${GameDataFormat.gameJsonFileName}');
            if (await gameJsonFile.exists()) {
              await gameJsonFile.delete();
            }

            final entries = await metaDir.list().toList();
            if (entries.isEmpty) {
              await metaDir.delete();
            }
            debugPrint('[删除]   ✅ 已清理元数据残留文件');
          } catch (e2) {
            debugPrint('[删除]   ⚠️ 清理残留失败: $e2');
          }
        }
      }

      // 通过 metaDataDir 查找 _games 中的正确 key（而非 directoryPath）
      String? gameKey;
      for (final entry in _games.entries) {
        if (entry.value.metaDataDir == game.metaDataDir) {
          gameKey = entry.key;
          break;
        }
      }
      if (gameKey != null) {
        _removeByDirName(gameKey);
      } else {
        _removeByDirName(dirName);
      }

      final afterLen = _games.length;
      final afterTitlesLen = _installedTitles.length;

      // 通知截图抓取服务清理已删除游戏的进度记录
      onGameRemoved?.call(game.title);

      debugPrint(
          '[删除] ✅ 彻底删除完成: ${game.title} | 库: $beforeLen→$afterLen | 已安装列表: $beforeTitlesLen→$afterTitlesLen');
      return true;
    } catch (e) {
      debugPrint('[删除] ❌ 删除过程异常: $e');
      return false;
    }
  }

  Future<bool> removeGameRecordOnly(String title) async {
    final game = getGameByTitle(title);
    if (game == null) {
      debugPrint('[删除] ⚠️ 移除记录失败: 未找到游戏 | $title');
      return false;
    }

    final dirPath = game.metaDataDir;
    final dirName = dirPath.split('/').last.split('\\').last;

    debugPrint('[删除] ========== 开始彻底移除游戏数据记录(保留游戏本体) ==========');
    debugPrint('[删除] 游戏标题: ${game.title}');
    debugPrint('[删除] 元数据目录: $dirPath');

    try {
      // ★ H6: 清理活跃会话（★ v3 阶段 4: 含定时器）
      _cleanupSession(game.metaDataDir);

      // ★ H7: 删除桌面快捷方式
      try {
        await ShortcutService.instance.deleteShortcut(game.title);
      } catch (e) {
        debugPrint('[删除]   ⚠️ 删除快捷方式失败(可忽略): $e');
      }

      _removeByDirName(dirName);

      try {
        final ctgameFile = File('$dirPath/${GameDataFormat.ctgameFileName}');
        if (await ctgameFile.exists()) {
          await ctgameFile.delete();
          debugPrint('[删除]   ✅ 已删除: .ctgame');
        }

        final gameJsonFile =
            File('$dirPath/${GameDataFormat.gameJsonFileName}');
        if (await gameJsonFile.exists()) {
          await gameJsonFile.delete();
          debugPrint('[删除]   ✅ 已删除: game.json');
        }

        final coverFile = GameDataFormat.findCoverFile(dirPath);
        if (coverFile != null && await coverFile.exists()) {
          await coverFile.delete();
          debugPrint('[删除]   ✅ 已删除封面: ${coverFile.path.split('\\').last}');
        }
      } catch (fileErr) {
        debugPrint('[删除]   ⚠️ 清理本地数据文件时部分失败（可忽略）: $fileErr');
      }

      final afterLen = _games.length;

      // 通知截图抓取服务清理已删除游戏的进度记录
      onGameRemoved?.call(game.title);

      debugPrint('[删除] ✅✅✅ 游戏数据记录已彻底移除！');
      debugPrint('[删除]   游戏名: ${game.title}');
      debugPrint('[删除]   当前库容量: $afterLen');
      debugPrint('[删除]   游戏本体文件夹已保留: ${game.directoryPath}');
      debugPrint('[删除] ======================================================');

      return true;
    } catch (e) {
      debugPrint('[删除] ❌ 移除记录失败: ${game.directoryPath} | $e');
      return false;
    }
  }

  static Future<String?> detectLaunchExe(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return null;

    try {
      final exeFiles = <File>[];
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer')) {
            exeFiles.add(entity);
          }
        }
      }

      if (exeFiles.isEmpty) return null;

      final chinesePattern = RegExp(r'[\u4e00-\u9fa5]');
      final chineseFiles =
          exeFiles.where((f) => chinesePattern.hasMatch(f.path)).toList();
      if (chineseFiles.isNotEmpty) {
        debugPrint(
            '[LOCAL-REGISTRY] 🔍 检测到汉化可执行文件: ${chineseFiles.first.path}');
        return chineseFiles.first.path;
      }

      final mainFiles = exeFiles.where((f) {
        final lower = f.path.toLowerCase();
        return !lower.contains('patch') &&
            !lower.contains('crack') &&
            !lower.contains('fix');
      }).toList();
      if (mainFiles.isNotEmpty) {
        mainFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
        debugPrint(
            '[LOCAL-REGISTRY] 🔍 检测到原版可执行文件(最大体积): ${mainFiles.first.path}');
        return mainFiles.first.path;
      }

      exeFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      debugPrint('[LOCAL-REGISTRY] 🔍 兜底选择最大体积exe: ${exeFiles.first.path}');
      return exeFiles.first.path;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ detectLaunchExe异常: $e');
      return null;
    }
  }

  Future<String?> findExecutable(String title) async {
    final game = getGameByTitle(title);
    if (game == null) return null;

    final dir = Directory(game.directoryPath);
    if (!await dir.exists()) return null;

    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer')) {
            debugPrint('[LOCAL-REGISTRY] 🔍 找到可执行文件: ${entity.path}');
            return entity.path;
          }
        }
      }
      debugPrint('[LOCAL-REGISTRY] ⚠️ 未找到可执行文件: ${game.title}');
      return null;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ 搜索可执行文件异常: $e');
      return null;
    }
  }

  final Map<String, _GameSession> _activeGameSessions = {};
  Timer? _playTimeMonitor;

  /// ★ v3 阶段 4: 前台检测定时器改为 Map，支持多游戏同时运行
  /// 每个 metaDataDir 对应一个独立的 2s 定时器
  /// 单例定时器只能追踪最后一个启动的游戏，Map 方案确保所有游戏的前台状态都正确
  final Map<String, Timer> _foregroundCheckTimers = {};

  /// ★ 重构: 前台状态共享 Map（key = metaDataDir）
  /// 由 _foregroundTimer (500ms) 更新，_mainMonitorTimer (2s) 读取
  final Map<String, _ForegroundState> _foregroundStates = {};
  Timer? _foregroundTimer;
  static const Duration _foregroundCheckInterval = Duration(milliseconds: 500);

  // ★ v2 参数调整（借鉴 ReinaManager）
  // - 主定时器从 30s → 2s：更快响应游戏退出（FFI 毫秒级，无需 10s）
  // - missThreshold 从 20（10分钟）→ 3（6s）：借鉴 ReinaManager MAX_CONSECUTIVE_FAILURES=3
  //   配合重扫描机制（missCount=3 时重扫游戏目录），避免启动器型游戏误判
  static const int _monitorIntervalSec = 2;
  static const int _missThreshold = 3; // 3次×2s=6s 宽限期
  static const int _tasklistFailThreshold = 10; // 10次×2s≈20s 系统级问题容忍
  static const int _writeFailThreshold = 5; // 5次×2s=10s 写入重试窗口
  static const int _minSessionSeconds =
      60; // ★ v2: 过滤误启动（借鉴 ReinaManager MIN_SESSION_SECONDS）

  /// v2: 全局追踪模式缓存（启动时从 SharedPreferences 加载）
  TimeTrackingMode _globalTrackingMode = TimeTrackingMode.playtime;
  TimeTrackingMode get globalTrackingMode => _globalTrackingMode;

  /// C1: 防止 _checkActiveSessions 并发执行的互斥标志
  /// Timer.periodic 不 await async 回调，若上次执行未完成下次 tick 会并发
  bool _isCheckingSessions = false;

  /// M3: tasklist 连续失败计数，超过阈值后结束所有会话
  int _tasklistFailCount = 0;

  /// 游戏会话结束回调（游戏标题, 本次会话秒数）
  /// 由 TrayService 设置，用于在游戏退出时发送通知和刷新托盘菜单
  void Function(String gameTitle, int sessionSeconds)? onGameSessionEnded;

  Future<bool> launchGame(String title,
      {String? forceExePath,
      String localeMode = 'none',
      bool skipUpscaling = false}) async {
    debugPrint(
        '[LOCAL-REGISTRY] 🎮 launchGame 调用: title="$title" forceExePath=$forceExePath localeMode=$localeMode');

    var game = getGameByTitle(title);
    if (game == null) {
      // ★ 容错：游戏可能尚未扫描到内存中，触发一次 scan 后重试
      debugPrint('[LOCAL-REGISTRY] ⚠️ 未找到游戏记录，触发 scan 后重试: "$title"');
      try {
        await scan();
      } catch (e) {
        debugPrint('[LOCAL-REGISTRY] scan 重试异常: $e');
      }
      game = getGameByTitle(title);
    }
    if (game == null) {
      debugPrint('[LOCAL-REGISTRY] ❌ 无法启动游戏: scan 后仍未找到游戏记录: "$title"');
      // 打印当前内存中所有游戏标题，帮助诊断
      final allTitles = _games.values.map((g) => g.title).toList();
      debugPrint('[LOCAL-REGISTRY] 当前内存中游戏标题: $allTitles');
      return false;
    }

    debugPrint(
        '[LOCAL-REGISTRY] ✅ 找到游戏: ${game.title} | metaDataDir=${game.metaDataDir}');

    // 读取 game.json 中的转区和超分配置
    String upscalingMode = 'none';
    {
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null) {
          if (localeMode == 'none' && data.localeMode.isNotEmpty) {
            localeMode = data.localeMode;
            debugPrint('[LOCAL-REGISTRY] 🌸 从 game.json 读取转区模式: $localeMode');
          }
          if (data.upscalingMode.isNotEmpty) {
            upscalingMode = data.upscalingMode;
            debugPrint(
                '[LOCAL-REGISTRY] 🔍 从 game.json 读取超分模式: $upscalingMode');
          }
        }
      } catch (_) {}
    }

    // 超分模式：优先使用 MagpieService 启动
    // ★ C5: skipUpscaling=true 时跳过，避免 executeLaunch Magpie 失败回退后重复启动
    if (upscalingMode == 'magpie' && !skipUpscaling) {
      debugPrint('[LOCAL-REGISTRY] 🖥 检测到超分模式，使用 MagpieService 启动...');

      // 先确定 exe 路径
      String? exePath;
      if (forceExePath != null && forceExePath.isNotEmpty) {
        final forceFile = File(forceExePath);
        if (await forceFile.exists()) {
          exePath = forceExePath;
        }
      }
      if (exePath == null && game.launchPath.isNotEmpty) {
        final resolved = GameDataFormat.resolveLaunchPath(
            game.launchPath, game.directoryPath);
        if (await File(resolved).exists()) {
          exePath = resolved;
        }
      }
      if (exePath == null) {
        final detection = await GameLauncherDetector.detect(game.directoryPath);
        if (detection.success && detection.launcherPath != null) {
          exePath = detection.launcherPath!;
        }
      }

      if (exePath != null) {
        final success = await MagpieService.instance.startGameWithUpscaling(
          gameExePath: exePath,
          gameTitle: game.title,
          localeMode: localeMode,
        );

        if (success) {
          // 注册游玩时长追踪会话
          // ★ 检查返回值：若失败，告知调用方（launchGame 仍返回 true，
          // 因为 Magpie 进程已启动，但时长不会记录）
          final trackingOk =
              await startPlayTimeTracking(game.title, exePath: exePath);
          if (!trackingOk) {
            debugPrint('[LOCAL-REGISTRY] ⚠️ 超分启动成功但会话注册失败，时长将不记录');
          }

          // 更新游玩状态
          if (game.playStatus == PlayStatus.notStarted) {
            game.playStatus = PlayStatus.inProgress;
            GameDataFormat.setPlayStatus(game.metaDataDir, 'in_progress');
          }
          final now = DateTime.now().toIso8601String();
          final updates = <String, dynamic>{'last_opened_at': now};
          if (game.firstOpenedAt.isEmpty) {
            game.firstOpenedAt = now;
            updates['first_opened_at'] = now;
          }
          game.lastOpenedAt = now;
          await GameDataFormat.updateGameJson(game.metaDataDir, updates);

          debugPrint('[LOCAL-REGISTRY] ✅ 超分启动成功!');
          return true;
        }

        // Magpie 启动失败，检查是否允许回退
        if (MagpieService.instance.fallbackOnFail) {
          debugPrint(
              '[LOCAL-REGISTRY] ⚠️ 超分启动失败，回退到普通启动（skipUpscaling=true）...');
          // ★ C5: 设置 skipUpscaling=true，避免下方普通启动流程再次尝试 Magpie
          skipUpscaling = true;
          // 继续走下面的普通启动流程
        } else {
          debugPrint('[LOCAL-REGISTRY] ❌ 超分启动失败且不允许回退');
          return false;
        }
      } else {
        debugPrint('[LOCAL-REGISTRY] ⚠️ 无法确定 exe 路径，跳过超分');
      }
    }

    String? exePath;

    debugPrint('');
    debugPrint('[LOCAL-REGISTRY] ════════════════════════════');
    debugPrint('[LOCAL-REGISTRY] 🎮 准备启动游戏: ${game.title}');
    if (forceExePath != null) {
      debugPrint('[LOCAL-REGISTRY] 🔒 强制使用用户指定的exe路径(绕过所有检测)');
      debugPrint('[LOCAL-REGISTRY]   强制路径: $forceExePath');
    }
    debugPrint('[LOCAL-REGISTRY] ════════════════════════════');

    if (forceExePath != null && forceExePath.isNotEmpty) {
      final forceFile = File(forceExePath);
      if (await forceFile.exists()) {
        exePath = forceExePath;
        debugPrint('[LOCAL-REGISTRY] ✅ 强制路径文件存在，直接使用: $exePath');

        // 使用 directoryPath 作为相对路径基准，与 resolveLaunchPath 保持一致
        final relativePath = _toRelative(exePath, game.directoryPath);
        game.launchPath = relativePath.isNotEmpty ? relativePath : exePath;
        await GameDataFormat.updateGameJson(
            game.metaDataDir, {'launch_path': game.launchPath});
      } else {
        debugPrint('[LOCAL-REGISTRY] ❌ 强制路径文件不存在! $forceExePath');
        debugPrint('[LOCAL-REGISTRY]   回退到标准启动流程...');
      }
    }

    if (exePath == null) {
      if (game.launchPath.isNotEmpty) {
        final resolvedPath = GameDataFormat.resolveLaunchPath(
            game.launchPath, game.directoryPath);

        debugPrint('[LOCAL-REGISTRY] 📂 检查已记录的启动路径...');
        debugPrint('[LOCAL-REGISTRY]   相对路径: ${game.launchPath}');
        debugPrint('[LOCAL-REGISTRY]   解析路径: $resolvedPath');

        final launchFile = File(resolvedPath);
        if (await launchFile.exists()) {
          exePath = resolvedPath;
          debugPrint('[LOCAL-REGISTRY] ✅ 文件存在，直接使用: $exePath');
        } else {
          debugPrint('[LOCAL-REGISTRY] ⚠️ 文件不存在，触发重新扫描...');
        }
      } else {
        debugPrint('[LOCAL-REGISTRY] ℹ️ 无已记录的启动路径，执行自动识别...');
      }

      if (exePath == null) {
        debugPrint('[LOCAL-REGISTRY] 🔍 调用智能识别器扫描目录...');

        final detection = await GameLauncherDetector.detect(game.directoryPath);

        if (detection.success && detection.launcherPath != null) {
          exePath = detection.launcherPath!;

          debugPrint('[LOCAL-REGISTRY] ✅ 识别成功，更新启动路径...');
          debugPrint('[LOCAL-REGISTRY]   新路径: $exePath');

          // 使用 directoryPath 作为相对路径基准，与 resolveLaunchPath 保持一致
          final relativePath = _toRelative(exePath, game.directoryPath);
          game.launchPath = relativePath.isNotEmpty ? relativePath : exePath;

          await GameDataFormat.updateGameJson(
              game.metaDataDir, {'launch_path': relativePath});

          debugPrint('[LOCAL-REGISTRY] ✅ 已更新 game.json');
        } else {
          debugPrint('[LOCAL-REGISTRY] ❌ 自动识别失败，无法确定启动文件');
        }
      }
    }

    if (exePath == null) {
      debugPrint('[LOCAL-REGISTRY] ❌ 无法启动游戏: 未找到可执行的EXE | ${game.title}');
      debugPrint('[LOCAL-REGISTRY] ════════════════════════════');
      debugPrint('');
      return false;
    }

    // ═══════════════════════════════════════════════════════════════
    // ★ 关键修复：分离"进程启动"与"会话创建"
    // 旧实现在同一个 try 块中执行 Process.run + 会话创建，若 Process.run
    // 抛异常（antivirus 拦截、工作目录异常等），整个会话创建被跳过，
    // 导致游戏已启动但时长永不记录。
    // 新实现：进程启动用独立 try-catch，会话创建无条件执行——
    // 因为 cmd /c start 是异步 fire-and-forget，即使 Process.run 抛异常，
    // 游戏进程也可能已经启动。让进程检测（missCount 机制）决定会话生命周期。
    // ═══════════════════════════════════════════════════════════════

    final exeFile = File(exePath);
    final workDir = exeFile.parent.path;
    final exeName = p.basename(exePath);

    // ★ 普通启动流程日志（超分模式由 MagpieService.startGameWithUpscaling 自行记录）
    await GameLaunchLogger.instance.logLaunchStart(
      gameTitle: game.title,
      exePath: exePath,
      launchMode: skipUpscaling ? 'normal(超分回退)' : 'normal',
      localeMode: localeMode,
      trackingMode: _globalTrackingMode == TimeTrackingMode.playtime
          ? '精准模式(仅前台计时)'
          : '宽松模式(存活即计时)',
    );

    debugPrint('[LOCAL-REGISTRY] 🚀 执行启动命令...');
    debugPrint('[LOCAL-REGISTRY]   EXE路径: $exePath');
    debugPrint('[LOCAL-REGISTRY]   转区模式: $localeMode');
    debugPrint('[LOCAL-REGISTRY]   工作目录: $workDir');
    debugPrint('[LOCAL-REGISTRY]   启动程序: $exeName');

    // ★ directoryPath 自愈：若 game.directoryPath 为空或目录不存在，
    // 从 exePath 的父目录（workDir）自动恢复。这解决了主页/BPM/快捷方式
    // 启动时 game.directoryPath 错指导致 _scanGameExes 在错误目录扫描、
    // monitoredExes 为空的问题。仅在确实无效时才写入，避免不必要的磁盘 I/O。
    if (game.directoryPath.isEmpty ||
        !Directory(game.directoryPath).existsSync()) {
      debugPrint(
          '[LOCAL-REGISTRY] 🔧 directoryPath 无效("${game.directoryPath}")，从 exePath 恢复为: $workDir');
      game.directoryPath = workDir;
      try {
        await GameDataFormat.updateGameJson(
            game.metaDataDir, {'directory_path': workDir});
      } catch (e) {
        debugPrint('[LOCAL-REGISTRY] ⚠️ directoryPath 回写失败（不阻塞）: $e');
      }
    }

    // ── 阶段 1：启动进程（独立 try-catch，失败不阻塞会话创建） ──
    bool processStarted = false;
    // ★ 重构: 使用 Process.start(detached) 捕获 PID（替代 cmd /c start）
    int? launchedPid;
    try {
      if (localeMode == 'japanese') {
        final leAvailable = await LocaleService.isLocaleAvailable();
        if (leAvailable) {
          debugPrint('[LOCAL-REGISTRY] 🌸 使用 Locale Emulator 转区启动...');
          await LocaleService.launchWithLocale(exePath, workingDir: workDir)
              .timeout(const Duration(seconds: 15), onTimeout: () {
            debugPrint('[LOCAL-REGISTRY] ⚠️ LE 启动超时(15s)，继续创建会话');
            return ProcessResult(0, 0, '', '');
          });
          // LE 启动不返回游戏 PID，后续靠 exe 名检测
        } else {
          debugPrint('[LOCAL-REGISTRY] ⚠️ LE 不可用，回退到普通启动（游戏可能显示乱码）...');
          // ★ M10: LE 不可用时记录警告，调用方可通过日志诊断乱码问题
          // ★ 重构: 尝试 Process.start(detached) 捕获 PID，失败回退 cmd /c start
          try {
            final process = await Process.start(exePath, [],
                workingDirectory: workDir, mode: ProcessStartMode.detached);
            launchedPid = process.pid;
            debugPrint('[LOCAL-REGISTRY] 🆔 启动进程 PID: $launchedPid');
          } catch (e) {
            debugPrint(
                '[LOCAL-REGISTRY] ⚠️ Process.start 失败，回退到 cmd /c start: $e');
            await Process.run('cmd.exe', ['/c', 'start', '""', exePath],
                    workingDirectory: workDir, runInShell: true)
                .timeout(const Duration(seconds: 15), onTimeout: () {
              debugPrint('[LOCAL-REGISTRY] ⚠️ cmd /c start 超时(15s)，继续创建会话');
              throw TimeoutException('cmd /c start timeout');
            });
            debugPrint('[LOCAL-REGISTRY]   通过 Shell 启动（无 PID 返回）');
          }
        }
      } else {
        // ★ 重构: 使用 Process.start(detached) 启动并捕获 PID
        // 彻底断开父子进程关系（detached 模式），同时获取 PID 用于进程检测
        try {
          final process = await Process.start(exePath, [],
              workingDirectory: workDir, mode: ProcessStartMode.detached);
          launchedPid = process.pid;
          debugPrint('[LOCAL-REGISTRY] 🆔 启动进程 PID: $launchedPid');
        } catch (e) {
          // 回退到 cmd /c start（无 PID，靠进程名追踪）
          debugPrint(
              '[LOCAL-REGISTRY] ⚠️ Process.start 失败，回退到 cmd /c start: $e');
          await Process.run('cmd.exe', ['/c', 'start', '""', exePath],
                  workingDirectory: workDir, runInShell: true)
              .timeout(const Duration(seconds: 15), onTimeout: () {
            debugPrint('[LOCAL-REGISTRY] ⚠️ cmd /c start 超时(15s)，继续创建会话');
            throw TimeoutException('cmd /c start timeout');
          });
          debugPrint('[LOCAL-REGISTRY]   通过 Shell 启动（无 PID 返回）');
        }
      }
      processStarted = true;
    } catch (e) {
      // ★ 关键：cmd /c start 是异步的，异常抛出时游戏进程可能已启动
      // 仍然继续创建会话，由 _isGameStillRunning + missCount 机制优雅降级：
      //   - 若游戏确实在运行 → 正常累加时长
      //   - 若游戏未启动 → missCount 达阈值后自动结束会话（无副作用）
      debugPrint('[LOCAL-REGISTRY] ⚠️ 进程启动异常（仍将创建会话由检测机制兜底）: $e');
    }

    // ★ 日志：记录进程启动结果
    await GameLaunchLogger.instance.logStep(
      '游戏进程启动',
      processStarted ? 'OK' : 'WARN',
      detail: processStarted
          ? (launchedPid != null ? 'PID=$launchedPid' : '已启动(无PID)')
          : '启动异常，将创建会话由检测机制兜底',
    );

    // ── 阶段 2：创建游玩会话（无条件执行，确保时长统计生效） ──
    try {
      debugPrint(
          '[LOCAL-REGISTRY] 📝 创建游玩会话: metaDataDir=${game.metaDataDir} exeName=$exeName (进程启动: ${processStarted ? "成功" : "异常"})');

      // ★ H4/v2: 已有活跃会话时保留累计时长，而非直接覆盖
      int preservedAccumulated = 0;
      bool preservedBackupTriggered = false;
      DateTime preservedStartTime = DateTime.now();
      int preservedMissCount = 0;
      int preservedWriteFails = 0;
      DateTime preservedLastSettled = DateTime.now();
      Set<int> preservedCandidatePids = <int>{};
      if (_activeGameSessions.containsKey(game.metaDataDir)) {
        final old = _activeGameSessions[game.metaDataDir]!;
        preservedAccumulated = old.accumulatedSeconds;
        preservedBackupTriggered = old.backupTriggered;
        preservedStartTime = old.startTime;
        preservedMissCount = old.missCount;
        preservedWriteFails = old.consecutiveWriteFails;
        preservedLastSettled = old.lastSettledTime;
        preservedCandidatePids = old.candidatePids;
        debugPrint('[LOCAL-REGISTRY] 🔄 保留已有会话累计: ${preservedAccumulated}s');
      }

      // ★ v2: 扫描游戏目录获取初始候选 PID 集（借鉴 ReinaManager L268-273）
      final gameDirForScan =
          game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir;
      var initialCandidatePids = await _scanGameDirPids(gameDirForScan);
      // ★ Fix 1.4：首次扫描为空时延迟 500ms 重试一次，覆盖 cmd /c start 后
      // 游戏进程尚未在 WMI 注册的竞态（首次启动最易触发）
      if (initialCandidatePids.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        initialCandidatePids = await _scanGameDirPids(gameDirForScan);
      }
      final mergedCandidatePids = <int>{
        ...preservedCandidatePids,
        ...initialCandidatePids
      };

      // ★ v2: 从全局缓存读取追踪模式
      final trackingMode = _globalTrackingMode;

      final newSession = _GameSession(
        startTime: preservedStartTime, // ★ H4: 保留原始开始时间
        gameTitle: game.title,
        metaDataDir: game.metaDataDir,
        directoryPath: game.directoryPath, // ★ C6: 传入游戏目录用于自动备份
        trackingMode: trackingMode, // ★ v2: 追踪模式
        bestPid: launchedPid, // ★ 重构: 使用捕获的 PID（替代 launchedPid: null）
        primaryExe: exeName.toLowerCase(), // ★ C7: 主 exe 作为进程检测主指标
        monitoredExes: await _scanGameExes(
          game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
          launchedExe: exeName,
        ),
      )
        ..accumulatedSeconds = preservedAccumulated
        ..backupTriggered = preservedBackupTriggered
        ..missCount = preservedMissCount // ★ M2: 保留 missCount
        ..consecutiveWriteFails = preservedWriteFails
        ..lastSettledTime = preservedLastSettled
        ..candidatePids = mergedCandidatePids;
      _activeGameSessions[game.metaDataDir] = newSession;
      _ensurePlayTimeMonitor();
      // ★ 重构: 注册到前台状态共享 Map（替代 _startForegroundHook）
      if (newSession.trackingMode == TimeTrackingMode.playtime) {
        _foregroundStates[newSession.metaDataDir] = _ForegroundState(
          newSession.directoryPath,
          newSession.candidatePids,
        );
      }
      // ★ Fix 2.1：会话创建后3s立即检测（不等首个10s tick），快速回填
      // candidatePids 并开始计时，解决"刚启动软件首次打开游戏不计时"
      _scheduleImmediateSessionCheck();
      debugPrint(
          '[LOCAL-REGISTRY] ✅ 会话已创建，监控定时器已启动. 活跃会话数: ${_activeGameSessions.length}');

      // ★ 日志：时长统计已启用
      await GameLaunchLogger.instance.logTrackingState('已启用',
          detail:
              '${_globalTrackingMode == TimeTrackingMode.playtime ? "精准模式" : "宽松模式"} | 监控exe: $exeName');

      // 自动更新游玩状态：未入坑 → 游玩中
      if (game.playStatus == PlayStatus.notStarted) {
        game.playStatus = PlayStatus.inProgress;
        GameDataFormat.setPlayStatus(game.metaDataDir, 'in_progress');
      }

      // 记录首次打开时间和最后打开时间
      final now = DateTime.now().toIso8601String();
      final updates = <String, dynamic>{'last_opened_at': now};
      if (game.firstOpenedAt.isEmpty) {
        game.firstOpenedAt = now;
        updates['first_opened_at'] = now;
      }
      game.lastOpenedAt = now;
      await GameDataFormat.updateGameJson(game.metaDataDir, updates);

      // ★ 记录当日游玩次数（用于统计面板）
      await _incrementDailyPlayCount(game.metaDataDir);

      debugPrint(
          '[LOCAL-REGISTRY] ✅ 启动流程完成! (进程启动: ${processStarted ? "成功" : "异常-会话已兜底"})');
      debugPrint('[LOCAL-REGISTRY]   游戏: ${game.title}');
      debugPrint('[LOCAL-REGISTRY] ════════════════════════════');
      debugPrint('');

      // ★ 日志：启动流程结束
      await GameLaunchLogger.instance.logLaunchEnd(
        gameTitle: game.title,
        success: true,
        summary: '普通启动成功 | 时长统计已启用',
      );

      return true;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ 会话创建失败: $e');
      debugPrint('[LOCAL-REGISTRY]   EXE路径: $exePath');
      debugPrint('[LOCAL-REGISTRY] ════════════════════════════');
      debugPrint('');

      return false;
    }
  }

  /// 为外部启动的游戏注册游玩时长追踪会话（不启动游戏进程）
  /// 用于 Magpie 超分启动等场景，游戏进程由外部服务启动，
  /// 但仍需追踪游玩时长
  ///
  /// ★ 返回 bool：true 表示会话注册成功，false 表示失败（游戏未找到）。
  /// 调用方据此决定是否报错，避免 Magpie 启动成功但时长追踪静默失败。
  Future<bool> startPlayTimeTracking(String gameTitle,
      {String? exePath, int? launchedPid}) async {
    debugPrint(
        '[PLAYTIME] 📝 startPlayTimeTracking 调用: title="$gameTitle" exePath=$exePath pid=$launchedPid');
    final game = getGameByTitle(gameTitle);
    if (game == null) {
      // ★ 容错：游戏可能尚未扫描到内存中，触发一次 scan 后重试
      debugPrint('[PLAYTIME] ⚠️ 未找到游戏，触发 scan 后重试: "$gameTitle"');
      try {
        await scan();
      } catch (e) {
        debugPrint('[PLAYTIME] scan 重试异常: $e');
      }
      final gameRetry = getGameByTitle(gameTitle);
      if (gameRetry == null) {
        debugPrint('[PLAYTIME] ❌ scan 后仍未找到游戏: "$gameTitle"');
        return false; // ★ 返回 false 让调用方感知失败
      }
      // 继续使用重试找到的游戏
      return _startPlayTimeTrackingInternal(gameRetry, exePath, launchedPid);
    }
    return _startPlayTimeTrackingInternal(game, exePath, launchedPid);
  }

  Future<bool> _startPlayTimeTrackingInternal(
      LibraryGame game, String? exePath, int? launchedPid) async {
    debugPrint(
        '[PLAYTIME] 📝 注册会话: ${game.title} | metaDataDir=${game.metaDataDir} | exePath=$exePath');

    // ★ RC6/v2 修复：已有活跃会话时保留累计时长，而非归零重建
    int preservedAccumulatedSeconds = 0;
    bool preservedBackupTriggered = false;
    DateTime preservedStartTime = DateTime.now();
    DateTime preservedLastSettled = DateTime.now();
    int preservedMissCount = 0; // ★ M2: 保留 missCount
    int preservedWriteFails = 0;
    Set<int> preservedCandidatePids = <int>{};
    if (_activeGameSessions.containsKey(game.metaDataDir)) {
      final oldSession = _activeGameSessions[game.metaDataDir]!;
      preservedAccumulatedSeconds = oldSession.accumulatedSeconds;
      preservedBackupTriggered = oldSession.backupTriggered;
      preservedStartTime = oldSession.startTime;
      preservedLastSettled = oldSession.lastSettledTime;
      preservedMissCount = oldSession.missCount;
      preservedWriteFails = oldSession.consecutiveWriteFails;
      preservedCandidatePids = oldSession.candidatePids;
      debugPrint(
          '[PLAYTIME] 🔄 游戏已有活跃会话，保留累计时长: ${preservedAccumulatedSeconds}s missCount: $preservedMissCount');
      _activeGameSessions.remove(game.metaDataDir);
      // ★ v3 阶段 4: 取消旧定时器，新会话会启动新定时器
      _foregroundCheckTimers[game.metaDataDir]?.cancel();
      _foregroundCheckTimers.remove(game.metaDataDir);
      // ★ 重构: 同时清理前台状态（新会话会重新注册）
      _foregroundStates.remove(game.metaDataDir);
    }

    String exeName = '';
    if (exePath != null) {
      exeName = p.basename(exePath);
    }

    // ★ v2: 扫描游戏目录获取初始候选 PID 集
    final gameDirForScan =
        game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir;
    var initialCandidatePids = await _scanGameDirPids(gameDirForScan);
    // ★ Fix 1.4：首次扫描为空时延迟 500ms 重试一次，覆盖启动竞态
    if (initialCandidatePids.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 500));
      initialCandidatePids = await _scanGameDirPids(gameDirForScan);
    }
    final mergedCandidatePids = <int>{
      ...preservedCandidatePids,
      ...initialCandidatePids
    };

    // ★ v2: 从全局缓存读取追踪模式
    final trackingMode = _globalTrackingMode;

    final newSession = _GameSession(
      startTime: preservedStartTime, // ★ 保留原始开始时间
      gameTitle: game.title,
      metaDataDir: game.metaDataDir,
      directoryPath: game.directoryPath, // ★ C6: 传入游戏目录
      trackingMode: trackingMode, // ★ v2: 追踪模式
      bestPid: launchedPid, // ★ 重构: launchedPid → bestPid
      primaryExe: exeName.isNotEmpty ? exeName.toLowerCase() : null, // ★ C7
      monitoredExes: await _scanGameExes(
        game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
        launchedExe: exeName,
      ),
    )
      ..accumulatedSeconds = preservedAccumulatedSeconds
      ..backupTriggered = preservedBackupTriggered
      ..missCount = preservedMissCount // ★ M2: 保留 missCount
      ..consecutiveWriteFails = preservedWriteFails
      ..lastSettledTime = preservedLastSettled
      ..candidatePids = mergedCandidatePids;
    _activeGameSessions[game.metaDataDir] = newSession;
    _ensurePlayTimeMonitor();
    // ★ 重构: 注册到前台状态共享 Map（替代 _startForegroundHook）
    if (newSession.trackingMode == TimeTrackingMode.playtime) {
      _foregroundStates[newSession.metaDataDir] = _ForegroundState(
        newSession.directoryPath,
        newSession.candidatePids,
      );
    }
    // ★ Fix 2.1：会话创建后3s立即检测（不等首个10s tick）
    _scheduleImmediateSessionCheck();

    // 自动更新游玩状态：未入坑 → 待通关
    if (game.playStatus == PlayStatus.notStarted) {
      game.playStatus = PlayStatus.inProgress;
      GameDataFormat.setPlayStatus(game.metaDataDir, 'in_progress');
    }

    // 记录首次打开时间和最后打开时间
    final now = DateTime.now().toIso8601String();
    final updates = <String, dynamic>{'last_opened_at': now};
    if (game.firstOpenedAt.isEmpty) {
      game.firstOpenedAt = now;
      updates['first_opened_at'] = now;
    }
    game.lastOpenedAt = now;
    await GameDataFormat.updateGameJson(game.metaDataDir, updates);

    // ★ 记录当日游玩次数（用于统计面板）
    await _incrementDailyPlayCount(game.metaDataDir);

    debugPrint(
        '[PLAYTIME] ✅ 已注册外部启动会话: ${game.title} | PID: $launchedPid | 监控exe: ${_activeGameSessions[game.metaDataDir]?.monitoredExes} | 累计: ${preservedAccumulatedSeconds}s');
    return true; // ★ 会话注册成功
  }

  void _ensurePlayTimeMonitor() {
    // 主监控定时器（2s）：进程存活检测 + 时长累加
    if (_playTimeMonitor == null || !_playTimeMonitor!.isActive) {
      _playTimeMonitor = Timer.periodic(
        const Duration(seconds: 2), // ★ 从 10s 改为 2s
        (_) => _checkActiveSessions(),
      );
      debugPrint('[PLAYTIME] 🕐 时长监控定时器已启动 (间隔: 2s)');
    }
    // 前台检测定时器（500ms）：前台窗口 + 逃逸进程检测
    if (_foregroundTimer == null || !_foregroundTimer!.isActive) {
      _foregroundTimer = Timer.periodic(
        _foregroundCheckInterval,
        (_) => _checkForegroundAll(),
      );
      debugPrint(
          '[PLAYTIME] 🕐 前台检测定时器已启动 (间隔: ${_foregroundCheckInterval.inMilliseconds}ms)');
    }
  }

  /// ★ Fix 2.1：会话创建后立即调度一次前台检测（不等首个 500ms tick）
  ///
  /// 解决"刚启动软件首次打开游戏大概率不计时"问题：
  /// Timer.periodic 首次回调在 500ms 后。期间 candidatePids 可能为空，
  /// 前台检测无法匹配 → isForeground=false → playtime 不累加。
  /// 500ms 延迟给游戏进程初始化窗口的时间，然后立即检测。
  ///
  /// 幂等：多个会话并发创建时仅调度一次（_immediateCheckScheduled 标志）。
  bool _immediateCheckScheduled = false;
  void _scheduleImmediateSessionCheck() {
    if (_immediateCheckScheduled) return;
    _immediateCheckScheduled = true;
    // ★ 重构: 立即执行前台检测（500ms 周期的定时器首检太慢）
    Future.delayed(const Duration(milliseconds: 500), () {
      _immediateCheckScheduled = false;
      _checkForegroundAll();
    });
  }

  /// ★ v3 阶段 4: 统一的会话清理辅助方法
  /// 同时移除活跃会话和对应的前台检测定时器
  /// 避免在多处重复写 remove + cancel 逻辑
  void _cleanupSession(String metaDataDir) {
    _activeGameSessions.remove(metaDataDir);
    _foregroundCheckTimers[metaDataDir]?.cancel();
    _foregroundCheckTimers.remove(metaDataDir);
    // ★ 重构: 同时清理前台状态共享 Map
    _foregroundStates.remove(metaDataDir);
  }

  Future<void> _checkActiveSessions() async {
    if (_activeGameSessions.isEmpty) {
      _playTimeMonitor?.cancel();
      _playTimeMonitor = null;
      // ★ v3 阶段 4: 取消所有前台检测定时器
      for (final timer in _foregroundCheckTimers.values) {
        timer.cancel();
      }
      _foregroundCheckTimers.clear();
      // ★ 重构: 取消统一前台检测定时器 + 清理状态 Map
      _foregroundTimer?.cancel();
      _foregroundTimer = null;
      _foregroundStates.clear();
      return;
    }

    // ★ C1: 互斥锁防止并发执行（Timer.periodic 不 await async 回调）
    if (_isCheckingSessions) {
      debugPrint('[PLAYTIME] ⏭️ 上次检测仍在执行，跳过本次 tick（防止时长翻倍）');
      return;
    }
    _isCheckingSessions = true;

    try {
      await _checkActiveSessionsInternal();
    } finally {
      _isCheckingSessions = false;
    }
  }

  Future<void> _checkActiveSessionsInternal() async {
    final completedSessions = <String>[];
    final now = DateTime.now();
    bool playTimeChanged = false;

    // ═══════════════════════════════════════════════════════════════
    // ★ v2 阶段 A：进程检测（Win32 FFI，毫秒级）
    //
    // 核心改变：先检测进程，后决定累加。
    // 旧实现：先无条件累加（阶段 A），再检测（阶段 B/C）→ 幽灵累加
    // 新实现：仅在进程检测成功且确认存活时累加 → 彻底消除幽灵累加
    // ═══════════════════════════════════════════════════════════════
    Set<int> runningPids = <int>{};
    // ★ Fix 1.1：保留 name→PID 关联，用于 isRunning 分支回填 session.candidatePids
    // 解决首次启动竞态：_scanGameDirPids 在 cmd /c start 后立即调用，
    // 游戏进程尚未在 WMI 注册 → candidatePids 为空 → 前台检测步骤1 永不命中。
    Map<String, Set<int>> runningNameToPids = <String, Set<int>>{};

    try {
      // ★ 重构: 使用 Win32 FFI 替代 tasklist（毫秒级 vs 秒级）
      // ★ 安全兜底: FFI 返回空列表时（不应发生但可能因运行时异常），
      // 自动回退到 tasklist，避免游戏进程被误判为已退出
      if (Win32ProcessService.isAvailable) {
        final ffiResult = Win32ProcessService.getRunningProcessInfo();
        if (ffiResult.$1.isEmpty && ffiResult.$2.isEmpty) {
          // FFI 返回空 → 几乎不可能（系统至少有 100+ 进程），回退到 tasklist
          debugPrint('[PLAYTIME] ⚠️ FFI 返回空进程列表，回退到 tasklist');
          final legacy = await _getRunningProcessInfoLegacy();
          runningPids = legacy.$1;
          runningNameToPids = legacy.$2;
        } else {
          runningPids = ffiResult.$1;
          runningNameToPids = ffiResult.$2;
        }
      } else {
        final legacy = await _getRunningProcessInfoLegacy();
        runningPids = legacy.$1;
        runningNameToPids = legacy.$2;
      }
      _tasklistFailCount = 0;
    } catch (e) {
      _tasklistFailCount++;
      debugPrint(
          '[PLAYTIME] ⚠️ 进程检测失败 (${_tasklistFailCount}/$_tasklistFailThreshold): $e');

      // ★ 宁少勿多：放弃所有会话的 pending delta，重置时间基线
      // 不累加任何时长——这是消除幽灵累加的关键
      for (final session in _activeGameSessions.values) {
        session.lastSettledTime = now;
      }

      // 持续失败超过阈值时，结束所有会话（安全阀）
      if (_tasklistFailCount >= _tasklistFailThreshold) {
        debugPrint('[PLAYTIME] 🛑 进程检测持续失败超过阈值，结束所有会话');
        for (final entry in _activeGameSessions.entries) {
          final session = entry.value;
          if (session.accumulatedSeconds >= _minSessionSeconds &&
              onGameSessionEnded != null) {
            try {
              onGameSessionEnded!(
                  session.gameTitle, session.accumulatedSeconds);
            } catch (_) {}
          }
          completedSessions.add(entry.key);
        }
        _tasklistFailCount = 0;
      }

      for (final dirPath in completedSessions) {
        _activeGameSessions.remove(dirPath);
        // ★ v3 阶段 4: 同时取消对应的前台检测定时器
        _foregroundCheckTimers[dirPath]?.cancel();
        _foregroundCheckTimers.remove(dirPath);
        // ★ 重构: 同时清理前台状态共享 Map
        _foregroundStates.remove(dirPath);
      }
      return; // ★ 进程检测失败，不进入阶段 B
    }

    // ═══════════════════════════════════════════════════════════════
    // ★ v2 阶段 B：逐会话处理（确认存活才累加）
    // ═══════════════════════════════════════════════════════════════
    final runningNames = runningNameToPids.keys.toSet();
    final entries = _activeGameSessions.entries.toList();

    for (final entry in entries) {
      final metaDataDir = entry.key;
      final session = entry.value;
      if (completedSessions.contains(metaDataDir)) continue;

      final isRunning = _isGameStillRunning(session, runningPids, runningNames);

      if (isRunning) {
        // ── 进程存活：累加时长 ──
        session.missCount = 0;

        // ★ Fix 1.1：回填 candidatePids（修复首次启动前台检测竞态）
        // 主监控已通过 primaryExe 确认游戏在运行，把对应 PID 并入候选集，
        // 这样前台检测 Hook 的步骤1（candidatePids.contains(fgPid)）即可命中。
        // runningNameToPids 每 tick 从全新进程枚举重建，无陈旧 PID 风险。
        if (session.primaryExe != null) {
          final pids = runningNameToPids[session.primaryExe];
          if (pids != null) session.candidatePids.addAll(pids);
        }
        for (final exe in session.monitoredExes) {
          final pids = runningNameToPids[exe];
          if (pids != null) session.candidatePids.addAll(pids);
        }

        // ★ v2 核心改变：根据 trackingMode 决定是否累加
        int secondsToAdd = 0;
        if (session.trackingMode == TimeTrackingMode.playtime) {
          // 精准模式：仅前台时累加
          // ★ 重构: 从 _foregroundStates 读取前台状态（由 500ms 定时器更新）
          final isForeground =
              _foregroundStates[session.metaDataDir]?.isForeground ?? false;
          if (isForeground) {
            final delta = now.difference(session.lastSettledTime).inSeconds;
            secondsToAdd = delta.clamp(0, _monitorIntervalSec * 2).toInt();
          }
          // 后台不累加
        } else {
          // 宽松模式：存活即累加
          final delta = now.difference(session.lastSettledTime).inSeconds;
          secondsToAdd = delta.clamp(0, _monitorIntervalSec * 2).toInt();
        }

        if (secondsToAdd > 0) {
          final writeOk = await _writePlayTimeDirect(metaDataDir, secondsToAdd);
          if (writeOk) {
            session.accumulatedSeconds += secondsToAdd;
            session.consecutiveWriteFails = 0;
            session.lastSettledTime = now;
            playTimeChanged = true;
          } else {
            session.consecutiveWriteFails++;
            debugPrint(
                '[PLAYTIME] ⚠️ 写入失败 (${session.consecutiveWriteFails}/$_writeFailThreshold) 本次 ${secondsToAdd}s 未计入');
            if (session.consecutiveWriteFails >= _writeFailThreshold) {
              debugPrint(
                  '[PLAYTIME] 🛑 连续写入失败 ${session.consecutiveWriteFails} 次，放弃未写入时长并重置');
              session.lastSettledTime = now;
              session.consecutiveWriteFails = 0;
            }
          }
        }

        // 自动备份检查（游玩超过15分钟）
        if (session.accumulatedSeconds >= 900 && !session.backupTriggered) {
          session.backupTriggered = true;
          _triggerAutoBackup(session.gameTitle, session.directoryPath);
        }

        final isFg =
            _foregroundStates[session.metaDataDir]?.isForeground ?? false;
        debugPrint(
            '[PLAYTIME] ✅ ${session.gameTitle} 运行中 (前台: ${isFg ? "是" : "否"} | 本次: ${GameDataFormat.formatPlayTime(session.accumulatedSeconds)} | 总计: ${GameDataFormat.formatPlayTime(_getGamePlayTime(session.gameTitle))})');
      } else {
        // ── 进程不存活：不累加，重置基线 ──
        session.missCount++;
        session.lastSettledTime = now; // ★ 防止下次存活时多算 miss 期间时长

        // ★ v2: missCount=3 时重扫描游戏目录（借鉴 ReinaManager L354-385）
        if (session.missCount == 3) {
          debugPrint('[PLAYTIME] 🔍 触发游戏目录重扫描: ${session.directoryPath}');
          final newPids = await _scanGameDirPids(session.directoryPath);
          if (newPids.isNotEmpty) {
            session.candidatePids = newPids;
            session.missCount = 0;
            session.lastSettledTime = now;
            debugPrint('[PLAYTIME] 🔄 重扫描发现新候选进程: $newPids');
            continue;
          }
        }

        debugPrint(
            '[PLAYTIME] ⏳ ${session.gameTitle} 未检测到进程 (${session.missCount}/$_missThreshold)');

        if (session.missCount >= _missThreshold) {
          debugPrint(
              '[PLAYTIME] 🛑 ${session.gameTitle} 退出，本次总计: ${GameDataFormat.formatPlayTime(session.accumulatedSeconds)}');

          // ★ v3 阶段 2：误启动过滤与事实表写入
          if (session.accumulatedSeconds >= _minSessionSeconds) {
            // 自动备份
            if (session.accumulatedSeconds >= 900 && !session.backupTriggered) {
              session.backupTriggered = true;
              _triggerAutoBackup(session.gameTitle, session.directoryPath);
            }
            // ★ v3 阶段 2：写入会话记录到 sessions 数组（事实表）
            // exit_reason 默认 'normal'，由 toSessionRecord() 设置
            // 异常情况（崩溃/手动停止/应用退出）会显式设置 exitReason
            session.exitReason = 'normal';
            // ★ 日志：记录游戏退出（有效会话）
            await GameLaunchLogger.instance.logGameExit(
              gameTitle: session.gameTitle,
              durationSeconds: session.accumulatedSeconds,
              exitReason: 'normal',
            );
            try {
              await GameDataFormat.appendSession(
                  session.metaDataDir, session.toSessionRecord());
            } catch (e) {
              debugPrint('[PLAYTIME] ⚠️ 追加会话记录失败（不影响主流程）: $e');
            }
            // 通知托盘服务
            if (onGameSessionEnded != null) {
              try {
                onGameSessionEnded!(
                    session.gameTitle, session.accumulatedSeconds);
              } catch (e) {
                debugPrint('[PLAYTIME] ⚠️ 游戏退出回调异常: $e');
              }
            }
          } else {
            // ★ v3 阶段 2：误启动会话也写入事实表，但 exit_reason='aborted'
            // 这样用户可以看到所有启动记录，但重建统计时会过滤掉 < 60s 的
            session.exitReason = 'aborted';
            // ★ 日志：记录误启动退出
            await GameLaunchLogger.instance.logGameExit(
              gameTitle: session.gameTitle,
              durationSeconds: session.accumulatedSeconds,
              exitReason: 'aborted(误启动<${_minSessionSeconds}s)',
            );
            try {
              await GameDataFormat.appendSession(
                  session.metaDataDir, session.toSessionRecord());
            } catch (e) {
              debugPrint('[PLAYTIME] ⚠️ 追加误启动会话记录失败: $e');
            }
            debugPrint(
                '[PLAYTIME] ⏭️ ${session.gameTitle} 误启动过滤（< ${_minSessionSeconds}s），不触发退出回调');
          }
          completedSessions.add(metaDataDir);
        }
      }
    }

    for (final dirPath in completedSessions) {
      _activeGameSessions.remove(dirPath);
      // ★ v3 阶段 4: 同时取消对应的前台检测定时器
      _foregroundCheckTimers[dirPath]?.cancel();
      _foregroundCheckTimers.remove(dirPath);
      // ★ 重构: 同时清理前台状态共享 Map
      _foregroundStates.remove(dirPath);
    }

    // 通知 UI 刷新
    if (playTimeChanged) {
      _notifyPlayTimeUpdate();
    }
  }

  /// ★ 重构: tasklist 回退方案（Win32ProcessService FFI 不可用时使用）
  ///
  /// 保留旧 tasklist CSV 解析逻辑作为降级路径。FFI 在 Windows 上几乎总是可用，
  /// 此方法仅在 FFI 初始化失败（如 kernel32.dll 缺失）时被调用。
  /// 抛出异常表示 tasklist 失败（超时/进程不存在），由调用方处理。
  Future<(Set<int>, Map<String, Set<int>>)>
      _getRunningProcessInfoLegacy() async {
    final runningPids = <int>{};
    final runningNameToPids = <String, Set<int>>{};

    final result = await Process.run(
      'tasklist',
      ['/FO', 'CSV', '/NH'],
    ).timeout(const Duration(seconds: 10), onTimeout: () {
      debugPrint('[PLAYTIME] ⚠️ tasklist 超时(10s)');
      throw TimeoutException('tasklist timeout');
    });
    final output = result.stdout.toString();
    for (final line in output.split('\n')) {
      final match = RegExp(r'^"([^"]+)","(\d+)"').firstMatch(line.trim());
      if (match != null) {
        final name = match.group(1)!.toLowerCase();
        final pid = int.tryParse(match.group(2)!) ?? 0;
        if (pid > 0) {
          runningPids.add(pid);
          if (name.endsWith('.exe')) {
            // ★ Fix 1.1：建立 name→PIDs 映射（同名多实例时累积全部 PID）
            runningNameToPids.putIfAbsent(name, () => <int>{}).add(pid);
          }
        }
      }
    }

    return (runningPids, runningNameToPids);
  }

  /// ★ v2: 扫描游戏目录下所有运行中的进程 PID
  /// 借鉴 ReinaManager get_processes_in_directory
  /// 用于会话创建时的初始候选集 + missCount=3 时的重扫描
  Future<Set<int>> _scanGameDirPids(String gameDir) async {
    final pids = <int>{};
    if (gameDir.isEmpty) return pids;

    // ★ 重构: 使用 Win32 FFI 替代 PowerShell Get-CimInstance
    // ★ 安全兜底: FFI 枚举到 0 个进程时（结构体错误等运行时异常），
    // 回退到 PowerShell，避免候选 PID 集恒为空
    if (Win32ProcessService.isAvailable) {
      final allProcs = Win32ProcessService.enumerateProcesses();
      if (allProcs.isNotEmpty) {
        // FFI 正常工作，筛选游戏目录下的进程
        return Win32ProcessService.getProcessesInDirectory(gameDir);
      }
      debugPrint(
          '[PLAYTIME] ⚠️ FFI enumerateProcesses 返回空，_scanGameDirPids 回退到 PowerShell');
    }
    // Fallback: PowerShell（FFI 不可用或返回空时使用）

    try {
      // 使用 PowerShell Get-CimInstance 查询进程路径（比 tasklist 更准确）
      final escapedDir = gameDir.replaceAll("'", "''");
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Get-CimInstance Win32_Process | Where-Object { \$_.ExecutablePath -like '$escapedDir*' } | Select-Object -ExpandProperty ProcessId",
        ],
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('[PLAYTIME] ⚠️ 扫描游戏目录进程超时(5s)');
        throw TimeoutException('scan game dir timeout');
      });

      final stdout = result.stdout.toString();
      for (final line in stdout.split('\n')) {
        final pid = int.tryParse(line.trim());
        if (pid != null && pid > 0) {
          pids.add(pid);
        }
      }
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 扫描游戏目录进程失败: $e');
    }
    return pids;
  }

  /// ★ 重构: 统一前台检测（替代 per-session _startForegroundHook + _checkForeground）
  ///
  /// 对应 ReinaManager 的 start_foreground_hook + update_foreground_state。
  /// 由单个 _foregroundTimer (500ms) 驱动，遍历所有活跃会话的前台状态。
  void _checkForegroundAll() {
    if (_foregroundStates.isEmpty) return;

    // ★ Fix 1.3：FFI 不可用时降级为存活即累加（playtime 模式退化为 elapsed）
    // 保持与旧 _startForegroundHook 一致的降级语义，确保至少有记录。
    if (!ForegroundWindowService.isAvailable) {
      for (final state in _foregroundStates.values) {
        state.isForeground = true;
      }
      return;
    }

    final fgPid = ForegroundWindowService.getForegroundPid();

    if (fgPid == null) {
      // 无前台窗口 → 所有会话标记为非前台
      for (final state in _foregroundStates.values) {
        state.isForeground = false;
      }
      return;
    }

    for (final entry in _foregroundStates.entries) {
      final metaDataDir = entry.key;
      final state = entry.value;
      final session = _activeGameSessions[metaDataDir];
      if (session == null) continue;

      // 1. 检查前台 PID 是否在候选集中
      if (session.candidatePids.contains(fgPid)) {
        if (!state.isForeground) {
          debugPrint('[FG-CHECK] ✅ ${session.gameTitle} 进入前台 (PID: $fgPid)');
        }
        state.isForeground = true;
        continue;
      }

      // 2. 检查是否为 bestPid
      if (session.bestPid != null && session.bestPid == fgPid) {
        if (!state.isForeground) {
          debugPrint(
              '[FG-CHECK] ✅ ${session.gameTitle} 进入前台 (bestPid: $fgPid)');
        }
        state.isForeground = true;
        session.candidatePids.add(fgPid);
        continue;
      }

      // 3. 逃逸检测：查询前台进程 exe 路径
      final exePath = ForegroundWindowService.getProcessExePath(fgPid);
      if (exePath != null) {
        if (ForegroundWindowService.isSubPath(exePath, state.gameDir)) {
          // 逃逸进程：加入候选集
          debugPrint(
              '[FG-CHECK] 🔍 ${session.gameTitle} 逃逸进程检测: PID=$fgPid 路径=$exePath');
          session.candidatePids.add(fgPid);
          state.isForeground = true;
          continue;
        } else {
          // 确定性判定：前台窗口不属于游戏
          if (state.isForeground) {
            debugPrint('[FG-CHECK] ❌ ${session.gameTitle} 进入后台');
          }
          state.isForeground = false;
          continue;
        }
      }

      // exePath == null：无法确定（PowerShell/FFI 失败），保持当前状态
      // ★ 与 Fix 2.4 一致：不因检测失败而误判为后台
    }
  }

  /// 获取游戏当前总游玩时长（从内存）
  int _getGamePlayTime(String gameTitle) {
    final game = getGameByTitle(gameTitle);
    return game?.playTime ?? 0;
  }

  /// 直接写入游玩时长到 game.json（不依赖 readGameJson）
  /// 使用 GameDataFormat.updateGameJsonAtomic 原子操作，消除竞态
  ///
  /// ★ 核心原则：文件是 play_time 的唯一真相源。
  /// 返回 true 表示写入成功，false 表示失败（M1: 调用方据此决定是否累加内存）
  Future<bool> _writePlayTimeDirect(
      String metaDataDir, int secondsToAdd) async {
    if (secondsToAdd <= 0) return false;
    try {
      int? newPlayTime;
      // ★ 使用原子操作同时写入 play_time 和 daily_play_log
      final success =
          await GameDataFormat.updateGameJsonAtomic(metaDataDir, (current) {
        final filePlayTime = (current['play_time'] as num?)?.toInt() ?? 0;
        newPlayTime = filePlayTime + secondsToAdd;

        // 兼容旧格式 daily_play_log
        Map<String, dynamic> dailyLog = {};
        final existing = current['daily_play_log'];
        if (existing is Map) {
          dailyLog = Map<String, dynamic>.from(existing);
          for (final key in dailyLog.keys.toList()) {
            final val = dailyLog[key];
            if (val is num) {
              dailyLog[key] = {'seconds': val.toInt(), 'count': 0};
            }
          }
        }

        final today = DateTime.now();
        final dateKey =
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

        final todayEntry = (dailyLog[dateKey] as Map<String, dynamic>?) ??
            {'seconds': 0, 'count': 0};
        final todaySeconds = (todayEntry['seconds'] as num?)?.toInt() ?? 0;
        todayEntry['seconds'] = todaySeconds + secondsToAdd;
        dailyLog[dateKey] = todayEntry;

        // 清理超过90天的旧数据
        final cutoff = today.subtract(const Duration(days: 90));
        dailyLog.removeWhere((key, _) {
          final date = DateTime.tryParse(key);
          return date == null || date.isBefore(cutoff);
        });

        return {
          'play_time': newPlayTime,
          'daily_play_log': dailyLog,
        };
      });

      // ★ 写入成功后同步内存
      if (success && newPlayTime != null) {
        try {
          final game =
              _games.values.firstWhere((g) => g.metaDataDir == metaDataDir);
          game.playTime = newPlayTime!;
        } catch (_) {
          // 游戏可能已被删除，跳过内存同步
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 写入play_time失败: $e');
      return false;
    }
  }

  /// 记录当日游玩次数+1（游戏启动时调用）
  /// 使用 GameDataFormat.incrementDailyPlayCount 原子操作，消除竞态
  Future<void> _incrementDailyPlayCount(String metaDataDir) async {
    try {
      await GameDataFormat.incrementDailyPlayCount(metaDataDir);
      debugPrint('[PLAYTIME] 📊 当日游玩次数+1');
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 记录游玩次数失败: $e');
    }
  }

  /// 检测游戏是否仍在运行
  /// ★ C7: 优先检测 primaryExe（用户启动的主 exe），
  /// 其次检测 monitoredExes 中的其他 exe（子进程）。
  /// 避免启动器型游戏中启动器存活导致会话永不结束。
  bool _isGameStillRunning(
      _GameSession session, Set<int> runningPids, Set<String> runningNames) {
    // 检测1：PID 直接检测
    // ★ 重构: launchedPid → bestPid
    if (session.bestPid != null && runningPids.contains(session.bestPid)) {
      return true;
    }
    // ★ C7: 优先检测 primaryExe（用户启动的主 exe，进程检测主指标）
    if (session.primaryExe != null &&
        runningNames.contains(session.primaryExe)) {
      return true;
    }
    // ★ Fix 2.3：primaryExe 退出时，检查 monitoredExes 是否有子进程在运行
    //
    // 旧 C7 逻辑：primaryExe 退出立即 return false。对启动器型游戏（启动器启动
    // 游戏后自身退出）这是致命错误——_isGameStillRunning 恒返回 false →
    // missCount 累积到3 → 重扫描发现游戏子进程 PID → 重置 missCount →
    // 下个 tick C7 又返回 false → 循环往复。会话成为"僵尸"：
    //   • 永不累加时长（isRunning=false 不进入累加分支）
    //   • 永不移除（重扫描不断重置 missCount）
    //   • 用户游玩数小时，记录零时长
    //
    // 新逻辑：primaryExe 退出时，若 monitoredExes 有在运行的进程（游戏子进程
    // 接管），判定游戏仍在运行。仅当 primaryExe 和所有 monitoredExes 都退出
    // 才判定结束。monitoredExes 已由 _scanGameExes 的 excludeKeywords 排除
    // uninstall/setup/installer/magpie/leproc，避免配置/超分工具存活导致
    // 会话永不结束。
    return session.monitoredExes.any((exe) => runningNames.contains(exe));
  }

  /// 扫描游戏目录中的 exe 文件名（含子目录），用于多 exe 监控
  /// 限制扫描深度和数量，避免大目录导致超时
  /// 过滤 uninstall/setup/installer 等非游戏进程，避免误判
  ///
  /// ★ RC5 改进：仅排除明确的卸载/安装程序，保留启动器/配置工具，
  /// 因为启动器型游戏可能在运行期间保持启动器进程存活
  Future<Set<String>> _scanGameExes(String gameDir,
      {String? launchedExe}) async {
    final exeNames = <String>{};

    // 始终包含启动的 exe
    if (launchedExe != null && launchedExe.isNotEmpty) {
      exeNames.add(launchedExe.toLowerCase());
    }

    // ★ H10: 排除超分/转区工具 exe（它们在游戏运行期间存活会导致误判）
    // ★ L3: 用 'setup' 而非 'setup.exe' 以正确匹配 setup_x64.exe
    const excludeKeywords = [
      'uninstall', 'unins', 'setup', 'installer',
      'magpie', 'leproc', 'localeemulator', // ★ H10: 超分/转区工具
    ];

    try {
      final dir = Directory(gameDir);
      if (await dir.exists()) {
        int count = 0;
        // ★ M4: followLinks: false 避免符号链接导致扫描越界
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
            final basename = p.basename(entity.path).toLowerCase();
            // 过滤非游戏进程
            if (excludeKeywords.any((kw) => basename.contains(kw))) {
              continue;
            }
            // 计算相对路径深度（兼容 / 和 \ 分隔符）
            final relative = entity.path.substring(dir.path.length);
            final depth = '\\'.allMatches(relative).length +
                '/'.allMatches(relative).length;
            if (depth <= 3) {
              exeNames.add(basename);
              count++;
              if (count >= 50) break;
            }
          }
        }
      }
    } catch (_) {}

    debugPrint('[PLAYTIME] 监控的exe列表: $exeNames');
    return exeNames;
  }

  /// 清理所有游戏会话和定时器（用于应用退出时）
  /// ★ v3 阶段 2: 退出前持久化未写入的 pending delta + 写入会话记录到事实表
  ///
  /// 仅写入"已确认存活但未落盘"的部分（≤ 2 倍间隔）
  /// ★ 重构: lastConfirmedAliveTime 已移除，用 now 代替（误差 ≤ 2s）
  ///
  /// 异步方法：会话记录写入需要 await，调用方需 await 本方法
  /// 已在 tray_service._exitApp 和 custom_title_bar.performCleanExit 中适配
  Future<void> disposeAllSessions() async {
    _playTimeMonitor?.cancel();
    _playTimeMonitor = null;
    // ★ v3 阶段 4: 取消所有前台检测定时器
    for (final timer in _foregroundCheckTimers.values) {
      timer.cancel();
    }
    _foregroundCheckTimers.clear();
    // ★ 重构: 取消统一前台检测定时器 + 清理状态 Map
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
    _foregroundStates.clear();

    final now = DateTime.now();
    for (final session in _activeGameSessions.values) {
      // ★ 重构: lastConfirmedAliveTime 已移除，用 now 近似（退出时最近一次检测 ≤ 2s）
      final pendingDelta = now.difference(session.lastSettledTime).inSeconds;
      // ★ 仅写入合理范围内的 pending delta（≤ 2 倍间隔）
      if (pendingDelta > 0 && pendingDelta <= _monitorIntervalSec * 2) {
        _writePlayTimeDirect(session.metaDataDir, pendingDelta);
        // ★ v3 阶段 2：累加到 accumulatedSeconds 以反映最终会话时长
        session.accumulatedSeconds += pendingDelta;
      }

      // ★ v3 阶段 2：写入会话记录到事实表（应用退出场景）
      // exit_reason='app_shutdown' 标记应用正常退出时结算
      if (session.accumulatedSeconds >= _minSessionSeconds) {
        session.exitReason = 'app_shutdown';
        // ★ 日志：记录应用退出时的游戏退出
        await GameLaunchLogger.instance.logGameExit(
          gameTitle: session.gameTitle,
          durationSeconds: session.accumulatedSeconds,
          exitReason: 'app_shutdown(应用退出)',
        );
        try {
          await GameDataFormat.appendSession(
              session.metaDataDir, session.toSessionRecord());
        } catch (e) {
          debugPrint('[PLAYTIME] ⚠️ 应用退出时追加会话记录失败: $e');
        }
      }
    }
    _activeGameSessions.clear();
    debugPrint('[PLAYTIME] 所有会话已清理（含事实表写入）');
  }

  /// ★ v2: 从 SharedPreferences 加载追踪模式
  /// 在应用启动时调用，默认 playtime（精准模式）
  Future<void> loadTrackingMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString('time_tracking_mode') ?? 'playtime';
      _globalTrackingMode = modeStr == 'elapsed'
          ? TimeTrackingMode.elapsed
          : TimeTrackingMode.playtime;
      debugPrint('[PLAYTIME] 📊 追踪模式: $_globalTrackingMode');
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 加载追踪模式失败，使用默认 playtime: $e');
      _globalTrackingMode = TimeTrackingMode.playtime;
    }
  }

  /// ★ v2: 设置追踪模式（供设置页面调用）
  Future<void> setTrackingMode(TimeTrackingMode mode) async {
    _globalTrackingMode = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('time_tracking_mode',
          mode == TimeTrackingMode.elapsed ? 'elapsed' : 'playtime');
      debugPrint('[PLAYTIME] 📊 追踪模式已切换为: $mode');
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 保存追踪模式失败: $e');
    }
  }

  /// ★ v2: 异常恢复——应用启动时检查未正常结束的会话
  /// 借鉴 ReinaManager 的设计：应用崩溃后重启，检测游戏是否仍在运行
  /// 如果在运行，重新创建会话恢复追踪
  Future<void> recoverPendingSessions() async {
    try {
      for (final game in _games.values) {
        // 检查 last_opened_at 是否在最近 2 小时内
        if (game.lastOpenedAt.isEmpty) continue;
        final lastOpened = DateTime.tryParse(game.lastOpenedAt);
        if (lastOpened == null) continue;
        final elapsed = DateTime.now().difference(lastOpened);
        if (elapsed.inHours > 2) continue; // 超过 2 小时不恢复

        // 当前已有活跃会话则跳过
        if (_activeGameSessions.containsKey(game.metaDataDir)) continue;

        // 扫描游戏目录进程
        final pids = await _scanGameDirPids(game.directoryPath);
        if (pids.isNotEmpty) {
          debugPrint('[PLAYTIME] 🔄 恢复未结束的会话: ${game.title} (PIDs: $pids)');
          await _startPlayTimeTrackingInternal(
            game,
            null,
            pids.first,
          );
          // ★ v3 阶段 2：标记恢复会话的 exitReason
          // 这样在会话结束时写入事实表的 exit_reason 字段为 'recovered'
          // 表示这是一个崩溃后恢复的会话（开始时间来自 lastOpenedAt，可能少算）
          final recoveredSession = _activeGameSessions[game.metaDataDir];
          if (recoveredSession != null) {
            recoveredSession.exitReason = 'recovered';
          }
        }
      }
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 异常恢复失败: $e');
    }
  }

  /// ★ 诊断方法：获取所有活跃会话的状态信息
  /// 用于排查"时长不统计"问题——调用方可打印此结果查看会话是否真的在运行
  List<Map<String, dynamic>> getActiveSessionsInfo() {
    final now = DateTime.now();
    return _activeGameSessions.entries.map((e) {
      final s = e.value;
      // ★ 重构: 前台状态从 _foregroundStates 读取（由 500ms 定时器更新）
      final isFg = _foregroundStates[e.key]?.isForeground ?? false;
      return {
        'metaDataDir': e.key,
        'gameTitle': s.gameTitle,
        'primaryExe': s.primaryExe,
        'monitoredExes': s.monitoredExes.toList(),
        'bestPid': s.bestPid, // ★ 重构: launchedPid → bestPid
        'trackingMode': s.trackingMode.toString().split('.').last,
        'isForeground': isFg, // ★ 重构: 从 _foregroundStates 读取
        'candidatePids': s.candidatePids.toList(),
        'accumulatedSeconds': s.accumulatedSeconds,
        'missCount': s.missCount,
        'consecutiveWriteFails': s.consecutiveWriteFails,
        // ★ 重构: lastConfirmedAliveTime 已移除，用 now 近似
        'lastSettledAgeSec': now.difference(s.lastSettledTime).inSeconds,
        'sessionDurationMin': now.difference(s.startTime).inMinutes,
      };
    }).toList();
  }

  /// ★ 诊断方法：获取定时器和进程检测的运行状态
  Map<String, dynamic> getMonitorStatus() {
    return {
      'monitorActive': _playTimeMonitor?.isActive ?? false,
      'foregroundTimerActive': _foregroundTimer?.isActive ?? false, // ★ 重构
      'foregroundHookActive': _foregroundCheckTimers.isNotEmpty, // 旧字段，保留兼容
      'foregroundStateCount': _foregroundStates.length, // ★ 重构
      'monitorIntervalSec': _monitorIntervalSec,
      'foregroundCheckIntervalMs':
          _foregroundCheckInterval.inMilliseconds, // ★ 重构
      'isCheckingSessions': _isCheckingSessions,
      'tasklistFailCount': _tasklistFailCount,
      'tasklistFailThreshold': _tasklistFailThreshold,
      'writeFailThreshold': _writeFailThreshold,
      'activeSessionCount': _activeGameSessions.length,
      'missThreshold': _missThreshold,
      'trackingMode': _globalTrackingMode.toString().split('.').last,
      'ffiAvailable': ForegroundWindowService.isAvailable,
      'win32ProcessAvailable': Win32ProcessService.isAvailable, // ★ 重构
    };
  }

  /// 自动备份：游戏退出后自动扫描并备份存档
  Future<void> _triggerAutoBackup(String gameTitle, String gameDir) async {
    try {
      debugPrint('[AUTO-BACKUP] 🔄 开始自动备份: $gameTitle');
      final scanner = SaveScanner();
      final detected = scanner.scanGameSaves(
        gameTitle,
        gameDir,
        manifestEntry: ManifestService.instance.lookup(gameTitle),
      );

      // 合并自定义路径扫描结果（去重）
      final prefs = await SharedPreferences.getInstance();
      final customPaths = prefs.getStringList('save_custom_paths_$gameTitle') ?? [];
      if (customPaths.isNotEmpty) {
        final customDetected = scanner.scanCustomPaths(customPaths, gameDir);
        final existing = detected.map((f) => f.filePath).toSet();
        for (final f in customDetected) {
          if (!existing.contains(f.filePath)) {
            detected.add(f);
          }
        }
      }

      if (detected.isEmpty) {
        debugPrint('[AUTO-BACKUP] ℹ️ 未检测到存档文件，跳过备份');
        return;
      }
      final savePaths = detected.map((f) => f.filePath).toList();
      final backup = await SaveBackupService.instance.autoBackup(
        gameTitle,
        savePaths,
      );
      debugPrint(
          '[AUTO-BACKUP] ✅ 自动备份完成: ${backup.name} (${backup.fileCount}个文件)');
    } catch (e) {
      debugPrint('[AUTO-BACKUP] ❌ 自动备份失败: $e');
    }
  }

  void unregisterGame(String title) {
    final game = getGameByTitle(title);
    if (game != null) {
      // 通过 metaDataDir 找到 _games 的 key
      String? key;
      for (final entry in _games.entries) {
        if (entry.value.metaDataDir == game.metaDataDir) {
          key = entry.key;
          break;
        }
      }
      if (key != null) {
        _removeByDirName(key);
      }
    }
    debugPrint('[LOCAL-REGISTRY] 🗑️ 移除注册: $title');
  }
}
