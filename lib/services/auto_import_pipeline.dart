import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/watch_folder.dart';
import '../pages/join/utils/game_folder_scanner.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';
import 'metadata_fetcher.dart';
import 'screenshot_fetch_service.dart';
import 'cover_download_service.dart';
import '../utils/title_cleaner.dart';
import '../utils/path_normalizer.dart';
import '../core/path_helper.dart';
import 'import_dedup_index.dart';

/// 智能导入流水线
///
/// 处理 WatchFolderService 发现的候选目录，流程对齐批量导入（三段式）：
///
/// 1. 识别段（已迁移至 GameFolderScanner.scanGames 五阶段共享扫描管线，
///    由 WatchFolderService 直接调用，与批量导入行为完全一致）
/// 2. [enrichCandidate] 元数据富化段：检测启动程序 + MIX 多源抓取
///    + 源 ID 排重 + 副标题/标签/简介/会社填充 + 封面预下载
///    → 候选进入 ready / failed 状态（与批量导入 _processSingleGameById 一致）
/// 3. [importCandidate] 入库段：一次性写入完整字段（简介/标签/封面/会社/截图/
///    副标题/双标题/metadataSource），与批量导入 importSingleGame 字段完全对齐
///
/// 与旧版（两阶段设计）的关键差异：
/// - 旧版先入库裸数据、后异步补元数据，失败则永久裸数据
/// - 新版先富化、后入库，入库即完整数据；富化失败的候选转入确认队列
///   等用户处理（重试 / 忽略 / 强制入库）
class AutoImportPipeline {
  AutoImportPipeline._();

  /// 检查目录是否已入库（路径精确匹配 + 标题匹配）
  static bool isAlreadyImported(String dirPath) {
    final normalized = PathNormalizer.forCompare(dirPath);
    for (final game in LocalGameRegistry.instance.allGames) {
      // 路径精确匹配
      if (PathNormalizer.forCompare(game.directoryPath) == normalized) {
        return true;
      }
      // 标题匹配：推断标题与已入库标题相同
      final inferredTitle = _inferTitle(dirPath);
      final safeName =
          inferredTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      if (game.title == inferredTitle ||
          game.title == safeName ||
          p.basename(game.metaDataDir) == safeName) {
        return true;
      }
    }
    return false;
  }

  /// 获取所有已入库游戏的目录路径（供 WatchFolderService 统计 gameCount）
  static List<String> get allImportedDirectoryPaths {
    return LocalGameRegistry.instance.allGames
        .map((g) => g.directoryPath)
        .toList();
  }

  // ==================== 第一段：识别 ====================
  // （识别段已迁移至 GameFolderScanner.scanGames 五阶段共享扫描管线，
  //   由 WatchFolderService 直接调用；本类保留富化与入库两段。）

  // ==================== 第二段：元数据富化 ====================

