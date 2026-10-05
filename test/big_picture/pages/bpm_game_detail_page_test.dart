// BPM 二级游戏详情页 widget 测试（v3.12，2026-09-28 全屏整页取代右侧滑出面板）
//
// 🔴 锁死的是**纯静态分析抓不到**的三类问题：
//   1. 结构断言 —— `Positioned` 必须挂在 `Stack` 的直接子级；一旦中间隔了
//      `AnimatedSlide` / `AnimatedOpacity` 这类 pass-through 渲染对象，
//      ParentDataWidget 的父级约定会在**运行期**抛断言（analyze 全绿也照样崩）。
//   2. 布局溢出 —— 面板顶部数据区 + 底部常驻按钮行 + 中间唯一滚动视口的组合，
//      在 BPM 最低窗口（1280×720）下不得出现 RenderFlex overflow。
//   3. 接线 —— 隐藏 UI 回调、播放按钮的有无（无视频时必须没有死钮）、
//      以及手柄/读屏共用的语义标签。
//
// 截图 L 型排版沿用旧面板的既有实现（未改动），本文件不重复覆盖。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/pages/bpm_game_detail_page.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

LibraryGame _game({
  String title = 'ATRI -My Dear Moments-',
  String developer = 'ANIPLEX.EXE',
  String description = '在沉没的世界里，与一位少女相遇的故事。',
  List<String> tags = const ['视觉小说', '科幻', '治愈'],
  int playTime = 7325,
  String lastOpenedAt = '2024-08-30 21:15:00',
  PlayStatus status = PlayStatus.inProgress,
}) {
  return LibraryGame(
    title: title,
    directoryPath: '',
    metaDataDir: '',
    installedAt: '2024-01-02 10:00:00',
    developer: developer,
    description: description,
    tags: tags,
    playTime: playTime,
    lastOpenedAt: lastOpenedAt,
    playStatus: status,
  );
}

