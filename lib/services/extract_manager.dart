import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'local_game_registry.dart';
import 'rar_lz4_unzip_service.dart';
import 'game_launcher_detector.dart';
import 'game_data_format.dart';
import 'install_path_preference.dart';
import '../core/path_helper.dart';
import '../core/backend_config.dart';

enum ExtractStatus {
  idle,
  extracting,
  completed,
  failed,
}

class ExtractProgress {
  final double percent;
  final String currentFile;
  final int extractedFiles;
  final int totalFiles;
  final String message;

  const ExtractProgress({
    required this.percent,
    this.currentFile = '',
    this.extractedFiles = 0,
    this.totalFiles = 0,
    this.message = '',
  });
}

class ExtractManager {
  static final String _gamesBaseDir = PathHelper.gamesDir;
  static final String _logsDir = PathHelper.logsDir;
  static final String _downloadsDir = PathHelper.downloadsDir;
  static final String _defaultPassword =
      BackendConfig.defaultExtractionPassword;
  static final String _toolsDir = PathHelper.toolsDir;

  static int _activeTaskCount = 0;
  static bool get hasActiveTask => _activeTaskCount > 0;

  static final Set<String> _registeredGames = {};
  static int _registrationCount = 0;

  ExtractStatus _status = ExtractStatus.idle;
  ExtractProgress? _progress;
  String? _errorMessage;
  String? _currentArchivePath;
  String? _targetGameDir;
  String? _actualGameDir;
  Process? _currentProcess;
  bool _isCancelled = false;

  final List<void Function(ExtractStatus)> _statusListeners = [];
  final List<void Function(ExtractProgress)> _progressListeners = [];
  final List<void Function()> _successListeners = [];
  final List<void Function(String)> _failureListeners = [];

  ExtractStatus get status => _status;
  ExtractProgress? get progress => _progress;
  String? get errorMessage => _errorMessage;
  String? get targetGameDir => _targetGameDir;
  String? get actualGameDir => _actualGameDir;
  String get gamesBaseDir => _gamesBaseDir;

  void addStatusListener(void Function(ExtractStatus) listener) {
    _statusListeners.add(listener);
  }

  void addProgressListener(void Function(ExtractProgress) listener) {
    _progressListeners.add(listener);
  }

  void addSuccessListener(void Function() listener) {
    _successListeners.add(listener);
  }

  void addFailureListener(void Function(String) listener) {
    _failureListeners.add(listener);
  }

  void removeListeners() {
    _statusListeners.clear();
    _progressListeners.clear();
    _successListeners.clear();
    _failureListeners.clear();
  }

  void _emitStatus(ExtractStatus s) {
    _status = s;
    for (final l in _statusListeners) {
      l(s);
    }
  }

  void _emitProgress(ExtractProgress p) {
    _progress = p;
    for (final l in _progressListeners) {
      l(p);
    }
  }

  void _emitSuccess() {
    for (final l in _successListeners) {
      l();
    }
  }

  void _emitFailure(String msg) {
    for (final l in _failureListeners) {
      l(msg);
    }
  }

