import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/big_picture_theme.dart';
import 'package:chrono_tide/big_picture/focus/bpm_zone_focus_controller.dart';
import 'package:chrono_tide/big_picture/widgets/bpm_focus_domain.dart';
import 'package:chrono_tide/big_picture/widgets/bpm_focus_zone.dart';

/// BPM 板块高亮容器回归测试（规范第 6 条：板块模式高亮整个板块容器）
///
/// 覆盖三件事：
/// ① 只有「板块模式 + 板块匹配」才亮 —— 组件模式下不亮（避免双高亮）；
/// ② 不在 BPM 子树（无 scope）时**完全不介入**，保证既有调用点零影响；
/// ③ 高亮层不拦截命中测试 —— 「保留原有鼠标操作」的机械保证。
void main() {
  Finder highlight() => find.descendant(
        of: find.byType(BpmFocusZone),
        matching: find.byType(AnimatedContainer),
      );

  Color? borderColor(WidgetTester tester) {
    final containers = tester.widgetList<AnimatedContainer>(highlight());
    for (final c in containers) {
      final d = c.decoration;
      if (d is BoxDecoration && d.border is Border) {
        return (d.border! as Border).top.color;
      }
    }
    return null;
  }

  Future<void> pumpZone(
    WidgetTester tester,
    BpmZoneFocusController controller,
    BpmZoneId zone, {
    VoidCallback? onTap,
  }) {
    final child = onTap == null
        ? const SizedBox(width: 120, height: 60, child: Text('zone'))
        : GestureDetector(
            onTap: onTap,
            child: const SizedBox(width: 120, height: 60, child: Text('zone')),
          );
    return tester.pumpWidget(
      MaterialApp(
        home: BpmZoneFocusScope(
          controller: controller,
          child: Scaffold(
            body: Center(child: BpmFocusZone(zone: zone, child: child)),
          ),
        ),
      ),
    );
  }

  testWidgets('无 BpmZoneFocusScope 时直接返回 child, 不插入任何高亮层', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: BpmFocusZone(
              zone: BpmZoneId.homeShelf,
              child: SizedBox(width: 120, height: 60, child: Text('zone')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('zone'), findsOneWidget);
    expect(highlight(), findsNothing);
  });

  testWidgets('板块模式 + 板块匹配 → 樱粉高亮', (tester) async {
    final c = BpmZoneFocusController();
    c.enableFocusMode(); // v3.19: 焦点体系默认停用，测试手柄模式语义
    await pumpZone(tester, c, BpmZoneId.rail);
    expect(highlight(), findsOneWidget);
    expect(borderColor(tester), BpmColors.cherryRose);
  });

  testWidgets('板块模式 + 板块不匹配 → 透明 (其余板块不亮)', (tester) async {
    final c = BpmZoneFocusController();
    await pumpZone(tester, c, BpmZoneId.homeShelf);
    expect(highlight(), findsOneWidget);
    expect(borderColor(tester), Colors.transparent);
  });

  testWidgets('切板块后高亮跟随 (rail → topBar)', (tester) async {
    final c = BpmZoneFocusController();
    c.enableFocusMode(); // v3.19
    await pumpZone(tester, c, BpmZoneId.topBar);
    expect(borderColor(tester), Colors.transparent);

    c.moveZone(TraversalDirection.up); // rail → topBar
    await tester.pumpAndSettle();
    expect(c.zone, BpmZoneId.topBar);
    expect(borderColor(tester), BpmColors.cherryRose);
  });

  testWidgets('组件模式下板块高亮让位 (只高亮单个组件)', (tester) async {
    final c = BpmZoneFocusController();
    c.enableFocusMode(); // v3.19
    await pumpZone(tester, c, BpmZoneId.rail);
    expect(borderColor(tester), BpmColors.cherryRose);

    c.confirm(); // A: 进入板块 → 组件模式
    await tester.pumpAndSettle();
    expect(c.mode, BpmFocusMode.component);
    expect(borderColor(tester), Colors.transparent);
  });

  testWidgets('高亮层不拦截命中测试 (鼠标操作零影响)', (tester) async {
    var taps = 0;
    final c = BpmZoneFocusController();
    await pumpZone(tester, c, BpmZoneId.rail, onTap: () => taps++);
    await tester.pumpAndSettle();

    await tester.tap(find.text('zone'));
    await tester.pump();
    expect(taps, 1, reason: '高亮层是 IgnorePointer, 不得吃掉点击');
  });

  testWidgets('高亮层不影响子组件布局 (靠负 Positioned 外扩)', (tester) async {
    final c = BpmZoneFocusController();
    await pumpZone(tester, c, BpmZoneId.rail);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('zone')).height, 60);
    expect(tester.getSize(find.byType(BpmFocusZone)).height, 60);
  });

  testWidgets('BpmFocusDomain 挂载即注册焦点域, 卸载即注销', (tester) async {
    final c = BpmZoneFocusController();
    final node = FocusNode(debugLabel: 'probe');
    await tester.pumpWidget(
      MaterialApp(
        home: BpmZoneFocusScope(
          controller: c,
          child: BpmFocusDomain(
            zone: BpmZoneId.libraryWall,
            child: Focus(
              focusNode: node,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      ),
    );
    expect(c.domainOf(BpmZoneId.libraryWall), isNotNull);
    expect(c.zoneOfScope(node.nearestScope), BpmZoneId.libraryWall);
    expect(c.entryFocusOf(BpmZoneId.libraryWall), same(node));

    // 先卸载再释放节点, 避免「已挂载节点被 dispose」的断言
    await tester.pumpWidget(const SizedBox.shrink());
    expect(c.domainOf(BpmZoneId.libraryWall), isNull, reason: '卸载后应注销');
    node.dispose();
  });

  testWidgets('BpmZoneFocusScope.maybeZoneMode: 无 scope = null, 有 scope = 模式值',
      (tester) async {
    final c = BpmZoneFocusController();
    c.enableFocusMode(); // v3.19: 断言的是「手柄模式下的模式值」
    bool? outside;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            outside = BpmZoneFocusScope.maybeZoneMode(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(outside, isNull, reason: '非 BPM 子树不得被干预');

    BuildContext? insideCtx;
    await tester.pumpWidget(
      MaterialApp(
        home: BpmZoneFocusScope(
          controller: c,
          child: Builder(
            builder: (context) {
              insideCtx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final ctx = insideCtx!;
    expect(BpmZoneFocusScope.maybeZoneMode(ctx), isTrue);

    c.confirm(); // A → 组件模式
    await tester.pump();
    expect(BpmZoneFocusScope.maybeZoneMode(ctx), isFalse);
  });
}
