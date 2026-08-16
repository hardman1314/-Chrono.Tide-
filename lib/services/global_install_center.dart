import 'dart:io';
import 'package:flutter/material.dart';
import 'download_core.dart';
import 'extract_manager.dart';
import 'local_game_registry.dart';
import 'game_data_format.dart';
import 'path_validator.dart';
import '../core/path_helper.dart';
import 'storage/cleanup_utils.dart';

enum InstallPhase {
  idle,
  downloading,
  extracting,
  completed,
  failed,
  cancelled
}

class InstallProgress {
  final double downloadPercent;
  final double extractPercent;
  final String downloadSpeed;
  final String statusMessage;

  const InstallProgress({
    this.downloadPercent = 0.0,
    this.extractPercent = 0.0,
    this.downloadSpeed = '0 B/s',
    this.statusMessage = '',
  });
}

class InstallTask {
  final String gameId;
  final String title;
  final String? description;
  final String? coverUrl;
  final List<String>? tags;
  final String downloadUrl;
  final String? developer;
  final String? customGameLocation;
  final List<String>? screenshotUrls;

  const InstallTask({
    required this.gameId,
    required this.title,
    this.description,
    this.coverUrl,
    this.tags,
    required this.downloadUrl,
    this.developer,
    this.customGameLocation,
    this.screenshotUrls,
  });
}

class GlobalInstallCenter {
  static final GlobalInstallCenter _instance = GlobalInstallCenter._internal();
  static GlobalInstallCenter get instance => _instance;

  GlobalInstallCenter._internal();

  final DownloadCore _dlCore = DownloadCore();

  InstallPhase _phase = InstallPhase.idle;
  InstallTask? _currentTask;
  String? _downloadedFilePath;
  String? _errorMessage;
  bool _isBusy = false;
  String? _customGameLocation;

  InstallProgress _progress = const InstallProgress();

  final List<void Function(InstallPhase)> _phaseListeners = [];
  final List<void Function(InstallProgress)> _progressListeners = [];
  final List<void Function(String)> _errorListeners = [];
  final List<void Function()> _successListeners = [];

  InstallPhase get phase => _phase;
  InstallTask? get currentTask => _currentTask;
  String? get downloadedFilePath => _downloadedFilePath;
  String? get errorMessage => _errorMessage;
  bool get isBusy => _isBusy;
  bool get isRunning =>
      _phase == InstallPhase.downloading || _phase == InstallPhase.extracting;
  InstallProgress get progress => _progress;

  void addListener(
      {void Function(InstallPhase)? phase,
      void Function(InstallProgress)? progress}) {
    if (phase != null) _phaseListeners.add(phase);
    if (progress != null) _progressListeners.add(progress);
  }

  void removeListener(
      {void Function(InstallPhase)? phase,
      void Function(InstallProgress)? progress}) {
    if (phase != null) _phaseListeners.remove(phase);
    if (progress != null) _progressListeners.remove(progress);
  }

  void removeAllListeners() {
    _phaseListeners.clear();
    _progressListeners.clear();
    _errorListeners.clear();
    _successListeners.clear();
  }

  void _emitPhase(InstallPhase newPhase) {
    _phase = newPhase;
    for (final l in _phaseListeners) l(newPhase);
  }

  void _emitProgress(InstallProgress p) {
    _progress = p;
    for (final l in _progressListeners) l(p);
  }

  void _emitError(String msg) {
    _errorMessage = msg;
    for (final l in _errorListeners) l(msg);
  }

  void _emitSuccess() {
    for (final l in _successListeners) l();
  }

