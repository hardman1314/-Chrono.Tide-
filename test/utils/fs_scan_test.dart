// 流式文件遍历辅助回归测试（★ P0-7，2026-09-16 稳定性审计）
//
// 旧实现 `list(recursive: true).toList()` 在大目录（几十万~百万条目）上会
// 一次性物化全部实体 → 数百 MB~GB 内存 → OOM 崩溃。本测试验证流式实现的
// 语义与原实现等价（计数 / 存在性 / 有界收集）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/utils/fs_scan.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp
        .createTempSync('ct_fs_scan_${DateTime.now().microsecondsSinceEpoch}');
    // 结构：root/a.txt, root/sub/b.exe, root/sub/deep/c.xp3, root/empty/
    File(p.join(root.path, 'a.txt')).writeAsStringSync('a');
    final sub = Directory(p.join(root.path, 'sub'))..createSync();
    File(p.join(sub.path, 'b.exe')).writeAsStringSync('b');
    final deep = Directory(p.join(sub.path, 'deep'))..createSync();
    File(p.join(deep.path, 'c.xp3')).writeAsStringSync('c');
    Directory(p.join(root.path, 'empty')).createSync();
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('countRecursive 统计文件与目录数（含空目录）', () async {
    final result = await FsScan.countRecursive(root);
    expect(result.files, 3);
    expect(result.dirs, 3, reason: 'sub / sub\deep / empty');
  });

  test('containsFile 命中深层文件（找到即中断）', () async {
    expect(await FsScan.containsFile(root, (p) => p.endsWith('.xp3')), isTrue);
    expect(await FsScan.containsFile(root, (p) => p.endsWith('.ctgame')),
        isFalse);
  });

  test('collectFilePaths 受上限约束', () async {
    final all = await FsScan.collectFilePaths(root, test: (_) => true);
    expect(all.length, 3);

    final limited =
        await FsScan.collectFilePaths(root, test: (p) => p.endsWith('.exe'), limit: 1);
    expect(limited.length, 1);
    expect(limited.single.endsWith('.exe'), isTrue);

    final none = await FsScan.collectFilePaths(root, test: (_) => true, limit: 0);
    expect(none, isEmpty);
  });

  test('目录不存在时静默返回空/假值（不抛错）', () async {
    final missing = Directory(p.join(root.path, 'not_exists'));
    expect((await FsScan.countRecursive(missing)).files, 0);
    expect(await FsScan.containsFile(missing, (_) => true), isFalse);
    expect(await FsScan.collectFilePaths(missing, test: (_) => true), isEmpty);
  });
}
