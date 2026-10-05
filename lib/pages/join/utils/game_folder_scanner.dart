import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../services/import_dedup_index.dart';
import '../../../services/scan_logger.dart';
import '../../../utils/network_path.dart';
import '../../../utils/path_normalizer.dart';
import '../../../utils/title_cleaner.dart';
import 'gal_game_detector.dart';

/// 扫描识别出的游戏（目录 + 检测结果 + 推断标题）
class ScannedGame {
  /// 游戏目录绝对路径
  final String path;

  /// 识别器检测结果（置信度 / 依据 / 引擎 / 主程序）
  final GalDetectionResult detection;

  /// 推断标题（TitleCleaner 清洗文件夹名，清洗为空时回退文件夹名）
  final String title;

  /// 同名软警告（库中已有同名游戏，不阻止导入，仅供 UI 提示）
  final String? duplicateWarning;

  const ScannedGame({
    required this.path,
    required this.detection,
    required this.title,
    this.duplicateWarning,
  });
}

/// 单个目录在扫描管线中的最终决策（供调用方做日志 / 统计 / 渐进入队）
class ScanDecision {
  /// 是否被接受为游戏
  final bool accepted;

  /// 跳过原因（accepted = false 时必填）
  final ScanSkipReason? reason;

  /// 识别器检测结果（无主程序等场景可能为 null）
  final GalDetectionResult? detection;

  /// 接受时的完整游戏信息（accepted = true 时非空）
  final ScannedGame? game;

  ScanDecision.accepted(ScannedGame this.game)
      : accepted = true,
        reason = null,
        detection = game.detection;

  const ScanDecision.skipped(this.reason, [this.detection])
      : accepted = false,
        game = null;
}

/// 识别后的游戏候选（内部暂存：路径 + 检测结果）
///
/// ★ P0-5（2026-09-16 稳定性审计）：路径规范化结果与"清洗后标题键"**缓存**。
/// 去重阶段（4a/4b/4c/阶段五）原先对每对候选现场调用
/// `PathNormalizer.forCompare` / `TitleCleaner.cleanFromDirPath`（含正则），
/// 2000 条时是数百万~上千万次重复计算，全部跑在 UI isolate。
class _DetectedGame {
  final String path;
  final GalDetectionResult detection;

  /// 预计算的规范化路径（小写、`\` 分隔），用于 O(1) 包含判定
  final String normalizedPath;

  /// 预计算的路径段数（用于深度排序与"取更浅者"平手裁决）
  final int segCount;

  String? _titleKey;

  factory _DetectedGame(String path, GalDetectionResult detection) {
    final norm = PathNormalizer.forCompare(path);
    return _DetectedGame._(path, detection, norm);
  }

  _DetectedGame._(this.path, this.detection, this.normalizedPath)
      : segCount = normalizedPath.split('\\').length;

  /// 清洗后标题键（同名副本判重），惰性计算 + 缓存
  String get titleKey => _titleKey ??=
      TitleCleaner.normalizeForCompare(TitleCleaner.cleanFromDirPath(path));
}

/// 游戏文件夹扫描器 —— 批量导入与智能导入共享的五阶段识别管线
///
/// 提取自批量导入（BatchImportController.scanFolderForGames）的成熟算法，
/// 供两种导入模式共用，保证识别行为完全一致。
///
/// 智能导入此前只做了「逐目录 detect」这一步，缺失后四个阶段，导致：
/// - 同一游戏的多个子模块被重复识别成多款游戏（缺父子重叠 / 共享启动程序去重，
///   如 Ren'Py 游戏根目录与它的 game/ 子目录同时入库）
/// - 启动器型合集连同每个子游戏一起被重复导入（缺归纳文件夹剔除）
/// - 无主程序或通用名目录被误判为游戏（缺主程序门槛与通用名拦截，
///   如仅含 config.ini 的目录、名为 game/bin 的目录）
///
/// 五阶段：
/// 1. 收集候选目录（排除规则 + 隐藏目录 + 深度限制）
/// 2. 逐目录严格识别：根目录保护 → 多维排重 → 主程序门槛 → 通用名拦截
///    → 置信度阈值（[minConfidence]）
/// 2.5 包装文件夹救援（主程序在子目录的 CJK 命名游戏，提升父目录为游戏）
/// 3. 归纳文件夹剔除（启动器型合集含 ≥2 个游戏子目录时移除合集本身）
/// 4. 最终去重：同名副本（清洗后同题且引擎兼容，保留识别度最高者）
///    → 父子重叠（深度升序遍历，保留祖先）→ 救援包装传播（包装目录的
///    内容游戏在别处已有代表时一并淘汰）
/// 5. 共享启动程序去重（父子目录解析到同一 exe 且深度差 ≤1 时跳过子目录）
class GameFolderScanner {
  GameFolderScanner._();

