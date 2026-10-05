import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/local_game_registry.dart';
import '../../core/path_helper.dart';
import '../../services/game_data_format.dart';
import '../../services/metadata_fetcher.dart';
import '../../services/screenshot_fetch_service.dart';
import '../../services/cover_download_service.dart';
import '../../utils/path_normalizer.dart';
import '../../utils/import_completeness.dart';
import '../../models/watch_folder.dart';
import '../../services/scan_logger.dart';
import '../../services/import_dedup_index.dart';
import './utils/game_folder_scanner.dart';

enum GameTaskStatus {
  pending, // 等待处理
  processing, // 正在处理（识别exe/抓取元数据）
  completed, // 已完成
  failed, // 失败
  cancelled, // 已取消
}

class BatchGameItem {
  final String id;
  final String folderPath;
  String gameName;
  String? launchExe;
  List<String> tags;
  String description;
  String? coverFilePath;
  Map<String, dynamic>? metadata;
  bool isSelected;
  GameTaskStatus taskStatus;
  String? errorMessage;
  String developer;
  List<String> screenshotUrls;
  // 副标题：与主标题共同构成标题系统（通常为日文原版标题），用户可自定义
  String subtitle;

  // 多维排重：软警告（同名可能重复）+ 硬冲突（元数据源 ID 重复）
  // duplicateWarning 非空时 UI 显示橙色徽章，仍允许导入
  // isHardDuplicate 为 true 时 submitBatchImport 自动跳过
  String? duplicateWarning;
  bool isHardDuplicate;

  /// 数据完整性判定（2026-10-03）：封面/简介任一缺失 = 数据不全。
  /// 返回缺失字段名列表（如 ['封面']），空列表 = 齐全。
  /// 实时计算：submitBatchImport 入库确认时评估，用户补全后再次确认即通过。
  List<String> get missingCoreFields => missingCoreDataFields(
        coverFilePath: coverFilePath,
        coverUrl: metadata?['cover_url']?.toString(),
        description: description,
      );

  // 双标题管理（业务规则：导入标题 > 抓取标题）：
  // - originalTitle：导入时从文件夹名清洗得到（不可变，导入后固定）
  // - metadataTitle：元数据抓取到的标准游戏名（首次抓取后赋值，可被新选择覆盖）
  // - usingMetadataTitle：当前 gameName 是否使用元数据标题（默认 false）
  //   抓取后主标题保持导入标题不变，metadataTitle 仅作为切换选项；
  //   用户可通过 UI 主动切换：gameName = usingMetadataTitle ? metadataTitle : originalTitle
  //   手动编辑 gameName 时视为自定义标题（不切换标志）
  final String originalTitle;
  String? metadataTitle;
  bool usingMetadataTitle;

  // 原始数据快照，用于撤回/恢复编辑
  String? originalGameName;
  List<String>? originalTags;
  String? originalDescription;
  String? originalCoverFilePath;
  String? originalDeveloper;
  List<String>? originalScreenshotUrls;

  BatchGameItem({
    required this.id,
    required this.folderPath,
    required this.gameName,
    required this.originalTitle,
    this.metadataTitle,
    this.usingMetadataTitle = false,
    this.launchExe,
    this.tags = const [],
    this.description = '',
    this.coverFilePath,
    this.metadata,
    this.isSelected = false,
    this.taskStatus = GameTaskStatus.pending,
    this.errorMessage,
    this.developer = '',
    this.screenshotUrls = const [],
    this.subtitle = '',
    this.duplicateWarning,
    this.isHardDuplicate = false,
    this.originalGameName,
    this.originalTags,
    this.originalDescription,
    this.originalCoverFilePath,
    this.originalDeveloper,
    this.originalScreenshotUrls,
  });

  /// 是否可在原标题与元数据标题间切换
  /// （需有元数据标题，且与原标题不同）
  bool get canToggleTitle =>
      metadataTitle != null &&
      metadataTitle!.isNotEmpty &&
      metadataTitle != originalTitle;

  /// 保存当前数据作为原始快照（在首次编辑前调用）
  void saveOriginalSnapshot() {
    originalGameName ??= gameName;
    originalTags ??= List.from(tags);
    originalDescription ??= description;
    originalCoverFilePath ??= coverFilePath;
    originalDeveloper ??= developer;
    originalScreenshotUrls ??= List.from(screenshotUrls);
  }

  /// 恢复到原始快照数据
  void restoreFromSnapshot() {
    if (originalGameName != null) gameName = originalGameName!;
    if (originalTags != null) tags = List.from(originalTags!);
    if (originalDescription != null) description = originalDescription!;
    if (originalCoverFilePath != null) coverFilePath = originalCoverFilePath!;
    if (originalDeveloper != null) developer = originalDeveloper!;
    if (originalScreenshotUrls != null)
      screenshotUrls = List.from(originalScreenshotUrls!);
  }

  /// 是否有原始快照可恢复
  bool get hasOriginalSnapshot => originalGameName != null;

  BatchGameItem copyWith({
    String? id,
    String? folderPath,
    String? gameName,
    String? launchExe,
    List<String>? tags,
    String? description,
    String? coverFilePath,
    Map<String, dynamic>? metadata,
    bool? isSelected,
    GameTaskStatus? taskStatus,
    String? errorMessage,
    String? developer,
    List<String>? screenshotUrls,
    String? subtitle,
    String? duplicateWarning,
    bool? isHardDuplicate,
    String? originalTitle,
    String? metadataTitle,
    bool? usingMetadataTitle,
    String? originalGameName,
    List<String>? originalTags,
    String? originalDescription,
    String? originalCoverFilePath,
    String? originalDeveloper,
    List<String>? originalScreenshotUrls,
  }) {
    return BatchGameItem(
      id: id ?? this.id,
      folderPath: folderPath ?? this.folderPath,
      gameName: gameName ?? this.gameName,
      launchExe: launchExe ?? this.launchExe,
      tags: tags ?? this.tags,
      description: description ?? this.description,
      coverFilePath: coverFilePath ?? this.coverFilePath,
      metadata: metadata ?? this.metadata,
      isSelected: isSelected ?? this.isSelected,
      taskStatus: taskStatus ?? this.taskStatus,
      errorMessage: errorMessage ?? this.errorMessage,
      developer: developer ?? this.developer,
      screenshotUrls: screenshotUrls ?? this.screenshotUrls,
      subtitle: subtitle ?? this.subtitle,
      duplicateWarning: duplicateWarning ?? this.duplicateWarning,
      isHardDuplicate: isHardDuplicate ?? this.isHardDuplicate,
      originalTitle: originalTitle ?? this.originalTitle,
      metadataTitle: metadataTitle ?? this.metadataTitle,
      usingMetadataTitle: usingMetadataTitle ?? this.usingMetadataTitle,
      originalGameName: originalGameName ?? this.originalGameName,
      originalTags: originalTags ?? this.originalTags,
      originalDescription: originalDescription ?? this.originalDescription,
      originalCoverFilePath:
          originalCoverFilePath ?? this.originalCoverFilePath,
      originalDeveloper: originalDeveloper ?? this.originalDeveloper,
      originalScreenshotUrls:
          originalScreenshotUrls ?? this.originalScreenshotUrls,
    );
  }
}

class BatchImportController extends ChangeNotifier {
  List<BatchGameItem> _games = [];
  BatchGameItem? _selectedGame;
  String? _lastSelectedGameId; // 记录上次选中的游戏ID，用于判断是否为切换操作

  // 任务队列管理
  bool _isProcessingQueue = false;
  int _currentProcessingIndex = -1;
  final Set<String> _cancelledTasks = {}; // 已取消的任务ID集合
  bool _hasNewPendingGames = false; // 新增：标记是否有新的待处理游戏
  bool _isDisposed = false; // 标记是否已释放/清空，用于中断异步循环
  // 预览确认状态：扫描后暂停，等待用户点击"开始处理"才触发 autoProcessNewGames
  // 避免扫描后立即抓取元数据，让用户有机会预览/筛选/编辑待导入列表
  bool _isAwaitingConfirmation = false;

  // 入库进度管理
  bool _isImporting = false;
  int _importProgressCurrent = 0;
  int _importProgressTotal = 0;
  String _importingGameName = '';

  // 多维排重索引缓存：confirmAndProcess 时预构建，避免每游戏重建
  // autoProcessNewGames 结束后清空
  ImportDedupIndex? _currentDedupIndex;

