// 游戏数据层加固回归测试（批 1，2026-09-19）
//
// 对应 docs/DEV/tickets/2026-09-17-game-data-schema-audit.md：
//   P0-3   writeGameDir 覆盖写入语义翻转（「保留白名单」→「覆盖黑名单」）
//          旧语义漏列 = 累积型字段被清零且无日志；新语义漏列 = 该字段不更新
//   P0-3b  GameJsonData 补齐 sessions / daily_play_log / title_locked
//          （此前磁盘 schema 与模型不一致，全量序列化会把事实表写没）
//   P1-2   findCoverFile 支持传入已解析的 cover_file，消除第二次 JSON 读取
//   P1-3   incrementDailyPlayCount 补 90 天裁剪（与 addDailyPlaySeconds 对齐）
//
// 路径隔离：PathHelper.exeDirOverride 必须在任何路径 getter 首次解析前设置。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_data_format.dart';

void main() {
  late Directory appRoot;
  late Directory appGames;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_data_fix_');
    appGames = Directory(p.join(appRoot.path, 'Games'))
      ..createSync(recursive: true);
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory newGameDir(String name) =>
      Directory(p.join(appGames.path, name))..createSync(recursive: true);

  Map<String, dynamic> readJson(Directory dir) =>
      jsonDecode(File(p.join(dir.path, 'game.json')).readAsStringSync())
          as Map<String, dynamic>;

  group('P0-3 覆盖写入语义：旧值默认保留，仅黑名单字段生效', () {
    test('重复入库：累积型字段一字不动，本次导入字段全部生效', () async {
      final dir = newGameDir('overwrite_keep');
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'format_version': 1,
        'title': '旧标题',
        'play_time': 3600,
        'sessions': [
          {'session_id': 'a', 'duration_seconds': 600},
          {'session_id': 'b', 'duration_seconds': 3000},
        ],
        'daily_play_log': {
          '2026-01-01': {'seconds': 3600, 'count': 2}
        },
        'installed_at': '2020-01-01T00:00:00.000000',
        'collection_ids': ['col_a'],
        'screenshot_files': ['s1.png'],
        'screenshot_status': 'completed',
        'title_locked': true,
        'mark': 'star',
        'play_status': 'completed',
      }));

      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '新标题',
        description: '新描述',
        tags: ['tag1'],
        launchPath: p.join(dir.path, 'game.exe'),
        directoryPath: dir.path,
        source: 'local_import',
        developer: '新会社',
        screenshotUrls: ['http://x/1.png'],
        metadataSource: 'VNDB',
        metadataSourceId: 'v123',
      );

      final out = readJson(dir);

      // ── 累积型：必须原样保留 ──
      expect(out['play_time'], 3600);
      expect((out['sessions'] as List).length, 2,
          reason: '会话事实表丢失 = 时长不可重建');
      expect((out['daily_play_log'] as Map)['2026-01-01']['seconds'], 3600);
      expect(out['installed_at'], '2020-01-01T00:00:00.000000',
          reason: 'installed_at = 首次入库时间，重复入库不得重置');
      expect(out['collection_ids'], ['col_a']);
      expect(out['screenshot_files'], ['s1.png']);
      expect(out['title_locked'], true);
      expect(out['mark'], 'star');
      expect(out['play_status'], 'completed');

      // ── 本次导入必须生效 ──
      expect(out['title'], '新标题');
      expect(out['description'], '新描述');
      expect(out['tags'], ['tag1']);
      expect(out['developer'], '新会社');
      expect(out['source'], 'local_import');
      expect(out['metadata_source'], 'VNDB');
      expect(out['metadata_source_id'], 'v123');
      expect(out['screenshot_urls'], ['http://x/1.png']);
    });

    test('首入库语义不变：空目录写入后含全部默认键', () async {
      final dir = newGameDir('fresh_write');
      await GameDataFormat.writeGameDir(targetDir: dir.path, title: '全新游戏');
      final out = readJson(dir);

      for (final k in [
        'format_version',
        'title',
        'play_time',
        'play_status',
        'installed_at',
        'updated_at',
        'collection_ids',
        'screenshot_files',
        'screenshot_urls',
        'screenshot_status',
      ]) {
        expect(out.containsKey(k), isTrue, reason: '首入库必须写入 $k');
      }
      expect(out['play_time'], 0);
      expect(out['play_status'], 'not_started');
      expect(out['screenshot_status'], 'completed',
          reason: '无截图 URL 时不应置 pending');
    });

    test('黑名单漏列的后果是「没更新」而不是「清零」（fail-safe 方向）', () async {
      final dir = newGameDir('unknown_field');
      File(p.join(dir.path, 'game.json'))
          .writeAsStringSync(jsonEncode({'title': 'x', 'my_future_field': 42}));

      await GameDataFormat.writeGameDir(targetDir: dir.path, title: 'y');

      final out = readJson(dir);
      expect(out['my_future_field'], 42,
          reason: '未列入覆盖名单的既有字段默认保留');
      expect(out['title'], 'y', reason: 'title 在覆盖名单内，正常生效');
    });
  });

  group('P0-3b GameJsonData 补齐累积型字段', () {
    test('fromJson 读取 sessions / daily_play_log / title_locked', () {
      final data = GameJsonData.fromJson({
        'title': 't',
        'sessions': [
          {'session_id': 's1', 'duration_seconds': 60}
        ],
        'daily_play_log': {
          '2026-09-19': {'seconds': 60, 'count': 1}
        },
        'title_locked': true,
      });

      expect(data.sessions?.length, 1);
      expect(data.sessions!.first['session_id'], 's1');
      expect(data.dailyPlayLog!['2026-09-19']['seconds'], 60);
      expect(data.titleLocked, true);
    });

    test('未加载时 toJson 不输出累积字段（防全量回写把事实表清空）', () {
      final json = GameJsonData.fromJson({'title': 't'}).toJson();
      expect(json.containsKey('sessions'), isFalse);
      expect(json.containsKey('daily_play_log'), isFalse);
      expect(json.containsKey('title_locked'), isFalse);
    });

    test('已加载时 toJson 原样回写（往返一致）', () {
      final src = {
        'title': 't',
        'sessions': [
          {'session_id': 's1'}
        ],
        'daily_play_log': {
          '2026-09-19': {'seconds': 5, 'count': 1}
        },
        'title_locked': false,
      };
      final json = GameJsonData.fromJson(src).toJson();
      expect(json['sessions'], src['sessions']);
      expect(json['daily_play_log'], src['daily_play_log']);
      expect(json['title_locked'], false);
    });
  });

  group('P1-2 findCoverFile 复用已解析的封面文件名', () {
    test('传入的 cover_file 命中时直接返回', () {
      final dir = newGameDir('cover_hit');
      File(p.join(dir.path, 'game.json'))
          .writeAsStringSync(jsonEncode({'cover_file': 'from_json.png'}));
      final real = File(p.join(dir.path, 'real.png'))..writeAsBytesSync([1]);

      final found = GameDataFormat.findCoverFile(dir.path,
          coverFileName: 'real.png');

      expect(found, isNotNull);
      expect(p.canonicalize(found!.path), p.canonicalize(real.path));
    });

    test('传入的 cover_file 不存在时回退原有探测逻辑（行为不回退）', () {
      final dir = newGameDir('cover_fallback');
      File(p.join(dir.path, 'game.json'))
          .writeAsStringSync(jsonEncode({'cover_file': 'from_json.png'}));
      final jsonCover = File(p.join(dir.path, 'from_json.png'))
        ..writeAsBytesSync([2]);

      final found = GameDataFormat.findCoverFile(dir.path,
          coverFileName: 'missing.png');

      expect(found, isNotNull);
      expect(p.canonicalize(found!.path), p.canonicalize(jsonCover.path));
    });

    test('不传参数时行为与改造前一致', () {
      final dir = newGameDir('cover_legacy');
      File(p.join(dir.path, 'game.json'))
          .writeAsStringSync(jsonEncode({'cover_file': 'legacy.png'}));
      final legacy = File(p.join(dir.path, 'legacy.png'))..writeAsBytesSync([3]);

      final found = GameDataFormat.findCoverFile(dir.path);

      expect(found, isNotNull);
      expect(p.canonicalize(found!.path), p.canonicalize(legacy.path));
    });
  });

  group('P1-3 每日游玩日志 90 天裁剪', () {
    test('incrementDailyPlayCount 清理 90 天前的条目', () async {
      final dir = newGameDir('daily_prune');
      final old = DateTime.now().subtract(const Duration(days: 120));
      final oldKey =
          '${old.year}-${old.month.toString().padLeft(2, '0')}-${old.day.toString().padLeft(2, '0')}';
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'title': 't',
        'daily_play_log': {
          oldKey: {'seconds': 999, 'count': 9}
        },
      }));

      await GameDataFormat.incrementDailyPlayCount(dir.path);

      final log = readJson(dir)['daily_play_log'] as Map;
      expect(log.containsKey(oldKey), isFalse,
          reason: '超过 90 天的条目应被裁剪');
      expect(log.length, 1, reason: '当日条目应保留');
    });

    test('addDailyPlaySeconds 保留 90 天内的条目（行为不回退）', () async {
      final dir = newGameDir('daily_keep');
      final recent = DateTime.now().subtract(const Duration(days: 10));
      final recentKey =
          '${recent.year}-${recent.month.toString().padLeft(2, '0')}-${recent.day.toString().padLeft(2, '0')}';
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'title': 't',
        'daily_play_log': {
          recentKey: {'seconds': 100, 'count': 1}
        },
      }));

      await GameDataFormat.addDailyPlaySeconds(dir.path, 60);

      final log = readJson(dir)['daily_play_log'] as Map;
      expect(log[recentKey]['seconds'], 100,
          reason: '90 天内的既有条目必须原样保留');
      final now = DateTime.now();
      final todayKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(log[todayKey]['seconds'], 60, reason: '当日条目正常累加');
    });
  });
}
