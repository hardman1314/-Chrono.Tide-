import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'game_launcher_detector.dart';
import 'game_data_format.dart';
import 'locale_service.dart';
import 'save_scanner.dart';
import 'save_backup_service.dart';
import '../core/path_helper.dart';

enum GameMark { none, star, favorite }

class LibraryGame {
  String title;
  String directoryPath;
  String metaDataDir;
  String installedAt;
  String coverUrl;
  String description;
  List<String> tags;
  GameMark mark;
  String launchPath;
  String source;
  String developer;

  LibraryGame({
    required this.title,
    required this.directoryPath,
    required this.metaDataDir,
    required this.installedAt,
    this.coverUrl = '',
    this.description = '',
    this.tags = const [],
    this.mark = GameMark.none,
    this.launchPath = '',
    this.source = 'download',
    this.developer = '',
  });

  String get coverPath => coverUrl;

  String get pathForCover =>
      metaDataDir.isNotEmpty ? metaDataDir : directoryPath;
}

class LocalGameRegistry extends ChangeNotifier {
  static final LocalGameRegistry _instance = LocalGameRegistry._internal();
  static LocalGameRegistry get instance => _instance;

  LocalGameRegistry._internal();

  static final String _gamesBaseDir = PathHelper.gamesDir;
  static String get gamesBaseDir => _gamesBaseDir;

  final Map<String, LibraryGame> _games = {};
  final Set<String> _installedTitles = {};

  List<LibraryGame> get allGames {
    final list = _games.values.toList();
    list.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return list;
  }

  int get gameCount => _games.length;

  Map<String, LibraryGame> get gamesMap => Map.unmodifiable(_games);
  Set<String> get installedTitles => Set.unmodifiable(_installedTitles);

  bool isTitleInstalled(String title) {
    if (title.isEmpty) return false;
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (!_installedTitles.contains(safeName)) return false;
    return _verifyDirOnDisk(safeName);
  }

  bool isGameIdInstalled(String gameId) {
    return _games.containsKey(gameId);
  }

  LibraryGame? getGameByTitle(String title) {
    if (title.isEmpty) return null;
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return _games[safeName];
  }

  bool isMarked(String title) {
    final game = getGameByTitle(title);
    return game?.mark != GameMark.none;
  }

  void toggleMark(String title) {
    final game = getGameByTitle(title);
    if (game == null) return;

    final beforeLen = _games.length;
    game.mark = game.mark == GameMark.star ? GameMark.none : GameMark.star;
    final afterLen = _games.length;

    assert(
        beforeLen == afterLen, '[标记] ❌ 严重错误！标记后卡片数量变化: $beforeLen → $afterLen');

    debugPrint(
        '[标记] 已修改原对象: ${game.title}，标记状态: ${game.mark == GameMark.star}');

    _persistMarkToGameJson(game);
  }

  Future<void> _persistMarkToGameJson(LibraryGame game) async {
    try {
      final markStr = game.mark == GameMark.star
          ? 'star'
          : game.mark == GameMark.favorite
              ? 'favorite'
              : 'none';
      await GameDataFormat.updateGameJson(game.metaDataDir, {'mark': markStr});
    } catch (e) {
      debugPrint('[标记] ⚠️ 持久化标记失败: $e');
    }
  }

