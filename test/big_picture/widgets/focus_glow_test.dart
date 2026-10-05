// FocusGlow widget 测试
//
// 验证:
// - autofocus 获取焦点后显示边框 (通过焦点状态变化)
// - Enter 键触发 onSelect 回调
// - 无 onSelect 时 Enter 不触发
// - v3.10.2: 连按两次 Enter(≡ 手柄连按两次 A) 触发 onDoubleTap,
//   等价鼠标双击; 且**单击会被推迟到双击窗口结束**才落地 ——
//   与 GestureDetector 同时给 onTap + onDoubleTap 时的语义一致

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/big_picture/widgets/focus_glow.dart';

void main() {
  testWidgets('FocusGlow renders child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            child: Text('test_target'),
          ),
        ),
      ),
    );

    expect(find.text('test_target'), findsOneWidget);
  });

  testWidgets('autofocus=true acquires focus on build', (tester) async {
    final focusNode = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            autofocus: true,
            focusNode: focusNode,
            child: const Text('auto_target'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    focusNode.dispose();
  });

  testWidgets('Enter key triggers onSelect callback', (tester) async {
    final focusNode = FocusNode();
    bool selected = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected = true,
            child: const Text('enter_target'),
          ),
        ),
      ),
    );
    await tester.pump();

    // 获取焦点
    focusNode.requestFocus();
    await tester.pump();

    // 模拟 Enter 键按下
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(selected, isTrue);
    focusNode.dispose();
  });

  testWidgets('Space key triggers onSelect callback', (tester) async {
    final focusNode = FocusNode();
    bool selected = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected = true,
            child: const Text('space_target'),
          ),
        ),
      ),
    );
    await tester.pump();

    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(selected, isTrue);
    focusNode.dispose();
  });

  testWidgets('Enter key does not trigger when onSelect is null',
      (tester) async {
    final focusNode = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            child: const Text('no_select_target'),
          ),
        ),
      ),
    );
    await tester.pump();

    focusNode.requestFocus();
    await tester.pump();

    // 不应抛出异常
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // 仅验证无异常即可
    expect(focusNode.hasFocus, isTrue);
    focusNode.dispose();
  });

  // ============ v3.10.2: 双击 A(Enter) ≡ 鼠标双击 ============

  testWidgets('无 onDoubleTap 时单击**立即**触发 onSelect (零回归)', (tester) async {
    final focusNode = FocusNode();
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected++,
            child: const Text('single_target'),
          ),
        ),
      ),
    );
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // 不做任何等待, 立刻断言 —— 旧行为不允许被延迟
    expect(selected, 1, reason: '没有双击语义时必须保持零延迟');

    focusNode.unfocus();
    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });

  testWidgets('连按两次 Enter → onDoubleTap 触发, onSelect 不触发', (tester) async {
    final focusNode = FocusNode();
    var selected = 0;
    var doubled = 0;
    FocusGlow.clock = () => DateTime(2026, 9, 20, 12);
    addTearDown(() => FocusGlow.clock = DateTime.now);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected++,
            onDoubleTap: () => doubled++,
            child: const Text('double_target'),
          ),
        ),
      ),
    );
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(doubled, 1, reason: '窗口内第二次按下 = 鼠标双击语义');
    expect(selected, 0, reason: '被判为双击后, 单击不得再落地');

    // 双击窗口过去后也不该再冒出单击 (挂起的 Timer 已被取消)
    await tester.pump(FocusGlow.doubleTapWindow + const Duration(milliseconds: 50));
    expect(selected, 0);

    focusNode.unfocus();
    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });

  testWidgets('单击在双击窗口结束后落地为 onSelect', (tester) async {
    final focusNode = FocusNode();
    var selected = 0;
    var doubled = 0;
    FocusGlow.clock = () => DateTime(2026, 9, 20, 12);
    addTearDown(() => FocusGlow.clock = DateTime.now);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected++,
            onDoubleTap: () => doubled++,
            child: const Text('deferred_target'),
          ),
        ),
      ),
    );
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, 0, reason: '窗口内不得立即落地, 否则双击永远没机会');

    await tester.pump(FocusGlow.doubleTapWindow + const Duration(milliseconds: 50));
    expect(selected, 1);
    expect(doubled, 0);

    focusNode.unfocus();
    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });

  testWidgets('失焦丢弃挂起的单击 (防止打开上一张卡的详情)', (tester) async {
    final focusNode = FocusNode();
    var selected = 0;
    FocusGlow.clock = () => DateTime(2026, 9, 20, 12);
    addTearDown(() => FocusGlow.clock = DateTime.now);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusGlow(
            focusNode: focusNode,
            onSelect: () => selected++,
            onDoubleTap: () {},
            child: const Text('blur_target'),
          ),
        ),
      ),
    );
    await tester.pump();
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    focusNode.unfocus(); // 立刻移走焦点
    await tester.pump(FocusGlow.doubleTapWindow + const Duration(milliseconds: 50));
    expect(selected, 0, reason: '失焦后挂起的单击必须作废');

    await tester.pumpWidget(const SizedBox.shrink());
    focusNode.dispose();
  });
}
