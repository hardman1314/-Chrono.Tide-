// ===========================================================================
// 游玩统计聚合服务（阅历系统核心）
//
// 设计目的：
//   将"原始会话事实表 → 折线图数据点"的聚合逻辑从 UI 中抽离，
//   形成 100% 纯 Dart 可测试单元，避免 UI 测试的复杂度。
//
// 数据源：
//   - 短时段（≤90 天）：直接从 game.json 的 daily_play_log 读取
//   - 长时段（>90 天）：从 sessions + sessions_archive.json 重新聚合
//   两种数据源都汇入统一的 [AggregatedPoint] 序列。
//
// 设计原则：
//   - 不依赖 Flutter（仅 dart:core），保证可测试性
//   - 不依赖文件系统（数据由调用方传入），保证纯函数特性
//   - 跨日会话按比例分配（与 game_data_format.dart _distributeSessionByDays 一致）
// ===========================================================================

/// 时间段枚举（用户可切换的预设窗口）
enum StatsPeriod {
  /// 近 7 日（默认，走实时流）
  last7,

  /// 近 30 日
  last30,

  /// 近 90 日
  last90,

  /// 全部（自首次游玩起，最长到当前时刻）
  all,

  /// 自定义（携带 from / to）
  custom,
}

/// 聚合粒度（决定 X 轴每个点代表的时间跨度）
enum StatsGranularity {
  /// 每天 1 个点（跨度 ≤ 14 天）
  day,

  /// 每周 1 个点（15~90 天）
  week,

  /// 每月 1 个点（91~730 天）
  month,

  /// 每年 1 个点（> 730 天）
  year,
}

/// 聚合后的单个数据点
class AggregatedPoint {
  /// 该 bucket 的起始日期（本地时区，已对齐到日/周首/月初/年初）
  final DateTime bucketStart;

  /// 该 bucket 内累计游玩时长（秒）
  final int seconds;

  /// 该 bucket 内累计游玩次数（按会话开始日归集）
  final int count;

  /// 该 bucket 内有数据的游戏数（用于详情展示）
  final int gameCount;

  /// 该 bucket 的可读标签（如 "8/4"、"2026-W32"、"2026-08"）
  final String label;

  const AggregatedPoint({
    required this.bucketStart,
    required this.seconds,
    required this.count,
    required this.gameCount,
    required this.label,
  });

  @override
  String toString() =>
      'AggregatedPoint($label: ${seconds}s, $count次, $gameCount款)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AggregatedPoint &&
          bucketStart == other.bucketStart &&
          seconds == other.seconds &&
          count == other.count &&
          gameCount == other.gameCount &&
          label == other.label;

  @override
  int get hashCode => Object.hash(
      bucketStart, seconds, count, gameCount, label);
}

/// 单日聚合结果（用于从 daily_play_log 直接构造）
class DailyEntry {
  final DateTime date;
  final int seconds;
  final int count;

  const DailyEntry({
    required this.date,
    required this.seconds,
    required this.count,
  });
}

/// 原始会话记录（统一结构，从 sessions / sessions_archive 反序列化而来）
class SessionRecord {
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;

  const SessionRecord({
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
  });