  bool _verifyDirOnDisk(String dirName) {
    try {
      final dir = Directory('$_gamesBaseDir/$dirName');
      if (!dir.existsSync()) {
        debugPrint('[LOCAL-REGISTRY] ⚠️ 磁盘校验失败: 目录不存在 → $dirName');
        _removeByDirName(dirName);
        return false;
      }

      final ctgameFile = File('${dir.path}/${GameDataFormat.ctgameFileName}');
      final gameJsonFile =
          File('${dir.path}/${GameDataFormat.gameJsonFileName}');
      if (!ctgameFile.existsSync() && !gameJsonFile.existsSync()) {
        debugPrint('[LOCAL-REGISTRY] ⚠️ 磁盘校验失败: 无.ctgame或game.json → $dirName');
        _removeByDirName(dirName);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ 磁盘校验异常: $dirName | $e');
      return false;
    }
  }

  void _removeByDirName(String dirName) {
    final exactMatch = _games.keys.firstWhere(
      (k) => k == dirName,
      orElse: () => '',
    );

    if (exactMatch.isNotEmpty) {
      _games.remove(exactMatch);
      _installedTitles.remove(exactMatch);
      debugPrint('[删除]   ✅ 精确移除: "$exactMatch"');
      notifyListeners();
    } else {
      debugPrint('[删除]   ⚠️ 未找到精确匹配: "$dirName"');
    }
  }

  Future<int> refreshStaleEntries() async {
    int removedCount = 0;
    final staleKeys = <String>[];

    for (final entry in _games.entries.toList()) {
      final dir = Directory(entry.value.directoryPath);
      try {
        if (!await dir.exists()) {
          staleKeys.add(entry.key);
          continue;
        }

        final ctgameFile = File('${dir.path}/${GameDataFormat.ctgameFileName}');
        final gameJsonFile =
            File('${dir.path}/${GameDataFormat.gameJsonFileName}');
        if (!await ctgameFile.exists() && !await gameJsonFile.exists()) {
          staleKeys.add(entry.key);
        }
      } catch (e) {
        staleKeys.add(entry.key);
      }
    }

    for (final key in staleKeys) {
      final game = _games[key];
      _games.remove(key);
      _installedTitles.remove(key);
      removedCount++;
      debugPrint(
          '[LOCAL-REGISTRY] 🗑️ 清除失效条目: ${game?.title ?? key} (磁盘文件已删除)');
    }

    if (removedCount > 0) {
      debugPrint(
          '[LOCAL-REGISTRY] 刷新完成: 清除 $removedCount 个失效条目, 剩余 ${_games.length} 个');
      notifyListeners();
    }
    return removedCount;
  }

  Future<void> scan() async {
    debugPrint('[LOCAL-REGISTRY] ========== 开始智能增量扫描 ==========');
    debugPrint('[LOCAL-REGISTRY] 扫描目标目录: $_gamesBaseDir');
    debugPrint('[LOCAL-REGISTRY] 当前内存中已有: ${_games.length} 个游戏');

    try {
      final gamesDir = Directory(_gamesBaseDir);
      if (!await gamesDir.exists()) {
        debugPrint('[LOCAL-REGISTRY] ❌ 目录不存在: ${PathHelper.gamesDir}');
        try {
          await gamesDir.create(recursive: true);
        } catch (e) {}
        return;
      }

      final entities = await gamesDir.list(followLinks: false).toList();
      int dirCount = entities.where((e) => e is Directory).length;
      int foundCount = 0;
      int updatedCount = 0;
      int skipCount = 0;

      final scannedDirNames = <String>{};

      for (final entity in entities) {
        if (entity is! Directory) continue;

        final dirName = entity.path.split('/').last.split('\\').last;

        if (dirName.contains('_temp_layer_') || dirName.startsWith('.')) {
          skipCount++;
          continue;
        }

        scannedDirNames.add(dirName);

        final hasCtgame =
            await File('${entity.path}/${GameDataFormat.ctgameFileName}')
                .exists();
        final hasGameJson =
            await File('${entity.path}/${GameDataFormat.gameJsonFileName}')
                .exists();

        if (!hasCtgame && !hasGameJson) {
          continue;
        }

        if (_games.containsKey(dirName)) {
          final existingGame = _games[dirName]!;

          final gameData = await GameDataFormat.readGameJson(entity.path);
          if (gameData != null) {
            existingGame.title =
                gameData.title.isNotEmpty ? gameData.title : dirName;
            existingGame.description = gameData.description;
            existingGame.launchPath = gameData.launchPath;
            existingGame.source = gameData.source;
            existingGame.mark = _parseMark(gameData.mark);

            if (gameData.tags.isNotEmpty) {
              existingGame.tags = gameData.tags;
            }

            if (gameData.directoryPath.isNotEmpty) {
              existingGame.directoryPath = gameData.directoryPath;
            }

            final coverFile = GameDataFormat.findCoverFile(entity.path);
            if (coverFile != null) {
              existingGame.coverUrl = coverFile.path;
            }

            updatedCount++;
          }
          foundCount++;
          continue;
        }

        final gameData = await GameDataFormat.readGameJson(entity.path);
        if (gameData != null) {
          final coverFile = GameDataFormat.findCoverFile(entity.path);

          final game = LibraryGame(
            title: gameData.title.isNotEmpty ? gameData.title : dirName,
            directoryPath: gameData.directoryPath.isNotEmpty
                ? gameData.directoryPath
                : entity.path,
            metaDataDir: entity.path,
            installedAt: gameData.installedAt.isNotEmpty
                ? gameData.installedAt
                : DateTime.now().toIso8601String(),
            coverUrl: coverFile?.path ?? '',
            description: gameData.description,
            tags: gameData.tags,
            launchPath: gameData.launchPath,
            mark: _parseMark(gameData.mark),
            source: gameData.source,
          );

          _games[dirName] = game;
          _installedTitles.add(dirName);
          foundCount++;

          debugPrint(
              '[LOCAL-REGISTRY] ✅ 发现新游戏 [$foundCount]: $dirName | "${game.title}" | source=${game.source}');
        }
      }

      final staleKeys =
          _games.keys.where((k) => !scannedDirNames.contains(k)).toList();
      for (final key in staleKeys) {
        final game = _games[key];
        if (game == null) continue;
        final dir = Directory(game.directoryPath);
        if (!await dir.exists()) {
          _games.remove(key);
          _installedTitles.remove(key);
          debugPrint(
              '[LOCAL-REGISTRY] 🗑️ 移除失效游戏: ${game?.title ?? key} (目录不存在)');
        }
      }

      debugPrint('[LOCAL-REGISTRY] ════════════════════════════════');
      debugPrint(
          '[LOCAL-REGISTRY] 扫描完成 | 子目录: $dirCount | 新增: $foundCount | 更新: $updatedCount | 清理失效: ${staleKeys.length} | 当前内存: ${_games.length}');
      debugPrint('[LOCAL-REGISTRY] ════════════════════════════════');
      if (foundCount > 0 || staleKeys.length > 0) {
        notifyListeners();
      }
    } catch (e, stackTrace) {
      debugPrint('[LOCAL-REGISTRY] ❌ 扫描异常: $e');
    }

    debugPrint('[LOCAL-REGISTRY] ========== 智能增量扫描结束 ==========');
  }

  GameMark _parseMark(String markStr) {
    switch (markStr) {
      case 'star':
        return GameMark.star;
      case 'favorite':
        return GameMark.favorite;
      default:
        return GameMark.none;
    }
  }

  void registerExtractionComplete({
    required String gameTitle,
    required String directoryPath,
    String? coverUrl,
    String? description,
    List<String>? tags,
    String? launchPath,
    String? developer,
  }) {
    final safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final metaDataDir = '${LocalGameRegistry.gamesBaseDir}/$safeName';

    if (coverUrl == null || coverUrl.isEmpty) {
      final detectedCover = GameDataFormat.findCoverFile(directoryPath);
      if (detectedCover != null) {
        coverUrl = detectedCover.path;
        debugPrint('[LOCAL-REGISTRY] 自动检测到封面: $coverUrl');
      }
    }

    if (_games.containsKey(safeName)) {
      debugPrint('[LOCAL-REGISTRY] 📝 游戏已存在于库中，原地更新信息: $gameTitle');
      final existing = _games[safeName]!;
      existing.title = gameTitle;
      existing.directoryPath = directoryPath;
      existing.metaDataDir = metaDataDir;
      existing.installedAt = DateTime.now().toIso8601String();
      if (coverUrl != null) existing.coverUrl = coverUrl;
      if (description != null) existing.description = description;
      if (tags != null) existing.tags = tags;
      if (launchPath != null && launchPath!.isNotEmpty) {
        existing.launchPath = launchPath!;
      }
      if (developer != null) existing.developer = developer!;
    } else {
      final game = LibraryGame(
        title: gameTitle,
        directoryPath: directoryPath,
        metaDataDir: metaDataDir,
        installedAt: DateTime.now().toIso8601String(),
        coverUrl: coverUrl ?? '',
        description: description ?? '',
        tags: tags ?? [],
        launchPath: launchPath ?? '',
        developer: developer ?? '',
      );
      _games[safeName] = game;
      _installedTitles.add(safeName);
      debugPrint(
          '[LOCAL-REGISTRY] 📝 注册新安装游戏到本地库: $gameTitle → $directoryPath');
    }
    notifyListeners();
  }

  Future<void> updateLauncherPath(String title, String newLaunchPath) async {
    final game = getGameByTitle(title);
    if (game != null) {
      final relativePath =
          GameDataFormat.resolveLaunchPath(newLaunchPath, game.directoryPath) !=
                  newLaunchPath
              ? _toRelative(newLaunchPath, game.metaDataDir)
              : newLaunchPath;

      game.launchPath = relativePath.isNotEmpty ? relativePath : newLaunchPath;

      await GameDataFormat.updateGameJson(
          game.metaDataDir, {'launch_path': game.launchPath});
      debugPrint('[LOCAL-REGISTRY] ✅ 已更新启动路径: $title → ${game.launchPath}');
    } else {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新启动路径失败: 未找到游戏 $title');
    }
  }

  Future<void> updateGameLocation({
    required String gameTitle,
    required String newDirectoryPath,
  }) async {
    final game = getGameByTitle(gameTitle);
    if (game != null) {
      final oldDirectoryPath = game.directoryPath;

      game.directoryPath = newDirectoryPath;

      await GameDataFormat.updateGameJson(
        game.metaDataDir,
        {'directory_path': newDirectoryPath},
      );

      debugPrint('[LOCAL-REGISTRY] ✅ 已更新游戏位置: $gameTitle');
      debugPrint('[LOCAL-REGISTRY]   旧位置: $oldDirectoryPath');
      debugPrint('[LOCAL-REGISTRY]   新位置: $newDirectoryPath');
    } else {
      debugPrint('[LOCAL-REGISTRY] ⚠️ 更新游戏位置失败: 未找到游戏 $gameTitle');
    }
  }

  String _toRelative(String absoluteOrRelativePath, String baseDir) {
    if (absoluteOrRelativePath.isEmpty) return '';
    var normalized = absoluteOrRelativePath.replaceAll('/', '\\');
    var normalizedBase = baseDir.replaceAll('/', '\\');
    if (!normalizedBase.endsWith('\\')) {
      normalizedBase += '\\';
    }
    if (normalized.toLowerCase().startsWith(normalizedBase.toLowerCase())) {
      return normalized.substring(normalizedBase.length);
    }
    if (!normalized.contains('\\') && !normalized.contains('/')) {
      return normalized;
    }
    return absoluteOrRelativePath;
  }

  Future<bool> deleteGame(String title) async {
    final game = getGameByTitle(title);
    if (game == null) {
      debugPrint('[删除] ⚠️ 删除失败: 未找到游戏 | $title');
      return false;
    }

    final dirName = game.directoryPath.split('/').last.split('\\').last;
    final beforeLen = _games.length;
    final beforeTitlesLen = _installedTitles.length;

    debugPrint(
        '[删除] 开始彻底删除游戏: ${game.title} | 本体目录: $dirName | 元数据: ${game.metaDataDir}');

    try {
      final bodyDir = Directory(game.directoryPath);
      if (await bodyDir.exists()) {
        try {
          await bodyDir.delete(recursive: true);
          debugPrint('[删除]   ✅ 已删除游戏本体: ${game.directoryPath}');
        } catch (e) {
          debugPrint('[删除]   ⚠️ 删除本体失败(可能已被手动删除): $e');
        }
      }

      final metaDir = Directory(game.metaDataDir);
      if (await metaDir.exists()) {
        try {
          await metaDir.delete(recursive: true);
          debugPrint('[删除]   ✅ 已删除元数据目录: ${game.metaDataDir}');
        } catch (e) {
          debugPrint('[删除]   ⚠️ 删除元数据失败: $e');

          try {
            final ctgameFile =
                File('${game.metaDataDir}/${GameDataFormat.ctgameFileName}');
            if (await ctgameFile.exists()) {
              await ctgameFile.delete();
            }

            final gameJsonFile =
                File('${game.metaDataDir}/${GameDataFormat.gameJsonFileName}');
            if (await gameJsonFile.exists()) {
              await gameJsonFile.delete();
            }

            final entries = await metaDir.list().toList();
            if (entries.isEmpty) {
              await metaDir.delete();
            }
            debugPrint('[删除]   ✅ 已清理元数据残留文件');
          } catch (e2) {
            debugPrint('[删除]   ⚠️ 清理残留失败: $e2');
          }
        }
      }

      _removeByDirName(dirName);

      final afterLen = _games.length;
      final afterTitlesLen = _installedTitles.length;

      debugPrint(
          '[删除] ✅ 彻底删除完成: ${game.title} | 库: $beforeLen→$afterLen | 已安装列表: $beforeTitlesLen→$afterTitlesLen');
      return true;
    } catch (e) {
      debugPrint('[删除] ❌ 删除过程异常: $e');
      return false;
    }
  }

  Future<bool> removeGameRecordOnly(String title) async {
    final game = getGameByTitle(title);
    if (game == null) {
      debugPrint('[删除] ⚠️ 移除记录失败: 未找到游戏 | $title');
      return false;
    }

    final dirPath = game.metaDataDir;
    final dirName = dirPath.split('/').last.split('\\').last;

    debugPrint('[删除] ========== 开始彻底移除游戏数据记录(保留游戏本体) ==========');
    debugPrint('[删除] 游戏标题: ${game.title}');
    debugPrint('[删除] 元数据目录: $dirPath');

    try {
      _removeByDirName(dirName);

      try {
        final ctgameFile = File('$dirPath/${GameDataFormat.ctgameFileName}');
        if (await ctgameFile.exists()) {
          await ctgameFile.delete();
          debugPrint('[删除]   ✅ 已删除: .ctgame');
        }

        final gameJsonFile =
            File('$dirPath/${GameDataFormat.gameJsonFileName}');
        if (await gameJsonFile.exists()) {
          await gameJsonFile.delete();
          debugPrint('[删除]   ✅ 已删除: game.json');
        }

        final coverFile = GameDataFormat.findCoverFile(dirPath);
        if (coverFile != null && await coverFile.exists()) {
          await coverFile.delete();
          debugPrint('[删除]   ✅ 已删除封面: ${coverFile.path.split('\\').last}');
        }
      } catch (fileErr) {
        debugPrint('[删除]   ⚠️ 清理本地数据文件时部分失败（可忽略）: $fileErr');
      }

      final afterLen = _games.length;
      debugPrint('[删除] ✅✅✅ 游戏数据记录已彻底移除！');
      debugPrint('[删除]   游戏名: ${game.title}');
      debugPrint('[删除]   当前库容量: $afterLen');
      debugPrint('[删除]   游戏本体文件夹已保留: ${game.directoryPath}');
      debugPrint('[删除] ======================================================');

      return true;
    } catch (e) {
      debugPrint('[删除] ❌ 移除记录失败: ${game.directoryPath} | $e');
      return false;
    }
  }

  static Future<String?> detectLaunchExe(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return null;

    try {
      final exeFiles = <File>[];
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer')) {
            exeFiles.add(entity);
          }
        }
      }

