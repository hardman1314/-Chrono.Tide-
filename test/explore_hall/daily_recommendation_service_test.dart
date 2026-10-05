import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/game_model.dart';
import 'package:chrono_tide/services/daily_recommendation_service.dart';
import 'package:chrono_tide/services/explore_calendar_service.dart';

/// DailyRecommendationService 测试（当日快照持久化 + 就绪编排）
///
/// 全程内存 reader/writer 注入，零磁盘零网络；
/// 探索库数据经 debugInjectGames 注入（gamesLoaded=true、isWarming=false）。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_daily_rec_test');
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  GameModel game(String id, {List<String> tags = const [], String dev = ''}) =>
      GameModel(
        id: id,
        title: '游戏$id',
        tags: tags,
        developer: dev,
        created: DateTime(2026, 1, 1),
        updated: DateTime(2026, 1, 1),
      );

  test('就绪编排：探索库未就绪不生成，注入数据后立即生成并持久化', () {
    String? stored;
    var writeCount = 0;
    final daily = DailyRecommendationService.forTest(
      reader: () => stored,
      writer: (s) {
        stored = s;
        writeCount++;
      },
    );
    final calendar = ExploreCalendarService.forTest();

    daily.attach(calendar);
    expect(daily.plan, isNull, reason: '数据未就绪不应生成');

    calendar.debugInjectGames([
      game('a', tags: ['恋爱'], dev: 'Key'),
      game('b', tags: ['恋爱'], dev: 'Key'),
      game('c', tags: ['奇幻'], dev: 'AliceSoft'),
    ]);

    expect(daily.plan, isNotNull, reason: 'gamesLoaded=true 后应自动生成');
    expect(daily.plan!.items, isNotEmpty);
    expect(writeCount, 1, reason: '生成后应持久化一次');
  });

  test('当日恒定：二次事件（notify）不重算，快照写入次数不变', () {
    String? stored;
    var writeCount = 0;
    final daily = DailyRecommendationService.forTest(
      reader: () => stored,
      writer: (s) {
        stored = s;
        writeCount++;
      },
    );
    final calendar = ExploreCalendarService.forTest();
    daily.attach(calendar);
    calendar.debugInjectGames([game('a')]);
    final first = daily.plan;
    expect(first, isNotNull);
    final writesAfterFirst = writeCount;

    // 再次通知（模拟元数据补全等事件）——当日已定，绝不重算
    calendar.debugInjectGames([game('a'), game('b'), game('c')]);
    expect(identical(daily.plan, first), isTrue,
        reason: '当日快照对象不应被替换');
    expect(writeCount, writesAfterFirst, reason: '当日不应再次写入');
  });

  test('load：命中当日快照直接展示（不依赖探索库就绪）', () {
    String? stored;
    final generator = DailyRecommendationService.forTest(
      writer: (s) => stored = s,
    );
    final calendar = ExploreCalendarService.forTest();
    generator.attach(calendar);
    calendar.debugInjectGames([
      game('a', tags: ['恋爱']),
      game('b', tags: ['恋爱']),
    ]);
    expect(stored, isNotNull);

    // 新服务实例读同一份快照：无需 attach / 未注入数据也直接命中
    final loaded = DailyRecommendationService.forTest(reader: () => stored);
    loaded.load();
    expect(loaded.plan, isNotNull);
    expect(loaded.plan!.items, isNotEmpty);
    expect(loaded.plan!.day.day, DateTime.now().day, reason: '应为当日快照');
  });

  test('load：非当日快照被静默丢弃', () {
    const oldJson =
        '{"day":"2020-01-01","dimension":"rating","dimensionValue":null,'
        '"label":"过期主题","items":[{"gameId":"x","title":"x","score":9.0}]}';
    final daily = DailyRecommendationService.forTest(reader: () => oldJson);
    daily.load();
    expect(daily.plan, isNull, reason: '过期快照不应展示');
  });

  test('load：无 version 的旧版快照（残缺数据）被丢弃重生成', () {
    // 修复前（预热未等完就生成）写入的快照没有 version 字段，
    // 读入必须丢弃——否则当日一直锁定一份不完整数据
    const legacyTemplate =
        '{"day":"DAY_PLACEHOLDER","dimension":"tag","dimensionValue":"恋爱",'
        '"label":"旧格式","items":[{"gameId":"x","title":"x","score":0.0}]}';
    final n = DateTime.now();
    final todayJson = legacyTemplate.replaceFirst(
        'DAY_PLACEHOLDER',
        '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}');
    final daily = DailyRecommendationService.forTest(reader: () => todayJson);
    daily.load();
    expect(daily.plan, isNull, reason: '旧版快照应被丢弃，等待重新生成');
  });

  test('detach 后再 attach 可重新绑定（大厅页重建场景）', () {
    String? stored;
    final daily = DailyRecommendationService.forTest(
      reader: () => stored,
      writer: (s) => stored = s,
    );
    final calendar = ExploreCalendarService.forTest();
    daily.attach(calendar);
    calendar.debugInjectGames([game('a')]);
    expect(daily.plan, isNotNull);

    daily.detach();
    final calendar2 = ExploreCalendarService.forTest();
    daily.attach(calendar2);
    expect(daily.plan, isNotNull, reason: '当日快照仍在，attach 不应清空');
    // 换新日历（未就绪）不触发任何异常
    calendar2.debugInjectGames([]);
  });
}
