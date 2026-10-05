// 收藏夹内独立排序（`GameCollection.gameOrder`）· Phase 0 技术验证
//
// 覆盖需求（方案文档 §3.2 / §5）：
// 1. `game_order` 往返序列化保真；
// 2. 老数据缺字段 → 读作空列表，**不需要迁移**；
// 3. 与既有 pinned 三级排序 + `_save()` 内的规整共存，互不踩踏；
// 4. 任意写入路径（重命名/新建）落盘后 `game_order` 不丢。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/collection_service.dart';

Directory? _tmpRoot;

String get _collectionsFile =>
    '${PathHelper.dataDir}${Platform.pathSeparator}collections.json';

/// 两份历史数据：一份已带 `game_order`，一份是完全没有该字段的老数据
String _legacyJson() {
  return jsonEncode({
    'format_version': 1,
    'mark_migrated': true,
    'collections': [
      {
        'id': 'c_ordered',
        'name': '已排序夹',
        'color': 0xFF67A86B,
        'sort_order': 0,
        'game_order': [r'D:\GAL\A', r'D:\GAL\B', r'D:\GAL\C'],
      },
      {
        'id': 'c_legacy',
        'name': '老数据夹',
        'color': 0xFF4A90D9,
        'sort_order': 1,
        // 刻意不写 game_order：验证缺字段读取
      },
    ],
  });
}

Future<List<GameCollection>> _readStored() async {
  final content = await File(_collectionsFile).readAsString();
  final data = jsonDecode(content) as Map<String, dynamic>;
  return (data['collections'] as List)
      .map((e) => GameCollection.fromJson(e as Map<String, dynamic>))
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_collection_order');
    PathHelper.exeDirOverride = _tmpRoot!.path;
    await Directory(PathHelper.dataDir).create(recursive: true);
    await File(_collectionsFile).writeAsString(_legacyJson());
    await CollectionService.instance.load();
  });

  tearDownAll(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  group('T0-1 序列化', () {
    test('往返保真：gameOrder 原样保留', () {
      final origin = GameCollection(
        id: 'c_rt',
        name: '往返',
        colorValue: 0xFFE05252,
        gameOrder: [r'D:\GAL\X', r'D:\GAL\Y'],
      );
      final restored = GameCollection.fromJson(origin.toJson());
      expect(restored.gameOrder, [r'D:\GAL\X', r'D:\GAL\Y']);
    });

    test('老数据缺 game_order：读作空列表且不抛异常', () {
      final legacy = GameCollection.fromJson({
        'id': 'c_old',
        'name': '老夹',
        'color': 0xFF4A90D9,
        'sort_order': 3,
      });
      expect(legacy.gameOrder, isEmpty);
      expect(legacy.name, '老夹');
      expect(legacy.sortOrder, 3);
    });

    test('读到的是可写列表（非 const），不会因后续写入抛错', () {
      final legacy = GameCollection.fromJson({'id': 'c_x', 'name': 'X'});
      expect(() => legacy.gameOrder.add(r'D:\GAL\Z'), returnsNormally);
    });
  });

  group('T0-1 加载与规整共存', () {
    test('带 game_order 的收藏夹按原顺序读出，缺字段的为空', () {
      final list = CollectionService.instance.collections;
      final ordered = list.firstWhere((c) => c.id == 'c_ordered');
      final legacy = list.firstWhere((c) => c.id == 'c_legacy');
      expect(ordered.gameOrder, [r'D:\GAL\A', r'D:\GAL\B', r'D:\GAL\C']);
      expect(legacy.gameOrder, isEmpty);
    });

    test('重命名触发 _save 后，game_order 与 pinned 规整互不影响', () async {
      await CollectionService.instance.rename('c_ordered', '已排序夹（改名）');
      final stored = await _readStored();

      final ordered = stored.firstWhere((c) => c.id == 'c_ordered');
      expect(ordered.name, '已排序夹（改名）', reason: '重命名应落盘');
      expect(ordered.gameOrder, [r'D:\GAL\A', r'D:\GAL\B', r'D:\GAL\C'],
          reason: '_save() 内的 pinned 规整与 sortForDisplay 重排不得丢掉成员顺序');

      // 预设收藏夹仍稳居前两位（ADR-003 不受本次改动影响）
      expect(stored[0].id, CollectionService.kPresetWishlistId);
      expect(stored[1].id, CollectionService.kPresetStarredId);
    });

    test('新建收藏夹默认空顺序，且不影响既有收藏夹的顺序字段', () async {
      final created =
          await CollectionService.instance.create('T0-1 新建夹', 0xFFE05252);
      expect(created.gameOrder, isEmpty);

      final stored = await _readStored();
      final ordered = stored.firstWhere((c) => c.id == 'c_ordered');
      expect(ordered.gameOrder, [r'D:\GAL\A', r'D:\GAL\B', r'D:\GAL\C']);
    });
  });

  group('Phase 3 收藏夹内顺序 API', () {
    test('setGameOrder 写入并落盘可读回', () async {
      await CollectionService.instance
          .setGameOrder('c_ordered', ['B', 'C', 'A']);
      expect(CollectionService.instance.byId('c_ordered')!.gameOrder,
          ['B', 'C', 'A']);
      final stored = await _readStored();
      expect(stored.firstWhere((c) => c.id == 'c_ordered').gameOrder,
          ['B', 'C', 'A']);
    });

    test('setGameOrder 清洗空串与重复键（保留首次位置）', () async {
      await CollectionService.instance
          .setGameOrder('c_ordered', ['', 'B', 'B', 'A', '']);
      expect(
          CollectionService.instance.byId('c_ordered')!.gameOrder, ['B', 'A']);
    });

    test('pruneGameOrder 清掉失效键并保留其余相对顺序', () async {
      await CollectionService.instance
          .setGameOrder('c_ordered', ['A', 'B', 'C', 'D']);
      await CollectionService.instance.pruneGameOrder('c_ordered', {'B', 'D'});
      expect(
          CollectionService.instance.byId('c_ordered')!.gameOrder, ['B', 'D']);
    });

    test('pruneGameOrder 无失效键时不改动（幂等）', () async {
      final before = List<String>.from(
          CollectionService.instance.byId('c_ordered')!.gameOrder);
      await CollectionService.instance
          .pruneGameOrder('c_ordered', {'B', 'D', 'X'});
      expect(CollectionService.instance.byId('c_ordered')!.gameOrder, before);
    });

    test('裁剪集合为空 → 自定顺序被清空（成员全部移出收藏夹）', () async {
      await CollectionService.instance.pruneGameOrder('c_ordered', <String>{});
      expect(CollectionService.instance.byId('c_ordered')!.gameOrder, isEmpty);
    });

    test('resetGameOrder 清空自定顺序并落盘', () async {
      await CollectionService.instance.setGameOrder('c_ordered', ['A', 'B']);
      await CollectionService.instance.resetGameOrder('c_ordered');
      expect(CollectionService.instance.byId('c_ordered')!.gameOrder, isEmpty);
      final stored = await _readStored();
      expect(stored.firstWhere((c) => c.id == 'c_ordered').gameOrder, isEmpty);
    });

    test('对不存在的收藏夹操作是安全的 no-op', () async {
      await CollectionService.instance.setGameOrder('c_not_exist', ['A']);
      await CollectionService.instance.resetGameOrder('c_not_exist');
      await CollectionService.instance.pruneGameOrder('c_not_exist', {'A'});
      expect(CollectionService.instance.byId('c_not_exist'), isNull);
    });
  });
}
