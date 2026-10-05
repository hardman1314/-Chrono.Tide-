// ===========================================================================
// StatsAggregator 单元测试
//
// 覆盖目标：
//   - 粒度选择策略（4 种）
//   - 区间聚合（day/week/month/year 4 种粒度）
//   - sessions → DailyEntry 重聚合（含跨日会话比例分配）
//   - daily_play_log 解析（新旧两种格式）
//   - periodRange 5 种时段计算
//   - 边界：空数据、单日、超长跨度
// ===========================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/stats_aggregator.dart';

void main() {
  // ===========================================================================
  // 1. granularityFor 粒度选择策略
  // ===========================================================================
  group('granularityFor - 粒度选择', () {
    test('≤14 天应返回 day', () {
      expect(StatsAggregator.granularityFor(Duration.zero),
          StatsGranularity.day);
      expect(StatsAggregator.granularityFor(const Duration(days: 1)),
          StatsGranularity.day);
      expect(StatsAggregator.granularityFor(const Duration(days: 14)),
          StatsGranularity.day);
    });

    test('15~90 天应返回 week', () {
      expect(StatsAggregator.granularityFor(const Duration(days: 15)),
          StatsGranularity.week);
      expect(StatsAggregator.granularityFor(const Duration(days: 30)),
          StatsGranularity.week);
      expect(StatsAggregator.granularityFor(const Duration(days: 90)),
          StatsGranularity.week);
    });

    test('91~730 天应返回 month', () {
      expect(StatsAggregator.granularityFor(const Duration(days: 91)),
          StatsGranularity.month);
      expect(StatsAggregator.granularityFor(const Duration(days: 365)),
          StatsGranularity.month);
      expect(StatsAggregator.granularityFor(const Duration(days: 730)),
          StatsGranularity.month);
    });

    test('>730 天应返回 year', () {
      expect(StatsAggregator.granularityFor(const Duration(days: 731)),
          StatsGranularity.year);
      expect(StatsAggregator.granularityFor(const Duration(days: 3650)),
          StatsGranularity.year);
    });
  });

  // ===========================================================================
  // 2. parseDailyPlayLog 解析
  // ===========================================================================
  group('parseDailyPlayLog - 日志解析', () {
    test('应正确解析新格式 {seconds, count}', () {
      final log = {
        '2026-07-29': {'seconds': 3600, 'count': 2},
        '2026-07-30': {'seconds': 1800, 'count': 1},
      };
      final entries = StatsAggregator.parseDailyPlayLog(log);
      expect(entries.length, 2);
      expect(entries[0].date, DateTime(2026, 7, 29));
      expect(entries[0].seconds, 3600);
      expect(entries[0].count, 2);
      expect(entries[1].date, DateTime(2026, 7, 30));
      expect(entries[1].seconds, 1800);
      expect(entries[1].count, 1);
    });

    test('应正确解析旧格式（纯数字）', () {
      final log = {'2026-07-29': 3600, '2026-07-30': 1800};
      final entries = StatsAggregator.parseDailyPlayLog(log);
      expect(entries.length, 2);
      expect(entries[0].seconds, 3600);
      expect(entries[0].count, 0); // 旧格式无 count
      expect(entries[1].seconds, 1800);
      expect(entries[1].count, 0);
    });

    test('应跳过无效日期 key', () {
      final log = {
        'invalid-date': {'seconds': 100, 'count': 1},
        '2026-07-29': {'seconds': 3600, 'count': 2},
      };
      final entries = StatsAggregator.parseDailyPlayLog(log);
      expect(entries.length, 1);
      expect(entries[0].date, DateTime(2026, 7, 29));
    });

    test('应按日期升序排列', () {
      final log = {
        '2026-07-31': {'seconds': 3000, 'count': 3},
        '2026-07-29': {'seconds': 1000, 'count': 1},
        '2026-07-30': {'seconds': 2000, 'count': 2},
      };
      final entries = StatsAggregator.parseDailyPlayLog(log);
      expect(entries[0].date, DateTime(2026, 7, 29));
      expect(entries[1].date, DateTime(2026, 7, 30));
      expect(entries[2].date, DateTime(2026, 7, 31));
    });

    test('空 map 应返回空列表', () {
      expect(StatsAggregator.parseDailyPlayLog({}), isEmpty);
    });
  });

  // ===========================================================================
  // 3. aggregate - 日粒度聚合
  // ===========================================================================
  group('aggregate - 日粒度', () {
    test('7 日跨度应生成 7 个点', () {
      final from = DateTime(2026, 7, 29);
      final to = DateTime(2026, 8, 4);
      final entries = [
        DailyEntry(date: DateTime(2026, 7, 29), seconds: 3600, count: 2),
        DailyEntry(date: DateTime(2026, 8, 1), seconds: 1800, count: 1),
        DailyEntry(date: DateTime(2026, 8, 4), seconds: 7200, count: 3),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.day,
      );
      expect(points.length, 7);
      expect(points[0].bucketStart, DateTime(2026, 7, 29));
      expect(points[0].seconds, 3600);
      expect(points[0].label, '07/29');
      expect(points[6].bucketStart, DateTime(2026, 8, 4));
      expect(points[6].seconds, 7200);
      expect(points[6].label, '08/04');
    });

    test('无数据的日期应填充 0', () {
      final from = DateTime(2026, 7, 29);
      final to = DateTime(2026, 7, 31);
      final entries = [
        DailyEntry(date: DateTime(2026, 7, 30), seconds: 3600, count: 1),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.day,
      );
      expect(points.length, 3);
      expect(points[0].seconds, 0); // 7/29 无数据
      expect(points[1].seconds, 3600); // 7/30 有数据
      expect(points[2].seconds, 0); // 7/31 无数据
    });

    test('单日应返回 1 个点', () {
      final day = DateTime(2026, 7, 29);
      final entries = [
        DailyEntry(date: day, seconds: 3600, count: 2),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: day,
        to: day,
        granularity: StatsGranularity.day,
      );
      expect(points.length, 1);
      expect(points[0].seconds, 3600);
      expect(points[0].count, 2);
    });

    test('空 entries 应返回全 0 的等距点', () {
      final from = DateTime(2026, 7, 29);
      final to = DateTime(2026, 7, 31);
      final points = StatsAggregator.aggregate(
        dailyEntries: const [],
        from: from,
        to: to,
        granularity: StatsGranularity.day,
      );
      expect(points.length, 3);
      expect(points.every((p) => p.seconds == 0 && p.count == 0), isTrue);
    });
  });

  // ===========================================================================
  // 4. aggregate - 周粒度
  // ===========================================================================
  group('aggregate - 周粒度', () {
    test('应按周一为起始聚合', () {
      // 2026-08-04 是周二，所在周周一是 2026-08-03
      final from = DateTime(2026, 7, 27); // 周一
      final to = DateTime(2026, 8, 9); // 周日
      final entries = [
        DailyEntry(date: DateTime(2026, 7, 28), seconds: 3600, count: 1),
        DailyEntry(date: DateTime(2026, 8, 4), seconds: 1800, count: 1),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.week,
      );
      expect(points.length, 2);
      // 第一周 7/27~8/2，包含 7/28
      expect(points[0].seconds, 3600);
      // 第二周 8/3~8/9，包含 8/4
      expect(points[1].seconds, 1800);
      expect(points[0].label, contains('W'));
    });
  });

  // ===========================================================================
  // 5. aggregate - 月粒度
  // ===========================================================================
  group('aggregate - 月粒度', () {
    test('应按自然月聚合', () {
      final from = DateTime(2026, 7, 1);
      final to = DateTime(2026, 8, 31);
      final entries = [
        DailyEntry(date: DateTime(2026, 7, 15), seconds: 3600, count: 1),
        DailyEntry(date: DateTime(2026, 7, 30), seconds: 1800, count: 1),
        DailyEntry(date: DateTime(2026, 8, 10), seconds: 7200, count: 2),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.month,
      );
      expect(points.length, 2);
      expect(points[0].seconds, 5400); // 7 月合计
      expect(points[0].label, '2026-07');
      expect(points[1].seconds, 7200); // 8 月
      expect(points[1].label, '2026-08');
    });

    test('跨年应正确分桶', () {
      final from = DateTime(2025, 12, 1);
      final to = DateTime(2026, 1, 31);
      final entries = [
        DailyEntry(date: DateTime(2025, 12, 25), seconds: 3600, count: 1),
        DailyEntry(date: DateTime(2026, 1, 5), seconds: 1800, count: 1),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.month,
      );
      expect(points.length, 2);
      expect(points[0].label, '2025-12');
      expect(points[1].label, '2026-01');
    });
  });

  // ===========================================================================
  // 6. aggregate - 年粒度
  // ===========================================================================
  group('aggregate - 年粒度', () {
    test('应按自然年聚合', () {
      final from = DateTime(2024, 1, 1);
      final to = DateTime(2026, 12, 31);
      final entries = [
        DailyEntry(date: DateTime(2024, 6, 15), seconds: 36000, count: 10),
        DailyEntry(date: DateTime(2025, 12, 31), seconds: 7200, count: 2),
        DailyEntry(date: DateTime(2026, 1, 1), seconds: 1800, count: 1),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.year,
      );
      expect(points.length, 3);
      expect(points[0].label, '2024');
      expect(points[0].seconds, 36000);
      expect(points[1].label, '2025');
      expect(points[1].seconds, 7200);
      expect(points[2].label, '2026');
      expect(points[2].seconds, 1800);
    });
  });

  // ===========================================================================
  // 7. aggregateSessionsToDaily - 会话重聚合
  // ===========================================================================
  group('aggregateSessionsToDaily - 会话重聚合', () {
    test('同日会话应正确累加', () {
      final sessions = [
        SessionRecord(
          startTime: DateTime(2026, 8, 4, 10, 0),
          endTime: DateTime(2026, 8, 4, 11, 0),
          durationSeconds: 3600,
        ),
        SessionRecord(
          startTime: DateTime(2026, 8, 4, 14, 0),
          endTime: DateTime(2026, 8, 4, 15, 30),
          durationSeconds: 5400,
        ),
      ];
      final entries = StatsAggregator.aggregateSessionsToDaily(sessions);
      expect(entries.length, 1);
      expect(entries[0].date, DateTime(2026, 8, 4));
      expect(entries[0].seconds, 9000);
      expect(entries[0].count, 2);
    });

    test('跨日会话应按比例分配到两天', () {
      // 23:00 → 01:00（共 2 小时 = 7200s）
      // 第一天 23:00~24:00 = 1h = 3600s
      // 第二天 00:00~01:00 = 1h = 3600s
      final sessions = [
        SessionRecord(
          startTime: DateTime(2026, 8, 4, 23, 0),
          endTime: DateTime(2026, 8, 5, 1, 0),
          durationSeconds: 7200,
        ),
      ];
      final entries = StatsAggregator.aggregateSessionsToDaily(sessions);
      expect(entries.length, 2);
      final e1 = entries.firstWhere((e) => e.date == DateTime(2026, 8, 4));
      final e2 = entries.firstWhere((e) => e.date == DateTime(2026, 8, 5));
      expect(e1.seconds, 3600);
      expect(e2.seconds, 3600);
      // 会话次数归入开始日期
      expect(e1.count, 1);
      expect(e2.count, 0);
    });

    test('duration < 60s 的会话应被过滤', () {
      final sessions = [
        SessionRecord(
          startTime: DateTime(2026, 8, 4, 10, 0),
          endTime: DateTime(2026, 8, 4, 10, 0, 30),
          durationSeconds: 30, // < 60s，应过滤
        ),
        SessionRecord(
          startTime: DateTime(2026, 8, 4, 11, 0),
          endTime: DateTime(2026, 8, 4, 12, 0),
          durationSeconds: 3600,
        ),
      ];
      final entries = StatsAggregator.aggregateSessionsToDaily(sessions);
      expect(entries.length, 1);
      expect(entries[0].seconds, 3600);
      expect(entries[0].count, 1);
    });

    test('空 sessions 应返回空列表', () {
      expect(StatsAggregator.aggregateSessionsToDaily([]), isEmpty);
    });

    test('多日多会话应正确分组合并', () {
      final sessions = [
        SessionRecord(
          startTime: DateTime(2026, 8, 1, 10, 0),
          endTime: DateTime(2026, 8, 1, 11, 0),
          durationSeconds: 3600,
        ),
        SessionRecord(
          startTime: DateTime(2026, 8, 3, 10, 0),
          endTime: DateTime(2026, 8, 3, 12, 0),
          durationSeconds: 7200,
        ),
        SessionRecord(
          startTime: DateTime(2026, 8, 1, 20, 0),
          endTime: DateTime(2026, 8, 1, 21, 0),
          durationSeconds: 3600,
        ),
      ];
      final entries = StatsAggregator.aggregateSessionsToDaily(sessions);
      expect(entries.length, 2);
      // 8/1 有两次会话，共 7200s
      final e1 = entries.firstWhere((e) => e.date == DateTime(2026, 8, 1));
      expect(e1.seconds, 7200);
      expect(e1.count, 2);
      final e3 = entries.firstWhere((e) => e.date == DateTime(2026, 8, 3));
      expect(e3.seconds, 7200);
      expect(e3.count, 1);
    });
  });

  // ===========================================================================
  // 8. periodRange - 时段计算
  // ===========================================================================
  group('periodRange - 时段计算', () {
    final now = DateTime(2026, 8, 4, 15, 30);
    final today = DateTime(2026, 8, 4);

    test('last7 应返回最近 7 天（含今日）', () {
      final r = StatsAggregator.periodRange(StatsPeriod.last7, now: now);
      expect(r.from, DateTime(2026, 7, 29));
      expect(r.to, today);
      expect(r.to.difference(r.from).inDays, 6);
    });

    test('last30 应返回最近 30 天', () {
      final r = StatsAggregator.periodRange(StatsPeriod.last30, now: now);
      expect(r.from, DateTime(2026, 7, 6));
      expect(r.to, today);
      expect(r.to.difference(r.from).inDays, 29);
    });

    test('last90 应返回最近 90 天', () {
      final r = StatsAggregator.periodRange(StatsPeriod.last90, now: now);
      expect(r.from, DateTime(2026, 5, 7));
      expect(r.to, today);
      expect(r.to.difference(r.from).inDays, 89);
    });

    test('all 应使用 firstPlayDate 作为 from', () {
      final r = StatsAggregator.periodRange(
        StatsPeriod.all,
        now: now,
        firstPlayDate: DateTime(2025, 1, 15),
      );
      expect(r.from, DateTime(2025, 1, 15));
      expect(r.to, today);
    });

    test('all 无 firstPlayDate 时退化为今日', () {
      final r = StatsAggregator.periodRange(StatsPeriod.all, now: now);
      expect(r.from, today);
      expect(r.to, today);
    });

    test('custom 应使用自定义区间', () {
      final r = StatsAggregator.periodRange(
        StatsPeriod.custom,
        now: now,
        customFrom: DateTime(2026, 1, 1),
        customTo: DateTime(2026, 6, 30),
      );
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2026, 6, 30));
    });

    test('custom 反向区间应自动修正顺序', () {
      final r = StatsAggregator.periodRange(
        StatsPeriod.custom,
        now: now,
        customFrom: DateTime(2026, 6, 30),
        customTo: DateTime(2026, 1, 1),
      );
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2026, 6, 30));
    });

    test('区间的两端应被规范化到本地 0 点', () {
      final r = StatsAggregator.periodRange(
        StatsPeriod.custom,
        now: now,
        customFrom: DateTime(2026, 1, 1, 10, 30),
        customTo: DateTime(2026, 1, 5, 23, 59),
      );
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2026, 1, 5));
    });
  });

  // ===========================================================================
  // 9. SessionRecord.fromJson 反序列化
  // ===========================================================================
  group('SessionRecord.fromJson - 反序列化', () {
    test('应正确解析标准字段', () {
      final json = {
        'start_time': '2026-08-04T10:00:00',
        'end_time': '2026-08-04T11:00:00',
        'duration_seconds': 3600,
      };
      final s = SessionRecord.fromJson(json);
      expect(s.startTime, DateTime(2026, 8, 4, 10, 0));
      expect(s.endTime, DateTime(2026, 8, 4, 11, 0));
      expect(s.durationSeconds, 3600);
    });

    test('缺失字段应使用默认值', () {
      final s = SessionRecord.fromJson({});
      expect(s.durationSeconds, 0);
      // 缺失时间字段应回退到 epoch
      expect(s.startTime, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });

  // ===========================================================================
  // 10. AggregatedPoint 相等性
  // ===========================================================================
  group('AggregatedPoint - 相等性', () {
    test('字段相同的两个实例应相等', () {
      final a = AggregatedPoint(
        bucketStart: DateTime(2026, 8, 4),
        seconds: 3600,
        count: 2,
        gameCount: 1,
        label: '08/04',
      );
      final b = AggregatedPoint(
        bucketStart: DateTime(2026, 8, 4),
        seconds: 3600,
        count: 2,
        gameCount: 1,
        label: '08/04',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('字段不同的实例应不相等', () {
      final a = AggregatedPoint(
        bucketStart: DateTime(2026, 8, 4),
        seconds: 3600,
        count: 2,
        gameCount: 1,
        label: '08/04',
      );
      final b = AggregatedPoint(
        bucketStart: DateTime(2026, 8, 4),
        seconds: 1800,
        count: 2,
        gameCount: 1,
        label: '08/04',
      );
      expect(a, isNot(equals(b)));
    });
  });

  // ===========================================================================
  // 11. 集成场景：模拟 1 年数据按月聚合
  // ===========================================================================
  group('集成场景 - 1 年数据按月聚合', () {
    test('应生成 12 个月度点', () {
      final from = DateTime(2026, 1, 1);
      final to = DateTime(2026, 12, 31);
      final entries = <DailyEntry>[
        for (int m = 1; m <= 12; m++)
          DailyEntry(
            date: DateTime(2026, m, 15),
            seconds: 3600 * m, // 1月3600s, 2月7200s, ...
            count: m,
          ),
      ];
      final points = StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.month,
      );
      expect(points.length, 12);
      expect(points[0].seconds, 3600);
      expect(points[0].count, 1);
      expect(points[11].seconds, 3600 * 12);
      expect(points[11].count, 12);
      // 性能验证：处理应足够快（< 200ms 期望）
      final sw = Stopwatch()..start();
      StatsAggregator.aggregate(
        dailyEntries: entries,
        from: from,
        to: to,
        granularity: StatsGranularity.month,
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: '1 年数据按月聚合应 < 200ms');
    });
  });
}
