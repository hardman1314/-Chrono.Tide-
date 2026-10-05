// BPM 主页货架「选中放大被视口硬裁剪」几何回归测试（v3.23）
//
// 🔴 锁死的**真机现象**：把货架最左 / 最右那张卡片选中时，封面在该侧显示
// 不完整 —— 约 6.72px 内容连同该侧 2px 樱粉描边与圆角被一起切掉，看起来
// 像「被主页界面挡住了」。
//
// 成因（两层叠加，缺一不可）：
//   ① 卡片静止时的左右边缘**正好压在横向 ListView 的视口边缘上**
//      —— 货架 Container 水平 padding 32，而 ListView 只有竖直 padding；
//   ② 选中放大走 `AnimatedScale`，属于「只画不改布局」，左右各向外多画
//      shelfCardWidth * (shelfFocusScale - 1) / 2 = 224 * 0.06 / 2 = 6.72px。
//   → 超出视口的部分被 `Clip.hardEdge` 硬切。框架自带的
//     `Scrollable.ensureVisible` 只保证**布局矩形**可见，救不了「画出去」的部分。
//
// 修法：货架 Container 的水平 padding 收窄到 `shelfViewportBleed`（把视口
// 裁剪边界向外扩出余量），内容侧（标题行 / ListView）用自己的 padding 保持
// `shelfPageInset` 的静止内缩 —— 静止几何逐像素不变，只多出余量。
//
// 因此本测试断言的是**几何不变量**，而不是某个魔数：
//   ① 视口裁剪边界距舞台左右边缘只有 shelfViewportBleed（而不是 32）；
//   ② 卡片静止边缘距视口边界还有 shelfContentHorizontalPadding 的余量；
//   ③ 该余量 ≥ 放大溢出量（「放大后不被裁」这件事本身）。
// 谁把货架 Container 的 padding 改回 32、或把 bleed 调小到溢出量以下，这里当场红。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/big_picture/big_picture_theme.dart';
import 'package:chrono_tide/big_picture/pages/big_picture_home.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

void _noopStage(LibraryGame _) {}

void _noopLaunch(LibraryGame _) {}

void _noopDetail(LibraryGame _) {}

/// 货架卡片（`_ShelfCard` 是私有类，按 ValueKey('shelf_<title>') 认领）
Finder _shelfCards() => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('shelf_');
    });

void main() {
  late Directory appRoot;
  final registered = <String>[];

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_bpm_shelf_clip_');
    // 必须在任何 PathHelper 路径 getter / LocalGameRegistry 静态字段解析之前设置
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  void seedGames(int count) {
    final reg = LocalGameRegistry.instance;
    for (var i = 0; i < count; i++) {
      final title = '货架裁剪测试作品_$i';
      registered.add(title);
      reg.registerExtractionComplete(
        gameTitle: title,
        directoryPath: p.join(appRoot.path, 'Games', title),
        gameId: 'shelf-clip-$i',
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

  testWidgets('主页货架: 视口边界外扩且卡片两侧留足放大余量（放大不再被裁）',
      (tester) async {
    // 真机大屏尺寸；dpr=1 让「物理像素 == 逻辑像素」，断言读起来就是设计值
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 必须超过一屏：否则列表不可滚，右端「末卡贴视口右缘」的情形复现不出来
    seedGames(12);

    // 不套 BpmZoneFocusScope：`BpmFocusZone` 在无控制器时直接返回 child，
    // 货架 DOM 与真机一致，而少一层与几何无关的焦点机制。
    // 本用例只关心布局，故 stageGame 传 null（无选中卡也不影响静止几何）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BigPictureHome(
            stageGame: null,
            onStageGameChanged: _noopStage,
            onGameLaunch: _noopLaunch,
            onShowDetailPanel: _noopDetail,
          ),
        ),
      ),
    );
    await tester.pump();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    // 横向 ListView 的视口 = 它的裁剪边界（Clip.hardEdge）
    final viewportRect = tester.getRect(
      find.descendant(of: listFinder, matching: find.byType(Viewport)),
    );
    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // 本宿主没有左侧导航栏 → 舞台左缘 = 0，故视口边界就是纯 bleed 值
    const bleed = BigPictureTheme.shelfViewportBleed;

    // ── ① 裁剪边界只缩进 bleed（若有人改回 32，这里立刻红）──
    expect(
      viewportRect.left,
      moreOrLessEquals(bleed, epsilon: 0.5),
      reason: '视口左裁剪边界应在舞台左缘 + shelfViewportBleed($bleed)；'
          '变回货架 Container 的旧水平 padding(32) 就会重新裁掉放大段',
    );
    expect(
      screenWidth - viewportRect.right,
      moreOrLessEquals(bleed, epsilon: 0.5),
      reason: '视口右裁剪边界同理',
    );

    // ── ② 左端：首卡静止左缘距视口边界 = shelfContentHorizontalPadding ──
    //    （bleed + 该值 = shelfPageInset = 32，即静止内缩与改动前逐像素一致）
    expect(_shelfCards(), findsWidgets);
    final firstRect = tester.getRect(_shelfCards().first);
    final leftRoom = firstRect.left - viewportRect.left;
    expect(
      leftRoom,
      moreOrLessEquals(
        BigPictureTheme.shelfContentHorizontalPadding,
        epsilon: 0.5,
      ),
      reason: '首卡静止左缘应保持 shelfPageInset 的净内缩',
    );

    // ── ③ 这份余量必须装得下放大溢出（本 BUG 的直接判据）──
    //    ⚠️ 量到的是**卡片 item 盒**（232 = 224 + 2×cardFocusGlowWidth(4)，
    //    焦点环 4px 内边距在盒内、卡片在其中心），所以严格所需的余量只要
    //    6.72 − 4 = 2.72px 就能保住封面；这里仍按全额 6.72 断言 ——
    //    保守到「连焦点环与描边都完整落在视口内」。
    //    （离线探针实测：修复前 item 左缘 == 裁剪边界 → 实际被切 2.72px。）
    final overflow = BigPictureTheme.shelfCardWidth *
        (BigPictureTheme.shelfFocusScale - 1) /
        2; // 224 * 0.06 / 2 = 6.72
    expect(
      leftRoom,
      greaterThanOrEqualTo(overflow),
      reason: '首卡选中向左放大 $overflow px 会重新被视口裁掉（封面左侧缺一块）',
    );

    // ── 右端：滚到最右，末卡的静止右缘同样要留出余量 ──
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: listFinder, matching: find.byType(Scrollable)),
    );
    // 🔴 必须**迭代收敛**：单次 jumpTo(maxScrollExtent) 实测会短 20px
    // （ListView 的 trailing padding 未计入首次 content-dimensions 估计），
    // 直接断言会拿到「末卡还没贴到右缘」的假结果。
    for (var i = 0; i < 5; i++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
    }
    expect(
      (scrollable.position.pixels - scrollable.position.maxScrollExtent).abs(),
      lessThan(0.5),
      reason: '没有滚到最大偏移，右端断言无意义',
    );

    final lastRect = tester.getRect(_shelfCards().last);
    final rightRoom = viewportRect.right - lastRect.right;
    expect(
      rightRoom,
      moreOrLessEquals(
        BigPictureTheme.shelfContentHorizontalPadding,
        epsilon: 0.5,
      ),
      reason: '末卡静止右缘应保持 shelfPageInset 的净内缩',
    );
    expect(
      rightRoom,
      greaterThanOrEqualTo(overflow),
      reason: '末卡选中向右放大 $overflow px 会重新被视口裁掉（封面右侧缺一块）',
    );
  });
}
