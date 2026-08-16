import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';

/// 截图下载状态
///
/// - pending: 待下载（已入队，等待处理）
/// - downloading: 下载中
/// - completed: 完成（已下载到本地或无截图URL）
/// - failed: 失败（超过最大重试次数）
enum ScreenshotFetchStatus {
  pending,
  downloading,
  completed,
  failed,
}

extension ScreenshotFetchStatusExt on ScreenshotFetchStatus {
  String get jsonValue {
    switch (this) {
      case ScreenshotFetchStatus.pending:
        return 'pending';
      case ScreenshotFetchStatus.downloading:
        return 'downloading';
      case ScreenshotFetchStatus.completed:
        return 'completed';
      case ScreenshotFetchStatus.failed:
        return 'failed';
    }
  }

  static ScreenshotFetchStatus fromJson(String value) {
    switch (value) {
      case 'pending':
        return ScreenshotFetchStatus.pending;
      case 'downloading':
        return ScreenshotFetchStatus.downloading;
      case 'failed':
        return ScreenshotFetchStatus.failed;
      case 'completed':
      default:
        return ScreenshotFetchStatus.completed;
    }
  }
}

/// 单个截图下载任务
class _ScreenshotTask {
  final String gameTitle;
  final String metaDataDir;
  final List<String> screenshotUrls;

  _ScreenshotTask({
    required this.gameTitle,
    required this.metaDataDir,
    required this.screenshotUrls,
  });
}

/// 任务进度信息（供UI展示）
class ScreenshotFetchProgress {
  final String gameTitle;
  final ScreenshotFetchStatus status;
  final int completedCount; // 已下载张数
  final int totalCount; // 总张数
  final int retryCount;

  ScreenshotFetchProgress({
    required this.gameTitle,
    required this.status,
    this.completedCount = 0,
    this.totalCount = 0,
    this.retryCount = 0,
  });
}

/// 截图数据后台抓取服务
///
/// 职责：
/// 1. 检测新入库游戏（screenshot_status=pending）
/// 2. 异步下载截图到本地 screenshots/ 目录
/// 3. 更新 game.json（screenshot_files + screenshot_status）
/// 4. 刷新 LocalGameRegistry 内存
/// 5. 重试机制（最多3次，指数退避）
/// 6. 状态通知（供UI展示进度）
///
/// 设计要点：
/// - 单例 + ChangeNotifier，UI 可监听状态变化
/// - 串行处理队列，避免并发风暴对元数据源造成请求压力
/// - 启动时扫描恢复，确保应用崩溃后任务不丢失
/// - 与入库流程完全解耦，截图失败不影响游戏使用
class ScreenshotFetchService extends ChangeNotifier {
  static final ScreenshotFetchService _instance =
      ScreenshotFetchService._internal();
  static ScreenshotFetchService get instance => _instance;

  ScreenshotFetchService._internal() {
    // 注册游戏删除回调，自动清理已删除游戏的截图下载进度
    LocalGameRegistry.instance.onGameRemoved = (gameTitle) {
      clearProgress(gameTitle);
    };
  }

  // ===== 配置 =====
  /// 最大重试次数
  static const int maxRetryCount = 3;

  /// 每个游戏最多下载的截图张数
  static const int maxScreenshotsPerGame = 6;

  /// 任务间最小间隔（毫秒），避免请求过快
  static const int _taskIntervalMs = 500;

  /// 重试基础退避（毫秒），实际等待 = base * 2^retryCount
  static const int _retryBaseDelayMs = 2000;

  // ===== 状态 =====
  /// 任务队列
  final List<_ScreenshotTask> _queue = [];

  /// 是否正在处理队列
  bool _isProcessing = false;

  /// 进度映射：gameTitle → ScreenshotFetchProgress
  final Map<String, ScreenshotFetchProgress> _progressMap = {};

  /// 已入队的游戏标题集合（避免重复入队）
  final Set<String> _enqueuedTitles = {};

  // ===== Getters =====
  /// 获取所有游戏的截图进度（供UI监听）
  Map<String, ScreenshotFetchProgress> get progressMap =>
      Map.unmodifiable(_progressMap);

  /// 队列中待处理的任务数
  int get pendingCount => _queue.length;

