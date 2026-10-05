import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/widgets/game_data_dialog.dart';
import 'package:chrono_tide/widgets/save_backup_panel.dart';

/// Phase 2 布局/结构回归（方案 §11.1 #12：窄窗口 960×540 不得溢出）。
///
/// ⚠️ 这些用例**不在 AI 开发环境运行**（本机 Dart 匿名管道受限，
/// `CreateFile failed 231`），由开发者在正常终端执行：
///   `flutter\bin\flutter.bat test test/widgets/game_data_dialog_test.dart`
///
/// 覆盖点：
/// 1. 最小窗口（960×540，`main.dart:490` 的 `minimumSize`）下 `GameDataDialog`
///    随可用空间收缩、**不抛布局溢出**。这是本项目已知的高频坑（右栏窄宽 + 浮层）。
/// 2. 标准窗口 1280×720 下同样不溢出。
/// 3. `SaveBackupPanel` 从 `SaveBackupDialog` 抽出后，三张子 Tab 仍在。
///
/// 说明：`LocalGameRegistry` 为空 ⇒ 弹窗走「未找到库记录」分支，**不触磁盘**，
/// 因此本文件是纯 UI 冒烟 + 溢出哨兵，不依赖真实游戏目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpGameDataDialog(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GameDataDialog(gameName: '测试游戏', installDir: r'D:\NotExist'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('窄窗口 960×540：GameDataDialog 不溢出且两个 Tab 都在',
      (WidgetTester tester) async {
    await pumpGameDataDialog(tester, const Size(960, 540));

    expect(tester.takeException(), isNull, reason: '窄窗口下不得抛布局溢出');
    expect(find.text('游戏数据 — 测试游戏'), findsOneWidget, reason: '标题栏');
    // 两个顶层 Tab（标题栏是「游戏数据 — 测试游戏」，与本处精确匹配不同串）
    expect(find.text('游戏数据'), findsOneWidget);
    expect(find.text('存档备份'), findsOneWidget);
  });

  testWidgets('标准窗口 1280×720：GameDataDialog 不溢出', (WidgetTester tester) async {
    await pumpGameDataDialog(tester, const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SaveBackupPanel 抽取后三张子 Tab 完整', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              height: 584, // 原 SaveBackupDialog 640 - 标题栏 56
              child: SaveBackupPanel(
                gameName: '测试游戏',
                installDir: r'D:\NotExist',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(tester.takeException(), isNull);
    expect(find.text('存档扫描'), findsOneWidget);
    expect(find.text('备份列表'), findsOneWidget);
    expect(find.text('存档路径'), findsOneWidget);
  });
}
