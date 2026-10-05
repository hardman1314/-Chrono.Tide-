/// 游戏存储状态判定与流转（方案 §4.4）。
///
/// ## 四种状态
///
/// | 状态 | 本体 | 游戏数据 | 存档 | 说明 |
/// |---|:---:|:---:|:---:|---|
/// | `normal` | ✅ | ✅ | ✅ | 正常在库，可直接玩 |
/// | `sealed` | ⚠️ 可删 | ✅ | ✅ | 只保存了「游戏数据」，本体可能已被用户删除 |
/// | `packed` | 已压缩 | ✅ | ✅ | 本体被压成归档，解包后可玩 |
/// | `display_only` | ❌ | 仅元数据 | ❌ | **派生态**，只展示不管理（用户自己删的光） |
///
/// ## 关键设计：显式值 vs 派生态
///
/// `display_only` **不写盘** —— 它完全由「本体目录是否存在」推导，因此用户一旦
/// 重新定位本体，它自动回到 `normal`，状态机没有"卡死"的洞。
///
/// 而 `sealed` / `packed` 是**显式写盘**的（`game.json.storage_state`），
/// 但显式值**不可无条件信任**：用户可能手动把归档目录删了。因此
/// [resolveVerified] 会核对归档是否仍在，不在就降级为派生态并在 UI 上如实呈现
/// —— **不猜测、不自动清理**（方案 §4.6）。
///
/// ## 两个入口
///
/// - [resolveFast]：**零磁盘 I/O**，只读内存里的 `storage_state`。库页卡片渲染
///   必须用它（方案 §6：卡片构建期做磁盘探测会毁掉列表滚动性能）。
/// - [resolveVerified]：异步核对磁盘，供弹窗/任务/详情页使用。
///
/// 🔴 本文件**刻意不 import `package:flutter/*`**，以便用 `dart.exe` 直接加载真实类
/// 做运行期验证（本环境 `flutter test` 跑不通）。改动时请保持这一约束。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/archive_manifest.dart';

/// 游戏存储状态。
enum GameStorageState {
  /// 正常在库（本体 + 游戏数据 + 存档齐全）
  normal('normal'),

  /// 封装：只保存了游戏数据（软件侧数据 + 提取压缩后的存档），本体可能已删
  sealed('sealed'),

  /// 打包：本体也压成归档
  packed('packed'),

  /// 仅展示：派生态，不写盘
  displayOnly('display_only');

  const GameStorageState(this.wire);

  /// 磁盘上的字符串取值（写进 `game.json.storage_state`）
  final String wire;

  /// 宽松解析：空串 / 未知值一律归为 [normal]（老数据零破坏）。
  static GameStorageState fromWire(String? value) {
    switch (value) {
      case 'sealed':
        return GameStorageState.sealed;
      case 'packed':
        return GameStorageState.packed;
      case 'display_only':
        return GameStorageState.displayOnly;
      case 'normal':
      default:
        return GameStorageState.normal;
    }
  }

  /// 是否持有归档（用于决定要不要显示"归档体积"等 UI）
  bool get hasArchive =>
      this == GameStorageState.sealed || this == GameStorageState.packed;

  /// ⚠️ 该状态**不应**写盘
  bool get isDerived => this == GameStorageState.displayOnly;

  /// 用户可见文案（Phase 2/4 的 UI 直接用，避免各处硬编码中文）
  String get label {
    switch (this) {
      case GameStorageState.normal:
        return '正常';
      case GameStorageState.sealed:
        return '已封装';
      case GameStorageState.packed:
        return '已打包';
      case GameStorageState.displayOnly:
        return '仅展示';
    }
  }
}

/// 判定结果（比裸枚举多带"为什么降级"的信息 —— UI 需要如实告知用户）
class GameStorageResolution {
  /// 判定后的状态
  final GameStorageState state;

  /// 磁盘上的显式值（`game.json.storage_state`），用于对比是否发生降级
  final GameStorageState declared;

  /// 是否发生了降级（显式值不可信 → 走了派生态）
  final bool degraded;

  /// 判定依据 / 降级原因（面向用户的中文；无需说明时为空串）
  final String reason;

  /// 本体目录当前是否存在（判定时实测）
  final bool bodyExists;

  /// 核验成功时解析出的清单（[GameStorageStateController.resolveFast] 恒为 null）
  final ArchiveManifest? manifest;

  const GameStorageResolution({
    required this.state,
    required this.declared,
    this.degraded = false,
    this.reason = '',
    this.bodyExists = false,
    this.manifest,
  });

  @override
  String toString() =>
      'GameStorageResolution(state=${state.wire}, declared=${declared.wire}, '
      'degraded=$degraded, bodyExists=$bodyExists'
      '${reason.isEmpty ? '' : ', reason=$reason'})';
}

