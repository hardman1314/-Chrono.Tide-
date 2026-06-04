import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import '../../services/local_game_registry.dart';
import '../../services/game_data_format.dart';
import '../../services/metadata_fetcher.dart';
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
  GameTaskStatus taskStatus; // 新增：独立任务状态
  String? errorMessage;
  String developer;

  BatchGameItem({
    required this.id,
    required this.folderPath,
    required this.gameName,
    this.launchExe,
    this.tags = const [],
    this.description = '',
    this.coverFilePath,
    this.metadata,
    this.isSelected = false,
    this.taskStatus = GameTaskStatus.pending, // 默认待处理
    this.errorMessage,
    this.developer = '',
  });

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

  List<BatchGameItem> get games => _games;
  BatchGameItem? get selectedGame => _selectedGame;
  String? get lastSelectedGameId => _lastSelectedGameId;
  bool get hasGames => _games.isNotEmpty;
  bool get isProcessingQueue => _isProcessingQueue;

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

  double get overallProgress {
    if (_games.isEmpty) return 0;
    final finishedCount = completedCount + failedCount + cancelledCount;
    return finishedCount / _games.length;
  }

  String get batchStatusMessage {
    if (_isProcessingQueue &&
        _currentProcessingIndex >= 0 &&
        _currentProcessingIndex < _games.length) {
      final currentGame = _games[_currentProcessingIndex];
      return '正在处理: ${currentGame.gameName}';
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

  void selectGame(BatchGameItem? game) {
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

    // 清除切换标志——确认操作后不需要重新同步覆盖表单
    _lastSelectedGameId = null;

    notifyListeners();
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

    final newGames = <BatchGameItem>[];

    for (final path in folderPaths) {
      debugPrint('[BATCH] 正在扫描文件夹: $path');
      // 递归扫描所有子目录中的游戏
      final gamesInFolder = await scanFolderForGames(path);
      debugPrint('[BATCH] 扫描结果: 发现 ${gamesInFolder.length} 个游戏');
      newGames.addAll(gamesInFolder);
    }

    debugPrint('[BATCH] 总共发现 ${newGames.length} 个新游戏');

    // 去重：根据folderPath去重
    int addedCount = 0;
    int skippedCount = 0;
    for (final newGame in newGames) {
      if (!_games.any((g) => g.folderPath == newGame.folderPath)) {
        _games.add(newGame);
        addedCount++;
        debugPrint('[BATCH] ✓ 添加游戏: ${newGame.gameName}');
      } else {
        skippedCount++;
        debugPrint('[BATCH] ✗ 跳过重复: ${newGame.gameName} (路径已存在)');
      }
    }

    debugPrint(
        '[BATCH] 新增结果: +$addedCount 个, -$skippedCount 个重复, 总计 ${_games.length} 个游戏');

    if (addedCount > 0) {
      // 标记有新的待处理游戏
      _hasNewPendingGames = true;
      debugPrint('[BATCH] ✓ 已设置 _hasNewPendingGames=true');

      notifyListeners();

      // 触发自动处理（无论当前是否正在处理都能正确响应）
      if (_games.isNotEmpty) {
        debugPrint('[BATCH] 触发自动处理...');
        autoProcessNewGames();
      }
    } else {
      debugPrint('[BATCH] ⚠️ 没有新游戏需要添加');
      if (skippedCount > 0) {
        onError?.call('这些文件夹已经导入过了');
      }
    }
  }

  Future<List<BatchGameItem>> scanFolderForGames(String rootPath) async {
    final foundGames = <BatchGameItem>[];
    final dir = Directory(rootPath);

    if (!dir.existsSync()) return foundGames;

    // 首先检查当前目录是否是游戏
    if (GalGameDetector.isLikelyGalGame(rootPath)) {
      final folderName = rootPath.split('/').last.split('\\').last;
      foundGames.add(BatchGameItem(
        id: DateTime.now().millisecondsSinceEpoch.toString() +
            '_' +
            foundGames.length.toString(),
        folderPath: rootPath,
        gameName: folderName,
      ));
    }

    // 递归扫描子目录
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is Directory) {
          final subDirPath = entity.path;

          // 跳过太深的嵌套（超过4层）
          final depth =
              subDirPath.split('\\').length - rootPath.split('\\').length;
          if (depth > 4) continue;

          // 排除明显的非游戏目录（补丁、存档、配置等）
          final folderName =
              subDirPath.split('/').last.split('\\').last.toLowerCase();
          if (_isNonGameSubfolder(folderName)) {
            continue;
          }

          // 检查是否是游戏目录（且不是已添加的）
          if (GalGameDetector.isLikelyGalGame(subDirPath) &&
              !foundGames.any((g) => g.folderPath == subDirPath)) {
            // 关键验证：必须包含至少一个exe启动程序
            if (!_hasExecutableFile(subDirPath)) {
              debugPrint('[BATCH] ✗ 跳过（无exe文件）: $folderName ($subDirPath)');
              continue;
            }

            // 检查是否与已找到的游戏有相同的启动程序（避免重复）
            if (!_hasSameParentGame(foundGames, subDirPath)) {
              final folderName2 = subDirPath.split('/').last.split('\\').last;
              debugPrint('[BATCH] ✓ 识别到游戏: $folderName2 ($subDirPath)');
              foundGames.add(BatchGameItem(
                id: DateTime.now().millisecondsSinceEpoch.toString() +
                    '_' +
                    foundGames.length.toString(),
                folderPath: subDirPath,
                gameName: folderName2,
              ));
            } else {
              debugPrint('[BATCH] ✗ 跳过（重复游戏）: $folderName ($subDirPath)');
            }
          } else if (!GalGameDetector.isLikelyGalGame(subDirPath)) {
            // 仅在调试时记录未被识别为游戏的目录（减少日志噪音，只记录一级子目录）
            final depth2 =
                subDirPath.split('\\').length - rootPath.split('\\').length;
            if (depth2 <= 1) {
              debugPrint('[BATCH] ⊘ 非游戏目录: $folderName');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[BATCH] 扫描目录异常: $e');
    }

    return foundGames;
  }

  bool _isNonGameSubfolder(String folderName) {
    // 明确排除的目录名称模式
    final excludePatterns = [
      // 系统目录
      'patch',
      'save',
      'saves',
      'config',
      'setting',
      'settings',
      'cache',
      'temp',
      'tmp',
      'log',
      'backup',
      // 游戏资源目录（单独出现时通常不是游戏根目录）
      'sound',
      'bg',
      'cg',
      'graphic',
      'imagefolder',
      // 中文关键词
      '补丁',
      '存档',
      '配置',
      '缓存',
      '备份',
      '更新',
      // 明确的非游戏子目录
      'dlc', // DLC内容
      'addon', // 扩展包
      'demo', // 试玩版
      'trial', // 试用版
      'sdk', // 开发工具包
      'plugin', // 插件
      'launcher', // 启动器
      'updater', // 更新器
      'uninstaller', // 卸载程序
      'install', // 安装程序
      'redist', // 运行时库
      'common', // 公共文件
    ];

    for (final pattern in excludePatterns) {
      if (folderName.contains(pattern)) {
        return true;
      }
    }

    return false;
  }

  // 新增：验证是否真的是独立的游戏目录（而不是某个游戏的子模块）
  bool _isIndependentGame(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return false;

      // 检查1：必须有主启动程序（exe文件）
      final hasExe = _hasMainExecutable(dir);
      if (!hasExe) {
        debugPrint('[BATCH] 排除: $folderPath (无主启动程序)');
        return false;
      }

      // 检查2：必须有典型的GAL游戏特征文件
      final galFeatures = _countGalFeatures(dir);
      if (galFeatures < 2) {
        // 至少需要2个GAL特征才认为是游戏
        debugPrint('[BATCH] 排除: $folderPath (GAL特征不足: $galFeatures)');
        return false;
      }

      // 检查3：目录名不能是过于通用的名称
      final folderName =
          folderPath.split('/').last.split('\\').last.toLowerCase();
      if (_isGenericName(folderName)) {
        debugPrint('[BATCH] 排除: $folderPath (目录名过于通用)');
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  bool _hasMainExecutable(Directory dir) {
    int exeCount = 0;

    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();

          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer') &&
              !name.contains('patch') &&
              !name.contains('update') &&
              !name.contains('config') &&
              !name.contains('tool') &&
              !name.contains('editor')) {
            exeCount++;
            if (exeCount >= 1) return true; // 至少1个有效exe
          }
        }
      }
    } catch (e) {}

    return false;
  }

  int _countGalFeatures(Directory dir) {
    int featureCount = 0;

    final galIndicators = [
      'data.ks',
      'scenario.ks',
      'game.exe',
      'kikyo.exe',
      'nss.npa',
      'arc.nsa',
      'data.xp3',
      'game.dat',
      'script.ks',
      'initial.ks',
      'system.ks',
      'config.ini',
      'config.sys',
      'game.ini',
      'startup.tjs',
      'initialize.tjs',
      'krkr.exe',
      'kirikiri',
      'buriko',
      'monshiro',
      'siglus',
      'malie',
      'musica',
      'ruggie',
      'eagls',
      'cmvs',
      'yuris',
      'fns',
      'agi4',
      'artalk',
      'mages',
      'nitroplus',
      'leaf',
      'cabbage',
      'reallive',
      'willplus',
      'runscript',
      'advhd',
      'bgi',
      'anex86',
      'alice',
      'system40',
      'rpgmaker',
      'tyrano',
      'onscripter',
    ];

    final resourceFolders = [
      'data',
      'sound',
      'bg',
      'cg',
      'graphic',
      'image',
      'movie',
      'music',
      'voice',
      'sav',
      'save',
    ];

    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.path.toLowerCase();

          for (final indicator in galIndicators) {
            if (fileName.contains(indicator)) {
              featureCount++;
              break; // 每个文件只计数一次
            }
          }
        } else if (entity is Directory) {
          final dirName =
              entity.path.split('/').last.split('\\').last.toLowerCase();

          if (resourceFolders.contains(dirName)) {
            featureCount++;
          }
        }
      }
    } catch (e) {}

    return featureCount;
  }

  bool _isGenericName(String folderName) {
    // 过于通用的目录名，不太可能是独立游戏
    final genericNames = [
      'game',
      'games',
      'test',
      'new',
      'project',
      'sample',
      'demo',
      'temp',
      'backup',
      'copy',
      'old',
      'new',
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

    for (final name in genericNames) {
      if (folderName == name) {
        return true;
      }
    }

    return false;
  }

  bool _hasExecutableFile(String folderPath) {
    // 检查目录中是否包含至少一个exe文件（游戏启动程序）
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return false;

      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer') &&
              !name.contains('patch') &&
              !name.contains('update')) {
            return true; // 找到有效的exe文件
          }
        }
      }
    } catch (e) {
      debugPrint('[BATCH] 检查exe文件异常: $e');
    }

    return false;
  }

  bool _hasSameParentGame(List<BatchGameItem> existingGames, String newPath) {
    // 检查新路径是否是某个已存在游戏的子目录，且共享相同的启动程序
    for (final game in existingGames) {
      if (_isSubdirectory(game.folderPath, newPath)) {
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
          final parentDepth = game.folderPath.split('\\').length;
          final childDepth = newPath.split('\\').length;
          final depthDiff = childDepth - parentDepth;

          if (depthDiff <= 1 && parentExeName == childExeName) {
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
    return potentialChild.startsWith(potentialParent + '\\') ||
        potentialChild.startsWith(potentialParent + '/');
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
    );

    _selectedGame = _games[index];
    notifyListeners();
  }

  Future<void> autoProcessNewGames() async {
    if (_games.isEmpty) {
      debugPrint('[BATCH] 队列为空，无需处理');
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
    notifyListeners();

    try {
      // ✨ 新增：外层循环支持多次追加导入
      // 当用户在处理过程中新增游戏时，_hasNewPendingGames会被设置为true
      // 外层循环会检测到这个标志并继续处理新游戏
      int processingRound = 0;

      do {
        processingRound++;
        debugPrint(
            '[BATCH] 📍 开始第 $processingRound 轮处理 (共 ${_games.length} 个游戏)');
        _hasNewPendingGames = false; // 重置新任务标志

        // 内层循环：处理当前列表中的所有待处理游戏
        int i = 0;
        while (i < _games.length) {
          final game = _games[i];

          // 安全检查：如果游戏已被物理删除，跳过
          if (!_games.any((g) => g.id == game.id)) {
            debugPrint('[BATCH] 游戏已不存在，跳过: ${game.gameName}');
            i++;
            continue;
          }

          // 跳过已取消的任务
          if (_cancelledTasks.contains(game.id)) {
            debugPrint('[BATCH] 跳过已取消的任务: ${game.gameName}');
            i++;
            continue;
          }

          // 跳过已完成/失败的任务
          if (game.taskStatus == GameTaskStatus.completed ||
              game.taskStatus == GameTaskStatus.failed) {
            i++;
            continue;
          }

          // 更新当前处理的索引
          _currentProcessingIndex = i;

          // 标记为处理中
          final index = _games.indexWhere((g) => g.id == game.id);
          if (index != -1) {
            _games[index] = _games[index].copyWith(
              taskStatus: GameTaskStatus.processing,
              errorMessage: null,
            );
            notifyListeners();
          }

          try {
            debugPrint(
                '[BATCH] 开始处理 [第${processingRound}轮 | ${i + 1}/${_games.length}]: ${game.gameName}');

            // 步骤1：识别启动程序
            final exe = detectLaunchExe(game.folderPath);
            if (exe != null && index != -1 && index < _games.length) {
              _games[index] = _games[index].copyWith(launchExe: exe);
              notifyListeners();
            }

            // 再次检查是否被取消/删除（在长时间操作后）
            if (!_games.any((g) => g.id == game.id)) {
              debugPrint('[BATCH] 游戏在处理过程中被删除，停止当前任务');
              i++; // 移动到下一个
              continue;
            }
            if (_cancelledTasks.contains(game.id)) {
              debugPrint('[BATCH] 任务在处理过程中被取消: ${game.gameName}');
              i++;
              continue;
            }

            // 步骤2：抓取元数据
            await fetchSingleGameMetadata(index);

            // 重新获取索引（可能在异步操作期间列表发生了变化）
            final currentIndex = _games.indexWhere((g) => g.id == game.id);

            // 步骤3：下载封面图（如果有）
            if (currentIndex != -1 &&
                currentIndex < _games.length &&
                _games[currentIndex].metadata?['cover_url'] != null &&
                !_cancelledTasks.contains(_games[currentIndex].id)) {
              await downloadCoverImage(currentIndex);
            }

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

            final errorIndex = _games.indexWhere((g) => g.id == game.id);
            if (errorIndex != -1 && errorIndex < _games.length) {
              _games[errorIndex] = _games[errorIndex].copyWith(
                taskStatus: GameTaskStatus.failed,
                errorMessage: e.toString(),
              );
            }
            notifyListeners();
          }

          i++; // 移动到下一个游戏
        }

        // 检查这一轮处理期间是否有新游戏被添加
        if (_hasNewPendingGames) {
          debugPrint('[BATCH] 🔄 检测到有新游戏被添加，准备开始下一轮处理...');
          debugPrint('[BATCH] 当前待处理游戏数: $pendingCount');
        } else {
          debugPrint('[BATCH] ✓ 第 $processingRound 轮处理完成，无新游戏');
        }
      } while (_hasNewPendingGames); // 如果有新游戏，继续循环

      // 队列处理完成
      _isProcessingQueue = false;
      _currentProcessingIndex = -1;

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
    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 15);

      final response = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );

      if (response.statusCode == 200 &&
          response.data != null &&
          response.data!.isNotEmpty) {
        final tempDir = Directory.systemTemp;
        final tempFile = File(
            '${tempDir.path}/batch_cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await tempFile.writeAsBytes(response.data!);

        _games[gameIndex] =
            _games[gameIndex].copyWith(coverFilePath: tempFile.path);
      }
    } catch (e) {
      debugPrint('[BATCH] 封面下载失败: $e');
    }
  }

  // 新增：处理单个游戏的元数据抓取
  Future<void> fetchSingleGameMetadata(int gameIndex) async {
    if (gameIndex >= _games.length) return;

    final game = _games[gameIndex];

    // 如果已有元数据，跳过
    if (game.metadata != null && game.metadata!.isNotEmpty) return;

    try {
      debugPrint('[BATCH] 抓取元数据: ${game.gameName}');

      final results = await MetadataFetcher.fetchGame(game.gameName);

      if (results.isNotEmpty) {
        final bestMatch = results.first;

        _games[gameIndex] = _games[gameIndex].copyWith(
          metadata: bestMatch,
          gameName: bestMatch['game_name'] ?? game.gameName,
          tags:
              (bestMatch['tags'] as List?)?.map((t) => t.toString()).toList() ??
                  game.tags,
          description: bestMatch['summary'] ?? game.description,
          developer: bestMatch['developer']?.toString() ?? '',
        );

        notifyListeners();
        debugPrint('[BATCH] ✓ 元数据获取成功: ${_games[gameIndex].gameName}');
      }
    } catch (e) {
      debugPrint('[BATCH] 元数据抓取失败 [${game.gameName}]: $e');
    }

    // 间隔避免请求过快
    await Future.delayed(const Duration(milliseconds: 1000));
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

    // 筛选已完成且未取消的游戏进行入库
    final gamesToImport = _games
        .where((g) =>
            g.taskStatus == GameTaskStatus.completed &&
            !_cancelledTasks.contains(g.id))
        .toList();

    if (gamesToImport.isEmpty) {
      onError?.call('没有已完成的游戏可入库');
      return;
    }

    _isProcessingQueue = true;
    notifyListeners();

    try {
      int successCount = 0;
      int failCount = 0;

      for (int i = 0; i < gamesToImport.length; i++) {
        final game = gamesToImport[i];

        // 再次检查是否被取消
        if (_cancelledTasks.contains(game.id)) continue;

        debugPrint(
            '[BATCH] 入库 [${i + 1}/${gamesToImport.length}]: ${game.gameName}');

        try {
          await importSingleGame(game);
          successCount++;
          debugPrint('[BATCH] ✓ 入库成功: ${game.gameName}');
        } catch (e) {
          failCount++;
          debugPrint('[BATCH] ✗ 入库失败 [${game.gameName}]: $e');
        }

        notifyListeners();
      }

      // 构建详细的成功消息
      String resultMessage;
      if (failCount == 0) {
        resultMessage = '✓ 成功入库 $successCount 个游戏';
      } else if (successCount > 0) {
        resultMessage = '⚠ 入库完成: $successCount 成功, $failCount 失败';
      } else {
        resultMessage = '✗ 入库失败: 所有游戏均未成功';
      }

      // 调用成功回调（显示给用户看的消息）
      onSuccess?.call(resultMessage);

      // 通知外部（刷新库页等）
      onGameAdded?.call();

      // 🎯 关键：入库完成后清空所有数据！
      debugPrint('[BATCH] ========== 入库完成，开始清理 ==========');
      clearAll(); // 这会清空列表、缓存、重置所有状态
      debugPrint('[BATCH] ✓ 批量导入数据已全部清理');
    } catch (e) {
      onError?.call('批量入库异常: $e');
    } finally {
      _isProcessingQueue = false;
      notifyListeners();
    }
  }

  Future<void> importSingleGame(BatchGameItem game) async {
    final safeName =
        game.gameName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

    await GameDataFormat.writeGameDir(
      targetDir: '${LocalGameRegistry.gamesBaseDir}/$safeName',
      title: game.gameName,
      description: game.description,
      tags: game.tags,
      coverFilePath: game.coverFilePath,
      launchPath: game.launchExe ?? '',
      directoryPath: game.folderPath,
      source: 'batch_import',
      developer: game.developer,
    );

    LocalGameRegistry.instance.registerExtractionComplete(
      gameTitle: safeName,
      directoryPath: game.folderPath,
      tags: game.tags,
      launchPath: game.launchExe ?? '',
    );
  }

  void clearAll() {
    // 停止正在处理的队列
    if (_isProcessingQueue) {
      debugPrint('[BATCH] 用户清空了所有任务，停止队列处理');
      _isProcessingQueue = false;
      _currentProcessingIndex = -1;
    }

    // 清理所有临时缓存文件
    _cleanupAllCache();

    // 重置所有状态
    _games.clear();
    _selectedGame = null;
    _cancelledTasks.clear();
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
    super.dispose();
  }
}