  /// 是否正在处理
  bool get isProcessing => _isProcessing;

  /// 获取指定游戏的截图进度
  ScreenshotFetchProgress? getProgress(String gameTitle) =>
      _progressMap[gameTitle];

  /// 注册新游戏需要抓取截图
  ///
  /// 由导入流程在入库成功后调用：
  /// - [gameTitle] 游戏标题（用于查找 registry 中的游戏对象）
  /// - [metaDataDir] 元数据目录（game.json 所在目录）
  /// - [screenshotUrls] 截图URL列表
  void enqueue(
      String gameTitle, String metaDataDir, List<String> screenshotUrls) {
    if (screenshotUrls.isEmpty) {
      debugPrint(
          '[SCREENSHOT-FETCH] 跳过 $gameTitle: 无截图URL');
      return;
    }

    // 已入队则跳过
    if (_enqueuedTitles.contains(gameTitle)) {
      debugPrint(
          '[SCREENSHOT-FETCH] 已在队列中，跳过: $gameTitle');
      return;
    }

    // 已完成则跳过
    final existing = _progressMap[gameTitle];
    if (existing != null &&
        (existing.status == ScreenshotFetchStatus.completed ||
            existing.status == ScreenshotFetchStatus.downloading)) {
      debugPrint(
          '[SCREENSHOT-FETCH] 已完成或正在下载，跳过: $gameTitle');
      return;
    }

    _queue.add(_ScreenshotTask(
      gameTitle: gameTitle,
      metaDataDir: metaDataDir,
      screenshotUrls: screenshotUrls,
    ));
    _enqueuedTitles.add(gameTitle);

    _progressMap[gameTitle] = ScreenshotFetchProgress(
      gameTitle: gameTitle,
      status: ScreenshotFetchStatus.pending,
      completedCount: 0,
      totalCount: screenshotUrls.length.clamp(0, maxScreenshotsPerGame),
    );

    debugPrint(
        '[SCREENSHOT-FETCH] 📥 入队: $gameTitle | 截图数: ${screenshotUrls.length} | 队列长度: ${_queue.length}');

    notifyListeners();

    // 触发队列处理
    _processQueue();
  }

  /// 启动/继续处理队列
  ///
  /// 串行处理，每个任务完成后间隔 [_taskIntervalMs] 再处理下一个
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    if (_queue.isEmpty) return;

    _isProcessing = true;

    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeAt(0);

        // 更新状态为下载中
        _progressMap[task.gameTitle] = ScreenshotFetchProgress(
          gameTitle: task.gameTitle,
          status: ScreenshotFetchStatus.downloading,
          completedCount: 0,
          totalCount: task.screenshotUrls.length
              .clamp(0, maxScreenshotsPerGame),
        );
        notifyListeners();

        try {
          await _processSingleTask(task);
        } catch (e) {
          debugPrint(
              '[SCREENSHOT-FETCH] 任务异常: ${task.gameTitle} | $e');
          await _handleFailure(task, e.toString());
        }

