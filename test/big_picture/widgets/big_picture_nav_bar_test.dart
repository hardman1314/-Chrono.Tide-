// BigPictureNavBar widget 测试 (v3.2 方形圆角纯图标 rail)
//
// 验证:
// - 4 个 rail 按钮 (主页/我的库/添加游戏/退出) 语义标签正确渲染
// - 按钮内不放文字 (纯图标设计) — 任何位置均无导航文案 Text
// - 不再提供探索页入口 (大屏模式为纯本地模式)
// - 点击导航项触发 onPageChanged 回调 (int: 0=主页 1=我的库)
// - 点击添加游戏/退出触发对应回调

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/big_picture/widgets/big_picture_nav_bar.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

void main() {
  // BpmInteractiveWrapper -> FocusGlow 会读 AppThemeManager.colors,
  // 未注册内置主题时 _themes 为空会抛 null check 异常,故先注册。
  setUp(() {
    ThemeRegistry.registerBuiltinThemes();
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    int currentPage = 0,
    ValueChanged<int>? onPageChanged,
    VoidCallback? onAddGame,
    VoidCallback? onExitBpm,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BigPictureNavBar(
            currentPage: currentPage,
            onPageChanged: onPageChanged ?? (_) {},
            onAddGame: onAddGame,
            onExitBpm: onExitBpm,
          ),
        ),
      ),
    );
  }

  testWidgets('renders 4 rail buttons by semantics label', (tester) async {
    await pumpBar(tester);

    // 语义标签 (纯图标按钮的可访问性入口)
    expect(find.bySemanticsLabel('主页'), findsOneWidget);
    expect(find.bySemanticsLabel('我的库'), findsOneWidget);
    expect(find.bySemanticsLabel('添加游戏'), findsOneWidget);
    expect(find.bySemanticsLabel('退出大屏模式'), findsOneWidget);
    // 探索页已移除
    expect(find.bySemanticsLabel('探索'), findsNothing);
  });

  testWidgets('buttons contain no text labels (icon only)', (tester) async {
    await pumpBar(tester);

    // v3.2: 方形圆角纯图标设计 — rail 内不渲染导航文字
    expect(find.text('主页'), findsNothing);
    expect(find.text('我的库'), findsNothing);
    expect(find.text('添加游戏'), findsNothing);
    expect(find.text('退出'), findsNothing);
  });

  testWidgets('onPageChanged triggered on library button tap',
      (tester) async {
    int? tapped;
    await pumpBar(tester, onPageChanged: (page) => tapped = page);

    await tester.tap(find.bySemanticsLabel('我的库'));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('onAddGame triggered on add button tap', (tester) async {
    bool addTapped = false;
    await pumpBar(tester, onAddGame: () => addTapped = true);

    await tester.tap(find.bySemanticsLabel('添加游戏'));
    await tester.pump();

    expect(addTapped, isTrue);
  });

  testWidgets('exit button triggers onExitBpm', (tester) async {
    bool exited = false;
    await pumpBar(tester, onExitBpm: () => exited = true);

    await tester.tap(find.bySemanticsLabel('退出大屏模式'));
    await tester.pump();

    expect(exited, isTrue);
  });
}
