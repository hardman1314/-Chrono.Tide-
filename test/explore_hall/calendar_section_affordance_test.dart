import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/kungal_calendar_game.dart';
import 'package:chrono_tide/services/kungal_calendar_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/explore_hall/calendar_section.dart';

/// 发售月历「可点 / 不可点」视觉可预期性回归（2026-10-03 · P0+P1）
///
/// 现象（开发者实测反馈）：KUNGAL 站内未收录的作品点不动。真因不是 NSFW、
/// 也不是遮罩层，而是这些条目缺 `claim.site == 'kungal'` ⇒ workId=0 ⇒
/// `detailUrl` 为空（kungal_calendar_service.dart:463-467），点击无处可去；
/// 但它们的卡片和可跳转条目**渲染完全一致**，于是被误读成「被挡住了」。
///
/// 本测试锁定修复后的视觉契约：
/// - 可打开（本地探索库命中 或 有 KUNGAL 详情页）→ 行尾「›」外跳箭头；
/// - 不可打开 → 行尾灰色「无详情」，不再给出可点击的暗示。
///
/// 判定器 `canOpen` 由大厅页注入（本地库命中判定只在大厅页可见），
/// 这里直接以两种返回值覆盖其两分支，全程零网络。

/// 今天（本地时区）的 ISO 日期前缀，月历条目必须落在今天才进日期面板
String get _todayIso {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

void main() {
  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题会抛 null check
    ThemeRegistry.registerBuiltinThemes();
  });

  /// 今日两条作品：
  /// - A「可跳转作品」带 KUNGAL claim → detailUrl 非空 → 天然可打开；
  /// - B「无详情作品」无 claim → detailUrl 为空 → 是否可打开取决于 canOpen。
  ///
  /// ⚠️ 必须带 companies：否则 company 为空串，行副标题回落到 `nameOriginal`
  /// （= display_name），同一标题字符串在 widget 树里出现两次，断言计数失真。
  Map<String, dynamic> buildPayload() => {
        'items': [
          {
            'id': '1001',
            'display_name': '可跳转作品',
            'release_date': _todayIso,
            'release_date_precision': 'day',
            'content_limit': 'sfw',
            'companies': [
              {'display_name': '测试会社A', 'attribution_role': 'developer'}
            ],
            'claim': {'site': 'kungal', 'site_work_id': '60936'},
          },
          {
            'id': '1002',
            'display_name': '无详情作品',
            'release_date': _todayIso,
            'release_date_precision': 'day',
            'content_limit': 'nsfw',
            'companies': [
              {'display_name': '测试会社B', 'attribution_role': 'developer'}
            ],
          },
        ],
      };

  /// 走注入 fetcher 的独立服务实例（`_useDisk=false` ⇒ 全程零磁盘零网络）
  Future<KungalCalendarService> loadedService() async {
    final svc = KungalCalendarService.forTest(
      fetchOverride: (url) async => buildPayload(),
    );
    await svc.ensureMonth(KungalCalendarService.monthKey(DateTime.now()));
    return svc;
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    required KungalCalendarService svc,
    bool Function(KungalCalendarGame)? canOpen,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarSection(
            kungal: svc,
            onItemTap: (_) {},
            canOpen: canOpen,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 行内（列表里）的箭头；必须排除月份导航「›」（同为
  /// Icons.chevron_right_rounded，且在 ListView 之外）
  Finder rowArrows() => find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.chevron_right_rounded),
      );

  testWidgets('未注入判定器：按「有 KUNGAL 详情页」判定，两条行状态分开', (tester) async {
    final svc = await loadedService();
    await pumpSection(tester, svc: svc);

    expect(tester.takeException(), isNull);
    expect(find.text('可跳转作品'), findsOneWidget);
    expect(find.text('无详情作品'), findsOneWidget);
    // 只有带 claim 的那条给箭头
    expect(rowArrows(), findsOneWidget);
    expect(find.text('无详情'), findsOneWidget);
  });

  testWidgets('判定器 true（本地探索库命中）：无 detailUrl 的行也视为可打开', (tester) async {
    final svc = await loadedService();
    await pumpSection(tester, svc: svc, canOpen: (_) => true);

    expect(rowArrows(), findsNWidgets(2));
    expect(find.text('无详情'), findsNothing);
  });

  testWidgets('判定器 false：两条行都明确标为不可打开', (tester) async {
    final svc = await loadedService();
    await pumpSection(tester, svc: svc, canOpen: (_) => false);

    expect(rowArrows(), findsNothing);
    expect(find.text('无详情'), findsNWidgets(2));
  });
}
