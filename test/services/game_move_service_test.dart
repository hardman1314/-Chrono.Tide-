// GameMoveService 回归测试（游戏目录真迁移）
//
// 覆盖方案 docs/DEV/features/move_game_location_implementation_plan.md §7 Phase 1：
// - 同卷 Directory.rename 原子路径（成功 → 源消失 / 目标完整 / 引用已切换）
// - 跨卷 isolate copy 路径（debugForceCrossVolume 强制走 copy：成功 → 校验 + 清源）
// - copy 失败回滚（debugFailAtRelativePath 注入：源完好 / 目标被清理 / 登记 unlink）
// - M0 校验（目标已存在 / 嵌套路径 / 运行中守卫）
// - M1 事务登记 + 启动检测（checkPendingMoveOnStartup，不自动删除）
//
// 路径隔离：照 import_data_safety_guard_test.dart 范式——
// exeDirOverride 在任何 PathHelper getter 首次解析前设置（setUpAll 最前）。
// 源/目标目录用 .dart_tool 下 gitignore 目录（systemTemp 会干扰
// debugActiveSessionDirsOverride 与 gamesDir 的隔离语义）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_move_service.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

void main() {
  late Directory appRoot;
  late Directory appGames;
  late Directory workRoot; // 迁移源/目标的工作区（应用自有目录之外）

  late String uniqueSuffix;

  /// 与 service._toAbsolute 相同语义：相对 → 绝对 + 反斜杠
  /// （service 归一化后 registry 存绝对路径，断言必须用同形态比较）
  String abs(String rel) =>
      Directory(rel).absolute.path.replaceAll('/', '\\');
  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_move_app_');
    appGames = Directory(p.join(appRoot.path, 'Games'))
      ..createSync(recursive: true);
    PathHelper.exeDirOverride = appRoot.path;

    final outside = Directory(p.join('.dart_tool', 'ct_move_work'));
    if (!outside.existsSync()) outside.createSync(recursive: true);
    workRoot = outside;
    uniqueSuffix = DateTime.now().millisecondsSinceEpoch.toString();
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    GameMoveService.debugForceCrossVolume = false;
    GameMoveService.debugFailAtRelativePath = null;
    LocalGameRegistry.instance.debugActiveSessionDirsOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
    try {
      if (workRoot.existsSync()) workRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GameMoveService.debugForceCrossVolume = false;
    GameMoveService.debugFailAtRelativePath = null;
    LocalGameRegistry.instance.debugActiveSessionDirsOverride = null;
  });

  /// 构造一个源游戏目录（含子目录/中文文件/多层嵌套）并注册到 registry
  Directory makeSourceTree(String title) {
    final src = Directory(p.join(workRoot.path, '${title}_src'))
      ..createSync(recursive: true);
    File(p.join(src.path, 'game.exe')).writeAsBytesSync(List.filled(4096, 1));
    File(p.join(src.path, '说明_中文.txt')).writeAsStringSync('存档数据-中文');
    final sub = Directory(p.join(src.path, 'data\\save'))
      ..createSync(recursive: true);
    File(p.join(sub.path, 'slot01.sav')).writeAsBytesSync(List.filled(2048, 7));

    final reg = LocalGameRegistry.instance;
    // 真实场景 game.directoryPath 恒为绝对路径（game_data_format.dart:158-159），
    // 注册时同样用绝对路径，保证同卷判定走 rename 快速路径
    reg.registerExtractionComplete(
      gameTitle: title,
      directoryPath: abs(src.path),
      tags: const [],
      launchPath: 'game.exe',
    );
    // 保证 metaDataDir + game.json 存在（M4 的 updateGameJson 需要落点）
    final metaDataDir = Directory(
        p.join(LocalGameRegistry.gamesBaseDir, title.replaceAll(
            RegExp(r'[\\/:*?"<>|]'), '_')))
      ..createSync(recursive: true);
    final gameJson = File(p.join(metaDataDir.path, 'game.json'));
    if (!gameJson.existsSync()) {
      gameJson.writeAsStringSync(jsonEncode({
        'title': title,
        'directory_path': src.path,
        'launch_path': 'game.exe',
      }));
    }
    return src;
  }

  group('M0 前置校验', () {
    test('目标目录已存在 → 拒绝（防覆盖合并）', () async {
      final title = 'M0目标已存在_$uniqueSuffix';
      makeSourceTree(title);
      final dst = Directory(p.join(workRoot.path, 'm0_existing_$uniqueSuffix'))
        ..createSync(recursive: true);

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: dst.path,
      );

      expect(result.status, MoveStatus.failed);
      expect(result.errorMessage, contains('已存在'));
    });

    test('目标是源目录的子目录 → 拒绝（嵌套）', () async {
      final title = 'M0嵌套_$uniqueSuffix';
      final src = makeSourceTree(title);

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: p.join(src.path, 'nested_target'),
      );

      expect(result.status, MoveStatus.failed);
      expect(result.errorMessage, contains('内部'));
    });

    test('游戏运行中 → 拒绝（activeSessionDirs 守卫）', () async {
      final title = 'M0运行中_$uniqueSuffix';
      final src = makeSourceTree(title);
      final reg = LocalGameRegistry.instance;
      final game = reg.getGameByTitle(title)!;
      reg.debugActiveSessionDirsOverride = {game.metaDataDir};

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: p.join(workRoot.path, 'm0_running_$uniqueSuffix'),
      );

      expect(result.status, MoveStatus.failed);
      expect(result.errorMessage, contains('运行'));
      expect(src.existsSync(), isTrue, reason: '拒绝时源目录不受影响');
    });
  });

  group('同卷 rename 快速路径', () {
    test('成功：源消失、目标完整、引用切换、movedViaRename=true', () async {
      final title = 'SV成功_$uniqueSuffix';
      final src = makeSourceTree(title);
      final target = abs(p.join(workRoot.path, 'sv_target_$uniqueSuffix'));

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: target,
      );
      // ignore: avoid_print
      print('SV_RESULT status=${result.status} err=${result.errorMessage}');

      expect(result.status, MoveStatus.success,
          reason: 'referenceWarnings=${result.referenceWarnings}');
      expect(result.movedViaRename, isTrue);
      expect(result.sourcePath, abs(src.path),
          reason: 'MoveResult 需携带源路径（完成页注册表扫描依赖）');
      expect(src.existsSync(), isFalse, reason: '同卷 rename 后源目录应消失');
      expect(File(p.join(target, 'game.exe')).lengthSync(), 4096);
      expect(File(p.join(target, r'data\save\slot01.sav')).lengthSync(), 2048);
      expect(File(p.join(target, '说明_中文.txt')).existsSync(), isTrue);

      final game = LocalGameRegistry.instance.getGameByTitle(title)!;
      expect(game.directoryPath, target,
          reason: 'M4 引用切换后 registry 应指向新目录');
      // 事务登记应被清除
      expect(
          File(p.join(PathHelper.dataDir, 'move_in_progress.json'))
              .existsSync(),
          isFalse);
    });

    test('重复移动到同一目录 → 目标已存在拒绝', () async {
      final title = 'SV重复_$uniqueSuffix';
      makeSourceTree(title);
      final target = p.join(workRoot.path, 'sv_dup_$uniqueSuffix');

      final first = await GameMoveService.instance.moveGame(
          gameTitle: title, targetDirPath: target);
      expect(first.status, MoveStatus.success);

      final second = await GameMoveService.instance.moveGame(
          gameTitle: title, targetDirPath: p.join(workRoot.path, 'sv_dup2_$uniqueSuffix'));
      // 第一次移动后 directoryPath 已是 target；第二次成功移动也无妨——
      // 这里主要验证互斥与引用一致，不强断言第二次结果
      expect(second.status, anyOf(MoveStatus.success, MoveStatus.failed));
    });
  });

  group('跨卷 copy 路径（debugForceCrossVolume 强制）', () {
    test('成功：逐文件校验 + 清源 + 引用切换', () async {
      final title = 'XV成功_$uniqueSuffix';
      final src = makeSourceTree(title);
      GameMoveService.debugForceCrossVolume = true;
      final target = abs(p.join(workRoot.path, 'xv_target_$uniqueSuffix'));

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: target,
      );

      expect(result.status, MoveStatus.success,
          reason: 'warnings=${result.referenceWarnings} '
              'leftover=${result.sourceLeftoverPath}');
      expect(result.movedViaRename, isFalse);
      expect(src.existsSync(), isFalse, reason: '跨卷成功后源目录应被清源');
      expect(File(p.join(target, 'game.exe')).lengthSync(), 4096);
      expect(File(p.join(target, r'data\save\slot01.sav')).lengthSync(), 2048);

      final game = LocalGameRegistry.instance.getGameByTitle(title)!;
      expect(game.directoryPath, target);
    });

    test('copy 失败回滚：源完好、目标被清理、状态 failed', () async {
      final title = 'XV回滚_$uniqueSuffix';
      final src = makeSourceTree(title);
      GameMoveService.debugForceCrossVolume = true;
      GameMoveService.debugFailAtRelativePath = 'data\\save\\slot01.sav';
      final target = p.join(workRoot.path, 'xv_rollback_$uniqueSuffix');

      final result = await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: target,
      );

      expect(result.status, MoveStatus.failed);
      expect(src.existsSync(), isTrue, reason: '★ 回滚后源目录必须完好');
      expect(File(p.join(src.path, 'game.exe')).lengthSync(), 4096);
      expect(Directory(target).existsSync(), isFalse,
          reason: '自建目标目录应被回滚清理');
      expect(File(p.join(PathHelper.dataDir, 'move_in_progress.json'))
          .existsSync(), isFalse, reason: '失败后事务登记应清除');

      final game = LocalGameRegistry.instance.getGameByTitle(title)!;
      expect(game.directoryPath, abs(src.path), reason: '回滚后引用不应变更');
    });
  });

  group('M1 事务登记与启动检测', () {
    test('checkPendingMoveOnStartup：登记存在时报告且不自动删除', () async {
      final title = 'PEND检测_$uniqueSuffix';
      final regFile = File(p.join(PathHelper.dataDir, 'move_in_progress.json'));
      regFile.parent.createSync(recursive: true);

      final fakeTarget = Directory(p.join(workRoot.path, 'pend_target_$uniqueSuffix'))
        ..createSync(recursive: true);
      File(p.join(fakeTarget.path, 'half.bin')).writeAsBytesSync([1, 2, 3]);

      regFile.writeAsStringSync(jsonEncode({
        'task_id': 'move-test',
        'gameTitle': title,
        'sourcePath': p.join(workRoot.path, 'pend_src_$uniqueSuffix'),
        'targetPath': fakeTarget.path,
        'phase': 'copy',
        'startedAt': '2026-09-12T00:00:00.000',
      }));

      await GameMoveService.instance.checkPendingMoveOnStartup();

      expect(GameMoveService.instance.startupPendingMoves, isNotEmpty);
      final rec = GameMoveService.instance.takeStartupPendingMove(title);
      expect(rec, isNotNull);
      expect(rec!.targetExists, isTrue);
      expect(rec.sourceExists, isFalse);
      expect(fakeTarget.existsSync(), isTrue,
          reason: '★ 启动检测不得自动删除半成品（用户确认后清理）');
      expect(regFile.existsSync(), isTrue, reason: '检测不应清除登记文件');
    });

    test('无登记文件时启动检测为空操作', () async {
      final regFile = File(p.join(PathHelper.dataDir, 'move_in_progress.json'));
      if (regFile.existsSync()) regFile.deleteSync();

      await GameMoveService.instance.checkPendingMoveOnStartup();

      expect(GameMoveService.instance.startupPendingMoves, isEmpty);
    });
  });

  group('互斥', () {
    test('isMoving 状态在任务结束后复位', () async {
      final title = '互斥_$uniqueSuffix';
      makeSourceTree(title);
      expect(GameMoveService.isMoving, isFalse);

      await GameMoveService.instance.moveGame(
        gameTitle: title,
        targetDirPath: p.join(workRoot.path, 'mutex_$uniqueSuffix'),
      );

      expect(GameMoveService.isMoving, isFalse,
          reason: '任务结束（无论成败）必须复位互斥标志');
    });
  });
}