        // 任务间间隔
        if (_queue.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: _taskIntervalMs));
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// 处理单个游戏的截图下载
  Future<void> _processSingleTask(_ScreenshotTask task) async {
    debugPrint(
        '[SCREENSHOT-FETCH] 🚀 开始下载: ${task.gameTitle} | 截图数: ${task.screenshotUrls.length}');

    // 标记 downloading 状态到 game.json
    await _updateStatus(
        task.metaDataDir, ScreenshotFetchStatus.downloading);

    try {
      // 调用 GameDataFormat 的截图下载方法（复用缓存优先逻辑）
      final downloadedFiles = await GameDataFormat.downloadAndSaveScreenshots(
          task.metaDataDir, task.screenshotUrls);

      // 更新 game.json：写入 screenshot_files + 标记 completed
      await GameDataFormat.updateGameJson(task.metaDataDir, {
        'screenshot_files': downloadedFiles,
        'screenshot_status':
            ScreenshotFetchStatus.completed.jsonValue,
        'screenshot_retry_count': 0,
      });

      // 刷新 registry 内存
      _refreshRegistry(task.gameTitle, task.metaDataDir, downloadedFiles);

      // 更新进度
      _progressMap[task.gameTitle] = ScreenshotFetchProgress(
        gameTitle: task.gameTitle,
        status: ScreenshotFetchStatus.completed,
        completedCount: downloadedFiles.length,
        totalCount: task.screenshotUrls.length
            .clamp(0, maxScreenshotsPerGame),
      );
      _enqueuedTitles.remove(task.gameTitle);

      debugPrint(
          '[SCREENSHOT-FETCH] ✅ 完成: ${task.gameTitle} | 成功: ${downloadedFiles.length}/${task.screenshotUrls.length}');

      notifyListeners();
    } catch (e) {
      await _handleFailure(task, e.toString());
    }
  }

  /// 处理下载失败：递增重试次数，达到上限则标记 failed
  Future<void> _handleFailure(_ScreenshotTask task, String errorMsg) async {
    // 读取当前重试次数
    final gameData = await GameDataFormat.readGameJson(task.metaDataDir);
    final currentRetry = gameData?.screenshotRetryCount ?? 0;
    final newRetry = currentRetry + 1;

    debugPrint(
        '[SCREENSHOT-FETCH] ⚠️ 失败: ${task.gameTitle} | 重试 $newRetry/$maxRetryCount | $errorMsg');

    if (newRetry >= maxRetryCount) {
      // 达到最大重试次数，标记 failed
      await GameDataFormat.updateGameJson(task.metaDataDir, {
        'screenshot_status': ScreenshotFetchStatus.failed.jsonValue,
        'screenshot_retry_count': newRetry,
      });

      _progressMap[task.gameTitle] = ScreenshotFetchProgress(
        gameTitle: task.gameTitle,
        status: ScreenshotFetchStatus.failed,
        completedCount: 0,
        totalCount: task.screenshotUrls.length
            .clamp(0, maxScreenshotsPerGame),
        retryCount: newRetry,
      );
      _enqueuedTitles.remove(task.gameTitle);

      debugPrint(
          '[SCREENSHOT-FETCH] ❌ 最终失败: ${task.gameTitle} | 已达最大重试次数');
    } else {
      // 递增重试次数，标记回 pending 等待下次处理
      await GameDataFormat.updateGameJson(task.metaDataDir, {
        'screenshot_status': ScreenshotFetchStatus.pending.jsonValue,
        'screenshot_retry_count': newRetry,
      });

      // 指数退避后重新入队
      final delay = _retryBaseDelayMs * (1 << newRetry);
      debugPrint(
          '[SCREENSHOT-FETCH] ⏳ ${task.gameTitle} 将在 ${delay}ms 后重试');
      _enqueuedTitles.remove(task.gameTitle);

      Future.delayed(Duration(milliseconds: delay), () {
        // 退避后重新入队
        if (!_enqueuedTitles.contains(task.gameTitle)) {
          _queue.add(task);
          _enqueuedTitles.add(task.gameTitle);
          _progressMap[task.gameTitle] = ScreenshotFetchProgress(
            gameTitle: task.gameTitle,
            status: ScreenshotFetchStatus.pending,
            completedCount: 0,
            totalCount: task.screenshotUrls.length
                .clamp(0, maxScreenshotsPerGame),
            retryCount: newRetry,
          );
          notifyListeners();
          _processQueue();
        }
      });
    }

    notifyListeners();
  }

  /// 更新 game.json 的截图状态
  Future<void> _updateStatus(
      String metaDataDir, ScreenshotFetchStatus status) async {
    try {
      await GameDataFormat.updateGameJson(metaDataDir, {
        'screenshot_status': status.jsonValue,
      });
    } catch (e) {
      debugPrint('[SCREENSHOT-FETCH] 更新状态失败: $e');
    }
  }

  /// 刷新 LocalGameRegistry 内存中的游戏对象
  void _refreshRegistry(
      String gameTitle, String metaDataDir, List<String> screenshotFiles) {
    try {
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      if (game != null) {
        game.screenshotFiles = screenshotFiles
            .map((f) => '$metaDataDir/$f')
            .toList();
        game.screenshotStatus = ScreenshotFetchStatus.completed.jsonValue;
        LocalGameRegistry.instance.notifyListenersForScreenshot();
        debugPrint(
            '[SCREENSHOT-FETCH] 🔄 已刷新 registry: $gameTitle | 截图: ${screenshotFiles.length}张');
      }
    } catch (e) {
      debugPrint('[SCREENSHOT-FETCH] 刷新 registry 失败: $e');
    }
  }

  /// 手动触发截图更新
  ///
  /// 用户在详情页点击"重新获取截图"时调用
  Future<void> triggerManualFetch(String gameTitle) async {
    try {
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      if (game == null) {
        debugPrint('[SCREENSHOT-FETCH] 手动触发失败: 未找到游戏 $gameTitle');
        return;
      }

      // 读取 game.json 获取截图URL
      final gameData = await GameDataFormat.readGameJson(game.metaDataDir);
      if (gameData == null || gameData.screenshotUrls.isEmpty) {
        debugPrint('[SCREENSHOT-FETCH] 手动触发失败: 无截图URL $gameTitle');
        return;
      }

      // 重置重试次数并重新入队
      await GameDataFormat.updateGameJson(game.metaDataDir, {
        'screenshot_status': ScreenshotFetchStatus.pending.jsonValue,
        'screenshot_retry_count': 0,
      });

      _enqueuedTitles.remove(gameTitle);
      enqueue(gameTitle, game.metaDataDir, gameData.screenshotUrls);
    } catch (e) {
      debugPrint('[SCREENSHOT-FETCH] 手动触发异常: $e');
    }
  }

  /// 扫描所有 pending/downloading 状态的游戏（应用启动时调用）
  ///
  /// 确保应用崩溃或异常退出后，未完成的截图任务能够恢复
  Future<void> scanPendingGames() async {
    try {
      debugPrint(
          '[SCREENSHOT-FETCH] 🔍 开始扫描未完成的截图任务...');

      final gamesDir = Directory(LocalGameRegistry.gamesBaseDir);
      if (!await gamesDir.exists()) {
        debugPrint('[SCREENSHOT-FETCH] 游戏目录不存在，跳过扫描');
        return;
      }

      int recoveredCount = 0;

      await for (final entity in gamesDir.list(followLinks: false)) {
        if (entity is! Directory) continue;

        final gameData = await GameDataFormat.readGameJson(entity.path);
        if (gameData == null) continue;

        // 只处理 pending 和 downloading 状态的（downloading 说明上次崩溃）
        if (gameData.screenshotStatus ==
                ScreenshotFetchStatus.pending.jsonValue ||
            gameData.screenshotStatus ==
                ScreenshotFetchStatus.downloading.jsonValue) {
          if (gameData.screenshotUrls.isEmpty) {
            // 无URL但状态为pending，标记为completed
            await GameDataFormat.updateGameJson(entity.path,
                {'screenshot_status': ScreenshotFetchStatus.completed.jsonValue});
            continue;
          }

          // 重新入队
          final title = gameData.title.isNotEmpty
              ? gameData.title
              : entity.path.split(Platform.pathSeparator).last;
          enqueue(title, entity.path, gameData.screenshotUrls);
          recoveredCount++;
        }
      }

      debugPrint(
          '[SCREENSHOT-FETCH] ✅ 扫描完成，恢复 $recoveredCount 个未完成任务');
    } catch (e) {
      debugPrint('[SCREENSHOT-FETCH] 扫描异常: $e');
    }
  }

  /// 获取指定游戏的截图状态（供UI查询）
  ScreenshotFetchStatus? getStatus(String gameTitle) {
    final progress = _progressMap[gameTitle];
    if (progress != null) return progress.status;

    // 进度Map中没有，尝试从 registry 读取
    final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    if (game != null && game.screenshotStatus.isNotEmpty) {
      return ScreenshotFetchStatusExt.fromJson(game.screenshotStatus);
    }
    return null;
  }

  /// 清理指定游戏的进度记录（游戏被删除时调用）
  void clearProgress(String gameTitle) {
    _progressMap.remove(gameTitle);
    _enqueuedTitles.remove(gameTitle);
    // 从队列中移除
    _queue.removeWhere((task) => task.gameTitle == gameTitle);
    notifyListeners();
  }
}
