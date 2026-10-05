import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/game_model.dart';
import 'package:chrono_tide/services/daily_recommendation_service.dart';
import 'package:chrono_tide/services/explore_calendar_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/explore_hall/related_topics_section.dart';

/// 相关话题「焦点轮播」交互测试
///
/// 语义（用户口径，档案 §18.2）：定时把**选中焦点项**下移一条（不是滚动
/// 列表），大卡跟随联动；鼠标悬停 / 点击条目 / 键盘上下键 均暂停自动
/// 焦点；鼠标离开并闲置一段时间后自动恢复循环。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_topics_carousel_test');
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    ThemeRegistry.registerBuiltinThemes();
  });

  /// 当日快照 JSON（version 2，否则被判为旧格式丢弃）
  String snapshot({required int count}) {
    final n = DateTime.now();
    final day =
        '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
    final items = [
      for (var i = 0; i < count; i++)
        '{"gameId":"g$i","title":"游戏$i","coverUrl":"","tags":["t$i"],'
            '"developer":"会社$i","score":${(9 - i / 10).toStringAsFixed(1)}}'
    ];
    return '{"version":2,"day":"$day","dimension":"rating","dimensionValue":null,'
        '"label":"全库高星 · 按星级排序","items":[${items.join(',')}]}';
  }

  Future<void> pumpSection(
    WidgetTester tester,
    DailyRecommendationService daily,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            width: 640,
            child: RelatedTopicsSection(
              service: ExploreCalendarService.forTest(),
              daily: daily,
              onGameTap: (GameModel _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(); // load() 的异步读快照落地
  }

  String bigTitle(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('topicBigCardTitle'))).data!;

  testWidgets('定时下移焦点：大卡跟随联动，到底循环回第一条', (tester) async {
    final daily =
        DailyRecommendationService.forTest(reader: () => snapshot(count: 4));
    await pumpSection(tester, daily);

    expect(bigTitle(tester), '游戏0', reason: '初始焦点在第 1 条');

    for (var i = 1; i <= 3; i++) {
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(bigTitle(tester), '游戏$i', reason: '第 ${i + 1} 次 tick 后焦点应在 $i');
    }

    // 最后一条后回到第一条（循环）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(bigTitle(tester), '游戏0', reason: '到底应循环回第一条');
  });

  testWidgets('鼠标悬停列表区域 → 暂停自动焦点；移开闲置后恢复', (tester) async {
    final daily =
        DailyRecommendationService.forTest(reader: () => snapshot(count: 4));
    await pumpSection(tester, daily);
    expect(bigTitle(tester), '游戏0');

    final listCenter = tester.getCenter(find.byKey(const Key('topicList')));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() async => gesture.removePointer());
    await gesture.moveTo(listCenter);
    await tester.pump();

    // 悬停期间：自动焦点不动
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(bigTitle(tester), '游戏0', reason: '悬停时应暂停自动焦点');

    // 移开：闲置延时（3s）后恢复循环 → 再经过一个推进间隔（4s）焦点下移
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(bigTitle(tester), '游戏1', reason: '鼠标移开并闲置后应恢复自动焦点');
  });

  testWidgets('点击条目锁定选中 + 方向键手动切换（同样暂停自动循环）',
      (tester) async {
    final daily =
        DailyRecommendationService.forTest(reader: () => snapshot(count: 4));
    await pumpSection(tester, daily);

    // 点击第 3 条 → 锁定选中（并让列表取得键盘焦点）
    await tester.tap(find.byKey(const Key('topicRow_2')));
    await tester.pumpAndSettle();
    expect(bigTitle(tester), '游戏2', reason: '点击应锁定选中项');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'topicsList',
        reason: '点击后列表应取得键盘焦点');

    // 键盘 ↓ / ↑ 手动切换
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(bigTitle(tester), '游戏3', reason: '↓ 应下移焦点');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(bigTitle(tester), '游戏1', reason: '↑ 应上移焦点');

    // 主动操作后 [_interactionHold](8s) 内不自动推进
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bigTitle(tester), '游戏1', reason: '交互后应保持焦点不动');
  });

  testWidgets('推荐列表不足两条时不推进焦点', (tester) async {
    final daily =
        DailyRecommendationService.forTest(reader: () => snapshot(count: 1));
    await pumpSection(tester, daily);
    expect(bigTitle(tester), '游戏0');
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(bigTitle(tester), '游戏0');
  });
}