  /// 元数据富化管线（对齐批量导入 _processSingleGameById）
  ///
  /// 步骤：
  /// 1. 检测启动程序（相对路径，中文版优先 → 最大文件兜底）
  /// 2. MIX 多源抓取元数据（fetchGameMixed：VNDB/KunGal/Hikarinagi/Steam/月幕GAL
  ///    按字段优先级整合——与手动导入/批量导入完全一致的抓取源）
  /// 3. 源 ID 排重（阶段 B：VNDB ID/Bangumi ID 等与库内冲突 → 硬重复标记）
  /// 4. 填充字段：双标题（title 保持、metadataTitle 记录）、副标题（日文原版
  ///    且 CJK）、标签、简介、会社
  /// 5. 封面预下载到临时目录（fire-and-forget，完成后回调 [onCoverDownloaded]）
  ///
  /// 结果写入候选对象：
  /// - taskStatus = ready（含源 ID 硬重复标记的情况）
  /// - taskStatus = failed + errorMessage（抓取异常 / 未找到匹配）
  ///
  /// 返回 true 表示就绪（含硬重复），false 表示富化失败。
  static Future<bool> enrichCandidate({
    required ImportCandidate candidate,
    VoidCallback? onCoverDownloaded,
    ImportDedupIndex? dedupIndex,
  }) async {
    final title = candidate.title;
    debugPrint('[AUTO-IMPORT] 🔍 开始元数据富化: $title');

    try {
      // 1. 检测启动程序（批量导入同款算法：中文版优先 → 最大 exe 兜底）
      candidate.launchExe ??= _detectLaunchExe(candidate.dirPath);
      if (candidate.launchExe == null) {
        debugPrint('[AUTO-IMPORT] ⚠️ 未检测到启动程序: $title');
      }

      // 2. MIX 多源抓取（与手动/批量导入一致的抓取源）
      final bestMatch = await MetadataFetcher.fetchGameMixed(title);

      if (bestMatch == null) {
        candidate.taskStatus = CandidateTaskStatus.failed;
        candidate.errorMessage = '未找到匹配的元数据，可重试或手动入库';
        debugPrint('[AUTO-IMPORT] ⚠️ 未找到元数据: $title');
        return false;
      }

      // 3. 阶段 B 排重：元数据源 ID 硬冲突检查
      //    MIX 结果附带 source_platforms（各底层平台与其 ID），
      //    任一底层平台 ID 与库内冲突即视为重复
      final platform = bestMatch['platform']?.toString() ?? '';
      final platformId = bestMatch['platform_id']?.toString() ?? '';
      final sourcePlatforms =
          bestMatch['source_platforms'] as Map<String, dynamic>?;

      final index = dedupIndex ?? ImportDedupIndex.fromRegistry();
      final checkPairs = <List<String>>[
        if (platform.isNotEmpty && platformId.isNotEmpty) [platform, platformId],
        if (sourcePlatforms != null)
          ...sourcePlatforms.entries
              .where((e) => e.value.toString().isNotEmpty)
              .map((e) => [e.key, e.value.toString()]),
      ];
      for (final pair in checkPairs) {
        final verdict = index.checkWithSource(pair[0], pair[1]);
        if (verdict.isHardConflict) {
          candidate.metadata = bestMatch;
          candidate.metadataTitle = bestMatch['game_name']?.toString();
          candidate.isHardDuplicate = true;
          candidate.duplicateWarning = verdict.reason;
          candidate.taskStatus = CandidateTaskStatus.ready;
          debugPrint(
              '[AUTO-IMPORT] ✗ 元数据源 ID 冲突，标记硬重复: $title | ${verdict.reason}');
          return true;
        }
      }

      // 4. 填充字段（业务规则：导入标题 > 抓取标题，主标题保持不变，
      //    元数据标题记录到 metadataTitle 供 UI 切换）
      final metadataGameName = bestMatch['game_name']?.toString() ?? '';
      if (metadataGameName.isNotEmpty) {
        candidate.metadataTitle = metadataGameName;
      }

      // 副标题：日文原版标题（含 CJK 字符，排除纯英文）且与主标题不同时填充
      final originalTitleStr =
          bestMatch['original_title']?.toString().trim() ?? '';
      if (originalTitleStr.isNotEmpty &&
          _containsCjk(originalTitleStr) &&
          originalTitleStr != candidate.title.trim() &&
          candidate.subtitle.isEmpty) {
        candidate.subtitle = originalTitleStr;
      }

      if (candidate.tags.isEmpty) {
        candidate.tags = (bestMatch['tags'] as List?)
                ?.map((t) => t.toString())
                .toList() ??
            const [];
      }
      if (candidate.description.isEmpty) {
        candidate.description = bestMatch['summary']?.toString() ?? '';
      }
      if (candidate.developer.isEmpty) {
        candidate.developer = bestMatch['developer']?.toString() ?? '';
      }
      candidate.metadata = bestMatch;
      candidate.taskStatus = CandidateTaskStatus.ready;
      candidate.errorMessage = null;

      debugPrint('[AUTO-IMPORT] ✓ 元数据富化完成: $title');

      // 5. 封面预下载到临时目录（fire-and-forget，不阻塞队列）
      final coverUrl = bestMatch['cover_url']?.toString();
      if (coverUrl != null && coverUrl.startsWith('http')) {
        _downloadTempCover(candidate, coverUrl).then((ok) {
          if (ok) onCoverDownloaded?.call();
        }).catchError((e) {
          debugPrint('[AUTO-IMPORT] ⚠️ 封面下载失败: $title | $e');
        });
      }

      return true;
    } catch (e) {
      candidate.taskStatus = CandidateTaskStatus.failed;
      candidate.errorMessage = '元数据抓取失败: $e';
      debugPrint('[AUTO-IMPORT] ✗ 元数据富化失败: $title | $e');
      return false;
    }
  }