  /// 从 game.json sessions 数组项反序列化
  /// 兼容字段：start_time / end_time / duration_seconds
  factory SessionRecord.fromJson(Map<String, dynamic> json) {
    final start = DateTime.tryParse(json['start_time'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final end = DateTime.tryParse(json['end_time'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final duration =
        (json['duration_seconds'] as num?)?.toInt() ?? 0;
    return SessionRecord(
      startTime: start,
      endTime: end,
      durationSeconds: duration,
    );
  }
}

/// 聚合器主类
///
/// 所有方法均为静态纯函数，无状态、无副作用。
class StatsAggregator {
  StatsAggregator._();

  /// 根据时间跨度自动选择合适的粒度
  ///
  /// 与方案 §5.2.2 粒度策略一致：
  ///   - ≤14 天 → day
  ///   - 15~90 天 → week
  ///   - 91~730 天 → month
  ///   - > 730 天 → year
  static StatsGranularity granularityFor(Duration span) {
    final days = span.inDays;
    if (days <= 14) return StatsGranularity.day;
    if (days <= 90) return StatsGranularity.week;
    if (days <= 730) return StatsGranularity.month;
    return StatsGranularity.year;
  }

  /// 把 [from, to] 区间切成等距 bucket，每个 bucket 一个 [AggregatedPoint]
  ///
  /// 输入：
  ///   - [dailyEntries] 已按日聚合的输入（来自 daily_play_log 或 sessions 重聚合）
  ///   - [from] / [to] 区间端点（含两端，已对齐到本地 0 点）
  ///   - [granularity] 粒度
  ///
  /// 输出：等距 bucket 列表，无数据的 bucket 也填充 0 值（保证 X 轴等距）
  static List<AggregatedPoint> aggregate({
    required List<DailyEntry> dailyEntries,
    required DateTime from,
    required DateTime to,
    required StatsGranularity granularity,
  }) {
    // 规范化边界到本地 0 点
    final normalizedFrom = DateTime(from.year, from.month, from.day);
    final normalizedTo = DateTime(to.year, to.month, to.day);
    if (!normalizedTo.isAfter(normalizedFrom)) {
      // 单日情况：返回 1 个点
      final entry = _pickDay(dailyEntries, normalizedFrom);
      return [
        AggregatedPoint(
          bucketStart: normalizedFrom,
          seconds: entry.seconds,
          count: entry.count,
          gameCount: entry.seconds > 0 ? 1 : 0,
          label: _formatLabel(normalizedFrom, granularity),
        ),
      ];
    }

    // 生成 bucket 边界
    final buckets = _generateBuckets(normalizedFrom, normalizedTo, granularity);

    // 按 bucket 聚合
    return buckets.map((bucket) {
      final next = _nextBucketStart(bucket, granularity);
      // bucket 区间 [bucket, next)
      final inRange = dailyEntries.where((e) {
        return !e.date.isBefore(bucket) && e.date.isBefore(next);
      });
      final seconds = inRange.fold<int>(0, (a, e) => a + e.seconds);
      final count = inRange.fold<int>(0, (a, e) => a + e.count);
      // gameCount 用估算：有数据即 ≥1（精确值需调用方按游戏传入）
      final gameCount = inRange.any((e) => e.seconds > 0)
          ? inRange.where((e) => e.seconds > 0).length
          : 0;
      return AggregatedPoint(
        bucketStart: bucket,
        seconds: seconds,
        count: count,
        gameCount: gameCount,
        label: _formatLabel(bucket, granularity),
      );
    }).toList();
  }

  /// 从 sessions 列表聚合为 DailyEntry 列表（用于 > 90 天的长跨度查询）
  ///
  /// 跨日会话按比例分配，与 [game_data_format.dart] _distributeSessionByDays 算法一致。
  /// duration < 60s 的会话被过滤（与 rebuildPlayTimeFromSessions 一致）。
  static List<DailyEntry> aggregateSessionsToDaily(
      List<SessionRecord> sessions) {
    final Map<String, _DayAccumulator> acc = {};

    for (final s in sessions) {
      if (s.durationSeconds < 60) continue; // 过滤误启动

      final distribution =
          _distributeSessionByDays(s.startTime, s.endTime, s.durationSeconds);
      final startDateKey = _formatDateKey(s.startTime);

      for (final entry in distribution.entries) {
        acc.putIfAbsent(entry.key, () => _DayAccumulator(entry.key));
        acc[entry.key]!.seconds += entry.value;
      }
      // 会话次数归入开始日期
      acc.putIfAbsent(startDateKey, () => _DayAccumulator(startDateKey));
      acc[startDateKey]!.count += 1;
    }

    return acc.values.map((a) {
      final date = DateTime.tryParse(a.dateKey) ?? DateTime.now();
      return DailyEntry(date: date, seconds: a.seconds, count: a.count);
    }).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  /// 解析 daily_play_log（来自 game.json）为 DailyEntry 列表
  ///
  /// 兼容两种格式：
  ///   - 旧格式: { "2026-06-23": 3600 }
  ///   - 新格式: { "2026-06-23": { "seconds": 3600, "count": 1 } }
  static List<DailyEntry> parseDailyPlayLog(Map<String, dynamic> log) {
    final result = <DailyEntry>[];
    for (final entry in log.entries) {
      final date = DateTime.tryParse(entry.key);
      if (date == null) continue;
      final val = entry.value;
      int seconds = 0;
      int count = 0;
      if (val is Map) {
        seconds = (val['seconds'] as num?)?.toInt() ?? 0;
        count = (val['count'] as num?)?.toInt() ?? 0;
      } else if (val is num) {
        seconds = val.toInt();
      }
      result.add(DailyEntry(
        date: DateTime(date.year, date.month, date.day),
        seconds: seconds,
        count: count,
      ));
    }
    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  /// 根据 StatsPeriod 计算 [from, to] 区间
  ///
  /// [firstPlayDate] 用于 all 模式，可为 null（无历史时退化为最近 7 日）
  static ({DateTime from, DateTime to}) periodRange(
    StatsPeriod period, {
    DateTime? now,
    DateTime? customFrom,
    DateTime? customTo,
    DateTime? firstPlayDate,
  }) {
    final today = (now ?? DateTime.now());
    final todayMidnight = DateTime(today.year, today.month, today.day);

    switch (period) {
      case StatsPeriod.last7:
        return (
          from: todayMidnight.subtract(const Duration(days: 6)),
          to: todayMidnight,
        );
      case StatsPeriod.last30:
        return (
          from: todayMidnight.subtract(const Duration(days: 29)),
          to: todayMidnight,
        );
      case StatsPeriod.last90:
        return (
          from: todayMidnight.subtract(const Duration(days: 89)),
          to: todayMidnight,
        );
      case StatsPeriod.all:
        final from = firstPlayDate ?? todayMidnight;
        final normalizedFrom = DateTime(from.year, from.month, from.day);
        return (from: normalizedFrom, to: todayMidnight);
      case StatsPeriod.custom:
        final from = customFrom ?? todayMidnight;
        final to = customTo ?? todayMidnight;
        final normalizedFrom = DateTime(from.year, from.month, from.day);
        final normalizedTo = DateTime(to.year, to.month, to.day);
        // 保证 from <= to
        if (!normalizedTo.isBefore(normalizedFrom)) {
          return (from: normalizedFrom, to: normalizedTo);
        }
        return (from: normalizedTo, to: normalizedFrom);
    }
  }

  // ===========================================================================
  // 内部辅助方法
  // ===========================================================================

  static DailyEntry _pickDay(List<DailyEntry> entries, DateTime day) {
    for (final e in entries) {
      if (e.date.year == day.year &&
          e.date.month == day.month &&
          e.date.day == day.day) {
        return e;
      }
    }
    return DailyEntry(date: day, seconds: 0, count: 0);
  }

  /// 生成所有 bucket 的起始日期列表
  static List<DateTime> _generateBuckets(
      DateTime from, DateTime to, StatsGranularity g) {
    final result = <DateTime>[];
    DateTime cursor = _bucketStart(from, g);
    while (!cursor.isAfter(to)) {
      result.add(cursor);
      cursor = _nextBucketStart(cursor, g);
    }
    return result;
  }

  /// 把任意日期对齐到 bucket 起始
  static DateTime _bucketStart(DateTime date, StatsGranularity g) {
    switch (g) {
      case StatsGranularity.day:
        return DateTime(date.year, date.month, date.day);
      case StatsGranularity.week:
        // 周一为一周起始
        final weekday = date.weekday; // Monday = 1, Sunday = 7
        final monday = date.subtract(Duration(days: weekday - 1));
        return DateTime(monday.year, monday.month, monday.day);
      case StatsGranularity.month:
        return DateTime(date.year, date.month);
      case StatsGranularity.year:
        return DateTime(date.year);
    }
  }

  /// 下一个 bucket 的起始
  static DateTime _nextBucketStart(DateTime bucket, StatsGranularity g) {
    switch (g) {
      case StatsGranularity.day:
        return bucket.add(const Duration(days: 1));
      case StatsGranularity.week:
        return bucket.add(const Duration(days: 7));
      case StatsGranularity.month:
        // 月 +1（处理跨年）
        if (bucket.month == 12) {
          return DateTime(bucket.year + 1, 1);
        }
        return DateTime(bucket.year, bucket.month + 1);
      case StatsGranularity.year:
        return DateTime(bucket.year + 1);
    }
  }

  /// bucket 标签格式化
  static String _formatLabel(DateTime bucket, StatsGranularity g) {
    switch (g) {
      case StatsGranularity.day:
        return '${bucket.month.toString().padLeft(2, '0')}/${bucket.day.toString().padLeft(2, '0')}';
      case StatsGranularity.week:
        final weekNum = _weekOfYear(bucket);
        return '${bucket.year}W$weekNum';
      case StatsGranularity.month:
        return '${bucket.year}-${bucket.month.toString().padLeft(2, '0')}';
      case StatsGranularity.year:
        return '${bucket.year}';
    }
  }

  /// ISO 周数计算
  static int _weekOfYear(DateTime date) {
    // 找到当年第一个周一（ISO 周一为一周起始）
    var firstMonday = DateTime(date.year, 1, 1);
    while (firstMonday.weekday != 1) {
      firstMonday = firstMonday.add(const Duration(days: 1));
    }
    // 如果 date 在第一个周一之前，归入上一年最后一周
    if (date.isBefore(firstMonday)) return 52;
    final diff = date.difference(firstMonday).inDays;
    return (diff ~/ 7) + 1;
  }

  /// 格式化日期为 YYYY-MM-DD（与 game_data_format.dart _formatDateKey 一致）
  static String _formatDateKey(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// 跨日会话按比例分配
  /// 与 [game_data_format.dart] _distributeSessionByDays 算法保持一致
  static Map<String, int> _distributeSessionByDays(
      DateTime startTime, DateTime endTime, int totalDurationSeconds) {
    final result = <String, int>{};

    final startDate =
        DateTime(startTime.year, startTime.month, startTime.day);
    final endDate = DateTime(endTime.year, endTime.month, endTime.day);

    // 同日会话
    if (startDate == endDate) {
      result[_formatDateKey(startTime)] = totalDurationSeconds;
      return result;
    }

    // 跨日会话：按比例分配
    final totalSeconds = endTime.difference(startTime).inSeconds;
    if (totalSeconds <= 0) {
      result[_formatDateKey(startTime)] = totalDurationSeconds;
      return result;
    }

    DateTime currentDate = startDate;
    int allocatedSeconds = 0;

    while (currentDate.isBefore(endDate)) {
      final nextMidnight = currentDate.add(const Duration(days: 1));
      final dayBoundary =
          nextMidnight.isBefore(endTime) ? nextMidnight : endTime;
      final dayStart =
          currentDate.isBefore(startTime) ? startTime : currentDate;

      final elapsedSeconds = dayBoundary.difference(dayStart).inSeconds;
      if (elapsedSeconds > 0) {
        final daySeconds =
            (elapsedSeconds * totalDurationSeconds / totalSeconds).round();
        if (daySeconds > 0) {
          result[_formatDateKey(currentDate)] = daySeconds;
          allocatedSeconds += daySeconds;
        }
      }

      currentDate = nextMidnight;
    }

    final lastDayKey = _formatDateKey(endDate);
    final lastDaySeconds = totalDurationSeconds - allocatedSeconds;
    if (lastDaySeconds > 0) {
      result[lastDayKey] = (result[lastDayKey] ?? 0) + lastDaySeconds;
    }

    return result;
  }
}

/// 内部累加器
class _DayAccumulator {
  final String dateKey;
  int seconds = 0;
  int count = 0;
  _DayAccumulator(this.dateKey);
}
