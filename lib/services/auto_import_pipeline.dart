import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/watch_folder.dart';
import '../pages/join/utils/gal_game_detector.dart';
import 'game_launcher_detector.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';
import 'metadata_fetcher.dart';
import 'screenshot_fetch_service.dart';
import 'cover_download_service.dart';
import '../utils/title_cleaner.dart';
import '../utils/path_normalizer.dart';
import '../core/path_helper.dart';
import 'import_dedup_index.dart';

/// 自动导入流水线
///
/// 处理 WatchFolderService 发现的候选目录：
/// 1. 快速过滤（排除不存在的目录）
/// 2. 精确识别（GalGameDetector.detect，置信度 + 依据）
/// 3. 去重检查（路径 + 标题双重匹配）
/// 4. 推断标题（升级版算法，支持中日文括号/版本号/汉化标记）
/// 5. 根据模式决定行为（自动入库 / 加入候选队列）
///
/// 入库采用两阶段设计：
/// - 阶段一（立即）：写入 game.json + 注册到 registry（基本字段）
/// - 阶段二（异步）：抓取元数据 + 下载封面 + 更新 registry + 触发 UI 刷新
class AutoImportPipeline {
  AutoImportPipeline._();

  /// 默认置信度阈值（可被 WatchFolderService 覆盖）
  static const double defaultThreshold = 0.30;

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

  /// 处理候选目录
  ///
  /// [dirPath] 候选目录路径
  /// [lockTitle] 是否锁定标题
  /// [autoMode] true=自动入库，false=加入候选队列
  /// [confidenceThreshold] 置信度阈值
  /// [onCandidate] 发现候选游戏时的回调（通知确认模式使用）
  /// [dedupIndex] 批次级排重索引（可选）。传入时启用多维排重（路径包含硬冲突 +
  ///   同名软警告），与批量导入一致；未传入时回退 [isAlreadyImported]（向后兼容）。
  ///   由 WatchFolderService 批次级构建一次传入，避免逐目录全量构建的性能开销。
  static Future<void> processCandidate({
    required String dirPath,
    required bool lockTitle,
    required bool autoMode,
    required ValueChanged<ImportCandidate> onCandidate,
    double confidenceThreshold = defaultThreshold,
    ImportDedupIndex? dedupIndex,
  }) async {
    try {
      // 1. 快速过滤
      if (!Directory(dirPath).existsSync()) return;

      // 2. 去重检查（前置，避免对已入库游戏调用 detect 浪费性能）
      //    优先用批次级 ImportDedupIndex（支持路径包含硬冲突 + 同名软警告），
      //    未传入时回退 isAlreadyImported（向后兼容）
      final title = _inferTitle(dirPath);
      String? duplicateWarning;
      if (dedupIndex != null) {
        final verdict = dedupIndex.check(dirPath, title: title);
        if (verdict.isHardConflict) {
          debugPrint('[AUTO-IMPORT] 已入库（${verdict.reason}），跳过: $dirPath');
          return;
        }
        if (verdict.hasWarning) {
          duplicateWarning = verdict.reason;
        }
      } else if (isAlreadyImported(dirPath)) {
        debugPrint('[AUTO-IMPORT] 已入库，跳过: $dirPath');
        return;
      }

      // 3. 精确识别（带依据）
      final detection = GalGameDetector.detect(dirPath);
      if (!detection.isGame || detection.confidence < confidenceThreshold) {
        debugPrint(
            '[AUTO-IMPORT] 置信度不足 (${detection.confidence.toStringAsFixed(2)} < $confidenceThreshold): $dirPath');
        debugPrint('[AUTO-IMPORT]   依据: ${detection.reasonSummary}');
        return;
      }

      // 4. 创建候选对象（带识别依据 + 排重软警告）
      final candidate = ImportCandidate(
        dirPath: dirPath,
        inferredTitle: title,
        confidence: detection.confidence,
        discoveredAt: DateTime.now(),
        engineType: detection.engineType,
        mainExeName: detection.mainExeName,
        reasonSummary: detection.reasonSummary,
        duplicateWarning: duplicateWarning,
      );

      if (autoMode) {
        // 自动入库模式
        await importCandidate(candidate: candidate, lockTitle: lockTitle);
      } else {
        // 通知确认模式
        debugPrint(
            '[AUTO-IMPORT] 📋 发现候选游戏: $title (置信度: ${(detection.confidence * 100).toInt()}% | 引擎: ${detection.engineType})');
        debugPrint('[AUTO-IMPORT]   依据: ${detection.reasonSummary}');
        onCandidate(candidate);
      }
    } catch (e) {
      debugPrint('[AUTO-IMPORT] 处理候选异常: $e');
    }
  }

