// ===========================================================================
// 阅历历史数据服务
//
// 设计目的：
//   为主页"阅历"板块提供独立的"历史数据"数据集，作为现有 sessions/
//   daily_play_log 的适配层，专门用于按日/按月查询用户历史活跃信息。
//
// 适配原则（不大改现有数据）：
//   - 不创建新的数据文件
//   - 不修改 game.json 结构
//   - 仅读取现有 sessions + sessions_archive.json + daily_play_log
//   - 通过内存缓存降低 I/O 开销
//
// 核心 API：
//   - getMonthSummary(year, month) → 该月每日活跃摘要（日历着色用）
//   - getDayDetail(date) → 该日游戏列表 + 各自时长（日详情用）
//   - invalidateCache() → registry 变化时清理缓存
// ===========================================================================

import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'local_game_registry.dart';
import 'game_data_format.dart';
import 'stats_aggregator.dart';

/// 单个游戏在某日的活跃记录
class GameActivity {
  /// 游戏标题（用于显示）
  final String gameTitle;

  /// 游戏元数据目录（用于唯一标识）
  final String metaDataDir;

  /// 该日游玩时长（秒）
  final int seconds;

  /// 该日游玩次数
  final int sessionCount;

  const GameActivity({
    required this.gameTitle,
    required this.metaDataDir,
    required this.seconds,
    required this.sessionCount,
  });

  @override
  String toString() =>
      'GameActivity($gameTitle: ${seconds}s, $sessionCount次)';
}

/// 单日活跃详情
class DayActivity {
  final DateTime date;

  /// 当日总时长（秒）
  final int totalSeconds;

  /// 当日总会话次数
  final int totalSessionCount;

  /// 当日玩过的游戏列表（按时长降序）
  final List<GameActivity> games;

  const DayActivity({
    required this.date,
    required this.totalSeconds,
    required this.totalSessionCount,
    required this.games,
  });

  /// 是否无活跃
  bool get isEmpty => games.isEmpty || totalSeconds == 0;
}

/// 月度活跃摘要（用于日历着色）
class MonthSummary {
  final int year;
  final int month;

  /// key = 日期（1~31），value = 当日总时长（秒）
  final Map<int, int> daySeconds;

  /// key = 日期，value = 当日总会话次数
  final Map<int, int> daySessionCounts;

  /// key = 日期，value = 当日游戏数
  final Map<int, int> dayGameCounts;

  const MonthSummary({
    required this.year,
    required this.month,
    required this.daySeconds,
    required this.daySessionCounts,
    required this.dayGameCounts,
  });

  /// 该月是否有任何活跃
  bool get hasAnyActivity => daySeconds.values.any((s) => s > 0);

  /// 当月总时长（秒）
  int get monthTotalSeconds =>
      daySeconds.values.fold<int>(0, (a, b) => a + b);

  /// 当月活跃天数
  int get activeDayCount => daySeconds.values.where((s) => s > 0).length;
}

/// 阅历历史数据服务（单例）
///
/// 通过 [instance] 访问。所有方法均为异步，结果会被缓存。
class ExperienceHistoryService {
  ExperienceHistoryService._();
  static final ExperienceHistoryService instance = ExperienceHistoryService._();

  // ==================== 缓存 ====================

  /// 月份摘要缓存：key = "yyyy-mm"
  final Map<String, MonthSummary> _monthCache = {};

  /// 单日详情缓存：key = "yyyy-mm-dd"
  final Map<String, DayActivity> _dayCache = {};

  /// 全量重聚合后的 daily entries（按游戏分组）：key = metaDataDir
  Map<String, List<DailyEntry>>? _allDailyByGame;

  /// 是否正在加载全量数据
  bool _loadingAll = false;

  // ==================== 公共 API ====================

  /// 获取某月的活跃摘要
  ///
  /// 返回该月每日的总时长 / 次数 / 游戏数，用于日历着色。
  /// 优先命中缓存；未命中时触发全量重聚合（首次稍慢，后续走缓存）。
  Future<MonthSummary> getMonthSummary(int year, int month) async {
    final key = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
    final cached = _monthCache[key];
    if (cached != null) return cached;

    final dailyByGame = await _ensureAllDailyLoaded();
    final daySeconds = <int, int>{};
    final daySessionCounts = <int, int>{};
    final dayGameCounts = <int, int>{};

    for (final entry in dailyByGame.entries) {
      final entries = entry.value;
      for (final e in entries) {
        if (e.date.year == year && e.date.month == month && e.seconds > 0) {
          final day = e.date.day;
          daySeconds[day] = (daySeconds[day] ?? 0) + e.seconds;
          daySessionCounts[day] = (daySessionCounts[day] ?? 0) + e.count;
          dayGameCounts[day] = (dayGameCounts[day] ?? 0) + 1;
        }
      }
    }

    final summary = MonthSummary(
      year: year,
      month: month,
      daySeconds: daySeconds,
      daySessionCounts: daySessionCounts,
      dayGameCounts: dayGameCounts,
    );
    _monthCache[key] = summary;
    return summary;
  }

