// NSFW 判定缓存的容量/过期治理回归测试（P1-4）
//
// 背景：`docs/DEV/tickets/2026-09-17-game-data-schema-audit.md` P1-4。
// 旧实现的 `_items` **无上限、无过期、无按目录清理**：
// 1000 游戏 × 6 张截图 ≈ 6000 条全部常驻内存并整表落盘，
// 删除游戏后记录仍是孤儿，文件只增不减。
//
// 本文件锁定三条治理能力：
//   1. 过期淘汰 —— detectedAtMs 超过 maxAge 的条目在 load 时被丢弃；
//   2. 容量淘汰 —— 超过 maxItems 时按判定时间淘汰最旧的；
//   3. 按目录清理 —— 删游戏时清掉该目录下的记录，且**前缀必须落在分隔符边界**。
//
// ⚠️ 与既有 `nsfw_detection_store_test.dart` 的分工：那个文件守的是
// 「双键写入」这条 v1 P0 bug 的纪律，本文件只守容量治理，互不重叠。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_store.dart';

const String _sig = 'censor_detect_v1.0_n/640/0.2';

NsfwDetection _det({int atMs = 1700000000000, int imgW = 800, int imgH = 600}) =>
    NsfwDetection(imgW: imgW, imgH: imgH, detectedAtMs: atMs, boxes: const []);

void main() {
  late Directory tmpRoot;
  late File cacheFile;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ct_nsfw_retention_');
    PathHelper.exeDirOverride = tmpRoot.path;
    NsfwDetectionStore.resetForTest();
    cacheFile = File(PathHelper.nsfwDetectionsFilePath);
  });

  tearDown(() async {
    NsfwDetectionStore.resetForTest();
    PathHelper.exeDirOverride = null;
    if (await tmpRoot.exists()) {
      try {
        await tmpRoot.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> writeCache(Map<String, NsfwDetection> items) async {
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsString(jsonEncode(<String, dynamic>{
      'model_ver': _sig,
      'items': <String, dynamic>{
        for (final e in items.entries) e.key: e.value.toJson(),
      },
    }));
  }

  group('P1-4 过期淘汰', () {
    test('load 时丢弃超过 maxAge 的条目，保留新鲜条目', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int expired =
          now - NsfwDetectionStore.maxAge.inMilliseconds - 86400000; // 多一天
      await writeCache(<String, NsfwDetection>{
        'C;\\games\\old\\cover.png': _det(atMs: expired),
        'C;\\games\\new\\cover.png': _det(atMs: now),
        'C;\\games\\new2\\cover.png': _det(atMs: now - 86400000), // 一天前
      });

      final store = NsfwDetectionStore.instance;
      await store.load(_sig);

      expect(store.count, 2, reason: '过期条目必须被丢弃');
      expect(store.has('C;\\games\\old\\cover.png'), isFalse);
      expect(store.has('C;\\games\\new\\cover.png'), isTrue);
      expect(store.lastPrunedCount, 1);
    });

    test('detectedAtMs == 0 的老数据不参与过期淘汰（避免升级即整批误删）', () async {
      await writeCache(<String, NsfwDetection>{
        'C;\\games\\legacy\\cover.png': _det(atMs: 0),
      });

      final store = NsfwDetectionStore.instance;
      await store.load(_sig);

      expect(store.count, 1,
          reason: '时间戳为 0 = 不可判定，应保留而不是当成"极旧"删掉');
    });

    test('淘汰结果会落盘（flush 后文件里不再有过期项）', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await writeCache(<String, NsfwDetection>{
        'C;\\games\\old\\cover.png': _det(
            atMs: now - NsfwDetectionStore.maxAge.inMilliseconds - 1000),
        'C;\\games\\new\\cover.png': _det(atMs: now),
      });

      final store = NsfwDetectionStore.instance;
      await store.load(_sig);
      // load 已置脏，直接落盘
      await store.flush();

      final onDisk = jsonDecode(await cacheFile.readAsString())
          as Map<String, dynamic>;
      final items = onDisk['items'] as Map<String, dynamic>;
      expect(items.length, 1);
      expect(items.containsKey('C;\\games\\new\\cover.png'), isTrue);
    });
  });

  group('P1-4 容量淘汰', () {
    test('超过 maxItems 时按判定时间淘汰最旧的', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      const int overflow = 3;
      final items = <String, NsfwDetection>{};
      for (int i = 0; i < NsfwDetectionStore.maxItems + overflow; i++) {
        // 时间递增：key 越小越旧
        items['C;\\games\\g$i\\cover.png'] = _det(atMs: now - 100000 + i);
      }
      await writeCache(items);

      final store = NsfwDetectionStore.instance;
      await store.load(_sig);

      expect(store.count, NsfwDetectionStore.maxItems,
          reason: '★ 缓存必须收敛到上限，这是"文件大小有上界"的依据');
      // 最旧的 3 条（g0 / g1 / g2）应被淘汰，最新的必须还在
      expect(store.has('C;\\games\\g0\\cover.png'), isFalse);
      expect(store.has('C;\\games\\g2\\cover.png'), isFalse);
      expect(
          store.has('C;\\games\\g${NsfwDetectionStore.maxItems + overflow - 1}'
              '\\cover.png'),
          isTrue);
    });
  });

  group('P1-4 按游戏目录清理', () {
    test('只删该目录下的记录', () async {
      final store = NsfwDetectionStore.instance;
      store.seedForTest(_sig, <String, NsfwDetection>{
        NsfwDetectionStore.keyForFile('C:\\Games\\Alpha\\cover.png'): _det(),
        NsfwDetectionStore.keyForFile('C:\\Games\\Alpha\\shot1.png'): _det(),
        NsfwDetectionStore.keyForFile('C:\\Games\\Beta\\cover.png'): _det(),
      });

      final removed = store.removeUnderDirectory('C:\\Games\\Alpha');

      expect(removed, 2);
      expect(store.has(NsfwDetectionStore.keyForFile('C:\\Games\\Alpha\\cover.png')),
          isFalse);
      expect(store.has(NsfwDetectionStore.keyForFile('C:\\Games\\Beta\\cover.png')),
          isTrue);
    });

    test('★ 前缀必须落在分隔符边界，不能误伤同名前缀的兄弟目录', () async {
      final store = NsfwDetectionStore.instance;
      store.seedForTest(_sig, <String, NsfwDetection>{
        NsfwDetectionStore.keyForFile('C:\\Games\\A\\cover.png'): _det(),
        // 目录名以 "A" 开头但不是同一个目录
        NsfwDetectionStore.keyForFile('C:\\Games\\AB\\cover.png'): _det(),
      });

      final removed = store.removeUnderDirectory('C:\\Games\\A');

      expect(removed, 1, reason: '★ 朴素 startsWith 会连 AB 一起删掉');
      expect(store.has(NsfwDetectionStore.keyForFile('C:\\Games\\AB\\cover.png')),
          isTrue);
    });

    test('空路径 / 无匹配时是安全的空操作', () async {
      final store = NsfwDetectionStore.instance;
      store.seedForTest(_sig, <String, NsfwDetection>{
        NsfwDetectionStore.keyForFile('C:\\Games\\Alpha\\cover.png'): _det(),
      });

      expect(store.removeUnderDirectory(''), 0);
      expect(store.removeUnderDirectory('D:\\Nowhere'), 0);
      expect(store.count, 1);
    });
  });
}
