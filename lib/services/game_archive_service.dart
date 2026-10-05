/// 游戏数据归档编排服务（方案 §4、§7 Phase 1）。
///
/// ## 术语（全文必须一致，方案 §1.2）
///
/// - **游戏数据** = 「软件侧游戏数据」+「提取并压缩后的存档」。
///   ⚠️ 这里的「存档」**不是**指游戏本体文件夹里的存档文件本身，而是指软件帮用户
///   提取出来、并压缩好的那份归档。
/// - **游戏本体** = 游戏安装目录（可执行文件那一坨）。
///
/// ## 四种状态里的三个动作
///
/// | 动作 | 做什么 | 状态结果 |
/// |---|---|---|
/// | [seal] 封装 | 归档「游戏数据」，**不动本体**（用户可自行删本体腾空间） | `sealed` |
/// | [pack] 打包 | 归档「游戏数据」+ 压缩游戏本体 | `packed` |
/// | [restoreAppData] / [restoreSaves] | 解封/解包时把数据还原回去 | → `normal` |
///
/// ## 目录布局（方案 §4.2）
///
/// ```
/// <归档库根>/<dirNameFromTitle(标题)>/
///   latest.json
///   <时间戳>_<state>/          ← 例：2026-10-02_20-45-11_packed
///     meta.json  appdata.7z  saves.7z  body.7z
/// ```
///
/// ## 硬约束（违反即数据事故）
///
/// 1. 🔴 **绝不连带删除 `.ctgame`** —— 它是在库识别标记，删了卡片会从库里
///    静默消失，连带游玩时长与会话记录。`appdata.7z` 打包时排除它，且磁盘上的
///    元数据目录**始终保留**（决策 2：归档只存一份，本地只留让卡片不消失的最小集）。
/// 2. 🔴 **删除必须过 `PathHelper.isInsideAppStorage`**（ADR-007）。归档库若被配到
///    应用目录之外，[pruneArchives] / [cleanupPartials] 一律拒绝删除。
/// 3. 🔴 **校验不过 = 没备份成功**。任何分片 `7z t` 失败或文件数不符，都不得把
///    状态写成 `sealed`/`packed`，更不得删任何源。
/// 4. 🔴 **半成品不进状态机**。归档先写在 `<时间戳>_<state>.partial/`，全部成功
///    才改名 —— 目录名带 `.partial` 或缺 `meta.json` 即视为半成品。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../models/archive_manifest.dart';
import '../utils/game_key.dart';
import 'archive_compressor.dart';
import 'archive_layout_migrate.dart';
import 'archive_library_preference.dart';
import 'file_size_service.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';
import 'path_validator.dart';
import 'recycle_bin_service.dart';
import 'save_scanner.dart';
import 'storage/cleanup_utils.dart';

/// 归档流程的阶段（UI 用来显示"正在做什么"）
enum ArchivePhase {
  preparing('准备中'),
  saves('正在提取并压缩存档'),
  appdata('正在压缩游戏数据'),
  body('正在压缩游戏本体'),
  verify('正在校验归档'),
  finalize('正在整理'),
  restore('正在还原');

  const ArchivePhase(this.label);
  final String label;
}

/// 进度事件
class ArchiveProgress {
  final ArchivePhase phase;

  /// 0..100（阶段内百分比）
  final int percent;

  final String message;

  const ArchiveProgress({
    required this.phase,
    this.percent = 0,
    this.message = '',
  });

  @override
  String toString() => '${phase.name} $percent% ${message.isEmpty ? phase.label : message}';
}

/// 一个已落地的归档（对应归档库里的一个 `<时间戳>_<state>/` 目录）
class ArchiveRecord {
  /// 归档目录绝对路径
  final String archiveDir;

  /// 目录名（= 归档 id）
  final String id;

  final ArchiveManifest manifest;

  const ArchiveRecord({
    required this.archiveDir,
    required this.id,
    required this.manifest,
  });

  String get state => manifest.state;

  DateTime? get createdAt => DateTime.tryParse(manifest.createdAt);

  /// 各分片体积之和
  int get totalBytes =>
      (manifest.appdata?.bytes ?? 0) +
      (manifest.saves?.bytes ?? 0) +
      (manifest.body?.bytes ?? 0);

  /// 本体归档体积（0 = 该归档没有本体段）
  int get bodyBytes => manifest.body?.bytes ?? 0;

  String get metaPath => p.join(archiveDir, ArchiveManifest.fileName);
}

/// 归档操作结果
class ArchiveOperationResult {
  final bool ok;
  final bool cancelled;
  final String? error;

  /// 成功时的归档记录（restore 类操作恒为 null）
  final ArchiveRecord? record;

  /// 非致命问题（如"未检测到存档"）—— 必须如实展示给用户
  final List<String> warnings;

  /// 还原类操作的部分失败清单（成功项已保留，方案 §4.6）
  final List<String> failures;

  /// **打包且要求删本体时**：本体是否已成功移入回收站。
  /// `false` 不代表操作失败 —— 归档本体身已完成，只是本体目录仍在原位，
  /// 失败原因见 [warnings]（调用方必须如实展示，不得静默）。
  final bool bodyRemoved;

  const ArchiveOperationResult({
    required this.ok,
    this.cancelled = false,
    this.error,
    this.record,
    this.warnings = const [],
    this.failures = const [],
    this.bodyRemoved = false,
  });

  static ArchiveOperationResult fail(String error,
          {bool cancelled = false, List<String> warnings = const []}) =>
      ArchiveOperationResult(
          ok: false, error: error, cancelled: cancelled, warnings: warnings);

  static ArchiveOperationResult ok0(
          {ArchiveRecord? record,
          List<String> warnings = const [],
          bool bodyRemoved = false}) =>
      ArchiveOperationResult(
          ok: true,
          record: record,
          warnings: warnings,
          bodyRemoved: bodyRemoved);
}

/// 游戏数据归档编排服务（单例）。
class GameArchiveService {
  GameArchiveService._({ArchiveCompressor? compressor})
      : _compressor = compressor;

  static GameArchiveService? _instance;
  static GameArchiveService get instance => _instance ??= GameArchiveService._();

  final ArchiveCompressor? _compressor;

  /// 7z 封装。生产环境用随包内置的 `<exeDir>/runtime/tools/7z.exe`。
  ArchiveCompressor get compressor =>
      _compressor ??
      ArchiveCompressor(
        sevenZipPath: PathHelper.bundled7zPath,
        onLog: (m) => debugPrint('[ARCHIVE] $m'),
      );