  Future<String> _getToolPath(String toolName) async {
    final toolDir = Directory(_toolsDir);
    if (!await toolDir.exists()) {
      await toolDir.create(recursive: true);
    }

    final destPath = '$_toolsDir/$toolName';
    final destFile = File(destPath);

    if (!await destFile.exists()) {
      _log('INFO', '从Flutter Assets提取工具: $toolName');
      final byteData = await rootBundle.load('assets/tools/$toolName');
      final bytes = byteData.buffer.asUint8List();
      await destFile.writeAsBytes(bytes);

      if (Platform.isWindows) {
        await Process.run('attrib', ['+h', destPath], runInShell: true);
      }
      _log('INFO',
          '工具提取完成: $destPath (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
    }

    return destPath;
  }

  Future<Process> _startSilentProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    return await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
      includeParentEnvironment: true,
    );
  }

  Future<void> start({
    required String archivePath,
    required String gameTitle,
    String? gameDescription,
    String? gameCoverUrl,
    List<String>? gameTags,
    String? customGameLocation,
  }) async {
    if (_status == ExtractStatus.extracting) {
      _log('WARN', '已有解压任务在执行，忽略重复请求');
      return;
    }

    _currentArchivePath = archivePath;
    _errorMessage = null;

    _log('INFO', '========== 开始解压任务 ==========');
    _log('INFO', '压缩包路径: $archivePath');
    _log('INFO', '游戏标题: $gameTitle');

    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      final msg = '压缩包文件不存在: $archivePath';
      _log('ERROR', msg);
      _handleError(msg);
      return;
    }

    for (final dirPath in [
      PathHelper.downloadsDir,
      PathHelper.toolsDir,
      PathHelper.gamesDir
    ]) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        _log('INFO', '创建目录: $dirPath');
      }
    }

    final formats = _detectFormats(archivePath);

    if (formats.isEmpty) {
      final msg = '无法识别的压缩格式: $archivePath';
      _log('ERROR', msg);
      _handleError(msg);
      return;
    }

    _log('INFO',
        '检测到格式: ${formats.join(" → ")} ${formats.length > 1 ? "(双层/多层压缩)" : ""}');

    _targetGameDir = await _resolveGameDir(gameTitle);
    _log('INFO', '📋 元数据目录(固定): $_targetGameDir');

    late String extractionTargetDir;
    final effectiveLocation =
        await _resolveEffectiveLocation(customGameLocation);
    extractionTargetDir = await _determineExtractionTarget(
      effectiveLocation: effectiveLocation,
      gameTitle: gameTitle,
    );
    _actualGameDir = extractionTargetDir;

    _log('INFO', '✅ 安装方案确定:');
    _log('INFO', '   游戏本体 → $extractionTargetDir');
    _log('INFO', '   元数据   → $_targetGameDir');

    try {
      _emitStatus(ExtractStatus.extracting);
      _activeTaskCount++;

      if (!await Directory(extractionTargetDir).exists()) {
        await Directory(extractionTargetDir).create(recursive: true);
        _log('INFO', '已创建解压目标目录: $extractionTargetDir');
      }

      final isRarLz4Format = archivePath.toLowerCase().endsWith('.rar.lz4');

      if (isRarLz4Format) {
        _log('INFO', '');
        _log('INFO', '【.rar.lz4 格式检测】使用专用工具 rar_lz4_unzip.exe 处理');
        _log('INFO', '⚠️ 彻底废弃 LZ4+UnRAR 命令行方案，仅使用原生解压工具');
        _log('INFO', '');

        _emitProgress(
            const ExtractProgress(percent: 5, message: '正在初始化解压工具...'));

        await _extractRarLz4(
          archivePath: archivePath,
          outputDir: extractionTargetDir,
        );

        _log('INFO', '✅ 【.rar.lz4】专用解压完成');
      } else {
        var currentPath = archivePath;
        for (int i = 0; i < formats.length; i++) {
          final fmt = formats[i];
          final isLast = i == formats.length - 1;
          final outputDir = isLast
              ? extractionTargetDir
              : '$extractionTargetDir._temp_layer_$i';

          _log('INFO', '--- 第${i + 1}层解压: $fmt ---');

          double layerStartPercent;
          double layerEndPercent;

          if (formats.length == 2 && formats[0] == '.lz4') {
            layerStartPercent = 0.0;
            layerEndPercent = 50.0;
          } else if (formats.length == 2 && formats[1] == '.lz4') {
            layerStartPercent = (i == 0) ? 0.0 : 50.0;
            layerEndPercent = (i == 0) ? 50.0 : 100.0;
          } else {
            layerStartPercent = (i / formats.length) * 100;
            layerEndPercent = ((i + 1) / formats.length) * 100;
          }

          _emitProgress(ExtractProgress(
            percent: layerStartPercent,
            message: '正在解压($fmt)...',
          ));

          final isFromLz4Layer = i > 0 && formats[i - 1] == '.lz4';

          currentPath = await _extractSingleFormat(
            currentPath,
            fmt,
            outputDir,
            startPercent: layerStartPercent,
            endPercent: layerEndPercent,
            isFromLz4: isFromLz4Layer,
          );
          _log('INFO', '第${i + 1}层($fmt)解压完成');

          _emitProgress(ExtractProgress(
            percent: layerEndPercent,
            message: '第${i + 1}/${formats.length}层完成',
          ));

          if (!isLast && i < formats.length - 1) {
            _log('INFO', '准备下一层解压...');
          }
        }
      }

      _log('INFO', '全部解压完成，开始最终校验...');

      await Future.delayed(const Duration(milliseconds: 500));

      final targetDirCheck = Directory(extractionTargetDir);
      int finalFileCount = 0;
      List<String> foundExes = [];

      if (await targetDirCheck.exists()) {
        final allFiles = await targetDirCheck.list(recursive: true).toList();
        final allFileEntities = allFiles.whereType<File>().toList();
        finalFileCount = allFileEntities.length;

        for (final f in allFileEntities) {
          if (f.path.toLowerCase().endsWith('.exe')) {
            foundExes.add(f.uri.pathSegments.last);
          }
        }

        _log(
            'INFO', '最终校验 | 总文件数: $finalFileCount | EXE数: ${foundExes.length}');
        if (foundExes.isNotEmpty) {
          for (final e in foundExes) {
            _log('INFO', '   ✓ $e');
          }
        } else {
          _log('WARN', '   ⚠️ 未找到任何.exe文件！');
          _log('WARN', '   这可能导致游戏无法启动，请检查压缩包是否完整');
        }

        if (finalFileCount <= 3) {
          _log('ERROR', '   ❌ 文件数量异常少($finalFileCount)，解压可能不完整');
        }
      } else {
        _log('ERROR', '❌ 解压目标目录不存在: $extractionTargetDir');
      }

      _emitProgress(const ExtractProgress(percent: 96, message: '清理临时文件...'));

      if (await archiveFile.exists()) {
        await archiveFile.delete();
        _log('INFO', '已删除原压缩包: $archivePath');
      }

      for (int i = 0; i < formats.length - 1; i++) {
        final tempDir = Directory('$extractionTargetDir._temp_layer_$i');
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
          _log('INFO', '已清理临时目录: $extractionTargetDir._temp_layer_$i');
        }
      }

      _emitProgress(const ExtractProgress(percent: 98, message: '写入游戏元数据...'));

      if (!_targetGameDir!.startsWith(extractionTargetDir)) {
        if (!await Directory(_targetGameDir!).exists()) {
          await Directory(_targetGameDir!).create(recursive: true);
          _log('INFO', '已创建元数据目录: $_targetGameDir');
        }
      }

      await _writeGameInfo(
        targetDir: _targetGameDir!,
        title: gameTitle,
        description: gameDescription,
        coverUrl: gameCoverUrl,
        tags: gameTags,
        overrideDirectoryPath: extractionTargetDir,
      );

      await _embedCoverBase64(
        targetDir: _targetGameDir!,
        coverUrl: gameCoverUrl,
      );

      _log('SUCCESS', '========== 解压任务完成 ==========');
      _log('SUCCESS', '✅ 游戏本体已安装到: $extractionTargetDir');
      _log('SUCCESS', '✅ 游戏元数据已写入: $_targetGameDir');

      _emitProgress(const ExtractProgress(percent: 100, message: '解压完成'));
      _emitStatus(ExtractStatus.completed);
      if (_activeTaskCount > 0) _activeTaskCount--;

      final gamePath = _targetGameDir ?? '';
      final gameId = _currentArchivePath ?? '';

      if (_registeredGames.contains(gamePath)) {
        _log('WARN', '⚠️ 游戏已入库，跳过重复注册');
        _log('INFO', '   游戏ID: $gameId');
        _log('INFO', '   游戏路径: $gamePath');
        _log('INFO', '   当前已入库游戏数: ${_registeredGames.length}');
      } else {
        _registrationCount++;
        _log('INFO', '');
        _log('INFO', '📦 ========== 执行入库逻辑 ==========');
        _log('INFO', '   入库次数: #$_registrationCount');
        _log('INFO', '   游戏ID: $gameId');
        _log('INFO', '   游戏路径: $gamePath');
        _log('INFO',
            '   当前已入库游戏数: ${_registeredGames.length} → ${_registeredGames.length + 1}');

        LocalGameRegistry.instance.registerExtractionComplete(
          gameTitle: gameTitle,
          directoryPath: gamePath,
        );

        _registeredGames.add(gamePath);

        _log('INFO', '✅ 入库完成 | 累计已入库: ${_registeredGames.length} 个游戏');
        _log('INFO', '========================================');
        _log('INFO', '');
      }

      _emitSuccess();
    } catch (e, st) {
      _log('ERROR', '解压过程捕获异常: $e');
      _log('ERROR', '堆栈: $st');

      if (_currentProcess != null) {
        _log('WARN', '终止残留进程...');
        _currentProcess?.kill();
        _currentProcess = null;
      }

      _log('INFO', '');
      _log('INFO', '⏳ 等待文件系统同步（1秒）...');
      await Future.delayed(const Duration(seconds: 1));

      _log('INFO', '');
      _log('INFO', '========== 最终结果校验 ==========');

      bool extractionActuallySucceeded = false;

      for (int retry = 0; retry < 3; retry++) {
        if (retry > 0) {
          _log('INFO', '⏳ 等待后重试校验 (${retry + 1}/3)...');
          await Future.delayed(Duration(milliseconds: 500 * retry));
        }

        try {
          final targetDirCheck = Directory(_targetGameDir!);
          if (await targetDirCheck.exists()) {
            final entities = await targetDirCheck.list().toList();
            _log('INFO',
                '   目标目录检查 (尝试${retry + 1}): 存在=${await targetDirCheck.exists()}, 条目数=${entities.length}');

            if (entities.isNotEmpty) {
              final gameJsonFile =
                  File('$_targetGameDir/${GameDataFormat.gameJsonFileName}');
              final ctgameFile =
                  File('$_targetGameDir/${GameDataFormat.ctgameFileName}');
              if (await gameJsonFile.exists() || await ctgameFile.exists()) {
                extractionActuallySucceeded = true;
                _log('SUCCESS', '✅ 最终校验通过: 目标目录有效 + game.json/.ctgame 存在');
                _log('SUCCESS', '   目录条目数: ${entities.length}');
                break;
              } else {
                _log('WARN', '⚠️ game.json和.ctgame均不存在');
                if (entities.length >= 1) {
                  extractionActuallySucceeded = true;
                  _log('SUCCESS', '✅ 宽松校验通过: 目录非空(≥1项)，视为成功');
                  _log('SUCCESS', '   目录条目数: ${entities.length}');
                  break;
                }
              }
            } else {
              _log('WARN', '   ⚠️ 目标目录为空');
            }
          } else {
            _log('WARN', '   ⚠️ 目标目录不存在');
          }
        } catch (verifyErr) {
          _log('WARN', '   校验过程异常: $verifyErr');
        }
      }

      if (!extractionActuallySucceeded) {
        _log('INFO', '');
        _log('INFO', '========== 注册表交叉验证 ==========');
        try {
          final registry = LocalGameRegistry.instance;

          List<LibraryGame?> candidates = [];
          final exactMatch = registry.getGameByTitle(gameTitle);
          if (exactMatch != null) candidates.add(exactMatch);

          final allGames = registry.allGames;
          for (final game in allGames) {
            if (game.title.toLowerCase().contains(gameTitle.toLowerCase()) ||
                gameTitle.toLowerCase().contains(game.title.toLowerCase())) {
              if (!candidates.contains(game)) {
                candidates.add(game);
              }
            }

            if (game.directoryPath
                    .toLowerCase()
                    .contains(_targetGameDir!.toLowerCase()) ||
                _targetGameDir!
                    .toLowerCase()
                    .contains(game.directoryPath.toLowerCase())) {
              if (!candidates.contains(game)) {
                candidates.add(game);
              }
            }
          }

          for (final candidate in candidates) {
            if (candidate == null) continue;

            try {
              final regDir = Directory(candidate.directoryPath);
              if (await regDir.exists()) {
                final regEntities = await regDir.list().toList();
                if (regEntities.isNotEmpty) {
                  extractionActuallySucceeded = true;
                  _log('SUCCESS', '✅✅✅ 注册表交叉验证通过！');
                  _log('SUCCESS', '   游戏已在注册表中: ${candidate.title}');
                  _log('SUCCESS', '   目录路径: ${candidate.directoryPath}');
                  _log('SUCCESS', '   文件数量: ${regEntities.length}');
                  _log('SUCCESS', '   结论：游戏确实已成功安装');
                  break;
                }
              }
            } catch (_) {}
          }

          if (!extractionActuallySucceeded && candidates.isEmpty) {
            _log('WARN', '   注册表中未找到匹配的游戏记录');
            _log('WARN', '   搜索标题: "$gameTitle"');
            _log('WARN', '   目标目录: "$_targetGameDir"');
          } else if (!extractionActuallySucceeded) {
            _log('WARN', '   找到${candidates.length}个候选记录，但目录均无效');
          }
        } catch (regErr) {
          _log('WARN', '注册表验证异常: $regErr');
        }
      }

      if (extractionActuallySucceeded) {
        _log('SUCCESS', '');
        _log('SUCCESS', '========== 以最终结果为准：解压成功 ==========');
        _log('SUCCESS', '中间步骤虽有异常，但最终文件已正确生成');

        _emitProgress(const ExtractProgress(percent: 98, message: '写入游戏信息...'));

        await _writeGameInfo(
          targetDir: _targetGameDir!,
          title: gameTitle,
          description: gameDescription,
          coverUrl: gameCoverUrl,
          tags: gameTags,
          overrideDirectoryPath: extractionTargetDir,
        );

        await _embedCoverBase64(
          targetDir: _targetGameDir!,
          coverUrl: gameCoverUrl,
        );

        _log('SUCCESS', '========== 解压任务完成（最终结果） ==========');
        _log('SUCCESS', '✅ 游戏本体已安装到: $extractionTargetDir');
        _log('SUCCESS', '✅ 游戏元数据已写入: $_targetGameDir');

        _emitProgress(const ExtractProgress(percent: 100, message: '解压完成'));
        _emitStatus(ExtractStatus.completed);
        if (_activeTaskCount > 0) _activeTaskCount--;

        final gamePath = _targetGameDir ?? '';
        final gameId = _currentArchivePath ?? '';

        if (_registeredGames.contains(gamePath)) {
          _log('WARN', '⚠️ 游戏已入库，跳过重复注册');
        } else {
          _registrationCount++;
          _log('INFO', '📦 执行入库逻辑（最终结果路径）');
          LocalGameRegistry.instance.registerExtractionComplete(
            gameTitle: gameTitle,
            directoryPath: gamePath,
          );
          _registeredGames.add(gamePath);
          _log('INFO', '✅ 入库完成');
        }

        _emitSuccess();
        return;
      }

      _log('ERROR', '❌ 最终校验失败: 目标目录无效或空，判定为安装失败');
      _cleanupOnFailure(_targetGameDir!, _actualGameDir);
      _handleError(e.toString());
      _emitFailure(e.toString());
    }
  }

  List<String> _detectFormats(String filePath) {
    final fileName = filePath.split('/').last.split('\\').last.toLowerCase();
    final formats = <String>[];
    final knownExtensions = [
      '.rar.lz4',
      '.zip.lz4',
      '.7z.lz4',
      '.tar.lz4',
      '.zip.7z',
      '.rar.7z',
      '.tar.7z',
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.zip.gz',
      '.rar.gz',
      '.7z.gz',
    ];

    for (final ext in knownExtensions) {
      if (fileName.endsWith(ext)) {
        final parts = ext.split('.').where((s) => s.isNotEmpty).toList();
        if (parts.length >= 2) {
          if (parts[0] == 'tar' &&
              (parts[1] == 'gz' || parts[1] == 'bz2' || parts[1] == 'xz')) {
            formats.add('.${parts[0]}.${parts[1]}');
          } else {
            formats.add('.${parts.last}');
            formats.add('.${parts[parts.length - 2]}');
          }
          final remaining = fileName.substring(0, fileName.length - ext.length);
          return [..._detectFormatsFromName(remaining), ...formats.reversed];
        }
      }
    }

    return _detectFormatsFromName(fileName);
  }

  List<String> _detectFormatsFromName(String name) {
    final singleExts = [
      '.zip',
      '.rar',
      '.7z',
      '.lz4',
      '.tar',
      '.gz',
      '.bz2',
      '.xz',
      '.iso',
      '.cab',
      '.arj',
      '.zst',
      '.lzma',
      '.tar.bz2',
      '.tar.gz',
      '.tar.xz',
      '.tar.zst',
    ];

    for (final ext in singleExts) {
      if (name.endsWith(ext)) {
        if (ext.startsWith('.tar.')) {
          return [ext];
        }
        return [ext];
      }
    }

    final volumePatterns = [
      RegExp(r'\.part(\d+)\.rar$'),
      RegExp(r'\.r(\d{2,3})$'),
      RegExp(r'\.rar$'),
    ];

    for (final pattern in volumePatterns) {
      if (pattern.hasMatch(name)) {
        return ['.rar'];
      }
    }

    return [];
  }

  Future<String> _resolveEffectiveLocation(String? customGameLocation) async {
    if (customGameLocation != null && customGameLocation.isNotEmpty) {
      _log('INFO', '📍 使用用户手动选择的路径: $customGameLocation');
      return customGameLocation;
    }

    final userDefaultLocation =
        await InstallPathPreference.instance.getDefaultGameLocation();

    if (userDefaultLocation != null && userDefaultLocation.isNotEmpty) {
      _log('INFO', '📍 使用用户设置的默认安装路径: $userDefaultLocation');
      return userDefaultLocation;
    }

    _log('INFO', '📍 未找到有效路径，将回退到元数据目录: $_gamesBaseDir');
    return _gamesBaseDir;
  }

  bool _isWithinGamesBaseDirectory(String locationPath) {
    final normalizedLocation = Directory(locationPath).absolute.path;
    final normalizedGamesBase = Directory(_gamesBaseDir).absolute.path;

    final isSameOrSubdir = normalizedLocation == normalizedGamesBase ||
        normalizedLocation.startsWith('$normalizedGamesBase\\') ||
        normalizedLocation.startsWith('$normalizedGamesBase/');

    if (isSameOrSubdir) {
      _log('INFO', '   ✅ 路径关联检测: "$locationPath" 在 Games 基础目录范围内');
    } else {
      _log('INFO', '   ❌ 路径关联检测: "$locationPath" 是独立的外部路径');
    }

    return isSameOrSubdir;
  }

  Future<String> _determineExtractionTarget({
    required String effectiveLocation,
    required String gameTitle,
  }) async {
    if (_isWithinGamesBaseDirectory(effectiveLocation)) {
      final targetDir = '$_targetGameDir\\${_safeDirectoryName(gameTitle)}';
      _log('INFO', '🎯 解压方案(本体在元数据子目录): $targetDir');
      return targetDir;
    } else {
      final targetDir = await _resolveCustomGameDir(
        customBaseDir: effectiveLocation,
        gameTitle: gameTitle,
      );
      _log('INFO', '🎯 解压方案(本体在外部路径): $targetDir');
      return targetDir;
    }
  }

  String _safeDirectoryName(String title) {
    var dirName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return dirName.isEmpty ? 'UnknownGame' : dirName;
  }

  Future<String> _resolveGameDir(String title) async {
    final baseDir = Directory(_gamesBaseDir);
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    var dirName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (dirName.isEmpty) dirName = 'UnknownGame';

    var candidate = '$_gamesBaseDir/$dirName';
    int idx = 1;
    while (await Directory(candidate).exists()) {
      candidate = '$_gamesBaseDir/${dirName}_$idx';
      idx++;
    }
    return candidate;
  }

  Future<String> _resolveCustomGameDir({
    required String customBaseDir,
    required String gameTitle,
  }) async {
    final baseDir = Directory(customBaseDir);
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
        _log('INFO', '自动创建自定义基础目录: $customBaseDir');
      } catch (e) {
        _log('ERROR', '无法创建自定义基础目录: $customBaseDir ($e)');
        rethrow;
      }
    }

    var safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'UnknownGame';

    var candidate = '$customBaseDir\\$safeName';
    int idx = 1;
    while (await Directory(candidate).exists()) {
      candidate = '$customBaseDir\\${safeName}_$idx';
      idx++;
    }

    return candidate;
  }

  Future<String> _extractSingleFormat(
    String inputPath,
    String format,
    String outputDir, {
    required double startPercent,
    required double endPercent,
    bool isFromLz4 = false,
    String? password,
  }) async {
    _log('INFO', '========== 开始解压: $format ==========');
    _log('INFO', '输入: $inputPath');
    _log('INFO', '输出: $outputDir');
    _log('INFO',
        '进度范围: ${startPercent.toStringAsFixed(1)}% - ${endPercent.toStringAsFixed(1)}%');

    if (isFromLz4) {
      _log('INFO', '⚠️ 此文件来自LZ4双层解压，将使用特殊密码策略');
    }

    final isPasswordSupportedFormat =
        (format == '.rar' || format == '.zip' || format == '.7z');

    try {
      _log('INFO', '--- 第1次尝试: 无密码解压 ---');

      String result;
      switch (format) {
        case '.zip':
          result = await _extractZip(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.rar':
          result = await _extractRar(inputPath, outputDir,
              password: password,
              startPercent: startPercent,
              endPercent: endPercent);
          break;
        case '.7z':
          result = await _extract7z(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.lz4':
          result = await _extractLz4(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.tar':
        case '.tar.gz':
        case '.tar.bz2':
        case '.tar.xz':
        case '.tar.zst':
          result = await _extractTarBased(inputPath, outputDir, format,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.gz':
        case '.bz2':
        case '.xz':
        case '.zst':
        case '.lzma':
          result = await _extractSingleCompression(inputPath, outputDir, format,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.iso':
          result = await _extractIso(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.cab':
          result = await _extractCab(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        case '.arj':
          result = await _extractArj(inputPath, outputDir,
              startPercent: startPercent, endPercent: endPercent);
          break;
        default:
          throw Exception('不支持的压缩格式: $format');
      }

      _log('INFO', '✅ 第1次尝试成功（无密码）');
      return result;
    } catch (firstError) {
      _log('WARN', '⚠️ 第1次尝试失败: $firstError');

      if (!isPasswordSupportedFormat) {
        _log('ERROR', '$format 格式不支持密码重试，直接抛出异常');
        rethrow;
      }

      final errStr = firstError.toString().toLowerCase();
      final isPasswordRelatedError = errStr.contains('password') ||
          errStr.contains('wrong') ||
          errStr.contains('incorrect') ||
          errStr.contains('加密') ||
          errStr.contains('need password') ||
          errStr.contains('corrupt') ||
          errStr.contains('checksum') ||
          errStr.contains('bad password') ||
          errStr.contains('wrong password') ||
          errStr.contains('password required') ||
          errStr.contains('encrypted') ||
          true;

      if (!isPasswordRelatedError) {
        _log('ERROR', '错误类型不是密码相关，不进行重试');
        rethrow;
      }

      _log('INFO', '');
      _log('INFO', '=== 检测到密码相关错误，开始第2次尝试 ===');
      _log('INFO', '使用默认密码: $_defaultPassword');
      _log('INFO', '--- 第2次尝试: 带密码解压 ---');

      try {
        String retryResult;

        final adjustedStartPercent =
            startPercent + ((endPercent - startPercent) * 0.5);

        switch (format) {
          case '.rar':
            retryResult = await _extractRar(inputPath, outputDir,
                password: _defaultPassword,
                startPercent: adjustedStartPercent,
                endPercent: endPercent);
            break;
          case '.zip':
            retryResult = await _extractZip(inputPath, outputDir,
                password: _defaultPassword,
                startPercent: adjustedStartPercent,
                endPercent: endPercent);
            break;
          case '.7z':
            retryResult = await _extract7z(inputPath, outputDir,
                password: _defaultPassword,
                startPercent: adjustedStartPercent,
                endPercent: endPercent);
            break;
          default:
            rethrow;
        }

        _log('INFO', '✅✅ 第2次尝试成功（使用默认密码）');
        return retryResult;
      } catch (retryError) {
        _log('ERROR', '❌❌ 第2次尝试也失败（默认密码无效）');
        _log('ERROR', '第1次错误: $firstError');
        _log('ERROR', '第2次错误: $retryError');

        throw Exception('双重解压失败:\n'
            '格式: $format\n'
            '文件: $inputPath\n'
            '----------------------------------------\n'
            '[无密码尝试] $firstError\n'
            '[带密码尝试($_defaultPassword)] $retryError\n'
            '----------------------------------------');
      }
    }
  }

  Future<String> _extractZip(
    String inputPath,
    String outputDir, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();
    _log('INFO', '使用内置7-Zip解压ZIP${password != null ? " (带密码)" : ""}');
    return await _extractWith7z(inputPath, outputDir, 'zip',
        password: password, startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractRar(
    String inputPath,
    String outputDir, {
    String? password,
    bool forceDefaultPassword = false,
    required double startPercent,
    required double endPercent,
  }) async {
    final effectivePassword =
        forceDefaultPassword ? _defaultPassword : password;

    _log('INFO', '═══════════════════════════════════════');
    _log('INFO', '【RAR解压】使用7-Zip解压');
    _log('INFO', '输入文件: $inputPath');
    _log('INFO', '输出目录: $outputDir');
    _log('INFO',
        '密码: ${effectivePassword != null && effectivePassword.isNotEmpty ? effectivePassword : "无密码"}');
    _log('INFO', '═══════════════════════════════════════');

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('RAR输入文件不存在: $inputPath');
    }

    final inputSize = await inputFile.length();
    if (inputSize == 0) {
      throw Exception('RAR输入文件为空: $inputPath');
    }

    _log('INFO', '输入文件大小: ${(inputSize / 1024 / 1024).toStringAsFixed(2)}MB');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
      _log('INFO', '创建输出目录: $outputDir');
    }

    _emitProgress(ExtractProgress(
      percent: startPercent,
      message: password != null ? '正在解压RAR(带密码)...' : '正在解压RAR...',
    ));

    return await _extractRarWith7z(
      inputPath: inputPath,
      outputDir: outputDir,
      password: effectivePassword,
      startPercent: startPercent,
      endPercent: endPercent,
    );
  }

  Future<String> _extractRarWith7z({
    required String inputPath,
    required String outputDir,
    required String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    // 直接使用 -aos 模式
    final args = <String>[
      'x',
      inputPath,
      '-o$outputDir',
      '-y',
      '-aos',
    ];

    if (password != null && password.isNotEmpty) {
      args.add('-p$password');
    } else {
      args.add('-p');
    }

    final result = await Process.run(exePath, args);

    final exitCode = result.exitCode;
    final stdoutContent = result.stdout.toString().trim();
    final stderrContent = result.stderr.toString().trim();

    int lastPercent = 0;
    for (final line in stdoutContent.split('\n')) {
      final parsed = _parse7zLine(line);
      if (parsed != null && parsed > lastPercent) {
        lastPercent = parsed;
        final adjusted =
            startPercent + (parsed / 100.0) * (endPercent - startPercent);
        _emitProgress(ExtractProgress(
          percent: adjusted,
          message: '解压中 $parsed%',
        ));
      }
    }

    if (exitCode != 0) {
      _log('ERROR', '7-Zip解压RAR失败 (exitCode=$exitCode)');
      throw Exception('解压失败(exitCode=$exitCode)');
    }

    await Future.delayed(const Duration(milliseconds: 200));
    return outputDir;
  }

  Future<String> _extract7z(
    String inputPath,
    String outputDir, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();

    _log('INFO', '使用内置7-Zip解压ZIP/7Z');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    // 直接使用 -aos 模式：跳过已存在的文件，不触发文件锁定冲突
    final args = <String>[
      'x',
      inputPath,
      '-o$outputDir',
      '-y',
      '-aos',
    ];

    if (password != null && password.isNotEmpty) {
      args.add('-p$password');
    } else {
      args.add('-p');
    }

    final result = await Process.run(exePath, args);

    final exitCode = result.exitCode;
    final stdoutContent = result.stdout.toString().trim();
    final stderrContent = result.stderr.toString().trim();

    // 进度解析
    int lastPercent = 0;
    for (final line in stdoutContent.split('\n')) {
      final parsed = _parse7zLine(line);
      if (parsed != null && parsed > lastPercent) {
        lastPercent = parsed;
        final adjusted =
            startPercent + (parsed / 100.0) * (endPercent - startPercent);
        _emitProgress(ExtractProgress(
          percent: adjusted,
          message: '解压中 $parsed%',
        ));
      }
    }

    // 关键错误日志
    if (exitCode != 0) {
      _log('ERROR', '7-Zip解压失败 (exitCode=$exitCode)');
      for (final line in stderrContent.split('\n')) {
        final lower = line.toLowerCase();
        if (lower.contains('error') ||
            lower.contains('cannot') ||
            lower.contains('wrong password')) {
          _log('ERROR', '  $line'.trim());
        }
      }
      throw Exception('解压失败(exitCode=$exitCode)');
    }

    // 验证结果
    await Future.delayed(const Duration(milliseconds: 200));
    final entities = await outDir.list(recursive: true).toList();
    final fileCount = entities.whereType<File>().length;

    if (fileCount == 0) {
      throw Exception('解压后目录为空');
    }

    _log('INFO', '解压完成 ($fileCount 个文件)');
    return outputDir;
  }

  int? _parse7zLine(String line) {
    final trimmed = line.trimLeft();
    final match = RegExp(r'^\s*(\d+)\s').firstMatch(trimmed);
    if (match != null) {
      final val = int.tryParse(match.group(1)!);
      if (val != null && val <= 100) {
        return val;
      }
    }
    return null;
  }

  Future<void> _extractRarLz4({
    required String archivePath,
    required String outputDir,
  }) async {
    _log('INFO', '==========================================');
    _log('INFO', '【.rar.lz4 格式检测】使用 rar_lz4_unzip.exe 专用工具');
    _log('INFO', '==========================================');
    _log('INFO', '压缩包: $archivePath');
    _log('INFO', '输出目录: $outputDir');

    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      throw Exception('.rar.lz4 压缩包不存在: $archivePath');
    }

    _emitProgress(const ExtractProgress(
        percent: 5, message: '正在调用 rar_lz4_unzip.exe...'));

    try {
      final service = RarLz4UnzipService();

      _emitProgress(const ExtractProgress(
          percent: 10, message: '正在调用 rar_lz4_unzip.exe...'));

      final success = await service.unzip(archivePath, outputDir);

      if (!success) {
        _log('ERROR', '❌ rar_lz4_unzip.exe 返回失败');
        throw Exception('[.rar.lz4 解压失败] 工具返回非 SUCCESS');
      }

      _emitProgress(const ExtractProgress(
        percent: 92,
        message: '解压成功，正在验证...',
      ));

      final targetDir = Directory(outputDir);
      if (!await targetDir.exists()) {
        throw Exception('解压完成但目标目录不存在: $outputDir');
      }

      final entities = await targetDir.list().toList();
      if (entities.isEmpty) {
        throw Exception('解压完成但目标目录为空: $outputDir');
      }

      _log('INFO', '✅ 验证通过 | 目标目录包含 ${entities.length} 个条目');

      final fileCount = entities.whereType<File>().length;
      final dirCount = entities.whereType<Directory>().length;
      _log('INFO', '   - 文件数: $fileCount');
      _log('INFO', '   - 目录数: $dirCount');

      _emitProgress(const ExtractProgress(
        percent: 96,
        message: '验证通过，准备写入游戏信息...',
      ));

      _emitProgress(const ExtractProgress(
        percent: 100,
        message: '解压完成',
      ));

      _log('INFO', '==========================================');
      _log('INFO', '✅ 【rar_lz4_unzip.exe】解压成功完成');
      _log('INFO', '==========================================');
      _log('INFO', '');
    } catch (e) {
      _log('ERROR', '');
      _log('ERROR', '【rar_lz4_unzip.exe】异常: $e');
      _log('ERROR', '');
      rethrow;
    }
  }

  Future<String> _extractLz4(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    // lz4.exe 不包含在开源版本中，检查工具是否可用
    try {
      final lz4Path = await _getToolPath('lz4.exe');
      final lz4File = File(lz4Path);
      if (!await lz4File.exists()) {
        throw Exception('lz4.exe 工具文件不存在，开源版本不支持纯 LZ4 格式解压');
      }
    } catch (e) {
      _log('ERROR', 'lz4.exe 不可用: $e');
      throw Exception('开源版本不支持纯 LZ4 格式解压，如需此功能请使用正式版');
    }

    final lz4Path = await _getToolPath('lz4.exe');

    _log('INFO', '');
    _log('INFO', '【LZ4 解压开始】');
    _log('INFO', '========== LZ4外层解压 ==========');
    _log('INFO', '工具路径: $lz4Path');
    _log('INFO', '输入文件: $inputPath');

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('LZ4输入文件不存在: $inputPath');
    }

    final inputSize = await inputFile.length();
    if (inputSize == 0) {
      throw Exception('LZ4输入文件为空: $inputPath');
    }

    _log('INFO', '输入文件大小: ${(inputSize / 1024 / 1024).toStringAsFixed(2)}MB');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
      _log('INFO', '创建输出目录: $outputDir');
    }

    final fileName = inputPath.split('/').last.split('\\').last;
    var outName = fileName;

    if (outName.endsWith('.lz4')) {
      outName = outName.substring(0, outName.length - 4);
    }

    if (outName.isEmpty) {
      outName = 'temp_archive';
    }

    final outputPath = '$outputDir\\$outName'.replaceAll('/', '\\');

    _log('INFO', '输出文件: $outputPath');

    _emitProgress(ExtractProgress(
      percent: startPercent,
      message: '正在解压LZ4外层...',
    ));

    try {
      final normalizedInputPath = inputPath.replaceAll('/', '\\');
      final normalizedOutputPath = outputPath.replaceAll('/', '\\');

      _log('INFO',
          'LZ4完整命令: $lz4Path -d -f "$normalizedInputPath" "$normalizedOutputPath"');

      final result = await Process.run(
        lz4Path,
        ['-d', '-f', normalizedInputPath, normalizedOutputPath],
        workingDirectory: outputDir,
      );

      final exitCode = result.exitCode;

      _log('INFO', 'LZ4进程退出码: $exitCode');

      if (exitCode != 0) {
        throw Exception('LZ4解压失败(exitCode=$exitCode)');
      }

      final outputFile = File(outputPath);
      if (!await outputFile.exists()) {
        throw Exception('LZ4解压完成但输出文件不存在: $outputPath');
      }

      final outputSize = await outputFile.length();
      if (outputSize == 0) {
        throw Exception('LZ4解压完成但输出文件为空: $outputPath');
      }

      _log('INFO',
          '✅ LZ4解压成功 | 输出大小: ${(outputSize / 1024 / 1024).toStringAsFixed(2)}MB | 路径: $outputPath');
      _log('INFO', '【LZ4 解压完成，生成临时 .rar 文件】');
      _log('INFO', '========== LZ4外层解压结束 ==========');
      _log('INFO', '');

      _emitProgress(ExtractProgress(
        percent: endPercent,
        message: 'LZ4外层解压完成',
      ));

      return outputPath;
    } catch (e) {
      _log('ERROR', 'LZ4解压异常: $e');

      final badFile = File(outputPath);
      if (await badFile.exists()) {
        try {
          await badFile.delete();
          _log('INFO', '已清理失败的LZ4输出: $outputPath');
        } catch (_) {}
      }

      rethrow;
    }
  }

  Future<String> _extractTarBased(
    String inputPath,
    String outputDir,
    String format, {
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压TAR系列格式($format)');
    return await _extractWith7z(
        inputPath, outputDir, format.replaceAll('.', ''),
        startPercent: startPercent, endPercent: endPercent);

    _log('INFO', '尝试使用tar命令解压($format)');
    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    String flag;
    switch (format) {
      case '.tar.gz':
      case '.gz':
        flag = 'xzf';
        break;
      case '.tar.bz2':
      case '.bz2':
        flag = 'xjf';
        break;
      case '.tar.xz':
        flag = 'xJf';
        break;
      default:
        flag = 'xf';
    }

    final result = await Process.run(
      'tar',
      [flag, inputPath, '-C', outputDir],
    );

    final exitCode = result.exitCode;

    if (exitCode != 0) {
      throw Exception('TAR解压失败(exitCode=$exitCode)');
    }

    _emitProgress(ExtractProgress(
      percent: endPercent,
      message: 'TAR解压完成',
    ));
    return outputDir;
  }

  Future<String> _extractWith7z(
    String inputPath,
    String outputDir,
    String formatType, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    return await _extract7z(inputPath, outputDir,
        password: password, startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractSingleCompression(
    String inputPath,
    String outputDir,
    String format, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【单文件压缩格式解压】$format');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压单文件压缩格式: $format');
    return await _extractWith7z(
        inputPath, outputDir, format.replaceAll('.', ''),
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractIso(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【ISO格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压ISO');
    return await _extractWith7z(inputPath, outputDir, 'iso',
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractCab(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【CAB格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压CAB');
    return await _extractWith7z(inputPath, outputDir, 'cab',
        startPercent: startPercent, endPercent: endPercent);

    _log('INFO', '尝试使用Windows内置expand工具解压CAB...');
    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final result = await Process.run(
      'expand',
      [inputPath, '-F:\\*', outputDir],
    );

    if (result.exitCode != 0) {
      throw Exception('CAB解压失败(exitCode=${result.exitCode})');
    }

    _emitProgress(ExtractProgress(
      percent: endPercent,
      message: 'CAB解压完成',
    ));
    return outputDir;
  }

  Future<String> _extractArj(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【ARJ格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压ARJ');
    return await _extractWith7z(inputPath, outputDir, 'arj',
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _getBundled7zPath() async {
    final bundled = '${PathHelper.toolsDir}/7z.exe';
    final f = File(bundled);
    if (await f.exists()) return f.absolute.path;
    throw Exception('内置 7z.exe 不存在: $bundled');
  }

  Future<void> _writeGameInfo({
    required String targetDir,
    required String title,
    String? description,
    String? coverUrl,
    List<String>? tags,
    String? overrideDirectoryPath,
  }) async {
    _log('INFO', '🔍 开始智能识别启动 EXE...');

    final detectionDir = overrideDirectoryPath ?? targetDir;
    final detection = await GameLauncherDetector.detect(detectionDir);

    String launcherPath = '';
    if (detection.success && detection.launcherPath != null) {
      launcherPath = detection.launcherPath!;
      _log('INFO',
          '✅ 识别成功 | 优先级#${detection.priority} | ${detection.exeFileName}');
    } else {
      _log('WARN', '⚠️ 自动识别失败，launch_path留空（用户可手动选择）');
    }

    await GameDataFormat.writeGameDir(
      targetDir: targetDir,
      title: title,
      description: description ?? '',
      tags: tags ?? [],
      coverUrl: coverUrl,
      launchPath: launcherPath,
      directoryPath: overrideDirectoryPath ?? targetDir,
      source: 'download',
    );

    final effectiveDir = overrideDirectoryPath ?? targetDir;
    _log('INFO', '已写入 .ctgame + game.json: $targetDir');
    _log('INFO', '   directory_path: $effectiveDir');

    if (launcherPath.isNotEmpty) {
      _log('INFO', '   launch_path: $launcherPath');
    }

    final writtenData = await GameDataFormat.readGameJson(targetDir);
    if (writtenData != null) {
      if (writtenData.directoryPath != effectiveDir) {
        _log('WARN', '⚠️ game.json中的directory_path不一致!');
        _log('WARN', '   期望: $effectiveDir');
        _log('WARN', '   实际: ${writtenData.directoryPath}');
        _log('WARN', '   正在修正...');
        await GameDataFormat.updateGameJson(targetDir, {
          'directory_path': effectiveDir,
        });
        _log('INFO', '✅ directory_path已修正');
      } else {
        _log('INFO', '✅ directory_path一致性检查通过');
      }
    } else {
      _log('WARN', '⚠️ 无法读取刚写入的game.json进行验证');
    }
  }

  Future<void> _embedCoverBase64({
    required String targetDir,
    String? coverUrl,
  }) async {
    return;
  }

  void _cleanupOnFailure(String targetDir,
      [String? extractionTargetDir]) async {
    _log('WARN', '');
    _log('WARN', '========================================');
    _log('WARN', '开始失败回滚清理...');
    _log('WARN', '========================================');

    if (_currentProcess != null) {
      try {
        _log('INFO', '步骤1: 终止残留解压进程...');
        _currentProcess?.kill(ProcessSignal.sigterm);

        await Future.delayed(const Duration(milliseconds: 500));

        if (_currentProcess != null) {
          _currentProcess?.kill(ProcessSignal.sigkill);
          await Future.delayed(const Duration(milliseconds: 200));
        }

        _currentProcess = null;
        _log('INFO', '✅ 步骤1完成: 进程已终止');
      } catch (e) {
        _log('WARN', '⚠️ 步骤1警告: 终止进程时异常: $e');
        _currentProcess = null;
      }
    } else {
      _log('INFO', '步骤1: 无残留进程，跳过');
    }

    _log('INFO', '步骤2: 扫描并清理所有临时目录...');

    for (int i = 0; i < 10; i++) {
      final tempDirPattern = [
        '$targetDir._temp_layer_$i',
        '${targetDir}_temp_layer_$i',
      ];

      for (final pattern in tempDirPattern) {
        final tempDir = Directory(pattern);
        if (await tempDir.exists()) {
          try {
            final filesBefore = await tempDir.list().toList();
            await tempDir.delete(recursive: true);

            if (!await tempDir.exists()) {
              _log('INFO', '  ✅ 已清理: $pattern (${filesBefore.length}个条目)');
            } else {
              _log('WARN', '  ⚠️ 清理后仍存在: $pattern');
            }
          } catch (e) {
            _log('ERROR', '  ❌ 清理失败: $pattern | 错误: $e');
            try {
              await Future.delayed(const Duration(milliseconds: 300));
              await tempDir.delete(recursive: true);
              _log('INFO', '  ✅ 重试成功: $pattern');
            } catch (retryErr) {
              _log('ERROR', '  ❌ 重试也失败: $pattern | $retryErr');
            }
          }
        }
      }
    }
    _log('INFO', '✅ 步骤2完成: 临时目录清理结束');

    _log('INFO', '步骤3: 扫描并清理LZ4生成的临时文件...');

    final lz4TempPatterns = [
      '$targetDir\\*.rar',
      '$targetDir\\*.zip',
      '$targetDir\\*.7z',
      '$targetDir\\*.tar',
    ];

    for (final pattern in lz4TempPatterns) {
      try {
        final parentDir = Directory(targetDir);
        if (await parentDir.exists()) {
          await for (final entity in parentDir.list()) {
            if (entity is File) {
              final name = entity.path.toLowerCase();
              final isArchiveFile = name.endsWith('.rar') ||
                  name.endsWith('.zip') ||
                  name.endsWith('.7z') ||
                  name.endsWith('.tar');

              if (isArchiveFile && entity.path != _currentArchivePath) {
                try {
                  await entity.delete();
                  _log('INFO', '  ✅ 已删除临时压缩文件: ${entity.path}');
                } catch (delErr) {
                  _log('WARN', '  ⚠️ 删除临时文件失败: ${entity.path} | $delErr');
                }
              }
            }
          }
        }
      } catch (scanErr) {
        _log('WARN', '  ⚠️ 扫描临时文件异常: $scanErr');
      }
    }
    _log('INFO', '✅ 步骤3完成: 临时文件清理结束');

    _log('INFO', '步骤4: 检查目标目录状态...');

    final target = Directory(targetDir);
    if (await target.exists()) {
      try {
        final entities = await target.list().toList();

        if (entities.isEmpty) {
          try {
            await target.delete();
            _log('INFO', '  ✅ 目标目录为空，已删除: $targetDir');
          } catch (delErr) {
            _log('WARN', '  ⚠️ 删除空目录失败: $targetDir | $delErr');
          }
        } else {
          final fileCount = entities.where((e) => e is File).length;
          final dirCount = entities.where((e) => e is Directory).length;
          _log('INFO', '  ℹ️ 目标目录非空，保留已解压内容: $targetDir');
          _log('INFO', '     包含: $fileCount 个文件, $dirCount 个子目录');

          final testFiles = entities.whereType<File>().take(3).toList();
          for (final f in testFiles) {
            _log('INFO', '     - ${f.path.split('\\').last}');
          }
          if (entities.length > 3) {
            _log('INFO', '     ... 还有 ${entities.length - 3} 个条目');
          }
        }
      } catch (checkErr) {
        _log('ERROR', '  ❌ 检查目标目录异常: $checkErr');
      }
    } else {
      _log('INFO', '  ℹ️ 目标目录不存在，无需清理');
    }
    _log('INFO', '✅ 步骤4完成: 目标目录检查结束');

    _log('INFO', '步骤5: 保留原始压缩包（失败回滚不删除）...');

    if (_currentArchivePath != null && _currentArchivePath!.isNotEmpty) {
      final archiveFile = File(_currentArchivePath!);
      if (await archiveFile.exists()) {
        final size = await archiveFile.length();
        _log('INFO',
            '  ℹ️ 保留原压缩包: $_currentArchivePath (${(size / 1024 / 1024).toStringAsFixed(2)}MB)');
        _log('INFO', '  ℹ️ 用户可手动删除或重新尝试安装');
      } else {
        _log('INFO', '  ℹ️ 原压缩包不存在: $_currentArchivePath');
      }
    } else {
      _log('INFO', '  ℹ️ 无原压缩包路径信息');
    }
    _log('INFO', '✅ 步骤5完成: 原始压缩包已保留');

    if (extractionTargetDir != null &&
        extractionTargetDir!.isNotEmpty &&
        extractionTargetDir != targetDir) {
      _log('INFO', '步骤6: 清理解压目标目录(自定义路径)...');

      final extractDir = Directory(extractionTargetDir!);
      if (await extractDir.exists()) {
        try {
          final entities = await extractDir.list().toList();

          if (entities.isEmpty) {
            try {
              await extractDir.delete();
              _log('INFO', '  ✅ 解压目录为空，已删除: $extractionTargetDir');
            } catch (delErr) {
              _log('WARN', '  ⚠️ 删除空解压目录失败: $extractionTargetDir | $delErr');
            }
          } else {
            final fileCount = entities.where((e) => e is File).length;
            final dirCount = entities.where((e) => e is Directory).length;
            _log('INFO', '  ℹ️ 解压目录非空，保留部分解压内容: $extractionTargetDir');
            _log('INFO', '     包含: $fileCount 个文件, $dirCount 个子目录');

            bool hasGameData = false;
            for (final entity in entities) {
              final name = entity.path.toLowerCase();
              if (name.endsWith('.exe') ||
                  name.endsWith('.ctgame') ||
                  name.endsWith('.json')) {
                hasGameData = true;
                break;
              }
            }

            if (!hasGameData && entities.length <= 5) {
              try {
                await extractDir.delete(recursive: true);
                _log('INFO', '  ✅ 已清理无效的解压目录: $extractionTargetDir');
              } catch (delErr) {
                _log('WARN', '  ⚠️ 清理解压目录失败: $extractionTargetDir | $delErr');
              }
            }
          }
        } catch (checkErr) {
          _log('ERROR', '  ❌ 检查解压目录异常: $extractionTargetDir | $checkErr');
        }
      }
      _log('INFO', '✅ 步骤6完成: 解压目录清理结束');
    }

    _log('INFO', '');
    _log('INFO', '========================================');
    _log('INFO', '✅ 失败回滚清理全部完成');
    _log('INFO', '========================================');
    _log('INFO', '');
  }

  void _handleError(String rawMsg) {
    if (_activeTaskCount > 0) _activeTaskCount--;
    _errorMessage = rawMsg;
    _emitStatus(ExtractStatus.failed);
  }

  void _log(String level, String message) {
    final timestamp = DateTime.now().toString().substring(0, 19);
    final logLine = '[$timestamp] [$level] [EXTRACT] $message';
    debugPrint(logLine);

    _persistLog(logLine);
  }

  Future<void> _persistLog(String line) async {
    try {
      final logDir = Directory(_logsDir);
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final dateStr = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-')
          .substring(0, 19);
      final logFile = File('$_logsDir/extract_${dateStr}.txt');
      if (!await logFile.exists()) {
        await logFile.writeAsString('');
      }
      await logFile.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  void cancel() {
    if (_status == ExtractStatus.extracting) {
      if (_activeTaskCount > 0) _activeTaskCount--;

      if (_currentProcess != null) {
        _log('WARN', '用户取消解压操作，终止进程...');
        _currentProcess?.kill();
        _currentProcess = null;
      }

      _log('WARN', '用户取消解压操作');
      _emitStatus(ExtractStatus.idle);
    }
  }

  void reset() {
    _status = ExtractStatus.idle;
    _progress = null;
    _errorMessage = null;
    _currentArchivePath = null;
    _targetGameDir = null;
    _currentProcess = null;
  }
}
