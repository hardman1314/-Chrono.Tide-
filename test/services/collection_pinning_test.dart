// 收藏夹置顶（准备入手 / 特别关注）单元测试
//
// 覆盖需求：
// 1. 两个预设收藏夹恒定置顶
// 2. 新增 / 删除 / 重命名其他收藏夹后，置顶位置不变
// 3. 历史脏数据（序号被普通收藏夹占用、缺 pinned 标记）能被自动纠正
// 4. 置顶状态会持久化到 collections.json

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/collection_service.dart';

Directory? _tmpRoot;

String get _collectionsFile =>
    '${PathHelper.dataDir}${Platform.pathSeparator}collections.json';

/// 构造一份"脏"历史数据：
/// - 两个预设收藏夹缺少 pinned 标记，且序号被挤到 5 / 7
/// - 普通收藏夹抢占了序号 0 / 1（升级前删除过预设时会真实出现）
String _dirtyLegacyJson() {
  return jsonEncode({
    'format_version': 1,
    'mark_migrated': true,
    'collections': [
      {'id': 'c_legacy_a', 'name': '通关记录', 'color': 0xFF67A86B, 'sort_order': 0},
      {'id': 'c_legacy_b', 'name': '想补票', 'color': 0xFF4A90D9, 'sort_order': 1},
      {
        'id': CollectionService.kPresetWishlistId,
        'name': '准备入手',
        'color': 0xFF2F3437,
        'sort_order': 5,
        'icon': GameCollection.kIconGamepad,
      },
      {
        'id': CollectionService.kPresetStarredId,
        'name': '特别关注',
        'color': 0xFFD9A514,
        'sort_order': 7,
        'icon': GameCollection.kIconStar,
      },
      {'id': 'c_legacy_c', 'name': '汉化待补', 'color': 0xFFC75B9E, 'sort_order': 2},
    ],
  });
}

/// 断言前两个收藏夹恒为「准备入手」「特别关注」
void _expectPresetOnTop(List<GameCollection> list) {
  expect(list.length, greaterThanOrEqualTo(2), reason: '应至少包含两个预设收藏夹');
  expect(list[0].id, CollectionService.kPresetWishlistId,
      reason: '第一位必须是「准备入手」');
  expect(list[1].id, CollectionService.kPresetStarredId,
      reason: '第二位必须是「特别关注」');
  expect(list[0].isPinnedTop, isTrue);
  expect(list[1].isPinnedTop, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_collections_test');
    PathHelper.exeDirOverride = _tmpRoot!.path;
    // 预置脏历史数据，验证加载阶段的自动纠正
    await Directory(PathHelper.dataDir).create(recursive: true);
    await File(_collectionsFile).writeAsString(_dirtyLegacyJson());
    await CollectionService.instance.load();
  });

  tearDownAll(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  test('加载脏历史数据后，预设收藏夹自动回到置顶前两位', () {
    expect(CollectionService.instance.loadFailed, isFalse,
        reason: '收藏夹加载不应失败');
    final list = CollectionService.instance.collections;
    _expectPresetOnTop(list);
    // 普通收藏夹保留原有相对顺序：通关记录 → 想补票 → 汉化待补
    expect(
      list.skip(2).map((c) => c.id).toList(),
      ['c_legacy_a', 'c_legacy_b', 'c_legacy_c'],
      reason: '普通收藏夹应保持原有相对顺序',
    );
    // 序号被重新规范化为 0/1/2/3/4
    expect(list.map((c) => c.sortOrder).toList(), [0, 1, 2, 3, 4]);
  });

  test('新增其他收藏夹后，置顶位置不变', () async {
    await CollectionService.instance.create('测试新增夹', 0xFFE05252);
    final list = CollectionService.instance.collections;
    _expectPresetOnTop(list);
    expect(list.last.name, '测试新增夹', reason: '新建收藏夹应排在置顶区之后');
  });

  test('重命名其他收藏夹后，置顶位置不变', () async {
    final target = CollectionService.instance.collections
        .firstWhere((c) => c.id == 'c_legacy_b');
    await CollectionService.instance.rename(target.id, '想补票（已改名）');
    final list = CollectionService.instance.collections;
    _expectPresetOnTop(list);
    expect(
      list.any((c) => c.id == 'c_legacy_b' && c.name == '想补票（已改名）'),
      isTrue,
      reason: '重命名应生效',
    );
  });

  test('重命名预设收藏夹后，仍保持置顶', () async {
    await CollectionService.instance
        .rename(CollectionService.kPresetWishlistId, '准备入手（改名验证）');
    final list = CollectionService.instance.collections;
    expect(list[0].id, CollectionService.kPresetWishlistId);
    expect(list[0].name, '准备入手（改名验证）');
    expect(list[1].id, CollectionService.kPresetStarredId);
    // 还原名称，避免影响后续用例
    await CollectionService.instance
        .rename(CollectionService.kPresetWishlistId, '准备入手');
  });

  test('删除其他收藏夹后，置顶位置不变且序号保持连续', () async {
    await CollectionService.instance.delete('c_legacy_a');
    await CollectionService.instance.delete('c_legacy_c');
    final list = CollectionService.instance.collections;
    _expectPresetOnTop(list);
    expect(list.map((c) => c.sortOrder).toList(),
        List<int>.generate(list.length, (i) => i),
        reason: '删除后剩余收藏夹序号应连续，不产生空档');
  });

  test('预设收藏夹不允许取消置顶', () async {
    final ok = await CollectionService.instance
        .setPinned(CollectionService.kPresetStarredId, false);
    expect(ok, isFalse, reason: '预设收藏夹应拒绝取消置顶');
    _expectPresetOnTop(CollectionService.instance.collections);
  });

  test('置顶状态与顺序已持久化到磁盘', () async {
    final content = await File(_collectionsFile).readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    final stored = (data['collections'] as List)
        .map((e) => GameCollection.fromJson(e as Map<String, dynamic>))
        .toList();
    expect(stored.first.id, CollectionService.kPresetWishlistId);
    expect(stored[1].id, CollectionService.kPresetStarredId);
    expect(stored.first.pinned, isTrue, reason: 'pinned 标记应写入磁盘');
    expect(stored[1].pinned, isTrue);
  });

  test('纯排序函数：任意脏序号下置顶组都排在最前', () {
    final list = [
      GameCollection(id: 'c_x', name: 'X', colorValue: 0xFFE05252, sortOrder: -5),
      GameCollection(
          id: CollectionService.kPresetStarredId,
          name: '特别关注',
          colorValue: 0xFFD9A514,
          sortOrder: 99),
      GameCollection(id: 'c_y', name: 'Y', colorValue: 0xFF4A90D9, sortOrder: -9),
      GameCollection(
          id: CollectionService.kPresetWishlistId,
          name: '准备入手',
          colorValue: 0xFF2F3437,
          sortOrder: 88),
      GameCollection(
          id: 'c_z',
          name: 'Z',
          colorValue: 0xFF67A86B,
          sortOrder: 0,
          pinned: true),
    ];
    final sorted = CollectionService.sortForDisplay(list);
    expect(sorted[0].id, CollectionService.kPresetWishlistId);
    expect(sorted[1].id, CollectionService.kPresetStarredId);
    expect(sorted[2].id, 'c_z', reason: '普通收藏夹的 pinned 也应在置顶区内');
    expect(sorted[3].id, 'c_y');
    expect(sorted[4].id, 'c_x');
  });
}
