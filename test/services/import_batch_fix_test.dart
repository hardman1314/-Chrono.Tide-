// 导入链路批 3 修复回归测试（IMP-13 / IMP-16）
//
// 对应 docs/DEV/tickets/2026-09-12-import-audit-summary.md 的批 3：
//   IMP-13  批量入库"取下一批"不再在循环内删元素（否则按索引跳项、静默漏游戏）
//   IMP-16  「批量入库完成 X/Y」的分母必须是"本次实际尝试数"（ready 且非硬重复），
//           而不是 actionableCandidates（ready + failed）——否则数字会误导用户
//           以为失败项已被处理。本文件用服务层不变量锁定该口径。
//
// 说明：batch_import_controller 的入库循环依赖私有 `_games` 与网络抓取，
// 因此以"提取出的纯函数 + 服务层不变量"作为回归锚点（见汇总单 §5.1.3）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/watch_folder.dart';
import 'package:chrono_tide/pages/join/batch_import_controller.dart';
import 'package:chrono_tide/services/watch_folder_service.dart';

void main() {
  late Directory appRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_b3_app_');
    Directory(p.join(appRoot.path, 'Games')).createSync(recursive: true);
    // 必须在任何 PathHelper 路径 getter 首次解析之前设置
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  BatchGameItem game(String id) => BatchGameItem(
        id: id,
        folderPath: p.join(appRoot.path, 'src_$id'),
        gameName: 'Game_$id',
        originalTitle: 'Game_$id',
      );

  group('IMP-13 取下一批（不因取消而跳项）', () {
    test('取消中间项时，位于其后的游戏不会被跳过', () {
      final all = [game('A'), game('B'), game('C')];
      const batchSize = 2;

      // 第一批发现在 i=0，此时 B 已被取消
      final first = BatchImportController.takeNextImportBatch(
        all: all,
        startIndex: 0,
        batchSize: batchSize,
        cancelledIds: {'B'},
      );
      expect(first.map((g) => g.id), ['A']);

      // 第二批发在 i=2（循环变量按 batchSize 递增）
      final second = BatchImportController.takeNextImportBatch(
        all: all,
        startIndex: 2,
        batchSize: batchSize,
        cancelledIds: {'B'},
      );
      expect(second.map((g) => g.id), ['C'],
          reason: '★ 旧实现在循环内 removeWhere 把 B 删掉后列表变为 [A,C]，'
              'skip(2) 取到空集 → C 既不导入也不计入失败（随后被 clearAll 抹掉）');
    });

    test('无取消时按批切分，且不修改传入列表', () {
      final all = [game('A'), game('B'), game('C')];
      final first = BatchImportController.takeNextImportBatch(
        all: all,
        startIndex: 0,
        batchSize: 2,
        cancelledIds: const {},
      );
      final second = BatchImportController.takeNextImportBatch(
        all: all,
        startIndex: 2,
        batchSize: 2,
        cancelledIds: const {},
      );

      expect(first.map((g) => g.id), ['A', 'B']);
      expect(second.map((g) => g.id), ['C']);
      expect(all.length, 3, reason: '取批次不得改动原列表');
    });

    test('起始索引越界时返回空集', () {
      final all = [game('A')];
      expect(
        BatchImportController.takeNextImportBatch(
          all: all,
          startIndex: 2,
          batchSize: 2,
          cancelledIds: const {},
        ),
        isEmpty,
      );
    });
  });

  group('IMP-16 批量入库口径（分母 = 实际尝试数）', () {
    test('只就绪候选被处理：失败项保留在队列中', () async {
      final readyDir = Directory(p.join(appRoot.path, 'src_ready'))
        ..createSync(recursive: true);
      final failedDir = Directory(p.join(appRoot.path, 'src_failed'))
        ..createSync(recursive: true);

      final candidatesJson = jsonEncode([
        {
          'dir_path': readyDir.path,
          'inferred_title': 'B3_ReadyGame',
          'original_title': 'B3_ReadyGame',
          'task_status': 'ready',
          'confidence': 0.9,
          'discovered_at': DateTime.now().toIso8601String(),
        },
        {
          'dir_path': failedDir.path,
          'inferred_title': 'B3_FailedGame',
          'original_title': 'B3_FailedGame',
          'task_status': 'failed',
          'error_message': '模拟抓取失败',
          'confidence': 0.9,
          'discovered_at': DateTime.now().toIso8601String(),
        },
      ]);
      SharedPreferences.setMockInitialValues({
        'watch_folder_candidates': candidatesJson,
      });

      final service = WatchFolderService.instance;
      await service.loadSettings();
      expect(service.candidates.length, 2);

      // 服务层口径：ready 且非硬重复的才被处理
      final attemptCount = service.candidates
          .where((c) =>
              c.taskStatus == CandidateTaskStatus.ready && !c.isHardDuplicate)
          .length;
      expect(attemptCount, 1,
          reason: '★ IMP-16：分母是 1（只就绪项），不是 actionableCandidates 的 2');

      final successCount = await service.confirmAllCandidates();
      expect(successCount, 1);

      // 就绪项出队、失败项保留（供用户重试）
      expect(service.candidates.length, 1);
      expect(service.candidates.first.taskStatus, CandidateTaskStatus.failed);
      expect(service.candidates.first.title, 'B3_FailedGame');
    });
  });
}