  /// 导入候选游戏（入库）— 两阶段设计
  ///
  /// 阶段一（立即）：写入 game.json + 注册到 registry
  /// 阶段二（异步）：抓取元数据 + 下载封面 + 更新 registry + 触发 UI 刷新
  static Future<bool> importCandidate({
    required ImportCandidate candidate,
    required bool lockTitle,
  }) async {
    try {
      final dirPath = candidate.dirPath;
      final title = candidate.inferredTitle;

      debugPrint('[AUTO-IMPORT] 🚀 开始入库: $title ($dirPath)');

      // ==================== 阶段一：立即入库 ====================

      // 1. 检测启动程序
      final detection = await GameLauncherDetector.detect(dirPath);
      final launchPath = detection.success ? detection.launcherPath ?? '' : '';

      if (launchPath.isEmpty) {
        debugPrint('[AUTO-IMPORT] ⚠️ 未检测到启动程序: $title');
      }

      // 2. 创建元数据目录 + game.json
      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final metaDataDir = '${PathHelper.gamesDir}/$safeName';

      await GameDataFormat.writeGameDir(
        targetDir: metaDataDir,
        title: title,
        launchPath: launchPath,
        directoryPath: dirPath,
        source: 'smart_import',
      );

      // 3. 标题锁定
      if (lockTitle) {
        await GameDataFormat.updateGameJson(metaDataDir, {
          'title_locked': true,
        });
      }

      // 4. 注册到内存（带可用的识别信息）
      LocalGameRegistry.instance.registerExtractionComplete(
        gameTitle: title,
        directoryPath: dirPath,
        launchPath: launchPath,
      );

      debugPrint('[AUTO-IMPORT] ✅ 阶段一完成（已入库）: $title');

      // ==================== 阶段二：异步补全元数据 ====================
      // 不阻塞入库流程，完成后更新 registry 并触发 UI 刷新
      _fetchMetadataAndRefresh(
        metaDataDir: metaDataDir,
        title: title,
        lockTitle: lockTitle,
      );

      return true;
    } catch (e) {
      debugPrint('[AUTO-IMPORT] ❌ 入库失败: $e');
      return false;
    }
  }

  /// 异步抓取元数据 + 下载封面 + 更新 registry + 触发 UI 刷新
  ///
  /// 关键修复：原版 _fetchMetadataAsync 只写 game.json 不刷新内存，
  /// 导致库页面看不到元数据。本方法在写入后重新注册到 registry。
  static Future<void> _fetchMetadataAndRefresh({
    required String metaDataDir,
    required String title,
    required bool lockTitle,
  }) async {
    try {
      debugPrint('[AUTO-IMPORT] 🔍 异步抓取元数据: $title');
      final results = await MetadataFetcher.fetchGame(title);
      if (results.isEmpty) {
        debugPrint('[AUTO-IMPORT] 未找到元数据: $title');
        return;
      }

      final data = results.first;
      final updates = <String, dynamic>{};

      // 标题锁定时不覆盖 title
      if (!lockTitle && data['game_name'] != null) {
        final fetchedName = data['game_name'].toString();
        if (fetchedName.isNotEmpty) {
          updates['title'] = fetchedName;
        }
      }

      if (data['description'] != null) {
        updates['description'] = data['description'].toString();
      }
      if (data['tags'] != null) {
        updates['tags'] = data['tags'];
      }
      if (data['developer'] != null) {
        updates['developer'] = data['developer'].toString();
      }
      if (data['release_date'] != null) {
        updates['release_date'] = data['release_date'].toString();
      }
      if (data['cover_url'] != null &&
          data['cover_url'].toString().isNotEmpty) {
        updates['cover_url'] = data['cover_url'].toString();
      }
      if (data['screenshot_urls'] != null &&
          data['screenshot_urls'] is List &&
          (data['screenshot_urls'] as List).isNotEmpty) {
        updates['screenshot_urls'] = data['screenshot_urls'];
        // 标记截图状态为 pending，交由 ScreenshotFetchService 异步下载
        updates['screenshot_status'] = 'pending';
        updates['screenshot_retry_count'] = 0;
      }

      if (updates.isEmpty) {
        debugPrint('[AUTO-IMPORT] 元数据无可用更新: $title');
        return;
      }

      // 写入 game.json
      await GameDataFormat.updateGameJson(metaDataDir, updates);
      debugPrint('[AUTO-IMPORT] ✅ 元数据已写入 game.json: $title');

      // ==================== 关键：先刷新 registry 内存中的游戏对象 ====================
      // 性能优化：先刷新内存（让标签/简介等元数据立即可见），
      // 再异步下载封面，避免封面下载阻塞 UI 刷新
      await _refreshRegistryGame(metaDataDir, title);

      // 下载封面到元数据目录（异步 fire-and-forget，不阻塞流程）
      // 性能优化：封面下载改为异步，避免 30s 超时期间库页面元数据刷新延迟
      final coverUrl = updates['cover_url']?.toString();
      if (coverUrl != null && coverUrl.startsWith('http')) {
        _downloadCoverToMetaDir(metaDataDir, coverUrl).then((_) {
          debugPrint('[AUTO-IMPORT] ✅ 封面已下载: $title');
          // 封面下载完成后再次刷新 registry（更新封面路径）
          _refreshRegistryGame(metaDataDir, title);
        }).catchError((e) {
          debugPrint('[AUTO-IMPORT] ⚠️ 封面下载失败: $title | $e');
        });
      }

      // ===== 截图通过 ScreenshotFetchService 统一异步处理 =====
      final screenshotUrls = updates['screenshot_urls'];
      if (screenshotUrls is List && screenshotUrls.isNotEmpty) {
        final urls = screenshotUrls.cast<String>();
        // 使用更新后的标题（如果标题被覆盖）作为 gameTitle
        final effectiveTitle = (updates['title'] as String?)?.isNotEmpty == true
            ? updates['title'] as String
            : title;
        ScreenshotFetchService.instance
            .enqueue(effectiveTitle, metaDataDir, urls);
        debugPrint(
            '[AUTO-IMPORT] 📥 截图已入队 ScreenshotFetchService: $title | ${urls.length}张');
      }
    } catch (e) {
      debugPrint('[AUTO-IMPORT] 元数据抓取失败: $title | $e');
    }
  }

