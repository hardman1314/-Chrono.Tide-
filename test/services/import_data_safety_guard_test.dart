// 导入链路数据安全护栏回归测试（IMP-01 / IMP-02 / IMP-03）
//
// 背景：2026-09-12「导入功能漏洞与 Bug 审查」发现三条能触达**用户自有目录**的
// 删除路径（详见 docs/DEV/tickets/2026-09-12-import-audit-summary.md）：
//   IMP-01  LocalGameRegistry.deleteGame 对 game.directoryPath 裸递归删除
//           （对本地导入的游戏而言该路径就是用户自己的游戏文件夹）
//   IMP-02  InterruptCleanup 退出清理对 actualGameDir / targetGameDir 越界删除，
//           且"是否含游戏数据"只看顶层 4 种扩展名（exe 在 bin/ 的目录会被误删）
//   IMP-03  AutoImportPipeline.cleanupTempCover 无条件删除候选封面
//           （可能是用户在表单里选的磁盘原图）
//
// 本文件锁定修复后的行为：**应用自有目录之外一律不删**（方向：宁可残留，不可误删）。
//
// 路径隔离说明：
// - `PathHelper.exeDirOverride` 必须在任何 PathHelper 路径 getter 首次解析前设置
//   （exeDir 一旦解析即缓存），因此放在 setUpAll 最前面。
// - `PathHelper.isInsideAppStorage` 的白名单包含 `Directory.systemTemp`，
//   所以"应用外目录"不能建在系统临时目录里，改用项目内被 gitignore 的
//   `.dart_tool/` 下（测试内会先断言该前提成立）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/watch_folder.dart';
import 'package:chrono_tide/services/auto_import_pipeline.dart';
import 'package:chrono_tide/services/interrupt_cleanup.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