  // ==================== 第三段：完整入库 ====================

  /// 入库候选游戏（完整字段，对齐批量导入 importSingleGame）
  ///
  /// 一次性写入全部数据：标题/双标题/副标题/简介/标签/会社/封面/截图/
  /// metadataSource/Id。截图通过 ScreenshotFetchService 后台异步下载。
  ///
  /// [lockTitle] 为 true 时写入 title_locked 标记（库页面据此锁定标题编辑）。
  static Future<bool> importCandidate({
    required ImportCandidate candidate,
    required bool lockTitle,
  }) async {
    try {
      final title = candidate.effectiveTitle;
      final dirPath = candidate.dirPath;
      debugPrint('[AUTO-IMPORT] 🚀 开始入库: $title ($dirPath)');

      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final metaDataDir = '${PathHelper.gamesDir}/$safeName';

      // 封面回退：本地临时文件不存在时，通过网络 URL 下载（writeGameDir 内处理）
      final coverUrl = candidate.coverUrl;
      final coverFileExists = candidate.coverFilePath != null &&
          File(candidate.coverFilePath!).existsSync();
      final screenshotUrls = candidate.screenshotUrls;

      // 1. 写入 game.json（完整字段）
      await GameDataFormat.writeGameDir(
        targetDir: metaDataDir,
        title: title,
        description: candidate.description,
        tags: candidate.tags,
        coverFilePath: coverFileExists ? candidate.coverFilePath : null,
        coverUrl: coverUrl,
        launchPath: candidate.launchExe ?? '',
        directoryPath: dirPath,
        source: 'smart_import',
        developer: candidate.developer,
        screenshotUrls: screenshotUrls.isNotEmpty ? screenshotUrls : null,
        originalTitle: candidate.originalTitle,
        subtitle: candidate.subtitle.isNotEmpty ? candidate.subtitle : null,
        metadataTitle: candidate.metadataTitle,
        metadataSource:
            candidate.metadataSource.isNotEmpty ? candidate.metadataSource : null,
        metadataSourceId:
            candidate.metadataSourceId.isNotEmpty ? candidate.metadataSourceId : null,
        // ★ 2026-10-04：探索页对齐元数据（MIX 抓取结果透传入库）
        releaseDate: candidate.metadata?['release_date']?.toString(),
        rating: (candidate.metadata?['rating'] as num?)?.toDouble(),
        ratingCount: (candidate.metadata?['vote_count'] as num?)?.toInt(),
        estimatedMinutes:
            (candidate.metadata?['length_minutes'] as num?)?.toInt(),
        // ★ 2026-10-04：横幅封面 URL（MIX 整合结果透传；无横幅时为空串/缺失
        //   → writeGameDir 内按"无横幅"处理，不阻塞入库）
        bannerUrl: candidate.metadata?['banner_url']?.toString(),
      );

      // 2. 标题锁定
      if (lockTitle) {
        await GameDataFormat.updateGameJson(metaDataDir, {
          'title_locked': true,
        });
      }

      // 3. 截图后台抓取（不阻塞入库）
      if (screenshotUrls.isNotEmpty) {
        ScreenshotFetchService.instance.enqueue(safeName, metaDataDir, screenshotUrls);
        debugPrint(
            '[AUTO-IMPORT] 📥 截图已入队 ScreenshotFetchService: $title | ${screenshotUrls.length}张');
      }

      // 4. 注册到内存（完整字段，库页面立即可见）
      final coverFile = GameDataFormat.findCoverFile(metaDataDir);
      LocalGameRegistry.instance.registerExtractionComplete(
        gameTitle: safeName,
        directoryPath: dirPath,
        coverUrl: coverFile?.path,
        description: candidate.description,
        developer: candidate.developer,
        tags: candidate.tags,
        launchPath: candidate.launchExe ?? '',
        subtitle: candidate.subtitle,
        metadataSource: candidate.metadataSource,
        metadataSourceId: candidate.metadataSourceId,
      );

      // 5. 清理临时封面（writeGameDir 已将其复制到元数据目录）
      cleanupTempCover(candidate);

      debugPrint('[AUTO-IMPORT] ✅ 入库完成（完整数据）: $title');
      return true;
    } catch (e) {
      debugPrint('[AUTO-IMPORT] ❌ 入库失败: $e');
      return false;
    }
  }

