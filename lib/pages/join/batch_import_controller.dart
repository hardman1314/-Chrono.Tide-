import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../../services/metadata_fetcher.dart';
import '../../services/screenshot_fetch_service.dart';
import '../../services/cover_download_service.dart';
import '../../utils/title_cleaner.dart';
import '../../utils/path_normalizer.dart';
import '../../models/watch_folder.dart';
import '../../services/scan_logger.dart';
import '../../services/import_dedup_index.dart';
import './utils/gal_game_detector.dart';

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

  // 多维排重：软警告（同名可能重复）+ 硬冲突（元数据源 ID 重复）
  // duplicateWarning 非空时 UI 显示橙色徽章，仍允许导入
  // isHardDuplicate 为 true 时 submitBatchImport 自动跳过
  String? duplicateWarning;
  bool isHardDuplicate;

  // 双标题管理：
  // - originalTitle：导入时从文件夹名清洗得到（不可变，导入后固定）
  // - metadataTitle：元数据抓取到的标准游戏名（首次抓取后赋值，可被新选择覆盖）
  // - usingMetadataTitle：当前 gameName 是否使用元数据标题（默认 false，抓取后切 true）
  //   gameName 始终 = usingMetadataTitle ? metadataTitle : originalTitle
  //   用户可通过 UI 在两者间切换；手动编辑 gameName 时视为自定义标题（不切换标志）
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

/// 内部辅助：识别后的游戏候选（路径 + 检测结果）
///
/// 用于 [BatchImportController.scanFolderForGames] 阶段三/四的后处理，
/// 需访问 [GalDetectionResult.strongSignals] 判定是否为引擎根目录
/// （强信号）vs 归纳文件夹（无强信号）。
class _DetectedGame {
  final String path;
  final GalDetectionResult detection;
  _DetectedGame(this.path, this.detection);
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
    await _collectCandidates(
      dir,
      candidates,
      rootPath,
      depth: 0,
      maxDepth: 4,
      excludePatterns: WatchFolder.defaultExcludePatterns,
    );
    debugPrint('[BATCH] 阶段一：收集到 ${candidates.length} 个候选目录');

    // 初始化 ScanLogger 与 ScanSummary（扫描期间累积决策依据）
    final summary = ScanSummary();
    ScanLogger.instance.startScan(rootPath, candidates.length);

    // ===== 阶段二：逐个识别（不做父子重叠去重）=====
    // 关键修复：先收集所有识别为游戏的目录，再做后处理。
    // 旧实现在循环中做父子重叠去重（"先识别的保留"），导致 rootPath
    // （如 GAL 文件夹）被识别后，所有子目录游戏都因父子重叠被跳过。
    final detected = <_DetectedGame>[];
    // 检测结果缓存：记录所有 mainExeName != null 的候选检测结果，
    // 供阶段 2.5 包装文件夹救援复用，避免对同一目录重复调用 detect()。
    final detectionCache = <String, GalDetectionResult>{};
    for (final candidatePath in candidates) {
      // ★ 根目录保护：用户选择的扫描根目录本身不应被识别为单个游戏
      // （即使根目录恰好含 exe，也应让扫描进入子目录发现各游戏）
      // 用 forCompare 规范化比较，消除尾斜杠/大小写/分隔符差异导致保护失效的风险
      if (PathNormalizer.forCompare(candidatePath) ==
          PathNormalizer.forCompare(rootPath)) {
        debugPrint('[BATCH] ⊘ 跳过根目录本身（不作为游戏）: $candidatePath');
        continue;
      }

      final folderName = candidatePath.split('/').last.split('\\').last;

      // 2a. 多维排重（路径包含硬跳过 + 同名软警告）
      // 替代旧实现的 Set 精确匹配，支持路径包含冲突（A⊂B 或 B⊂A）
      final cleanedTitle = TitleCleaner.cleanFromDirPath(candidatePath);
      final inferredTitle = cleanedTitle.isNotEmpty ? cleanedTitle : folderName;
      final verdict = dedupIndex.check(candidatePath, title: inferredTitle);
      if (verdict.isHardConflict) {
        skippedImportedPaths?.add(candidatePath);
        debugPrint('[BATCH] ✗ 跳过已导入游戏: $folderName | ${verdict.reason}');
        ScanLogger.instance.logCandidate(
          candidatePath,
          accepted: false,
          summary: summary,
          reason: ScanSkipReason.pathConflict,
        );
        continue;
      }

      // 2b. 严格识别（GalGameDetector.detect + 通用名拦截）
      final detection = _isIndependentGame(candidatePath);
      // 缓存非 null 检测结果（mainExeName != null），供阶段 2.5 救援复用
      if (detection != null) {
        detectionCache[candidatePath] = detection;
      }
      if (detection == null || !detection.isGame) {
        final reason = detection == null
            ? ScanSkipReason.noExecutable
            : ScanSkipReason.lowConfidence;
        debugPrint('[BATCH] ✗ 跳过（非游戏）: $folderName | '
            '${detection?.reasonSummary ?? "无可执行文件"}');
        ScanLogger.instance.logCandidate(
          candidatePath,
          accepted: false,
          summary: summary,
          reason: reason,
          detection: detection,
        );
        continue;
      }

      debugPrint('[BATCH] ✓ 候选游戏: $folderName ($candidatePath) | '
          '${detection.reasonSummary}');
      detected.add(_DetectedGame(candidatePath, detection));
    }