  ArchiveLibraryPreference get prefs => ArchiveLibraryPreference.instance;

  /// 归档时排除的条目名（相对源根）
  ///
  /// - `.ctgame`：在库识别标记。归档它没有价值（磁盘上的原件始终保留），
  ///   排除可避免「还原时在别处冒出一个重复标记」。若元数据目录丢失后还原，
  ///   [restoreAppData] 会按需重建它。
  /// - `saves`：存档备份目录，已单独压成 `saves.7z`，排除避免双份占用。
  static const String excludedCtgame = GameDataFormat.ctgameFileName;
  static const String excludedSavesDir = 'saves';

  /// 仅供单测注入
  @visibleForTesting
  static void resetForTest() => _instance = null;

  // ==================== 路径 ====================

  /// 某游戏在归档库中的根目录：`<归档库根>/<dirNameFromTitle(标题)>`
  ///
  /// 🔴 目录名清洗复用项目唯一实现 [GameKey.dirNameFromTitle]，不另起炉灶
  /// （全项目已存在 16 处重复实现，属技术债，不要再加第 17 处）。
  /// 归档根目录（v2 布局）= `<归档库>/<game_id>`。
  ///
  /// 🔴 钥匙统一（2026-10-03，对齐 `20e1671`「卡片 key 改 game_id」）：全局唯一
  /// 身份是 `game.json.game_id`（UUID v4，文件系统安全），而标题会因清洗差异
  /// 不同、同名不同路径又是合法场景 —— 按「标题清洗名」组织归档库会让两个
  /// 同名游戏共用一个根，latest / 保留份数清理 / 列表全部互相串库。
  /// `game_id` 为空时兜底标题清洗名（历史脏数据，与库页卡片 key 同策略）。
  /// 旧布局 → 新布局的迁移见 [ArchiveLayoutMigrator]（[_resolveRoot] 委托）。
  String gameRootFor(LibraryGame game) {
    final id = game.gameId.trim();
    if (id.isEmpty) {
      return p.join(prefs.rootPath, GameKey.dirNameFromTitle(game.title));
    }
    return p.join(prefs.rootPath, id);
  }

  /// 解析某游戏的归档根（含旧布局按需迁移），实际逻辑在
  /// [ArchiveLayoutMigrator.resolveGameRoot]（纯 Dart，探针可实测）。
  Future<String> _resolveRoot(LibraryGame game) async {
    final res = await ArchiveLayoutMigrator.resolveGameRoot(
      libraryRoot: prefs.rootPath,
      gameId: game.gameId.trim(),
      title: game.title,
      log: (m) => debugPrint('[ARCHIVE] $m'),
    );
    return res.root;
  }

  /// 生成归档 id：`<游戏名>_<yyyy-MM-dd_HH-mm-ss>_<state>`（Q15）。
  ///
  /// 游戏名清洗 Windows 目录非法字符（`\ / : * ? " < > |`）并截断 40 字符，
  /// 让归档目录与卡片一眼可辨属于哪个游戏；清洗后为空则退回纯时间戳格式
  /// （旧格式归档零影响 —— id 从目录名动态读取，不解析格式）。
  static String newArchiveId(DateTime now, String state, {String? title}) {
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    final clean = sanitizeTitleForId(title);
    return clean.isEmpty ? '${ts}_$state' : '${clean}_${ts}_$state';
  }

  /// 清洗标题为可作目录名的安全片段（公开以便探针/测试复用）。
  static String sanitizeTitleForId(String? title) {
    if (title == null) return '';
    var t = title
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (t.length > 40) t = t.substring(0, 40);
    // Windows 目录名不允许以点/空格结尾
    t = t.replaceAll(RegExp(r'[. ]+$'), '');
    return t;
  }

  static const String _latestFileName = 'latest.json';

  // ==================== 主流程 ====================

  /// **封装**：归档「游戏数据」（软件侧数据 + 提取压缩后的存档），不动本体。
  ///
  /// 成功后把 `storage_state` 回写为 `sealed`。
  ///
  /// [savePaths] 存档确认（方案 §23.1 Q14）：`null` = 沿用自动检测（兼容既有
  /// 调用与测试）；非 `null` = 用户在确认框里勾选的路径清单（可为空 = 明确
  /// 不含存档），服务层照单全收、不再自行扫描。
  Future<ArchiveOperationResult> seal({
    required LibraryGame game,
    List<String>? savePaths,
    void Function(ArchiveProgress progress)? onProgress,
  }) =>
      _archiveCore(
        game: game,
        includeBody: false,
        savePaths: savePaths,
        onProgress: onProgress,
      );

  /// **打包**：归档「游戏数据」+ 压缩游戏本体。
  ///
  /// [removeBody] = true 时，**归档校验通过且状态回写成功后**，把原本体目录
  /// 移入**回收站**（`RecycleBinService`，可还原），并写 `CleanupLog` 审计。
  /// 删除失败**不会**让整个打包失败 —— 归档已完成、状态已是 packed，只会往
  /// [ArchiveOperationResult.warnings] 里追加原因，并把 [ArchiveOperationResult.bodyRemoved]
  /// 置 false，由 UI 如实告知「本体仍在原位」。
  ///
  /// 🔴 删除走回收站而非永久删除（方案 §10 P0）；调用方 UI 必须先过
  /// 「二次确认框明示真实绝对路径」这一关（Q3：复选框默认不预选）。
  /// [savePaths] 存档确认清单，语义同 [seal]。
  Future<ArchiveOperationResult> pack({
    required LibraryGame game,
    void Function(ArchiveProgress progress)? onProgress,
    bool removeBody = false,
    List<String>? savePaths,
  }) =>
      _archiveCore(
        game: game,
        includeBody: true,
        onProgress: onProgress,
        removeBody: removeBody,
        savePaths: savePaths,
      );

