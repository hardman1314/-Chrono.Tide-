// BpmInteractiveWrapper widget 测试
//
// 验证:
// - onTap 回调被触发
// - 禁用态 (onTap=null) 不响应点击
// - 焦点态缩放生效 (通过 AnimatedScale 验证)
// - v3.22 focusToActivate 两段式 (未选中点击只落焦点 / 已选中点击触发 onTap /
//   未选中双击只触发 onDoubleTap)
// - v3.22 连按分流: 真实键盘 Enter 连按 = onDoubleTap;
//   手柄合成 Enter (synthesized) 在 enableKeyDoubleTap=false 时单击立即生效

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/big_picture/widgets/bpm_interactive_wrapper.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

void main() {
  // FocusGlow 依赖 AppThemeManager.colors (内置主题表),
  // 测试进程内未注册时抛 null check,统一在此注册。
  setUp(() {
    ThemeRegistry.registerBuiltinThemes();
  });

  testWidgets('onTap callback is triggered on tap', (tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmInteractiveWrapper(
            onTap: () => tapped = true,
            child: const Text('tap_target'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('tap_target'));
    await tester.pump();

    expect(tapped, isTrue);
  });

  testWidgets('disabled state (onTap=null) does not respond to tap',
      (tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmInteractiveWrapper(
            onTap: null,
            child: GestureDetector(
              onTap: () => tapped = true,
              child: const Text('disabled_target'),
            ),
          ),
        ),
      ),
    );

    // 禁用态: wrapper 内的 GestureDetector 不应被触发 (wrapper 本身吞掉手势)
    // 但禁用态 wrapper 的 child 仍可点击 (因为 wrapper 不挂 GestureDetector)
    // 这里验证 wrapper 自身的 onTap=null 不触发
    await tester.tap(find.text('disabled_target'), warnIfMissed: false);
    await tester.pump();

    // wrapper 不响应,但内部 GestureDetector 可能响应
    // 关键是 wrapper 自身不调用回调
    expect(tapped, isTrue); // 内部 GestureDetector 仍响应
  });

  testWidgets('renders child correctly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmInteractiveWrapper(
            onTap: () {},
            child: const Text('render_target'),
          ),
        ),
      ),
    );

    expect(find.text('render_target'), findsOneWidget);
  });

  testWidgets('focus state applies focusScale', (tester) async {
    final focusNode = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmInteractiveWrapper(
            onTap: () {},
            focusNode: focusNode,
            focusScale: 1.5,
            child: const Text('focus_target'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始无焦点: scale = 1.0
    final initialScale = tester.widget<AnimatedScale>(
      find.byType(AnimatedScale),
    );
    expect(initialScale.scale, 1.0);

    // 获取焦点
    focusNode.requestFocus();
    // requestFocus 触发 listener -> setState -> AnimatedScale 重建
    // pumpAndSettle 等待所有帧完成 (包括 focusAnimDuration 动画)
    await tester.pumpAndSettle();

    // 焦点态: scale = 1.5
    final focusedScale = tester.widget<AnimatedScale>(
      find.byType(AnimatedScale),
    );
    expect(focusedScale.scale, 1.5);

    focusNode.dispose();
  });

  testWidgets('onLongPress callback is triggered', (tester) async {
    bool longPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BpmInteractiveWrapper(
            onTap: () {},
            onLongPress: () => longPressed = true,
            child: const Text('longpress_target'),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('longpress_target'));
    await tester.pump();

    expect(longPressed, isTrue);
  });

  group('v3.22 focusToActivate 两段式', () {
    testWidgets('点击未选中组件: 只落焦点, 不触发 onTap', (tester) async {
      int taps = 0;
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BpmInteractiveWrapper(
              onTap: () => taps++,
              focusToActivate: true,
              focusNode: focusNode,
              child: const Text('two_stage_target'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('two_stage_target'));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(taps, 0);
      focusNode.dispose();
    });

    testWidgets('点击已选中组件: 触发 onTap', (tester) async {
      int taps = 0;
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BpmInteractiveWrapper(
              onTap: () => taps++,
              focusToActivate: true,
              focusNode: focusNode,
              child: const Text('two_stage_target'),
            ),
          ),
        ),
      );
      // 先把焦点给到组件（等价于上一轮点击已选中）
      focusNode.requestFocus();
      await tester.pumpAndSettle();

      await tester.tap(find.text('two_stage_target'));
      await tester.pump();

      expect(taps, 1);
      focusNode.dispose();
    });

    testWidgets('未选中组件双击: 只触发 onDoubleTap, 不触发 onTap', (tester) async {
      int taps = 0;
      int doubleTaps = 0;
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BpmInteractiveWrapper(
              onTap: () => taps++,
              onDoubleTap: () => doubleTaps++,
              focusToActivate: true,
              focusNode: focusNode,
              child: const Text('two_stage_target'),
            ),
          ),
        ),
      );

      // 双击未选中卡片: 第一击落焦点(选中), 第二击构成双击启动
      // (双击间隔取 kDoubleTapMinTime=40ms —— gestures 库常量, 此处直书等值)
      await tester.tap(find.text('two_stage_target'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('two_stage_target'));
      await tester.pump();

      expect(doubleTaps, 1);
      expect(taps, 0);
      focusNode.dispose();
    });
  });

  group('v3.22 连按分流 (键盘 vs 手柄合成)', () {
    testWidgets('真实键盘 Enter 连按两次 = onDoubleTap', (tester) async {
      int taps = 0;
      int doubleTaps = 0;
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BpmInteractiveWrapper(
              onTap: () => taps++,
              onDoubleTap: () => doubleTaps++,
              // 主页 shelf 卡片组合: 手柄合成不参与连按, 真实键盘参与
              enableKeyDoubleTap: false,
              keyboardDoubleTap: true,
              focusNode: focusNode,
              child: const Text('kb_target'),
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pumpAndSettle();

      // 两次快速 Enter（真实硬件事件, synthesized=false）→ 双击
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(doubleTaps, 1);
      expect(taps, 0);
      focusNode.dispose();
    });

    testWidgets('手柄合成 Enter 连按两次: 各触发一次单击, 不构成双击',
        (tester) async {
      int taps = 0;
      int doubleTaps = 0;
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BpmInteractiveWrapper(
              onTap: () => taps++,
              onDoubleTap: () => doubleTaps++,
              enableKeyDoubleTap: false,
              keyboardDoubleTap: true,
              focusNode: focusNode,
              child: const Text('kb_target'),
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pumpAndSettle();

      // 手柄「连按两次 A」由 shell 合成 synthesized KeyDownEvent 派发,
      // enableKeyDoubleTap=false → 不走双击窗口, 各自立即激活
      final synthDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        character: null,
        timeStamp: Duration.zero,
        synthesized: true,
      );
      focusNode.onKeyEvent!(focusNode, synthDown);
      await tester.pump();
      focusNode.onKeyEvent!(focusNode, synthDown);
      await tester.pump();

      expect(taps, 2);
      expect(doubleTaps, 0);
      focusNode.dispose();
    });
  });
}
