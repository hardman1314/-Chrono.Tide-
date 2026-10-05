// 智能导入板块 — WatchFolderService 路径管理测试
//
// 测试覆盖：
// 1. 添加监控路径（forStore 保留大小写）
// 2. 移除监控路径（forCompare 大小写不敏感匹配）
// 3. 切换启用状态（forCompare 匹配）
// 4. 更新排除规则（forCompare 匹配 + 缓存清理）
// 5. 重复路径检测
// 6. 操作逻辑一致性验证

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chrono_tide/services/watch_folder_service.dart';

void main() {
  late Directory tempDir;
  late WatchFolderService service;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('watch_folder_test_');
  });

  tearDownAll(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = WatchFolderService.instance;
    // 清理状态：移除所有监控路径
    for (final folder in service.watchFolders.toList()) {
      await service.removeWatchFolder(folder.path);
    }
    await service.clearCandidates();
    await service.clearIgnored();
    await service.loadSettings();
  });

  /// 创建测试目录
  Directory createTestDir(String name) {
    final dir = Directory(p.join(tempDir.path, name));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    return dir;
  }

  group('WatchFolderService - 添加监控路径', () {
    test('应成功添加存在的目录', () async {
      final dir = createTestDir('game_folder_1');
      final success = await service.addWatchFolder(dir.path);
      expect(success, true);
      expect(service.watchFolders.length, 1);
    });

    test('不应添加不存在的目录', () async {
      final success =
          await service.addWatchFolder('Z:\\nonexistent\\path');
      expect(success, false);
      expect(service.watchFolders.length, 0);
    });

    test('不应重复添加相同路径（大小写不敏感）', () async {
      final dir = createTestDir('GameFolder');
      await service.addWatchFolder(dir.path);

      // 用不同大小写尝试添加相同路径
      final altPath = dir.path.toUpperCase();
      final success = await service.addWatchFolder(altPath);
      expect(success, false, reason: '大小写不同的相同路径应判为重复');
      expect(service.watchFolders.length, 1);
    });

    test('应保留路径原始大小写用于显示', () async {
      final dir = createTestDir('MyGameFolder');
      await service.addWatchFolder(dir.path);

      final folder = service.watchFolders.first;
      expect(folder.path, contains('MyGameFolder'),
          reason: '存储路径应保留原始大小写');
    });
  });

  group('WatchFolderService - 移除监控路径', () {
    test('应成功移除已添加的路径', () async {
      final dir = createTestDir('remove_test');
      await service.addWatchFolder(dir.path);
      expect(service.watchFolders.length, 1);

      await service.removeWatchFolder(dir.path);
      expect(service.watchFolders.length, 0);
    });

    test('应支持大小写不敏感的移除', () async {
      final dir = createTestDir('CaseTest');
      await service.addWatchFolder(dir.path);
      expect(service.watchFolders.length, 1);

      // 用不同大小写移除
      await service.removeWatchFolder(dir.path.toUpperCase());
      expect(service.watchFolders.length, 0,
          reason: '大小写不敏感匹配应成功移除');
    });

    test('移除不存在的路径应安全处理（不抛异常）', () async {
      expect(
        () async => await service.removeWatchFolder('Z:\\nonexistent'),
        returnsNormally,
      );
    });

    test('移除后应能重新添加相同路径', () async {
      final dir = createTestDir('readd_test');
      await service.addWatchFolder(dir.path);
      await service.removeWatchFolder(dir.path);
      final success = await service.addWatchFolder(dir.path);
      expect(success, true);
      expect(service.watchFolders.length, 1);
    });
  });

  group('WatchFolderService - 切换启用状态', () {
    test('应成功切换启用→禁用', () async {
      final dir = createTestDir('toggle_test');
      await service.addWatchFolder(dir.path);
      expect(service.watchFolders.first.enabled, true);

      await service.toggleFolderEnabled(dir.path);
      expect(service.watchFolders.first.enabled, false);
    });

    test('应成功切换禁用→启用', () async {
      final dir = createTestDir('toggle_test_2');
      await service.addWatchFolder(dir.path);
      await service.toggleFolderEnabled(dir.path); // → false
      await service.toggleFolderEnabled(dir.path); // → true
      expect(service.watchFolders.first.enabled, true);
    });

    test('应支持大小写不敏感的切换', () async {
      final dir = createTestDir('ToggleCase');
      await service.addWatchFolder(dir.path);

      await service.toggleFolderEnabled(dir.path.toLowerCase());
      expect(service.watchFolders.first.enabled, false,
          reason: '大小写不敏感匹配应成功切换');
    });

    test('切换不存在的路径应安全处理', () async {
      expect(
        () async =>
            await service.toggleFolderEnabled('Z:\\nonexistent'),
        returnsNormally,
      );
    });
  });

  group('WatchFolderService - 更新排除规则', () {
    test('应成功更新排除规则', () async {
      final dir = createTestDir('exclude_test');
      await service.addWatchFolder(dir.path);

      const patterns = ['patch', 'save', 'config'];
      await service.updateExcludePatterns(dir.path, patterns);

      expect(service.watchFolders.first.excludePatterns, patterns);
    });

    test('应支持大小写不敏感的排除规则更新', () async {
      final dir = createTestDir('ExcludeCase');
      await service.addWatchFolder(dir.path);

      await service.updateExcludePatterns(dir.path.toUpperCase(), ['test']);
      expect(service.watchFolders.first.excludePatterns, ['test'],
          reason: '大小写不敏感匹配应成功更新');
    });

    test('空排除规则列表应被接受', () async {
      final dir = createTestDir('empty_exclude');
      await service.addWatchFolder(dir.path);

      await service.updateExcludePatterns(dir.path, []);
      expect(service.watchFolders.first.excludePatterns, []);
    });

    test('默认排除规则应被设置', () async {
      final dir = createTestDir('default_exclude');
      await service.addWatchFolder(dir.path);

      final patterns = service.watchFolders.first.excludePatterns;
      expect(patterns, isNotEmpty);
      expect(patterns, contains('patch'));
      expect(patterns, contains('save'));
    });
  });

  group('WatchFolderService - 操作逻辑一致性', () {
    test('添加→移除→添加 应正常工作', () async {
      final dir = createTestDir('consistency_1');
      // 添加
      expect(await service.addWatchFolder(dir.path), true);
      expect(service.watchFolders.length, 1);
      // 移除
      await service.removeWatchFolder(dir.path);
      expect(service.watchFolders.length, 0);
      // 再次添加
      expect(await service.addWatchFolder(dir.path), true);
      expect(service.watchFolders.length, 1);
    });

    test('添加→禁用→启用 应正常工作', () async {
      final dir = createTestDir('consistency_2');
      await service.addWatchFolder(dir.path);
      expect(service.watchFolders.first.enabled, true);
      // 禁用
      await service.toggleFolderEnabled(dir.path);
      expect(service.watchFolders.first.enabled, false);
      // 启用
      await service.toggleFolderEnabled(dir.path);
      expect(service.watchFolders.first.enabled, true);
    });

    test('添加→更新排除规则→移除 应正常工作', () async {
      final dir = createTestDir('consistency_3');
      await service.addWatchFolder(dir.path);
      await service.updateExcludePatterns(dir.path, ['custom_pattern']);
      expect(service.watchFolders.first.excludePatterns, ['custom_pattern']);
      await service.removeWatchFolder(dir.path);
      expect(service.watchFolders.length, 0);
    });

    test('多个路径的独立操作应互不影响', () async {
      final dir1 = createTestDir('multi_1');
      final dir2 = createTestDir('multi_2');

      await service.addWatchFolder(dir1.path);
      await service.addWatchFolder(dir2.path);
      expect(service.watchFolders.length, 2);

      // 禁用 dir1
      await service.toggleFolderEnabled(dir1.path);
      expect(service.watchFolders[0].enabled, false);
      expect(service.watchFolders[1].enabled, true);

      // 更新 dir2 排除规则
      await service.updateExcludePatterns(dir2.path, ['test']);
      expect(service.watchFolders[0].excludePatterns, isNot(['test']));
      expect(service.watchFolders[1].excludePatterns, ['test']);

      // 移除 dir1
      await service.removeWatchFolder(dir1.path);
      expect(service.watchFolders.length, 1);
      expect(service.watchFolders[0].path, dir2.path);
    });
  });

  group('WatchFolderService - 候选管理', () {
    test('清空候选列表应正常工作', () async {
      await service.clearCandidates();
      expect(service.candidates.length, 0);
    });

    test('清空忽略列表应正常工作', () async {
      await service.clearIgnored();
      expect(service.ignoredPaths.length, 0);
    });
  });

  group('WatchFolderService - 持久化', () {
    test('配置应在 loadSettings 后恢复', () async {
      final dir = createTestDir('persist_test');
      await service.addWatchFolder(dir.path);
      await service.updateExcludePatterns(dir.path, ['persist_pattern']);

      // 重新加载
      await service.loadSettings();

      expect(service.watchFolders.length, 1);
      expect(service.watchFolders.first.excludePatterns,
          contains('persist_pattern'));
    });
  });
}
