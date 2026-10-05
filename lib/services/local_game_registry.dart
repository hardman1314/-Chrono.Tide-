import 'dart:io';
import 'dart:async';
import 'dart:convert';
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
import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';
import '../utils/game_key.dart';
import '../utils/game_config_manager.dart'; // 迁移收尾：启动配置同步（兼容读取，见 P0-2）
import 'storage/cleanup_utils.dart';
import 'nsfw/nsfw_detection_store.dart'; // P1-4: 删游戏时清理其 NSFW 判定缓存
import 'company_alias_store.dart'; // ★ 会社归一化（v4）：company_id 解析
import 'tag_vocabulary_store.dart'; // ★ 标签归一化（全局重命名/删除口径）
import 'company_alias_pending.dart'; // ★ 会社归一化（v4）：未命中漏斗

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

/// 游戏标记（库页卡片徽标 / 上下文菜单）
///
/// ⚠️ [favorite] 目前**没有 UI 入口**：`toggleMark` 只在 [none] / [star]
/// 之间翻转，`_persistMarkToGameJson` 也只是照实把已有值写回。
/// 保留这个取值的理由是**读兼容**：早期版本允许三态，老 game.json 里
/// 可能有 `mark: "favorite"`。删掉枚举值会让 `_parseMark` 落到 default 分支，
/// 把老数据静默降级成 none —— 那不是"清理死代码"，是丢信息。
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

  /// ★ 运行任务横幅：会话是否已首次确认进程存活
  ///
  /// 用于在「游戏进程真正跑起来」的那一刻触发一次
  /// [LocalGameRegistry.onGameSessionConfirmed] 回调，驱动横幅从「正在启动」
  /// 切换到「运行中」并开始墙钟计时。
  /// 每个会话生命周期内只会从 false 翻转到 true 一次。
  bool confirmed;

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
        exitReason = 'normal',
        confirmed = false;

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
///
/// 实现已统一到 [GameKey.generateId]（P0-1：全项目只保留一处随机 ID 生成），
/// 这里保留函数名只是为了不打散既有调用点。
String _generateSessionId() => GameKey.generateId();

class LibraryGame {
  /// 稳定主键（对应 game.json 的 `game_id`，UUID v4）。
  ///
  /// 🔴 与 [metaDataDir] / 目录名的区别：元数据目录名会随标题改动而重命名，
  /// [directoryPath] 会随用户搬移游戏而变——只有本字段**一辈子不变**。
  ///
  /// 用途：① [LocalGameRegistry.getGameById] 的键 ② `_byIdIndex`
  /// ③ 未来 `library_index.db` 的主键。老数据可能为空串（尚未经过
  /// v2 迁移），所有读取方必须容忍空值，不得假定非空。
  String gameId;

  String title;
  String directoryPath;
  String metaDataDir;
  String installedAt;

  /// ⚠️ 命名与实际内容不符（P2-3）：这里存的是**本地封面文件的绝对路径**，
  /// 不是 URL。[coverPath] 是同一份数据的别名 getter。
  /// 之所以不改名：该字段有 232 处引用，且多个不相关类（WatchFolder /
  /// GameModel / SDK）也有同名字段，机械替换会误伤；改名收益仅是"读起来更顺"，
  /// 不足以承担这个面积的风险。读取方请以本注释为准。
  String coverUrl;

  /// ★ 2026-10-04 横幅封面：本地横幅图片文件的**绝对路径**（空串 = 无横幅）。
  ///
  /// 与 [coverUrl] 同源（game.json `banner_file` → 磁盘探测），扫描时填充。
  /// UI 使用优先级：BPM 背景 / 主页大图**横幅优先**，缺失回退 [coverUrl]。
  String bannerUrl;
  String description;
  List<String> tags;
  GameMark mark;
  String launchPath;
  String source;
  String developer;

  /// 会社归一化解析结果（会社词典 `CompanyAliasStore` 的 company_id，可空）。
  ///
  /// 与 [developer]（原文）并存：筛选 / 智能归纳分组以本字段优先、原文兜底。
  /// null = 未解析（老数据 / 词典未命中 / 词典未加载）；
  /// [LocalGameRegistry.scan] 的 backfill 会为「有原文无 id」的条目补算。
  int? companyId;
  PlayStatus playStatus;
  int playTime;
  bool isBlurred;
  String firstOpenedAt;
  String lastOpenedAt;
  /// 已下载到本地的截图文件名清单（**渲染只看这个**）
  List<String> screenshotFiles;
  // ===== 截图异步抓取相关字段 =====

  /// 元数据源给的原始截图 URL 清单（**源**，不参与渲染）
  ///
  /// 详见 `GameJsonData.screenshotUrls` 的语义说明：urls = 源，files = 产物。
  List<String> screenshotUrls;
  // 截图下载状态：pending | downloading | completed | failed
  String screenshotStatus;
  // 失败重试次数
  int screenshotRetryCount;
  // 元数据源（如 VNDB/Bangumi）与源内 ID，用于 ImportDedupIndex 源 ID 排重维度
  String metadataSource;
  String metadataSourceId;

  /// ★ 2026-09-26 P1-4：云端来源主键（探索库云端记录 record.id）。
  /// 安装入库时写入 game.json 的 `cloud_game_id`；空 = 老数据/非云端来源。
  /// 「是否已安装」按它优先判定（[isCloudGameInstalled]），不受本地改标题影响。
  final String cloudGameId;
  // 副标题：与主标题共同构成标题系统（通常为日文原版标题），用户可自定义
  String subtitle;
  // 所属收藏夹 ID 列表（多对多），持久化于 game.json 的 collection_ids
  List<String> collectionIds;

  // ===== 游戏数据保存（存储状态，2026-10-02）=====
  //
  // 与 `GameJsonData.storageState` 同源，语义见 `game_storage_state_controller.dart`。
  // 库页卡片**只读这里**（零磁盘 I/O，方案 §6）—— 绝不要在卡片构建期去探磁盘。

  /// 存储状态：`normal` / `sealed` / `packed`。
  /// ⚠️ `display_only` 是派生态，**不写盘**，因此这里不会出现它。
  String storageState;

  /// 当前生效归档目录的绝对路径（空串 = 无归档）
  String archiveDir;

  /// 归档时间（ISO8601；空串 = 无归档）
  String archiveAt;

