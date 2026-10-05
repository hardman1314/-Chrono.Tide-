// 智能归纳板块（标签 / 会社派生分组 + 展示层覆盖项）· 单元测试
//
// 覆盖需求（方案 §4.3 / §7 Phase 5）：
// 1. 分组从游戏数据**派生**：标签一人多组、会社一人一组、未填会社单独成组；
// 2. 成员判定 `matches` 与派生计数口径一致（写穿后组内容即时变化）；
// 3. 展示层覆盖项（重命名/置顶/隐藏）只影响展示，**不落盘成员**；
// 4. 覆盖项持久化往返 + 读取失败时不覆写磁盘（数据可恢复）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/library_smart_group_service.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

Directory? _tmpRoot;

String get _file =>
    '${PathHelper.dataDir}${Platform.pathSeparator}smart_groups.json';

LibraryGame _game({
  required String title,
  List<String> tags = const [],
  String developer = '',
}) {
  return LibraryGame(
    title: title,
    directoryPath: r'D:\GAL\' + title,
    metaDataDir: r'D:\GAL\' + title + r'\.metadata',
    installedAt: '2026-01-01T00:00:00.000',
    tags: tags,
    developer: developer,
  );
}

List<SmartGroup> _derive(List<LibraryGame> games,
        {Map<String, SmartGroupOverride> overrides = const {}}) =>
    SmartGroupService.deriveGroups(games, overrides: overrides);

