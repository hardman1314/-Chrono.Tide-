// 智能归纳"写穿"入口（标签 / 会社）· 单元测试
//
// 为什么必须有这层测试：
// 智能归纳的成员关系是**派生**的——「把游戏加入标签组」在本项目里的正确实现
// 就是改游戏自己的标签。所以这两个 API 是"用户编辑归纳"的唯一落点，
// 一旦它们只改内存不落盘（或落盘失败不回滚），
// 分组显示就会与磁盘上的游戏数据脱节，且重启后无声复原。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

Directory? _tmpRoot;

String _p(String name) => '${_tmpRoot!.path}${Platform.pathSeparator}$name';

LibraryGame _game(String metaDir,
        {List<String> tags = const ['纯爱'], String developer = 'Key'}) =>
    LibraryGame(
      title: '测试游戏',
      directoryPath: metaDir,
      metaDataDir: metaDir,
      installedAt: '2026-01-01T00:00:00.000',
      tags: tags,
      developer: developer,
    );

Future<void> _seed(String metaDir,
    {List<String> tags = const ['纯爱'], String developer = 'Key'}) async {
  await Directory(metaDir).create(recursive: true);
  await File('$metaDir${Platform.pathSeparator}game.json').writeAsString(
    jsonEncode({
      'title': '测试游戏',
      'tags': tags,
      'developer': developer,
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_sg_write');
    PathHelper.exeDirOverride = _tmpRoot!.path;
  });

  tearDownAll(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  group('setGameTag（标签写穿）', () {
    test('添加标签：内存与 game.json 同步', () async {
      final meta = _p('t1');
      await _seed(meta);
      final game = _game(meta);

      final ok =
          await LocalGameRegistry.instance.setGameTag(game, '悬疑', true);
      expect(ok, isTrue);
      expect(game.tags, ['纯爱', '悬疑']);

      final data = await GameDataFormat.readGameJson(meta);
      expect(data!.tags, ['纯爱', '悬疑'], reason: '必须落盘，否则重启即复原');
    });

    test('移除标签：内存与 game.json 同步', () async {
      final meta = _p('t2');
      await _seed(meta, tags: ['纯爱', '悬疑']);
      final game = _game(meta, tags: ['纯爱', '悬疑']);

      final ok =
          await LocalGameRegistry.instance.setGameTag(game, '纯爱', false);
      expect(ok, isTrue);
      expect(game.tags, ['悬疑']);

      final data = await GameDataFormat.readGameJson(meta);
      expect(data!.tags, ['悬疑']);
    });

    test('标签首尾空白被裁剪后再匹配（不产生 "" 与 "纯爱 " 两个组）', () async {
      final meta = _p('t3');
      await _seed(meta);
      final game = _game(meta);

      final ok = await LocalGameRegistry.instance
          .setGameTag(game, '  悬疑  ', true);
      expect(ok, isTrue);
      expect(game.tags, ['纯爱', '悬疑'], reason: '写入前必须 trim');
    });

    test('已经是目标状态 → 幂等返回 true 且不重复写入', () async {
      final meta = _p('t4');
      await _seed(meta);
      final game = _game(meta);

      final ok =
          await LocalGameRegistry.instance.setGameTag(game, '纯爱', true);
      expect(ok, isTrue);
      expect(game.tags, ['纯爱']);
    });

    test('空标签被拒绝（返回 false，不改内存也不落盘）', () async {
      final meta = _p('t5');
      await _seed(meta);
      final game = _game(meta);

      expect(await LocalGameRegistry.instance.setGameTag(game, '   ', true),
          isFalse);
      expect(game.tags, ['纯爱']);
      final data = await GameDataFormat.readGameJson(meta);
      expect(data!.tags, ['纯爱']);
    });

    test('写盘失败时回滚内存，UI 不会与磁盘脱节', () async {
      // metaDataDir 指向一个"文件"，创建目录必然失败 → 写入返回 false
      final blocked = _p('blocked');
      await File(blocked).writeAsString('not a dir');
      final game = _game(blocked);

      final ok =
          await LocalGameRegistry.instance.setGameTag(game, '悬疑', true);
      expect(ok, isFalse);
      expect(game.tags, ['纯爱'], reason: '写盘失败必须回滚内存');
    });
  });

  group('setGameDeveloper（会社写穿）', () {
    test('设置会社：内存与 game.json 同步', () async {
      final meta = _p('d1');
      await _seed(meta);
      final game = _game(meta);

      final ok = await LocalGameRegistry.instance
          .setGameDeveloper(game, 'Nitroplus');
      expect(ok, isTrue);
      expect(game.developer, 'Nitroplus');

      final data = await GameDataFormat.readGameJson(meta);
      expect(data!.developer, 'Nitroplus');
    });

    test('清空会社（空串）→ 归入「未填会社」组', () async {
      final meta = _p('d2');
      await _seed(meta);
      final game = _game(meta);

      final ok = await LocalGameRegistry.instance.setGameDeveloper(game, '  ');
      expect(ok, isTrue);
      expect(game.developer, '');

      final data = await GameDataFormat.readGameJson(meta);
      expect(data!.developer, '');
    });

    test('会社相同 → 幂等返回 true', () async {
      final meta = _p('d3');
      await _seed(meta);
      final game = _game(meta);
      expect(await LocalGameRegistry.instance.setGameDeveloper(game, 'Key'),
          isTrue);
      expect(game.developer, 'Key');
    });

    test('写盘失败时回滚内存', () async {
      final blocked = _p('d_blocked');
      await File(blocked).writeAsString('not a dir');
      final game = _game(blocked);

      final ok =
          await LocalGameRegistry.instance.setGameDeveloper(game, 'X');
      expect(ok, isFalse);
      expect(game.developer, 'Key', reason: '写盘失败必须回滚内存');
    });
  });
}
