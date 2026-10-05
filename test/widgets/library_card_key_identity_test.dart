// 卡片 key 策略对 State 归属的影响 · Phase 0 技术验证
//
// ## 为什么需要这个测试
//
// 库页的卡片拖拽/悬停态依赖 State（`library_page.dart` 的卡片子树），
// 而卡片 GlobalKey 是**按位置**分配的（`_cardKeys[index]`，`_syncCardKeys` 只做
// 长度增删）。当显示集合变化（筛选切换、导入新游、重排）时，同一位置的 key
// 会落到**另一个游戏**上——Flutter 因 key 相同而复用同一个 Element/State，
// State 里与"哪个游戏"绑定的东西（悬停动画、封面解码态、NSFW 判定放行标志）
// 就跟着串台。2026-09-08 修过的"悬停放大后封面重新模糊"是同一族问题的表现。
//
// 本测试用最小 widget 复刻两种 key 写法，**在动 Phase 4 之前先证实机制**：
// - 位置型 GlobalKey → State 跟随位置，必然串台；
// - 身份型 key → State 始终跟随游戏，稳定。
//
// 若这两个断言有一天不成立（例如 Flutter 改了 key 复用语义），
// Phase 4 的整改动因就需要重新评估——这正是把它放在 Phase 0 的意义。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 探针卡片：State 在首帧记录"我是为哪个游戏创建的"
class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.tag});

  final String tag;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  /// 首帧绑定（等价于真实的悬停动画控制器 / 封面解码态 / 检测放行标志）
  ///
  /// ⚠️ 必须在 initState 里立即取值：写成 `late final String initTag = widget.tag;`
  /// 会变成**惰性求值**，首次访问时才读 `widget.tag`，于是永远等于当前值，
  /// 断言退化为恒真（本测试初版就踩了这个坑）。
  late String initTag;

  @override
  void initState() {
    super.initState();
    initTag = widget.tag;
  }

  @override
  Widget build(BuildContext context) => Text(widget.tag);
}

Future<void> _pumpTags(
  WidgetTester tester,
  List<String> tags,
  Key? Function(String tag, int index) keyOf,
) {
  return tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          for (var i = 0; i < tags.length; i++)
            _Probe(key: keyOf(tags[i], i), tag: tags[i]),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('位置型 GlobalKey：显示集合变化后 State 跟随位置，绑到了另一个游戏',
      (tester) async {
    final indexKeys = [GlobalKey(), GlobalKey()];

    await _pumpTags(tester, ['A', 'B'], (_, i) => indexKeys[i]);
    // 模拟"同一个网格，显示列表被重排 / 头一项被换成了别的游戏"
    await _pumpTags(tester, ['B', 'A'], (_, i) => indexKeys[i]);

    final states = tester.stateList<_ProbeState>(find.byType(_Probe)).toList();
    expect(states.length, 2);

    // 断言：存在 State 的首帧绑定与其当前承载的游戏不一致 → 复用串台
    expect(
      states.any((s) => s.initTag != s.widget.tag),
      isTrue,
      reason: '位置型 key 下 State 会跟随位置而非游戏（这正是 Phase 4 要消除的）',
    );
  });

  testWidgets('身份型 key：State 始终跟随游戏，集合变化不串台', (tester) async {
    final identityKeys = <String, GlobalKey>{
      'A': GlobalKey(),
      'B': GlobalKey(),
    };

    await _pumpTags(tester, ['A', 'B'], (tag, _) => identityKeys[tag]);
    await _pumpTags(tester, ['B', 'A'], (tag, _) => identityKeys[tag]);

    final states = tester.stateList<_ProbeState>(find.byType(_Probe)).toList();
    expect(states.length, 2);
    for (final s in states) {
      expect(s.initTag, s.widget.tag,
          reason: '身份型 key 下 State 必须始终与其游戏一致');
    }
  });

  testWidgets('身份型 key：新增/移除成员时既有游戏的 State 不被顶替', (tester) async {
    final identityKeys = <String, GlobalKey>{
      'A': GlobalKey(),
      'B': GlobalKey(),
      'C': GlobalKey(),
    };

    await _pumpTags(tester, ['A', 'B'], (tag, _) => identityKeys[tag]);
    final beforeA = tester.state<_ProbeState>(find.byWidgetPredicate(
      (w) => w is _Probe && w.tag == 'A',
    ));

    // 模拟导入新游 / 筛选变化：B 被移除、C 加在最前
    await _pumpTags(tester, ['C', 'A'], (tag, _) => identityKeys[tag]);
    final afterA = tester.state<_ProbeState>(find.byWidgetPredicate(
      (w) => w is _Probe && w.tag == 'A',
    ));

    expect(identical(beforeA, afterA), isTrue,
        reason: 'A 的 State 应被原样复用，而不是被 C 顶替');
    expect(afterA.initTag, 'A');
  });
}
