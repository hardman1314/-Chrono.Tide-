/// 归档库布局解析 + 旧布局迁移（**纯 Dart，不 import flutter** —— 探针可加载，
/// 与 `seven_zip_progress.dart` 同一设计动机：本环境 `flutter test` 跑不通，
/// 纯 Dart 模块才能被 `dart.exe` 直跑实测）。
///
/// ## 背景：钥匙统一（2026-10-03，对齐提交 `20e1671`）
///
/// 全局唯一身份是 `game.json.game_id`（UUID v4，文件系统安全）；标题会因目录名
/// 清洗差异不同，「同名不同路径」重复导入也是合法场景。归档库 v1 布局按
/// 「标题清洗名」组织游戏根（`<归档库>/<dirNameFromTitle(title)>/`），会让两个
/// 同名游戏共用同一个根 —— latest 指针 / 保留份数清理 / 归档列表全部互相串库。
///
/// v2 布局：`<归档库>/<game_id>/`。`game_id` 为空的历史脏数据兜底回 v1 规则
/// （与库页卡片 GlobalKey 的兜底策略一致，见 `20e1671` 提交说明）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/archive_manifest.dart';
import '../utils/game_key.dart';

/// 迁移结果：[root] 是最终应使用的游戏归档根；[moved] / [kept] 为迁移统计
/// （未发生迁移时均为 0）。
class ArchiveRootResolution {
  final String root;
  final int moved;
  final int kept;

  const ArchiveRootResolution({
    required this.root,
    this.moved = 0,
    this.kept = 0,
  });
}

class ArchiveLayoutMigrator {
  ArchiveLayoutMigrator._();

  static const String latestFileName = 'latest.json';

  /// 解析某游戏的归档根，并按需把**旧布局**（标题清洗名根）迁移到新布局。
  ///
  /// 迁移策略（保守，只动「确认属于这个游戏」的数据）：
  /// - 新根已存在 → 幂等返回，不迁移。
  /// - 旧根存在 → 逐归档子目录读 `meta.json`：`gameId` 与当前游戏一致才
  ///   rename 到新根（**同盘 rename，原子操作**）；无 `meta.json` 的
  ///   `.partial` 半成品一并搬（无身份数据、当前操作者就是该游戏，半成品
  ///   本身无价值）。
  /// - 旧根里 `gameId` 不一致的其他游戏归档**留在原地** —— 它们各自的
  ///   `listArchives` 会来认领（同名不同游戏正是本次要隔离的场景）。
  /// - 旧根搬空（无归档子目录残留）→ `latest.json` 搬到新根（若新根没有）
  ///   并删除旧根。
  /// - 任何一步失败：[log] 记录后返回新根（新归档仍进新根；旧数据原地保留，
  ///   仍可经 `game.json.archive_dir` 绝对路径还原，不丢）。
  static Future<ArchiveRootResolution> resolveGameRoot({
    required String libraryRoot,
    required String gameId,
    required String title,
    void Function(String message)? log,
  }) async {
    final id = gameId.trim();
    final legacyRoot =
        p.join(libraryRoot, GameKey.dirNameFromTitle(title));

    // 历史脏数据：无 game_id —— 与库页卡片 key 同策略，兜底 v1 布局
    if (id.isEmpty) return ArchiveRootResolution(root: legacyRoot);

    final newRoot = p.join(libraryRoot, id);
    if (newRoot == legacyRoot) return ArchiveRootResolution(root: newRoot);

    try {
      final newDir = Directory(newRoot);
      if (await newDir.exists()) {
        return ArchiveRootResolution(root: newRoot); // 已是新布局（幂等）
      }
      final legacyDir = Directory(legacyRoot);
      if (!await legacyDir.exists()) {
        return ArchiveRootResolution(root: newRoot); // 无旧数据
      }

      var moved = 0;
      var kept = 0;
      await for (final e in legacyDir.list(followLinks: false)) {
        if (e is! Directory) continue; // latest.json 等文件最后统一处理
        final name = p.basename(e.path);
        final metaFile = File(p.join(e.path, ArchiveManifest.fileName));
        String? owner;
        if (await metaFile.exists()) {
          try {
            owner =
                ArchiveManifest.tryParse(await metaFile.readAsString())?.gameId;
          } catch (_) {
            // 清单损坏 = 无法确认归属 → 保守留原地（kept）
          }
        }
        final isPartial = name.endsWith('.partial');
        if (owner == id || (owner == null && isPartial)) {
          await newDir.create(recursive: true);
          await e.rename(p.join(newRoot, name));
          moved++;
        } else {
          kept++; // 其他游戏的归档，留给它们自己的 resolveGameRoot 认领
        }
      }

      if (moved > 0) {
        // latest 指针跟着走（它指向的归档要么已迁走、要么本就不存在）
        final legacyLatest = File(p.join(legacyRoot, latestFileName));
        if (await legacyLatest.exists()) {
          final newLatest = File(p.join(newRoot, latestFileName));
          if (!await newLatest.exists()) {
            await legacyLatest.rename(newLatest.path);
          } else {
            await legacyLatest.delete();
          }
        }
      }

      // 旧根搬空（无归档子目录残留）才删，否则保留给其他游戏认领
      var remainingDirs = 0;
      await for (final e in legacyDir.list(followLinks: false)) {
        if (e is Directory) remainingDirs++;
      }
      if (remainingDirs == 0) {
        await legacyDir.delete(recursive: true);
      }
      if (moved > 0 || kept > 0) {
        log?.call('旧布局迁移：迁移 $moved 份、留待其他游戏认领 $kept 份 → $newRoot');
      }
      return ArchiveRootResolution(root: newRoot, moved: moved, kept: kept);
    } catch (e) {
      log?.call('⚠️ 旧布局迁移失败（旧数据原地保留，可经 archive_dir 还原）: $e');
      return ArchiveRootResolution(root: newRoot);
    }
  }
}
