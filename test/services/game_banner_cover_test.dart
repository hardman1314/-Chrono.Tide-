// 横幅封面（banner_file）回归测试（2026-10-04）
//
// 对应 docs/DEV/features/game_banner_cover.md：
//   - game.json 新增可空字段 banner_file，**不升 format_version**
//     （ADR-012 例外先例：storage_state 三字段，game_data_format.dart 头注释）
//   - findBannerFile 探测顺序：传入已解析值 → game.json 键 → banner.* 扫描
//   - 重复入库覆盖语义：banner_file 属抓取派生数据（与 cover_file 同类），
//     本次导入无横幅时落空串（= 无横幅，UI 回退竖向封面）
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
    appRoot = Directory.systemTemp.createTempSync('ct_banner_cover_');
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

  group('banner_file 字段（不升版本兼容）', () {
    test('老文件无 banner_file 键：读回默认空串，format_version 不被改动', () async {
      final dir = newGameDir('banner_legacy');
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'format_version': 4,
        'title': '老游戏',
        'cover_file': 'cover.png',
      }));

      final data = await GameDataFormat.readGameJson(dir.path);
      expect(data, isNotNull);
      expect(data!.bannerFile, '',
          reason: '老文件无键 → ?? \'\' 读取，完全兼容（不升版本的兼容前提）');
      expect(data.formatVersion, 4,
          reason: '纯新增可空字段不升版本（ADR-012 例外先例：storage_state）');
    });

    test('GameJsonData.toJson：空横幅不输出键（避免老文件无意义改写），有值才输出', () {
      final empty = GameJsonData(formatVersion: 4, title: 'a');
      expect(empty.toJson().containsKey('banner_file'), isFalse,
          reason: '无横幅的游戏 game.json 保持字节级旧形态');

      final withBanner =
          GameJsonData(formatVersion: 4, title: 'a', bannerFile: 'banner_1.jpg');
      expect(withBanner.toJson()['banner_file'], 'banner_1.jpg');
    });

    test('updateGameJson 写 banner_file 后 findBannerFile 按 json 键命中', () async {
      final dir = newGameDir('banner_json_key');
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '横幅测试',
        directoryPath: dir.path,
        source: 'local_import',
      );
      // 模拟横幅已落盘（真实落盘由 CoverDownloadService 完成，测试直接放文件）
      final bannerPath = p.join(dir.path, 'banner_7.jpg');
      File(bannerPath).writeAsStringSync('fake');

      await GameDataFormat.updateGameJson(
          dir.path, {'banner_file': 'banner_7.jpg'});

      final data = await GameDataFormat.readGameJson(dir.path);
      expect(data!.bannerFile, 'banner_7.jpg');

      // ① 传入已解析值：热路径直接命中
      final hit1 = GameDataFormat.findBannerFile(dir.path,
          bannerFileName: 'banner_7.jpg');
      expect(hit1?.path, bannerPath);

      // ② 不传：回退 game.json 键命中
      final hit2 = GameDataFormat.findBannerFile(dir.path);
      expect(hit2?.path, bannerPath);

      // ③ json 键指向的文件已被删：回退 banner.* 扫描命中同名之外的文件
      File(bannerPath).deleteSync();
      final altPath = p.join(dir.path, 'banner.png');
      File(altPath).writeAsStringSync('fake');
      final hit3 = GameDataFormat.findBannerFile(dir.path);
      expect(hit3?.path, altPath);

      // ④ 目录里啥都没有：null
      final emptyDir = newGameDir('banner_empty');
      expect(GameDataFormat.findBannerFile(emptyDir.path), isNull);
    });

    test('重复入库覆盖语义：旧文件有 banner_file，本次导入无横幅 → 落空串', () async {
      final dir = newGameDir('banner_reimport');
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'format_version': 4,
        'title': '旧标题',
        'banner_file': 'banner_3.jpg',
        'play_time': 120,
      }));

      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '新标题',
        directoryPath: dir.path,
        source: 'local_import',
      );

      final out = readJson(dir);
      expect(out['banner_file'], '',
          reason: 'banner_file 是抓取派生数据（与 cover_file 同类），'
              '重复入库以本次为准；本次无横幅 = 无横幅语义，UI 回退竖封面');
      expect(out['play_time'], 120, reason: '累积型字段不受影响');
    });

    test('writeGameDir 传非 http 的 bannerUrl → 按无横幅处理（不抛异常）', () async {
      final dir = newGameDir('banner_bad_url');
      await GameDataFormat.writeGameDir(
        targetDir: dir.path,
        title: '坏URL测试',
        directoryPath: dir.path,
        source: 'local_import',
        bannerUrl: 'not-a-url',
      );

      final out = readJson(dir);
      expect(out['banner_file'], '');
      expect(out['format_version'], 4);
    });
  });
}
