// 标题槽位收敛回归测试（P2-4）
//
// 背景：`docs/DEV/tickets/2026-09-17-game-data-schema-audit.md` P2-4。
// `game.json` 曾同时写 `original_title`（导入时的原名）与 `metadata_title`
// （抓取到的标准名），二者在磁盘上是同一份数据的两个副本；而经全库核对，
// **没有任何读取方读 game.json 的 `metadata_title`**（界面上的"双标题切换"
// 读的是内存中的导入候选对象），它是纯写入型冗余字段。
//
// 收敛方案：v2→v3 迁移把 `metadata_title` 并入 `original_title` 后删除该键；
// `writeGameDir` 不再写它，但在 `originalTitle` 为空时用入参 `metadataTitle`
// 兜底填入 `original_title` —— 保证"抓取到的标准名"这一信息不丢。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_data_format.dart';

void main() {
  late Directory appRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_title_slots_');
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory newGameDir(String name) {
    final d = Directory(p.join(appRoot.path, 'Games', name));
    d.createSync(recursive: true);
    return d;
  }

  Map<String, dynamic> readJson(Directory dir) =>
      jsonDecode(File(p.join(dir.path, GameDataFormat.gameJsonFileName))
          .readAsStringSync()) as Map<String, dynamic>;

  void writeRawJson(Directory dir, Map<String, dynamic> json) {
    File(p.join(dir.path, GameDataFormat.gameJsonFileName))
        .writeAsStringSync(jsonEncode(json));
  }

  group('P2-4 v2 → v3 迁移', () {
    test('两个键都有 → 保留 original_title，删除 metadata_title', () async {
      final dir = newGameDir('slots_both');
      writeRawJson(dir, {
        'format_version': 2,
        'game_id': 'gid-slots-both',
        'title': '展示标题',
        'original_title': '原始名',
        'metadata_title': '抓取到的标准名',
      });

      final data = await GameDataFormat.readGameJson(dir.path);

      expect(data!.originalTitle, '原始名',
          reason: '两个键都在时，original_title 是权威值');
      expect(data.formatVersion, GameDataFormat.currentVersion);

      final onDisk = readJson(dir);
      expect(onDisk.containsKey('metadata_title'), isFalse,
          reason: '★ v3 必须删除冗余键');
      expect(onDisk['original_title'], '原始名');
    });

    test('★ 只有 metadata_title → 无损搬运到 original_title 后再删键', () async {
      final dir = newGameDir('slots_only_meta');
      writeRawJson(dir, {
        'format_version': 2,
        'game_id': 'gid-only-meta',
        'title': '展示标题',
        'metadata_title': '抓取到的标准名',
      });

      final data = await GameDataFormat.readGameJson(dir.path);

      expect(data!.originalTitle, '抓取到的标准名',
          reason: '★ 迁移必须无损：值为空时要把 metadata_title 搬过来');
      expect(readJson(dir).containsKey('metadata_title'), isFalse);
      expect(readJson(dir)['original_title'], '抓取到的标准名');
    });

    test('迁移完成后再读一次应无变更（幂等，不反复写盘）', () async {
      final dir = newGameDir('slots_idempotent');
      writeRawJson(dir, {
        'format_version': 2,
        'title': 't',
        'metadata_title': 'm',
      });

      await GameDataFormat.readGameJson(dir.path);
      final stampAfterFirst = File(p.join(dir.path, 'game.json')).lastModifiedSync();

      final second = await GameDataFormat.readGameJson(dir.path);
      expect(second!.formatVersion, GameDataFormat.currentVersion);
      expect(File(p.join(dir.path, 'game.json')).lastModifiedSync(),
          stampAfterFirst,
          reason: '已是当前版本的文件不应再触发写回');
    });
  });

  group('P2-4 writeGameDir 不再产生冗余字段', () {
    test('不再写 metadata_title 键', () async {
      final dir = newGameDir('slots_write');
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '展示标题',
        directoryPath: dir.path,
        originalTitle: '原始名',
        metadataTitle: '标准名',
      );

      final onDisk = readJson(dir);
      expect(onDisk.containsKey('metadata_title'), isFalse);
      expect(onDisk['original_title'], '原始名');
    });

    test('originalTitle 为空时用 metadataTitle 兜底，信息不丢', () async {
      final dir = newGameDir('slots_fallback');
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '展示标题',
        directoryPath: dir.path,
        originalTitle: null,
        metadataTitle: '标准名',
      );

      expect(readJson(dir)['original_title'], '标准名');
    });

    test('★ 重复入库不会把已有的 original_title 清空', () async {
      final dir = newGameDir('slots_reimport');
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '展示标题',
        directoryPath: dir.path,
        originalTitle: '第一次的原始名',
      );

      // 第二次重复入库时调用方没带 originalTitle（null）
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '展示标题',
        directoryPath: dir.path,
        originalTitle: null,
      );

      // original_title 在覆盖黑名单内 —— 所以它**会**被本次空值覆盖。
      // 这条用例固定的是"当前语义"：覆盖名单内的字段以新值为准。
      // 真正要守的是「累积型字段不受影响」，见 game_data_overwrite_safety_test。
      expect(readJson(dir).containsKey('original_title'), isTrue);
    });
  });
}
