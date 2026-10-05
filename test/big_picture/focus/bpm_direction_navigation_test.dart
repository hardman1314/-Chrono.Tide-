import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/focus/bpm_zone_focus_controller.dart';
import 'package:chrono_tide/big_picture/widgets/bpm_focus_domain.dart';
import 'package:chrono_tide/big_picture/widgets/bpm_interactive_wrapper.dart';

/// BPM 手柄方向导航回归测试（2026-09-20 v3.10.1）
///
/// 🔴 这个文件锁死的是两个**真机 BUG 的根因**：
///
/// 1. `FocusTraversalPolicy.findFirstFocusInDirection` 在 Flutter 3.24.3 里
///    **完全不做方向过滤** —— 它把整个 scope 的可聚焦节点按前缘排序后取第一个。
///    实测：从左侧栏节点按「下」得到的是**屏幕最上方**那个节点（→ 永远选不中
///    「我的库」）；按「右」得到的是**最左边**那个节点（→ 主页卡片列表左右键
///    换不了游戏）。正解是 `inDirection`（几何筛选 + 空候选即边缘停）。
/// 2. `inDirection` 只认 `currentNode.nearestScope` —— 所以「板块内移动、
///    边界停、不跨板块」必须靠**每个板块一个 FocusScope** 才能成立。
///
/// 下面每个用例都直接走 shell 的方向键代码路径（取 primaryFocus 的
/// `nearestScope` 所属策略 → `inDirection`），因此任何一处回退都会失败。
void main() {
  late BpmZoneFocusController controller;
  late Map<String, FocusNode> n;

  FocusNode node(String name) => n[name]!;

  Widget item(String name) => BpmInteractiveWrapper(
        onTap: () {},
        focusNode: node(name),
        semanticsLabel: name,
        child: SizedBox(
          width: 80,
          height: 44,
          child: Center(child: Text(name)),
        ),
      );

  Future<void> pumpBoard(WidgetTester tester) async {
    controller = BpmZoneFocusController();
    n = <String, FocusNode>{
      for (final name in <String>[
        'top1', 'top2',
        'rail0', 'rail1', 'rail2',
        'tool0', 'tool1', 'tool2',
        'wall00', 'wall01', 'wall10', 'wall11',
      ])
        name: FocusNode(debugLabel: name),
    };

    await tester.pumpWidget(
      MaterialApp(
        home: BpmZoneFocusScope(
          controller: controller,
          child: Scaffold(
            body: Column(
              children: <Widget>[
                // 一级：顶部状态栏
                SizedBox(
                  height: 44,
                  child: BpmFocusDomain(
                    zone: BpmZoneId.topBar,
                    child: Row(children: <Widget>[item('top1'), item('top2')]),
                  ),
                ),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      // 一级：左侧导航栏
                      SizedBox(
                        width: 120,
                        child: BpmFocusDomain(
                          zone: BpmZoneId.rail,
                          child: Column(
                            children: <Widget>[
                              item('rail0'),
                              item('rail1'),
                              item('rail2'),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: BpmFocusDomain(
                          zone: BpmZoneId.stage,
                          child: Column(
                            children: <Widget>[
                              // 二级：顶部筛选操作板块
                              SizedBox(
                                height: 44,
                                child: BpmFocusDomain(
                                  zone: BpmZoneId.libraryTools,
                                  child: Row(
                                    children: <Widget>[
                                      item('tool0'),
                                      item('tool1'),
                                      item('tool2'),
                                    ],
                                  ),
                                ),
                              ),
                              // 二级：游戏卡片列表板块（2×2 网格）
                              Expanded(
                                child: BpmFocusDomain(
                                  zone: BpmZoneId.libraryWall,
                                  child: Column(
                                    children: <Widget>[
                                      Row(
                                        children: <Widget>[
                                          item('wall00'),
                                          item('wall01'),
                                        ],
                                      ),
                                      Row(
                                        children: <Widget>[
                                          item('wall10'),
                                          item('wall11'),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 走 shell 的方向键代码路径
  void press(TraversalDirection dir) {
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull, reason: '当前没有焦点, 无法测方向');
    final context = focus!.context;
    final policy = context == null
        ? ReadingOrderTraversalPolicy()
        : (FocusTraversalGroup.maybeOf(context) ?? ReadingOrderTraversalPolicy());
    policy.inDirection(focus, dir);
  }

  /// 断言焦点停在某个节点上
  void expectFocus(String name) {
    expect(FocusManager.instance.primaryFocus, same(node(name)));
  }

  setUp(() {
    n = <String, FocusNode>{};
  });

  tearDown(() {
    for (final value in n.values) {
      value.dispose();
    }
    n = <String, FocusNode>{};
  });

  group('侧栏（一级 rail）—— 真机「选不中我的库」的根因', () {
    testWidgets('↓ 从第 1 项移动到第 2 项（旧实现会跳到屏幕最上方的顶部栏）', (tester) async {
      await pumpBoard(tester);
      node('rail0').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.down);
      await tester.pumpAndSettle();

      expectFocus('rail1');
    });

    testWidgets('↓ 依次走到第 3 项', (tester) async {
      await pumpBoard(tester);
      node('rail0').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.down);
      await tester.pumpAndSettle();
      press(TraversalDirection.down);
      await tester.pumpAndSettle();

      expectFocus('rail2');
    });

    testWidgets('末项再 ↓ 不动（板块边界停，不跨级）', (tester) async {
      await pumpBoard(tester);
      node('rail2').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.down);
      await tester.pumpAndSettle();

      expectFocus('rail2');
    });

    testWidgets('↑ 回到上一项', (tester) async {
      await pumpBoard(tester);
      node('rail2').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.up);
      await tester.pumpAndSettle();

      expectFocus('rail1');
    });

    testWidgets('→ 不离开侧栏（组件模式不跨板块；旧实现会跳到顶部栏）', (tester) async {
      await pumpBoard(tester);
      node('rail0').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();

      expectFocus('rail0');
    });
  });

  group('顶部状态栏（一级 topBar）', () {
    testWidgets('→ 在栏内移动', (tester) async {
      await pumpBoard(tester);
      node('top1').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();

      expectFocus('top2');
    });

    testWidgets('末项 → 不动；↓ 不跳到别的板块', (tester) async {
      await pumpBoard(tester);
      node('top2').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();
      expectFocus('top2');

      press(TraversalDirection.down);
      await tester.pumpAndSettle();
      expectFocus('top2');
    });
  });

  group('库页顶部筛选操作板块（二级 libraryTools）', () {
    testWidgets('←/→ 在栏内移动', (tester) async {
      await pumpBoard(tester);
      node('tool0').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();
      expectFocus('tool1');

      press(TraversalDirection.right);
      await tester.pumpAndSettle();
      expectFocus('tool2');

      press(TraversalDirection.left);
      await tester.pumpAndSettle();
      expectFocus('tool1');
    });

    testWidgets('↓ 不跨到海报墙（规范第 4 条：须先 B 退出组件模式）', (tester) async {
      await pumpBoard(tester);
      node('tool1').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.down);
      await tester.pumpAndSettle();

      expectFocus('tool1');
    });
  });

  group('库页海报墙（二级 libraryWall）—— 真机「换不了游戏」的根因', () {
    testWidgets('→ 在行内换卡（旧实现会跳到侧栏）', (tester) async {
      await pumpBoard(tester);
      node('wall00').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();

      expectFocus('wall01');
    });

    testWidgets('→ 到行尾停住（边缘停，不回绕）', (tester) async {
      await pumpBoard(tester);
      node('wall01').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.right);
      await tester.pumpAndSettle();

      expectFocus('wall01');
    });

    testWidgets('↓ 换到下一行，底行 ↓ 停住', (tester) async {
      await pumpBoard(tester);
      node('wall00').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.down);
      await tester.pumpAndSettle();
      expectFocus('wall10');

      press(TraversalDirection.down);
      await tester.pumpAndSettle();
      expectFocus('wall10');
    });

    testWidgets('↑ 从首行不跳到顶部筛选板块（不跨板块）', (tester) async {
      await pumpBoard(tester);
      node('wall00').requestFocus();
      await tester.pumpAndSettle();

      press(TraversalDirection.up);
      await tester.pumpAndSettle();

      expectFocus('wall00');
    });
  });

  group('焦点域注册与进入落点', () {
    testWidgets('按 nearestScope 反查所属板块', (tester) async {
      await pumpBoard(tester);
      node('rail1').requestFocus();
      await tester.pumpAndSettle();
      expect(
        controller.zoneOfScope(node('rail1').nearestScope),
        BpmZoneId.rail,
      );

      node('wall11').requestFocus();
      await tester.pumpAndSettle();
      expect(
        controller.zoneOfScope(node('wall11').nearestScope),
        BpmZoneId.libraryWall,
      );
    });

    testWidgets('focusEntryOf 落在域内第一个组件', (tester) async {
      await pumpBoard(tester);
      // 先让域内组件全部挂载（requestFocus 前需要元素已布局）
      expect(controller.focusEntryOf(BpmZoneId.libraryTools), isTrue);
      await tester.pumpAndSettle();
      expectFocus('tool0');
    });

    testWidgets('再次进入同一板块落回「上次落焦的组件」（位置记忆）', (tester) async {
      await pumpBoard(tester);

      node('tool2').requestFocus();
      await tester.pumpAndSettle();
      node('rail0').requestFocus();
      await tester.pumpAndSettle();

      expect(controller.focusEntryOf(BpmZoneId.libraryTools), isTrue);
      await tester.pumpAndSettle();
      expectFocus('tool2');
    });

    testWidgets('域未挂载时 focusEntryOf 返回 false（不抛异常）', (tester) async {
      final bare = BpmZoneFocusController();
      expect(bare.focusEntryOf(BpmZoneId.homeShelf), isFalse);
      expect(bare.entryFocusOf(BpmZoneId.rail), isNull);
    });
  });
}
