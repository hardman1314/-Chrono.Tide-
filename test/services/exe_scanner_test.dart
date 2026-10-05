// exe 扫描关键字误匹配完整路径回归测试（2026-09-13 用户实锤 bug）
//
// 背景：游戏目录名含 "Install Patch" 字样时（galgame 收藏极常见），
// ExeScanner.scanBounded / GameFolderScanner.detectLaunchExe /
// LocalGameRegistry.detectLaunchExe 把排除关键字（unins/install/setup/
// patch 等）对**完整路径**做 contains 匹配——目录名一命中就把目录下
// 所有 exe 全部滤光，启动管理弹窗显示「0 个程序 / 未找到可执行文件」。
//
// 本文件锁定修复后的行为：**排除/特征关键字只对文件名（路径最后一段）匹配**，
// 目录名含任何关键字都不再影响扫描结果。
//
// 路径隔离说明：与 import_data_safety_guard_test 同理，临时目录建在
// 项目内被 gitignore 的 `.dart_tool/` 下，且每次运行唯一
// （gal_game_detector_test 教训：固定路径会跨运行删除竞态）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/pages/join/utils/game_folder_scanner.dart';
import 'package:chrono_tide/services/exe_scanner.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

void main() {
  late Directory testRoot;

  /// 造文件：写入 [size] 字节，保证"最大体积"判定可区分
  Future<File> makeFile(Directory dir, String name, int size) {
    final f = File(p.join(dir.path, name));
    return f.writeAsBytes(List.filled(size, 0x61));
  }

  void makeFileSync(Directory dir, String name, int size) {
    File(p.join(dir.path, name)).writeAsBytesSync(List.filled(size, 0x61));
  }

  String baseNameOf(String path) => path.replaceAll('\\', '/').split('/').last;

  setUpAll(() {
    testRoot = Directory(p.join(
        '.dart_tool', 'exe_scanner_test_${DateTime.now().microsecondsSinceEpoch}'))
      ..createSync(recursive: true);
  });

  tearDownAll(() {
    try {
      testRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('ExeScanner.scanBounded（启动管理 / exe 选择弹窗）', () {
    test('目录名含 "Install Patch" 不再滤光所有 exe（用户实锤场景）', () async {
      final gameDir = Directory(p.join(testRoot.path,
              '[160325] [ensemble] 乙女が彩る恋のエッセンス + All Star Disk + Install Patch + Bonus'))
        ..createSync(recursive: true);
      await makeFile(gameDir, 'AdvHD.exe', 3000);
      await makeFile(gameDir, 'launcher.exe', 2000);
      await makeFile(gameDir, 'setup.exe', 100);
      await makeFile(gameDir, 'uninst.exe', 100);

      final result = await ExeScanner.scanBounded(gameDir);

      final names =
          result.map((f) => baseNameOf(f.path).toLowerCase()).toSet();
      expect(names, containsAll(['advhd.exe', 'launcher.exe']));
      expect(names, isNot(contains('setup.exe')));
      expect(names, isNot(contains('uninst.exe')));
    });

    test('文件名本身含关键字的 exe 仍被排除；子目录正常 exe 可见', () async {
      final gameDir = Directory(p.join(testRoot.path, 'NormalGame'))
        ..createSync(recursive: true);
      await makeFile(gameDir, 'game.exe', 1000);
      await makeFile(gameDir, 'setup.exe', 100);
      await makeFile(gameDir, 'uninst.exe', 100);
      await makeFile(gameDir, 'installer.exe', 100);
      final sub = Directory(p.join(gameDir.path, 'bin'))..createSync();
      await makeFile(sub, 'inner.exe', 500);

      final result = await ExeScanner.scanBounded(gameDir);

      final names =
          result.map((f) => baseNameOf(f.path).toLowerCase()).toSet();
      expect(names, {'game.exe', 'inner.exe'});
    });
  });

  group('GameFolderScanner.detectLaunchExe（智能导入 / 批量导入预选）', () {
    test('目录名含 "Install Patch" 仍能选出主程序（最大体积）', () {
      final gameDir = Directory(p.join(testRoot.path, 'Install Patch Bonus Collection'))
        ..createSync(recursive: true);
      makeFileSync(gameDir, 'setup.exe', 100);
      makeFileSync(gameDir, 'uninst.exe', 100);
      makeFileSync(gameDir, 'AdvHD.exe', 3000);

      final result = GameFolderScanner.detectLaunchExe(gameDir.path);

      expect(result, isNotNull);
      expect(result!.toLowerCase(), 'advhd.exe');
    });

    test('中文版优先只看文件名，目录名含中文不触发误选', () {
      // 旧逻辑（全路径匹配）：目录名含"中文" → 按列表顺序把第一个 exe
      // 当"中文版"返回（可能是 setup.exe）。新逻辑：目录名不影响，取最大体积。
      final gameDir = Directory(p.join(testRoot.path, '中文Gal合集'))
        ..createSync(recursive: true);
      makeFileSync(gameDir, 'setup.exe', 100);
      makeFileSync(gameDir, 'agame.exe', 100);
      makeFileSync(gameDir, 'zmain.exe', 3000);

      final result = GameFolderScanner.detectLaunchExe(gameDir.path);

      expect(result, isNotNull);
      expect(result!.toLowerCase(), 'zmain.exe');
    });

    test('文件名含"汉化"仍优先命中（文件名级匹配行为保留）', () {
      final gameDir = Directory(p.join(testRoot.path, 'CNGame'))
        ..createSync(recursive: true);
      makeFileSync(gameDir, 'game.exe', 3000);
      makeFileSync(gameDir, '汉化补丁.exe', 100);

      final result = GameFolderScanner.detectLaunchExe(gameDir.path);

      expect(result, isNotNull);
      expect(result!, '汉化补丁.exe');
    });
  });

  group('LocalGameRegistry.detectLaunchExe（注册表兜底检测）', () {
    test('目录名含 "Install Patch" 返回最大主程序而非空', () async {
      final gameDir = Directory(p.join(testRoot.path, '[160325] Install Patch Edition'))
        ..createSync(recursive: true);
      await makeFile(gameDir, 'setup.exe', 100);
      await makeFile(gameDir, 'uninst.exe', 100);
      await makeFile(gameDir, 'AdvHD.exe', 3000);

      final result = await LocalGameRegistry.detectLaunchExe(gameDir.path);

      expect(result, isNotNull);
      expect(result!.toLowerCase(), endsWith('advhd.exe'));
    });

    test('目录名含日文汉字不触发汉化误判（旧逻辑会选中字母序第一个 exe）', () async {
      final gameDir = Directory(p.join(testRoot.path, '乙女が彩る恋のエッセンス'))
        ..createSync(recursive: true);
      await makeFile(gameDir, 'a_main.exe', 100); // 旧逻辑：路径含汉字→误选它
      await makeFile(gameDir, 'z_main.exe', 3000); // 正确答案：最大体积

      final result = await LocalGameRegistry.detectLaunchExe(gameDir.path);

      expect(result, isNotNull);
      expect(result!.toLowerCase(), endsWith('z_main.exe'));
    });
  });
}
