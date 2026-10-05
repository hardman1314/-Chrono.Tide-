// 桌面分类匣侧栏 · 标签库内联编辑回归测试
//
// 背景（2026-10-04）：真机反馈「点击编辑标签后面板整块变灰、不可操作」。
// 根因 = `_buildTagSection` 里 `body` 变量被重新赋值为 DragTarget 后，
// DragTarget.builder 闭包引用了该变量（Dart 闭包捕获变量引用而非值）→
// builder 产物自包含 DragTarget → 挂载时无限递归 → 栈溢出/release 灰屏。
// 修复 = builder 引用快照 `sectionBody`。本测试锁死该回归：
// 进入编辑模式必须零异常且分区/chip/隐藏项完整渲染。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/collection_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/library/category_box_sidebar.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

CategoryBoxSidebar _sidebar({List<CategoryBoxTagSection>? sections}) {
  return CategoryBoxSidebar(
    open: true,
    onClose: () {},
    collections: [
      GameCollection(id: 'c1', name: '准备入手', colorValue: 0xFF7EC8E3),
    ],
    activeCollectionId: '',
    gameCountOf: (_) => 3,
    itemKeys: const <String, GlobalKey>{},
    dropTargetId: ValueNotifier<String?>(null),
    onEnterCollection: (_) {},
    onCreate: () {},
    onEdit: (_) {},
    tagSections: sections ??
        [
          CategoryBoxTagSection(
            title: '玩法结构',
            dimId: 'gameplay',
            tags: const [
              CategoryBoxTag(
                  key: 'concept:k1', name: '拔作', count: 12, isConcept: true),
              CategoryBoxTag(
                  key: 'concept:k2',
                  name: '共通线短',
                  count: 3,
                  hidden: true,
                  isConcept: true),
            ],
          ),
          CategoryBoxTagSection(
            title: '其他',
            dimId: '',
            tags: const [
              CategoryBoxTag(key: 'tag:原始标签', name: '原始标签', count: 1),
            ],
          ),
        ],
    onToggleTag: (_) {},
    onRenameTag: (_, __) {},
    onRemoveTag: (_, __) {},
    onToggleHideTag: (_, __) {},
    onMoveTagToDim: (_, __) {},
    onRenameDimension: (_, __) {},
    onAddDimension: (_) {},
    companies: const [
      CategoryBoxCompany(
        key: 'devId:42',
        name: '柚子社',
        subName: 'Yuzusoft',
        logoText: 'Y',
        logoBg: Color(0xFFE7EDE2),
        logoFg: Color(0xFF7E9678),
        gameCount: 15,
        followed: false,
      ),
    ],
    onEnterCompany: (_) {},
    onToggleFollowCompany: (_) {},
    onAddCompany: () {},
    onEditCompany: (_) {},
    smartItemKeys: <String, GlobalKey>{},
    smartDropTargetId: ValueNotifier<String?>(null),
  );
}

Future<void> _gotoTagsEditMode(
  WidgetTester tester, {
  List<CategoryBoxTagSection>? sections,
}) async {
  await tester.pumpWidget(_host(_sidebar(sections: sections)));
  await tester.pumpAndSettle();

  // 头部切换触发按钮 → 下拉 → 标签库
  await tester.tap(find.text('收藏夹').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('标签库').last);
  await tester.pumpAndSettle();

  // 底栏「编辑标签」→ 内联编辑模式
  await tester.tap(find.text('编辑标签'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题时抛 null check
    ThemeRegistry.registerBuiltinThemes();
  });

  testWidgets('进入标签编辑模式：零异常 + 分区/chip/隐藏项完整渲染', (tester) async {
    await _gotoTagsEditMode(tester);

    expect(tester.takeException(), isNull);
    // 编辑模式下隐藏标签也要可见（斜眼可恢复）
    expect(find.text('拔作'), findsOneWidget);
    expect(find.text('共通线短'), findsOneWidget);
    expect(find.text('原始标签'), findsOneWidget);
    // 维度标题 + 新增维度入口 + 完成编辑
    expect(find.text('玩法结构'), findsOneWidget);
    expect(find.text('新增维度'), findsOneWidget);
    expect(find.text('完成编辑'), findsOneWidget);
  });

  testWidgets('单维度分区 + 编辑模式（闭包自引用回归最小集）', (tester) async {
    await _gotoTagsEditMode(
      tester,
      sections: [
        CategoryBoxTagSection(
          title: '玩法结构',
          dimId: 'gameplay',
          tags: const [
            CategoryBoxTag(
                key: 'concept:k1', name: '拔作', count: 12, isConcept: true),
          ],
        ),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('拔作'), findsOneWidget);
    expect(find.text('玩法结构'), findsOneWidget);
  });

  testWidgets('会社墙：原版两段式卡片渲染（名称/副名/作品数/关注）零异常', (tester) async {
    await tester.pumpWidget(_host(_sidebar()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('收藏夹').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('会社墙').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('柚子社'), findsOneWidget);
    expect(find.text('Yuzusoft'), findsOneWidget);
    expect(find.text('15 部作品'), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);
    // 无图标 → 衬线字标回退
    expect(find.text('Y'), findsOneWidget);
  });

  testWidgets('编辑模式：点 chip 弹管理菜单不抛异常', (tester) async {
    await _gotoTagsEditMode(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('拔作'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('重命名（写穿全部游戏）'), findsOneWidget);
  });

  testWidgets('编辑模式：新增维度输入行出现不抛异常', (tester) async {
    await _gotoTagsEditMode(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('新增维度'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('维度名称，回车确认'), findsOneWidget);
  });
}