  /// 扫描 [rootPath] 下的游戏目录，返回最终识别出的游戏列表
  ///
  /// [excludePatterns] 排除目录关键词（小写包含匹配，命中则该子目录不收集）
  /// [maxDepth] 递归收集最大深度（根为 0 层）
  /// [candidates] 预收集的候选目录（null 时从 rootPath 现场收集；
  ///   智能导入传入 TTL 过滤后的列表以复用缓存语义）
  /// [dedupIndex] 已入库排重索引（null 时跳过阶段 2a 排重）
  /// [minConfidence] 额外置信度门槛（默认 0 = 仅按识别器 isGame 判定；
  ///   智能导入传入用户设置的识别灵敏度）
  /// [onEvaluateStart] 每个候选开始评估时回调（进度展示）
  /// [onDecision] 每个目录的最终决策回调；accepted 决策在阶段 5 逐个触发，
  ///   调用方可据此渐进入队（智能导入的发现队列实时填充）
  static Future<List<ScannedGame>> scanGames({
    required String rootPath,
    List<String> excludePatterns = const [],
    int maxDepth = 4,
    List<String>? candidates,
    ImportDedupIndex? dedupIndex,
    double minConfidence = 0.0,
    void Function(String dirPath)? onEvaluateStart,
    void Function(String dirPath, ScanDecision decision)? onDecision,
  }) async {
    final rootNormalized = PathNormalizer.forCompare(rootPath);

    // ★ IMP-12 批A：本次扫描内复用"启动程序检测结果"。
    // 阶段五会对每对父子关系各调 2 次 detectLaunchExe（整树同步遍历），
    // 无缓存时是 O(n²) 次全树扫描 —— 300GB 收藏下 UI 长时间冻结的主因之一。
    // 缓存随本次扫描创建、结束即弃，不存在跨扫描的过期问题。
    final launchExeCache = <String, String?>{};

    // ===== 阶段一：收集候选目录 =====
    // 对齐 watch_folder_service._collectCandidateDirs 的两阶段架构：
    // 先按排除规则过滤，再做精确识别。
    final candidateList = <String>[];
    if (candidates == null) {
      await collectCandidates(
        Directory(rootPath),
        candidateList,
        depth: 0,
        maxDepth: maxDepth,
        excludePatterns: excludePatterns,
      );
    } else {
      candidateList.addAll(candidates);
    }
    debugPrint('[SCAN] 阶段一：收集到 ${candidateList.length} 个候选目录');

    // ===== 阶段二：逐个识别（不做父子重叠去重）=====
    // 关键：先收集所有识别为游戏的目录，再做后处理。
    // 否则"先识别的保留"式循环内去重会导致根目录（如 GAL 文件夹）
    // 被识别后，所有子目录游戏都因父子重叠被跳过。
    final detected = <_DetectedGame>[];
    // 检测结果缓存：记录所有 mainExeName != null 的候选检测结果，
    // 供阶段 2.5 包装文件夹救援复用，避免对同一目录重复调用 detect()。
    final detectionCache = <String, GalDetectionResult>{};
    // 阶段 2a 的同名软警告（携带至最终结果）
    final duplicateWarnings = <String, String>{};
    // 已评估候选计数（用于周期性让出事件循环，避免大规模扫描阻塞 UI）
    var evaluatedCount = 0;

    for (final candidatePath in candidateList) {
      // ★ 根目录保护：扫描根目录本身不作为单个游戏
      // （即使根目录恰好含 exe，也应让扫描进入子目录发现各游戏）
      if (PathNormalizer.forCompare(candidatePath) == rootNormalized) {
        debugPrint('[SCAN] ⊘ 跳过根目录本身（不作为游戏）: $candidatePath');
        continue;
      }

      onEvaluateStart?.call(candidatePath);

      // 每 25 个候选让出一次事件循环：识别器的文件扫描是同步 I/O，
      // 大规模目录（数百个候选）连续评估会长时间不yield，冻结 UI 帧
      //（智能导入 watcher 扫描在 UI isolate 执行，必须周期性让出）
      if (++evaluatedCount % 25 == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      final folderName = candidatePath.split('/').last.split('\\').last;

      // 2a. 多维排重（路径包含硬跳过 + 同名软警告）
      if (dedupIndex != null) {
        final cleanedTitle = TitleCleaner.cleanFromDirPath(candidatePath);
        final inferredTitle =
            cleanedTitle.isNotEmpty ? cleanedTitle : folderName;
        final verdict = dedupIndex.check(candidatePath, title: inferredTitle);
        if (verdict.isHardConflict) {
          debugPrint(
              '[SCAN] ✗ 跳过已导入游戏: $folderName | ${verdict.reason}');
          onDecision?.call(candidatePath,
              const ScanDecision.skipped(ScanSkipReason.pathConflict));
          continue;
        }
        if (verdict.hasWarning) {
          duplicateWarnings[candidatePath] = verdict.reason;
        }
      }

      // 2b. 严格识别（主程序门槛 + 通用名拦截 + 置信度阈值）
      final detection = _detectIndependentGame(candidatePath);
      // 缓存非 null 检测结果（mainExeName != null），供阶段 2.5 救援复用
      if (detection != null) {
        detectionCache[candidatePath] = detection;
      }
      if (detection == null ||
          !detection.isGame ||
          detection.confidence < minConfidence) {
        final reason = detection == null
            ? ScanSkipReason.noExecutable
            : ScanSkipReason.lowConfidence;
        debugPrint('[SCAN] ✗ 跳过（非游戏）: $folderName | '
            '${detection?.reasonSummary ?? "无可执行文件"}');
        onDecision?.call(
            candidatePath, ScanDecision.skipped(reason, detection));
        continue;
      }

      debugPrint('[SCAN] ✓ 候选游戏: $folderName ($candidatePath) | '
          '${detection.reasonSummary}');
      detected.add(_DetectedGame(candidatePath, detection));
    }

    // ===== 阶段 2.5：包装文件夹救援（exe 在子目录场景）=====
    // 场景：游戏本体文件夹（如"命运石之门"）本身无直接 exe——exe 在 bin/、
    //       launcher/ 等子目录中。直接签名门控使其 isGame=false 被跳过；
    //       含 exe 的子目录又因通用名拦截或自身非游戏也被跳过 → 游戏完全漏识别。
    //       这是直接签名门控引入的回归风险点，必须救援。
    // 修复：扫描未被识别的候选，若它有「继承 exe」（mainExeInherited，即 exe 在
    //       子目录）、非通用名、CJK 名、无直接签名、且含 <2 个游戏子目录（避免
    //       救起容器），提升为游戏。复用阶段二的 detectionCache 避免重复 detect()。
    final rescuedParents = <_DetectedGame>[];
    for (final candidatePath in candidateList) {
      final normalized = PathNormalizer.forCompare(candidatePath);
      // 已识别 / 已救援 / 根目录本身 → 跳过
      if (detected
          .any((d) => PathNormalizer.forCompare(d.path) == normalized)) {
        continue;
      }
      if (rescuedParents
          .any((d) => PathNormalizer.forCompare(d.path) == normalized)) {
        continue;
      }
      if (normalized == rootNormalized) continue;

      // 复用缓存的检测结果（无缓存说明 mainExeName == null，无 exe 无法救援）
      final cached = detectionCache[candidatePath];
      if (cached == null) continue;
      // 必须有继承 exe（exe 在子目录）且无直接签名（有直接签名的应已被阶段二识别）
      if (!cached.mainExeInherited || cached.mainExeName == null) continue;
      if (cached.hasDirectSignature) continue;

      final folderName = candidatePath.split('/').last.split('\\').last;
      // 通用名 → 不救援（GAL、bin、存档备份等本身不应作为游戏导入）
      if (_isGenericName(folderName.toLowerCase())) continue;
      // 非 CJK 名 → 不救援（避免误救 Downloads/Games 等英文系统文件夹）
      if (!_containsCjk(folderName)) continue;

      // 含 ≥2 个游戏子目录 → 容器（如 JRPG/系列合集），不救援
      final childGameCount = detected
          .where((other) =>
              PathNormalizer.isSubdirectory(candidatePath, other.path))
          .length;
      if (childGameCount >= 2) {
        debugPrint('[SCAN] ⊘ 救援判定："$folderName" 含 $childGameCount 个'
            '游戏子目录，判定为容器不救援');
        continue;
      }

      debugPrint('[SCAN] 🔄 包装文件夹救援: $candidatePath '
          '(无直接签名，继承 exe "${cached.mainExeName}"，提升为游戏)');
      rescuedParents.add(_DetectedGame(
        candidatePath,
        GalDetectionResult(
          confidence: 0.4,
          isGame: true,
          strongSignals: cached.strongSignals,
          mediumSignals: cached.mediumSignals,
          weakSignals: cached.weakSignals,
          negativeSignals: cached.negativeSignals,
          engineType: cached.engineType,
          mainExeName: cached.mainExeName,
          mainExeInherited: true,
        ),
      ));
    }
    detected.addAll(rescuedParents);
    if (rescuedParents.isNotEmpty) {
      debugPrint('[SCAN] 阶段 2.5：救援了 ${rescuedParents.length} 个包装文件夹');
    }

    // ===== 阶段三：移除归纳文件夹 =====
    // 容器文件夹（GAL/JRPG）会因检测器 2 层扫描继承子游戏的引擎文件而获得
    // 强信号，但直接签名判定（isGame 要求直接签名）已使容器不进入 detected。
    // 本阶段专注于「启动器型合集」：有直接 exe 但含 ≥2 个游戏子目录 → 容器。
    final aggregateFolders = <_DetectedGame>[];
    final kept = detected.where((g) {
      // 救援提升的游戏（阶段 2.5 构造，isGame=true 但无直接签名）直接保留
      if (g.detection.isGame && !g.detection.hasDirectSignature) return true;

      // 有直接强信号（引擎核心文件直接在本文件夹）→ 真实游戏本体，保留
      if (g.detection.hasDirectStrongSignal) return true;
      // 有直接数据包 + 特征目录 → 真实游戏本体，保留
      if (g.detection.hasDirectDataPack && g.detection.hasDirectFeatureDir) {
        return true;
      }
      // 有直接 exe：可能是真实游戏，也可能是启动器型合集
      // 启动器型合集（如 Launcher.exe + Game1/ + Game2/）含 ≥2 个游戏子目录 → 容器
      // ★ P0-5：子目录判定用预计算规范化路径前缀比较（旧实现每对 2 次 forCompare，
      //   2000 条时约 800 万次，是扫描阶段另一个 CPU 热点）
      if (g.detection.hasDirectExe) {
        final childGameCount = detected
            .where((other) =>
                other != g &&
                other.detection.isGame &&
                _isUnderNorm(g.normalizedPath, other.normalizedPath))
            .length;
        if (childGameCount >= 2) {
          aggregateFolders.add(g);
          return false; // 启动器型容器，移除
        }
        return true; // 直接 exe + 0-1 游戏子目录 → 真实游戏
      }

      // 无直接签名（安全网：正常情况下容器不会进入 detected）
      final hasChildGame = detected.any((other) =>
          other != g && _isUnderNorm(g.normalizedPath, other.normalizedPath));
      if (!hasChildGame) return true; // 无子游戏，保留
      aggregateFolders.add(g);
      return false; // 有子游戏 + 无直接签名 → 容器，移除
    }).toList();

    for (final af in aggregateFolders) {
      final folderName = af.path.split('/').last.split('\\').last;
      debugPrint('[SCAN] ✗ 跳过（归纳文件夹）: $folderName (${af.path}) | '
          '含 ${detected.where((o) => o != af && _isUnderNorm(af.normalizedPath, o.normalizedPath)).length} 个游戏子目录');
      onDecision?.call(af.path,
          ScanDecision.skipped(ScanSkipReason.aggregateFolder, af.detection));
    }

    // ===== 阶段 4：最终去重（★ 2026-09-13 排重修复，三步按优先级）=====
    // 旧管线只有「父子重叠」「共享启动程序」两种**路径维度**去重，存在三个洞：
    // ① 同一游戏以相同（清洗后）名称出现在互不包含的两个位置（如
    //    「E:\GAL\远月少女的礼仪.1」与「E:\GAL\远月少女的礼仪.2.1\远月少女的
    //    礼仪.1」，解压残缺/搬家残留的典型产物）→ 双双入队、双双入库；
    // ② 阶段 2.5 救援的父目录 append 在 detected 末尾，"子先父后"使父子
    //    重叠去重失效（isSubdirectory(子, 父) = false）；
    // ③ 救援父目录（无直接签名、游戏身份完全借用子目录内容）包裹的子游戏
    //    被同名去重淘汰后，父目录仍以自己的目录名存活 → 换名的第三份副本。
    //
    // -- 4a 同名副本：按 [TitleCleaner.normalizeForCompare] 键分组，组内保留
    //    识别度最高者（平手取路径更浅者）。保守门：组内出现两个**明确不同**
    //    的引擎类型（kirikiri vs unity 等）时整组不合并 —— 同名但引擎不同
    //    更可能是两个不同游戏。
    final titleLosers = <_DetectedGame>{};
    final titleGroups = <String, List<_DetectedGame>>{};
    for (final g in kept) {
      final key = g.titleKey; // ★ P0-5: 缓存键，避免逐对重算正则
      if (key.isEmpty) continue; // 无可比键 → 不参与同名合并（宁可保留）
      (titleGroups[key] ??= []).add(g);
    }
    titleGroups.forEach((key, members) {
      if (members.length < 2) return;
      final engines = members
          .map((m) => m.detection.engineType)
          .where((e) => e != 'unknown')
          .toSet();
      if (engines.length > 1) {
        debugPrint('[SCAN] ⊘ 同名判定："$key" 组内引擎冲突 '
            '(${engines.join("/")})，保守保留全部 ${members.length} 份');
        return;
      }
      _DetectedGame best = members.first;
      for (final m in members.skip(1)) {
        if (_preferGame(m, best)) best = m;
      }
      for (final m in members) {
        if (!identical(m, best)) titleLosers.add(m);
      }
    });

    // -- 4b 父子重叠：保留祖先、跳过后代（与旧语义一致）。先按路径深度
    //    **升序稳定排序**再遍历，保证祖先先于后代（修洞②）；同名淘汰者
    //    不参与，避免子副本被祖先吸收而抵消 4a 的裁决。
    //    ★ P0-5：包含判定改用**预计算规范化路径的前缀比较**（零再规范化）。
    final deduped = <_DetectedGame>[];
    final ordered = kept.where((g) => !titleLosers.contains(g)).toList()
      ..sort((a, b) {
        if (a.segCount != b.segCount) return a.segCount - b.segCount;
        return a.normalizedPath.compareTo(b.normalizedPath);
      });
    for (final g in ordered) {
      final isChildOfExisting = deduped
          .any((existing) => _isUnderNorm(existing.normalizedPath, g.normalizedPath));
      if (isChildOfExisting) {
        final folderName = g.path.split('/').last.split('\\').last;
        debugPrint('[SCAN] ✗ 跳过（父子重叠）: $folderName (${g.path})');
        onDecision?.call(g.path,
            const ScanDecision.skipped(ScanSkipReason.parentChildOverlap));
        continue;
      }
      deduped.add(g);
    }

    // -- 4c 救援传播（修洞③）：无直接签名的救援父目录，其游戏身份完全
    //    借用子目录内容；若其子树内某游戏的标题键在子树**之外**也存在
    //    （= 同一游戏在别处已有代表），则该父目录只是"换名的另一份副本"，
    //    一并淘汰。有直接签名的真实游戏本体不参与本步（它们已在 4a 以
    //    自身身份参与同名裁决）。
    //    ★ P0-5：只对救援父目录（数量极少）执行，且全用缓存键/前缀比较。
    final rescuedWrapperLosers = <_DetectedGame>[];
    for (final g in deduped) {
      if (g.detection.hasDirectSignature) continue; // 只约束救援提升的父目录
      final keysInside = <String>{};
      for (final k in kept) {
        if (!_isUnderNorm(g.normalizedPath, k.normalizedPath)) continue;
        if (k.titleKey.isNotEmpty) keysInside.add(k.titleKey);
      }
      if (keysInside.isEmpty) continue;
      final duplicatedOutside = kept.any((k) {
        if (_isUnderNorm(g.normalizedPath, k.normalizedPath)) return false;
        return k.titleKey.isNotEmpty && keysInside.contains(k.titleKey);
      });
      if (duplicatedOutside) rescuedWrapperLosers.add(g);
    }
    for (final g in rescuedWrapperLosers) {
      deduped.remove(g);
      final folderName = g.path.split('/').last.split('\\').last;
      debugPrint('[SCAN] ✗ 跳过（救援包装目录，其内容游戏在别处已有代表）: '
          '$folderName (${g.path})');
      onDecision?.call(g.path,
          ScanDecision.skipped(ScanSkipReason.duplicateTitle, g.detection));
    }
    if (titleLosers.isNotEmpty || rescuedWrapperLosers.isNotEmpty) {
      debugPrint('[SCAN] 阶段 4：去除 ${titleLosers.length} 份同名副本、'
          '${rescuedWrapperLosers.length} 个救援包装目录');
    }

    // ===== 阶段五：共享启动程序去重 + 构建结果 =====
    final foundGames = <ScannedGame>[];
    // ★ P0-5：与 foundGames 同序的候选对象（携带预计算规范化路径/段数，
    //   替代每对调用 PathNormalizer.isSubdirectory / depthOf 的重算）
    final foundNorm = <_DetectedGame>[];
    for (final g in deduped) {
      if (_hasSameParentGame(foundNorm, g, launchExeCache)) {
        final folderName = g.path.split('/').last.split('\\').last;
        debugPrint('[SCAN] ✗ 跳过（共享启动程序）: $folderName (${g.path})');
        onDecision?.call(
            g.path, const ScanDecision.skipped(ScanSkipReason.sharedLauncher));
        continue;
      }

      // ★ P0-5：复用缓存键（旧实现每游戏一次 cleanFromDirPath 正则，可接受，
      //   但键已算过就直接用）
      final cleanedName = TitleCleaner.cleanFromDirPath(g.path);
      final folderName = g.path.split('/').last.split('\\').last;
      final effectiveTitle = cleanedName.isNotEmpty ? cleanedName : folderName;
      debugPrint('[SCAN] ✓ 识别到游戏: $folderName (${g.path}) | '
          '${g.detection.reasonSummary}');
      final game = ScannedGame(
        path: g.path,
        detection: g.detection,
        title: effectiveTitle,
        duplicateWarning: duplicateWarnings[g.path],
      );
      foundGames.add(game);
      foundNorm.add(g);
      onDecision?.call(g.path, ScanDecision.accepted(game));
    }

    debugPrint('[SCAN] 识别完成：候选 ${detected.length} 个，'
        '归纳文件夹 ${aggregateFolders.length} 个，'
        '最终识别 ${foundGames.length} 个游戏');
    return foundGames;
  }

  /// 递归收集候选目录（限制深度避免性能问题）
  ///
  /// - 跳过隐藏目录（`.` 开头）
  /// - 按 [excludePatterns] 做小写包含匹配过滤
  /// - 限制 [maxDepth] 避免过深递归
  /// - 不包含根目录本身（根目录保护由 [scanGames] 负责）
  static Future<void> collectCandidates(
    Directory dir,
    List<String> out, {
    required int depth,
    required int maxDepth,
    required List<String> excludePatterns,
  }) async {
    if (depth >= maxDepth) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final dirName = entity.path.split('/').last.split('\\').last;
        // 跳过隐藏目录
        if (dirName.startsWith('.') && dirName.length > 1) continue;
        // 排除规则（lowercase 包含匹配）
        final lower = dirName.toLowerCase();
        if (excludePatterns.any((p) => lower.contains(p.toLowerCase()))) {
          continue;
        }
        out.add(entity.path);
        await collectCandidates(
          Directory(entity.path),
          out,
          depth: depth + 1,
          maxDepth: maxDepth,
          excludePatterns: excludePatterns,
        );
      }
    } catch (e) {
      debugPrint('[SCAN] 收集候选目录异常: $e');
    }
  }

  /// 检测目录的启动程序（批量导入 / 智能导入共享的规范实现）
  ///
  /// 优先级：中文版 exe（chs/cn/zh/汉化/中文/简中）→ 最大的非安装类 exe
  /// 返回相对目录的路径（如 `Game.exe` 或 `bin/Game.exe`）
  ///
  /// ★ IMP-12 批A（2026-09-12 导入审查，"软件未响应"根因缓解）：
  /// ① [cache] 同一次扫描内复用结果 —— 阶段五 `_hasSameParentGame` 对每对父子
  ///    关系各调 2 次，300GB 收藏下是 O(n²) 次**整树同步遍历**，全部跑在 UI isolate；
  /// ② 递归遍历加条数/深度上限 —— 旧实现对单个 300GB 目录是无界 `listSync(recursive: true)`。
  /// 传入 [cache] 的调用方须保证同一次扫描内复用同一实例（扫描结束即弃）。
  static String? detectLaunchExe(
    String folderPath, {
    Map<String, String?>? cache,
  }) {
    if (cache != null && cache.containsKey(folderPath)) {
      return cache[folderPath];
    }
    final result = _detectLaunchExeUncached(folderPath);
    cache?[folderPath] = result;
    return result;
  }

  /// 单次启动程序扫描的条数预算与深度上限（★ IMP-12 批A）
  static const int _launchScanMaxEntries = 20000;
  static const int _launchScanMaxDepth = 8;

  /// 网络路径（UNC / 映射网络驱动器）单次扫描的墙钟预算（★ 2026-09-26 NAS 适配）
  ///
  /// 本方法是**同步**的、跑在 UI isolate 上；SMB 上每一个目录项枚举与
  /// `lengthSync()` 都是一次网络往返，条数/深度预算拦不住
  /// 「1000 个文件 × 每次数百毫秒」这类高延迟场景 → 「软件未响应」。
  /// 故对网络路径额外加墙钟截止：超时即以已收集的结果返回
  /// （主程序通常在浅层就已找到），并留下日志。
  /// **本地磁盘不加该预算**，行为与耗时逐字不变。
  static const Duration _launchScanNetworkBudget = Duration(seconds: 5);

  static String? _detectLaunchExeUncached(String folderPath) {
    try {
      // 不再先做 existsSync()：目录不存在时 listSync 会抛异常并被
      // _collectExeFiles 吞掉，结果同样是「未找到启动程序」，
      // 但省掉一次网络盘上的同步往返（★ 2026-09-26）。
      final dir = Directory(folderPath);
      final deadline = NetworkPath.isNetwork(folderPath)
          ? DateTime.now().add(_launchScanNetworkBudget)
          : null;
      final exeFiles = <MapEntry<File, int>>[];
      final budget = <int>[_launchScanMaxEntries];
      _collectExeFiles(dir, exeFiles, 0, budget, deadline);
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        debugPrint('[SCAN] ⏱️ 网络目录扫描超出 '
            '${_launchScanNetworkBudget.inSeconds}s 预算，'
            '按已收集的 ${exeFiles.length} 个候选返回: $folderPath');
      }
      return _pickLaunchExe(exeFiles, folderPath);
    } catch (e) {
      return null;
    }
  }

  /// 递归收集候选 exe（带条数预算与深度上限，★ IMP-12 批A；
  /// [deadline] 为网络路径的墙钟截止，本地路径传 null）
  static void _collectExeFiles(
    Directory dir,
    List<MapEntry<File, int>> out,
    int depth,
    List<int> remainingEntries, [
    DateTime? deadline,
  ]) {
    if (depth > _launchScanMaxDepth || remainingEntries[0] <= 0) return;
    if (deadline != null && DateTime.now().isAfter(deadline)) return;
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } catch (_) {
      return; // 无权限/离线等：跳过该子目录
    }
    for (final entity in entities) {
      if (remainingEntries[0] <= 0) return;
      if (deadline != null && DateTime.now().isAfter(deadline)) return;
      remainingEntries[0]--;
      if (entity is File) {
        // 🔴 排除关键字只对文件名匹配，禁止用完整路径——目录名含
        // "Install Patch" 等字样时全路径匹配会把所有 exe 误杀（2026-09-13 实锤）
        final name =
            entity.path.replaceAll('\\', '/').split('/').last.toLowerCase();
        if (name.endsWith('.exe') &&
            !name.contains('uninstall') &&
            !name.contains('setup') &&
            !name.contains('installer') &&
            !name.contains('patch')) {
          try {
            out.add(MapEntry(entity, entity.lengthSync()));
          } catch (_) {}
        }
      } else if (entity is Directory) {
        _collectExeFiles(entity, out, depth + 1, remainingEntries, deadline);
      }
    }
  }

  /// 从候选 exe 中选择启动程序：中文版优先 → 最大的非安装类 exe
  static String? _pickLaunchExe(
    List<MapEntry<File, int>> exeFiles,
    String folderPath,
  ) {
    if (exeFiles.isEmpty) return null;

    // 优先选择中文版（只看文件名——目录名含中文/日文汉字时
    // 全路径匹配会把任意先遍历到的 exe 当"汉化版"返回）
    for (final entry in exeFiles) {
      final name =
          entry.key.path.replaceAll('\\', '/').split('/').last.toLowerCase();
      if (name.contains('chs') ||
          name.contains('_cn') ||
          name.contains('_zh') ||
          name.contains('汉化') ||
          name.contains('中文') ||
          name.contains('简中')) {
        return entry.key.path
            .replaceFirst('$folderPath\\', '')
            .replaceFirst('$folderPath/', '');
      }
    }

    // 选择最大的文件（通常是主程序）
    exeFiles.sort((a, b) => b.value.compareTo(a.value));
    return exeFiles.first.key.path
        .replaceFirst('$folderPath\\', '')
        .replaceFirst('$folderPath/', '');
  }

  // ==================== 内部工具 ====================

  /// 路径深度（段数，规范化后按 \ 切分）—— 用于父子排序与"取更浅者"平手裁决
  /// 严格后代判定（★ P0-5）：入参为 [PathNormalizer.forCompare] 的输出。
  /// 零再规范化，仅前缀比较 —— 替代旧实现每对 2 次 `forCompare` 的写法。
  static bool _isUnderNorm(String parentNorm, String childNorm) =>
      parentNorm.isNotEmpty &&
      childNorm.length > parentNorm.length + 1 &&
      childNorm.startsWith('$parentNorm\\');

  /// 同名副本二选一：识别度更高者优先；平手取路径更浅者（更接近游戏本体、
  /// 嵌套副本多为二次解压残留）；再平手取路径字典序（保证确定性）。
  static bool _preferGame(_DetectedGame a, _DetectedGame b) {
    if (a.detection.confidence != b.detection.confidence) {
      return a.detection.confidence > b.detection.confidence;
    }
    if (a.segCount != b.segCount) return a.segCount < b.segCount;
    return a.normalizedPath.compareTo(b.normalizedPath) < 0;
  }

  /// 严格判定目录是否为独立游戏
  ///
  /// 返回 null 表示无可用主启动程序（连 Ren'Py 也至少有 .exe 解释器，
  /// 无 exe 基本可判非游戏）；否则返回完整检测结果（含依据供日志/UI）。
  /// 调用方据 detection.isGame 判定是否接受。
  ///
  /// ★ 主程序门槛 + 通用名拦截是智能导入此前缺失的关键防线：
  /// 仅含 config.ini 等弱特征文件（无 exe）的目录、名为 game/bin/gal
  /// 或含"补丁/存档/汉化"关键词的目录，都在此处被拦截。
  static GalDetectionResult? _detectIndependentGame(String folderPath) {
    final detection = GalGameDetector.detect(folderPath);
    // 无主 exe → 连 Ren'Py 也至少有 .exe 解释器，无 exe 基本可判非游戏
    if (detection.mainExeName == null) return null;
    if (!detection.isGame) return detection;
    // 通用目录名拦截
    final folderName =
        folderPath.split('/').last.split('\\').last.toLowerCase();
    if (_isGenericName(folderName)) {
      return GalDetectionResult(
        confidence: detection.confidence,
        isGame: false,
        negativeSignals: [...detection.negativeSignals, '通用目录名'],
      );
    }
    return detection;
  }

  /// 过于通用的目录名，不太可能是独立游戏
  ///
  /// 英文通用名：精确匹配（避免误伤 "gameData" 等合法名称）
  /// CJK 关键词：子串匹配（覆盖组合名如 "AI补丁"、"补丁&存档"、
  ///   "全CG存档"、"[白井木学园]...完整汉化补丁" 等）
  ///
  /// CJK 子串匹配安全：游戏文件夹名通常是游戏标题（如"命运石之门"），
  /// 不会包含"补丁/存档/备份/汉化"等附属词汇作为子串。
  static bool _isGenericName(String folderName) {
    final englishGenericNames = [
      'game',
      'games',
      'gal', // 归纳用文件夹名（如 D:\GAL），双保险拦截
      'test',
      'new',
      'project',
      'sample',
      'demo',
      'temp',
      'backup',
      'copy',
      'old',
      'work',
      'src',
      'source',
      'bin',
      'out',
      'build',
      'dist',
      'release',
      'debug',
    ];

    // 英文通用名：精确匹配
    if (englishGenericNames.contains(folderName)) return true;

    // CJK 附属文件夹关键词：子串匹配（硬拦截，不论评分高低）
    final cjkKeywords = ['补丁', '存档', '备份', '汉化'];
    for (final kw in cjkKeywords) {
      if (folderName.contains(kw)) return true;
    }

    return false;
  }

  /// 检查字符串是否含 CJK 字符（中日韩）
  /// 用于父目录救援时验证父目录名是日文/中文游戏名而非英文系统文件夹
  static bool _containsCjk(String text) {
    for (final codeUnit in text.runes) {
      if ((codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) || // CJK 统一表意
          (codeUnit >= 0x3040 && codeUnit <= 0x30FF) || // 平假名/片假名
          (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF)) {
        // 韩文音节
        return true;
      }
    }
    return false;
  }

  /// 检查新路径是否是某个已识别游戏的子目录，且共享相同的启动程序
  ///
  /// 只有当两个路径非常接近（真正的子模块）时才跳过：
  /// 通过路径深度差判断——深度差 ≤1 且 exe 同名，才认为是重复。
  ///
  /// ★ P0-5（2026-09-16 稳定性审计）：包含判定与深度差改用调用方预计算的
  /// 规范化路径/段数（旧实现对每对候选各调 `isSubdirectory`（2 次 forCompare）
  /// 与 `depthOf`（2 次 normalize+split），2000 条时约 400 万次重算）。
  static bool _hasSameParentGame(List<_DetectedGame> existingGames,
      _DetectedGame candidate, Map<String, String?> launchExeCache) {
    for (final game in existingGames) {
      if (_isUnderNorm(game.normalizedPath, candidate.normalizedPath)) {
        // 如果父目录和新目录有相同的exe文件，则视为同一个游戏
        // ★ IMP-12 批A: 复用本次扫描的检测结果缓存
        final parentExe = detectLaunchExe(game.path, cache: launchExeCache);
        final childExe = detectLaunchExe(candidate.path, cache: launchExeCache);

        if (parentExe != null && childExe != null) {
          // 提取exe完整相对路径进行比较（而不只是文件名）
          // 只有当exe在完全相同的位置时才认为是同一个游戏
          final parentExeName = parentExe.toLowerCase();
          final childExeName = childExe.toLowerCase();

          // 严格后代 → 深度差 ≥1（旧实现的 depthOf ≥0 恒成立）
          final depthDiff = candidate.segCount - game.segCount;

          if (depthDiff >= 1 &&
              depthDiff <= 1 &&
              parentExeName == childExeName) {
            debugPrint('[SCAN] 跳过重复游戏: ${candidate.path} '
                '(与 ${game.path} 共享相同启动程序, 深度差=$depthDiff)');
            return true;
          }
        }
      }
    }
    return false;
  }
}