SmartGroup _group(List<SmartGroup> groups, String key) =>
    groups.firstWhere((g) => g.key == key);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_smart_group_test');
    PathHelper.exeDirOverride = _tmpRoot!.path;
    await Directory(PathHelper.dataDir).create(recursive: true);
  });

  tearDownAll(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  group('派生分组', () {
    final games = [
      _game(title: 'A', tags: ['纯爱', '学园'], developer: 'Key'),
      _game(title: 'B', tags: ['纯爱'], developer: 'Key'),
      _game(title: 'C', tags: ['纯爱', '悬疑'], developer: 'Nitroplus'),
      _game(title: 'D'),
    ];

    test('标签按成员数计数，一人多组', () {
      final groups = _derive(games);
      expect(_group(groups, SmartGroupService.tagKey('纯爱')).count, 3);
      expect(_group(groups, SmartGroupService.tagKey('学园')).count, 1);
      expect(_group(groups, SmartGroupService.tagKey('悬疑')).count, 1);
    });

    test('会社一人一组 + 未填会社单独成组', () {
      final groups = _derive(games);
      expect(_group(groups, SmartGroupService.devKey('Key')).count, 2);
      expect(_group(groups, SmartGroupService.devKey('Nitroplus')).count, 1);
      final unassigned =
          _group(groups, SmartGroupService.kUnassignedDevKey);
      expect(unassigned.count, 1);
      expect(unassigned.displayName, SmartGroupService.kUnassignedDevLabel);
      expect(unassigned.isUnassignedDeveloper, isTrue);
    });

    test('关闭"未填会社"时该组不出现', () {
      final groups = SmartGroupService.deriveGroups(games,
          includeUnassignedDeveloper: false);
      expect(
        groups.any((g) => g.key == SmartGroupService.kUnassignedDevKey),
        isFalse,
      );
    });

    test('空标签 / 首尾空白被忽略与归并；同游戏内重复标签只算一次', () {
      final dirty = [
        _game(title: 'X', tags: ['  纯爱 ', '纯爱', '', '   '], developer: '  Key  '),
      ];
      final groups = _derive(dirty);
      expect(_group(groups, SmartGroupService.tagKey('纯爱')).count, 1);
      expect(_group(groups, SmartGroupService.devKey('Key')).count, 1);
      expect(groups.length, 2, reason: '空标签不产生分组');
    });

    test('排序：置顶 → 成员数降序 → 展示名', () {
      final groups = _derive(games, overrides: {
        SmartGroupService.tagKey('悬疑'):
            const SmartGroupOverride(pinned: true),
      });
      expect(groups.first.key, SmartGroupService.tagKey('悬疑'),
          reason: '置顶组优先');
      // 其余按成员数降序：纯爱(3) → 会社 Key(2) → 其余 count=1
      expect(groups[1].key, SmartGroupService.tagKey('纯爱'));
      expect(groups[2].key, SmartGroupService.devKey('Key'));
    });

    test('展示名可被覆盖，但 value 保持原始数据值', () {
      final groups = _derive(games, overrides: {
        SmartGroupService.devKey('Key'):
            const SmartGroupOverride(displayName: 'Key 社（旧名）'),
      });
      final g = _group(groups, SmartGroupService.devKey('Key'));
      expect(g.displayName, 'Key 社（旧名）');
      expect(g.value, 'Key', reason: 'value 必须是数据原值，写穿时用它');
    });

    test('visibleGroups 滤掉隐藏组', () {
      final groups = _derive(games, overrides: {
        SmartGroupService.tagKey('学园'): const SmartGroupOverride(hidden: true),
      });
      final visible = SmartGroupService.visibleGroups(groups);
      expect(visible.any((g) => g.key == SmartGroupService.tagKey('学园')),
          isFalse);
      expect(visible.length, groups.length - 1);
    });
  });

  group('成员判定 matches', () {
    final games = [
      _game(title: 'A', tags: ['纯爱'], developer: 'Key'),
      _game(title: 'B'),
    ];
    final groups = _derive(games);

    test('标签组：含该标签的游戏属于该组', () {
      final g = _group(groups, SmartGroupService.tagKey('纯爱'));
      expect(g.matches(games[0]), isTrue);
      expect(g.matches(games[1]), isFalse);
    });

    test('会社组：仅该会社的游戏属于该组', () {
      final g = _group(groups, SmartGroupService.devKey('Key'));
      expect(g.matches(games[0]), isTrue);
      expect(g.matches(games[1]), isFalse);
    });

    test('未填会社组：会社为空的游戏属于该组', () {
      final g = _group(groups, SmartGroupService.kUnassignedDevKey);
      expect(g.matches(games[1]), isTrue);
      expect(g.matches(games[0]), isFalse);
    });
  });

  group('展示层覆盖项持久化', () {
    test('未加载时覆盖项为空', () {
      SmartGroupService.instance.resetForTest();
      expect(SmartGroupService.instance.overrideOf('tag:纯爱'), isNull);
      expect(SmartGroupService.instance.loadFailed, isFalse);
    });

    test('重命名 / 置顶 / 隐藏可落盘并读回', () async {
      final svc = SmartGroupService.instance;
      await svc.load();
      await svc.renameGroup('tag:纯爱', ' 恋爱 ');
      await svc.setPinned('dev:Key', true);
      await svc.setHidden('tag:悬疑', true);

      expect(svc.overrideOf('tag:纯爱')!.displayName, '恋爱',
          reason: '首尾空白应被裁剪');
      expect(svc.overrideOf('dev:Key')!.pinned, isTrue);
      expect(svc.overrideOf('tag:悬疑')!.hidden, isTrue);

      final raw =
          jsonDecode(await File(_file).readAsString()) as Map<String, dynamic>;
      final overrides = raw['overrides'] as Map<String, dynamic>;
      expect(overrides.containsKey('tag:纯爱'), isTrue);
      expect(overrides['tag:纯爱']['display_name'], '恋爱');
      expect(overrides.containsKey('dev:Key'), isTrue);
      // 只存展示层字段，绝不存成员列表
      expect(overrides['tag:纯爱'].containsKey('members'), isFalse);
      expect(overrides['tag:纯爱'].containsKey('games'), isFalse);
    });

    test('恢复默认（clearOverride）后该键从磁盘消失', () async {
      final svc = SmartGroupService.instance;
      await svc.clearOverride('dev:Key');
      expect(svc.overrideOf('dev:Key'), isNull);
      final raw =
          jsonDecode(await File(_file).readAsString()) as Map<String, dynamic>;
      expect((raw['overrides'] as Map).containsKey('dev:Key'), isFalse);
    });

    test('覆盖项变更会自增 revision（供 UI 缓存失效）', () async {
      final svc = SmartGroupService.instance;
      final before = svc.revision;
      await svc.setPinned('tag:学园', true);
      expect(svc.revision, greaterThan(before));
    });

    test('磁盘数据损坏时不覆写（loadFailed），内存退化为无覆盖项', () async {
      final svc = SmartGroupService.instance;
      await File(_file).writeAsString('{ 这不是合法 JSON');
      svc.resetForTest();
      await svc.load();

      expect(svc.loadFailed, isTrue);
      expect(svc.overrideOf('tag:纯爱'), isNull);

      final beforeWrite = await File(_file).readAsString();
      await svc.setPinned('tag:纯爱', true); // 应被拒绝写盘
      final afterWrite = await File(_file).readAsString();
      expect(afterWrite, beforeWrite,
          reason: '上次加载失败时必须跳过写盘，保留人工恢复机会');
    });
  });
}
