// 启动路径收敛回归测试（P0-2）
//
// 背景：`docs/DEV/tickets/2026-09-17-game-data-schema-audit.md` P0-2。
// 启动 exe 路径曾同时存在三处：
//   A `game.json.launch_path`（权威本体）
//   B `data/game_configs/game_<标题>_config.json`（注释自称"主存储"）
//   C prefs `default_exe_<标题>`
// 三个读取入口的优先级各不相同，于是出现「改了启动程序却不生效」。
//
// 本文件锁定收敛后的行为：
//   1. A 命中即 A 优先，且 A 是**相对 directoryPath 的相对路径**；
//   2. B / C 只读兼容：命中即搬进 A 并**删除自身**；
//   3. 历史存储被清掉后，A 为空就必须返回 null（不允许旧值复活）；
//   4. persistUserChoice 只写 A，不再产生新的历史记录。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/game_launch_service.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/utils/game_config_manager.dart';
import 'package:chrono_tide/utils/game_key.dart';

void main() {
  late Directory appRoot;
  final registered = <String>[];

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    appRoot = Directory.systemTemp.createTempSync('ct_launch_path_app_');
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    final reg = LocalGameRegistry.instance;
    for (final t in registered) {
      try {
        await reg.deleteGame(t);
      } catch (_) {}
      try {
        await GameConfigManager.instance.removeConfig(t);
      } catch (_) {}
    }
    registered.clear();
  });

  /// 建一个"已入库"的游戏：本体目录里有真 exe，元数据目录里有 game.json
  Future<(LibraryGame, String)> setupGame(
    String title, {
    String launchRel = '',
  }) async {
    final body = Directory(p.join(appRoot.path, 'GameBody', title))
      ..createSync(recursive: true);
    File(p.join(body.path, 'game.exe')).writeAsBytesSync(const [0x4D, 0x5A]);

    final metaDir = p.join(PathHelper.gamesDir, GameKey.dirNameFromTitle(title));
    await GameDataFormat.writeGameDir(
      targetDir: metaDir,
      title: title,
      directoryPath: body.path,
      launchPath: launchRel,
    );
    LocalGameRegistry.instance
        .registerExtractionComplete(gameTitle: title, directoryPath: body.path);
    registered.add(title);
    final game = LocalGameRegistry.instance.getGameByTitle(title)!;
    return (game, body.path);
  }

  group('P0-2 解析优先级：A → B → C', () {
    test('A（game.json.launch_path）命中即优先，且按相对路径解析', () async {
      final (game, body) = await setupGame('收敛_A优先', launchRel: 'game.exe');
      // 先塞一份"更有诱惑力"的历史存储：如果优先级写反就会返回它
      await GameConfigManager.instance
          .saveLaunchPath('收敛_A优先', p.join(body, 'game.exe'));

      final resolved =
          await GameLaunchService.instance.resolveUserChoice('收敛_A优先');

      expect(resolved, isNotNull);
      expect(p.equals(resolved!, p.join(body, 'game.exe')), isTrue);
      expect(game.launchPath, 'game.exe',
          reason: 'launch_path 应是相对 directoryPath 的相对形式');
    });

    test('A 为空时回退 B，并把 B 的值搬进 A、删掉 B（一次性迁移）', () async {
      final (game, body) = await setupGame('收敛_回退B');
      final exe = p.join(body, 'game.exe');
      await GameConfigManager.instance.saveLaunchPath('收敛_回退B', exe);

      final resolved =
          await GameLaunchService.instance.resolveUserChoice('收敛_回退B');

      expect(resolved, isNotNull);
      expect(p.equals(resolved!, exe), isTrue);
      expect(game.launchPath.isNotEmpty, isTrue,
          reason: '★ 命中历史存储后必须把值搬进 game.json');
      expect(await GameConfigManager.instance.getLaunchPath('收敛_回退B'), isNull,
          reason: '★ 迁移完成后旧配置文件必须删除，否则又变成两份事实');
    });

    test('A / B 都为空时回退 C（prefs），同样搬进 A 并清掉 prefs', () async {
      final (game, body) = await setupGame('收敛_回退C');
      final exe = p.join(body, 'game.exe');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_exe_收敛_回退C', exe);

      final resolved =
          await GameLaunchService.instance.resolveUserChoice('收敛_回退C');

      expect(resolved, isNotNull);
      expect(p.equals(resolved!, exe), isTrue);
      expect(game.launchPath.isNotEmpty, isTrue);

      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.getString('default_exe_收敛_回退C'), isNull,
          reason: '★ 迁移完成后必须清掉 prefs 遗留键');
    });

    test('三处都没有 → 返回 null（调用方据此弹 exe 选择器）', () async {
      await setupGame('收敛_全空');
      final resolved =
          await GameLaunchService.instance.resolveUserChoice('收敛_全空');
      expect(resolved, isNull);
    });
  });

  group('P0-2 历史存储清理后不允许旧值复活', () {
    test('清空 launch_path 且历史存储已清 → 返回 null', () async {
      final (game, body) = await setupGame('收敛_不复活');
      final exe = p.join(body, 'game.exe');
      // 先让历史存储存在，触发一次迁移（迁移会把它删掉）
      await GameConfigManager.instance.saveLaunchPath('收敛_不复活', exe);
      await GameLaunchService.instance.resolveUserChoice('收敛_不复活');
      expect(game.launchPath.isNotEmpty, isTrue);

      // 用户主动清空启动路径（"我要重选"）
      await LocalGameRegistry.instance.updateLauncherPath('收敛_不复活', '');
      expect(game.launchPath, '');

      final resolved =
          await GameLaunchService.instance.resolveUserChoice('收敛_不复活');
      expect(resolved, isNull,
          reason: '★ 历史存储若还在，过期的 exe 会在这里被兜底复活');
    });
  });

  group('P0-2 persistUserChoice 只写唯一事实源', () {
    test('写 game.json，且不再产生新的历史记录', () async {
      final (game, body) = await setupGame('收敛_写入');
      final exe = p.join(body, 'game.exe');

      await GameLaunchService.instance.persistUserChoice('收敛_写入', exe);

      expect(game.launchPath.isNotEmpty, isTrue,
          reason: '★ 唯一事实源必须被写入');
      expect(await GameConfigManager.instance.getLaunchPath('收敛_写入'), isNull,
          reason: '★ 不应再写历史配置文件（旧实现会写三处）');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('default_exe_收敛_写入'), isNull,
          reason: '★ 不应再写 prefs（旧实现会写三处）');
    });

    test('写入会覆盖已有历史存储，避免旧值残留', () async {
      final (_ /*game*/, body) = await setupGame('收敛_写入清理');
      final exe = p.join(body, 'game.exe');
      await GameConfigManager.instance.saveLaunchPath('收敛_写入清理', exe);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_exe_收敛_写入清理', 'C:\\stale\\old.exe');

      await GameLaunchService.instance.persistUserChoice('收敛_写入清理', exe);

      expect(
          await GameConfigManager.instance.getLaunchPath('收敛_写入清理'), isNull);
      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.getString('default_exe_收敛_写入清理'), isNull);
    });
  });
}