  Future<ArchiveOperationResult> _archiveCore({
    required LibraryGame game,
    required bool includeBody,
    bool removeBody = false,
    List<String>? savePaths,
    void Function(ArchiveProgress progress)? onProgress,
  }) async {
    void emit(ArchivePhase phase, int percent, [String message = '']) =>
        onProgress?.call(
            ArchiveProgress(phase: phase, percent: percent, message: message));

    final warnings = <String>[];
    final title = game.title.trim();
    if (title.isEmpty) {
      return ArchiveOperationResult.fail('游戏标题为空，无法建立归档');
    }
    final metaDir = game.metaDataDir;
    if (metaDir.isEmpty || !await Directory(metaDir).exists()) {
      return ArchiveOperationResult.fail('元数据目录不存在：$metaDir');
    }
    if (game.metaDataDir == game.directoryPath) {
      return ArchiveOperationResult.fail('元数据目录与本体目录相同，拒绝归档（会自包含）');
    }

    emit(ArchivePhase.preparing, 0);

    final now = DateTime.now();
    final state = includeBody
        ? ArchiveManifest.statePacked
        : ArchiveManifest.stateSealed;
    final root = await _resolveRoot(game);
    final id = newArchiveId(now, state, title: title);
    final finalDir = p.join(root, id);
    final workDir = '$finalDir.partial';

    // 归档库根可写性 + 磁盘空间预检
    final spaceErr = await _precheckSpace(targetDir: root);
    if (spaceErr != null) return ArchiveOperationResult.fail(spaceErr);

    // 清掉同名残留（同秒重入 / 上次中断）
    try {
      final stale = Directory(workDir);
      if (await stale.exists()) await stale.delete(recursive: true);
    } catch (_) {}
    try {
      await Directory(workDir).create(recursive: true);
    } catch (e) {
      return ArchiveOperationResult.fail('无法创建归档工作目录：$workDir | $e');
    }

    var aborted = false;
    try {
      // ---------- 1. 存档：提取 → 暂存 → 压缩 ----------
      emit(ArchivePhase.saves, 0);
      final savesPart = await _buildSavesPart(
        game: game,
        workDir: workDir,
        savePaths: savePaths,
        onProgress: (pct) => emit(ArchivePhase.saves, pct),
        warnings: warnings,
      );
      if (savesPart.abortMessage != null) {
        aborted = true;
        return ArchiveOperationResult.fail(savesPart.abortMessage!,
            cancelled: savesPart.cancelled, warnings: warnings);
      }

      // ---------- 2. 软件侧游戏数据 ----------
      emit(ArchivePhase.appdata, 0);
      final appdataArchive = p.join(workDir, 'appdata.7z');
      final appdataOutcome = await compressor.compressDirectory(
        sourceDir: metaDir,
        outputArchive: appdataArchive,
        level: prefs.compressionLevel,
        recursiveExcludes: const [excludedCtgame],
        topLevelExcludes: const [excludedSavesDir],
        onProgress: (pct) => emit(ArchivePhase.appdata, pct),
      );
      if (!appdataOutcome.ok) {
        aborted = true;
        return ArchiveOperationResult.fail(
            '归档游戏数据失败：${appdataOutcome.error}',
            cancelled: appdataOutcome.cancelled,
            warnings: warnings);
      }
      final appdataPart = ArchivePartInfo(
        archive: p.basename(appdataOutcome.archivePath),
        bytes: appdataOutcome.bytes,
        fileCount: appdataOutcome.fileCount,
        sha256: appdataOutcome.sha256,
        root: _relativeToExe(metaDir),
        excluded: const [excludedCtgame, '$excludedSavesDir/'],
      );

      // ---------- 3. 游戏本体（仅打包态） ----------
      ArchiveBodyInfo? bodyPart;
      String bodyDir = '';
      if (includeBody) {
        bodyDir = game.directoryPath;
        if (bodyDir.isEmpty || !await Directory(bodyDir).exists()) {
          aborted = true;
          return ArchiveOperationResult.fail(
              '游戏本体目录不存在，无法打包：$bodyDir',
              warnings: warnings);
        }
        emit(ArchivePhase.body, 0);
        final unpackedBytes =
            await FileSizePrefetchService.calculateDirectorySize(bodyDir);
        final bodySpaceErr = await _precheckSpace(
          targetDir: root,
          requiredBytes: (unpackedBytes * 0.65).round(),
        );
        if (bodySpaceErr != null) {
          aborted = true;
          return ArchiveOperationResult.fail(bodySpaceErr, warnings: warnings);
        }

        final bodyArchive = p.join(workDir, 'body.7z');
        final bodyOutcome = await compressor.compressDirectory(
          sourceDir: bodyDir,
          outputArchive: bodyArchive,
          level: prefs.compressionLevel,
          onProgress: (pct) => emit(ArchivePhase.body, pct),
        );
        if (!bodyOutcome.ok) {
          aborted = true;
          return ArchiveOperationResult.fail(
              '压缩游戏本体失败：${bodyOutcome.error}',
              cancelled: bodyOutcome.cancelled,
              warnings: warnings);
        }
        bodyPart = ArchiveBodyInfo(
          archive: p.basename(bodyOutcome.archivePath),
          bytes: bodyOutcome.bytes,
          unpackedBytes: unpackedBytes,
          fileCount: bodyOutcome.fileCount,
          sha256: bodyOutcome.sha256,
          originalDir: bodyDir,
          launchPath: game.launchPath,
        );
      }

      // ---------- 4. 写清单（写它 = 归档完成） ----------
      emit(ArchivePhase.finalize, 60);
      final manifest = ArchiveManifest(
        gameId: game.gameId,
        title: title,
        state: state,
        createdAt: now.toIso8601String(),
        appVersion: await _appVersion(),
        appdata: appdataPart,
        saves: savesPart.part,
        body: bodyPart,
      );
      final problems = manifest.validate();
      if (problems.isNotEmpty) {
        aborted = true;
        return ArchiveOperationResult.fail(
            '归档清单自检未通过：${problems.join('；')}',
            warnings: warnings);
      }
      await File(p.join(workDir, ArchiveManifest.fileName))
          .writeAsString(manifest.toPrettyJson(), flush: true);

      // ---------- 5. 校验（7z t + 文件数交叉比对） ----------
      emit(ArchivePhase.verify, 0);
      final verifyResult = await _verifyDir(workDir, manifest);
      if (!verifyResult.ok) {
        aborted = true;
        return ArchiveOperationResult.fail(
            '归档校验未通过，已丢弃半成品：${verifyResult.error}',
            warnings: warnings);
      }
      warnings.addAll(verifyResult.warnings);

      // ---------- 6. 转正 + 清理暂存 ----------
      emit(ArchivePhase.finalize, 85);
      await _deleteQuietly(Directory(p.join(workDir, _stageDirName)));

      final finalDirObj = Directory(finalDir);
      if (await finalDirObj.exists()) {
        await finalDirObj.delete(recursive: true);
      }
      try {
        await Directory(workDir).rename(finalDir);
      } catch (e) {
        aborted = true;
        return ArchiveOperationResult.fail(
            '归档改名失败（半成品保留在 $workDir）：$e',
            warnings: warnings);
      }

      final record = ArchiveRecord(
        archiveDir: finalDir,
        id: id,
        manifest: manifest,
      );

      // ---------- 7. 回写 game.json + latest 指针 ----------
      emit(ArchivePhase.finalize, 95);
      final wrote = await LocalGameRegistry.instance.setStorageState(
        game,
        storageState: state,
        archiveDir: finalDir,
        archiveAt: now.toIso8601String(),
      );
      if (!wrote) {
        warnings.add('归档已生成，但状态回写 game.json 失败 —— 下次扫描会按「正常」显示，'
            '可手动重新封装或重试');
      }
      await _writeLatestPointer(game, id);

      // ---------- 7.5 删本体（仅打包 + 用户明确要求；走回收站，失败不致命） ----------
      var bodyRemoved = false;
      if (includeBody && removeBody && bodyDir.isNotEmpty) {
        emit(ArchivePhase.finalize, 97, '正在把本体移入回收站');
        final rb = await RecycleBinService.moveToRecycleBin(bodyDir);
        if (rb.ok) {
          bodyRemoved = true;
        } else {
          warnings.add('本体移入回收站失败：${rb.error} —— '
              '归档已完成，本体仍保留在 $bodyDir，可稍后手动处理');
        }
        // 无论成败都留审计痕迹（方案 §10：删用户可见数据必须可追溯）
        await CleanupLog.append({
          'op': 'archive_body_recycle',
          'target': bodyDir,
          'archiveId': id,
          'state': state,
          'result': rb.ok ? 'ok' : 'fail',
          'reason': rb.ok ? 'pack_remove_body' : (rb.error ?? 'unknown'),
        });
      }

      emit(ArchivePhase.finalize, 100);
      return ArchiveOperationResult.ok0(
          record: record, warnings: warnings, bodyRemoved: bodyRemoved);
    } catch (e, st) {
      aborted = true;
      debugPrint('[ARCHIVE] 归档异常: $e\n$st');
      return ArchiveOperationResult.fail('归档过程异常：$e', warnings: warnings);
    } finally {
      // 只有"没成功转正"才清工作目录；成功时 workDir 已被 rename 掉
      if (aborted) {
        await _deleteQuietly(Directory(workDir));
      }
    }
  }

