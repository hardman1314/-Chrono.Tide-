// 智能导入板块 — GalGameDetector 识别算法测试
//
// 测试覆盖：
// 1. 强信号引擎识别（Kirikiri / Ren'Py / Unity / NScripter 等）
// 2. 中等信号组合识别（exe + 特征目录 + 脚本）
// 3. 弱信号与救援规则（CJK 目录名 + exe + 特征目录）
// 4. 负信号排除（系统目录 / 开发项目 / 通用目录名）
// 5. CJK 附属文件夹关键词排除（补丁 / 存档 / 汉化 / 特典 等）
// 6. 救援规则2：非 CJK 命名的便携式游戏识别
// 7. 边界条件（空目录 / 不存在路径 / 超大目录）

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chrono_tide/pages/join/utils/gal_game_detector.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    // 使用非系统路径作为临时目录，避免 AppData/Program Files 等
    // 系统路径关键词触发 _systemPatterns 负信号扣分。
    // ★ 批4 附带修复：原固定路径 `gal_detector_test_temp` 在连续两次运行间
    // 存在删除竞态（上一轮 tearDownAll 刚删完，下一轮 existsSync 仍返回 true
    // 但 deleteSync 报"系统找不到指定的路径"）→ 加时间戳后缀，每次运行唯一。
    final stamp = DateTime.now().millisecondsSinceEpoch;
    tempDir = Directory('D:\\gal_detector_test_temp_$stamp');
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    tempDir.createSync(recursive: true);
  });

  tearDownAll(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 创建测试用游戏目录结构
  Directory createGameDir(String name, Map<String, dynamic> structure) {
    final gameDir = Directory(p.join(tempDir.path, name));
    if (gameDir.existsSync()) gameDir.deleteSync(recursive: true);
    gameDir.createSync(recursive: true);

    for (final entry in structure.entries) {
      final path = p.join(gameDir.path, entry.key);
      if (entry.value is List) {
        final dir = Directory(path);
        dir.createSync(recursive: true);
        for (final fileName in entry.value as List) {
          File(p.join(dir.path, fileName)).writeAsStringSync('');
        }
      } else {
        File(path).writeAsStringSync(entry.value.toString());
      }
    }
    return gameDir;
  }

  group('GalGameDetector.detect - 强信号引擎识别', () {
    test('Kirikiri 引擎：data.xp3 + startup.tjs 应识别为游戏', () {
      final dir = createGameDir('kirikiri_game', {
        'data.xp3': 'fake xp3 data',
        'startup.tjs': 'script',
        'game.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true, reason: 'Kirikiri 引擎应有强信号');
      expect(result.engineType, 'kirikiri');
      expect(result.strongSignals, contains('kirikiri'));
      expect(result.confidence, greaterThan(0.3));
    });

    test('Ren\'Py 引擎：archive.rpa + .rpyc 应识别为游戏', () {
      final dir = createGameDir('renpy_game', {
        'archive.rpa': 'data',
        'script.rpyc': 'compiled script',
        'game.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true, reason: 'Ren\'Py 引擎应有强信号');
      expect(result.engineType, 'renpy');
    });

    test('Unity 引擎：UnityPlayer.dll 应识别为游戏', () {
      final dir = createGameDir('unity_gal', {
        'UnityPlayer.dll': 'dll',
        'Assembly-CSharp.dll': 'dll',
        'game.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true, reason: 'Unity 引擎应有强信号');
      expect(result.engineType, 'unity');
    });

    test('NScripter 引擎：arc.nsa + nss.npa 应识别为游戏', () {
      final dir = createGameDir('nscripter_game', {
        'arc.nsa': 'data',
        'nss.npa': 'data',
        'game.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true);
      expect(result.engineType, 'nscripter');
    });

    test('SiglusEngine 应识别为游戏', () {
      final dir = createGameDir('siglus_game', {
        'siglusengine.exe': 'exe',
        'data.pck': 'data',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true);
      expect(result.engineType, 'siglus');
    });
  });

  group('GalGameDetector.detect - 救援规则', () {
    test('救援规则1：CJK目录名 + exe + 特征目录（无强信号）应识别为游戏', () {
      final dir = createGameDir('命运石之门', {
        'game.exe': 'exe',
        'data': ['config.ini'],
        'sound': ['bgm01.ogg'],
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true, reason: 'CJK名+exe+特征目录应触发救援规则1');
    });

    test('救援规则2：非CJK目录名 + exe + 2个特征目录应识别为游戏', () {
      final dir = createGameDir('Kanon', {
        'game.exe': 'exe',
        'data': ['config.ini'],
        'sound': ['bgm01.ogg'],
        'script': ['scene01.txt'],
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true, reason: '非CJK名+exe+多个特征目录应触发救援规则2');
    });

    test('无强信号且无exe应判定为非游戏', () {
      final dir = createGameDir('some_folder', {
        'readme.txt': 'readme',
        'data': ['info.txt'],
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, false, reason: '无exe无强信号不应识别为游戏');
    });
  });

  group('GalGameDetector.detect - 负信号排除', () {
    test('系统目录路径应被排除', () {
      final dir = createGameDir('test_in_system', {
        'data.xp3': 'data',
        'game.exe': 'exe',
      });
      // 在路径中注入系统目录名
      final systemPath = p.join(dir.parent.path, 'Windows', 'test_game');
      final systemDir = Directory(systemPath);
      if (systemDir.existsSync()) systemDir.deleteSync(recursive: true);
      systemDir.createSync(recursive: true);
      File(p.join(systemDir.path, 'data.xp3')).writeAsStringSync('data');
      File(p.join(systemDir.path, 'game.exe')).writeAsStringSync('exe');

      final result = GalGameDetector.detect(systemDir.path);
      expect(result.negativeSignals.any((s) => s.startsWith('系统路径')),
          true,
          reason: '系统路径应触发负信号');
      systemDir.deleteSync(recursive: true);
    });

    test('开发项目标记文件应被排除', () {
      final dir = createGameDir('dev_project', {
        'package.json': '{"name":"test"}',
        'game.exe': 'exe',
        'data.xp3': 'data',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals.any((s) => s.startsWith('项目标记')),
          true,
          reason: 'package.json应触发项目标记负信号');
    });

    test('通用目录名应被扣分', () {
      final dir = createGameDir('temp', {
        'game.exe': 'exe',
        'data': ['file.txt'],
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'));
    });
  });

  group('GalGameDetector.detect - CJK 附属文件夹排除', () {
    test('含"补丁"关键词应被扣分', () {
      final dir = createGameDir('汉化补丁', {
        'patch.exe': 'exe',
        'data': ['file.txt'],
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'),
          reason: '"补丁"应触发CJK通用目录名扣分');
    });

    test('含"存档"关键词应被扣分', () {
      final dir = createGameDir('全CG存档', {
        'save.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'));
    });

    test('含"特典"关键词应被扣分', () {
      final dir = createGameDir('予約特典', {
        'bonus.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'),
          reason: '扩展CJK关键词"特典"应触发扣分');
    });

    test('含"攻略"关键词应被扣分', () {
      final dir = createGameDir('攻略集', {
        'guide.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'),
          reason: '扩展CJK关键词"攻略"应触发扣分');
    });

    test('含"おまけ"关键词应被扣分', () {
      final dir = createGameDir('おまけ集', {
        'bonus.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.negativeSignals, contains('通用目录名'),
          reason: '扩展CJK关键词"おまけ"应触发扣分');
    });
  });

  group('GalGameDetector.detect - 边界条件', () {
    test('不存在的路径应返回 isGame=false', () {
      final result = GalGameDetector.detect('Z:\\nonexistent\\path\\game');
      expect(result.isGame, false);
      expect(result.confidence, 0.0);
      expect(result.negativeSignals, contains('目录不存在'));
    });

    test('空目录应判定为非游戏', () {
      final dir = Directory(p.join(tempDir.path, 'empty_dir'));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync();
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, false, reason: '空目录不应识别为游戏');
    });

    test('只有 readme 的目录应判定为非游戏', () {
      final dir = createGameDir('readme_only', {
        'readme.txt': 'This is a readme',
        'manual.pdf': 'manual',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, false);
    });

    test('exe 排除关键词：uninstall.exe 不应作为 mainExe', () {
      final dir = createGameDir('game_with_uninstaller', {
        'data.xp3': 'data',
        'startup.tjs': 'script',
        'uninstall.exe': 'uninstaller',
        'game.exe': 'real game exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.isGame, true);
      expect(result.mainExeName, 'game.exe',
          reason: 'uninstall.exe应被排除，mainExe应为game.exe');
    });

    test('exe 排除关键词：汉化补丁.exe 不应作为 mainExe', () {
      final dir = createGameDir('game_with_patch', {
        'data.xp3': 'data',
        'startup.tjs': 'script',
        '汉化补丁.exe': 'patch exe',
        'game.exe': 'real game exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.mainExeName, 'game.exe',
          reason: '汉化补丁.exe应被排除');
    });
  });

  group('GalGameDetector.detect - reasonSummary', () {
    test('reasonSummary 应包含命中信号描述', () {
      final dir = createGameDir('kirikiri_test', {
        'data.xp3': 'data',
        'startup.tjs': 'script',
        'game.exe': 'exe',
      });
      final result = GalGameDetector.detect(dir.path);
      expect(result.reasonSummary, isNotEmpty);
      expect(result.reasonSummary, contains('强:'));
    });

    test('空目录的 reasonSummary 应包含负信号描述', () {
      final dir = Directory(p.join(tempDir.path, 'featureless'));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync();
      final result = GalGameDetector.detect(dir.path);
      // 空目录会触发"无可执行文件"负信号，reasonSummary 应反映此情况
      expect(result.reasonSummary, isNotEmpty);
      expect(result.reasonSummary, contains('负信号'));
    });
  });

  // ===== 直接签名 vs 继承信号（容器文件夹拦截核心测试）=====
  //
  // 这些测试验证直接签名门控：容器文件夹（GAL/JRPG 等仅存放游戏的文件夹）
  // 不应被识别为游戏，即使其子目录中的游戏引擎文件被 2 层扫描继承收集到。
  // 真实游戏本体（直接含 exe / 引擎核心文件）应被正确识别。

  group('GalGameDetector.detect - 容器文件夹拦截（直接签名门控）', () {
    test('容器文件夹（子目录含游戏）不应识别为游戏', () {
      // 模拟 E:\GAL 结构：GAL 下有多个游戏子目录
      final container = createGameDir('GAL_container', {
        '游戏A': ['game.exe', 'data.xp3'],
        '游戏B': ['game.exe', 'data.xp3'],
      });
      final result = GalGameDetector.detect(container.path);
      expect(result.isGame, false,
          reason: '容器文件夹（GAL）本身无直接游戏签名，不应识别为游戏');
      expect(result.hasDirectSignature, false,
          reason: '容器无直接 exe/引擎文件/数据包');
      expect(result.negativeSignals.any((s) => s.contains('无直接签名')), true,
          reason: '应标注"无直接签名(容器)"负信号');
    });

    test('JRPG 分类容器（子目录含游戏）不应识别为游戏', () {
      // 模拟 E:\GAL\JRPG 结构：JRPG 是分类文件夹，内含多个游戏
      final container = createGameDir('JRPG_container', {
        '命运石之门': ['game.exe', 'data.xp3', 'startup.tjs'],
        '月姬': ['game.exe', 'arc.nsa'],
      });
      final result = GalGameDetector.detect(container.path);
      expect(result.isGame, false,
          reason: 'JRPG 分类容器不应识别为游戏');
      expect(result.hasDirectSignature, false);
      // 继承信号仍存在（用于引擎类型推断），但不构成 isGame
      expect(result.strongSignals, isNotEmpty,
          reason: '继承的引擎强信号仍应被收集（供引擎类型推断）');
    });

    test('真实游戏本体（直接含 exe + 引擎文件）应识别为游戏', () {
      final game = createGameDir('命运石之门', {
        'game.exe': 'exe',
        'data.xp3': 'data',
        'startup.tjs': 'script',
      });
      final result = GalGameDetector.detect(game.path);
      expect(result.isGame, true, reason: '直接含 exe + 引擎文件应识别为游戏');
      expect(result.hasDirectStrongSignal, true,
          reason: 'data.xp3 直接位于本文件夹 → 直接强信号');
      expect(result.hasDirectExe, true,
          reason: 'game.exe 直接位于本文件夹 → 直接 exe');
      expect(result.hasDirectSignature, true);
    });

    test('直接签名字段应正确区分直接 vs 继承内容', () {
      // 游戏本体：直接含 exe + 数据包 + 特征目录
      final game = createGameDir('direct_signature_test', {
        'game.exe': 'exe',
        'data.xp3': 'data',
        'data': ['config.ini'],
        'sound': ['bgm01.ogg'],
      });
      final result = GalGameDetector.detect(game.path);
      expect(result.hasDirectExe, true);
      expect(result.hasDirectStrongSignal, true, reason: 'data.xp3 直接存在');
      expect(result.hasDirectDataPack, true, reason: 'data.xp3 是直接数据包');
      expect(result.hasDirectFeatureDir, true, reason: 'data/ 是直接特征目录');
      expect(result.mainExeInherited, false,
          reason: 'mainExe 来自直接 exe，非继承');
    });

    test('exe 在子目录（bin/）→ 父目录 isGame=false 但有继承 exe（供救援）', () {
      // 模拟"命运石之门/bin/game.exe"结构
      // 直接签名门控使父目录 isGame=false，但 mainExeName 应来自继承
      // （供批量导入阶段 2.5 包装文件夹救援使用）
      final game = createGameDir('包装游戏', {
        'bin': ['game.exe'],
      });
      final result = GalGameDetector.detect(game.path);
      expect(result.isGame, false,
          reason: '父目录无直接签名，不应识别为游戏');
      expect(result.hasDirectExe, false, reason: 'exe 在 bin/ 子目录，非直接');
      expect(result.hasDirectSignature, false);
      expect(result.mainExeName, 'game.exe',
          reason: '应继承子目录 exe 作为 mainExeName（供救援）');
      expect(result.mainExeInherited, true,
          reason: 'mainExe 来自子目录，应标记为继承');
    });

    test('空容器（无任何子目录内容）不应识别为游戏', () {
      final container = Directory(p.join(tempDir.path, 'empty_container'));
      if (container.existsSync()) container.deleteSync(recursive: true);
      container.createSync();
      // 创建空子目录
      Directory(p.join(container.path, 'sub1')).createSync();
      Directory(p.join(container.path, 'sub2')).createSync();
      final result = GalGameDetector.detect(container.path);
      expect(result.isGame, false, reason: '空容器不应识别为游戏');
      expect(result.hasDirectSignature, false);
      expect(result.mainExeName, null, reason: '无 exe（含继承）');
    });

    test('深层嵌套：GAL/JRPG/系列/游戏A 各级容器拦截 + 最内层游戏识别', () {
      // 模拟用户实际场景：E:\GAL\JRPG\系列\游戏A
      // GAL、JRPG、系列 都是容器，游戏A 是真实游戏
      final root = Directory(p.join(tempDir.path, 'deep_nest'));
      if (root.existsSync()) root.deleteSync(recursive: true);
      root.createSync(recursive: true);

      // 构建嵌套结构
      final gal = Directory(p.join(root.path, 'GAL'));
      final jrpg = Directory(p.join(gal.path, 'JRPG'));
      final series = Directory(p.join(jrpg.path, '系列'));
      final gameA = Directory(p.join(series.path, '游戏A'));
      for (final d in [gal, jrpg, series, gameA]) {
        d.createSync(recursive: true);
      }
      // 游戏A 含直接游戏文件
      File(p.join(gameA.path, 'game.exe')).writeAsStringSync('exe');
      File(p.join(gameA.path, 'data.xp3')).writeAsStringSync('data');
      File(p.join(gameA.path, 'startup.tjs')).writeAsStringSync('script');

      // 各级容器不应识别为游戏
      for (final containerPath in [gal.path, jrpg.path, series.path]) {
        final name = p.basename(containerPath);
        final result = GalGameDetector.detect(containerPath);
        expect(result.isGame, false, reason: '容器 "$name" 不应识别为游戏');
        expect(result.hasDirectSignature, false,
            reason: '容器 "$name" 无直接签名');
      }

      // 最内层游戏A 应识别为游戏
      final gameResult = GalGameDetector.detect(gameA.path);
      expect(gameResult.isGame, true, reason: '游戏A 应识别为游戏');
      expect(gameResult.hasDirectStrongSignal, true);
      expect(gameResult.hasDirectExe, true);
    });

    test('classify: 容器文件夹返回 container 分类', () {
      final container = createGameDir('classify_container', {
        '游戏A': ['game.exe', 'data.xp3'],
        '游戏B': ['game.exe', 'data.xp3'],
      });
      final classification = GalGameDetector.classify(container.path);
      expect(classification, FolderClassification.container,
          reason: '含游戏子目录但无直接签名的文件夹应分类为 container');
    });

    test('classify: 真实游戏返回 game 分类', () {
      final game = createGameDir('classify_game', {
        'game.exe': 'exe',
        'data.xp3': 'data',
      });
      final classification = GalGameDetector.classify(game.path);
      expect(classification, FolderClassification.game);
    });
  });

  group('GalGameDetector.detect - IMP-19 系统路径按分段精确匹配', () {
    test('父目录名含 origin（如 Original）不应触发系统路径负信号', () {
      final gameRoot = Directory(p.join(tempDir.path, 'Original'));
      if (gameRoot.existsSync()) gameRoot.deleteSync(recursive: true);
      gameRoot.createSync(recursive: true);
      final gameDir = Directory(p.join(gameRoot.path, 'MyGame'))
        ..createSync(recursive: true);
      File(p.join(gameDir.path, 'data.xp3')).writeAsStringSync('data');
      File(p.join(gameDir.path, 'game.exe')).writeAsStringSync('exe');

      final result = GalGameDetector.detect(gameDir.path);

      expect(
        result.negativeSignals.where((s) => s.contains('origin')).toList(),
        isEmpty,
        reason: '★ 旧实现用整条路径 contains("origin")，会把 Original 误记为系统路径',
      );
      gameRoot.deleteSync(recursive: true);
    });

    test('路径分段恰好为系统目录名时仍应触发负信号（行为不回退）', () {
      final sysRoot = Directory(p.join(tempDir.path, 'Windows'));
      if (sysRoot.existsSync()) sysRoot.deleteSync(recursive: true);
      sysRoot.createSync(recursive: true);
      final gameDir = Directory(p.join(sysRoot.path, 'MyGame'))
        ..createSync(recursive: true);
      File(p.join(gameDir.path, 'data.xp3')).writeAsStringSync('data');
      File(p.join(gameDir.path, 'game.exe')).writeAsStringSync('exe');

      final result = GalGameDetector.detect(gameDir.path);

      expect(
        result.negativeSignals.any((s) => s.startsWith('系统路径')),
        isTrue,
        reason: '真正的系统目录分段仍应命中（负信号排除能力不回退）',
      );
      sysRoot.deleteSync(recursive: true);
    });
  });
}