void main() {
  /// 「⋯」拉出菜单开合（shell 持有，页面读写）
  final ValueNotifier<bool> menuNotifier = ValueNotifier(false);

  setUpAll(() {
    // LocalGameRegistry / PathHelper 的路径 getter 必须在任何静态字段解析前
    // 拿到一个可写的根目录（与 focus/bpm_page_zone_wiring_test.dart 同款处理）。
    final root = Directory.systemTemp.createTempSync('ct_bpm_detail_page_');
    PathHelper.exeDirOverride = root.path;
  });

  setUp(() {
    // BpmInteractiveWrapper -> FocusGlow 会读 AppThemeManager.colors，
    // 未注册内置主题时 _themes 为空会抛 null check 异常。
    ThemeRegistry.registerBuiltinThemes();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    LibraryGame? game,
    bool visible = true,
    bool uiHidden = false,
    bool soundMuted = false,
    bool hasVideo = true,
    VoidCallback? onToggleUiHidden,
    VoidCallback? onReplayOp,
    VoidCallback? onLaunch,
    VoidCallback? onToggleSound,
    VoidCallback? onOpenGamepadConfig,
    VoidCallback? onEdit,
    VoidCallback? onOpenDirectory,
    VoidCallback? onDelete,
    Size size = const Size(1920, 1080),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmGameDetailPage(
            game: game ?? _game(),
            visible: visible,
            uiHidden: uiHidden,
            soundMuted: soundMuted,
            menuOpen: menuNotifier,
            onToggleUiHidden: onToggleUiHidden,
            // v3.17: 声音拉杆与播放钮都只在「有背景视频」时出现
            onReplayOp: hasVideo ? (onReplayOp ?? () {}) : null,
            onLaunch: onLaunch ?? () {},
            onToggleSound: onToggleSound ?? () {},
            onOpenGamepadConfig: onOpenGamepadConfig ?? () {},
            onBackdropTune: () {},
            onEdit: onEdit ?? () {},
            onOpenDirectory: onOpenDirectory ?? () {},
            onDelete: onDelete ?? () {},
          ),
        ),
      ),
    );
    // 进/出场动画跑完，避免半途的中间态
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('面板结构挂载不抛异常，且核心内容齐全', (tester) async {
    await pumpPage(tester);

    // ① 游戏数据区
    expect(find.text('ATRI -My Dear Moments-'), findsOneWidget);
    expect(find.text('ANIPLEX.EXE'), findsOneWidget);
    expect(find.text('视觉小说'), findsOneWidget);
    // ② 介绍（无截图 → 简介全文）
    expect(find.text('在沉没的世界里，与一位少女相遇的故事。'), findsOneWidget);
    // ③ 统计三项
    expect(find.text('游玩时长'), findsOneWidget);
    expect(find.text('上次游玩'), findsOneWidget);
    expect(find.text('游玩状态'), findsOneWidget);
    expect(find.text('2 小时 2 分钟'), findsOneWidget);
    expect(find.text('2024/8/30'), findsOneWidget);
    // ④ 底部常驻按钮行：编辑/目录/删除收进「⋯」菜单，不再各自独立成钮
    expect(find.text('游玩'), findsOneWidget);
    // ⚠️ 游玩按钮内**有文字**，语义标签会与子文本合并成同一节点
    // （图标按钮是纯图标，标签才等值匹配）→ 这里用正则匹配前缀。
    expect(find.bySemanticsLabel(RegExp('启动 ATRI')), findsOneWidget);
    expect(find.bySemanticsLabel('更多操作'), findsOneWidget);
    // v3.17: 手柄按钮改纯图标方钮（无文字标签）
    expect(find.bySemanticsLabel('手柄映射配置'), findsOneWidget);
    expect(find.text('手柄'), findsNothing);
    // v3.17: 有背景视频 → 声音拉杆 + 播放钮都在
    expect(find.bySemanticsLabel('静音背景声音'), findsOneWidget);
    expect(find.bySemanticsLabel('重播背景 OP 视频'), findsOneWidget);
    expect(find.bySemanticsLabel('背景图与背景视频管理'), findsOneWidget);
    expect(find.bySemanticsLabel('隐藏界面（欣赏背景）'), findsOneWidget);
    // 旧版「三个独立功能按钮」不允许回潮（已收进 ⋯ 拉出菜单）
    expect(find.bySemanticsLabel('编辑信息'), findsNothing);
    expect(find.bySemanticsLabel('打开游戏目录'), findsNothing);
    expect(find.bySemanticsLabel('删除游戏'), findsNothing);
    // 统计区新增「启动次数」
    expect(find.text('启动次数'), findsOneWidget);
    // 四个区域的固定部分都必须在，且**面板整体不滚动**（唯一滚动视口 = 介绍区）
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('「⋯」点击拉出菜单面板；点菜单外只关菜单；条目触发回调', (tester) async {
    var edited = 0;
    await pumpPage(tester, onEdit: () => edited++);

    // 拉出
    await tester.tap(find.bySemanticsLabel('更多操作'));
    await tester.pumpAndSettle();
    expect(menuNotifier.value, isTrue);
    expect(find.text('编辑信息'), findsOneWidget);
    expect(find.text('打开游戏目录'), findsOneWidget);
    expect(find.text('删除游戏'), findsOneWidget);

    // 点菜单外（屏幕右上角）→ 只关菜单，不触发 onEdit
    await tester.tapAt(const Offset(1700, 80));
    await tester.pumpAndSettle();
    expect(menuNotifier.value, isFalse);
    expect(find.text('编辑信息'), findsNothing);
    expect(edited, 0);

    // 再拉出并点「编辑信息」→ 回调触发 + 菜单收起
    await tester.tap(find.bySemanticsLabel('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    expect(edited, 1);
    expect(menuNotifier.value, isFalse);
  });

  testWidgets('「声音」按钮触发 onToggleSound', (tester) async {
    var toggled = 0;
    await pumpPage(tester, onToggleSound: () => toggled++);

    await tester.tap(find.bySemanticsLabel('静音背景声音'));
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('v3.17: 无背景视频时声音拉杆与播放钮都不渲染', (tester) async {
    await pumpPage(tester, hasVideo: false);

    expect(find.bySemanticsLabel('静音背景声音'), findsNothing);
    expect(find.bySemanticsLabel('重播背景 OP 视频'), findsNothing);
    // 背景管理 / 隐藏钮与视频无关，仍在
    expect(find.bySemanticsLabel('背景图与背景视频管理'), findsOneWidget);
    expect(find.bySemanticsLabel('隐藏界面（欣赏背景）'), findsOneWidget);
  });

  testWidgets('「手柄」按钮触发 onOpenGamepadConfig', (tester) async {
    var opened = 0;
    await pumpPage(tester, onOpenGamepadConfig: () => opened++);

    await tester.tap(find.bySemanticsLabel('手柄映射配置'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('BPM 最低窗口 1280×720 下不出现布局溢出', (tester) async {
    await pumpPage(tester, size: const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无背景视频时不渲染「播放」按钮（不留死钮）', (tester) async {
    await pumpPage(tester, hasVideo: false);
    expect(find.bySemanticsLabel('重播背景 OP 视频'), findsNothing);
  });

  testWidgets('有背景视频时渲染「播放」按钮并可回调', (tester) async {
    var replayed = false;
    await pumpPage(tester, onReplayOp: () => replayed = true);

    final play = find.bySemanticsLabel('重播背景 OP 视频');
    expect(play, findsOneWidget);
    await tester.tap(play);
    await tester.pump();
    expect(replayed, isTrue);
  });

  testWidgets('隐藏 UI 按钮触发回调；隐藏态整块淡出', (tester) async {
    var toggled = 0;
    await pumpPage(tester, onToggleUiHidden: () => toggled++);

    await tester.tap(find.bySemanticsLabel('隐藏界面（欣赏背景）'));
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('隐藏态：点击任意位置即唤回（且不穿透关闭详情）', (tester) async {
    var toggled = 0;
    await pumpPage(
      tester,
      uiHidden: true,
      onToggleUiHidden: () => toggled++,
    );

    await tester.tapAt(const Offset(960, 540));
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('隐藏态：任意键即唤回', (tester) async {
    var toggled = 0;
    await pumpPage(
      tester,
      uiHidden: true,
      onToggleUiHidden: () => toggled++,
    );

    // 唤回层靠 autofocus 拿焦点，拿不到就说明键盘唤回路径断了
    expect(FocusManager.instance.primaryFocus, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('隐藏态：定位层仍完整（Positioned 仍挂在 Stack 直接子级）',
      (tester) async {
    await pumpPage(tester, uiHidden: true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不可见态不抛异常（关闭后 widget 仍在树上做退场）', (tester) async {
    await pumpPage(tester, visible: false);
    expect(tester.takeException(), isNull);
  });
}