  // ==================== 存档段 ====================

  static const String _stageDirName = '.stage';

  Future<_SavesBuildResult> _buildSavesPart({
    required LibraryGame game,
    required String workDir,
    List<String>? savePaths,
    required void Function(int percent) onProgress,
    required List<String> warnings,
  }) async {
    // 存档来源（Q14 存档确认）：
    // - savePaths == null  → 自动检测（历史行为，兼容既有调用）
    // - savePaths 非 null  → 用户在确认框勾选的清单，照单全收；空 = 明确不含存档
    final List<DetectedSaveFile> detected;
    if (savePaths != null) {
      if (savePaths.isEmpty) {
        warnings.add('按你的选择，本次归档不包含存档');
        return const _SavesBuildResult();
      }
      detected = await _resolveUserPickedPaths(savePaths, warnings);
      if (detected.isEmpty) {
        warnings.add('所选存档路径均不存在，本次归档只包含软件侧游戏数据');
        return const _SavesBuildResult();
      }
    } else {
      final scanner = SaveScanner();
      List<DetectedSaveFile> auto;
      try {
        auto = scanner.scanGameSaves(
          game.title,
          game.directoryPath.isNotEmpty ? game.directoryPath : game.metaDataDir,
          manifestEntry: null,
        );
      } catch (e) {
        debugPrint('[ARCHIVE] 存档扫描异常（按无存档处理）: $e');
        auto = const [];
      }
      detected = auto;
    }

    if (detected.isEmpty) {
      warnings.add('未检测到该游戏的存档，本次归档只包含软件侧游戏数据');
      return const _SavesBuildResult();
    }

    // 暂存：把散落在各盘的存档收集到一个可控的目录树，再整体压缩。
    //
    // 🔴 为什么必须暂存而不是直接压原始路径：存档可能散落在 C:\Users\... 与
    // 游戏目录两处，直接多路径压缩会让归档内部路径不可控，还原时无法
    // 干净地映射回原始绝对路径。暂存后归档内是 `<f0>/` `<d1>/` 这种无盘符
    // 结构，原始路径完整记录在 meta.json 的 `entries` 里。
    final stageRoot = p.join(workDir, _stageDirName, 'saves');
    try {
      await Directory(stageRoot).create(recursive: true);
    } catch (e) {
      return _SavesBuildResult(abortMessage: '无法创建存档暂存目录：$e');
    }

    final entries = <SaveEntryRef>[];
    var idx = 0;
    for (final d in detected) {
      final src = d.filePath;
      final type = FileSystemEntity.typeSync(src);
      if (type == FileSystemEntityType.notFound) continue;

      // 标签在确认条目确实存在之后才分配，避免失败时留空洞
      final isDir = type == FileSystemEntityType.directory;
      final tag = isDir ? 'd$idx' : 'f$idx';
      idx++;
      try {
        if (isDir) {
          await _copyDirectory(src, p.join(stageRoot, tag));
          entries.add(SaveEntryRef(
            path: src,
            size: d.size,
            stage: tag,
            isDir: true,
          ));
        } else {
          final destDir = p.join(stageRoot, tag);
          await Directory(destDir).create(recursive: true);
          final base = p.basename(src);
          await File(src).copy(p.join(destDir, base));
          entries.add(SaveEntryRef(
            path: src,
            size: d.size,
            stage: p.posix.join(tag, base),
          ));
        }
      } catch (e) {
        // 单个存档读不到不该毁掉整个归档，但要如实记录
        warnings.add('存档「$src」暂存失败，已跳过：$e');
      }
    }

    if (entries.isEmpty) {
      warnings.add('检测到存档路径但全部暂存失败，本次归档只包含软件侧游戏数据');
      return const _SavesBuildResult();
    }

    final archive = p.join(workDir, 'saves.7z');
    final outcome = await compressor.compressDirectory(
      sourceDir: stageRoot,
      outputArchive: archive,
      level: prefs.compressionLevel,
      onProgress: onProgress,
    );
    if (!outcome.ok) {
      return _SavesBuildResult(
        abortMessage: '压缩存档失败：${outcome.error}',
        cancelled: outcome.cancelled,
      );
    }
    return _SavesBuildResult(
      part: ArchivePartInfo(
        archive: p.basename(outcome.archivePath),
        bytes: outcome.bytes,
        fileCount: outcome.fileCount,
        sha256: outcome.sha256,
        entries: entries,
      ),
    );
  }