  Future<bool> submitTask(InstallTask task) async {
    if (_isBusy) {
      debugPrint(
          '[INSTALL-CENTER] ⚠️ 当前有任务进行中，拒绝新任务 | 当前: ${_currentTask?.title} | 新请求: ${task.title}');
      return false;
    }

    debugPrint(
        '[INSTALL-CENTER] ✅ 接收新安装任务 | 游戏: ${task.title} | ID: ${task.gameId}');

    _currentTask = task;
    _errorMessage = null;
    _downloadedFilePath = null;
    _isBusy = true;
    _customGameLocation = task.customGameLocation;

    if (_customGameLocation != null && _customGameLocation!.isNotEmpty) {
      debugPrint('[INSTALL-CENTER] 🆕 自定义本体位置: $_customGameLocation');

      final pathValidation =
          PathValidator.validateCustomGameLocation(_customGameLocation);
      if (!pathValidation.isValid) {
        _isBusy = false;
        _errorMessage = '路径验证失败: ${pathValidation.message}';
        _emitPhase(InstallPhase.failed);
        _emitError(_errorMessage!);
        return false;
      }

      final diskSpace =
          await PathValidator.getDiskSpaceInfo(_customGameLocation!);
      if (!diskSpace.isAvailable) {
        _isBusy = false;
        _errorMessage = '无法访问目标磁盘: ${diskSpace.error}';
        _emitPhase(InstallPhase.failed);
        _emitError(_errorMessage!);
        return false;
      }
    } else {
      debugPrint('[INSTALL-CENTER] 使用默认安装路径');
    }

    _setupDownloadListeners();

    try {
      _emitPhase(InstallPhase.downloading);
      _emitProgress(const InstallProgress(statusMessage: '正在获取链接...'));

      debugPrint('[INSTALL-CENTER] 步骤1/3：开始下载...');
      await _startDownload(task);

      if (_phase == InstallPhase.cancelled) return false;

      debugPrint('[INSTALL-CENTER] 步骤2/3：开始解压...');
      _emitPhase(InstallPhase.extracting);
      await _startExtraction();

      if (_phase == InstallPhase.cancelled) return false;

      debugPrint('[INSTALL-CENTER] 步骤3/3：入库完成！');
      _emitPhase(InstallPhase.completed);
      _emitProgress(const InstallProgress(
        downloadPercent: 100.0,
        extractPercent: 100.0,
        statusMessage: '安装完成',
      ));

      await _onInstallSuccess(task);
      _emitSuccess();
      _resetBusyState();
      return true;
    } catch (e) {
      debugPrint('[INSTALL-CENTER] ⚠️ 安装流程捕获异常: $e');
      debugPrint('[INSTALL-CENTER] 开始终极兜底验证...');

      final ultimateCheck = await _ultimateSuccessVerification();
      if (ultimateCheck) {
        debugPrint('[INSTALL-CENTER] ✅ 终极兜底验证通过：游戏已成功安装，忽略异常');
        _emitPhase(InstallPhase.completed);
        _emitProgress(const InstallProgress(
          downloadPercent: 100.0,
          extractPercent: 100.0,
          statusMessage: '安装完成',
        ));
        await _onInstallSuccess(task);
        _emitSuccess();
        _resetBusyState();
        return true;
      }

      debugPrint('[INSTALL-CENTER] ❌ 终极兜底验证失败：确认安装失败');
      await _rollback(e.toString());
      return false;
    }
  }

  void _setupDownloadListeners() {
    _dlCore.removeAllListeners();

    _dlCore.addStatusListener((status) {
      if (!mounted) return;
      if (status == DownloadStatus.completed) {
        debugPrint('[INSTALL-CENTER]   下载完成，准备解压...');
      }
    });

    _dlCore.addProgressListener((prog) {
      if (!mounted) return;
      _emitProgress(InstallProgress(
        downloadPercent: prog.percent,
        downloadSpeed: prog.speed,
        statusMessage: '正在获取... ${prog.percent.toStringAsFixed(1)}%',
      ));
    });

    _dlCore.addCompleteListener((path) {
      if (!mounted) return;
      _downloadedFilePath = path;
      debugPrint('[INSTALL-CENTER]   文件下载保存到: $path');
    });

    _dlCore.addErrorListener((msg) {
      if (!mounted) return;
      _emitError(msg);
    });
  }

  Future<void> _startDownload(InstallTask task) async {
    await _dlCore.start(
      url: task.downloadUrl,
      gameId: task.gameId,
      fileName: task.title,
      title: task.title,
      description: task.description,
      coverUrl: task.coverUrl,
      tags: task.tags,
      customGameLocation: task.customGameLocation ?? _customGameLocation,
    );

    if (_dlCore.status == DownloadStatus.failed) {
      throw Exception(_dlCore.errorMessage ?? '获取失败');
    }
    if (_dlCore.status == DownloadStatus.cancelled) {
      _emitPhase(InstallPhase.cancelled);
      _resetBusyState();
      return;
    }
  }