  LibraryGame({
    this.gameId = '',
    required this.title,
    required this.directoryPath,
    required this.metaDataDir,
    required this.installedAt,
    this.coverUrl = '',
    this.bannerUrl = '',
    this.description = '',
    this.tags = const [],
    this.mark = GameMark.none,
    this.launchPath = '',
    this.source = 'download',
    this.developer = '',
    this.companyId,
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
    this.cloudGameId = '',
    this.subtitle = '',
    this.collectionIds = const [],
    this.storageState = 'normal',
    this.archiveDir = '',
    this.archiveAt = '',
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

  /// 已入库的**元数据目录名**集合（注意：不是标题）。
  ///
  /// 历史字段名 `_installedTitles` 与实际内容不符——里面装的从来都是
  /// scan 产出的 `dirName`。2026-09-19 审计时改正（P2-3）。
  /// 对外 getter 见 [installedDirNames]（旧名 [installedTitles] 保留为别名）。
  final Set<String> _installedDirNames = {};

  // ==================== 派生索引（P0-1 / P1-1） ====================
  //
  // 惰性构建：结构性变更时整体置空，下次查询重建。
  //
  // 为什么不逐条增量维护：`LibraryGame` 的 `title` / `directoryPath` 是
  // **可变公开字段**，任何一处直接赋值都会让增量索引失配，而要追踪所有
  // 赋值点本身就是这类 bug 的来源。整体重建是 O(n) 且只在结构性变更后
  // 发生一次，比"记账式维护"更难写错。
  //
  // 🔴 纪律：任何**绕过 `_notifyStructural` / `notifyDataChanged` 直接**改
  //    `_games`、`game.title`、`game.directoryPath` 的代码路径，都必须
  //    显式调用 [_invalidateIndexes]，否则查询会读到旧值。
  //    （当前所有此类路径都在本文件内，已逐一标注。）

  Map<String, LibraryGame>? _byIdIndex;
  Map<String, LibraryGame>? _byTitleIndex;
  Map<String, LibraryGame>? _byDirPathNormIndex;
  /// ★ 2026-09-26 P1-4：云端主键索引。键 = `'${metadataSource}:${metadataSourceId}'`
  /// （来源标识防不同平台 ID 撞号；探索库安装写入 `cloud:<record.id>`）。
  Map<String, LibraryGame>? _byCloudIdIndex;

  /// 建索引时 `_games` 的规模。规模变了说明集合被增删过（哪怕漏了通知），
  /// 此时强制重建——作为"忘记失效"的兜底（纯改名无法被这一步兜住，
  /// 靠上面那条纪律保证）。
  int _indexedGameCount = -1;

  /// [allGames] 的排序结果缓存与其对应的 `_games` 规模
  List<LibraryGame>? _cachedSortedGames;
  int _sortedCacheCount = -1;

  /// UX-34: 最近一次变更原因，供监听方区分处理
  RegistryChangeReason _lastChangeReason = RegistryChangeReason.structural;
  RegistryChangeReason get lastChangeReason => _lastChangeReason;

  /// 作废全部派生索引与排序缓存（P0-1 / P1-1）。
  ///
  /// 任何可能改变「有哪些游戏 / 它们的标题 / 它们的目录」的路径都必须调它。
  void _invalidateIndexes() {
    _byIdIndex = null;
    _byTitleIndex = null;
    _byDirPathNormIndex = null;
    _byCloudIdIndex = null;
    _cachedSortedGames = null;
    _sortedCacheCount = -1;
  }

  /// 惰性重建三张索引（O(n)，仅在作废后首次查询时发生）
  void _ensureIndexes() {
    if (_byIdIndex != null && _indexedGameCount == _games.length) return;
    final byId = <String, LibraryGame>{};
    final byTitle = <String, LibraryGame>{};
    final byDir = <String, LibraryGame>{};
    final byCloud = <String, LibraryGame>{};
    for (final game in _games.values) {
      // putIfAbsent：与旧实现的"线性遍历取第一个命中"保持一致的确定性
      if (game.gameId.isNotEmpty) byId.putIfAbsent(game.gameId, () => game);
      if (game.title.isNotEmpty) byTitle.putIfAbsent(game.title, () => game);
      final dirKey = PathNormalizer.forCompare(game.directoryPath);
      if (dirKey.isNotEmpty) byDir.putIfAbsent(dirKey, () => game);
      // ★ 2026-09-26 P1-4：cloud_game_id 由安装链路写入（source=cloud）
      if (game.cloudGameId.isNotEmpty) {
        byCloud.putIfAbsent('cloud:${game.cloudGameId}', () => game);
      }
    }
    _byIdIndex = byId;
    _byTitleIndex = byTitle;
    _byDirPathNormIndex = byDir;
    _byCloudIdIndex = byCloud;
    _indexedGameCount = _games.length;
  }

  /// UX-34: 结构性变更通知（新增/删除/扫描/标题修改）
  void _notifyStructural() {
    _lastChangeReason = RegistryChangeReason.structural;
    _invalidateIndexes();
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

  /// 通用数据变更通知（视图层响应式刷新入口）
  ///
  /// 供 UI / 服务在「直接修改了 LibraryGame 内存对象 + game.json 落盘」
  /// 之后调用，触发所有监听页面（库页/主页/BPM/详情）按 structural 语义
  /// 重建。与 [notifyListenersForScreenshot] 同为公开轻量入口；
  /// 注册表内部变更路径（scan/setGameCollection/...）仍走 [_notifyStructural]。
  void notifyDataChanged() {
    _lastChangeReason = RegistryChangeReason.structural;
    _invalidateIndexes();
    notifyListeners();
  }

  // ==================== 收藏夹成员关系（多对多） ====================

  /// 设置单个游戏与收藏夹的成员关系
  ///
  /// 内存即时更新，game.json 通过写队列原子落盘（C2/C3 保护），
  /// 成功后发出 structural 通知（收藏夹视图的过滤结果会变化）。
  Future<bool> setGameCollection(
      LibraryGame game, String collectionId, bool isMember) async {
    final current = game.collectionIds;
    final already = current.contains(collectionId);
    if (already == isMember) return true;

    final next = List<String>.from(current)..remove(collectionId);
    if (isMember) next.add(collectionId);
    game.collectionIds = next;

    final ok = await GameDataFormat.updateGameJsonAtomic(
        game.metaDataDir, (data) {
      final fileIds = (data['collection_ids'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final next = List<String>.from(fileIds)..remove(collectionId);
      if (isMember) next.add(collectionId);
      return {'collection_ids': next};
    });

    if (ok) {
      _notifyStructural();
    } else {
      // 写盘失败：回滚内存状态，避免 UI 与磁盘不一致
      game.collectionIds = current;
      debugPrint(
          '[LOCAL-REGISTRY] ⚠️ 收藏夹成员关系写入失败: ${game.title} / $collectionId');
    }
    return ok;
  }

  /// 删除收藏夹后，清理所有游戏对该收藏夹的引用（批量清引用）
  Future<void> removeCollectionReferences(String collectionId) async {
    final affected =
        _games.values.where((g) => g.collectionIds.contains(collectionId));
    var count = 0;
    for (final game in affected) {
      game.collectionIds = List<String>.from(game.collectionIds)
        ..remove(collectionId);
      await GameDataFormat.updateGameJson(
          game.metaDataDir, {'collection_ids': game.collectionIds});
      count++;
    }
    if (count > 0) {
      debugPrint('[LOCAL-REGISTRY] 🗑️ 已清理收藏夹引用: $collectionId ($count个游戏)');
      _notifyStructural();
    }
  }

  /// 添加 / 移除某个标签（智能归纳板块的"写穿"入口）
  ///
  /// 智能归纳的成员关系是**派生**的（标签组 = 含有该标签的游戏集合），
  /// 因此"把游戏加入/移出标签组"在本项目里的正确做法就是增删游戏自己的标签，
  /// 而不是另外维护一份成员表——否则会出现分组与数据脱节的双份事实。
  /// 写法与 [setGameCollection] 完全对齐（原子写入 game.json + 失败回滚内存）。
  Future<bool> setGameTag(LibraryGame game, String tag, bool enabled) async {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return false;

    final current = game.tags;
    final already = current.contains(trimmed);
    if (already == enabled) return true;

    final next = List<String>.from(current)..remove(trimmed);
    if (enabled) next.add(trimmed);
    game.tags = next;

    final ok = await GameDataFormat.updateGameJsonAtomic(
        game.metaDataDir, (data) {
      final fileTags = (data['tags'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final nextTags = List<String>.from(fileTags)..remove(trimmed);
      if (enabled) nextTags.add(trimmed);
      return {'tags': nextTags};
    });

    if (ok) {
      _notifyStructural();
    } else {
      game.tags = current; // 写盘失败：回滚内存，避免 UI 与磁盘不一致
      debugPrint('[LOCAL-REGISTRY] ⚠️ 标签写入失败: ${game.title} / $trimmed');
    }
    return ok;
  }

  /// **全局重命名标签**（写穿：改写库内所有游戏的 `tags`，2026-10-04）。
  ///
  /// 匹配口径 = [TagVocabularyStore.normalizeTag] 归一化相等（容忍别名变体：
  /// 大小写 / 全半角 / 标点差异的同一标签都会被改写）；替换值 = [newTag] 原文。
  ///
  /// - 逐游戏原子写 `game.json`，单游戏失败只回滚该游戏并继续（不中断整批）；
  /// - 返回成功改写的游戏数（0 = 无游戏命中或全部失败）；
  /// - 成功后 `_notifyStructural()` **只发一次**（循环内不发，防通知风暴）。
  ///
  /// ⚠️ 不可逆操作（直接改游戏数据），调用方必须先做二次确认。
  Future<int> renameTagEverywhere(String oldTag, String newTag) async {
    final oldN = TagVocabularyStore.normalizeTag(oldTag);
    final nt = newTag.trim();
    if (oldN.isEmpty || nt.isEmpty) return 0;

    var okCount = 0;
    for (final game in List<LibraryGame>.of(allGames)) {
      if (!game.tags.any((t) => TagVocabularyStore.normalizeTag(t) == oldN)) {
        continue;
      }
      final prev = game.tags;
      // 内存先行（保序 + 去重：目标名可能已存在于该游戏）
      final next = <String>{
        for (final t in prev)
          TagVocabularyStore.normalizeTag(t) == oldN ? nt : t,
      }.toList();
      game.tags = next;

      final ok = await GameDataFormat.updateGameJsonAtomic(
          game.metaDataDir, (data) {
        final fileTags = (data['tags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        return {
          'tags': <String>{
            for (final t in fileTags)
              TagVocabularyStore.normalizeTag(t) == oldN ? nt : t,
          }.toList(),
        };
      });

      if (ok) {
        okCount++;
      } else {
        game.tags = prev; // 写盘失败：回滚内存
        debugPrint('[LOCAL-REGISTRY] ⚠️ 全局重命名失败: ${game.title} / $oldN');
      }
    }
    if (okCount > 0) _notifyStructural();
    return okCount;
  }

  /// **全局删除标签**（写穿：从库内所有游戏的 `tags` 中移除，2026-10-04）。
  ///
  /// 匹配口径与 [renameTagEverywhere] 一致（归一化相等）。
  /// 返回成功改写的游戏数。⚠️ 不可逆操作，调用方必须先做二次确认。
  Future<int> removeTagEverywhere(String tag) async {
    final n = TagVocabularyStore.normalizeTag(tag);
    if (n.isEmpty) return 0;

    var okCount = 0;
    for (final game in List<LibraryGame>.of(allGames)) {
      if (!game.tags.any((t) => TagVocabularyStore.normalizeTag(t) == n)) {
        continue;
      }
      final prev = game.tags;
      game.tags = [
        for (final t in prev)
          if (TagVocabularyStore.normalizeTag(t) != n) t,
      ];

      final ok = await GameDataFormat.updateGameJsonAtomic(
          game.metaDataDir, (data) {
        final fileTags = (data['tags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        return {
          'tags': [
            for (final t in fileTags)
              if (TagVocabularyStore.normalizeTag(t) != n) t,
          ],
        };
      });

      if (ok) {
        okCount++;
      } else {
        game.tags = prev;
        debugPrint('[LOCAL-REGISTRY] ⚠️ 全局删除标签失败: ${game.title} / $n');
      }
    }
    if (okCount > 0) _notifyStructural();
    return okCount;
  }

  /// 设置游戏的存储状态（归档流程的写穿入口，2026-10-02）
  ///
  /// 三个字段**必须一起写**：状态与归档指针分开写会产生
  /// 「`storage_state=sealed` 但 `archive_dir` 为空」这类状态机无法解释的组合。
  ///
  /// 🔴 回到 `normal` 时**强制清空归档指针**，避免留下悬空路径 ——
  /// 悬空的 `archive_dir` 会让后续判定去探一个已不存在的目录。
  ///
  /// 写法与 [setGameTag] 完全对齐（原子写入 game.json + 失败回滚内存）。
  Future<bool> setStorageState(
    LibraryGame game, {
    required String storageState,
    required String archiveDir,
    required String archiveAt,
  }) async {
    final dir = storageState == 'normal' ? '' : archiveDir;
    final at = storageState == 'normal' ? '' : archiveAt;

    final prevState = game.storageState;
    final prevDir = game.archiveDir;
    final prevAt = game.archiveAt;
    if (prevState == storageState && prevDir == dir && prevAt == at) {
      return true;
    }

    game.storageState = storageState;
    game.archiveDir = dir;
    game.archiveAt = at;

    final ok = await GameDataFormat.updateGameJsonAtomic(game.metaDataDir, (_) => {
          'storage_state': storageState,
          'archive_dir': dir,
          'archive_at': at,
        });

    if (ok) {
      _notifyStructural();
    } else {
      // 写盘失败：回滚内存，避免 UI 与磁盘不一致
      game.storageState = prevState;
      game.archiveDir = prevDir;
      game.archiveAt = prevAt;
      debugPrint(
          '[LOCAL-REGISTRY] ⚠️ 存储状态写入失败: ${game.title} / $storageState');
    }
    return ok;
  }

  /// 设置游戏会社（智能归纳"会社组"的写穿入口；空串 = 清空 → 归入「未填会社」）
  ///
  /// ★ 会社归一化（v4）：写入原文的同时解析 company_id 一起落盘
  /// （null = 词典未命中 / 未加载）；未命中且原文非空时进 pending 漏斗。
  /// developer 原文不洗写为标准名（展示 / 导出兼容），分组按 companyId 归并。
  Future<bool> setGameDeveloper(LibraryGame game, String developer) async {
    final trimmed = developer.trim();
    if (game.developer == trimmed) return true;

    final current = game.developer;
    final currentCompanyId = game.companyId;
    game.developer = trimmed;
    final match = trimmed.isEmpty
        ? null
        : CompanyAliasStore.instanceOrNull?.resolve(trimmed);
    game.companyId = match?.record.companyId;

    final ok = await GameDataFormat.updateGameJsonAtomic(
        game.metaDataDir,
        (data) => {'developer': trimmed, 'company_id': game.companyId});

    if (ok) {
      if (match == null && trimmed.isNotEmpty) {
        await CompanyAliasPendingStore.instance
            .record(trimmed, sampleGameId: game.gameId);
      } else if (match != null) {
        // 命中即清待审漏斗（幂等）——词典扩批后旧 pending 条目可被消化
        await CompanyAliasPendingStore.instance
            .removeIfResolved(trimmed, match.record.companyId);
      }
      _notifyStructural();
    } else {
      game.developer = current; // 写盘失败：回滚内存
      game.companyId = currentCompanyId;
      debugPrint('[LOCAL-REGISTRY] ⚠️ 会社写入失败: ${game.title} / $trimmed');
    }
    return ok;
  }

  /// 游戏被删除时的回调（供 ScreenshotFetchService 注册以清理进度）
  ///
  /// 避免循环依赖：LocalGameRegistry 不直接依赖 ScreenshotFetchService，
  /// 而是通过此回调让 ScreenshotFetchService 自行清理已删除游戏的进度。
  void Function(String gameTitle)? onGameRemoved;

  /// 全量游戏列表，按「首次入库时间」倒序（最近添加在前）。
  ///
  /// P1-1：结果是**缓存**的。旧实现每次调用都 `toList() + sort()`，
  /// 而全库有 65 处引用（含 build 方法内的重复调用），2000 条规模下
  /// 等于每帧数千次字符串比较。
  ///
  /// 返回缓存列表的**副本**：调用方仍可自由排序 / 过滤 / 删除元素，
  /// 不会污染缓存（旧实现返回的本来就是一次性列表，语义不变）。
  List<LibraryGame> get allGames {
    final cached = _cachedSortedGames;
    if (cached != null && _sortedCacheCount == _games.length) {
      return List<LibraryGame>.of(cached);
    }
    final list = _games.values.toList();
    list.sort(_compareByInstalledAtDesc);
    _cachedSortedGames = List<LibraryGame>.unmodifiable(list);
    _sortedCacheCount = _games.length;
    return List<LibraryGame>.of(_cachedSortedGames!);
  }

  /// 「最近添加」排序口径（P2-5）：先解析成 DateTime 再比较。
  ///
  /// 旧实现直接 `String.compareTo`。ISO-8601 字符串的字典序通常等于时间序，
  /// 但只要历史数据里混入 **UTC 带 `Z`** 的值（迁移 / 外部工具写入），
  /// 字典序就不再等于时间序，排序会静默错乱且毫无提示。
  ///
  /// 不可解析时的次序：有效时间在前、空串最后（与旧行为的空值排尾一致），
  /// 其余退回字典序以保证排序稳定。
  static int _compareByInstalledAtDesc(LibraryGame a, LibraryGame b) {
    final ta = DateTime.tryParse(a.installedAt);
    final tb = DateTime.tryParse(b.installedAt);
    if (ta != null && tb != null) {
      final byTime = tb.compareTo(ta);
      if (byTime != 0) return byTime;
      // 同一时刻的不同写法（带/不带毫秒）：用原串做确定性兜底
      return b.installedAt.compareTo(a.installedAt);
    }
    if (ta != null) return -1;
    if (tb != null) return 1;
    final aEmpty = a.installedAt.isEmpty;
    final bEmpty = b.installedAt.isEmpty;
    if (aEmpty != bEmpty) return aEmpty ? 1 : -1;
    return b.installedAt.compareTo(a.installedAt);
  }

  int get gameCount => _games.length;

  Map<String, LibraryGame> get gamesMap => Map.unmodifiable(_games);

  /// 已入库的元数据目录名集合（P2-3：旧名 `installedTitles` 名不副实）
  Set<String> get installedDirNames => Set.unmodifiable(_installedDirNames);

  /// [installedDirNames] 的旧名，保留仅为兼容；新代码请用前者。
  Set<String> get installedTitles => installedDirNames;

  bool isTitleInstalled(String title) {
    if (title.isEmpty) return false;
    // 通过 getGameByTitle 查找，兼容标题已被修改的情况
    return getGameByTitle(title) != null;
  }

  /// 按**稳定主键**判断是否已入库（P0-1）。
  ///
  /// 旧实现是 `_games.containsKey(gameId)`——但 `_games` 的 key 是**目录名**，
  /// 于是这个"按 id 查"的 API 实际上在做"把 id 当目录名查"，永远返回 false。
  /// 现改为查 [_byIdIndex]。
  bool isGameIdInstalled(String gameId) {
    if (gameId.isEmpty) return false;
    _ensureIndexes();
    return _byIdIndex!.containsKey(gameId);
  }

  /// 按云端主键查游戏（O(1)，2026-09-26 P1-4）。
  ///
  /// 键为探索库云端记录的 record.id（安装入库时写入 game.json 的
  /// `cloud_game_id`）。老数据 / 非云端来源为空串，查不到返回 null。
  LibraryGame? getGameByCloudId(String cloudId) {
    if (cloudId.isEmpty) return null;
    _ensureIndexes();
    final hit = _byCloudIdIndex!['cloud:$cloudId'];
    if (hit != null && hit.cloudGameId == cloudId) return hit;
    return null;
  }

  /// 「这个云端作品是否已入库」——探索库安装判定的统一口径（P1-4）。
  ///
  /// 旧口径是 [isTitleInstalled]（标题精确匹配）：本地改过标题、或云端标题
  /// 与本地标题存在全角/空格/译名差异时判定失效 → 已入库游戏仍可被再次
  /// 安装，产生重复目录。现优先按稳定外部主键 [getGameByCloudId] 判定，
  /// cloudId 为空（老数据）时回退标题匹配，保持旧行为不回归。
  bool isCloudGameInstalled(String cloudId, String title) {
    if (cloudId.isNotEmpty && getGameByCloudId(cloudId) != null) return true;
    return isTitleInstalled(title);
  }

  /// 按稳定主键查游戏（O(1)，P0-1）
  LibraryGame? getGameById(String gameId) {
    if (gameId.isEmpty) return null;
    _ensureIndexes();
    final hit = _byIdIndex![gameId];
    // 命中后校验：索引可能因外部直接改字段而陈旧（见索引字段区注释）
    if (hit != null && hit.gameId == gameId) return hit;
    return null;
  }

  /// 按**游戏本体目录**查游戏（O(1)，P0-1 三张索引之一）。
  ///
  /// 键是 [PathNormalizer.forCompare] 归一化后的目录路径（反斜杠 + 小写 +
  /// 去尾斜杠），因此调用方传任何形态的路径都能命中。
  /// 用途：库页/收藏夹的排序键就是 `directoryPath`（见
  /// `docs/DEV/features/library_page_experience_overhaul_plan.md`）。
  /// 未来做 index.db 时这一维也要进表。
  LibraryGame? getGameByDirectoryPath(String directoryPath) {
    if (directoryPath.isEmpty) return null;
    _ensureIndexes();
    final key = PathNormalizer.forCompare(directoryPath);
    if (key.isEmpty) return null;
    final hit = _byDirPathNormIndex![key];
    // 命中后校验目录未变（索引陈旧的兜底）
    if (hit != null &&
        PathNormalizer.forCompare(hit.directoryPath) == key) {
      return hit;
    }
    return null;
  }

  /// 按标题查游戏（P1-1：由 O(n) 遍历改为 O(1) 索引）。
  ///
  /// 语义与旧实现保持一致：
  /// 1. 精确匹配 `title`（旧实现是线性遍历，现在查索引）；
  /// 2. 回退到「标题 → 目录名」的兼容索引（历史调用方可能直接传目录名）。
  ///
  /// 全库有 83 处调用点，其中导入排重会对每个候选调用一次——
  /// 旧实现下这是 O(候选数 × 游戏数)，也正是历史上「批量导入越跑越慢」的
  /// 原因之一。
  LibraryGame? getGameByTitle(String title) {
    if (title.isEmpty) return null;
    _ensureIndexes();
    final hit = _byTitleIndex![title];
    if (hit != null && hit.title == title) return hit;
    // 回退：兼容标题未被修改、调用方直接传目录名的历史用法
    return _games[GameKey.dirNameFromTitle(title)];
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
    // ★ 响应式修复：标记变更同步广播，星标/收藏徽标跨页面即时刷新
    _notifyStructural();
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
      _installedDirNames.remove(exactMatch);
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
          // ★ 2026-09-26 NAS 映射网络驱动器适配（P0）：
          // 网络位置（UNC / 映射盘）**离线时 exists() 返回 false**，但这不是
          // 「用户删了游戏」。若其卷根同样不可达，则视为「介质当前不可用」，
          // **保留条目** —— 否则用户断开 NAS 后启动软件，整个 NAS 库会被
          // 当作失效条目清空，重新连接后游戏「全部消失」。
          // 判定失败时方向一律为「保留」（与 ADR-007 一致）。
          if (NetworkPath.isNetwork(entry.value.directoryPath) &&
              !await NetworkPath.isVolumeReachableAsync(
                  entry.value.directoryPath)) {
            debugPrint('[LOCAL-REGISTRY] ⏸️ 网络位置暂不可达，保留条目: '
                '${entry.value.title}（${entry.value.directoryPath}）');
            continue;
          }
          staleKeys.add(entry.key);
          continue;
        }

        final ctgameFile = File('${dir.path}/${GameDataFormat.ctgameFileName}');
        if (!await ctgameFile.exists()) {
          staleKeys.add(entry.key);
        }
      } catch (e) {
        // ★ P2-6：exists() 抛异常 ≠ 路径不存在。移动硬盘/网络驱动器未就绪、
        // 权限抖动等都会在这里抛错——此时条目不应被移出库，否则用户重新挂载
        // 后会发现游戏"消失"了。只有"确认不存在"与"缺 .ctgame"两种情况才清理。
        debugPrint(
            '[LOCAL-REGISTRY] ⏭️ 检查 "${entry.value.title}" 时磁盘异常（保留条目）: $e');
      }
    }

    for (final key in staleKeys) {
      final game = _games[key];
      _games.remove(key);
      _installedDirNames.remove(key);
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
              // ★ P0-1：对齐稳定主键（老数据在首次读取时已由 v1→v2 迁移补发）
              if (gameData.gameId.isNotEmpty) {
                existingGame.gameId = gameData.gameId;
              }
              existingGame.description = gameData.description;
              existingGame.launchPath = gameData.launchPath;
              existingGame.source = gameData.source;
              existingGame.mark = _parseMark(gameData.mark);
              existingGame.developer = gameData.developer;
              existingGame.companyId = gameData.companyId;
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

              // 副标题同步（game.json 持有事实数据，与标题一致全量覆盖）
              existingGame.subtitle = gameData.subtitle;

              // 截图相关字段同步
              existingGame.screenshotFiles = gameData.screenshotFiles;
              existingGame.screenshotUrls = gameData.screenshotUrls;
              existingGame.screenshotStatus = gameData.screenshotStatus;
              existingGame.screenshotRetryCount = gameData.screenshotRetryCount;

              // 收藏夹归属同步（game.json 持有事实数据，空列表也需覆盖）
              existingGame.collectionIds = gameData.collectionIds;

              // ★ 2026-10-02 存储状态同步：game.json 是事实源，空值也要覆盖
              //   （用户可能在外部把归档删了 / 手动改了状态，重扫必须如实反映）
              existingGame.storageState = gameData.storageState;
              existingGame.archiveDir = gameData.archiveDir;
              existingGame.archiveAt = gameData.archiveAt;

              if (gameData.tags.isNotEmpty) {
                existingGame.tags = gameData.tags;
              }

              if (gameData.directoryPath.isNotEmpty) {
                existingGame.directoryPath = gameData.directoryPath;
              }

              final coverFile = GameDataFormat.findCoverFile(entity.path,
                coverFileName: gameData.coverFile);
              if (coverFile != null) {
                existingGame.coverUrl = coverFile.path;
              }

              // ★ 2026-10-04 横幅封面同步：game.json 是事实源，空值也要覆盖
              //   （横幅可能被外部删除 / 重复入库被清空，重扫必须如实反映）
              final bannerFile = GameDataFormat.findBannerFile(entity.path,
                  bannerFileName: gameData.bannerFile);
              existingGame.bannerUrl = bannerFile?.path ?? '';

              updatedCount++;
            }
            foundCount++;
            continue;
          }

          final gameData = await GameDataFormat.readGameJson(entity.path);
          if (gameData != null) {
            final coverFile = GameDataFormat.findCoverFile(entity.path,
                coverFileName: gameData.coverFile);
            // ★ 2026-10-04 横幅封面：与封面同套路（json 键优先 → 磁盘探测）
            final bannerFile = GameDataFormat.findBannerFile(entity.path,
                bannerFileName: gameData.bannerFile);

            final game = LibraryGame(
              gameId: gameData.gameId,
              title: gameData.title.isNotEmpty ? gameData.title : dirName,
              directoryPath: gameData.directoryPath.isNotEmpty
                  ? gameData.directoryPath
                  : entity.path,
              metaDataDir: entity.path,
              installedAt: gameData.installedAt.isNotEmpty
                  ? gameData.installedAt
                  : DateTime.now().toIso8601String(),
              coverUrl: coverFile?.path ?? '',
              bannerUrl: bannerFile?.path ?? '',
              description: gameData.description,
              tags: gameData.tags,
              launchPath: gameData.launchPath,
              mark: _parseMark(gameData.mark),
              source: gameData.source,
              developer: gameData.developer,
              companyId: gameData.companyId,
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
              cloudGameId: gameData.cloudGameId,
              subtitle: gameData.subtitle,
              collectionIds: gameData.collectionIds,
              // ★ 2026-10-02 存储状态：老 game.json 无此键 → 默认 normal/空
              storageState: gameData.storageState,
              archiveDir: gameData.archiveDir,
              archiveAt: gameData.archiveAt,
            );

            _games[dirName] = game;
            _installedDirNames.add(dirName);
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

        // ★ 2026-10-02 存储状态门禁（方案 §9 P0，必改项）
        //
        // sealed（已封装）/ packed（已打包）的游戏，**本体目录本来就不该存在**
        // —— 那正是用户按设计删掉腾空间的结果。旧逻辑只看 `directoryPath`
        // 在不在磁盘上，会把这类条目当「失效游戏」清出内存库：用户封装完
        // 一刷新，卡片连带归档入口一起凭空消失。
        //
        // 因此：**只有 normal 态才允许按目录缺失判失效**。
        // 非正常态一律保留 —— 即便归档也被用户删了，也只降级为「仅展示」如实
        // 呈现，由用户自己决定怎么处置（方案 §4.6：不猜测，不自动清理）。
        if (game.storageState != 'normal') {
          debugPrint(
              '[LOCAL-REGISTRY] 🛡️ 保留非正常态游戏: ${game.title} '
              '(state=${game.storageState}，本体目录不存在属预期，不移除)');
          continue;
        }

        final dir = Directory(game.directoryPath);
        if (!await dir.exists()) {
          _games.remove(key);
          _installedDirNames.remove(key);
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

      // ★ 会社归一化（v4）：借扫描为「有会社原文但还没有 company_id」的
      //   老数据补算（命中才写回，一次成本；未命中进 pending 漏斗）。
      await _backfillCompanyIds();

      if (foundCount > 0 || staleKeys.length > 0) {
        _notifyStructural();
      }
    } catch (e, stackTrace) {
      debugPrint('[LOCAL-REGISTRY] ❌ 扫描异常: $e');
    }

    debugPrint('[LOCAL-REGISTRY] ========== 智能增量扫描结束 ==========');
  }

  /// 会社 backfill 本会话内已记过 pending 的原文键（防每次扫描重复计数）
  final Set<String> _backfillMissRecorded = {};

  /// 读时回填（会社归一化 v4）：为「developer 非空但 companyId 为空」的
  /// 游戏补算归一化结果。
  ///
  /// - 词典未加载 / 加载失败：整体跳过（降级，零影响，下次扫描再试）；
  /// - 命中：内存 + game.json（`company_id` 字段，走 updateGameJson 写队列）
  ///   各写一次；写盘失败回滚内存，下次扫描重试；
  /// - 未命中：进 [CompanyAliasPendingStore] 漏斗（本会话内同键只记一次，
  ///   防止扫描周期把计数刷爆），**不写 game.json**。
  Future<void> _backfillCompanyIds() async {
    final store = CompanyAliasStore.instanceOrNull;
    if (store == null) return;
    for (final game in _games.values) {
      if (game.companyId != null) continue;
      final dev = game.developer.trim();
      if (dev.isEmpty) continue;
      final match = store.resolve(dev);
      if (match == null) {
        final key = CompanyAliasStore.normalize(dev);
        if (_backfillMissRecorded.add(key)) {
          await CompanyAliasPendingStore.instance
              .record(dev, sampleGameId: game.gameId);
        }
        continue;
      }
      game.companyId = match.record.companyId;
      final ok = await GameDataFormat.updateGameJson(
          game.metaDataDir, {'company_id': match.record.companyId});
      if (ok) {
        // 命中即清待审漏斗（幂等）——词典扩批后旧 pending 条目可被消化
        await CompanyAliasPendingStore.instance
            .removeIfResolved(dev, match.record.companyId);
      } else {
        game.companyId = null; // 写盘失败：回滚内存，下次扫描重试
      }
    }
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

  /// 登记一个已完成解包/入库的游戏（内存注册表入口）。
  ///
  /// [gameId] 可选：由 [GameDataFormat.writeGameDir] 的返回值传入，
  /// 保证内存对象与磁盘 game.json 使用**同一个**稳定主键。
  /// 不传时按"读磁盘 → 没有就补发"的顺序自行解析（见 [_readOrCreateGameId]）。
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
    String? subtitle,
    String? gameId,
  }) {
    final safeName = GameKey.dirNameFromTitle(gameTitle);
    final metaDataDir = '${LocalGameRegistry.gamesBaseDir}/$safeName';

    // ★ 会社归一化（v4）：developer 变更 → company_id 同步重算。
    //   本方法是同步 API，不能等词典异步加载：词典未就位时为 null，
    //   由 scan() 的 backfill 兜底补算。
    final resolvedCompanyId =
        (developer != null && developer.trim().isNotEmpty)
            ? CompanyAliasStore.instanceOrNull
                ?.resolve(developer)
                ?.record.companyId
            : null;
    // 命中即清待审漏斗（幂等）——本方法是同步 API，不能 await：
    // remove 的内存部分同步立即生效，磁盘刷盘本就由 800ms 定时器合并；
    // 若写盘失败下次扫描 backfill 会重新命中再补写，语义无损。
    if (resolvedCompanyId != null) {
      unawaited(CompanyAliasPendingStore.instance
          .removeIfResolved(developer!, resolvedCompanyId));
    }

    if (coverUrl == null || coverUrl.isEmpty) {
      final detectedCover = GameDataFormat.findCoverFile(directoryPath);
      if (detectedCover != null) {
        coverUrl = detectedCover.path;
        debugPrint('[LOCAL-REGISTRY] 自动检测到封面: $coverUrl');
      }
    }

    // ★ 2026-10-04 横幅封面：writeGameDir 刚把 banner.* 落进元数据目录，
    //   这里同步探测一次，让内存对象立刻可用（否则要等下一次 scan）。
    //   探测目标是 metaDataDir（横幅只由应用落盘在那里），找不到 = 无横幅。
    File? detectedBanner;
    try {
      detectedBanner = GameDataFormat.findBannerFile(metaDataDir);
    } catch (_) {}
    if (detectedBanner != null) {
      debugPrint('[LOCAL-REGISTRY] 自动检测到横幅封面: ${detectedBanner.path}');
    }

    if (_games.containsKey(safeName)) {
      debugPrint('[LOCAL-REGISTRY] 📝 游戏已存在于库中，原地更新信息: $gameTitle');
      final existing = _games[safeName]!;
      existing.title = gameTitle;
      existing.directoryPath = directoryPath;
      existing.metaDataDir = metaDataDir;
      // ★ P0-1：补齐稳定主键（内存里空着才补，绝不覆盖已有值）
      if (existing.gameId.isEmpty) {
        existing.gameId = (gameId != null && gameId.isNotEmpty)
            ? gameId
            : _readOrCreateGameId(metaDataDir);
      }
      // 🔴 installedAt 语义 = "首次入库时间"，原地更新（重导同一游戏 /
      //    更新元数据 / 换封面）**不得**覆写它：库页「最近添加」排序与
      //    「手动排序下新游置顶」都依赖它，覆写会让被编辑的游戏凭空跳到最前，
      //    表现为"改个游戏资料，卡片位置全乱"。
      //    真正的首次入库时间在下方 else 分支创建对象时写入。
      //    方案：docs/DEV/features/library_page_experience_overhaul_plan.md §0 #1
      if (coverUrl != null) existing.coverUrl = coverUrl;
      // 横幅：探测到才覆盖（保留既有值，下一轮 scan 会以 game.json 为准对齐）
      if (detectedBanner != null) existing.bannerUrl = detectedBanner.path;
      if (description != null) existing.description = description;
      if (tags != null) existing.tags = tags;
      if (launchPath != null && launchPath!.isNotEmpty) {
        existing.launchPath = launchPath!;
      }
      if (developer != null) {
        existing.developer = developer!;
        existing.companyId = resolvedCompanyId;
      }
      // 元数据源：仅在传入非空值时覆盖，避免原地更新清空已有排重信息
      if (metadataSource != null && metadataSource!.isNotEmpty) {
        existing.metadataSource = metadataSource!;
      }
      if (metadataSourceId != null && metadataSourceId!.isNotEmpty) {
        existing.metadataSourceId = metadataSourceId!;
      }
      // 副标题：仅在传入非空值时覆盖，避免原地更新清空已有副标题
      if (subtitle != null && subtitle.isNotEmpty) {
        existing.subtitle = subtitle;
      }
    } else {
      final game = LibraryGame(
        gameId: (gameId != null && gameId.isNotEmpty)
            ? gameId
            : _readOrCreateGameId(metaDataDir),
        title: gameTitle,
        directoryPath: directoryPath,
        metaDataDir: metaDataDir,
        installedAt: DateTime.now().toIso8601String(),
        coverUrl: coverUrl ?? '',
        bannerUrl: detectedBanner?.path ?? '',
        description: description ?? '',
        tags: tags ?? [],
        launchPath: launchPath ?? '',
        developer: developer ?? '',
        companyId: resolvedCompanyId,
        playStatus: _parsePlayStatus(playStatus ?? 'not_started'),
        metadataSource: metadataSource ?? '',
        metadataSourceId: metadataSourceId ?? '',
        subtitle: subtitle ?? '',
      );
      _games[safeName] = game;
      _installedDirNames.add(safeName);
      debugPrint(
          '[LOCAL-REGISTRY] 📝 注册新安装游戏到本地库: $gameTitle → $directoryPath');
    }
    _notifyStructural();
  }

  /// 读取 game.json 中的稳定主键；文件不存在 / 字段缺失时**补发**一个新的。
  ///
  /// 同步读的理由：[registerExtractionComplete] 是同步 API，且调用时
  /// game.json 通常刚由 [GameDataFormat.writeGameDir] 写好（几百字节），
  /// 代价可忽略。补发出来的 id 会在下一次 [GameDataFormat.readGameJson]
  /// 的 v1→v2 迁移里正式落盘。
  String _readOrCreateGameId(String metaDataDir) {
    try {
      final file = File('$metaDataDir/${GameDataFormat.gameJsonFileName}');
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          final id = (decoded['game_id'] as String?)?.trim() ?? '';
          if (id.isNotEmpty) return id;
        }
      }
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 读取 game_id 失败（补发新 id）: $e');
    }
    return GameKey.generateId();
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
      // ★ P0-1：directoryPath 变了 → 目录维度索引与排序缓存必须作废。
      //   本方法刻意不发 structural 通知（避免对话框开着时库页 rebuild），
      //   所以失效要在这里显式做，不能依赖 _notifyStructural。
      _invalidateIndexes();

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
    // ★ P0-1：同上——relink 也不发 structural 通知，索引失效必须显式做
    _invalidateIndexes();

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

  /// 迁移收尾聚合：文件搬运完成后切换全部路径引用（逐项 best-effort）。
  ///
  /// 由 `GameMoveService` 在 M4 阶段调用。核心步骤失败即返回；其余单项
  /// 失败不抛出，以 warning 描述返回，交由 UI 如实展示（「更换游戏目录」
  /// relink 是修复兜底）。包含：
  /// ① game.json 路径更新（复用 [updateGameLocation]，含 launchPath 重算
  ///    与活跃会话刷新）
  /// ② 启动配置收尾（P0-2：唯一事实源 = game.json.launch_path，
  ///    逻辑自详情弹窗 `_resyncLauncherConfig` 下沉）
  /// ③ 桌面快捷方式重建（存在旧快捷方式时才重建）
  /// ④ Magpie 路径引用（DPI 注册表值改名 + 类名缓存键迁移）
  /// ⑤ 存档备份清单 `originalPaths` 前缀改写（存档位于本体目录内的场景）
  Future<List<String>> finalizeGameMove({
    required String gameTitle,
    required String newDirectoryPath,
    required String oldDirectoryPath,
  }) async {
    final warnings = <String>[];

    // ① 核心引用：game.json
    try {
      await updateGameLocation(
          gameTitle: gameTitle, newDirectoryPath: newDirectoryPath);
    } catch (e) {
      warnings.add('game.json 路径更新失败: $e（可使用「更换游戏目录」修复）');
      return warnings;
    }

    final game = getGameByTitle(gameTitle);
    if (game == null) return warnings;

    // 计算新旧 exe 绝对路径（供 Magpie 引用修正；launchPath 为空则跳过）
    String oldExeAbsolute = '';
    String newExeAbsolute = '';
    if (game.launchPath.isNotEmpty) {
      oldExeAbsolute = p.isAbsolute(game.launchPath)
          ? game.launchPath
          : p.join(oldDirectoryPath, game.launchPath);
      newExeAbsolute = p.isAbsolute(game.launchPath)
          ? game.launchPath
          : p.join(newDirectoryPath, game.launchPath);
    }

    // ② 启动配置收尾（P0-2）
    //
    // ① 的 updateGameLocation 已把重算后的 launch_path 写进 game.json，
    // 本步骤只剩一件事：**清掉历史存储**。留着它们，一旦 launch_path
    // 被用户清空/失效，旧值就会作为兜底把过期 exe 复活。
    // 不再向 GameConfigManager / prefs 写任何东西。
    try {
      final prefs = await SharedPreferences.getInstance();
      await GameConfigManager.instance.removeConfig(gameTitle);
      await prefs.remove('default_exe_$gameTitle');
    } catch (e) {
      warnings.add('历史启动配置清理失败: $e');
    }

    // ③ 桌面快捷方式重建（仅当旧快捷方式存在）
    try {
      final shortcutPath = ShortcutService.instance.getShortcutPath(gameTitle);
      if (File(shortcutPath).existsSync()) {
        final jsonData = await GameDataFormat.readGameJson(game.metaDataDir);
        final exePath = GameDataFormat.resolveLaunchPath(
            game.launchPath, game.directoryPath);
        if (exePath.isNotEmpty && File(exePath).existsSync()) {
          await ShortcutService.instance.createShortcut(
            gameTitle: gameTitle,
            exePath: exePath,
            gameDirectory: game.directoryPath,
            customIconPath: jsonData?.customIconPath,
            localeMode: jsonData?.localeMode ?? 'none',
            upscalingMode: jsonData?.upscalingMode ?? 'none',
          );
        } else {
          warnings.add('快捷方式未重建（新目录未找到启动程序），旧快捷方式可能失效');
        }
      }
    } catch (e) {
      warnings.add('快捷方式重建失败: $e');
    }

    // ④ Magpie：DPI 注册表值改名 + 类名缓存键迁移
    if (oldExeAbsolute.isNotEmpty && newExeAbsolute.isNotEmpty) {
      try {
        await MagpieService.instance.updateGamePaths(
          oldExePath: oldExeAbsolute,
          newExePath: newExeAbsolute,
        );
      } catch (e) {
        warnings.add('Magpie 超分配置更新失败: $e');
      }
    }

    // ⑤ 存档备份清单前缀改写
    try {
      await SaveBackupService.instance.rewriteOriginalPathsPrefix(
        gameName: gameTitle,
        oldBodyDir: oldDirectoryPath,
        newBodyDir: newDirectoryPath,
      );
    } catch (e) {
      warnings.add('存档备份清单更新失败: $e');
    }

    return warnings;
  }

  /// 更新游戏标题（编辑模式下修改标题后调用）
  /// 同步更新：_games Map key、_installedTitles、元数据文件夹名、metaDataDir、活跃会话
  ///
  /// 返回 true 表示标题已成功持久化到 game.json；
  /// false 表示未找到游戏或 game.json 写入失败（调用方需向用户如实反馈）。
  ///
  /// ★ 用户主动改标题视为接管标题：写入时使用 forceTitle 绕过 title_locked
  ///   锁定保护（该保护本意是防元数据抓取覆盖标题，不应拦截用户手动修改），
  ///   并同时解除 title_locked 标记。
  Future<bool> updateGameTitle(String oldTitle, String newTitle) async {
    final game = getGameByTitle(oldTitle);
    if (game == null) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新标题失败: 未找到游戏 $oldTitle');
      return false;
    }

    final newSafeName = GameKey.dirNameFromTitle(newTitle);

    // 获取当前 _games 的 key（即 dirName）
    String? currentKey;
    for (final entry in _games.entries) {
      if (entry.value.metaDataDir == game.metaDataDir) {
        currentKey = entry.key;
        break;
      }
    }

    if (currentKey == null) return false;

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
        // ★ IMP-05 护栏（2026-09-12 导入审查）：元数据目录若**落在游戏本体目录之内
        // 或与之相同**，说明它就是用户自己的文件夹（本地导入同名重叠）；此时重命名
        // 等于把用户 300GB 级的游戏文件夹改名搬走。放弃重命名，仅更新标题。
        // 注意不能反向判断：云端安装时本体恰好在元数据目录**之下**（设计如此），
        // 那种情况必须继续允许重命名。
        if (_metaFallsInsideBodyDir(oldMetaDataDir, game.directoryPath)) {
          debugPrint(
              '[LOCAL-REGISTRY] ⛔ 元数据目录与用户游戏目录重叠，跳过目录重命名(防移动用户文件夹): $oldMetaDataDir');
        } else if (await oldDir.exists()) {
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
        _installedDirNames.remove(currentKey);
        _installedDirNames.add(newSafeName);
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

    // 更新 game.json 中的标题（forceTitle：用户主动改名必须绕过 title_locked 保护，
    // 同时解除锁定标记——用户已接管标题）
    final titlePersisted = await GameDataFormat.updateGameJson(
      game.metaDataDir,
      {'title': newTitle, 'title_locked': false},
      forceTitle: true,
    );
    if (!titlePersisted) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 标题写入 game.json 失败: $oldTitle → $newTitle');
      return false;
    }

    // ★ H8: 同步更新桌面快捷方式的 --launch-game 参数
    try {
      await ShortcutService.instance.updateShortcutTitle(oldTitle, newTitle);
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新桌面快捷方式失败: $e');
    }

    _notifyStructural();
    debugPrint('[LOCAL-REGISTRY] ✅ 已更新游戏标题: $oldTitle → $newTitle');
    return true;
  }

  /// ★ IMP-01 数据安全护栏（2026-09-12 导入审查）
  ///
  /// 最近一次删除操作中，因**位于应用自有目录之外**而被跳过删除的"游戏本体"路径。
  ///
  /// 背景：`game.directoryPath` 对三条本地导入链路而言就是**用户自己的游戏文件夹**
  /// （智能导入 candidate.dirPath / 批量导入 game.folderPath / 单文件导入用户所选路径），
  /// 对它做 `delete(recursive: true)` 等于删除用户数据。
  /// 调用方据此如实告知用户"记录已移除，但本地文件需自行处理"。
  final List<String> _skippedBodyPaths = [];

  /// 最近一次删除被跳过删除的本体路径（只读副本）
  List<String> get skippedBodyPaths => List.unmodifiable(_skippedBodyPaths);

  /// 该游戏的"本体目录"是否位于应用自有目录内（可安全删除）。
  /// 供删除确认 UI 复用，避免 UI 层重复实现归属判定。
  bool canDeleteGameBody(String title) {
    final path = getGameByTitle(title)?.directoryPath ?? '';
    if (path.isEmpty) return true; // 无本体路径 → 不受护栏限制
    return PathHelper.isInsideAppStorage(path);
  }

  /// 该游戏的本体目录路径（供 UI 明示即将影响的位置）
  String gameBodyPath(String title) =>
      getGameByTitle(title)?.directoryPath ?? '';

  /// 元数据目录是否**落在本体目录之内或与之相同**（★ IMP-05 判定）。
  ///
  /// 语义：返回 true 表示"这个元数据目录其实就是用户自己的文件夹"
  /// （本地导入时元数据目录由清洗后标题拼成，可能与源目录同名）。
  /// 这种情况下对它的重命名/文件删除都会落到用户文件上，必须跳过。
  ///
  /// ⚠️ 刻意**不做反向判断**：云端安装时游戏本体恰好位于元数据目录**之下**
  /// （`Games/<标题>_N/<标题>`），这是设计如此，必须继续允许重命名与清理。
  static bool _metaFallsInsideBodyDir(String metaDataDir, String bodyDirPath) {
    if (metaDataDir.isEmpty || bodyDirPath.isEmpty) return false;
    final meta = PathNormalizer.forCompare(metaDataDir);
    final body = PathNormalizer.forCompare(bodyDirPath);
    if (meta.isEmpty || body.isEmpty) return false;
    return meta == body || PathNormalizer.isSubdirectory(body, meta);
  }

  Future<bool> deleteGame(String title) async {
    final game = getGameByTitle(title);
    if (game == null) {
      debugPrint('[删除] ⚠️ 删除失败: 未找到游戏 | $title');
      return false;
    }

    final dirName = game.directoryPath.split('/').last.split('\\').last;
    final beforeLen = _games.length;
    final beforeTitlesLen = _installedDirNames.length;

    debugPrint(
        '[删除] 开始彻底删除游戏: ${game.title} | 本体目录: $dirName | 元数据: ${game.metaDataDir}');
    _skippedBodyPaths.clear();

    try {
      // ★ H6: 清理活跃会话（★ v3 阶段 4: 含定时器）
      _cleanupSession(game.metaDataDir);

      // ★ H7: 删除桌面快捷方式
      try {
        await ShortcutService.instance.deleteShortcut(game.title);
      } catch (e) {
        debugPrint('[删除]   ⚠️ 删除快捷方式失败(可忽略): $e');
      }

      // ★ IMP-01 数据安全护栏（2026-09-12 导入审查）：
      // game.directoryPath 对三条本地导入链路而言就是**用户自己的游戏文件夹**，
      // 越界递归删除会造成不可恢复的用户数据丢失（本应用尚无回收站机制）。
      // 因此只允许删除应用自有目录内的本体，其余一律跳过并交由用户手动处理。
      final bodyDir = Directory(game.directoryPath);
      if (!PathHelper.isInsideAppStorage(game.directoryPath)) {
        _skippedBodyPaths.add(game.directoryPath);
        debugPrint(
            '[删除]   ⛔ 跳过删除游戏本体(位于应用自有目录之外，防止误删用户文件): ${game.directoryPath}');
      } else if (await bodyDir.exists()) {
        // ★ IMP-07: 经 CleanupUtils 删除 → 自动写入 data/cleanup_log.jsonl
        // （reason=delete_game_body），本次事故暴露出"最危险的删除无审计"的问题。
        final bodyDeleted = await CleanupUtils.deleteWithRetry(
          bodyDir,
          retries: 1,
          reason: 'delete_game_body',
        );
        if (bodyDeleted) {
          debugPrint('[删除]   ✅ 已删除游戏本体: ${game.directoryPath}');
        } else {
          debugPrint('[删除]   ⚠️ 删除本体失败(可能被占用或已手动删除): ${game.directoryPath}');
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
      final afterTitlesLen = _installedDirNames.length;

      // 通知截图抓取服务清理已删除游戏的进度记录
      onGameRemoved?.call(game.title);
      // ★ P1-4：清掉该游戏目录下的 NSFW 判定缓存。不做的话会留下永久孤儿：
      //   键是归一化后的文件路径，游戏删了以后再也没有代码会去碰它们，
      //   只能等容量/过期淘汰兜底。
      NsfwDetectionStore.instance.removeUnderDirectory(game.directoryPath);

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
    // ★ IMP-01: 本方法不触碰本体目录，清空跳过记录避免调用方读到上次的陈旧值
    _skippedBodyPaths.clear();
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

      // ★ IMP-05 护栏（2026-09-12 导入审查）：元数据目录若落在用户游戏目录之内
      // （本地导入同名重叠），其中的 .ctgame/game.json/cover.* 属于用户文件，
      // 不得在"仅移除记录"时删除。
      if (_metaFallsInsideBodyDir(dirPath, game.directoryPath)) {
        debugPrint(
            '[删除]   ⛔ 元数据目录位于用户游戏目录内，跳过删除其中的元数据文件(防破坏用户文件): $dirPath');
      } else {
        try {
          final ctgameFile =
              File('$dirPath/${GameDataFormat.ctgameFileName}');
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
            debugPrint(
                '[删除]   ✅ 已删除封面: ${coverFile.path.split('\\').last}');
          }
        } catch (fileErr) {
          debugPrint('[删除]   ⚠️ 清理本地数据文件时部分失败（可忽略）: $fileErr');
        }
      }

      final afterLen = _games.length;

      // 通知截图抓取服务清理已删除游戏的进度记录
      onGameRemoved?.call(game.title);
      // ★ P1-4：同 deleteGame —— 清掉该游戏目录下的 NSFW 判定缓存
      NsfwDetectionStore.instance.removeUnderDirectory(game.directoryPath);

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
          // 🔴 关键字只对文件名匹配，禁止用完整路径（2026-09-13 实锤：
          // 目录名含 "Install Patch" 时全路径匹配会滤光所有 exe）
          final name =
              entity.path.replaceAll('\\', '/').split('/').last.toLowerCase();
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
      // 汉化检测只看文件名——目录名含日文汉字（galgame 标题常态）时
      // 全路径匹配会把任意先遍历到的 exe（可能是 setup/uninst）当"汉化版"
      String exeBaseName(File f) =>
          f.path.replaceAll('\\', '/').split('/').last;
      final chineseFiles =
          exeFiles.where((f) => chinesePattern.hasMatch(exeBaseName(f))).toList();
      if (chineseFiles.isNotEmpty) {
        debugPrint(
            '[LOCAL-REGISTRY] 🔍 检测到汉化可执行文件: ${chineseFiles.first.path}');
        return chineseFiles.first.path;
      }

      final mainFiles = exeFiles.where((f) {
        final lower = exeBaseName(f).toLowerCase();
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
          // 🔴 关键字只对文件名匹配，禁止用完整路径（2026-09-13 实锤：
          // 目录名含 "Install Patch" 时全路径匹配会滤光所有 exe）
          final name =
              entity.path.replaceAll('\\', '/').split('/').last.toLowerCase();
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

  // ★ P2-6：单次补计的容忍窗口（修复 clamp(0,4) 在 tick 被挤压时系统性少计）
  // - 宽松模式（存活即计时）：真实间隔即存活时长，容忍到 10 分钟
  // - 精准模式（仅前台计时）：覆盖 tick 拖延场景，同时限制"切后台很久后回前台"
  //   时 delta 包含整个后台时长导致的虚高
  static const int _foregroundCatchUpMaxSec = 30;
  static const int _elapsedCatchUpMaxSec = 600;

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

  /// ★ 运行任务横幅：会话首次确认进程存活回调（游戏标题, 元数据目录）
  ///
  /// 与 [onGameSessionEnded] 对称：后者在会话结束时触发，本回调在会话
  /// **首次被确认进程仍在运行**时触发（每个会话仅一次），供横幅把状态
  /// 从「正在启动」切换为「运行中」并启动墙钟计时。
  ///
  /// 之所以复用既有的进程检测而不是让 UI 自己轮询：检测逻辑已处理
  /// 启动器型游戏、逃逸进程、Win32 FFI 回退等边界（见 [_isGameStillRunning]），
  /// 再造一套轮询会与统计口径产生分歧。
  /// [pid] 为会话的主追踪 PID（`_GameSession.bestPid`），可能为 null
  /// （启动器型游戏未捕获到 PID）。消费方：运行任务横幅 + 手柄适配协调器
  /// （`gamepad_adaptation_coordinator.dart`，按 PID 绑定注入守卫）。
  void Function(String gameTitle, String metaDataDir, int? pid)?
      onGameSessionConfirmed;

  /// ★ 运行任务横幅：当前活跃会话的元数据目录集合（只读快照）
  ///
  /// 供横幅在冷启动（如应用崩溃恢复、用户手动启动游戏后再开软件）时
  /// 纳管已存在但非本次发起的会话。
  Set<String> get activeSessionDirs =>
      debugActiveSessionDirsOverride ?? _activeGameSessions.keys.toSet();

  /// 仅供测试：覆盖 [activeSessionDirs] 的返回值
  ///
  /// 让运行任务横幅的状态流转可以在不真正启动游戏进程的前提下被测试。
  @visibleForTesting
  Set<String>? debugActiveSessionDirsOverride;

  /// 仅供测试：记录 [stopTracking] 被调用过的 metaDataDir
  @visibleForTesting
  final List<String> debugStopTrackingCalls = <String>[];

  /// 仅供测试：记录 [terminateGame] 被调用过的 metaDataDir
  @visibleForTesting
  final List<String> debugTerminateCalls = <String>[];

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
            // ★ 响应式修复：状态徽标跨页面即时刷新（playTimeUpdate 轻量语义）
            _notifyPlayTimeUpdate();
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
      // ★ P0-1：directoryPath 自愈后同样要作废目录维度索引
      _invalidateIndexes();
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
        // ★ 响应式修复：状态徽标跨页面即时刷新（playTimeUpdate 轻量语义）
        _notifyPlayTimeUpdate();
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
      // ★ 响应式修复：状态徽标跨页面即时刷新（playTimeUpdate 语义轻量：
      // 库页/主页仅 setState，不触发封面缓存清理与重排序）
      _notifyPlayTimeUpdate();
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

        // ★ 运行任务横幅：首次确认进程存活 → 通知 UI 从「正在启动」切到「运行中」
        // 每个会话只会翻转一次（confirmed 单向 false→true），后续 tick 不再回调。
        // 用 try-catch 包裹：横幅的 UI 回调抛异常绝不能影响时长累加主流程。
        if (!session.confirmed) {
          session.confirmed = true;
          try {
            onGameSessionConfirmed?.call(
                session.gameTitle, metaDataDir, session.bestPid);
          } catch (e) {
            debugPrint('[PLAYTIME] ⚠️ 会话确认回调异常（不阻塞计时）: $e');
          }
        }

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
        // ★ P2-6：原 clamp(0, monitorInterval*2)=clamp(0,4) 在定时器被挤压
        // （FFI 回退 PowerShell、存档扫描、杀软扫描等造成 tick 拖延）时，
        // 真实间隔远超 4s 但每次只补 4s → 时长系统性少计。
        // 改为按模式区分容忍窗口：
        // - 宽松模式：单次最多补 10 分钟（真实间隔=进程存活时长，如实在计）；
        // - 精准模式：单次最多补 30s（覆盖 tick 拖延；同时限制"切后台很久后
        //   回前台"场景的虚高——delta 会包含整个后台时长，不能全额补计）。
        // 超过容忍窗口的部分不补（视为系统挂起/休眠，无法区分是否前台）。
        int secondsToAdd = 0;
        if (session.trackingMode == TimeTrackingMode.playtime) {
          // 精准模式：仅前台时累加
          // ★ 重构: 从 _foregroundStates 读取前台状态（由 500ms 定时器更新）
          final isForeground =
              _foregroundStates[session.metaDataDir]?.isForeground ?? false;
          if (isForeground) {
            final delta = now.difference(session.lastSettledTime).inSeconds;
            secondsToAdd = delta.clamp(0, _foregroundCatchUpMaxSec).toInt();
          }
          // 后台不累加
        } else {
          // 宽松模式：存活即累加
          final delta = now.difference(session.lastSettledTime).inSeconds;
          secondsToAdd = delta.clamp(0, _elapsedCatchUpMaxSec).toInt();
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

  // ═══════════════════════════════════════════════════════════════
  // ★ 运行任务横幅：会话管控公开 API
  //
  // 供「游戏运行任务状态横幅」的两个操作按钮使用：
  //   • [stopTracking] 解除监控 —— 放弃时长统计，游戏继续独立运行
  //   • [terminateGame] 关闭游戏 —— 终止游戏进程
  // 两者都会把会话以 exit_reason='manual' 写入 sessions 事实表，
  // 保证统计数据的完整性与可审计性。
  // ═══════════════════════════════════════════════════════════════

  /// 结束指定会话的时长追踪（不终止游戏进程）
  ///
  /// 用于横幅的「解除监控」按钮：软件放弃对游戏进程的监控与时长统计，
  /// 游戏继续独立运行。已产生的时长正常落盘并写入 sessions 事实表。
  ///
  /// [exitDetail] 写入日志的退出原因描述，便于区分「解除监控」与「关闭游戏」。
  ///
  /// 返回 true 表示确实结束了一个会话；false 表示该会话不存在。
  Future<bool> stopTracking(String metaDataDir,
      {String exitDetail = 'manual(用户解除监控)'}) async {
    debugStopTrackingCalls.add(metaDataDir);
    final session = _activeGameSessions[metaDataDir];
    if (session == null) return false;

    // 结算最后一次检测以来未落盘的时长（上限 2 倍监控间隔，与 _cleanupAll 一致）
    final now = DateTime.now();
    final pendingDelta = now.difference(session.lastSettledTime).inSeconds;
    if (pendingDelta > 0 && pendingDelta <= _monitorIntervalSec * 2) {
      final written = await _writePlayTimeDirect(metaDataDir, pendingDelta);
      if (written) session.accumulatedSeconds += pendingDelta;
    }

    session.exitReason = 'manual';
    await GameLaunchLogger.instance.logGameExit(
      gameTitle: session.gameTitle,
      durationSeconds: session.accumulatedSeconds,
      exitReason: exitDetail,
    );
    try {
      await GameDataFormat.appendSession(
          metaDataDir, session.toSessionRecord());
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 解除监控时写入会话记录失败（不影响主流程）: $e');
    }

    _cleanupSession(metaDataDir);
    debugPrint(
        '[PLAYTIME] 🔓 已结束追踪: ${session.gameTitle} | $exitDetail | 本次 ${GameDataFormat.formatPlayTime(session.accumulatedSeconds)}');
    return true;
  }

  /// 终止指定会话对应的游戏进程，并结束时长追踪
  ///
  /// 用于横幅的「关闭游戏」按钮。终止范围（尽力而为，单项失败不阻塞）：
  /// 1. [bestPid] —— 启动时捕获的主进程；
  /// 2. `candidatePids` —— 运行期间确认过的候选进程（逃逸进程等）；
  /// 3. 游戏目录内的所有进程 —— 覆盖启动器型游戏 fork 出的子进程。
  ///
  /// 先尝试优雅关闭（发关闭消息），800ms 后再对仍存活的进程强制终止，
  /// 给游戏留出存档写入窗口。
  ///
  /// 返回 true 表示会话已被移除（即使部分进程 kill 失败）。
  Future<bool> terminateGame(String metaDataDir) async {
    debugTerminateCalls.add(metaDataDir);
    final session = _activeGameSessions[metaDataDir];
    if (session == null) return false;

    final pids = <int>{...session.candidatePids};
    if (session.bestPid != null) pids.add(session.bestPid!);
    try {
      pids.addAll(await _scanGameDirPids(session.directoryPath.isNotEmpty
          ? session.directoryPath
          : session.metaDataDir));
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ 关闭游戏时扫描目录进程失败（用已知 PID 继续）: $e');
    }

    // 第一轮：优雅关闭
    var anyGraceful = false;
    for (final pid in pids) {
      if (await _killPid(pid, force: false)) anyGraceful = true;
    }
    // 给游戏 800ms 保存存档，再对残留进程强制终止
    if (anyGraceful) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    for (final pid in pids) {
      await _killPid(pid, force: true);
    }

    await stopTracking(metaDataDir, exitDetail: 'manual(用户关闭游戏)');
    debugPrint('[PLAYTIME] ⛔ 已关闭游戏: ${session.gameTitle}');
    return true;
  }

  /// 终止单个 PID（含子进程树 /T）
  /// [force] 为 true 时加 /F 强制终止
  Future<bool> _killPid(int pid, {required bool force}) async {
    try {
      final result = await Process.run(
        'taskkill',
        ['/PID', '$pid', '/T', if (force) '/F'],
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('[PLAYTIME] ⚠️ taskkill 超时(5s): PID=$pid');
        return ProcessResult(0, -1, '', '');
      });
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[PLAYTIME] ⚠️ taskkill 异常 PID=$pid: $e');
      return false;
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
      final customPaths =
          prefs.getStringList('save_custom_paths_$gameTitle') ?? [];
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