  /// 把用户确认的路径清单解析为可暂存的 [DetectedSaveFile] 列表。
  ///
  /// 不存在的路径不中止流程：记 warning 跳过（用户可能在确认后手动删了文件）。
  Future<List<DetectedSaveFile>> _resolveUserPickedPaths(
    List<String> paths,
    List<String> warnings,
  ) async {
    final out = <DetectedSaveFile>[];
    for (final path in paths) {
      final t = path.trim();
      if (t.isEmpty) continue;
      final type = FileSystemEntity.typeSync(t);
      if (type == FileSystemEntityType.notFound) {
        warnings.add('所选存档路径不存在，已跳过：$t');
        continue;
      }
      try {
        final stat = await FileStat.stat(t);
        final modified = stat.modified;
        if (type == FileSystemEntityType.directory) {
          final size = await FileSizePrefetchService.calculateDirectorySize(t);
          out.add(DetectedSaveFile(
            filePath: t,
            size: size,
            lastModified: modified,
            isDirectory: true,
            tag: 'user',
          ));
        } else {
          out.add(DetectedSaveFile(
            filePath: t,
            size: await File(t).length(),
            lastModified: modified,
            isDirectory: false,
            tag: 'user',
          ));
        }
      } catch (e) {
        warnings.add('所选存档路径读取失败，已跳过：$t | $e');
      }
    }
    // 同一路径只暂存一次（用户重复添加防护）
    final seen = <String>{};
    return out.where((f) => seen.add(f.filePath)).toList();
  }

  // ==================== 校验 ====================

  /// 对归档目录里的每个分片跑 `7z t`，并交叉比对文件数。
  Future<ArchiveOperationResult> verify(String archiveDir) async {
    final metaFile = File(p.join(archiveDir, ArchiveManifest.fileName));
    if (!await metaFile.exists()) {
      return ArchiveOperationResult.fail('缺少 ${
          ArchiveManifest.fileName}，该目录不是完整归档（可能是半成品）');
    }
    ArchiveManifest? manifest;
    try {
      manifest = ArchiveManifest.tryParse(await metaFile.readAsString());
    } catch (e) {
      return ArchiveOperationResult.fail('清单读取失败：$e');
    }
    if (manifest == null) {
      return ArchiveOperationResult.fail('清单无法解析');
    }
    final r = await _verifyDir(archiveDir, manifest);
    if (!r.ok) return ArchiveOperationResult.fail(r.error);
    final record = ArchiveRecord(
      archiveDir: archiveDir,
      id: p.basename(archiveDir),
      manifest: manifest,
    );
    return ArchiveOperationResult.ok0(record: record, warnings: r.warnings);
  }

  Future<_VerifyResult> _verifyDir(
      String archiveDir, ArchiveManifest manifest) async {
    final warnings = <String>[];
    for (final part in manifest.partArchives) {
      final file = p.join(archiveDir, part);
      if (!await File(file).exists()) {
        return _VerifyResult(ok: false, error: '分片缺失：$part');
      }
      final t = await compressor.testArchive(file);
      if (!t.ok) {
        return _VerifyResult(
            ok: false,
            error: '$part 校验失败（exit=${t.exitCode}）${t.detail.isEmpty ? '' : '\n${t.detail}'}');
      }
    }
    // 文件数交叉比对：清单里声明了多少，归档里就得有多少。
    //
    // 这一段是「删源/删本体」的最后一道闸 —— `7z t` 只保证归档自身可解，
    // 不保证解出来的东西跟归档前一致。文件数对不上就说明有文件没进去
    // （如权限跳过），此时绝不能声明备份成功。
    final appdata = manifest.appdata;
    if (appdata != null) {
      final bad = await _compareFileCount(
          archiveDir, 'appdata.7z', appdata.archive, appdata.fileCount);
      if (bad != null) return bad;
    }
    final saves = manifest.saves;
    if (saves != null) {
      final bad = await _compareFileCount(
          archiveDir, 'saves.7z', saves.archive, saves.fileCount);
      if (bad != null) return bad;
    }
    final body = manifest.body;
    if (body != null) {
      final bad = await _compareFileCount(
          archiveDir, 'body.7z', body.archive, body.fileCount);
      if (bad != null) return bad;
    }
    return _VerifyResult(ok: true, warnings: warnings);
  }

  /// 比对单个分片的「清单声明文件数」与「归档实际文件数」。
  /// 返回 `null` = 通过（或无法比对）。
  Future<_VerifyResult?> _compareFileCount(
    String archiveDir,
    String label,
    String archiveName,
    int declaredCount,
  ) async {
    if (archiveName.isEmpty || declaredCount < 0) return null;
    final t = await compressor.testArchive(p.join(archiveDir, archiveName));
    if (t.fileCount >= 0 && t.fileCount != declaredCount) {
      return _VerifyResult(
        ok: false,
        error: '$label 文件数不符：清单声明 $declaredCount，实际 ${t.fileCount}'
            '（可能有文件未被归档，已放弃本次归档）',
      );
    }
    return null;
  }

  // ==================== 列举 / 还原 ====================