      if (exeFiles.isEmpty) return null;

      final chinesePattern = RegExp(r'[\u4e00-\u9fa5]');
      final chineseFiles =
          exeFiles.where((f) => chinesePattern.hasMatch(f.path)).toList();
      if (chineseFiles.isNotEmpty) {
        debugPrint(
            '[LOCAL-REGISTRY] 🔍 检测到汉化可执行文件: ${chineseFiles.first.path}');
        return chineseFiles.first.path;
      }

      final mainFiles = exeFiles.where((f) {
        final lower = f.path.toLowerCase();
        return !lower.contains('patch') &&
            !lower.contains('crack') &&
            !lower.contains('fix');
      }).toList();
      if (mainFiles.isNotEmpty) {
        mainFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
        debugPrint(
            '[LOCAL-REGISTRY] 🔍 检测到原版可执行文件(最大体积): ${mainFiles.first.path}');
        return mainFiles.first.path;
      }

      exeFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      debugPrint('[LOCAL-REGISTRY] 🔍 兜底选择最大体积exe: ${exeFiles.first.path}');
      return exeFiles.first.path;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ detectLaunchExe异常: $e');
      return null;
    }
  }

  Future<String?> findExecutable(String title) async {
    final game = getGameByTitle(title);
    if (game == null) return null;

    final dir = Directory(game.directoryPath);
    if (!await dir.exists()) return null;

    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer')) {
            debugPrint('[LOCAL-REGISTRY] 🔍 找到可执行文件: ${entity.path}');
            return entity.path;
          }
        }
      }
      debugPrint('[LOCAL-REGISTRY] ⚠️ 未找到可执行文件: ${game.title}');
      return null;
    } catch (e) {
      debugPrint('[LOCAL-REGISTRY] ❌ 搜索可执行文件异常: $e');
      return null;
    }
  }

  final Map<String, DateTime> _activeGameSessions = {};
  Timer? _playTimeMonitor;
  static const int _monitorIntervalSec = 30;

  Future<bool> launchGame(String title,
      {String? forceExePath, String localeMode = 'none'}) async {
    final game = getGameByTitle(title);
    if (game == null) {
      print('[LOCAL-REGISTRY] ❌ 无法启动游戏: 未找到游戏记录');
      return false;
    }

    if (localeMode == 'none') {
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null && data.localeMode.isNotEmpty) {
          localeMode = data.localeMode;
          print('[LOCAL-REGISTRY] 🌸 从 game.json 读取转区模式: $localeMode');
        }
      } catch (_) {}
    }

    String? exePath;

    print('');
    print('[LOCAL-REGISTRY] ════════════════════════════');
    print('[LOCAL-REGISTRY] 🎮 准备启动游戏: ${game.title}');
    if (forceExePath != null) {
      print('[LOCAL-REGISTRY] 🔒 强制使用用户指定的exe路径(绕过所有检测)');
      print('[LOCAL-REGISTRY]   强制路径: $forceExePath');
    }
    print('[LOCAL-REGISTRY] ════════════════════════════');

    if (forceExePath != null && forceExePath.isNotEmpty) {
      final forceFile = File(forceExePath);
      if (await forceFile.exists()) {
        exePath = forceExePath;
        print('[LOCAL-REGISTRY] ✅ 强制路径文件存在，直接使用: $exePath');

        final relativePath = _toRelative(exePath, game.metaDataDir);
        game.launchPath = relativePath;
        await GameDataFormat.updateGameJson(
            game.metaDataDir, {'launch_path': relativePath});
      } else {
        print('[LOCAL-REGISTRY] ❌ 强制路径文件不存在! $forceExePath');
        print('[LOCAL-REGISTRY]   回退到标准启动流程...');
      }
    }

    if (exePath == null) {
      if (game.launchPath.isNotEmpty) {
        final resolvedPath = GameDataFormat.resolveLaunchPath(
            game.launchPath, game.directoryPath);

        print('[LOCAL-REGISTRY] 📂 检查已记录的启动路径...');
        print('[LOCAL-REGISTRY]   相对路径: ${game.launchPath}');
        print('[LOCAL-REGISTRY]   解析路径: $resolvedPath');

        final launchFile = File(resolvedPath);
        if (await launchFile.exists()) {
          exePath = resolvedPath;
          print('[LOCAL-REGISTRY] ✅ 文件存在，直接使用: $exePath');
        } else {
          print('[LOCAL-REGISTRY] ⚠️ 文件不存在，触发重新扫描...');
        }
      } else {
        print('[LOCAL-REGISTRY] ℹ️ 无已记录的启动路径，执行自动识别...');
      }

      if (exePath == null) {
        print('[LOCAL-REGISTRY] 🔍 调用智能识别器扫描目录...');

        final detection = await GameLauncherDetector.detect(game.directoryPath);

        if (detection.success && detection.launcherPath != null) {
          exePath = detection.launcherPath!;

          print('[LOCAL-REGISTRY] ✅ 识别成功，更新启动路径...');
          print('[LOCAL-REGISTRY]   新路径: $exePath');

          final relativePath = _toRelative(exePath, game.metaDataDir);
          game.launchPath = relativePath;

          await GameDataFormat.updateGameJson(
              game.metaDataDir, {'launch_path': relativePath});

          print('[LOCAL-REGISTRY] ✅ 已更新 game.json');
        } else {
          print('[LOCAL-REGISTRY] ❌ 自动识别失败，无法确定启动文件');
        }
      }
    }

    if (exePath == null) {
      print('[LOCAL-REGISTRY] ❌ 无法启动游戏: 未找到可执行的EXE | ${game.title}');
      print('[LOCAL-REGISTRY] ════════════════════════════');
      print('');
      return false;
    }

    try {
      print('[LOCAL-REGISTRY] 🚀 执行启动命令...');
      print('[LOCAL-REGISTRY]   EXE路径: $exePath');
      print('[LOCAL-REGISTRY]   转区模式: $localeMode');

      final exeFile = File(exePath);
      final workDir = exeFile.parent.path;
      final exeName = p.basename(exePath);

      print('[LOCAL-REGISTRY]   工作目录: $workDir');
      print('[LOCAL-REGISTRY]   启动程序: $exeName');

      if (localeMode == 'japanese') {
        final leAvailable = await LocaleService.isLocaleAvailable();
        if (leAvailable) {
          print('[LOCAL-REGISTRY] 🌸 使用 Locale Emulator 转区启动...');
          await LocaleService.launchWithLocale(exePath, workingDir: workDir);
        } else {
          print('[LOCAL-REGISTRY] ⚠️ LE 不可用，回退到普通启动...');
          await Process.start(
            exePath,
            [],
            workingDirectory: workDir,
            mode: ProcessStartMode.detachedWithStdio,
          );
        }
      } else {
        await Process.start(
          exePath,
          [],
          workingDirectory: workDir,
          mode: ProcessStartMode.detachedWithStdio,
        );
      }

      _activeGameSessions[game.directoryPath] = DateTime.now();
      _ensurePlayTimeMonitor();

      print('[LOCAL-REGISTRY] ✅ 游戏进程已成功启动!');
      print('[LOCAL-REGISTRY]   游戏: ${game.title}');
      print('[LOCAL-REGISTRY] ════════════════════════════');
      print('');

      return true;
    } catch (e) {
      print('[LOCAL-REGISTRY] ❌ 启动失败: $e');
      print('[LOCAL-REGISTRY]   EXE路径: $exePath');
      print('[LOCAL-REGISTRY] ════════════════════════════');
      print('');

      return false;
    }
  }

  void _ensurePlayTimeMonitor() {
    if (_playTimeMonitor != null && _playTimeMonitor!.isActive) return;
    _playTimeMonitor = Timer.periodic(
      Duration(seconds: _monitorIntervalSec),
      (_) => _checkActiveSessions(),
    );
  }

  Future<void> _checkActiveSessions() async {
    if (_activeGameSessions.isEmpty) {
      _playTimeMonitor?.cancel();
      _playTimeMonitor = null;
      return;
    }

    final completedSessions = <String>[];

    for (final entry in _activeGameSessions.entries) {
      final dirPath = entry.key;
      final startTime = entry.value;

      final data = await GameDataFormat.readGameJson(dirPath);
      if (data == null) {
        completedSessions.add(dirPath);
        continue;
      }

      final exePath =
          GameDataFormat.resolveLaunchPath(data.launchPath, dirPath);
      final exeName = p.basename(exePath).toLowerCase();

      bool isRunning = false;
      try {
        final result = await Process.run(
          'tasklist',
          ['/FI', 'IMAGENAME eq $exeName', '/NH'],
          runInShell: true,
        );
        final output = result.stdout.toString().toLowerCase();
        isRunning = output.contains(exeName);
      } catch (_) {}

      if (!isRunning) {
        final elapsed = DateTime.now().difference(startTime).inSeconds;
        if (elapsed > 5) {
          await GameDataFormat.addPlayTime(dirPath, elapsed);
          debugPrint(
              '[PLAYTIME] ${data.title} 本次游玩 ${GameDataFormat.formatPlayTime(elapsed)}');

          // 自动备份：游玩超过15分钟退出时自动备份存档
          if (elapsed >= 900) {
            _triggerAutoBackup(data.title, dirPath);
          }
        }
        completedSessions.add(dirPath);
      }
    }

    for (final dirPath in completedSessions) {
      _activeGameSessions.remove(dirPath);
    }
  }

  /// 自动备份：游戏退出后自动扫描并备份存档
  Future<void> _triggerAutoBackup(String gameTitle, String gameDir) async {
    try {
      debugPrint('[AUTO-BACKUP] 🔄 开始自动备份: $gameTitle');
      final scanner = SaveScanner();
      final detected = scanner.scanGameSaves(gameTitle, gameDir);
      if (detected.isEmpty) {
        debugPrint('[AUTO-BACKUP] ℹ️ 未检测到存档文件，跳过备份');
        return;
      }
      final savePaths = detected.map((f) => f.filePath).toList();
      final backup = await SaveBackupService.instance.autoBackup(
        gameTitle,
        savePaths,
      );
      debugPrint(
          '[AUTO-BACKUP] ✅ 自动备份完成: ${backup.name} (${backup.fileCount}个文件)');
    } catch (e) {
      debugPrint('[AUTO-BACKUP] ❌ 自动备份失败: $e');
    }
  }

  void unregisterGame(String title) {
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    _removeByDirName(safeName);
    debugPrint('[LOCAL-REGISTRY] 🗑️ 移除注册: $title');
  }
}
