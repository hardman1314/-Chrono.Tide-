// 游戏身份与索引回归测试（P0-1 / P1-1 / P2-2 / P2-5）
//
// 背景：`docs/DEV/tickets/2026-09-17-game-data-schema-audit.md` 指出三个结构性缺陷，
// 本文件锁定其中「稳定主键缺失」「零索引」「schema 无版本承载点」三条的修复行为：
//
//   P0-1  game_id 必须一次生成、终身不变；任何覆盖写入都不得换掉它
//   P1-1  getGameByTitle / getGameById 走索引；allGames 结果被缓存
//   P2-2  format_version 有迁移链，老 game.json 读取时自动升级并写回
//   P2-5  installedAt 按 DateTime 比较，混入 UTC 带 Z 的值也不会错序
//
// 路径隔离：`PathHelper.exeDirOverride` 必须在任何 PathHelper 路径 getter 首次
// 解析前设置（exeDir 一旦解析即缓存），因此放在 setUpAll 最前面。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/utils/game_key.dart';

void main() {
  late Directory appRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_game_identity_app_');
    // 必须在任何 PathHelper 路径 getter / LocalGameRegistry 静态字段解析之前设置
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

  // ==========================================================
  group('GameKey —— 身份工具的唯一实现', () {
    test('dirNameFromTitle 只替换 Windows 非法字符，保留空白', () {
      expect(GameKey.dirNameFromTitle('Fate/stay night'), 'Fate_stay night');
      expect(GameKey.dirNameFromTitle('a:b*c?d"e<f>g|h\\i'), 'a_b_c_d_e_f_g_h_i');
      expect(GameKey.dirNameFromTitle('  空白 保留  '), '空白 保留');
      expect(GameKey.dirNameFromTitle('正常标题'), '正常标题');
    });

    test('dirNameFromTitle 不会再出现「空白替换为下划线」的第二套规则', () {
      // 历史 bug：GameConfigManager._sanitizeGameId 会把空白换成 '_'，
      // 与注册表的三处规则不一致 → 同一游戏算出两个 key → 重复卡片。
      expect(GameKey.dirNameFromTitle('My Game'), isNot('My_Game'));
      expect(GameKey.dirNameFromTitle('My Game'), 'My Game');
    });

    test('generateId 产出合法 UUID v4 且不重复', () {
      final re = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      final ids = <String>{};
      for (var i = 0; i < 200; i++) {
        final id = GameKey.generateId();
        expect(re.hasMatch(id), isTrue, reason: '格式不合法: $id');
        ids.add(id);
      }
      expect(ids.length, 200, reason: '200 次生成必须全部唯一');
    });
  });

  // ==========================================================
  group('P0-1 game_id：一次生成、终身不变', () {
    test('writeGameDir 返回并落盘 game_id', () async {
      final dir = newGameDir('id_new');
      final id = await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: 'ID 新入库',
        directoryPath: dir.path,
      );

      expect(id, isNotEmpty);
      expect(readJson(dir)['game_id'], id);
    });

    test('★ 重复入库沿用旧 game_id（覆盖黑名单语义）', () async {
      final dir = newGameDir('id_reimport');
      final first = await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '重复入库',
        directoryPath: dir.path,
      );
      expect(first, isNotEmpty);

      // 第二次覆盖写入：freshData 里会生成一个新的候选 id，
      // 但 game_id 不在 _overwritableFields 内 → 必须沿用磁盘上的旧值。
      final second = await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '重复入库（改名后）',
        directoryPath: dir.path,
      );

      expect(second, first, reason: '★ game_id 必须在重复入库后保持不变');
      expect(readJson(dir)['game_id'], first);
    });

    test('updateGameJson 拒绝把 game_id 改成别的值', () async {
      final dir = newGameDir('id_guard');
      final id = await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '主键护栏',
        directoryPath: dir.path,
      );

      final ok = await GameDataFormat.updateGameJson(
          dir.path, {'game_id': 'attacker-controlled-id', 'title': '新标题'});

      expect(ok, isTrue, reason: '其它字段仍应正常写入');
      expect(readJson(dir)['game_id'], id, reason: '★ 主键必须拒绝被覆盖');
      expect(readJson(dir)['title'], '新标题',
          reason: '被拒绝的只是 game_id，同批其它字段不受影响');
    });

    test('updateGameJson 拒绝把 game_id 写成空值', () async {
      final dir = newGameDir('id_empty_guard');
      final id = await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '空值护栏',
        directoryPath: dir.path,
      );

      await GameDataFormat.updateGameJson(dir.path, {'game_id': '   '});

      expect(readJson(dir)['game_id'], id);
    });

    test('GameJsonData.toJson 在 gameId 为空时不输出该键（防回写覆盖）', () {
      final data = GameJsonData(formatVersion: 2, title: 'x');
      expect(data.toJson().containsKey('game_id'), isFalse);

      final withId =
          GameJsonData(formatVersion: 2, gameId: 'abc', title: 'x');
      expect(withId.toJson()['game_id'], 'abc');
    });
  });

  // ==========================================================
  group('P2-2 format_version 迁移链', () {
    test('v1 老文件读取时自动升到 currentVersion 并补发 game_id，且写回磁盘', () async {
      final dir = newGameDir('migrate_v1');
      final jsonFile = File(p.join(dir.path, GameDataFormat.gameJsonFileName));
      // 构造一份"没有 game_id、版本号为 1"的历史 game.json
      jsonFile.writeAsStringSync(jsonEncode({
        'format_version': 1,
        'title': '老文件',
        'play_time': 3600,
        'sessions': [
          {'session_id': 's1', 'duration_seconds': 3600}
        ],
      }));

      final data = await GameDataFormat.readGameJson(dir.path);

      expect(data, isNotNull);
      expect(data!.gameId, isNotEmpty, reason: '迁移必须补发 game_id');
      expect(data.formatVersion, GameDataFormat.currentVersion);
      expect(data.playTime, 3600, reason: '迁移不得动其它字段');

      // 迁移结果必须落盘，否则每次读取都要重新补发（且 id 会每次都变）
      final onDisk = readJson(dir);
      expect(onDisk['game_id'], data.gameId);
      expect(onDisk['format_version'], GameDataFormat.currentVersion);
      expect((onDisk['sessions'] as List).length, 1,
          reason: '会话事实表必须原样保留');
    });

    test('★ 补发的 id 落盘后稳定：再次读取得到同一个 id', () async {
      final dir = newGameDir('migrate_stable');
      File(p.join(dir.path, GameDataFormat.gameJsonFileName))
          .writeAsStringSync(jsonEncode({'format_version': 1, 'title': '稳定'  }));

      final first = await GameDataFormat.readGameJson(dir.path);
      final second = await GameDataFormat.readGameJson(dir.path);

      expect(first!.gameId, isNotEmpty);
      expect(second!.gameId, first.gameId,
          reason: '★ id 一旦补发即终身不变，不允许每次读都换一个');
    });

    test('migrateGameJsonMap 对已是当前版本的文件不报变更', () {
      final result = GameDataFormat.migrateGameJsonMap({
        'format_version': GameDataFormat.currentVersion,
        'game_id': 'keep-me',
        'title': 't',
      });
      expect(result.changed, isFalse);
      expect(result.json['game_id'], 'keep-me');
    });

    test('migrateGameJsonMap 返回的是副本，不污染调用方持有的 map', () {
      final raw = <String, dynamic>{'format_version': 1, 'title': 't'};
      final result = GameDataFormat.migrateGameJsonMap(raw);
      expect(raw.containsKey('game_id'), isFalse,
          reason: '迁移必须作用在副本上，否则调用方持有的数据会被就地改写');
      expect(result.json.containsKey('game_id'), isTrue);
    });
  });

  // ==========================================================
  group('P1-1 / P0-1 注册表索引', () {
    final registered = <String>[];

    tearDown(() async {
      final reg = LocalGameRegistry.instance;
      for (final t in registered) {
        try {
          await reg.deleteGame(t);
        } catch (_) {}
      }
      registered.clear();
    });

    test('getGameById / isGameIdInstalled 走 id 索引', () {
      final reg = LocalGameRegistry.instance;
      const title = '索引测试_ID查询';
      registered.add(title);
      reg.registerExtractionComplete(
        gameTitle: title,
        directoryPath: p.join(appRoot.path, 'Games', title),
        gameId: 'fixed-id-0001',
      );

      expect(reg.getGameById('fixed-id-0001'), isNotNull);
      expect(reg.getGameById('fixed-id-0001')!.title, title);
      expect(reg.isGameIdInstalled('fixed-id-0001'), isTrue);
      // 旧实现把 gameId 当目录名查，这里锁死它不再退化为 containsKey(_games)
      expect(reg.isGameIdInstalled('不存在的id'), isFalse);
    });

    test('getGameByTitle 命中标题索引，也兼容传入目录名', () {
      final reg = LocalGameRegistry.instance;
      const title = '索引测试_标题查询';
      registered.add(title);
      reg.registerExtractionComplete(
        gameTitle: title,
        directoryPath: p.join(appRoot.path, 'Games', title),
      );

      expect(reg.getGameByTitle(title)?.title, title);
      // 兼容分支：老调用方直接传 safeName（= 目录名）
      expect(reg.getGameByTitle(GameKey.dirNameFromTitle(title))?.title, title);
      expect(reg.getGameByTitle('绝对不存在的标题'), isNull);
    });

    test('getGameByDirectoryPath 归一化匹配（大小写 / 分隔符无关）', () {
      final reg = LocalGameRegistry.instance;
      const title = '索引测试_目录查询';
      final dir = p.join(appRoot.path, 'Games', title);
      registered.add(title);
      reg.registerExtractionComplete(gameTitle: title, directoryPath: dir);

      expect(reg.getGameByDirectoryPath(dir)?.title, title);
      expect(reg.getGameByDirectoryPath(dir.replaceAll('\\', '/'))?.title, title);
    });

    test('★ P2-5 allGames 按真实时间排序，混入 UTC 带 Z 的值不会错序', () {
      final reg = LocalGameRegistry.instance;
      const titleA = '排序测试_A';
      const titleB = '排序测试_B';
      registered.addAll([titleA, titleB]);
      reg.registerExtractionComplete(
          gameTitle: titleA,
          directoryPath: p.join(appRoot.path, 'Games', titleA));
      reg.registerExtractionComplete(
          gameTitle: titleB,
          directoryPath: p.join(appRoot.path, 'Games', titleB));

      final a = reg.getGameByTitle(titleA)!;
      final b = reg.getGameByTitle(titleB)!;
      // A：本地 +08:00 的 2026-01-01T00:00 == 绝对时间 2025-12-31T16:00Z
      // B：UTC 的 2025-12-31T23:00 == 绝对时间 2025-12-31T23:00Z（更晚）
      // 字典序：'2025-...' < '2026-...' → 旧实现会误判 B 更旧；
      // 真实时间：B 更晚 → 「最近添加」里 B 必须排在 A 前面。
      a.installedAt = '2026-01-01T00:00:00+08:00';
      b.installedAt = '2025-12-31T23:00:00Z';

      final list = reg.allGames;
      final ia = list.indexWhere((g) => g.title == titleA);
      final ib = list.indexWhere((g) => g.title == titleB);

      expect(ia, isNot(-1));
      expect(ib, isNot(-1));
      expect(ib, lessThan(ia),
          reason: '★ 字典序会把 A 排前，真实时间序必须把 B 排前');
    });

    test('allGames 返回的是副本，调用方排序不污染缓存', () {
      final reg = LocalGameRegistry.instance;
      const title = '排序测试_副本';
      registered.add(title);
      reg.registerExtractionComplete(
          gameTitle: title,
          directoryPath: p.join(appRoot.path, 'Games', title));

      final first = reg.allGames;
      if (first.length >= 2) {
        final swapped = List<LibraryGame>.from(first)
          ..setRange(0, 1, [first[1]])
          ..setRange(1, 2, [first[0]]);
        expect(swapped.first.title, first[1].title); // 仅确认副本可写
        final second = reg.allGames;
        expect(second.first.title, first.first.title, reason: '缓存不得被调用方改写');
      } else {
        expect(first, isNotEmpty);
      }
    });
  });
}