  /// 下载封面到元数据目录
  ///
  /// Phase 3.1: 委托给统一的 CoverDownloadService，并修复原实现遗漏的 game.json 写入
  /// 原实现仅下载文件到磁盘，不写 cover_file 字段，导致 registry 只能靠
  /// findCoverFile() 目录扫描兜底寻找封面（多个 cover.* 共存时可能匹配错误文件）
  static Future<void> _downloadCoverToMetaDir(
      String metaDataDir, String coverUrl) async {
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: metaDataDir,
      coverUrl: coverUrl,
    );
    if (savedName != null) {
      // 写入 cover_file 字段，让 registry 精确定位封面
      await GameDataFormat.updateGameJson(
          metaDataDir, {'cover_file': savedName});
    }
  }

  /// 刷新 registry 内存中的单个游戏对象（从 game.json 重新读取）
  ///
  /// 关键修复：原版元数据抓取后只更新 game.json 文件，
  /// 内存中的 LibraryGame 对象仍是空数据，导致库页面显示无封面无标签。
  /// 本方法重新读取 game.json 并更新 registry 中的对应字段。
  static Future<void> _refreshRegistryGame(
      String metaDataDir, String title) async {
    try {
      final gameData = await GameDataFormat.readGameJson(metaDataDir);
      if (gameData == null) {
        debugPrint('[AUTO-IMPORT] 刷新失败：无法读取 game.json: $metaDataDir');
        return;
      }

      // 通过 registerExtractionComplete 更新内存对象
      // 该方法会处理"已存在则原地更新"的情况，并触发 _notifyStructural()
      final coverFile = GameDataFormat.findCoverFile(metaDataDir);

      LocalGameRegistry.instance.registerExtractionComplete(
        gameTitle: gameData.title.isNotEmpty ? gameData.title : title,
        directoryPath: gameData.directoryPath,
        coverUrl: coverFile?.path,
        description: gameData.description,
        tags: gameData.tags,
        launchPath: gameData.launchPath,
        developer: gameData.developer,
      );

      debugPrint('[AUTO-IMPORT] ✅ registry 已刷新: ${gameData.title}');
    } catch (e) {
      debugPrint('[AUTO-IMPORT] 刷新 registry 失败: $title | $e');
    }
  }

  /// 从目录路径推断游戏标题（升级版算法）
  ///
  /// 处理优先级：
  /// 1. 移除前缀 [汉化组名] 或 【汉化组名】
  /// 2. 移除后缀 [中文] [chs] [汉化] （中文/英文/日文括号）
  /// 3. 移除版本号后缀 v1.2.3 / Ver1.23 / 1.23
  /// 4. 移除平台后缀 [PC] [Windows]
  /// 5. 移除末尾下划线/点/空格
  static String _inferTitle(String dirPath) {
    // Phase 2.4: 复用公共 TitleCleaner，避免重复实现
    return TitleCleaner.cleanFromDirPath(dirPath);
  }
}