  Future<void> _startExtraction() async {
    if (_downloadedFilePath == null || _downloadedFilePath!.isEmpty) {
      throw Exception('下载文件路径为空');
    }

    final extractMgr = _dlCore.extractManager;
    extractMgr.removeListeners();

    extractMgr.addStatusListener((status) {
      if (!mounted) return;
      debugPrint('[INSTALL-CENTER]   解压状态变更: $status');
    });

    extractMgr.addProgressListener((prog) {
      if (!mounted) return;
      _emitProgress(InstallProgress(
        downloadPercent: 100.0,
        extractPercent: prog.percent,
        downloadSpeed: '0 B/s',
        statusMessage: prog.message.isNotEmpty ? prog.message : '正在解压...',
      ));
    });

    extractMgr.addSuccessListener(() {
      debugPrint('[INSTALL-CENTER]   解压成功回调触发');
    });

    extractMgr.addFailureListener((err) {
      if (!mounted) return;
      debugPrint('[INSTALL-CENTER]   解压失败: $err');
    });

    await extractMgr.start(
      archivePath: _downloadedFilePath!,
      gameTitle: _currentTask?.title ?? _currentTask?.gameId ?? 'UnknownGame',
      gameDescription: _currentTask?.description,
      gameCoverUrl: _currentTask?.coverUrl,
      gameTags: _currentTask?.tags,
      customGameLocation: _customGameLocation,
    );

    final extractStatus = extractMgr.status;
    debugPrint('[INSTALL-CENTER] 解压完成 | 状态: $extractStatus');

    if (extractStatus == ExtractStatus.failed) {
      debugPrint('[INSTALL-CENTER] ⚠️ 解压状态为failed，开始二次验证...');

      final actuallySucceeded = await _verifyExtractionActuallySucceeded();
      if (actuallySucceeded) {
        debugPrint('[INSTALL-CENTER] ✅ 二次验证通过：解压实际成功，忽略failed状态');
        return;
      }

      final registryCheck = await _checkGameInRegistry();
      if (registryCheck) {
        debugPrint('[INSTALL-CENTER] ✅ 注册表验证通过：游戏已入库，视为安装成功');
        return;
      }

      debugPrint('[INSTALL-CENTER] ❌ 所有验证失败：确认安装失败');
      throw Exception(extractMgr.errorMessage ?? '解压失败');
    } else if (extractStatus == ExtractStatus.completed) {
      debugPrint('[INSTALL-CENTER] ✅ 解压状态为completed，安装成功');
    }
  }

  /// 安装成功后的清理与校验钩子。
  ///
  /// 1. 删除 downloads 里的游戏压缩包(无条件删除,用户已决策)。
  ///    注:extract_manager.start() 已删过一次,此处是兜底确保删除。
  /// 2. 完整性校验:检查解压目标目录文件数 ≥ 阈值且至少含 1 个 .exe。
  ///    校验失败仅记录日志,不回滚(安装已成功,仅警告)。
  Future<void> _onInstallSuccess(InstallTask task) async {
    debugPrint('[INSTALL-CENTER] 🧹 安装成功后清理与校验...');

    // 1. 兜底删除压缩包
    if (_downloadedFilePath != null && _downloadedFilePath!.isNotEmpty) {
      final ok = await CleanupUtils.deleteWithRetry(
        File(_downloadedFilePath!),
        retries: 2,
        reason: 'install_success_cleanup',
      );
      debugPrint('[INSTALL-CENTER]   压缩包清理: ${ok ? "已删除" : "删除失败或不存在"}');
    }

    // 2. 完整性校验
    await _verifyInstallIntegrity(task);
  }

