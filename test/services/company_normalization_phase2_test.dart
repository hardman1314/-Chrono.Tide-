import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/company_alias_pending.dart';
import 'package:chrono_tide/services/company_alias_store.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/library_smart_group_service.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

/// 会社归一化 Phase 2（接线层）回归测试。
///
/// 覆盖：game.json v3→v4 迁移、company_id 读写、writeGameDir /
/// setGameDeveloper 写入收敛、pending 漏斗、智能归纳 devId 分组与旧键迁移。
/// backfill（scan 后补算）依赖真实 gamesBaseDir，无法在单测内注入，
/// 由真机走查覆盖（见 features/company_alias_normalization.md §8）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory rootTmp;
  late CompanyAliasStore store;

  setUpAll(() async {
    // 单测无法走 rootBundle 资产链路：直接从仓库文件解析词典并注入单例
    final raw = await File('assets/data/company_aliases.json').readAsString();
    store = CompanyAliasStore.parse(raw);
    CompanyAliasStore.debugSetInstanceForTest(store);
    // 与 smart_group_write_through_test 同款：把 PathHelper 指到临时目录，
    // 避免单测触碰真实应用数据目录
    rootTmp = await Directory.systemTemp.createTemp('ct_company_root');
    PathHelper.exeDirOverride = rootTmp.path;
  });

  tearDownAll(() async {
    CompanyAliasStore.debugSetInstanceForTest(null);
    if (await rootTmp.exists()) {
      await rootTmp.delete(recursive: true);
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ct_company_test');
    CompanyAliasPendingStore.instance.resetForTest();
    CompanyAliasPendingStore.debugPathOverrideForTest =
        '${tempDir.path}${Platform.pathSeparator}company_alias_pending.json';
  });

  tearDown(() async {
    CompanyAliasPendingStore.debugPathOverrideForTest = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('game.json v3 → v4 迁移', () {
    test('v3 升到 v4：版本号前进、数据不动', () {
      final v3 = <String, dynamic>{
        'format_version': 3,
        'game_id': 'fixed-id',
        'title': '苍之彼方的四重奏',
        'developer': 'sprite',
      };
      final result = GameDataFormat.migrateGameJsonMap(v3);
      expect(result.changed, isTrue);
      expect(result.json['format_version'], GameDataFormat.currentVersion);
      expect(result.json['format_version'], 4);
      expect(result.json['developer'], 'sprite');
      expect(result.json['game_id'], 'fixed-id');
      expect(result.json.containsKey('company_id'), isFalse,
          reason: 'v4 迁移只升版本，不伪造解析结果');
    });

    test('v4 文件不再触发迁移（changed=false）', () {
      final v4 = <String, dynamic>{
        'format_version': 4,
        'game_id': 'fixed-id',
        'title': 't',
      };
      final result = GameDataFormat.migrateGameJsonMap(v4);
      expect(result.changed, isFalse);
      expect(result.json['format_version'], 4);
    });
  });

  group('GameJsonData.company_id 读写', () {
    test('fromJson：int / double / 缺键三种形态', () {
      final a = GameJsonData.fromJson(
          {'format_version': 4, 'company_id': 3});
      expect(a.companyId, 3);
      final b = GameJsonData.fromJson(
          {'format_version': 4, 'company_id': 3.0});
      expect(b.companyId, 3, reason: '外部工具写 double 也要能读（M7 同款策略）');
      final c = GameJsonData.fromJson({'format_version': 4});
      expect(c.companyId, isNull);
    });

    test('toJson：非空才输出该键', () {
      expect(GameJsonData(
        formatVersion: 4,
        title: 't',
        companyId: 3,
      ).toJson().containsKey('company_id'), isTrue);
      expect(GameJsonData(
        formatVersion: 4,
        title: 't',
      ).toJson().containsKey('company_id'), isFalse);
    });
  });

  group('写入收敛（writeGameDir / setGameDeveloper）', () {
    late String gameDir;

    setUp(() async {
      gameDir = '${tempDir.path}${Platform.pathSeparator}game_a';
      await GameDataFormat.writeGameDir(
        targetDir: gameDir,
        title: 'テストゲーム',
        developer: 'sprite', // 词典命中 → 入库即解析
      );
    });

    test('入库即解析：writeGameDir 落盘 company_id=3', () async {
      final data = await GameDataFormat.readGameJson(gameDir);
      expect(data, isNotNull);
      expect(data!.developer, 'sprite');
      expect(data.companyId, 3);
      expect(data.formatVersion, GameDataFormat.currentVersion);
    });

    test('setGameDeveloper：别名命中同一 company_id，原文保留', () async {
      final game = LibraryGame(
        title: 'テストゲーム',
        directoryPath: gameDir,
        metaDataDir: gameDir,
        installedAt: DateTime.now().toIso8601String(),
      );
      final ok = await LocalGameRegistry.instance
          .setGameDeveloper(game, '雪碧社');
      expect(ok, isTrue);
      expect(game.developer, '雪碧社', reason: '原文不洗写，分组靠 company_id');
      expect(game.companyId, 3, reason: '雪碧社与 sprite 必须是同一家会社');

      final disk = await GameDataFormat.readGameJson(gameDir);
      expect(disk!.companyId, 3);
      expect(disk.developer, '雪碧社');
    });

    test('setGameDeveloper：未命中 → company_id=null 且进 pending', () async {
      final pendingPath = CompanyAliasPendingStore.debugPathOverrideForTest!;
      final game = LibraryGame(
        title: 'テストゲーム',
        directoryPath: gameDir,
        metaDataDir: gameDir,
        installedAt: DateTime.now().toIso8601String(),
      );
      final ok = await LocalGameRegistry.instance
          .setGameDeveloper(game, '不存在的第10086社');
      expect(ok, isTrue);
      expect(game.companyId, isNull);

      await CompanyAliasPendingStore.instance.flushNow();
      final disk = jsonDecode(await File(pendingPath).readAsString())
          as Map<String, dynamic>;
      final pending = (disk['pending'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(pending, isNotEmpty);
      expect(
        pending.any((e) => e['raw'] == '不存在的第10086社'),
        isTrue,
      );
    });

    test('setGameDeveloper：清空会社 → company_id 一并清空', () async {
      final game = LibraryGame(
        title: 'テストゲーム',
        directoryPath: gameDir,
        metaDataDir: gameDir,
        installedAt: DateTime.now().toIso8601String(),
      );
      await LocalGameRegistry.instance.setGameDeveloper(game, '雪碧社');
      await LocalGameRegistry.instance.setGameDeveloper(game, '');
      expect(game.developer, '');
      expect(game.companyId, isNull);
      final disk = await GameDataFormat.readGameJson(gameDir);
      expect(disk!.companyId, isNull);
    });

    test('setGameDeveloper：命中时自动消化 pending 旧条目（词典扩批场景）', () async {
      final pendingPath = CompanyAliasPendingStore.debugPathOverrideForTest!;
      // 模拟旧词典时代留下的 pending 条目（当时『雪碧社』未命中）
      await CompanyAliasPendingStore.instance.record('雪碧社',
          sampleGameId: 'game-legacy');
      await CompanyAliasPendingStore.instance.flushNow();
      expect(CompanyAliasPendingStore.instance.entryCount, 1);

      final game = LibraryGame(
        title: 'テストゲーム',
        directoryPath: gameDir,
        metaDataDir: gameDir,
        installedAt: DateTime.now().toIso8601String(),
      );
      final ok = await LocalGameRegistry.instance
          .setGameDeveloper(game, '雪碧社');
      expect(ok, isTrue);
      expect(game.companyId, 3);

      // 命中即清：pending 旧条目被消化，不再只增不减
      await CompanyAliasPendingStore.instance.flushNow();
      final disk = jsonDecode(await File(pendingPath).readAsString())
          as Map<String, dynamic>;
      final pending = (disk['pending'] as List);
      expect(
        pending.any((e) => (e as Map)['raw'] == '雪碧社'),
        isFalse,
        reason: '词典命中后旧 pending 条目必须被自动清理',
      );
    });
  });

  group('智能归纳：devId 分组与旧键迁移', () {
    LibraryGame game(String dev, {int? companyId, List<String> tags = const []}) =>
        LibraryGame(
          title: dev.isEmpty ? 'unassigned' : dev,
          directoryPath: '/x/$dev',
          metaDataDir: '/x/$dev',
          installedAt: '2026-01-01T00:00:00.000',
          developer: dev,
          companyId: companyId,
          tags: tags,
        );

    test('同一会社的不同写法归并进同一 devId 组', () {
      final groups = SmartGroupService.deriveGroups([
        game('sprite', companyId: 3),
        game('雪碧社', companyId: 3),
        game('精灵社', companyId: 3),
        game('雪碧社'), // 未解析：原文组
        game('', companyId: null), // 未填
      ], companyAliases: store);

      final devGroups =
          groups.where((g) => g.kind == SmartGroupKind.developer).toList();

      final merged = devGroups.where((g) => g.companyId == 3).toList();
      expect(merged.length, 1, reason: 'sprite/雪碧社/精灵社 必须是同一组');
      expect(merged.first.key, SmartGroupService.companyDevKey(3));
      expect(merged.first.count, 3);
      // value = 标准主名（拖拽写穿把 developer 收敛到规范写法）
      expect(merged.first.value, 'sprite');

      final raw = devGroups
          .where((g) => g.companyId == null && g.key == 'dev:雪碧社')
          .toList();
      expect(raw.length, 1);
      expect(raw.first.count, 1, reason: '未解析原文组只收未解析的游戏，避免双计');
    });

    test('matches：devId 组跨写法命中；原文组不抢已解析游戏', () {
      final devIdGroup = SmartGroupService.deriveGroups(
          [game('sprite', companyId: 3)],
          companyAliases: store)
          .firstWhere((g) => g.companyId == 3);
      expect(devIdGroup.matches(game('雪碧社', companyId: 3)), isTrue);
      expect(devIdGroup.matches(game('sprite')), isFalse);

      final rawGroup = SmartGroupService.deriveGroups([game('雪碧社')],
              companyAliases: store)
          .firstWhere((g) => g.key == 'dev:雪碧社');
      expect(rawGroup.matches(game('雪碧社')), isTrue);
      expect(rawGroup.matches(game('雪碧社', companyId: 3)), isFalse);
    });

    test('旧覆盖项键迁移：dev:雪碧社 → devId:3，未命中的保留', () {
      final migrated = SmartGroupService.migrateLegacyDevOverrideKeys({
        'dev:雪碧社': const SmartGroupOverride(displayName: '雪碧酱'),
        'dev:不存在的社': const SmartGroupOverride(pinned: true),
        'tag:纯爱': const SmartGroupOverride(pinned: true),
      }, store);

      expect(
        migrated.containsKey(SmartGroupService.companyDevKey(3)),
        isTrue,
        reason: '雪碧社能在词典命中，覆盖项必须搬到 devId 键',
      );
      expect(
        migrated[SmartGroupService.companyDevKey(3)]!.displayName,
        '雪碧酱',
      );
      expect(migrated.containsKey('dev:雪碧社'), isFalse);
      expect(migrated.containsKey('dev:不存在的社'), isTrue);
      expect(migrated.containsKey('tag:纯爱'), isTrue);
    });

    test('词典缺席时迁移是空操作（降级零回归）', () {
      final input = {
        'dev:雪碧社': const SmartGroupOverride(pinned: true),
      };
      final out = SmartGroupService.migrateLegacyDevOverrideKeys(input, null);
      expect(out.containsKey('dev:雪碧社'), isTrue);
    });
  });

  group('pending 漏斗', () {
    test('同键归并计数、上限受控、落盘可读', () async {
      final s = CompanyAliasPendingStore.instance;
      await s.record('不存在的第10086社', sampleGameId: 'game-1');
      await s.record(' 不存在的第10086社 ', sampleGameId: 'game-2');
      await s.record('不存在的第10086社', sampleGameId: 'game-1');
      expect(s.entryCount, 1, reason: '归一化后同键必须归并');
      await s.flushNow();

      final disk = jsonDecode(await File(
              CompanyAliasPendingStore.debugPathOverrideForTest!)
          .readAsString()) as Map<String, dynamic>;
      final list = (disk['pending'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(list.length, 1);
      expect(list.first['count'], 3);
      expect((list.first['sample_game_ids'] as List).length, 2);
    });

    test('removeIfResolved：命中即清、未命中保留、重复清理幂等', () async {
      final s = CompanyAliasPendingStore.instance;
      await s.record('不存在的第10086社');
      await s.record('另一个不存在社');
      expect(s.entryCount, 2);

      // 未命中（companyId=null）→ 全部保留
      await s.removeIfResolved('不存在的第10086社', null);
      expect(s.entryCount, 2, reason: 'null = 未解析，不得清理');

      // 命中 → 只清对应键
      await s.removeIfResolved('不存在的第10086社', 3);
      expect(s.entryCount, 1);

      // 幂等：同键重复清理无副作用
      await s.removeIfResolved('不存在的第10086社', 3);
      expect(s.entryCount, 1);
    });
  });
}
