// 导入链路批 2 修复回归测试（IMP-04 / IMP-05 / IMP-09 / IMP-10 / IMP-11）
//
// 对应 docs/DEV/tickets/2026-09-12-import-audit-summary.md 的批 2：
//   IMP-04  单文件解压"同名重复导入写入旧目录" → 目标目录定位改为
//           "解压器回传优先 + 兜底取修改时间最新"（pickLatestExistingDir）
//   IMP-05  元数据目录与用户源目录重叠 → 禁止重命名用户目录、禁止覆盖其中的封面
//   IMP-09  处理队列运行中禁止提交批量入库（ActionButtons.submitEnabled）
//   IMP-10  压缩包白名单统一（.iso/.xz 等不再"被接受却提交失败"）
//   IMP-11  批量入库互斥（并发调用只处理一次）
//
// 路径隔离：PathHelper.exeDirOverride 必须在任何路径 getter 首次解析前设置；
// "应用外目录"不能放在系统临时目录（isInsideAppStorage 白名单含 systemTemp），
// 因此挂在项目内已 gitignore 的 .dart_tool/ 下。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/pages/join/join_controller.dart';
import 'package:chrono_tide/pages/join/widgets/action_buttons.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/services/watch_folder_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

void main() {
  late Directory appRoot;
  late Directory appGames;
  late Directory outsideRoot;

  setUp(() {
    // AppColors 底层读 AppThemeManager.colors；未注册内置主题时 _themes 为空会抛
    // null check 异常（与 explore_hall / big_picture 测试同款处理）
    ThemeRegistry.registerBuiltinThemes();
  });

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_b2_app_');
    appGames = Directory(p.join(appRoot.path, 'Games'))
      ..createSync(recursive: true);
    PathHelper.exeDirOverride = appRoot.path;

    outsideRoot = Directory(p.join('.dart_tool', 'ct_b2_outside'));
    if (!outsideRoot.existsSync()) outsideRoot.createSync(recursive: true);
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    for (final d in [appRoot, outsideRoot]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('IMP-04 解压目标目录定位（不猜测）', () {
    test('优先采用"成功回调瞬间捕获"的目录', () {
      final captured = Directory(p.join(appGames.path, 'Cap'))..createSync();
      final reported = Directory(p.join(appGames.path, 'Rep'))..createSync();

      expect(
        JoinController.resolveExtractionTargetDir(
          capturedDir: captured.path,
          reportedDir: reported.path,
        ),
        captured.path,
      );
    });

    test('捕获目录缺失/不存在时退回解压器回传目录', () {
      final reported = Directory(p.join(appGames.path, 'Rep2'))..createSync();

      expect(
        JoinController.resolveExtractionTargetDir(
          capturedDir: null,
          reportedDir: reported.path,
        ),
        reported.path,
      );
      expect(
        JoinController.resolveExtractionTargetDir(
          capturedDir: p.join(appGames.path, 'NotExist'),
          reportedDir: reported.path,
        ),
        reported.path,
      );
    });

    test('两个来源都不可用时返回 null（宁可不写，也不写错目录）', () {
      expect(
        JoinController.resolveExtractionTargetDir(
          capturedDir: null,
          reportedDir: null,
        ),
        isNull,
      );
      expect(
        JoinController.resolveExtractionTargetDir(
          capturedDir: p.join(appGames.path, 'Gone1'),
          reportedDir: p.join(appGames.path, 'Gone2'),
        ),
        isNull,
        reason: '★ 旧实现在同名副本之间猜目录，会把元数据覆盖到上一次导入的游戏上',
      );
    });
  });

  group('IMP-05 元数据目录与源目录重叠时的护栏', () {
    test('元数据目录落在本体目录内时，改标题不重命名目录（不移动用户文件夹）', () async {
      // 构造"冲突"：本体目录 == 元数据目录（本地导入同名重叠的形态）
      final collide = Directory(p.join(appGames.path, 'IMP05_X'))
        ..createSync(recursive: true);
      File(p.join(collide.path, 'game.exe')).writeAsBytesSync([0]);

      final reg = LocalGameRegistry.instance;
      reg.registerExtractionComplete(
        gameTitle: 'IMP05_X',
        directoryPath: collide.path,
        tags: const [],
        launchPath: 'game.exe',
      );

      await reg.updateGameTitle('IMP05_X', 'IMP05_Y');

      expect(collide.existsSync(), isTrue,
          reason: '★ 用户的游戏文件夹必须原地保留（旧实现会 rename 成新标题）');
      expect(
        Directory(p.join(appGames.path, 'IMP05_Y')).existsSync(),
        isFalse,
        reason: '不得产生"改名后的用户文件夹"',
      );
    });

    test('元数据目录与本体目录不重叠时，改标题仍照常重命名（行为不回退）', () async {
      final metaDir = Directory(p.join(appGames.path, 'IMP05_Z'))
        ..createSync(recursive: true);
      File(p.join(metaDir.path, 'game.json')).writeAsStringSync('{}');
      final body = Directory(p.join(appGames.path, 'IMP05_Z_BODY'))
        ..createSync(recursive: true);

      final reg = LocalGameRegistry.instance;
      reg.registerExtractionComplete(
        gameTitle: 'IMP05_Z',
        directoryPath: body.path,
        tags: const [],
      );

      await reg.updateGameTitle('IMP05_Z', 'IMP05_W');

      expect(Directory(p.join(appGames.path, 'IMP05_W')).existsSync(), isTrue,
          reason: '非冲突场景必须保留原有的目录重命名能力');
      expect(metaDir.existsSync(), isFalse);
    });

    test('应用目录之外的既有封面不被覆盖（源目录内的 cover.png 受保护）', () async {
      final userGame = Directory(p.join(outsideRoot.path, 'CoverGuard'))
        ..createSync(recursive: true);
      final userCover = File(p.join(userGame.path, 'cover.png'))
        ..writeAsStringSync('USER_ORIGINAL');

      final srcCover = File(p.join(appRoot.path, 'new_cover.png'))
        ..writeAsBytesSync([9, 9, 9, 9]);

      await GameDataFormat.writeGameDir(
        targetDir: userGame.path,
        title: 'CoverGuard',
        coverFilePath: srcCover.path,
      );

      expect(userCover.readAsStringSync(), 'USER_ORIGINAL',
          reason: '★ 应用目录之外的既有封面属于用户文件，不得覆盖');
    });

    test('应用目录内的封面照常写入（行为不回退）', () async {
      final metaDir = Directory(p.join(appGames.path, 'CoverInside'))
        ..createSync(recursive: true);
      final oldCover = File(p.join(metaDir.path, 'cover.png'))
        ..writeAsStringSync('OLD');
      final srcCover = File(p.join(appRoot.path, 'new_cover2.png'))
        ..writeAsBytesSync([7, 7]);

      await GameDataFormat.writeGameDir(
        targetDir: metaDir.path,
        title: 'CoverInside',
        coverFilePath: srcCover.path,
      );

      expect(oldCover.readAsStringSync(), isNot('OLD'));
      expect(oldCover.lengthSync(), 2);
    });
  });

  group('IMP-10 压缩包白名单一致性', () {
    test('.iso 等格式：isArchiveExt 与 isArchiveType 判定一致', () {
      final controller = JoinController();
      try {
        final iso = File(p.join(appRoot.path, 'probe.iso'))
          ..writeAsBytesSync([0]);
        controller.handleFileSelected(iso.path);
        expect(controller.isArchiveExt(iso.path), isTrue);
        expect(controller.isArchiveType, isTrue,
            reason: '★ 旧实现 isArchiveType 只认 5 种 → .iso 会被接受却在提交时报"不支持"');

        final txt = File(p.join(appRoot.path, 'probe.txt'))
          ..writeAsStringSync('x');
        controller.handleFileSelected(txt.path);
        expect(controller.isArchiveType, isFalse);

        final dir = Directory(p.join(appRoot.path, 'probeDir'))..createSync();
        controller.handleFileSelected(dir.path);
        expect(controller.isArchiveType, isFalse);
      } finally {
        controller.dispose();
      }
    });
  });

  group('IMP-09 批量提交按钮可用性', () {
    testWidgets('submitEnabled=false 时点击不触发提交', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ActionButtons(
            onBatchSubmit: () => tapped++,
            submitEnabled: false,
          ),
        ),
      ));

      await tester.tap(find.text('批量入库'));
      await tester.pump();
      expect(tapped, 0, reason: '★ 处理队列运行中不得提交（否则 clearAll 掐断队列）');
    });

    testWidgets('submitEnabled=true 时正常触发提交', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ActionButtons(
            onBatchSubmit: () => tapped++,
            submitEnabled: true,
          ),
        ),
      ));

      await tester.tap(find.text('批量入库'));
      await tester.pump();
      expect(tapped, 1);
    });
  });

  group('IMP-11 批量入库互斥', () {
    test('并发调用只处理一次，且互斥会被释放', () async {
      final queuedDir = Directory(p.join(appRoot.path, 'IMP11_Queued'))
        ..createSync(recursive: true);
      final candidatesJson = jsonEncode([
        {
          'dir_path': queuedDir.path,
          'inferred_title': 'IMP11_Queued',
          'original_title': 'IMP11_Queued',
          'task_status': 'ready',
          'confidence': 0.9,
          'discovered_at': DateTime.now().toIso8601String(),
        }
      ]);
      SharedPreferences.setMockInitialValues({
        'watch_folder_candidates': candidatesJson,
      });

      final service = WatchFolderService.instance;
      await service.loadSettings();
      expect(service.candidates.length, 1, reason: '前置条件：队列中应有 1 个就绪候选');

      final results = await Future.wait([
        service.confirmAllCandidates(),
        service.confirmAllCandidates(), // 同一事件循环内并发重入
      ]);

      expect(results.where((r) => r == 1).length, 1,
          reason: '只允许一次调用真正完成入库');
      expect(results.where((r) => r == 0).length, 1,
          reason: '★ 重入调用必须被互斥挡下并返回 0');
      expect(service.candidates, isEmpty, reason: '已入库候选应出队');

      // 互斥必须被释放（否则后续入库永久失效）
      expect(await service.confirmAllCandidates(), 0);
    });
  });
}
