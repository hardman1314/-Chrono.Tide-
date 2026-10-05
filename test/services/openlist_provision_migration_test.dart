// OpenListProvision.migrateLegacyIfNeeded 回归测试（2026-10-04 旧内置迁移）
//
// 背景：2026-10-02 半移植化之前，安装包直接内置 runtime/openlist/；
// 旧内置遗留（有 openlist.exe 但无 .provisioned 标记）升级后须清除，
// 要求用户走新流程重新对接。三态覆盖：
//   - 无 exe        → 什么都不做
//   - 有 exe 无标记 → 整目录删除（旧内置遗留）
//   - 有 exe 有标记 → 保留（新流程对接资产，永不自动清除）
//
// 用 PathHelper.exeDirOverride 隔离到临时目录（同 cache_quota_service_test 惯例）。

import 'dart:io';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/openlist_provision.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;

  setUpAll(() async {
    // exeDirOverride 必须在任何 PathHelper getter 首次解析之前设置。
    tempRoot = await Directory.systemTemp.createTemp('ct_ol_migrate_test_');
    PathHelper.exeDirOverride = tempRoot.path;
  });

  tearDownAll(() async {
    PathHelper.exeDirOverride = null;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  /// 场景种子：在隔离目录里造 runtime/openlist。
  Future<void> seedOpenList({required bool withMarker}) async {
    final dir = Directory(PathHelper.openlistDir);
    await dir.create(recursive: true);
    await File(PathHelper.openlistExePath)
        .writeAsBytes(const [0x4d, 0x5a]); // 'MZ' 假 exe，只测文件存在性
    await Directory(PathHelper.openlistDataDir).create(recursive: true);
    await File(PathHelper.openlistConfigPath).writeAsString('{}');
    if (withMarker) {
      await File(PathHelper.openlistProvisionMarkerPath).create();
    }
  }

  Future<bool> openlistDirExists() =>
      Directory(PathHelper.openlistDir).exists();

  setUp(() async {
    // 每个用例从干净状态开始（清掉上一例的 runtime/openlist）
    final dir = Directory(PathHelper.openlistDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('无 openlist.exe（未对接/已清除）→ 迁移不做任何事', () async {
    expect(await openlistDirExists(), isFalse);

    await OpenListProvision.migrateLegacyIfNeeded();

    // 不应无中生有创建目录
    expect(await openlistDirExists(), isFalse);
  });

  test('有 exe 无标记（旧内置遗留）→ 整目录删除', () async {
    await seedOpenList(withMarker: false);
    expect(await File(PathHelper.openlistExePath).exists(), isTrue);

    await OpenListProvision.migrateLegacyIfNeeded();

    expect(await openlistDirExists(), isFalse,
        reason: '旧内置遗留应整目录清除（exe+data 一并），逼出重新对接');
  });

  test('有 exe 有标记（新流程资产）→ 保留', () async {
    await seedOpenList(withMarker: true);

    await OpenListProvision.migrateLegacyIfNeeded();

    expect(await File(PathHelper.openlistExePath).exists(), isTrue,
        reason: '新流程对接资产有标记，迁移不得触碰（§6 更新稳定性语义）');
    expect(await File(PathHelper.openlistConfigPath).exists(), isTrue);
  });

  test('标记路径位于 openlist 目录内（生命周期与资产一致）', () {
    final marker = PathHelper.openlistProvisionMarkerPath;
    expect(
      p.isWithin(PathHelper.openlistDir, marker),
      isTrue,
      reason: '目录删除时标记随之消失、目录在标记就在，避免判定错位',
    );
  });
}
