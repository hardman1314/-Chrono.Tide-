// BPM 分类匣面板回归测试
//
// 覆盖：三视图渲染、筛选回调（收藏夹/标签/会社）、行操作菜单入口、
// 关闭回调、收起态零交互。焦点/手柄分层（B 键、openPanel 状态机）
// 属 shell 集成路径，见 big_picture_shell（真机走查覆盖）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/widgets/bpm_category_box_panel.dart';
import 'package:chrono_tide/services/collection_service.dart';
import 'package:chrono_tide/widgets/library/category_box_sidebar.dart'
    show CategoryBoxCompany, CategoryBoxTag, CategoryBoxTagSection;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

BpmCategoryBoxPanel _panel({
  bool open = true,
  VoidCallback? onClose,
  ValueChanged<String?>? onEnterCollection,
  ValueChanged<String>? onToggleTag,
  ValueChanged<String>? onEnterCompany,
  Future<void> Function(CategoryBoxCompany)? onToggleFollow,
}) {
  return BpmCategoryBoxPanel(
    open: open,
    leadFocusNode: FocusNode(debugLabel: 'testLead'),
    collections: [
      GameCollection(id: 'c1', name: '准备入手', colorValue: 0xFF7EC8E3),
      GameCollection(
          id: 'c2', name: '通完的', colorValue: 0xFFF0C987, pinned: true),
    ],
    activeCollectionId: null,
    allGamesCount: 128,
    gameCountOf: (id) => id == 'c1' ? 23 : 9,
    onEnterCollection: onEnterCollection ?? (_) {},
    onCreateCollection: () {},
    onRenameCollection: (_) async {},
    onDeleteCollection: (_) async {},
    onTogglePinCollection: (_) async {},
    tagSections: [
      const CategoryBoxTagSection(title: '玩法结构', tags: [
        CategoryBoxTag(key: 'concept:k1', name: '拔作', count: 12),
        CategoryBoxTag(key: 'concept:k2', name: '共通线短', count: 3),
      ]),
      const CategoryBoxTagSection(title: '其他', tags: [
        CategoryBoxTag(key: 'tag:未分类标签', name: '未分类标签', count: 1),
      ]),
    ],
    activeTagKeys: const {'concept:k1'},
    onToggleTag: onToggleTag ?? (_) {},
    companies: [
      CategoryBoxCompany(
        key: 'devId:42',
        name: '柚子社',
        subName: 'Yuzusoft',
        logoText: 'Y',
        logoBg: const Color(0xFFE7EDE2),
        logoFg: const Color(0xFF7E9678),
        gameCount: 15,
        followed: false,
      ),
    ],
    activeSmartGroupKey: '',
    onEnterCompany: onEnterCompany ?? (_) {},
    onToggleFollowCompany: onToggleFollow ?? (_) async {},
    onClose: onClose ?? () {},
  );
}

void main() {
  testWidgets('展开态：三视图 tab + 收藏夹行 + 计数渲染', (tester) async {
    await tester.pumpWidget(_host(_panel()));
    await tester.pumpAndSettle();

    expect(find.text('收藏夹'), findsWidgets); // tab pill + 无行重名
    expect(find.text('标签库'), findsOneWidget);
    expect(find.text('会社墙'), findsOneWidget);
    expect(find.text('所有游戏'), findsOneWidget);
    expect(find.text('准备入手'), findsOneWidget);
    expect(find.text('通完的'), findsOneWidget);
    expect(find.text('新建收藏夹'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    // 预设/置顶收藏夹显示图钉；预设行（准备入手）无 ⋯ 操作入口
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });

  testWidgets('点收藏夹行 → onEnterCollection 收到对应 id', (tester) async {
    String? picked;
    await tester.pumpWidget(_host(_panel(
      onEnterCollection: (id) => picked = id,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('准备入手'));
    await tester.pumpAndSettle();
    expect(picked, 'c1');
  });

  testWidgets('点「所有游戏」→ onEnterCollection 收到 null', (tester) async {
    String? picked = 'x';
    await tester.pumpWidget(_host(_panel(
      onEnterCollection: (id) => picked = id,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('所有游戏'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('标签库视图：维度分区渲染 + 点 chip → onToggleTag', (tester) async {
    final toggled = <String>[];
    await tester.pumpWidget(_host(_panel(
      onToggleTag: (k) => toggled.add(k),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('标签库'));
    await tester.pumpAndSettle();

    expect(find.text('玩法结构'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
    expect(find.text('拔作 12'), findsOneWidget);
    expect(find.text('共通线短 3'), findsOneWidget);
    expect(find.text('未分类标签 1'), findsOneWidget);

    await tester.tap(find.text('拔作 12'));
    await tester.pumpAndSettle();
    expect(toggled, ['concept:k1']);
  });

  testWidgets('会社墙视图：行点击进入过滤 + 星标切换关注', (tester) async {
    final entered = <String>[];
    var followToggled = 0;
    await tester.pumpWidget(_host(_panel(
      onEnterCompany: (k) => entered.add(k),
      onToggleFollow: (_) async => followToggled++,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('会社墙'));
    await tester.pumpAndSettle();

    expect(find.text('柚子社'), findsOneWidget);
    expect(find.text('Yuzusoft'), findsOneWidget);
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);

    await tester.tap(find.text('柚子社'));
    await tester.pumpAndSettle();
    expect(entered, ['devId:42']);

    await tester.tap(find.byIcon(Icons.star_border_rounded));
    await tester.pumpAndSettle();
    expect(followToggled, 1);
  });

  testWidgets('关闭按钮 → onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(_host(_panel(onClose: () => closed = true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('收起态（open:false）不渲染内容且零异常', (tester) async {
    await tester.pumpWidget(_host(_panel(open: false)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('准备入手'), findsNothing);
    expect(find.text('所有游戏'), findsNothing);
  });
}