  /// 获取某日的活跃详情
  ///
  /// 返回当日玩过的所有游戏列表 + 各自时长，按时长降序排列。
  Future<DayActivity> getDayDetail(DateTime date) async {
    final normalized = DateTime(date.year, date.month, date.day);
    final key = _dateKey(normalized);
    final cached = _dayCache[key];
    if (cached != null) return cached;

    final dailyByGame = await _ensureAllDailyLoaded();
    final games = <GameActivity>[];

    for (final game in LocalGameRegistry.instance.allGames) {
      final entries = dailyByGame[game.metaDataDir];
      if (entries == null) continue;
      for (final e in entries) {
        if (e.date.year == normalized.year &&
            e.date.month == normalized.month &&
            e.date.day == normalized.day &&
            e.seconds > 0) {
          games.add(GameActivity(
            gameTitle: game.title,
            metaDataDir: game.metaDataDir,
            seconds: e.seconds,
            sessionCount: e.count,
          ));
        }
      }
    }

    games.sort((a, b) => b.seconds.compareTo(a.seconds));
    final totalSeconds = games.fold<int>(0, (a, g) => a + g.seconds);
    final totalSessionCount =
        games.fold<int>(0, (a, g) => a + g.sessionCount);

    final activity = DayActivity(
      date: normalized,
      totalSeconds: totalSeconds,
      totalSessionCount: totalSessionCount,
      games: games,
    );
    _dayCache[key] = activity;
    return activity;
  }

  /// 清空所有缓存（registry 变化时调用）
  void invalidateCache() {
    _monthCache.clear();
    _dayCache.clear();
    _allDailyByGame = null;
  }

  /// 清空指定游戏的缓存（精细失效，未使用，预留）
  void invalidateForGame(String metaDataDir) {
    // 保守做法：清空所有缓存
    invalidateCache();
  }

  // ==================== 内部实现 ====================

  /// 确保全量 daily entries 已加载（按游戏分组）
  ///
  /// 数据源策略：
  ///   - 90 天内：直接读 daily_play_log（快速，已聚合）
  ///   - 全部：补充读 sessions + sessions_archive 重聚合（覆盖 > 90 天）
  ///
  /// 由于阅历需要查看任意历史日期，必须走 sessions 重聚合路径。
  /// 但 daily_play_log 已经是 90 天内的投影，可以直接复用，减少 sessions 解析。
  Future<Map<String, List<DailyEntry>>> _ensureAllDailyLoaded() async {
    if (_allDailyByGame != null) return _allDailyByGame!;
    if (_loadingAll) {
      // 等待正在进行的加载
      while (_loadingAll) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _allDailyByGame ?? {};
    }

    _loadingAll = true;
    try {
      final result = <String, List<DailyEntry>>{};
      final games = LocalGameRegistry.instance.allGames;

      for (final game in games) {
        try {
          // 优先读 daily_play_log（90 天内已聚合，快）
          final dailyLogEntries = await _readDailyPlayLog(game);

          // 检查是否需要补全 > 90 天的数据
          // 简化策略：直接走 sessions 重聚合（一次到位，避免双源拼接）
          final sessionEntries = await _readSessionsToDaily(game);

          // 合并：以 sessions 重聚合为准（覆盖更全）
          // 若 sessions 为空但 daily_play_log 有数据，退化为 daily_play_log
          if (sessionEntries.isNotEmpty) {
            result[game.metaDataDir] = sessionEntries;
          } else if (dailyLogEntries.isNotEmpty) {
            result[game.metaDataDir] = dailyLogEntries;
          }
        } catch (e) {
          debugPrint('[HISTORY] 读取 ${game.title} 历史数据失败: $e');
        }
      }

      _allDailyByGame = result;
      return result;
    } finally {
      _loadingAll = false;
    }
  }

  /// 读取单个游戏的 daily_play_log
  Future<List<DailyEntry>> _readDailyPlayLog(LibraryGame game) async {
    try {
      final jsonFile = File('${game.metaDataDir}/game.json');
      if (!jsonFile.existsSync()) return const [];
      final raw =
          jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
      final log = raw['daily_play_log'];
      if (log is! Map) return const [];
      return StatsAggregator.parseDailyPlayLog(
          Map<String, dynamic>.from(log));
    } catch (e) {
      debugPrint('[HISTORY] 读取 ${game.title} daily_play_log 失败: $e');
      return const [];
    }
  }

  /// 从 sessions + sessions_archive 重聚合为 daily entries
  Future<List<DailyEntry>> _readSessionsToDaily(LibraryGame game) async {
    try {
      final active = await GameDataFormat.readSessions(game.metaDataDir);
      final archived =
          await GameDataFormat.readArchivedSessions(game.metaDataDir);
      final all = [...archived, ...active];
      if (all.isEmpty) return const [];
      final sessions = all.map(SessionRecord.fromJson).toList();
      return StatsAggregator.aggregateSessionsToDaily(sessions);
    } catch (e) {
      debugPrint('[HISTORY] 读取 ${game.title} sessions 失败: $e');
      return const [];
    }
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
