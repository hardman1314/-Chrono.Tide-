import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/pages/explore_hall_page.dart';
import 'package:chrono_tide/services/daily_recommendation_service.dart';
import 'package:chrono_tide/services/explore_calendar_service.dart';
import 'package:chrono_tide/services/kungal_calendar_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

/// 探索大厅布局压测（方案 Phase 0-V4 / Phase 2 验收）
///
/// 主窗口最小尺寸 960×540，大厅是单页固定式两栏布局，
/// 用 widget test 固定视口尺寸验证无 RenderFlex 溢出。
///
/// 注意：autoWarmup=false + 注入 seriesLoader/noticeLoader，
/// 全程零网络请求；不点「开始探索」（DiscoverPage 会发起网络加载与免责弹窗，
/// 不适合在 fakeAsync 测试环境运行）。
void main() {
  late Directory tempDir;

  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题时
    // _themes 为空会抛 null check 异常（与 big_picture 测试同款处理）
    ThemeRegistry.registerBuiltinThemes();
  });

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_hall_layout_test');
    // 必须在任何 PathHelper 路径 getter 解析前设置（exeDir 首次访问即缓存）
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreHallPage(
            autoWarmup: false,
            calendarService: ExploreCalendarService.forTest(),
            kungalService: KungalCalendarService.forTest(),
            dailyService: DailyRecommendationService.forTest(),
            seriesLoader: () async => const [],
            noticeLoader: () async => '测试通知文本',
          ),
        ),
      ),
    );
    // 两帧：布局一帧 + 异步加载状态稳定一帧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('960×540 最小窗口：大厅布局无溢出', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHall(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('探索大厅'), findsOneWidget);
    expect(find.text('开始探索'), findsOneWidget);
    // 板块身份：相关话题副标题必须保留「每日推荐」字样（用户可辨识板块用途）
    expect(find.textContaining('每日推荐'), findsWidgets);
    // 七大板块标题全部就位（③大标题行之外的六个板块外壳）
    expect(find.text('发售月历'), findsOneWidget);
    expect(find.text('相关话题'), findsOneWidget);
    expect(find.text('常用站点'), findsOneWidget);
    expect(find.text('系列合集'), findsOneWidget);
    expect(find.text('文档与趣味'), findsOneWidget);
  });

  testWidgets('1280×800 常规窗口：大厅布局无溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHall(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('探索大厅'), findsOneWidget);
  });

  /// 回归护栏（2026-10-01）：文档板块的 tab 从 4 个增至 6 个
  /// （新增【发布】【我的】）。左区内容宽度在 960×540 下仅 ≈194px，
  /// 而 6 个标签单行需 ≈275px ⇒ 若仍用 `Row` 必然 RenderFlex 溢出，
  /// 故改用 `Wrap` 换行兜底。
  ///
  /// 🔴 `Wrap` 有两个必要前提，缺一即崩坏：
  /// ① 子项不能是裸 `InteractiveWrapper` —— 其内部 AnimatedContainer 带
  ///    `alignment: Alignment.center`，在 Wrap 的有界松约束下会撑满整行；
  /// ② 子项须由 `IntrinsicWidth` 给出 tight 宽度（= 内容宽）才按内容定宽。
  testWidgets('960×540 最小窗口：文档板块 6 个标签换行不溢出，【发布】【我的】可进入',
      (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHall(tester);
    expect(tester.takeException(), isNull);

    // 6 个标签全部在册（顺序即 _tabLabels：介绍/使用说明/通知/发布/我的/动态）
    for (var i = 0; i < 6; i++) {
      final finder = find.byKey(ValueKey('docsTab_$i'));
      expect(finder, findsOneWidget, reason: '文档板块第 $i 个分段标签缺失');
      // 🔴 崩坏哨兵（2026-10-01 回归）：InteractiveWrapper 内部的
      // AnimatedContainer 带 `alignment: Alignment.center`，一旦直接放进
      // `Wrap`，会被**有界松约束**撑满整行（Align 撑开）⇒ 每个标签各占
      // 一行竖排、并撑爆板块内容区（RenderFlex 溢出）。
      // 标签自然宽度上限约 60px（「使用说明」4 字），被撑满时 ≈ 整行宽
      // （960×540 下 ≈194px）⇒ 取 120px 为阈值可精准捕获该类回归。
      expect(tester.getSize(finder).width, lessThan(120),
          reason: '第 $i 个标签宽度异常偏大 ⇒ 在 Wrap 中被撑满整行（竖排崩坏回归）');
    }

    // 【发布】进入后不溢出（三步的第 1 步判重完全在板块内完成）
    await tester.tap(find.byKey(const ValueKey('docsTab_3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsWidgets);

    // 【我的】未登录时给登录提示，全程零网络请求（PBConfig.authStore 为空）
    await tester.tap(find.byKey(const ValueKey('docsTab_4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('登录后可在这里管理'), findsOneWidget);
  });
}