    // ===== 阶段 2.5：包装文件夹救援（exe 在子目录场景）=====
    // 场景：游戏本体文件夹（如"命运石之门"）本身无直接 exe——exe 在 bin/、
    //       存档备份/、launcher/ 等子目录中。直接签名门控使其 isGame=false 被跳过；
    //       含 exe 的子目录又因通用名拦截或自身非游戏也被跳过 → 游戏完全漏识别。
    //       这是直接签名门控引入的回归风险点，必须救援。
    // 修复：扫描未被识别的候选，若它有「继承 exe」（mainExeInherited，即 exe 在子目录）、
    //       非通用名、CJK 名、无直接签名、且含 <2 个游戏子目录（避免救起容器），
    //       提升为游戏。复用阶段二的 detectionCache 避免重复 detect() 调用。
    //
    // 此统一逻辑覆盖原「通用名子目录→父救援」场景（通用名子目录仍使父目录获得继承 exe）
    // 并扩展到非通用名子目录（launcher/app/program 等）。
    final rescuedParents = <_DetectedGame>[];
    final rootNormalized = PathNormalizer.forCompare(rootPath);
    for (final candidatePath in candidates) {
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
        debugPrint('[BATCH] ⊘ 救援判定："$folderName" 含 $childGameCount 个'
            '游戏子目录，判定为容器不救援');
        continue;
      }

      debugPrint('[BATCH] 🔄 包装文件夹救援: $candidatePath '
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
      debugPrint('[BATCH] 阶段 2.5：救援了 ${rescuedParents.length} 个包装文件夹');
    }

    // ===== 阶段三：移除归纳文件夹（核心修复）=====
    // 修复背景：旧逻辑用 strongSignals.isNotEmpty 保留，但容器文件夹（GAL/JRPG）
    //   会因检测器 2 层扫描继承子游戏的引擎文件而获得强信号 → 被错误保留。
    //   现检测器已区分直接/继承信号（isGame 要求直接签名），容器不再进入 detected。
    //   阶段三现专注于「启动器型合集」：有直接 exe 但含 ≥2 个游戏子目录 → 容器。
    //
    // 直接签名判定（hasDirectStrongSignal/hasDirectExe/hasDirectDataPack+FeatureDir）
    //   来自本文件夹自身内容，是真实游戏本体的可靠依据。
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
      if (g.detection.hasDirectExe) {
        final childGameCount = detected
            .where((other) =>
                other != g &&
                other.detection.isGame &&
                PathNormalizer.isSubdirectory(g.path, other.path))
            .length;
        if (childGameCount >= 2) {
          aggregateFolders.add(g);
          return false; // 启动器型容器，移除
        }
        return true; // 直接 exe + 0-1 游戏子目录 → 真实游戏
      }