  /// 校验解压结果完整性。
  ///
  /// 检查项:目标目录存在、文件数 ≥ 4、至少含 1 个 .exe。
  /// 校验失败记录 CleanupLog 但不抛错(安装已成功,仅警告)。
  Future<void> _verifyInstallIntegrity(InstallTask task) async {
    final checkDir = _dlCore.extractManager.actualGameDir ??
        _dlCore.extractManager.targetGameDir;
    if (checkDir == null || checkDir.isEmpty) {
      debugPrint('[INSTALL-CENTER]   ⚠️ 完整性校验:无目标目录信息,跳过');
      return;
    }

    final dir = Directory(checkDir);
    if (!await dir.exists()) {
      debugPrint('[INSTALL-CENTER]   ⚠️ 完整性校验:目标目录不存在 $checkDir');
      await CleanupLog.append({
        'op': 'integrity_check',
        'target': checkDir,
        'result': 'fail',
        'error': 'directory_not_found',
        'gameId': task.gameId,
      });
      return;
    }

    int fileCount = 0;
    bool hasExe = false;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          fileCount++;
          if (entity.path.toLowerCase().endsWith('.exe')) {
            hasExe = true;
          }
        }
      }
    } catch (e) {
      debugPrint('[INSTALL-CENTER]   ⚠️ 完整性校验:扫描异常 $e');
      await CleanupLog.append({
        'op': 'integrity_check',
        'target': checkDir,
        'result': 'fail',
        'error': e.toString(),
        'gameId': task.gameId,
      });
      return;
    }

    const minFileCount = 4;
    final passed = fileCount >= minFileCount && hasExe;
    debugPrint('[INSTALL-CENTER]   完整性校验: ${passed ? "✅ 通过" : "⚠️ 警告"} '
        '| 文件数=$fileCount (阈值$minFileCount) | 含EXE=$hasExe');

    await CleanupLog.append({
      'op': 'integrity_check',
      'target': checkDir,
      'result': passed ? 'ok' : 'warn',
      'fileCount': fileCount,
      'hasExe': hasExe,
      'gameId': task.gameId,
    });
  }

  Future<bool> _verifyExtractionActuallySucceeded() async {
    try {
      final targetDir = _dlCore.extractManager.targetGameDir;
      if (targetDir == null || targetDir.isEmpty) {
        debugPrint('[INSTALL-CENTER]   验证失败: 目标目录为空，尝试从注册表获取...');
        final registry = LocalGameRegistry.instance;
        final gameTitle = _currentTask?.title ?? '';
        if (gameTitle.isNotEmpty) {
          final game = registry.getGameByTitle(gameTitle);
          if (game != null && game.directoryPath.isNotEmpty) {
            return await _validateDirectory(game.directoryPath);
          }
        }
        return false;
      }

      return await _validateDirectory(targetDir);
    } catch (e) {
      debugPrint('[INSTALL-CENTER]   验证过程异常: $e');
      return false;
    }
  }

  Future<bool> _validateDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      debugPrint('[INSTALL-CENTER]   验证失败: 目标目录不存在: $dirPath');
      return false;
    }

    final entities = await dir.list().toList();
    if (entities.isEmpty) {
      debugPrint('[INSTALL-CENTER]   验证失败: 目标目录为空');
      return false;
    }

    bool hasExe = false;
    bool hasGameData = false;

    for (final entity in entities) {
      if (entity is File) {
        final name = entity.path.toLowerCase();
        if (name.endsWith('.exe') &&
            !name.contains('uninstall') &&
            !name.contains('setup') &&
            !name.contains('installer')) {
          hasExe = true;
        }
        if (name.endsWith('.zip') ||
            name.endsWith('.rar') ||
            name.endsWith('.7z') ||
            name.endsWith('.iso') ||
            name.endsWith('.ald') ||
            name.endsWith('.png') ||
            name.endsWith('.jpg')) {
          hasGameData = true;
        }
      } else if (entity is Directory) {
        hasGameData = true;
      }
    }

    final infoFile = File('$dirPath/${GameDataFormat.gameJsonFileName}');
    final hasInfoFile = await infoFile.exists();

    debugPrint('[INSTALL-CENTER]   目录验证结果:');
    debugPrint('[INSTALL-CENTER]      路径: $dirPath');
    debugPrint('[INSTALL-CENTER]      文件/文件夹数: ${entities.length}');
    debugPrint('[INSTALL-CENTER]      包含EXE: $hasExe');
    debugPrint('[INSTALL-CENTER]      包含游戏数据: $hasGameData');
    debugPrint('[INSTALL-CENTER]      game.json存在: $hasInfoFile');

    if (hasExe || (hasGameData && hasInfoFile) || (entities.length > 3)) {
      debugPrint('[INSTALL-CENTER]   ✅ 验证通过: 目录内容有效');
      return true;
    }

    debugPrint('[INSTALL-CENTER]   验证失败: 目录内容不足');
    return false;
  }

  Future<bool> _checkGameInRegistry() async {
    try {
      final gameTitle = _currentTask?.title ?? _currentTask?.gameId ?? '';
      if (gameTitle.isEmpty) {
        debugPrint('[INSTALL-CENTER]   注册表验证失败: 游戏标题为空');
        return false;
      }

      final registry = LocalGameRegistry.instance;
      final game = registry.getGameByTitle(gameTitle);

      if (game != null) {
        final dir = Directory(game.directoryPath);
        if (await dir.exists()) {
          final entities = await dir.list().toList();
          if (entities.isNotEmpty) {
            debugPrint('[INSTALL-CENTER]   ✅ 注册表验证通过:');
            debugPrint('[INSTALL-CENTER]      游戏标题: ${game.title}');
            debugPrint('[INSTALL-CENTER]      目录路径: ${game.directoryPath}');
            debugPrint('[INSTALL-CENTER]      文件数量: ${entities.length}');
            return true;
          }
        }
      }

      debugPrint('[INSTALL-CENTER]   注册表验证失败: 游戏未在注册表中找到或目录无效');
      return false;
    } catch (e) {
      debugPrint('[INSTALL-CENTER]   注册表验证异常: $e');
      return false;
    }
  }

  Future<bool> _ultimateSuccessVerification() async {
    debugPrint('[INSTALL-CENTER] ========== 终极兜底验证 ==========');

    try {
      final gameTitle = _currentTask?.title ?? _currentTask?.gameId ?? '';
      debugPrint('[INSTALL-CENTER]   待验证游戏: $gameTitle');

      if (gameTitle.isEmpty) {
        debugPrint('[INSTALL-CENTER]   ❌ 游戏标题为空');
        return false;
      }

      final registry = LocalGameRegistry.instance;

      bool registryCheck = false;
      String? foundDirPath;

      final game = registry.getGameByTitle(gameTitle);
      if (game != null) {
        foundDirPath = game.directoryPath;
        if (foundDirPath.isNotEmpty) {
          final dir = Directory(foundDirPath);
          if (await dir.exists()) {
            final entities = await dir.list().toList();
            if (entities.isNotEmpty) {
              registryCheck = true;
              debugPrint('[INSTALL-CENTER]   ✅ 注册表验证: 游戏已入库');
              debugPrint('[INSTALL-CENTER]      目录: $foundDirPath');
              debugPrint('[INSTALL-CENTER]      文件数: ${entities.length}');
            }
          }
        }
      }

      bool directoryCheck = false;
      final targetDir = _dlCore.extractManager.targetGameDir;
      String? checkedDirPath;

      if (targetDir != null && targetDir.isNotEmpty) {
        checkedDirPath = targetDir;
      } else if (foundDirPath != null && foundDirPath.isNotEmpty) {
        checkedDirPath = foundDirPath;
      }

      if (checkedDirPath != null && checkedDirPath.isNotEmpty) {
        final dir = Directory(checkedDirPath);
        if (await dir.exists()) {
          final entities = await dir.list().toList();
          if (entities.length >= 2) {
            directoryCheck = true;
            debugPrint('[INSTALL-CENTER]   ✅ 目录验证: 存在且非空');
            debugPrint('[INSTALL-CENTER]      路径: $checkedDirPath');
            debugPrint('[INSTALL-CENTER]      条目数: ${entities.length}');
          }
        }
      }

      bool extractStatusCheck = false;
      final extractStatus = _dlCore.extractManager.status;
      if (extractStatus == ExtractStatus.completed) {
        extractStatusCheck = true;
        debugPrint('[INSTALL-CENTER]   ✅ 状态验证: ExtractStatus.completed');
      } else {
        debugPrint(
            '[INSTALL-CENTER]   ⚠️ 状态验证: $extractStatus（非completed但可能仍成功）');
      }

      final finalResult = registryCheck || directoryCheck;

      debugPrint('[INSTALL-CENTER] =======================================');
      if (finalResult) {
        debugPrint('[INSTALL-CENTER] ✅✅✅ 终极兜底验证通过！游戏安装成功！');
        debugPrint('[INSTALL-CENTER]   注册表: ${registryCheck ? "✅" : "❌"}');
        debugPrint('[INSTALL-CENTER]   目录: ${directoryCheck ? "✅" : "❌"}');
        debugPrint('[INSTALL-CENTER]   状态: ${extractStatusCheck ? "✅" : "⚠️"}');
      } else {
        debugPrint('[INSTALL-CENTER] ❌❌❌ 终极兜底验证失败：游戏确实未安装成功');
        debugPrint('[INSTALL-CENTER]   注册表: ${registryCheck ? "✅" : "❌"}');
        debugPrint('[INSTALL-CENTER]   目录: ${directoryCheck ? "✅" : "❌"}');
        debugPrint('[INSTALL-CENTER]   状态: ${extractStatusCheck ? "✅" : "❌"}');
      }
      debugPrint('[INSTALL-CENTER] =======================================');

      return finalResult;
    } catch (e) {
      debugPrint('[INSTALL-CENTER] ❌ 终极兜底验证过程异常: $e');
      return false;
    }
  }

  Future<void> _rollback(String reason) async {
    debugPrint('[INSTALL-CENTER] 🔄 开始失败回滚 | 原因: $reason');

    _emitPhase(InstallPhase.failed);
    _emitError(reason);

    try {
      if (_dlCore.status == DownloadStatus.downloading) {
        debugPrint('[INSTALL-CENTER]   回滚步骤1：取消进行中的下载...');
        _dlCore.cancel();
      }

      debugPrint('[INSTALL-CENTER]   回滚步骤2：清理已下载文件...');
      if (_downloadedFilePath != null && _downloadedFilePath!.isNotEmpty) {
        final dlFile = File(_downloadedFilePath!);
        if (await dlFile.exists()) {
          await dlFile.delete();
          debugPrint('[INSTALL-CENTER]   ✅ 已删除: $_downloadedFilePath');
        }
      }

      // 步骤2.5:扫描 downloads 目录,清理与当前 gameId 相关的孤儿压缩包残留
      debugPrint('[INSTALL-CENTER]   回滚步骤2.5：扫描 downloads 孤儿压缩包...');
      try {
        final dlDir = Directory(PathHelper.downloadsDir);
        if (await dlDir.exists() && _currentTask != null) {
          final gameId = _currentTask!.gameId;
          final title = _currentTask!.title;
          final now = DateTime.now();
          await for (final entity in dlDir.list(followLinks: false)) {
            if (entity is File) {
              final name = entity.path.toLowerCase();
              // 仅处理压缩包格式,跳过 .tmp 分片文件
              final isArchive = name.endsWith('.zip') ||
                  name.endsWith('.rar') ||
                  name.endsWith('.7z') ||
                  name.endsWith('.tar');
              if (!isArchive) continue;
              // 匹配 gameId 或 title(忽略大小写)
              final matchesTask = name.contains(gameId.toLowerCase()) ||
                  name.contains(title.toLowerCase());
              if (!matchesTask) continue;
              // 仅清理 24 小时内修改的文件(避免误删旧的无关压缩包)
              try {
                final stat = await entity.stat();
                if (now.difference(stat.modified).inHours < 24) {
                  await entity.delete();
                  debugPrint('[INSTALL-CENTER]   ✅ 已删除孤儿压缩包: ${entity.path}');
                }
              } catch (e) {
                debugPrint(
                    '[INSTALL-CENTER]   ⚠️ 删除孤儿压缩包失败: ${entity.path} | $e');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[INSTALL-CENTER]   ⚠️ 扫描孤儿压缩包异常: $e');
      }

      debugPrint('[INSTALL-CENTER]   回滚步骤3：清理不完整目录...');
      // 优先清理实际解压目录(可能是用户自定义路径),再清理元数据目录
      final actualDir = _dlCore.extractManager.actualGameDir;
      final targetDir = _dlCore.extractManager.targetGameDir;

      if (actualDir != null && actualDir.isNotEmpty) {
        final dir = Directory(actualDir);
        if (await dir.exists()) {
          // 安全检查:仅当目录为空或不含游戏数据文件时才删除
          // (复用 _cleanupOnFailure 步骤6 的保护逻辑,避免误删用户已有数据)
          try {
            final entities = await dir.list().toList();
            bool hasGameData = false;
            if (entities.isNotEmpty) {
              for (final e in entities) {
                if (e is File) {
                  final fname = e.path.toLowerCase();
                  if (fname.endsWith('.exe') ||
                      fname.endsWith('.ctgame') ||
                      fname.endsWith('.json') ||
                      fname.endsWith('.dat') ||
                      fname.endsWith('.xp3') ||
                      fname.endsWith('.ks') ||
                      fname.endsWith('.ald') ||
                      fname.endsWith('.arc') ||
                      fname.endsWith('.pna')) {
                    hasGameData = true;
                    break;
                  }
                }
              }
            }
            if (!hasGameData) {
              await dir.delete(recursive: true);
              debugPrint('[INSTALL-CENTER]   ✅ 已删除实际解压目录: $actualDir');
            } else {
              debugPrint('[INSTALL-CENTER]   ⚠️ 实际解压目录含游戏数据,保留: $actualDir');
            }
          } catch (e) {
            debugPrint('[INSTALL-CENTER]   ⚠️ 清理实际解压目录异常: $actualDir | $e');
          }
        }
      }

      // 清理元数据目录(若与实际解压目录不同)
      if (targetDir != null && targetDir.isNotEmpty && targetDir != actualDir) {
        final dir = Directory(targetDir);
        if (await dir.exists()) {
          try {
            await dir.delete(recursive: true);
            debugPrint('[INSTALL-CENTER]   ✅ 已删除元数据目录: $targetDir');
          } catch (e) {
            debugPrint('[INSTALL-CENTER]   ⚠️ 清理元数据目录异常: $targetDir | $e');
          }
        }
      }

      for (int i = 0;; i++) {
        final tempDir =
            Directory('${_dlCore.extractManager.gamesBaseDir}/._temp_layer_$i');
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        } else {
          break;
        }
      }

      debugPrint('[INSTALL-CENTER] ✅ 回滚完成');
    } catch (e) {
      debugPrint('[INSTALL-CENTER] ⚠️ 回滚过程异常（非致命）: $e');
    }

    _resetBusyState();
  }

  void cancelCurrentTask() {
    if (!_isBusy) {
      debugPrint('[INSTALL-CENTER] ⚠️ 当前无活动任务，无法取消');
      return;
    }

    debugPrint('[INSTALL-CENTER] ❌ 用户主动取消安装任务 | 游戏: ${_currentTask?.title}');

    if (_phase == InstallPhase.downloading) {
      _dlCore.cancel();
    } else if (_phase == InstallPhase.extracting) {
      _dlCore.extractManager.cancel();
    }

    _emitPhase(InstallPhase.cancelled);
    _emitProgress(const InstallProgress(statusMessage: '已取消'));
    _resetBusyState();
  }

  void _resetBusyState() {
    _isBusy = false;
    if (_phase == InstallPhase.completed ||
        _phase == InstallPhase.failed ||
        _phase == InstallPhase.cancelled) {
      Future.delayed(const Duration(seconds: 2), () {
        if (_phase == InstallPhase.completed ||
            _phase == InstallPhase.failed ||
            _phase == InstallPhase.cancelled) {
          _emitPhase(InstallPhase.idle);
          _currentTask = null;
          _downloadedFilePath = null;
          _errorMessage = null;
          _emitProgress(const InstallProgress());
          debugPrint('[INSTALL-CENTER] 状态重置为空闲');
        }
      });
    }
  }

  bool get mounted => _phaseListeners.isNotEmpty || _isBusy;

  bool isGameInstalled(String gameId) {
    if (_currentTask != null &&
        _currentTask!.gameId == gameId &&
        (_phase == InstallPhase.completed ||
            _phase == InstallPhase.extracting)) {
      return true;
    }
    return false;
  }

  void dispose() {
    cancelCurrentTask();
    removeAllListeners();
    _dlCore.removeAllListeners();
    _dlCore.extractManager.removeListeners();
  }

  DownloadCore get dlCore => _dlCore;
}