  // 最近一次扫描的摘要（供 UI 展示）
  ScanSummary? _lastScanSummary;
  ScanSummary? get lastScanSummary => _lastScanSummary;

  List<BatchGameItem> get games => _games;
  BatchGameItem? get selectedGame => _selectedGame;
  String? get lastSelectedGameId => _lastSelectedGameId;
  bool get hasGames => _games.isNotEmpty;
  bool get isProcessingQueue => _isProcessingQueue;
  bool get isAwaitingConfirmation => _isAwaitingConfirmation;
  bool get isImporting => _isImporting;
  int get importProgressCurrent => _importProgressCurrent;
  int get importProgressTotal => _importProgressTotal;
  String get importingGameName => _importingGameName;

  /// 待确认处理的游戏数（pending 状态，等待用户点击"开始处理"）
  int get pendingConfirmationCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.pending).length;

  // 统计信息
  int get pendingCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.pending).length;
  int get processingCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.processing).length;
  int get completedCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.completed).length;
  int get failedCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.failed).length;
  int get cancelledCount =>
      _games.where((g) => g.taskStatus == GameTaskStatus.cancelled).length;
  int get totalCount => _games.length;

  /// 数据不全数（2026-10-03）：已完成但封面/简介任一缺失，
  /// 入库确认时会被闸口拦截保留在列表。UI 据此显示「重新处理」条。
  int get incompleteCount => _games
      .where((g) =>
          g.taskStatus == GameTaskStatus.completed &&
          g.missingCoreFields.isNotEmpty)
      .length;

  /// 已完成数（含成功+失败+取消），用于进度和 ETA 计算
  int get finishedCount => completedCount + failedCount + cancelledCount;

  double get overallProgress {
    if (_games.isEmpty) return 0;
    // 入库阶段使用入库进度
    if (_isImporting && _importProgressTotal > 0) {
      return _importProgressCurrent / _importProgressTotal;
    }
    final finishedCount = completedCount + failedCount + cancelledCount;
    return finishedCount / _games.length;
  }

  String get batchStatusMessage {
    if (_isProcessingQueue) {
      final processing = _games
          .where((g) => g.taskStatus == GameTaskStatus.processing)
          .toList();
      if (processing.isNotEmpty) {
        if (processing.length == 1) {
          return '正在处理: ${processing.first.gameName}';
        }
        return '正在处理 ${processing.length} 个游戏 · ${processing.first.gameName} 等';
      }
    } else if (_isImporting && _importProgressTotal > 0) {
      return '正在入库: $_importProgressCurrent/$_importProgressTotal ${_importingGameName.isNotEmpty ? "· ${_importingGameName}" : ""}';
    } else if (pendingCount > 0) {
      return '等待处理 $pendingCount 个游戏...';
    } else if (completedCount > 0) {
      return '已完成 $completedCount 个游戏';
    }
    return '准备就绪';
  }

  VoidCallback? onGameAdded;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function(String)? onInfo;
  VoidCallback? onConfirmEdit; // 新增：确认编辑回调

  BatchImportController({
    this.onGameAdded,
    this.onError,
    this.onSuccess,
    this.onInfo,
    this.onConfirmEdit,
  });

  /// 切换选中游戏前的自动保存回调（由 JoinPage 设置）
  VoidCallback? onAutoSave;

  void selectGame(BatchGameItem? game) {
    // 切换前自动保存当前编辑到上一个选中的游戏
    if (_selectedGame != null && game != null && _selectedGame!.id != game.id) {
      onAutoSave?.call();
    }

    // 取消之前选中的游戏
    if (_selectedGame != null) {
      final index = _games.indexWhere((g) => g.id == _selectedGame!.id);
      if (index != -1) {
        _games[index] = _games[index].copyWith(isSelected: false);
      }
    }

    _selectedGame = game;

    if (game != null) {
      final index = _games.indexWhere((g) => g.id == game!.id);
      if (index != -1) {
        // 在首次选中时保存原始数据快照（用于撤回）
        _games[index].saveOriginalSnapshot();
        _games[index] = _games[index].copyWith(isSelected: true);
      }

      // 标记这是切换操作（需要同步到左侧表单）
      _lastSelectedGameId = game.id;
    }

    notifyListeners();
  }

  void confirmCurrentSelection() {
    if (_selectedGame == null) return;

    // 先保存表单数据到当前选中的游戏
    onConfirmEdit?.call();

    // 取消选中状态
    final index = _games.indexWhere((g) => g.id == _selectedGame!.id);
    if (index != -1) {
      _games[index] = _games[index].copyWith(isSelected: false);
    }
    _selectedGame = null;

    // 清除切换标志——确认操作后不需要重新同步覆盖表单
    _lastSelectedGameId = null;

    notifyListeners();
  }

  /// 恢复当前选中游戏到原始快照数据
  void restoreSelectedGame() {
    if (_selectedGame == null) return;

    final index = _games.indexWhere((g) => g.id == _selectedGame!.id);
    if (index != -1 && _games[index].hasOriginalSnapshot) {
      _games[index].restoreFromSnapshot();
      _selectedGame = _games[index];
      // 标记为切换操作，让左侧表单重新同步恢复后的数据
      _lastSelectedGameId = _selectedGame!.id;
      notifyListeners();
    }
  }

  Future<void> pickFolders() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择游戏文件夹',
      );

      if (result != null) {
        await addFolders([result]);
      }
    } catch (e) {
      onError?.call('选择文件夹失败：$e');
    }
  }

  Future<void> addFolders(List<String> folderPaths) async {
    debugPrint('[BATCH] ========== 开始新增导入 ==========');
    debugPrint('[BATCH] 接收到 ${folderPaths.length} 个文件夹路径');
    debugPrint(
        '[BATCH] 当前队列状态: _isProcessingQueue=$_isProcessingQueue, 已有 ${_games.length} 个游戏');

    // 清空上一次扫描摘要（UI 会通过 notifyListeners 收到空值并隐藏摘要条）
    _lastScanSummary = null;
    notifyListeners();

    // 构建多维排重索引（路径包含 + 标题同名 + 元数据源 ID）
    // 参考 LunaBox import_index.go 的四维索引，一次构建多次查询
    // 替代旧实现的单维度路径 Set，支持路径包含冲突和同名软警告
    final dedupIndex = ImportDedupIndex.fromRegistry();
    debugPrint(
        '[BATCH] 已构建排重索引: ${LocalGameRegistry.instance.allGames.length} 个已入库游戏');

    final newGames = <BatchGameItem>[];
    final skippedImportedPaths = <String>[];

    for (final path in folderPaths) {
      debugPrint('[BATCH] 正在扫描文件夹: $path');
      // 递归扫描所有子目录中的游戏，传入排重索引进行多维排重
      final gamesInFolder = await scanFolderForGames(
        path,
        dedupIndex: dedupIndex,
        skippedImportedPaths: skippedImportedPaths,
      );
      debugPrint(
          '[BATCH] 扫描结果: 发现 ${gamesInFolder.length} 个新游戏, 跳过 ${skippedImportedPaths.length} 个已导入游戏');
      newGames.addAll(gamesInFolder);
    }

    debugPrint(
        '[BATCH] 总共发现 ${newGames.length} 个新游戏, 跳过 ${skippedImportedPaths.length} 个已导入游戏');

    // 去重：根据folderPath去重（本次会话内不重复）
    // 用 ImportDedupIndex.sessionContains 做路径包含去重，
    // 修复尾部斜杠/大小写差异及父子目录包含导致的会话内排重失效
    int addedCount = 0;
    int skippedCount = 0;
    final existingPaths = _games.map((g) => g.folderPath).toList();
    for (final newGame in newGames) {
      if (!ImportDedupIndex.sessionContains(
              existingPaths, newGame.folderPath) &&
          !_games.any((g) =>
              PathNormalizer.forCompare(g.folderPath) ==
              PathNormalizer.forCompare(newGame.folderPath))) {
        _games.add(newGame);
        existingPaths.add(newGame.folderPath);
        addedCount++;
        debugPrint('[BATCH] ✓ 添加游戏: ${newGame.gameName}');
      } else {
        skippedCount++;
        debugPrint('[BATCH] ✗ 跳过重复: ${newGame.gameName} (路径已存在)');
      }
    }

    debugPrint(
        '[BATCH] 新增结果: +$addedCount 个, -$skippedCount 个会话内重复, 总计 ${_games.length} 个游戏');

    if (addedCount > 0) {
      // 标记有新的待处理游戏
      _hasNewPendingGames = true;
      debugPrint('[BATCH] ✓ 已设置 _hasNewPendingGames=true');

      // 预览确认步骤：扫描后不立即触发 autoProcessNewGames，
      // 而是进入 _isAwaitingConfirmation 状态，让用户预览/筛选列表，
      // 点击"开始处理"按钮后才调用 confirmAndProcess() 触发处理。
      _isAwaitingConfirmation = true;
      debugPrint('[BATCH] 进入预览确认状态，等待用户点击"开始处理"');

      notifyListeners();

      // 如果有跳过的已导入游戏，提示用户
      if (skippedImportedPaths.isNotEmpty) {
        onInfo?.call('已跳过 ${skippedImportedPaths.length} 个已导入的游戏');
      }
    } else {
      debugPrint('[BATCH] ⚠️ 没有新游戏需要添加');
      if (skippedImportedPaths.isNotEmpty) {
        onError?.call('扫描到的游戏均已导入，无需重复添加');
      } else if (skippedCount > 0) {
        onError?.call('这些文件夹已经导入过了');
      }
    }
  }

  Future<List<BatchGameItem>> scanFolderForGames(
    String rootPath, {
    required ImportDedupIndex dedupIndex,
    List<String>? skippedImportedPaths,
  }) async {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return <BatchGameItem>[];

    // ===== 阶段一：收集所有候选目录 =====
    // 对齐 watch_folder_service._collectCandidateDirs 的两阶段架构：
    // 先按 WatchFolder.defaultExcludePatterns 过滤，再做精确识别。
    // 旧实现用 _isNonGameSubfolder 硬编码列表，含 common/launcher/install 等
    // 误伤项，会跳过用户实际场景如 G:\GAL\common\游戏A。
    final candidates = <String>[rootPath];
    await GameFolderScanner.collectCandidates(
      dir,
      candidates,
      depth: 0,
      maxDepth: 4,
      excludePatterns: WatchFolder.defaultExcludePatterns,
    );
    debugPrint('[BATCH] 阶段一：收集到 ${candidates.length} 个候选目录');

    // 初始化 ScanLogger 与 ScanSummary（扫描期间累积决策依据）
    final summary = ScanSummary();
    ScanLogger.instance.startScan(rootPath, candidates.length);

    // ===== 阶段二~五：委托共享扫描管线 =====
    // 五阶段识别算法（严格识别 / 包装救援 / 归纳剔除 / 父子去重 /
    // 共享启动程序去重）已提取至 GameFolderScanner，与智能导入共用，
    // 保证两种导入模式的识别行为完全一致。此处仅负责日志与结果组装。
    final scannedGames = await GameFolderScanner.scanGames(
      rootPath: rootPath,
      candidates: candidates,
      excludePatterns: WatchFolder.defaultExcludePatterns,
      maxDepth: 4,
      dedupIndex: dedupIndex,
      onDecision: (dirPath, decision) {
        if (decision.accepted) {
          ScanLogger.instance.logCandidate(
            dirPath,
            accepted: true,
            summary: summary,
            detection: decision.detection,
          );
          return;
        }
        // 路径冲突 = 已入库游戏，计入"跳过已导入"提示
        if (decision.reason == ScanSkipReason.pathConflict) {
          skippedImportedPaths?.add(dirPath);
        }
        ScanLogger.instance.logCandidate(
          dirPath,
          accepted: false,
          summary: summary,
          reason: decision.reason,
          detection: decision.detection,
        );
      },
    );

    // 组装 BatchGameItem（双标题：originalTitle = 清洗后的文件夹名）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final foundGames = <BatchGameItem>[
      for (var i = 0; i < scannedGames.length; i++)
        BatchGameItem(
          id: '${timestamp}_$i',
          folderPath: scannedGames[i].path,
          gameName: scannedGames[i].title,
          // 双标题：原标题=清洗后的文件夹名（导入时固定，不可变）
          // metadataTitle 默认 null，usingMetadataTitle 默认 false（用原标题）
          // 元数据抓取后主标题保持导入标题，metadataTitle 仅作为切换选项
          originalTitle: scannedGames[i].title,
          // 软警告：同名可能重复（UI 显示橙色徽章，仍允许导入）
          duplicateWarning: scannedGames[i].duplicateWarning,
        ),
    ];

    // 写入日志文件 + 更新 lastScanSummary 供 UI 展示
    await ScanLogger.instance.endScan(summary);
    _lastScanSummary = summary;
    debugPrint('[BATCH] 识别完成：最终识别 ${foundGames.length} 个游戏');
    return foundGames;
  }

  /// 检查字符串是否含 CJK 字符（中日韩）
  /// 用于父目录救援时验证父目录名是日文/中文游戏名而非英文系统文件夹
  bool _containsCjk(String text) {
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

  /// ★ 2026-10-05 需求：批量导入仅负责游戏文件夹直接导入，不支持压缩包。
  /// 拖入压缩包文件时明确忽略并提示（此前会误把压缩包所在父目录当游戏导入）。
  static const List<String> _rejectedArchiveExts = [
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.lz4',
    '.iso', '.cab', '.arj', '.zst', '.lzma', '.001', '.exe',
  ];

  static bool _isRejectedFile(String path) {
    final lower = path.toLowerCase();
    return _rejectedArchiveExts.any((e) => lower.endsWith(e));
  }

  Future<void> handleDraggedFiles(List<String> paths) async {
    final folders = <String>[];
    var rejectedCount = 0;

    for (final path in paths) {
      if (Directory(path).existsSync()) {
        folders.add(path);
      } else if (File(path).existsSync()) {
        // 压缩包/伪装包等文件一律拒收：批量导入不走解压流程
        // （.exe 同样拒收——拖入 exe 属单文件导入的解压语义，批量只收文件夹）
        if (_isRejectedFile(path)) {
          rejectedCount++;
          debugPrint('[BATCH] ⊘ 拒收压缩包/安装包文件: $path');
          continue;
        }
        final parentDir = File(path).parent.path;
        if (!folders.contains(parentDir)) {
          folders.add(parentDir);
        }
      }
    }

    if (rejectedCount > 0) {
      onError?.call('批量导入不支持压缩包（已忽略 $rejectedCount 个文件），'
          '请先解压，或在单文件导入中使用解压功能');
    }

    if (folders.isNotEmpty) {
      await addFolders(folders);
    }
  }

  void removeGame(String gameId) {
    debugPrint('[BATCH] ========== 用户请求删除游戏 ==========');
    debugPrint('[BATCH] 目标游戏ID: $gameId');

    // 查找游戏在列表中的位置
    final index = _games.indexWhere((g) => g.id == gameId);

    if (index == -1) {
      debugPrint('[BATCH] ⚠️ 游戏不存在于列表中，忽略删除请求');
      return;
    }

    final gameToRemove = _games[index];
    debugPrint(
        '[BATCH] 找到游戏: ${gameToRemove.gameName} (状态: ${gameToRemove.taskStatus})');

    // 步骤1：标记为已取消（防止正在处理的游戏继续执行）
    _cancelledTasks.add(gameId);
    debugPrint('[BATCH] ✓ 已添加到取消集合');

    // 步骤2：如果正在处理的就是这个游戏，记录日志
    if (_isProcessingQueue && _currentProcessingIndex == index) {
      debugPrint('[BATCH] ⚠️ 该游戏正在处理中！将在当前步骤完成后跳过');
    } else if (_isProcessingQueue && _currentProcessingIndex > index) {
      // 如果已经处理过这个位置，需要调整索引（因为后面要删除元素）
      debugPrint('[BATCH] ℹ️ 该游戏已被处理过或索引将变化');
    }

    // 步骤3：清理该游戏的临时缓存文件
    _cleanupSingleGameCache(gameToRemove);

    // 步骤4：从列表中物理删除该游戏
    final removedGame = _games.removeAt(index);
    debugPrint('[BATCH] ✓ 已从列表中物理删除: ${removedGame.gameName}');
    debugPrint('[BATCH] 剩余游戏数量: ${_games.length}');

    // 步骤5：调整当前处理索引（如果在处理队列中）
    if (_isProcessingQueue) {
      if (_currentProcessingIndex == index) {
        // 正在处理的被删除了，保持索引不变（指向下一个）
        debugPrint('[BATCH] ℹ️ 当前处理索引保持在 $index （自动指向下一个游戏）');
      } else if (_currentProcessingIndex > index) {
        // 被删除的在前面，需要减1以保持正确指向
        _currentProcessingIndex--;
        debugPrint('[BATCH] ℹ️ 处理索引调整为: $_currentProcessingIndex');
      }
    }

    // 步骤6：如果是选中的游戏，清除选中状态
    if (_selectedGame?.id == gameId) {
      _selectedGame = null;
      debugPrint('[BATCH] ✓ 已清除选中状态');
    }

    // 步骤7：通知UI更新
    notifyListeners();
    debugPrint('[BATCH] ========== 删除完成 ==========');
  }

  // 新增：清理单个游戏的缓存文件
  void _cleanupSingleGameCache(BatchGameItem game) {
    try {
      // 清理封面图片缓存
      if (game.coverFilePath != null && game.coverFilePath!.isNotEmpty) {
        // 修复：coverFilePath 可能是用户在表单里选的磁盘原图绝对路径
        // （join_controller.pickCover 未复制，且可与批量列表互传）。
        // 只清理位于应用自有目录内的临时封面，用户目录内的原图一律不删。
        if (!PathHelper.isInsideAppStorage(game.coverFilePath!)) {
          debugPrint(
              '[BATCH] ⏭️ 跳过非应用目录封面（可能是用户原图）: ${game.coverFilePath}');
        } else {
          final coverFile = File(game.coverFilePath!);
          if (coverFile.existsSync()) {
            coverFile.deleteSync();
            debugPrint('[BATCH] 🗑️ 已删除封面缓存: ${game.coverFilePath}');
          }
        }
      }
    } catch (e) {
      debugPrint('[BATCH] ⚠️ 清理游戏 [${game.gameName}] 缓存时出错: $e');
      // 不抛出异常，避免影响主流程
    }
  }

  void updateSelectedGame({
    String? gameName,
    List<String>? tags,
    String? description,
    String? coverFilePath,
    String? developer,
    Map<String, dynamic>? metadata,
    List<String>? screenshotUrls,
    String? subtitle,
    String? metadataTitle,
    bool? usingMetadataTitle,
  }) {
    if (_selectedGame == null) return;

    final index = _games.indexWhere((g) => g.id == _selectedGame!.id);
    if (index == -1) return;

    _games[index] = _games[index].copyWith(
      gameName: gameName,
      tags: tags,
      description: description,
      coverFilePath: coverFilePath,
      developer: developer,
      metadata: metadata,
      screenshotUrls: screenshotUrls,
      // 副标题：仅在非 null 时更新（null 表示保持原值）
      subtitle: subtitle,
      // 双标题：仅在非 null 时更新（null 表示保持原值）
      // 注意 copyWith 中 metadataTitle 用 ?? 保留，usingMetadataTitle 同理
      metadataTitle: metadataTitle,
      usingMetadataTitle: usingMetadataTitle,
    );

    _selectedGame = _games[index];
    notifyListeners();
  }

  void updateGamePath(String gameId, String newPath) {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index == -1) return;

    _games[index] = _games[index].copyWith(folderPath: newPath);
    if (_selectedGame?.id == gameId) {
      _selectedGame = _games[index];
    }
    notifyListeners();
  }

  /// 切换指定游戏的标题偏好（原标题 ↔ 元数据标题）
  ///
  /// 双标题管理：在 originalTitle 与 metadataTitle 间切换当前显示的 gameName。
  /// 仅当 [BatchGameItem.canToggleTitle] 为 true 时有效（有 metadataTitle 且不同于原标题）。
  void toggleTitlePreference(String gameId) {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index == -1) return;
    final game = _games[index];
    if (!game.canToggleTitle) return;

    final newUsingMeta = !game.usingMetadataTitle;
    _games[index] = _games[index].copyWith(
      usingMetadataTitle: newUsingMeta,
      gameName: newUsingMeta ? game.metadataTitle! : game.originalTitle,
    );
    if (_selectedGame?.id == gameId) {
      _selectedGame = _games[index];
    }
    notifyListeners();
  }

  /// 重试失败的游戏（点击卡片上的重试按钮触发）
  ///
  /// 将指定游戏从 [GameTaskStatus.failed] 重置为 [GameTaskStatus.pending]，
  /// 清除错误信息，然后触发 [autoProcessNewGames] 重新处理。
  /// 保留用户已编辑的 gameName/tags/description 等（不重置为初始值）。
  Future<void> retryGame(String gameId) async {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index == -1) return;
    final game = _games[index];
    if (game.taskStatus != GameTaskStatus.failed) return;

    // ★ IMP-17（2026-09-12 导入审查）：真正清空元数据以便重新抓取。
    // 旧注释声称"清除可能存在的错误元数据"，实际传的是 `metadata: game.metadata`
    // （原样保留），而 fetchSingleGameMetadata 见到非空元数据会直接 return
    // → 点"重试"后数据纹丝不动，与用户预期不符。
    // 注意：copyWith 用 `??` 语义无法置空，故这里直接改字段。
    game.taskStatus = GameTaskStatus.pending;
    game.errorMessage = null;
    game.metadata = null;
    game.metadataTitle = null;
    game.isHardDuplicate = false;
    game.duplicateWarning = null;
    _hasNewPendingGames = true;
    notifyListeners();

    debugPrint('[BATCH] 🔄 重试游戏: ${game.gameName}');

    // 若队列未运行，触发处理；若已在运行，靠 _hasNewPendingGames 标志自动续处理
    if (!_isProcessingQueue) {
      await autoProcessNewGames();
    }
  }

  /// 重新处理所有数据不全的游戏（点击「重新处理」条触发，2026-10-03）
  ///
  /// 把已完成但封面/简介缺失的游戏批量重置为 pending 并清空旧元数据，
  /// 重新走一轮自动抓取（对齐 [retryGame] 的清空语义，但作用于一批）。
  /// 保留用户已编辑的 gameName/tags/description 等字段；抓取后若数据齐全，
  /// 再次点「批量入库」即通过闸口入库。
  Future<void> reprocessIncompleteGames() async {
    final incomplete = _games
        .where((g) =>
            g.taskStatus == GameTaskStatus.completed &&
            g.missingCoreFields.isNotEmpty)
        .toList();
    if (incomplete.isEmpty) return;

    for (final game in incomplete) {
      // copyWith 用 `??` 语义无法置空，直接改字段（同 retryGame）
      game.taskStatus = GameTaskStatus.pending;
      game.errorMessage = null;
      game.metadata = null;
      game.metadataTitle = null;
      game.isHardDuplicate = false;
      game.duplicateWarning = null;
    }
    _hasNewPendingGames = true;
    notifyListeners();

    debugPrint('[BATCH] 🔄 重新处理 ${incomplete.length} 款数据不全的游戏');

    if (!_isProcessingQueue) {
      // 与 confirmAndProcess 一致：重建排重索引后再开跑
      _currentDedupIndex = ImportDedupIndex.fromRegistry();
      await autoProcessNewGames();
    }
  }

  /// 用户确认预览后开始处理（点击"开始处理"按钮触发）
  ///
  /// 退出预览确认状态，触发 [autoProcessNewGames] 开始识别 exe + 抓取元数据。
  Future<void> confirmAndProcess() async {
    _isAwaitingConfirmation = false;
    // 预构建排重索引，供 fetchSingleGameMetadata 做元数据源 ID 排重
    _currentDedupIndex = ImportDedupIndex.fromRegistry();
    notifyListeners();
    await autoProcessNewGames();
  }

  Future<void> autoProcessNewGames() async {
    if (_games.isEmpty) {
      debugPrint('[BATCH] 队列为空，无需处理');
      return;
    }

    // 预览确认检查：若处于待确认状态，不自动处理（等用户点"开始处理"）
    if (_isAwaitingConfirmation) {
      debugPrint('[BATCH] 等待用户确认，跳过自动处理');
      return;
    }

    debugPrint('[BATCH] ========== 启动/继续任务队列 ==========');
    debugPrint(
        '[BATCH] 当前状态: _isProcessingQueue=$_isProcessingQueue, 游戏数=${_games.length}');

    // 如果已经在处理队列中，只标记有新任务（不重复启动）
    if (_isProcessingQueue) {
      debugPrint('[BATCH] ℹ️ 队列已在运行，已通过 _hasNewPendingGames 标记新任务');
      debugPrint('[BATCH] 当前队列会在完成现有任务后自动检测并处理新游戏');
      return;
    }

    _isProcessingQueue = true;
    _isDisposed = false;
    notifyListeners();

    // P0.4：3 并发批处理，将串行 while 循环改为 maxConcurrency 并发池
    // 并发度选择 3：各源 RateLimiter 限制（VNDB 200ms、Bangumi 1s）下
    // 的吞吐与退避平衡点，过高会频繁触发 429 退避反而降低效率。
    const int maxConcurrency = 3;

    try {
      // ✨ 外层循环支持多次追加导入
      // 当用户在处理过程中新增游戏时，_hasNewPendingGames会被设置为true
      // 外层循环会检测到这个标志并继续处理新游戏
      int processingRound = 0;

      do {
        processingRound++;
        debugPrint(
            '[BATCH] 📍 开始第 $processingRound 轮处理 (共 ${_games.length} 个游戏)');
        _hasNewPendingGames = false; // 重置新任务标志

        // 快照本轮待处理游戏 ID（避免并发期间索引失效）
        final pendingIds = <String>[];
        for (int i = 0; i < _games.length; i++) {
          if (_isDisposed) break;
          final game = _games[i];
          if (_cancelledTasks.contains(game.id)) continue;
          if (game.taskStatus == GameTaskStatus.completed ||
              game.taskStatus == GameTaskStatus.failed ||
              game.taskStatus == GameTaskStatus.processing) {
            continue;
          }
          pendingIds.add(game.id);
        }

        debugPrint('[BATCH] 本轮待处理: ${pendingIds.length} 个游戏');

        // 分批并发处理（每批 maxConcurrency 个）
        for (int batchStart = 0;
            batchStart < pendingIds.length && !_isDisposed;
            batchStart += maxConcurrency) {
          if (_isDisposed) {
            debugPrint('[BATCH] 队列已被清空，中断处理');
            break;
          }

          final batchEnd =
              (batchStart + maxConcurrency).clamp(0, pendingIds.length);
          final batch = pendingIds.sublist(batchStart, batchEnd);

          // 标记批内所有游戏为 processing
          for (final id in batch) {
            final idx = _games.indexWhere((g) => g.id == id);
            if (idx != -1 &&
                idx < _games.length &&
                !_cancelledTasks.contains(id)) {
              _games[idx] = _games[idx].copyWith(
                taskStatus: GameTaskStatus.processing,
                errorMessage: null,
              );
            }
          }
          notifyListeners();

          debugPrint('[BATCH] 并发处理批次 ${batchStart ~/ maxConcurrency + 1}: '
              '${batch.length} 个游戏');

          // 并发执行批次（Future.wait 等待全部完成再进入下一批）
          await Future.wait(
            batch.map((id) => _processSingleGameById(id, processingRound)),
          );

          if (_isDisposed) break;
        }

        // 如果已被清空，跳出外层循环
        if (_isDisposed) break;

        // 检查这一轮处理期间是否有新游戏被添加
        if (_hasNewPendingGames) {
          debugPrint('[BATCH] 🔄 检测到有新游戏被添加，准备开始下一轮处理...');
          debugPrint('[BATCH] 当前待处理游戏数: $pendingCount');
        } else {
          debugPrint('[BATCH] ✓ 第 $processingRound 轮处理完成，无新游戏');
        }
      } while (_hasNewPendingGames && !_isDisposed); // 如果有新游戏且未被清空，继续循环

      // 队列处理完成
      _isProcessingQueue = false;
      _currentProcessingIndex = -1;
      _currentDedupIndex = null; // 清理排重索引缓存
      // ★ IMP-18（2026-09-12 导入审查）：处理循环结束后复位预览确认态。
      // 旧实现：处理中新增游戏会置位 _isAwaitingConfirmation（addFolders），
      // 而循环结束不复位 → 预览确认条常驻、retryGame 被 autoProcessNewGames
      // 的待确认早退拦下（静默失效）。此时所有待处理项已处理完毕，预览态应结束。
      _isAwaitingConfirmation = false;

      // 输出最终统计
      onSuccess?.call(
          '批量导入完成: $completedCount 成功, $failedCount 失败, $cancelledCount 已取消 (共 ${processingRound} 轮)');

      notifyListeners();
      debugPrint('[BATCH] ========== 任务队列全部完成 ==========');
      debugPrint('[BATCH] 总计处理轮数: $processingRound');
      debugPrint(
          '[BATCH] 最终统计: $completedCount 成功, $failedCount 失败, $cancelledCount 已取消');
    } catch (e) {
      onError?.call('队列处理异常: $e');
      _isProcessingQueue = false;
      _currentDedupIndex = null;
      // ★ IMP-18: 异常退出同样复位预览确认态（与正常收尾一致）
      _isAwaitingConfirmation = false;
      notifyListeners();
    }
  }

  /// 处理单个游戏（识别 exe + 抓取元数据 + 触发封面下载）
  ///
  /// 从 [autoProcessNewGames] 提取，支持并发调用。
  ///
  /// **并发安全**：
  /// - 所有状态更新通过 `_games.indexWhere` 按 ID 重新定位，不依赖固定索引
  /// - Dart 单线程事件循环保证 `_games` 列表操作无数据竞争
  /// - `_isDisposed` / `_cancelledTasks` 在关键检查点中断
  /// - 封面下载保持 fire-and-forget，不阻塞并发批次
  Future<void> _processSingleGameById(
      String gameId, int processingRound) async {
    // 重新按 ID 定位（并发期间索引可能已变化）
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index == -1 || index >= _games.length) {
      debugPrint('[BATCH] 游戏已不存在，跳过: $gameId');
      return;
    }

    // 跳过已取消的任务
    if (_cancelledTasks.contains(gameId)) {
      debugPrint('[BATCH] 跳过已取消的任务: $gameId');
      return;
    }

    final game = _games[index];
    debugPrint('[BATCH] 开始处理 [第${processingRound}轮]: ${game.gameName}');

    try {
      // 步骤1：识别启动程序
      final exe = detectLaunchExe(game.folderPath);
      if (exe != null) {
        final idx = _games.indexWhere((g) => g.id == gameId);
        if (idx != -1 && idx < _games.length) {
          _games[idx] = _games[idx].copyWith(launchExe: exe);
          notifyListeners();
        }
      }

      // 检查是否已被清空/释放
      if (_isDisposed) return;

      // 再次检查是否被取消/删除（在长时间操作后）
      if (!_games.any((g) => g.id == gameId)) {
        debugPrint('[BATCH] 游戏在处理过程中被删除，停止当前任务: ${game.gameName}');
        return;
      }
      if (_cancelledTasks.contains(gameId)) {
        debugPrint('[BATCH] 任务在处理过程中被取消: ${game.gameName}');
        return;
      }

      // 步骤2：抓取元数据
      final metaIndex = _games.indexWhere((g) => g.id == gameId);
      if (metaIndex == -1) return;
      await fetchSingleGameMetadata(metaIndex);

      // 检查是否已被清空/释放
      if (_isDisposed) return;

      // 重新获取索引（可能在异步操作期间列表发生了变化）
      final currentIndex = _games.indexWhere((g) => g.id == gameId);

      // 步骤3：下载封面图（异步，不阻塞并发批次中的其他游戏）
      // 性能优化：封面下载改为 fire-and-forget，UI 通过 notifyListeners 自动刷新
      // 修复 2026-08：进入 fire-and-forget 前先快照游戏 id，下载完成后回调里
      // 校验"仍然是同一游戏"再 notifyListeners，避免通知给"已删除游戏的回调"。
      if (currentIndex != -1 &&
          currentIndex < _games.length &&
          _games[currentIndex].id == gameId &&
          _games[currentIndex].metadata?['cover_url'] != null &&
          !_cancelledTasks.contains(gameId)) {
        // 快照游戏 id，下载完成回调里校验仍是同一游戏再 notifyListeners
        downloadCoverImage(currentIndex).then((_) {
          if (!_isDisposed) {
            // 双重校验：notify 前再确认游戏仍存在且未被替换
            if (currentIndex < _games.length &&
                _games[currentIndex].id == gameId) {
              notifyListeners();
            }
          }
        }).catchError((e) {
          debugPrint('[BATCH] 封面下载失败: ${game.gameName} - $e');
        });
      }

      // 检查是否已被清空/释放
      if (_isDisposed) return;

      // 标记为完成
      if (currentIndex != -1 &&
          currentIndex < _games.length &&
          _games[currentIndex].id == gameId &&
          !_cancelledTasks.contains(gameId)) {
        _games[currentIndex] = _games[currentIndex].copyWith(
          taskStatus: GameTaskStatus.completed,
        );
        debugPrint('[BATCH] ✓ 完成: ${_games[currentIndex].gameName}');
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[BATCH] ✗ 失败: ${game.gameName} - $e');

      final errorIndex = _games.indexWhere((g) => g.id == gameId);
      if (errorIndex != -1 &&
          errorIndex < _games.length &&
          _games[errorIndex].id == gameId) {
        _games[errorIndex] = _games[errorIndex].copyWith(
          taskStatus: GameTaskStatus.failed,
          errorMessage: e.toString(),
        );
      }
      notifyListeners();
    }
  }

  String? detectLaunchExe(String folderPath) {
    // 委托共享扫描器的规范实现（批量导入 / 智能导入共用，
    // 保证两种导入模式选中的启动程序完全一致）
    return GameFolderScanner.detectLaunchExe(folderPath);
  }

  Future<void> downloadCover(int gameIndex, String url) async {
    // 索引有效性检查：fire-and-forget 任务在并发期间游戏列表可能已变更
    if (gameIndex < 0 || gameIndex >= _games.length) {
      debugPrint('[BATCH] ⚠️ 封面下载跳过：索引 $gameIndex 已越界（列表长度 ${_games.length}）');
      return;
    }
    final game = _games[gameIndex];
    if (_cancelledTasks.contains(game.id) || _isDisposed) {
      debugPrint('[BATCH] ⚠️ 封面下载跳过：游戏已被取消/释放 ${game.gameName}');
      return;
    }

    // Phase 3.1: 委托给统一的 CoverDownloadService
    // 原实现硬编码 .jpg 扩展名，且无缓存优先/重试机制
    //
    // 文件命名规范：以游戏 id 为前缀 + nonce 后缀。
    // 修复 2026-08：原先用 DateTime.now().millisecondsSinceEpoch 生成 fileName，
    // 并发场景下 5 个游戏在同一毫秒进入会生成相同文件名 → 互相覆盖封面。
    // 现在 CoverDownloadService 自动追加进程内单调递增的 nonce 保证唯一性。
    final ext = CoverDownloadService.detectExtension(url);
    final tempDir = Directory(PathHelper.portableTmpDir);
    final fileName = 'batch_cover_${game.id}.$ext';
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: tempDir.path,
      coverUrl: url,
      fileName: fileName,
    );

    // 任务可能被并发取消/删除：再次校验再写回
    if (_isDisposed) return;
    if (gameIndex >= _games.length || _games[gameIndex].id != game.id) {
      debugPrint('[BATCH] ⚠️ 封面下载完成但游戏已被替换/删除，跳过写回 ${game.gameName}');
      // 清理已下载的临时文件，避免污染临时目录
      if (savedName != null) {
        try {
          final f = File('${tempDir.path}/$savedName');
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      return;
    }
    if (_cancelledTasks.contains(game.id)) {
      debugPrint('[BATCH] ⚠️ 封面下载完成但任务已被取消，丢弃 ${game.gameName}');
      if (savedName != null) {
        try {
          final f = File('${tempDir.path}/$savedName');
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      return;
    }

    if (savedName != null) {
      _games[gameIndex] = _games[gameIndex]
          .copyWith(coverFilePath: '${tempDir.path}/$savedName');
      debugPrint('[BATCH] ✅ 封面已下载: ${game.gameName} → $savedName');
    } else {
      debugPrint('[BATCH] 封面下载失败: ${game.gameName} - $url');
    }
  }

  // 新增：处理单个游戏的元数据抓取
  Future<void> fetchSingleGameMetadata(int gameIndex) async {
    if (gameIndex >= _games.length) return;

    final game = _games[gameIndex];

    // 抓取开始前再次校验：游戏可能已被用户取消
    if (_cancelledTasks.contains(game.id) || _isDisposed) return;

    // 如果已有元数据，跳过
    if (game.metadata != null && game.metadata!.isNotEmpty) return;

    // 记录抓取开始时间（用于自适应间隔计算）
    final fetchStartTime = DateTime.now();

    try {
      debugPrint('[BATCH] 抓取元数据: ${game.gameName}');

      // 批量导入默认使用 MIX 源：并发抓取 VNDB/KunGal/Hikarinagi/Steam/月幕GAL
      // 并按字段优先级整合（封面 VNDB、简介/截图 KunGal、标签 Hikarinagi、
      // 中文字段优先，详见 MetadataFetcher.fetchGameMixed）
      final bestMatch = await MetadataFetcher.fetchGameMixed(game.gameName);

      // await 期间游戏可能被用户取消/删除：写回前必须校验"仍然是同一游戏"
      // 修复 2026-08：原先直接 _games[gameIndex] = ... 写回，
      // 若用户在此期间删除了该游戏或切换了排序，会发生：
      //   1) 越界写入
      //   2) 把 A 的元数据写到 B 的位置（数据错乱）
      if (_isDisposed) return;
      if (gameIndex >= _games.length) {
        debugPrint('[BATCH] ⚠️ 元数据抓取完成但索引已越界，丢弃: ${game.gameName}');
        return;
      }
      if (_games[gameIndex].id != game.id) {
        debugPrint('[BATCH] ⚠️ 元数据抓取完成但游戏已被替换，丢弃: ${game.gameName}');
        return;
      }
      if (_cancelledTasks.contains(game.id)) {
        debugPrint('[BATCH] ⚠️ 元数据抓取完成但任务已取消，丢弃: ${game.gameName}');
        return;
      }

      if (bestMatch != null) {
        // ★ 阶段 B 排重：元数据源 ID 硬冲突检查
        // 扫描阶段（阶段 A）只能用路径+标题排重，此处元数据抓取后
        // 可用源 ID（VNDB ID/Bangumi ID 等）做可靠排重。
        // MIX 源结果附带 source_platforms（各底层平台与其 ID），
        // 任一底层平台 ID 与库内冲突即视为重复
        final platform = bestMatch['platform']?.toString() ?? '';
        final platformId = bestMatch['platform_id']?.toString() ?? '';
        final sourcePlatforms =
            bestMatch['source_platforms'] as Map<String, dynamic>?;

        var sourceVerdict = const DedupVerdict.noConflict();
        final dedupIndex =
            _currentDedupIndex ?? ImportDedupIndex.fromRegistry();
        // 依次检查各底层平台 ID（含 MIX 主标识）
        final checkPairs = <List<String>>[
          if (platform.isNotEmpty && platformId.isNotEmpty)
            [platform, platformId],
          if (sourcePlatforms != null)
            ...sourcePlatforms.entries
                .where((e) => e.value.toString().isNotEmpty)
                .map((e) => [e.key, e.value.toString()]),
        ];
        for (final pair in checkPairs) {
          final verdict = dedupIndex.checkWithSource(pair[0], pair[1]);
          if (verdict.isHardConflict) {
            sourceVerdict = verdict;
            break;
          }
        }
        if (sourceVerdict.isHardConflict) {
          debugPrint(
              '[BATCH] ✗ 元数据源 ID 冲突，标记为硬重复: ${game.gameName} | ${sourceVerdict.reason}');
          _games[gameIndex].saveOriginalSnapshot();
          _games[gameIndex] = _games[gameIndex].copyWith(
            metadata: bestMatch,
            metadataTitle:
                bestMatch['game_name']?.toString() ?? game.metadataTitle,
            // 主标题保持导入时的设置（导入标题 > 抓取标题）
            gameName: game.gameName,
            usingMetadataTitle: false,
            isHardDuplicate: true,
            duplicateWarning: sourceVerdict.reason,
            taskStatus: GameTaskStatus.completed,
          );
          notifyListeners();
          return;
        }

        // 在覆盖数据前保存原始快照
        _games[gameIndex].saveOriginalSnapshot();
        // 业务规则：导入标题 > 抓取标题，保持导入时设置的主标题不变。
        // 元数据标题仅记录到 metadataTitle，供用户通过 UI 切换（不直接替换主标题）。
        final metadataGameName = bestMatch['game_name']?.toString() ?? '';

        // 副标题：日文原版标题（含 CJK 字符，排除纯英文）且与主标题不同时填充
        final originalTitleStr =
            bestMatch['original_title']?.toString().trim() ?? '';
        final shouldFillSubtitle = originalTitleStr.isNotEmpty &&
            _containsCjk(originalTitleStr) &&
            originalTitleStr != game.gameName.trim();

        _games[gameIndex] = _games[gameIndex].copyWith(
          metadata: bestMatch,
          // 双标题：记录元数据标题（非空时更新，空则保留原值）
          metadataTitle: metadataGameName.isNotEmpty
              ? metadataGameName
              : game.metadataTitle,
          // 主标题保持导入时的设置，不被抓取结果替换（导入标题 > 抓取标题）
          gameName: game.gameName,
          usingMetadataTitle: false,
          // 副标题：自动填充日文原版标题（与主标题相同时不填充）
          subtitle: shouldFillSubtitle ? originalTitleStr : game.subtitle,
          tags:
              (bestMatch['tags'] as List?)?.map((t) => t.toString()).toList() ??
                  game.tags,
          description: bestMatch['summary'] ?? game.description,
          developer: bestMatch['developer']?.toString() ?? '',
          screenshotUrls: (bestMatch['screenshot_urls'] as List?)
                  ?.map((e) => e.toString())
                  .where((e) => e.isNotEmpty)
                  .toList() ??
              [],
        );

        // 如果当前抓取的游戏正是用户正在编辑的游戏，不触发表单同步
        // 只在用户主动切换选中时才同步，避免覆盖用户编辑
        final isCurrentlyEditing =
            _selectedGame != null && _selectedGame!.id == game.id;
        if (!isCurrentlyEditing) {
          notifyListeners();
        } else {
          // 仍然通知UI更新右侧卡片，但不触发左侧表单同步
          // 通过不设置 _lastSelectedGameId 来避免同步
          notifyListeners();
        }

        debugPrint('[BATCH] ✓ 元数据获取成功: ${_games[gameIndex].gameName}');
      }
    } catch (e) {
      debugPrint('[BATCH] 元数据抓取失败 [${game.gameName}]: $e');
    }

    // 自适应间隔：基于抓取耗时动态调整，避免不必要的等待
    // 性能优化：从固定1秒降至最小200ms，显著缩短批量抓取总耗时
    final fetchDuration = DateTime.now().difference(fetchStartTime);
    final minInterval = const Duration(milliseconds: 200);
    if (fetchDuration < minInterval) {
      await Future.delayed(minInterval - fetchDuration);
    }
  }

  // 新增：下载单个游戏的封面图
  Future<void> downloadCoverImage(int gameIndex) async {
    if (gameIndex >= _games.length) return;

    final coverUrl = _games[gameIndex].metadata?['cover_url'];
    if (coverUrl == null || coverUrl.toString().isEmpty) return;

    await downloadCover(gameIndex, coverUrl.toString());
  }

  Future<void> submitBatchImport() async {
    if (_games.isEmpty) {
      onError?.call('没有可入库的游戏');
      return;
    }

    // 筛选已完成且未取消且非硬重复的游戏进行入库
    // isHardDuplicate=true 的游戏在元数据抓取阶段被标记为源 ID 重复，自动跳过
    final candidates = _games
        .where((g) =>
            g.taskStatus == GameTaskStatus.completed &&
            !g.isHardDuplicate &&
            !_cancelledTasks.contains(g.id))
        .toList();

    // 数据完整性闸口（2026-10-03）：封面/简介任一缺失 = 数据不全，
    // 不入库、保留在列表中由用户自行处理（表单补全，或点"重试"重新抓取）。
    // 实时评估：用户补全后再次点击「确认导入」即通过。
    final gamesToImport =
        candidates.where((g) => g.missingCoreFields.isEmpty).toList();
    final incompleteGames =
        candidates.where((g) => g.missingCoreFields.isNotEmpty).toList();

    // 统计硬重复跳过数（用于结果提示）
    final hardDupSkipped = _games.where((g) => g.isHardDuplicate).length;

    if (gamesToImport.isEmpty) {
      if (incompleteGames.isNotEmpty) {
        onError?.call('${incompleteGames.length} 款游戏数据不全'
            '（缺封面/简介），已保留在列表——请补全数据后再次确认导入，'
            '或点卡片"重试"重新抓取');
      } else {
        onError?.call('没有已完成的游戏可入库');
      }
      return;
    }

    _isProcessingQueue = true;
    _isImporting = true;
    _importProgressTotal = gamesToImport.length;
    _importProgressCurrent = 0;
    _importingGameName = '';
    notifyListeners();

    try {
      int successCount = 0;
      int failCount = 0;
      // UX-39: 收集每条入库失败记录（游戏名+原因），完成后展示给用户
      final failureDetails = <String>[];
      // ★ IMP-14: 失败原因按游戏 id 记录，收尾时写回条目（UI 据此显示"重试"）
      final failureReasons = <String, String>{};
      // ★ IMP-14: 本次真正入库成功的条目，收尾时只移除它们
      final importedGames = <BatchGameItem>[];

      // 并行入库：每批2个游戏同时处理，提升速度
      const batchSize = 2;
      for (int i = 0; i < gamesToImport.length; i += batchSize) {
        // ★ IMP-13（2026-09-12 导入审查）：不再在循环内 removeWhere。
        // 循环内删元素会改变列表长度、使后续元素整体前移，而 `i` 仍按 batchSize
        // 递增 → 位于被删项之后的那个游戏会被 skip(i) 跳过，
        // 既不导入也不计入失败（随后又被 clearAll 抹掉）。
        // 现在改为"取批次时过滤已取消项"，索引语义保持稳定。
        final batch = takeNextImportBatch(
          all: gamesToImport,
          startIndex: i,
          batchSize: batchSize,
          cancelledIds: _cancelledTasks,
        );
        if (batch.isEmpty) continue;

        // 更新入库进度
        _importProgressCurrent = i;
        _importingGameName = batch.map((g) => g.gameName).join(', ');
        notifyListeners();

        // 并行处理当前批次
        final results = await Future.wait(
          batch.map((game) async {
            try {
              await importSingleGame(game);
              debugPrint('[BATCH] ✓ 入库成功: ${game.gameName}');
              return true;
            } catch (e) {
              // UX-39: 记录失败详情，完成后统一展示给用户
              final reason = e.toString();
              debugPrint('[BATCH] ✗ 入库失败 [${game.gameName}]: $reason');
              // 截断过长的错误信息，避免 SnackBar 撑爆
              final trimmed =
                  reason.length > 80 ? '${reason.substring(0, 80)}...' : reason;
              failureDetails.add('${game.gameName}: $trimmed');
              failureReasons[game.id] = reason; // ★ IMP-14
              return false;
            }
          }),
        );

        for (var k = 0; k < results.length; k++) {
          if (results[k]) {
            successCount++;
            importedGames.add(batch[k]); // ★ IMP-14: 只移除成功项
          } else {
            failCount++;
          }
        }

        _importProgressCurrent = min(i + batch.length, gamesToImport.length);
        notifyListeners();
      }

      // 构建详细的结果消息
      // UX-39: 有失败时附带具体失败游戏名与原因，便于用户排查
      String resultMessage;
      if (failCount == 0) {
        resultMessage = '✓ 成功入库 $successCount 个游戏，截图将在后台自动获取';
      } else {
        final buffer = StringBuffer();
        if (successCount > 0) {
          buffer.writeln('⚠ 入库完成: $successCount 成功, $failCount 失败');
        } else {
          buffer.writeln('✗ 入库失败: 全部 $failCount 个游戏均未成功');
        }
        // 列出失败详情，最多展示5条，超出部分汇总
        const maxShown = 5;
        for (final detail in failureDetails.take(maxShown)) {
          buffer.writeln('• $detail');
        }
        if (failureDetails.length > maxShown) {
          buffer.write('…及其他 ${failureDetails.length - maxShown} 个失败');
        }
        if (successCount > 0) {
          buffer.writeln('（截图将在后台自动获取）');
        }
        // ★ IMP-14: 明确告知失败项被保留，可重试
        buffer.writeln('失败的 $failCount 个已保留在列表中，可点"重试"重新处理');
        resultMessage = buffer.toString().trimRight();
      }

      // 数据不全项提示（2026-10-03）：被完整性闸口拦截未入库的游戏，
      // 保留在列表中由用户处理（卡片有琥珀色提示条）
      if (incompleteGames.isNotEmpty) {
        resultMessage += '\n📌 ${incompleteGames.length} 款数据不全'
            '（缺封面/简介）未入库，已保留在列表——补全后再次确认导入即可';
      }

      // 有失败时用错误通道（红色 SnackBar）展示详情；全部成功用成功通道
      if (failCount > 0) {
        onError?.call(resultMessage);
      } else {
        onSuccess?.call(resultMessage);
      }

      // 通知外部（刷新库页等）——即使部分失败也要刷新已成功入库的游戏
      onGameAdded?.call();

      // ★ IMP-14（2026-09-12 导入审查）：不再无条件 clearAll()。
      // 旧实现把失败项一并清空，用户无法重试，只能重新扫描整个监控目录。
      // 现在只移除已成功入库的条目，失败项保留并标记为 failed（UI 显示"重试"）。
      debugPrint('[BATCH] ========== 入库完成，开始清理已成功项 ==========');
      _removeImportedGames(importedGames, failureReasons);
      debugPrint(
          '[BATCH] ✓ 已移除 ${importedGames.length} 个成功项，剩余 ${_games.length} 个（失败项保留可重试）');
    } catch (e) {
      onError?.call('批量入库异常: $e');
    } finally {
      _isProcessingQueue = false;
      _isImporting = false;
      _importProgressCurrent = 0;
      _importProgressTotal = 0;
      _importingGameName = '';
      notifyListeners();
    }
  }

  /// 取出下一批待入库游戏（★ IMP-13，2026-09-12 导入审查）
  ///
  /// 语义：从 [startIndex] 起取 [batchSize] 个，并**过滤掉已取消的项**，
  /// 但**不修改**传入列表 —— 旧实现在循环内 `removeWhere` 会改变列表长度，
  /// 使后续元素整体前移，而循环变量仍按 batchSize 递增，导致位于被删项之后的
  /// 游戏被 `skip(i)` 跳过（既不导入也不报告失败）。
  /// 独立为静态方法以便单元测试。
  static List<BatchGameItem> takeNextImportBatch({
    required List<BatchGameItem> all,
    required int startIndex,
    required int batchSize,
    required Set<String> cancelledIds,
  }) {
    if (startIndex >= all.length) return const <BatchGameItem>[];
    return all
        .skip(startIndex)
        .take(batchSize)
        .where((g) => !cancelledIds.contains(g.id))
        .toList();
  }

  /// 入库收尾：移除已成功入库的条目，保留失败项并标记为 failed（★ IMP-14）
  ///
  /// 取代原先无条件的 `clearAll()` —— 后者会把失败项一并清空，用户无法重试，
  /// 只能重新扫描整个监控目录。失败项标记为 failed 后 UI 会显示"重试"按钮。
  void _removeImportedGames(
    List<BatchGameItem> importedGames,
    Map<String, String> failureReasons,
  ) {
    for (final game in importedGames) {
      _cleanupSingleGameCache(game);
      _games.removeWhere((g) => g.id == game.id);
      _cancelledTasks.remove(game.id);
      if (_selectedGame?.id == game.id) _selectedGame = null;
    }

    // 保留下来的失败项：标记 failed + 写入原因（UI 的"重试"只对 failed 显示）
    for (var i = 0; i < _games.length; i++) {
      final reason = failureReasons[_games[i].id];
      if (reason == null) continue;
      _games[i].taskStatus = GameTaskStatus.failed;
      _games[i].errorMessage =
          reason.length > 120 ? '${reason.substring(0, 120)}...' : reason;
    }

    // 摘要条与预览确认态：与原 clearAll 的收尾语义一致（本轮导入已结束）
    _lastScanSummary = null;
    _isAwaitingConfirmation = false;
    _currentProcessingIndex = -1;
    notifyListeners();
  }

  Future<void> importSingleGame(BatchGameItem game) async {
    final safeName =
        game.gameName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final metadataSource = game.metadata?['platform']?.toString() ?? '';
    final metadataSourceId = game.metadata?['platform_id']?.toString() ?? '';
    final metaDataDir = '${LocalGameRegistry.gamesBaseDir}/$safeName';

    // 封面URL回退：本地临时文件不存在时，通过网络URL下载（优先从缓存）
    final coverUrl = game.metadata?['cover_url']?.toString();
    final coverFileExists =
        game.coverFilePath != null && File(game.coverFilePath!).existsSync();

    await GameDataFormat.writeGameDir(
      targetDir: metaDataDir,
      title: game.gameName,
      description: game.description,
      tags: game.tags,
      coverFilePath: coverFileExists ? game.coverFilePath : null,
      coverUrl:
          (coverUrl != null && coverUrl.startsWith('http')) ? coverUrl : null,
      launchPath: game.launchExe ?? '',
      directoryPath: game.folderPath,
      source: 'batch_import',
      developer: game.developer,
      screenshotUrls:
          game.screenshotUrls.isNotEmpty ? game.screenshotUrls : null,
      subtitle: game.subtitle,
      metadataSource: metadataSource,
      metadataSourceId: metadataSourceId,
      // ★ 2026-10-04：探索页对齐元数据（抓取结果透传入库）
      releaseDate: game.metadata?['release_date']?.toString(),
      rating: (game.metadata?['rating'] as num?)?.toDouble(),
      ratingCount: (game.metadata?['vote_count'] as num?)?.toInt(),
      estimatedMinutes: (game.metadata?['length_minutes'] as num?)?.toInt(),
      // ★ 2026-10-04：横幅封面 URL（MIX 整合结果透传；无横幅 → 按无横幅处理）
      bannerUrl: game.metadata?['banner_url']?.toString(),
    );

    // 通知截图后台抓取服务（入库完成后异步下载截图，不阻塞批量入库流程）
    if (game.screenshotUrls.isNotEmpty) {
      ScreenshotFetchService.instance
          .enqueue(safeName, metaDataDir, game.screenshotUrls);
    }

    // 从元数据目录查找已保存的封面文件
    final coverFile = GameDataFormat.findCoverFile(metaDataDir);

    LocalGameRegistry.instance.registerExtractionComplete(
      gameTitle: safeName,
      directoryPath: game.folderPath,
      coverUrl: coverFile?.path,
      description: game.description,
      developer: game.developer,
      tags: game.tags,
      launchPath: game.launchExe ?? '',
      subtitle: game.subtitle,
      metadataSource: metadataSource,
      metadataSourceId: metadataSourceId,
    );
  }

  void clearAll() {
    // 停止正在处理的队列
    if (_isProcessingQueue) {
      debugPrint('[BATCH] 用户清空了所有任务，停止队列处理');
      _isDisposed = true; // 设置标志以中断异步循环
      _isProcessingQueue = false;
      _currentProcessingIndex = -1;
    }

    // 清理所有临时缓存文件
    _cleanupAllCache();

    // 重置所有状态
    _games.clear();
    _selectedGame = null;
    _cancelledTasks.clear();
    // 清空扫描摘要和预览确认状态：导入完成/取消/失败后摘要条应自动消失
    // 否则 UI 会持续显示上次扫描的统计信息，与实际任务状态不一致
    _lastScanSummary = null;
    _isAwaitingConfirmation = false;
    notifyListeners();
  }

  // ★ IMP-20：删除了无调用点的 `_cleanupCompletedTasksCache`（死代码）。
  // 其"只删应用自有目录内临时封面"的护栏逻辑已由 `_cleanupSingleGameCache` /
  // `_cleanupAllCache` 覆盖。

  // 新增：清理所有缓存（用于clearAll或应用退出时）
  void _cleanupAllCache() {
    try {
      for (final game in _games) {
        if (game.coverFilePath != null && game.coverFilePath!.isNotEmpty) {
          // 修复：同 _cleanupSingleGameCache，只删应用自有目录内的临时封面，
          // 绝不删用户磁盘上的原图（可能是表单里选的桌面/图片文件）。
          if (!PathHelper.isInsideAppStorage(game.coverFilePath!)) {
            debugPrint(
                '[BATCH] ⏭️ 跳过非应用目录封面（可能是用户原图）: ${game.coverFilePath}');
            continue;
          }
          final file = File(game.coverFilePath!);
          if (file.existsSync()) {
            file.deleteSync();
            debugPrint('[BATCH] 删除缓存文件: ${game.coverFilePath}');
          }
        }
      }
    } catch (e) {
      debugPrint('[BATCH] 清理所有缓存异常: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _isProcessingQueue = false;
    _cleanupAllCache();
    super.dispose();
  }
}