class GameStorageStateController {
  GameStorageStateController._();

  /// **快判**：零磁盘 I/O，只读内存字段。库页卡片专用。
  ///
  /// 不要在这里加任何 `Directory.exists()` —— 卡片构建期做磁盘探测会毁掉
  /// 列表滚动性能（方案 §6）。
  static GameStorageState resolveFast(String? storedStorageState) =>
      GameStorageState.fromWire(storedStorageState);

  /// **核验判定**：核对归档与本体是否仍在磁盘上（方案 §4.4）。
  ///
  /// 与 §4.4 的伪代码逐条对应；额外增加一条：`packed`/`sealed` 声明下，
  /// 清单里**声明的每个分片都要存在**才算可信 —— 只判断 `meta.json` 存在
  /// 会让"归档目录在、但 7z 文件被用户删了"被误判为健康。
  static Future<GameStorageResolution> resolveVerified({
    required String? storedStorageState,
    required String directoryPath,
    required String archiveDir,
  }) async {
    final declared = GameStorageState.fromWire(storedStorageState);
    final bodyExists =
        directoryPath.isNotEmpty && await Directory(directoryPath).exists();

    if (declared == GameStorageState.packed) {
      final check = await _inspectArchive(archiveDir, requireBody: true);
      if (check.ok) {
        return GameStorageResolution(
          state: GameStorageState.packed,
          declared: declared,
          bodyExists: bodyExists,
          manifest: check.manifest,
        );
      }
      return GameStorageResolution(
        state:
            bodyExists ? GameStorageState.normal : GameStorageState.displayOnly,
        declared: declared,
        degraded: true,
        reason: '归档已不可用（${check.reason}）',
        bodyExists: bodyExists,
      );
    }

    if (declared == GameStorageState.sealed) {
      final check = await _inspectArchive(archiveDir, requireBody: false);
      if (check.ok) {
        return GameStorageResolution(
          state: bodyExists ? GameStorageState.normal : GameStorageState.sealed,
          declared: declared,
          bodyExists: bodyExists,
          manifest: check.manifest,
        );
      }
      return GameStorageResolution(
        state:
            bodyExists ? GameStorageState.normal : GameStorageState.displayOnly,
        declared: declared,
        degraded: true,
        reason: '归档已不可用（${check.reason}）',
        bodyExists: bodyExists,
      );
    }

    // normal / display_only / 缺失
    if (!bodyExists) {
      return GameStorageResolution(
        state: GameStorageState.displayOnly,
        declared: declared,
        reason: '游戏本体目录不存在',
      );
    }
    return GameStorageResolution(
      state: GameStorageState.normal,
      declared: declared,
      bodyExists: true,
    );
  }

  /// 归档目录健康检查。
  ///
  /// [requireBody] 为 `true` 时（`packed` 态）额外要求 `body` 段与 `body.7z` 存在。
  static Future<_ArchiveCheck> _inspectArchive(
    String archiveDir, {
    required bool requireBody,
  }) async {
    if (archiveDir.isEmpty) {
      return const _ArchiveCheck(ok: false, reason: '未记录归档目录');
    }
    final dir = Directory(archiveDir);
    if (!await dir.exists()) {
      return const _ArchiveCheck(ok: false, reason: '归档目录不存在');
    }
    final metaFile = File(p.join(archiveDir, ArchiveManifest.fileName));
    if (!await metaFile.exists()) {
      return const _ArchiveCheck(ok: false, reason: '缺少 meta.json（可能是半成品）');
    }

    ArchiveManifest? manifest;
    try {
      manifest = ArchiveManifest.tryParse(await metaFile.readAsString());
    } catch (e) {
      return _ArchiveCheck(ok: false, reason: 'meta.json 读取失败: $e');
    }
    if (manifest == null) {
      return const _ArchiveCheck(ok: false, reason: 'meta.json 无法解析');
    }

    final problems = manifest.validate();
    if (problems.isNotEmpty) {
      return _ArchiveCheck(ok: false, reason: problems.first);
    }

    if (requireBody &&
        (manifest.body == null || manifest.body!.archive.isEmpty)) {
      return const _ArchiveCheck(ok: false, reason: 'meta.json 缺少 body 段');
    }

    for (final part in manifest.partArchives) {
      final f = File(p.join(archiveDir, part));
      if (!await f.exists()) {
        return _ArchiveCheck(ok: false, reason: '归档分片缺失: $part');
      }
    }

    return _ArchiveCheck(ok: true, reason: '', manifest: manifest);
  }
}

class _ArchiveCheck {
  final bool ok;
  final String reason;
  final ArchiveManifest? manifest;
  const _ArchiveCheck({required this.ok, required this.reason, this.manifest});
}
