// BPM 板块焦点域「装配完整性」回归测试（v3.10.2）
//
// 🔴 本文件锁死的是一个**装配漏项**型 BUG，它不会被任何纯逻辑单测发现：
//
// v3.10.1 给每个二级板块都加了 `BpmFocusDomain`（独立 `FocusScopeNode`），
// 但**主页第三个板块「游戏卡片列表」只包了 `BpmFocusZone`（视觉高亮），
// 漏了 `BpmFocusDomain`**。后果是双重的：
//   1. `FocusTraversalPolicy.inDirection` 只认 `nearestScope` —— 卡片所在的
//      最近 scope 变成了整个 stage，候选集合 = 搜索框 + chips + 操作按钮 +
//      所有卡片 → 左右键在列表里乱走（真机报「主页无法左右翻动游戏列表」）；
//   2. `BpmZoneFocusController.entryFocusOf(homeShelf)` 永远返回 null →
//      `focusEntryOf` false → **A 键连板块都进不去**（真机报「主页无法用手柄
//      操作」）。
//
// 因此这里不再用「假布局」复刻，而是**挂真页面**（BigPictureHome /
// BigPictureLibraryPage），逐个断言 `kBpmHomeZones` / `kBpmLibraryZones`
// 里每个板块都①注册了焦点域、②域内能算出落点焦点。以后再漏一个板块，
// 这里当场红。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/big_picture/focus/bpm_zone_focus_controller.dart';
import 'package:chrono_tide/big_picture/pages/big_picture_home.dart';
import 'package:chrono_tide/big_picture/pages/big_picture_library_page.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

/// 主页宿主：持有「舞台焦点游戏」并回传，与 `BigPictureShell` 的接线一致。
///
/// 🔴 不能直接给 `BigPictureHome(stageGame: null)` 了事 —— 无舞台游戏时
/// `_buildHeroActions()` 返回 `SizedBox.shrink()`，「操作按钮板块」里
/// **一个可聚焦组件都没有**，于是 `entryFocusOf(homeActions)` 必然为 null。
/// 那不是产品缺陷（真机启动时 `_loadGames` 必定先把最近游玩设成舞台游戏），
/// 但会让这条装配断言测不出东西。
class _HomeHost extends StatefulWidget {
  const _HomeHost({required this.onGameLaunch, this.onShowDetailPanel});

  final ValueChanged<LibraryGame> onGameLaunch;

  /// v3.14: 单击卡片 / 手柄 A = 进二级详情（记录触发）
  final ValueChanged<LibraryGame>? onShowDetailPanel;

  @override
  State<_HomeHost> createState() => _HomeHostState();
}

class _HomeHostState extends State<_HomeHost> {
  LibraryGame? _stage;

  @override
  void initState() {
    super.initState();
    final games = LocalGameRegistry.instance.allGames;
    _stage = games.isEmpty ? null : games.first;
  }

  @override
  Widget build(BuildContext context) {
    return BigPictureHome(
      stageGame: _stage,
      onStageGameChanged: (g) => setState(() => _stage = g),
      onGameLaunch: widget.onGameLaunch,
      onShowDetailPanel:
          widget.onShowDetailPanel ?? (LibraryGame _) {},
    );
  }
}

/// 占位回调：`const _HomeHost(...)` 需要编译期常量
void _noopLaunch(LibraryGame _) {}