      // 无直接签名（安全网：正常情况下容器不会进入 detected）
      final hasChildGame = detected.any((other) =>
          other != g && PathNormalizer.isSubdirectory(g.path, other.path));
      if (!hasChildGame) return true; // 无子游戏，保留
      aggregateFolders.add(g);
      return false; // 有子游戏 + 无直接签名 → 容器，移除
    }).toList();

    for (final af in aggregateFolders) {
      final folderName = af.path.split('/').last.split('\\').last;
      debugPrint('[BATCH] ✗ 跳过（归纳文件夹）: $folderName (${af.path}) | '
          '含 ${detected.where((o) => o != af && PathNormalizer.isSubdirectory(af.path, o.path)).length} 个游戏子目录');
      ScanLogger.instance.logCandidate(
        af.path,
        accepted: false,
        summary: summary,
        reason: ScanSkipReason.aggregateFolder,
        detection: af.detection,
      );
    }

    // ===== 阶段四：父子重叠去重（保留父目录，跳过子模块）=====
    // 经过阶段三后，剩下的父子关系中父目录是真正游戏
    // （有强信号，或有 exe+数据包的游戏本体保护），
    // 子目录是子模块（如 Ren'Py 的 game/ 子目录可能因含 .rpyc 被误识别），
    // 保留父跳过子符合预期。
    final deduped = <_DetectedGame>[];
    for (final g in kept) {
      final isChildOfExisting = deduped.any(
          (existing) => PathNormalizer.isSubdirectory(existing.path, g.path));
      if (isChildOfExisting) {
        final folderName = g.path.split('/').last.split('\\').last;
        debugPrint('[BATCH] ✗ 跳过（父子重叠）: $folderName (${g.path})');
        ScanLogger.instance.logCandidate(
          g.path,
          accepted: false,
          summary: summary,
          reason: ScanSkipReason.parentChildOverlap,
        );
        continue;
      }
      deduped.add(g);
    }

    // ===== 阶段五：共享启动程序去重 + 构建结果 =====
    final foundGames = <BatchGameItem>[];
    for (final g in deduped) {
      if (_hasSameParentGame(foundGames, g.path)) {
        final folderName = g.path.split('/').last.split('\\').last;
        debugPrint('[BATCH] ✗ 跳过（共享启动程序）: $folderName (${g.path})');
        ScanLogger.instance.logCandidate(
          g.path,
          accepted: false,
          summary: summary,
          reason: ScanSkipReason.sharedLauncher,
        );
        continue;
      }

      final cleanedName = TitleCleaner.cleanFromDirPath(g.path);
      final folderName = g.path.split('/').last.split('\\').last;
      final effectiveTitle = cleanedName.isNotEmpty ? cleanedName : folderName;
      debugPrint('[BATCH] ✓ 识别到游戏: $folderName (${g.path}) | '
          '${g.detection.reasonSummary}');
      ScanLogger.instance.logCandidate(
        g.path,
        accepted: true,
        summary: summary,
        detection: g.detection,
      );
      // 多维排重软警告（阶段 2a 中 dedupIndex.check 返回的 warning）
      // 硬冲突已在 2a 跳过，此处仅处理同名软警告
      final dupVerdict = dedupIndex.check(g.path, title: effectiveTitle);
      foundGames.add(BatchGameItem(
        id: '${DateTime.now().millisecondsSinceEpoch}_${foundGames.length}',
        folderPath: g.path,
        gameName: effectiveTitle,
        // 双标题：原标题=清洗后的文件夹名（导入时固定，不可变）
        // metadataTitle 默认 null，usingMetadataTitle 默认 false（用原标题）
        // 元数据抓取后（fetchSingleGameMetadata）才切到元数据标题
        originalTitle: effectiveTitle,
        // 软警告：同名可能重复（UI 显示橙色徽章，仍允许导入）
        duplicateWarning: dupVerdict.hasWarning ? dupVerdict.reason : null,
      ));
    }

    // 写入日志文件 + 更新 lastScanSummary 供 UI 展示
    await ScanLogger.instance.endScan(summary);
    _lastScanSummary = summary;
    debugPrint('[BATCH] 识别完成：候选 ${detected.length} 个，'
        '归纳文件夹 ${aggregateFolders.length} 个，'
        '最终识别 ${foundGames.length} 个游戏');
    return foundGames;
  }

  /// 递归收集候选目录（限制深度避免性能问题）
  ///
  /// 与 watch_folder_service._collectCandidateDirs 行为一致：
  /// - 跳过隐藏目录（`.` 开头）
  /// - 按 [excludePatterns] 做包含匹配过滤
  /// - 限制 [maxDepth] 避免过深递归
  Future<void> _collectCandidates(
    Directory dir,
    List<String> out,
    String rootPath, {
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
        // 排除规则（lowercase 包含匹配，与 watch_folder_service._isExcluded 一致）
        final lower = dirName.toLowerCase();
        if (excludePatterns.any((p) => lower.contains(p.toLowerCase()))) {
          continue;
        }
        out.add(entity.path);
        await _collectCandidates(
          Directory(entity.path),
          out,
          rootPath,
          depth: depth + 1,
          maxDepth: maxDepth,
          excludePatterns: excludePatterns,
        );
      }
    } catch (e) {
      debugPrint('[BATCH] 收集候选目录异常: $e');
      ScanLogger.instance.logError('收集目录异常: $e');
    }
  }

  // 严格判定目录是否为独立游戏。
  // 替代旧 _isIndependentGame（死代码）+ isLikelyGalGame + _hasExecutableFile 三段调用。
  // 返回 null 表示无可用主启动程序；否则返回完整检测结果（含依据供日志/UI）。
  // 调用方据 detection.isGame 判定是否接受。
  GalDetectionResult? _isIndependentGame(String folderPath) {
    final detection = GalGameDetector.detect(folderPath);
    // 无主 exe → 连 Ren'Py 也至少有 .exe 解释器，无 exe 基本可判非游戏
    if (detection.mainExeName == null) return null;
    if (!detection.isGame) return detection;
    // 通用目录名拦截（保留旧 _isGenericName 语义）
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

  bool _isGenericName(String folderName) {
    // 过于通用的目录名，不太可能是独立游戏
    //
    // 英文通用名：精确匹配（避免误伤 "gameData" 等合法名称）
    // CJK 关键词：子串匹配（覆盖组合名如 "AI补丁"、"补丁&存档"、
    //   "全CG存档"、"[白井木学园]...完整汉化补丁" 等）
    //
    // CJK 子串匹配安全：游戏文件夹名通常是游戏标题（如"命运石之门"），
    // 不会包含"补丁/存档/备份/汉化"等附属词汇作为子串。
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
    // 基础关键词覆盖所有组合形式：
    //   "补丁" → AI补丁、补丁&存档、汉化补丁、更新补丁...
    //   "存档" → 全CG存档、存档备份...
    //   "备份" → 存档备份、备份文件夹...
    //   "汉化" → 汉化补丁、汉化版...
    final cjkKeywords = ['补丁', '存档', '备份', '汉化'];
    for (final kw in cjkKeywords) {
      if (folderName.contains(kw)) return true;
    }

    return false;
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

  bool _hasSameParentGame(List<BatchGameItem> existingGames, String newPath) {
    // 检查新路径是否是某个已存在游戏的子目录，且共享相同的启动程序
    for (final game in existingGames) {
      if (PathNormalizer.isSubdirectory(game.folderPath, newPath)) {
        // 如果父目录和新目录有相同的exe文件，则视为同一个游戏
        final parentExe = detectLaunchExe(game.folderPath);
        final childExe = detectLaunchExe(newPath);

        if (parentExe != null && childExe != null) {
          // 提取exe完整相对路径进行比较（而不只是文件名）
          // 只有当exe在完全相同的位置时才认为是同一个游戏
          final parentExeName = parentExe.toLowerCase();
          final childExeName = childExe.toLowerCase();

          // 放宽条件：只有当两个路径非常接近（真正的子模块）时才跳过
          // 通过检查路径深度差来判断：如果深度差<=1且exe同名，才认为是重复
          // 用 PathNormalizer.depthOf 替代 split('\\').length，
          // 修复混合分隔符路径下深度计算错误的 bug
          final depthDiff = PathNormalizer.depthOf(newPath, game.folderPath);

          if (depthDiff >= 0 &&
              depthDiff <= 1 &&
              parentExeName == childExeName) {
            debugPrint(
                '[BATCH] 跳过重复游戏: $newPath (与 ${game.folderPath} 共享相同启动程序, 深度差=$depthDiff)');
            return true;
          }
        }
      }
    }

    return false;
  }

  bool _isSubdirectory(String potentialParent, String potentialChild) {
    // 检查potentialChild是否是potentialParent的直接或间接子目录
    return PathNormalizer.isSubdirectory(potentialParent, potentialChild);
  }

  Future<void> handleDraggedFiles(List<String> paths) async {
    final folders = <String>[];

    for (final path in paths) {
      if (Directory(path).existsSync()) {
        folders.add(path);
      } else if (File(path).existsSync()) {
        final parentDir = File(path).parent.path;
        if (!folders.contains(parentDir)) {
          folders.add(parentDir);
        }
      }
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
        final coverFile = File(game.coverFilePath!);
        if (coverFile.existsSync()) {
          coverFile.deleteSync();
          debugPrint('[BATCH] 🗑️ 已删除封面缓存: ${game.coverFilePath}');
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

    _games[index] = _games[index].copyWith(
      taskStatus: GameTaskStatus.pending,
      errorMessage: null,
      // 清除可能存在的错误元数据，允许重新抓取
      metadata: game.metadata,
    );
    _hasNewPendingGames = true;
    notifyListeners();

    debugPrint('[BATCH] 🔄 重试游戏: ${game.gameName}');

    // 若队列未运行，触发处理；若已在运行，靠 _hasNewPendingGames 标志自动续处理
    if (!_isProcessingQueue) {
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
      if (currentIndex != -1 &&
          currentIndex < _games.length &&
          _games[currentIndex].metadata?['cover_url'] != null &&
          !_cancelledTasks.contains(_games[currentIndex].id)) {
        downloadCoverImage(currentIndex).then((_) {
          if (!_isDisposed) notifyListeners();
        }).catchError((e) {
          debugPrint('[BATCH] 封面下载失败: ${game.gameName} - $e');
        });
      }

      // 检查是否已被清空/释放
      if (_isDisposed) return;

      // 标记为完成
      if (currentIndex != -1 &&
          currentIndex < _games.length &&
          !_cancelledTasks.contains(_games[currentIndex].id)) {
        _games[currentIndex] = _games[currentIndex].copyWith(
          taskStatus: GameTaskStatus.completed,
        );
        debugPrint('[BATCH] ✓ 完成: ${_games[currentIndex].gameName}');
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[BATCH] ✗ 失败: ${game.gameName} - $e');

      final errorIndex = _games.indexWhere((g) => g.id == gameId);
      if (errorIndex != -1 && errorIndex < _games.length) {
        _games[errorIndex] = _games[errorIndex].copyWith(
          taskStatus: GameTaskStatus.failed,
          errorMessage: e.toString(),
        );
      }
      notifyListeners();
    }
  }

  String? detectLaunchExe(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return null;

      final exeFiles = <MapEntry<File, int>>[];

      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer') &&
              !name.contains('patch')) {
            try {
              exeFiles.add(MapEntry(entity, entity.lengthSync()));
            } catch (_) {}
          }
        }
      }

      if (exeFiles.isEmpty) return null;

      // 优先选择中文版
      for (final entry in exeFiles) {
        final name = entry.key.path.toLowerCase();
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
    } catch (e) {
      return null;
    }
  }

  Future<void> downloadCover(int gameIndex, String url) async {
    // Phase 3.1: 委托给统一的 CoverDownloadService
    // 原实现硬编码 .jpg 扩展名，且无缓存优先/重试机制
    final ext = CoverDownloadService.detectExtension(url);
    final tempDir = Directory.systemTemp;
    final fileName =
        'batch_cover_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: tempDir.path,
      coverUrl: url,
      fileName: fileName,
    );
    if (savedName != null) {
      _games[gameIndex] = _games[gameIndex]
          .copyWith(coverFilePath: '${tempDir.path}/$savedName');
    } else {
      debugPrint('[BATCH] 封面下载失败: $url');
    }
  }

  // 新增：处理单个游戏的元数据抓取
  Future<void> fetchSingleGameMetadata(int gameIndex) async {
    if (gameIndex >= _games.length) return;

    final game = _games[gameIndex];

    // 如果已有元数据，跳过
    if (game.metadata != null && game.metadata!.isNotEmpty) return;

    // 记录抓取开始时间（用于自适应间隔计算）
    final fetchStartTime = DateTime.now();

    try {
      debugPrint('[BATCH] 抓取元数据: ${game.gameName}');

      final results = await MetadataFetcher.fetchGame(game.gameName);

      if (results.isNotEmpty) {
        final bestMatch = results.first;

        // ★ 阶段 B 排重：元数据源 ID 硬冲突检查
        // 扫描阶段（阶段 A）只能用路径+标题排重，此处元数据抓取后
        // 可用源 ID（VNDB ID/Bangumi ID 等）做可靠排重
        final platform = bestMatch['platform']?.toString() ?? '';
        final platformId = bestMatch['platform_id']?.toString() ?? '';
        if (platform.isNotEmpty && platformId.isNotEmpty) {
          final dedupIndex =
              _currentDedupIndex ?? ImportDedupIndex.fromRegistry();
          final sourceVerdict =
              dedupIndex.checkWithSource(platform, platformId);
          if (sourceVerdict.isHardConflict) {
            debugPrint(
                '[BATCH] ✗ 元数据源 ID 冲突，标记为硬重复: ${game.gameName} | ${sourceVerdict.reason}');
            _games[gameIndex].saveOriginalSnapshot();
            _games[gameIndex] = _games[gameIndex].copyWith(
              metadata: bestMatch,
              metadataTitle:
                  bestMatch['game_name']?.toString() ?? game.metadataTitle,
              gameName: bestMatch['game_name']?.toString() ?? game.gameName,
              usingMetadataTitle: true,
              isHardDuplicate: true,
              duplicateWarning: sourceVerdict.reason,
              taskStatus: GameTaskStatus.completed,
            );
            notifyListeners();
            return;
          }
        }

        // 在覆盖数据前保存原始快照
        _games[gameIndex].saveOriginalSnapshot();
        // 用户已确认：抓取后默认显示元数据标题（usingMetadataTitle=true）
        // 用户可通过 UI 切换回 originalTitle
        final metadataGameName = bestMatch['game_name']?.toString() ?? '';
        final effectiveGameName =
            metadataGameName.isNotEmpty ? metadataGameName : game.gameName;

        _games[gameIndex] = _games[gameIndex].copyWith(
          metadata: bestMatch,
          // 双标题：记录元数据标题（非空时更新，空则保留原值）
          metadataTitle: metadataGameName.isNotEmpty
              ? metadataGameName
              : game.metadataTitle,
          // 当前显示标题切换为元数据标题（若抓取到）
          gameName: effectiveGameName,
          usingMetadataTitle: metadataGameName.isNotEmpty,
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
    final gamesToImport = _games
        .where((g) =>
            g.taskStatus == GameTaskStatus.completed &&
            !g.isHardDuplicate &&
            !_cancelledTasks.contains(g.id))
        .toList();

    // 统计硬重复跳过数（用于结果提示）
    final hardDupSkipped = _games.where((g) => g.isHardDuplicate).length;

    if (gamesToImport.isEmpty) {
      onError?.call('没有已完成的游戏可入库');
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

      // 并行入库：每批2个游戏同时处理，提升速度
      const batchSize = 2;
      for (int i = 0; i < gamesToImport.length; i += batchSize) {
        // 再次检查是否被取消
        if (_cancelledTasks.isNotEmpty) {
          // 过滤掉被取消的
          gamesToImport.removeWhere((g) => _cancelledTasks.contains(g.id));
        }

        final batch = gamesToImport.skip(i).take(batchSize).toList();
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
              return false;
            }
          }),
        );

        for (final ok in results) {
          if (ok)
            successCount++;
          else
            failCount++;
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
        resultMessage = buffer.toString().trimRight();
      }

      // 有失败时用错误通道（红色 SnackBar）展示详情；全部成功用成功通道
      if (failCount > 0) {
        onError?.call(resultMessage);
      } else {
        onSuccess?.call(resultMessage);
      }

      // 通知外部（刷新库页等）——即使部分失败也要刷新已成功入库的游戏
      onGameAdded?.call();

      // 入库完成后清空所有数据
      debugPrint('[BATCH] ========== 入库完成，开始清理 ==========');
      clearAll();
      debugPrint('[BATCH] ✓ 批量导入数据已全部清理');
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
      metadataSource: metadataSource,
      metadataSourceId: metadataSourceId,
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

  // 新增：清理已完成任务的缓存（封面图等临时文件）
  Future<void> _cleanupCompletedTasksCache() async {
    try {
      for (final game in _games) {
        if (game.taskStatus == GameTaskStatus.completed &&
            game.coverFilePath != null &&
            game.coverFilePath!.isNotEmpty) {
          final file = File(game.coverFilePath!);
          if (await file.exists()) {
            await file.delete();
            debugPrint('[BATCH] 清理缓存: ${game.coverFilePath}');
          }
        }
      }
    } catch (e) {
      debugPrint('[BATCH] 清理缓存异常: $e');
    }
  }

  // 新增：清理所有缓存（用于clearAll或应用退出时）
  void _cleanupAllCache() {
    try {
      for (final game in _games) {
        if (game.coverFilePath != null && game.coverFilePath!.isNotEmpty) {
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