  /// 清理候选的临时封面文件（入库/忽略后调用）
  ///
  /// ★ IMP-03 数据安全护栏（2026-09-12 导入审查）：
  /// `candidate.coverFilePath` 可能是**用户在左侧表单里挑选的磁盘原图绝对路径**
  /// （`join_controller.pickCover` 不做复制，经 `_saveSingleToCandidate` 回写候选），
  /// 无条件 delete 会删掉用户桌面/图片目录里的原文件且不可恢复。
  /// 因此只在应用自有目录（含系统临时目录）内删除，其余一律跳过。
  /// 与批量导入的同类护栏一致（batch_import_controller `_cleanupSingleGameCache`）。
  static void cleanupTempCover(ImportCandidate candidate) {
    final path = candidate.coverFilePath;
    if (path == null || path.isEmpty) return;
    if (!PathHelper.isInsideAppStorage(path)) {
      debugPrint('[AUTO-IMPORT] ⏭️ 跳过非应用目录封面(可能是用户原图): $path');
      candidate.coverFilePath = null;
      return;
    }
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    candidate.coverFilePath = null;
  }

  // ==================== 内部工具 ====================

  /// 检测启动程序（委托共享扫描器，与批量导入同款算法）
  ///
  /// 优先级：中文版 exe（chs/cn/zh/汉化/中文/简中）→ 最大的非安装类 exe
  /// 返回相对目录的路径（如 `Game.exe` 或 `bin/Game.exe`）
  static String? _detectLaunchExe(String folderPath) {
    return GameFolderScanner.detectLaunchExe(folderPath);
  }

  /// 下载封面到临时目录（供候选卡片/左侧表单预览，入库时复制到元数据目录）
  static Future<bool> _downloadTempCover(
      ImportCandidate candidate, String coverUrl) async {
    // 文件命名规范：以候选 dirPath 的哈希为前缀 + nonce 后缀。
    // 修复 2026-08：原先用 DateTime.now().millisecondsSinceEpoch 生成 fileName，
    // 智能导入 3 并发 worker 同一毫秒会生成相同文件名 → 互相覆盖封面。
    // 现在 CoverDownloadService 自动追加进程内单调递增的 nonce 保证唯一性。
    final ext = CoverDownloadService.detectExtension(coverUrl);
    final tempDir = Directory(PathHelper.portableTmpDir);
    // 用 dirPath 哈希作前缀（短、确定性），方便排查是哪个候选的临时文件
    final pathHash = candidate.dirPath.hashCode.toRadixString(16);
    final fileName = 'smart_cover_$pathHash.$ext';
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: tempDir.path,
      coverUrl: coverUrl,
      fileName: fileName,
    );
    if (savedName != null) {
      candidate.coverFilePath = '${tempDir.path}/$savedName';
      return true;
    }
    return false;
  }

  /// 判断文本是否含 CJK 字符（与批量导入一致，用于副标题过滤）
  static final RegExp _cjkRegExp =
      RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');

  static bool _containsCjk(String text) => _cjkRegExp.hasMatch(text);

  /// 从目录路径推断游戏标题（复用公共 TitleCleaner）
  static String _inferTitle(String dirPath) {
    return TitleCleaner.cleanFromDirPath(dirPath);
  }
}