void main() {
  /// 充当"应用安装目录"（exeDir）
  late Directory appRoot;

  /// <app>/Games —— 应用自有目录内的游戏目录
  late Directory appGames;

  /// 模拟"用户自己的游戏收藏目录"（必须位于应用自有目录之外）
  late Directory outsideRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_import_guard_app_');
    appGames = Directory(p.join(appRoot.path, 'Games'))
      ..createSync(recursive: true);
    // 必须在任何 PathHelper 路径 getter / LocalGameRegistry 静态字段解析之前设置
    PathHelper.exeDirOverride = appRoot.path;

    outsideRoot = Directory(p.join('.dart_tool', 'ct_import_guard_outside'));
    if (!outsideRoot.existsSync()) {
      outsideRoot.createSync(recursive: true);
    }
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    for (final d in [appRoot, outsideRoot]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('测试前提', () {
    test('"应用外目录"确实位于应用自有目录之外', () {
      expect(
        PathHelper.isInsideAppStorage(outsideRoot.path),
        isFalse,
        reason: '前提不成立时本文件的护栏断言会失去意义',
      );
      expect(
        PathHelper.isInsideAppStorage(appGames.path),
        isTrue,
        reason: '<app>/Games 必须被判定为应用自有目录（否则正向用例失效）',
      );
    });
  });

  group('IMP-01 LocalGameRegistry.deleteGame 本体删除护栏', () {
    test('应用目录之外的本体：记录移除但用户文件保留，并记录跳过路径', () async {
      final userGame = Directory(p.join(outsideRoot.path, 'CLANNAD'))
        ..createSync(recursive: true);
      File(p.join(userGame.path, 'CLANNAD.exe')).writeAsBytesSync([0, 1, 2]);
      File(p.join(userGame.path, 'user_notes.txt')).writeAsStringSync('用户数据');

      final reg = LocalGameRegistry.instance;
      reg.registerExtractionComplete(
        gameTitle: '护栏测试_CLANNAD',
        directoryPath: userGame.path,
        tags: const [],
        launchPath: 'CLANNAD.exe',
      );

      expect(reg.canDeleteGameBody('护栏测试_CLANNAD'), isFalse,
          reason: '应用目录之外的本体必须被判定为不可删除');
      expect(reg.gameBodyPath('护栏测试_CLANNAD'), userGame.path);

      final ok = await reg.deleteGame('护栏测试_CLANNAD');

      expect(ok, isTrue, reason: '库记录应正常移除');
      expect(reg.getGameByTitle('护栏测试_CLANNAD'), isNull);
      expect(userGame.existsSync(), isTrue, reason: '★ 用户源目录必须原封不动');
      expect(File(p.join(userGame.path, 'CLANNAD.exe')).existsSync(), isTrue);
      expect(reg.skippedBodyPaths, contains(userGame.path),
          reason: '跳过的路径需暴露给 UI，用于如实回执');
    });

    test('应用目录之内的本体：照常删除（行为不回退）', () async {
      final internalGame = Directory(p.join(appGames.path, 'InternalGame'))
        ..createSync(recursive: true);
      File(p.join(internalGame.path, 'game.exe')).writeAsBytesSync([0]);

      final reg = LocalGameRegistry.instance;
      reg.registerExtractionComplete(
        gameTitle: '护栏测试_InternalGame',
        directoryPath: internalGame.path,
        tags: const [],
        launchPath: 'game.exe',
      );

      expect(reg.canDeleteGameBody('护栏测试_InternalGame'), isTrue);

      final ok = await reg.deleteGame('护栏测试_InternalGame');

      expect(ok, isTrue);
      expect(internalGame.existsSync(), isFalse,
          reason: '应用自有目录内的本体应正常清理');
      expect(reg.skippedBodyPaths, isEmpty);
    });

    test('"仅移除记录"路径不产生过期跳过记录', () async {
      final reg = LocalGameRegistry.instance;
      await reg.deleteGame('不存在的游戏_护栏测试');
      expect(reg.skippedBodyPaths, isEmpty);
    });
  });

  group('IMP-02 InterruptCleanup 退出清理护栏', () {
    test('应用目录之外的实际解压目录不会被删除', () async {
      final outsideDir = Directory(p.join(outsideRoot.path, 'OutsideBody'))
        ..createSync(recursive: true);
      File(p.join(outsideDir.path, 'readme.txt')).writeAsStringSync('用户数据');

      await InterruptCleanup.cleanupActiveTaskResidue(
        actualGameDir: outsideDir.path,
        timeout: const Duration(seconds: 10),
      );

      expect(outsideDir.existsSync(), isTrue,
          reason: '★ 应用目录之外的目录一律不删（旧实现会因"无游戏数据"整目录删除）');
      expect(File(p.join(outsideDir.path, 'readme.txt')).existsSync(), isTrue);
    });

    test('应用目录之内、exe 位于子目录的目录会被保留（递归判定）', () async {
      final partial = Directory(p.join(appGames.path, 'PartialGame'))
        ..createSync(recursive: true);
      Directory(p.join(partial.path, 'bin')).createSync(recursive: true);
      File(p.join(partial.path, 'bin', 'Game.exe')).writeAsBytesSync([0, 1]);

      await InterruptCleanup.cleanupActiveTaskResidue(
        actualGameDir: partial.path,
        timeout: const Duration(seconds: 10),
      );

      expect(partial.existsSync(), isTrue,
          reason: '★ 旧实现只看顶层扩展名，会把这类目录误判为"无游戏数据"并整目录删除');
    });

    test('应用目录之内、确实无游戏数据的目录仍会被清理（行为不回退）', () async {
      final junk = Directory(p.join(appGames.path, 'JunkGame'))
        ..createSync(recursive: true);
      File(p.join(junk.path, 'part.tmp')).writeAsStringSync('x');

      await InterruptCleanup.cleanupActiveTaskResidue(
        targetGameDir: junk.path,
        timeout: const Duration(seconds: 10),
      );

      expect(junk.existsSync(), isFalse,
          reason: '应用自有目录内的半成品残留仍应被正常清理');
    });
  });

  group('IMP-03 AutoImportPipeline.cleanupTempCover 封面归属护栏', () {
    ImportCandidate candidateWith(String coverPath) => ImportCandidate(
          dirPath: p.join(outsideRoot.path, 'Cand'),
          inferredTitle: 'Cand',
          confidence: 0.5,
          discoveredAt: DateTime.now(),
          coverFilePath: coverPath,
        );

    test('用户原图（应用目录之外）不被删除，仅解除引用', () {
      final userCover = File(p.join(outsideRoot.path, 'my_cover.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final candidate = candidateWith(userCover.path);

      AutoImportPipeline.cleanupTempCover(candidate);

      expect(userCover.existsSync(), isTrue, reason: '★ 用户封面原图必须保留');
      expect(candidate.coverFilePath, isNull);
    });

    test('应用自有目录内的临时封面照常清理（行为不回退）', () {
      final tmpDir = Directory(p.join(appRoot.path, 'data', 'tmp'))
        ..createSync(recursive: true);
      final tmpCover = File(p.join(tmpDir.path, 'smart_cover_ab12.png'))
        ..writeAsBytesSync([1]);
      final candidate = candidateWith(tmpCover.path);

      AutoImportPipeline.cleanupTempCover(candidate);

      expect(tmpCover.existsSync(), isFalse);
      expect(candidate.coverFilePath, isNull);
    });

    test('coverFilePath 为空时不抛异常', () {
      final candidate = candidateWith('');
      expect(
        () => AutoImportPipeline.cleanupTempCover(candidate),
        returnsNormally,
      );
    });
  });
}