  /// 列出某游戏的全部归档（按创建时间倒序）。
  ///
  /// 🔴 接收 [LibraryGame]（钥匙 = game_id，见 [gameRootFor]），不收裸 title ——
  /// 同名不同路径是合法场景，裸 title 无法唯一定位。
  Future<List<ArchiveRecord>> listArchives(LibraryGame game) async {
    final root = await _resolveRoot(game);
    final dir = Directory(root);
    if (!await dir.exists()) return const [];

    final out = <ArchiveRecord>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.endsWith('.partial')) continue; // 半成品不进列表
        final meta = File(p.join(e.path, ArchiveManifest.fileName));
        if (!await meta.exists()) continue;
        try {
          final m = ArchiveManifest.tryParse(await meta.readAsString());
          if (m == null) continue;
          out.add(ArchiveRecord(archiveDir: e.path, id: name, manifest: m));
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('[ARCHIVE] 列举归档异常: $e');
    }
    out.sort((a, b) {
      final ta = a.createdAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.createdAt?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });
    return out;
  }

  /// 还原「软件侧游戏数据」到 [targetDir]。
  ///
  /// 若目标目录缺 `.ctgame`（在库标记），会补一个 —— 否则还原出来的目录
  /// 不会被扫描进库，卡片也就回不来。这是 `appdata.7z` 排除 `.ctgame` 的配套兜底。
  Future<ArchiveOperationResult> restoreAppData({
    required ArchiveRecord record,
    required String targetDir,
    void Function(int percent)? onProgress,
  }) async {
    final part = record.manifest.appdata;
    if (part == null || part.archive.isEmpty) {
      return ArchiveOperationResult.fail('该归档不包含游戏数据段');
    }
    final archive = p.join(record.archiveDir, part.archive);
    try {
      await Directory(targetDir).create(recursive: true);
    } catch (e) {
      return ArchiveOperationResult.fail('无法创建还原目标目录：$targetDir | $e');
    }

    // 🔴 Q13 伴生保护：本地 game.json 是「封存期间仍会更新」的超集
    //    （relink 更新 launch_path、用户编辑字段），归档内的是封存前快照。
    //    解压会同名覆盖 —— 先暂存本地版，解压后原样写回，避免启动路径/编辑
    //    被旧快照打回；其余文件（封面/截图/统计）封存期间不变，照常覆盖还原。
    final localJson =
        File(p.join(targetDir, GameDataFormat.gameJsonFileName));
    List<int>? localJsonBytes;
    if (await localJson.exists()) {
      try {
        localJsonBytes = await localJson.readAsBytes();
      } catch (e) {
        debugPrint('[ARCHIVE] ⚠️ 本地 game.json 读取失败（按归档快照还原）: $e');
      }
    }

    final r = await compressor.extractArchive(
      archivePath: archive,
      outputDir: targetDir,
      onProgress: onProgress,
    );
    if (!r.ok) {
      return ArchiveOperationResult.fail('还原游戏数据失败：${r.error}',
          cancelled: r.cancelled);
    }

    final warnings = <String>[];
    if (localJsonBytes != null) {
      try {
        await localJson.writeAsBytes(localJsonBytes, flush: true);
      } catch (e) {
        warnings.add('保留本地 game.json 失败（已按归档快照还原）：$e');
      }
    }
    try {
      final marker = File(p.join(targetDir, GameDataFormat.ctgameFileName));
      if (!await marker.exists()) {
        await marker.writeAsString('', flush: true);
        warnings.add('已补回在库标记 .ctgame');
      }
    } catch (e) {
      warnings.add('补回 .ctgame 失败（游戏可能不会出现在库中）：$e');
    }
    return ArchiveOperationResult.ok0(warnings: warnings);
  }

  /// **解封/恢复前冲突预检**（Q13）：返回存档段还原时将覆盖的现有实体清单
  /// （manifest `saves.entries[].path` 逐条查磁盘）。
  ///
  /// 纯查询：不写盘、不解压、不动归档库。返回空列表 = 无冲突，可直接还原。
  Future<List<String>> checkRestoreConflicts(
      {required ArchiveRecord record}) async {
    final part = record.manifest.saves;
    if (part == null || part.entries.isEmpty) return const [];
    final conflicts = <String>[];
    for (final e in part.entries) {
      if (FileSystemEntity.typeSync(e.path) != FileSystemEntityType.notFound) {
        conflicts.add(e.path);
      }
    }
    return conflicts;
  }

  /// 还原存档到各自的**原始绝对路径**（映射见清单 `saves.entries`）。
  ///
  /// 单个条目失败不影响其它条目，失败清单如实回传（方案 §4.6）。
  ///
  /// 🔴 Q13：目标已有同路径实体时**默认拒绝**（防静默覆盖 —— 封存期间玩出的
  ///    新档会被旧档无提示盖掉）。UI 层应先 [checkRestoreConflicts] 预检，
  ///    用户明确选择「替换」后带 [replaceOld]=true 重入：旧实体**先移入回收站**
  ///    （可反悔），回收站失败的条目**跳过还原**并计入 [failures]。
  Future<ArchiveOperationResult> restoreSaves({
    required ArchiveRecord record,
    void Function(int percent)? onProgress,
    bool replaceOld = false,
  }) async {
    final part = record.manifest.saves;
    if (part == null || part.archive.isEmpty) {
      return ArchiveOperationResult.fail('该归档不包含存档段');
    }
    if (part.entries.isEmpty) {
      return ArchiveOperationResult.fail('存档段缺少原始路径映射，无法还原');
    }

    final failures = <String>[];
    final conflicts = await checkRestoreConflicts(record: record);
    if (conflicts.isNotEmpty && !replaceOld) {
      return ArchiveOperationResult.fail(
        '目标位置已有 ${conflicts.length} 处现有存档，拒绝覆盖：${conflicts.first}',
      );
    }
    final skipped = <String>{};
    if (conflicts.isNotEmpty && replaceOld) {
      for (final c in conflicts) {
        final rb = await RecycleBinService.moveToRecycleBin(c);
        if (!rb.ok) {
          skipped.add(c);
          failures.add('$c：旧档移入回收站失败（${rb.error ?? '未知'}），已跳过还原');
        }
      }
    }

    final archive = p.join(record.archiveDir, part.archive);
    final stage = Directory.systemTemp.createTempSync('ct_saves_restore_');
    try {
      final r = await compressor.extractArchive(
        archivePath: archive,
        outputDir: stage.path,
        onProgress: onProgress,
      );
      if (!r.ok) {
        return ArchiveOperationResult.fail('解包存档失败：${r.error}',
            cancelled: r.cancelled);
      }

      for (final entry in part.entries) {
        if (skipped.contains(entry.path)) continue; // 旧档回收失败，不动它
        try {
          final src = p.join(stage.path, p.joinAll(entry.stage.split('/')));
          if (entry.isDir) {
            if (!await Directory(src).exists()) {
              failures.add('${entry.path}：归档内缺少对应目录');
              continue;
            }
            await _copyDirectory(src, entry.path, overwrite: true);
          } else {
            final f = File(src);
            if (!await f.exists()) {
              failures.add('${entry.path}：归档内缺少对应文件');
              continue;
            }
            await Directory(p.dirname(entry.path)).create(recursive: true);
            await f.copy(entry.path);
          }
        } catch (e) {
          failures.add('${entry.path}：$e');
        }
      }
      return ArchiveOperationResult(
        ok: failures.isEmpty,
        error: failures.isEmpty ? null : '有 ${failures.length} 个存档条目还原失败',
        failures: failures,
      );
    } finally {
      await _deleteQuietly(stage);
    }
  }

  // ==================== 解包 ====================

  /// **解包**：把打包态归档里的 `body.7z` 解压回 [ArchiveBodyInfo.originalDir]
  /// （Q4 决策：一期只解回原目录，不做跨盘自选）。
  ///
  /// 安全边界：
  /// - 目标目录**已存在则拒绝**（⛔ 不覆盖已有本体目录，避免冲掉用户重建的数据）；
  /// - 目标不得落在归档目录自身之内（防把解压产物写进归档库）；
  /// - 解压前先 `7z t` 全量校验（GB 级解压到一半发现损坏是最坏结局）；
  /// - 空间预检：目标盘剩余空间须 ≥ `unpackedBytes`（不足时明确报错，Q4）。
  ///
  /// 状态回写（`packed → normal`）**不在本方法内做** —— 与 `_unseal` 的既有
  /// 约定一致：由 UI 在拿到 ok 后统一写，保证失败时状态绝不先变。
  Future<ArchiveOperationResult> unpack({
    required ArchiveRecord record,
    void Function(int percent)? onProgress,
  }) async {
    final body = record.manifest.body;
    if (body == null || body.archive.isEmpty) {
      return ArchiveOperationResult.fail('该归档不包含游戏本体段（可能是封装态归档）');
    }
    if (record.manifest.state != ArchiveManifest.statePacked) {
      return ArchiveOperationResult.fail(
          '归档状态为「${record.manifest.state}」，只有打包态归档可解包');
    }
    final bodyArchive = p.join(record.archiveDir, body.archive);
    if (!await File(bodyArchive).exists()) {
      return ArchiveOperationResult.fail('本体分片缺失：$bodyArchive');
    }
    final target = body.originalDir.trim();
    if (target.isEmpty) {
      return ArchiveOperationResult.fail('清单未记录原始本体目录，无法解包');
    }

    // ---- 目标路径守卫 ----
    final normTarget = p.normalize(target);
    final normArchiveDir = p.normalize(record.archiveDir);
    if (p.equals(normTarget, normArchiveDir) || p.isWithin(normArchiveDir, normTarget)) {
      return ArchiveOperationResult.fail('解包目标位于归档库内部，拒绝执行：$target');
    }
    final targetDir = Directory(normTarget);
    if (await targetDir.exists()) {
      return ArchiveOperationResult.fail(
          '目标目录已存在，拒绝解包（不覆盖）：$normTarget\n'
          '若确认要放到这里，请先手动移走或重命名该目录');
    }

    // ---- 空间预检（明确报错，Q4）----
    final needBytes = body.unpackedBytes > 0 ? body.unpackedBytes : 0;
    final spaceErr = await _precheckSpace(
      targetDir: normTarget,
      requiredBytes: needBytes,
      label: '解包目标',
    );
    if (spaceErr != null) return ArchiveOperationResult.fail(spaceErr);

    // ---- 先全量校验再解压 ----
    final t = await compressor.testArchive(bodyArchive);
    if (!t.ok) {
      return ArchiveOperationResult.fail(
          '本体分片校验未通过（exit=${t.exitCode}）'
          '${t.detail.isEmpty ? '' : '\n${t.detail}'}');
    }

    // ---- 解压（归档根 = 本体目录内容，cwd + `*` 打包，直接解到原目录）----
    try {
      await targetDir.create(recursive: true);
    } catch (e) {
      return ArchiveOperationResult.fail('无法创建解包目标目录：$normTarget | $e');
    }
    final r = await compressor.extractArchive(
      archivePath: bodyArchive,
      outputDir: normTarget,
      onProgress: onProgress,
    );
    if (!r.ok) {
      return ArchiveOperationResult.fail('解包失败：${r.error}', cancelled: r.cancelled);
    }

    // ---- 文件数交叉比对（不符只警告 —— 数据已落盘，报错反而无措）----
    final warnings = <String>[];
    if (body.fileCount > 0) {
      final actual = await ArchiveCompressor.countFilesRecursive(normTarget);
      if (actual >= 0 && actual != body.fileCount) {
        warnings.add('解包后文件数（$actual）与清单声明（${body.fileCount}）不符，'
            '建议在归档列表执行「校验」确认归档完整性');
      }
    }
    return ArchiveOperationResult.ok0(record: record, warnings: warnings);
  }

  // ==================== 清理 ====================

  /// 按保留份数清理旧归档。返回删除数量。
  ///
  /// 🔴 归档库若不在应用自有目录内（`PathHelper.isInsideAppStorage == false`），
  /// 一律拒绝删除并返回 0（ADR-007：用户可见路径的删除必须显式确认；
  /// 这里连"删自己的旧备份"都要先确认过归属）。调用方可在拿到用户明确同意后，
  /// 通过 [allowOutsideAppStorage] 放行。
  Future<int> pruneArchives(
    LibraryGame game, {
    int? keep,
    bool allowOutsideAppStorage = false,
  }) async {
    final records = await listArchives(game);
    final limit = keep ?? prefs.retention;
    if (records.length <= limit) return 0;

    final victims = records.sublist(limit);
    if (!allowOutsideAppStorage && !prefs.rootInsideAppStorage) {
      debugPrint('[ARCHIVE] ⛔ 归档库位于应用目录之外，拒绝自动清理：${prefs.rootPath}');
      return 0;
    }
    var removed = 0;
    for (final v in victims) {
      if (!allowOutsideAppStorage && !PathHelper.isInsideAppStorage(v.archiveDir)) {
        debugPrint('[ARCHIVE] ⛔ 跳过越界归档目录：${v.archiveDir}');
        continue;
      }
      if (await _deleteQuietly(Directory(v.archiveDir))) removed++;
    }
    return removed;
  }

  /// 清理某游戏归档库下的半成品（`.partial` 目录 / 文件）。返回清理数量。
  ///
  /// 半成品判据（双重）：目录名以 `.partial` 结尾，**或**目录里没有 `meta.json`。
  /// 后者覆盖"改名成功但清单没写进去"的异常窗口。
  Future<int> cleanupPartials(LibraryGame game) async {
    final root = await _resolveRoot(game);
    final dir = Directory(root);
    if (!await dir.exists()) return 0;
    if (!PathHelper.isInsideAppStorage(root)) {
      debugPrint('[ARCHIVE] ⛔ 归档库位于应用目录之外，跳过半成品清理：$root');
      return 0;
    }
    var n = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (name.endsWith('.partial')) {
            if (await _deleteQuietly(e)) n++;
            continue;
          }
          // 目录在但没有清单 = 上次写到一半（或清单写失败）
          final meta = File(p.join(e.path, ArchiveManifest.fileName));
          if (!await meta.exists()) {
            if (await _deleteQuietly(e)) n++;
          }
        } else if (e is File && name.endsWith('.partial')) {
          if (await _deleteQuietly(e)) n++;
        }
      }
    } catch (e) {
      debugPrint('[ARCHIVE] 半成品清理异常: $e');
    }
    return n;
  }

  /// 删除**单份**归档（整目录，含其全部分片）。返回是否删除成功。
  ///
  /// 🔴 与 [pruneArchives] 同一套护栏：归档库被配到应用目录之外时一律拒绝，
  /// 除非调用方拿到用户**明确同意**（确认框已明示真实绝对路径）后传
  /// `allowOutsideAppStorage: true` —— 这正是"归档库可指向别的盘"（方案 §5.5）
  /// 场景下唯一可行的删除路径。
  ///
  /// ⚠️ 本方法只删归档副本，**永不触碰游戏本体与元数据目录**。
  /// 回收站化（ADR-007「优先回收站」）与删本体共用 Phase 3 的回收站服务，届时一并升级。
  Future<bool> deleteArchive(
    ArchiveRecord record, {
    bool allowOutsideAppStorage = false,
  }) async {
    final target = record.archiveDir;
    if (target.trim().isEmpty) return false;

    // 越界拒绝：只允许删归档库根**之下**的目录（<根>/<游戏>/<归档id>）
    final root = p.normalize(prefs.rootPath);
    final norm = p.normalize(target);
    if (p.equals(norm, root) || !p.isWithin(root, norm)) {
      debugPrint('[ARCHIVE] ⛔ 拒绝删除越界路径（不在归档库内）: $target');
      return false;
    }
    if (!allowOutsideAppStorage && !PathHelper.isInsideAppStorage(target)) {
      debugPrint('[ARCHIVE] ⛔ 归档目录在应用目录之外，需显式放行才能删除：$target');
      return false;
    }

    final ok = await _deleteQuietly(Directory(target));
    await CleanupLog.append({
      'op': 'archive_delete',
      'target': target,
      'archiveId': record.id,
      'state': record.state,
      'result': ok ? 'ok' : 'fail',
      'reason': 'user_delete_archive',
    });
    return ok;
  }

  // ==================== latest 指针 ====================

  Future<void> _writeLatestPointer(LibraryGame game, String archiveId) async {
    try {
      final root = gameRootFor(game);
      await Directory(root).create(recursive: true);
      final f = File(p.join(root, _latestFileName));
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'latest': archiveId,
          'updated_at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('[ARCHIVE] 写 latest 指针失败（不影响归档本体）: $e');
    }
  }

  /// 读最新归档目录名；无指针返回 `null`。
  Future<String?> readLatestPointer(LibraryGame game) async {
    try {
      final f = File(p.join(gameRootFor(game), _latestFileName));
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      if (json is Map) return json['latest'] as String?;
    } catch (_) {}
    return null;
  }

  // ==================== 工具 ====================

  /// 归档库可用空间预检。
  ///
  /// 空间信息不可信时**放行**（`isAvailable=false` 或负值），让实际写盘失败兜底
  /// —— 与 `game_move_service.dart:131` 的既有降级策略一致，不因为探测不到空间
  /// 就把功能锁死。
  Future<String?> _precheckSpace({
    required String targetDir,
    int requiredBytes = 0,
    String label = '归档库',
  }) async {
    try {
      final info = await PathValidator.getDiskSpaceInfo(targetDir);
      if (!info.isAvailable || info.freeSpaceBytes < 0) return null;
      final need = requiredBytes > 0 ? requiredBytes : 64 * 1024 * 1024;
      if (info.freeSpaceBytes < (need * 1.05).round()) {
        return '$label所在磁盘空间不足：需要约 '
            '${FileSizePrefetchService.formatBytes((need * 1.05).round())}，'
            '仅剩 ${FileSizePrefetchService.formatBytes(info.freeSpaceBytes)}';
      }
    } catch (e) {
      debugPrint('[ARCHIVE] 空间预检异常（放行）: $e');
    }
    return null;
  }

  /// 把绝对路径表达成「相对 exeDir」；不在应用目录内则原样返回绝对路径。
  static String _relativeToExe(String abs) {
    final norm = p.normalize(abs);
    final base = p.normalize(PathHelper.exeDir);
    if (p.equals(norm, base) || p.isWithin(base, norm)) {
      return p.relative(norm, from: base).replaceAll(r'\', '/');
    }
    return norm;
  }

  /// 应用版本（写进清单，便于日后排查"哪个版本产生的归档"）。
  ///
  /// `PackageInfo` 是平台通道，在纯单测环境会抛异常 —— 一律吞掉返回空串，
  /// **绝不让一个版本号把归档流程搞挂**。
  static Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '';
    }
  }

  static Future<void> _copyDirectory(
    String from,
    String to, {
    bool overwrite = false,
  }) async {
    final src = Directory(from);
    if (!await src.exists()) return;
    await Directory(to).create(recursive: true);
    await for (final e in src.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: from);
      final dest = p.join(to, rel);
      if (e is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (e is File) {
        await Directory(p.dirname(dest)).create(recursive: true);
        final target = File(dest);
        if (!overwrite && await target.exists()) continue;
        await e.copy(dest);
      }
    }
  }

  static Future<bool> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
      return true;
    } catch (e) {
      debugPrint('[ARCHIVE] 删除失败（忽略）: ${entity.path} | $e');
      return false;
    }
  }
}

/// 结果内部类型：存档段构建
class _SavesBuildResult {
  final ArchivePartInfo? part;
  final String? abortMessage;
  final bool cancelled;
  const _SavesBuildResult({this.part, this.abortMessage, this.cancelled = false});
}

class _VerifyResult {
  final bool ok;
  final String error;
  final List<String> warnings;
  const _VerifyResult({required this.ok, this.error = '', this.warnings = const []});
}