void main() {
  late Directory appRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_bpm_zone_wiring_');
    // 必须在任何 PathHelper 路径 getter / LocalGameRegistry 静态字段解析之前设置
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 每个用例注册自己的游戏，用完删干净（registry 是进程内单例）
  final registered = <String>[];

  void seedGames(int count) {
    final reg = LocalGameRegistry.instance;
    for (var i = 0; i < count; i++) {
      final title = '板块装配测试作品_$i';
      registered.add(title);
      reg.registerExtractionComplete(
        gameTitle: title,
        directoryPath: p.join(appRoot.path, 'Games', title),
        gameId: 'zone-wiring-$i',
      );
    }
  }

  tearDown(() async {
    final reg = LocalGameRegistry.instance;
    for (final t in registered) {
      try {
        await reg.deleteGame(t);
      } catch (_) {}
    }
    registered.clear();
  });

  /// 挂载前把测试窗口放大到接近真机大屏，避免 Positioned 布局溢出
  void useBigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// shell 侧「激活当前焦点控件」的等价实现（big_picture_shell.dart 的
  /// `_activateFocused`）：先走节点的 Enter 回调，未消费再试 ActivateIntent。
  ///
  /// 用 Enter 而不是直接调回调，是为了让「双击 A」这类由 FocusGlow 自己
  /// 维护的连按状态一并被覆盖。
  Future<void> pressA(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  // ==========================================================
  group('主页二级板块装配', () {
    testWidgets('三个二级板块都必须注册焦点域且有落点焦点', (tester) async {
      useBigScreen(tester);
      seedGames(3);

      final controller = BpmZoneFocusController();
      await tester.pumpWidget(
        MaterialApp(
          home: BpmZoneFocusScope(
            controller: controller,
            child: const Scaffold(
              body: _HomeHost(onGameLaunch: _noopLaunch),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final zone in kBpmHomeZones) {
        expect(controller.domainOf(zone), isNotNull,
            reason: '$zone 只包了 BpmFocusZone 没包 BpmFocusDomain —— '
                '方向键候选集合会退化成整个 stage');
        expect(controller.entryFocusOf(zone), isNotNull,
            reason: '$zone 域内算不出落点焦点, 手柄 A 键进不去这个板块');
      }

      // 卡片列表板块必须真的能落焦（本 BUG 的直接判据）
      expect(controller.focusEntryOf(BpmZoneId.homeShelf), isTrue,
          reason: '规范第 2/3 条要求页面落点 = 卡片列表板块');
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(controller.zoneOfScope(focus!.nearestScope), BpmZoneId.homeShelf);
    });

    testWidgets('卡片列表: 左右键在卡片间移动; A 进详情不启动 (v3.14)',
        (tester) async {
      useBigScreen(tester);
      seedGames(4);

      final controller = BpmZoneFocusController();
      final launched = <String>[];
      final details = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: BpmZoneFocusScope(
            controller: controller,
            child: Scaffold(
              body: _HomeHost(
                onGameLaunch: (g) => launched.add(g.title),
                onShowDetailPanel: (g) {
              details.add(g.title);
              // ignore: avoid_print
              print('DETAIL-CALL #' + details.length.toString() + ': ' + g.title);
              // ignore: avoid_print
              print(StackTrace.current.toString().split('\n').take(14).join('\n'));
            },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      controller.landOnCardList(page: 0);
      expect(controller.focusEntryOf(BpmZoneId.homeShelf), isTrue);
      await tester.pump();

      // ── 左右键: 焦点必须留在卡片列表板块内 ──
      final first = FocusManager.instance.primaryFocus!;
      final policy = controller.domainOf(BpmZoneId.homeShelf)!.policy;
      expect(policy.inDirection(first, TraversalDirection.right), isTrue,
          reason: '列表里按右必须能换到下一张卡');
      await tester.pump();
      final second = FocusManager.instance.primaryFocus!;
      expect(identical(second, first), isFalse, reason: '右键没有换卡');
      expect(controller.zoneOfScope(second.nearestScope), BpmZoneId.homeShelf,
          reason: '右键把焦点带出了卡片列表板块');

      policy.inDirection(second, TraversalDirection.left);
      await tester.pump();
      expect(
          controller.zoneOfScope(
              FocusManager.instance.primaryFocus!.nearestScope),
          BpmZoneId.homeShelf);

      // ── v3.14: 手柄 A = 进二级详情（原「连按两次 A 启动」已移除，改 X 键启动）──
      // ⚠️ 实测：本测试环境一次 sendKeyEvent 会把同一 KeyDown 分发到同一节点
      // 两次（最小复现排除了 FocusScope / 嵌套 Focus；旧代码被双击窗口去重掩盖）。
      // 生产侧「进详情」幂等（_showGamePanel 重复调用状态不变），无用户可见影响。
      // 这里锁死关键语义：A 绝不启动、详情确实被打开。
      await pressA(tester);
      await tester.pump();
      expect(details, isNotEmpty, reason: 'A 必须直接进二级详情（单击卡片语义）');
      expect(launched, isEmpty, reason: 'A 不得触发启动（启动已改 X 键）');

      // 连按两次 A 同样绝不启动
      await pressA(tester);
      await tester.pump(
          const Duration(milliseconds: 400) + const Duration(milliseconds: 100));
      expect(launched, isEmpty, reason: '连按两次 A 也不得启动');

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  // ==========================================================
  group('库页二级板块装配', () {
    testWidgets('两个二级板块都必须注册焦点域且有落点焦点', (tester) async {
      useBigScreen(tester);
      seedGames(3);

      final controller = BpmZoneFocusController();
      await tester.pumpWidget(
        MaterialApp(
          home: BpmZoneFocusScope(
            controller: controller,
            child: Scaffold(
              body: BigPictureLibraryPage(
                onShowDetailPanel: (_) {},
                onGameLaunch: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final zone in kBpmLibraryZones) {
        expect(controller.domainOf(zone), isNotNull, reason: '$zone 缺焦点域');
        expect(controller.entryFocusOf(zone), isNotNull,
            reason: '$zone 域内无可聚焦组件');
      }
      expect(controller.focusEntryOf(BpmZoneId.libraryWall), isTrue);
      await tester.pump();
      expect(
          controller.zoneOfScope(
              FocusManager.instance.primaryFocus!.nearestScope),
          BpmZoneId.libraryWall);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('海报墙: 单击 A 走 onTap(开详情), 连按两次 A 走 onLaunch(启动)',
        (tester) async {
      useBigScreen(tester);
      seedGames(3);

      final controller = BpmZoneFocusController();
      final opened = <String>[];
      final launched = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: BpmZoneFocusScope(
            controller: controller,
            child: Scaffold(
              body: BigPictureLibraryPage(
                onShowDetailPanel: (g) => opened.add(g.title),
                onGameLaunch: (g) => launched.add(g.title),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      controller.landOnCardList(page: 1);
      expect(controller.focusEntryOf(BpmZoneId.libraryWall), isTrue);
      await tester.pump();

      // 连按两次 → 启动, 且**不**触发单击(开详情面板)
      await pressA(tester);
      await pressA(tester);
      expect(launched.length, 1, reason: '连按两次 A = 鼠标双击 = 启动');
      expect(opened, isEmpty,
          reason: '被判为双击后不得再走单击(否则会先弹出详情面板挡路)');

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });
}
