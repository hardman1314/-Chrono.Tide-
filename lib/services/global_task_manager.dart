import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'download_core.dart';
import 'extract_manager.dart';

enum GlobalTaskPhase {
  idle,
  downloading,
  extracting,
  completed,
  failed,
  cancelled
}

class GlobalTaskInfo {
  final String gameId;
  final String gameTitle;
  final GlobalTaskPhase phase;
  final double downloadPercent;
  final double extractPercent;
  final String downloadSpeed;
  final String statusMessage;

  const GlobalTaskInfo({
    required this.gameId,
    required this.gameTitle,
    required this.phase,
    this.downloadPercent = 0.0,
    this.extractPercent = 0.0,
    this.downloadSpeed = '0 B/s',
    this.statusMessage = '',
  });

  bool get isActive =>
      phase == GlobalTaskPhase.downloading ||
      phase == GlobalTaskPhase.extracting ||
      phase == GlobalTaskPhase.completed ||
      phase == GlobalTaskPhase.failed;

  bool get isRunning =>
      phase == GlobalTaskPhase.downloading ||
      phase == GlobalTaskPhase.extracting;

  double get displayPercent {
    if (phase == GlobalTaskPhase.downloading) return downloadPercent;
    if (phase == GlobalTaskPhase.extracting) return extractPercent;
    if (phase == GlobalTaskPhase.completed) return 100.0;
    return 0.0;
  }

  String get taskLabel {
    switch (phase) {
      case GlobalTaskPhase.downloading:
        return '下载中';
      case GlobalTaskPhase.extracting:
        return '解压中';
      case GlobalTaskPhase.completed:
        return '安装完成';
      case GlobalTaskPhase.failed:
        return '解压失败';
      case GlobalTaskPhase.cancelled:
        return '已取消';
      default:
        return '';
    }
  }
}

class GlobalTaskManager {
  static final GlobalTaskManager _instance = GlobalTaskManager._internal();
  static GlobalTaskManager get instance => _instance;

  GlobalTaskManager._internal();

  final DownloadCore _dlCore = DownloadCore();

  String _activeGameId = '';
  String _activeGameTitle = '';

  GlobalTaskPhase? _phaseOverride;
  Timer? _autoClearTimer;

  final List<void Function(GlobalTaskInfo)> _taskListeners = [];

  DownloadCore get dlCore => _dlCore;

  String get activeGameId => _activeGameId;
  String get activeGameTitle => _activeGameTitle;
  bool get hasActiveTask => isRunning;

  bool get isRunning {
    if (_phaseOverride != null) {
      final p = _phaseOverride!;
      return p == GlobalTaskPhase.downloading ||
          p == GlobalTaskPhase.extracting;
    }
    return _dlCore.status == DownloadStatus.downloading ||
        ExtractManager.hasActiveTask;
  }

  GlobalTaskPhase get currentPhase {
    if (_phaseOverride != null) return _phaseOverride!;

    if (ExtractManager.hasActiveTask) return GlobalTaskPhase.extracting;
    switch (_dlCore.status) {
      case DownloadStatus.downloading:
        return GlobalTaskPhase.downloading;
      case DownloadStatus.completed:
        if (_dlCore.extractManager.status == ExtractStatus.completed ||
            _dlCore.extractManager.status == ExtractStatus.idle) {
          return GlobalTaskPhase.completed;
        }
        return GlobalTaskPhase.extracting;
      case DownloadStatus.failed:
        return GlobalTaskPhase.failed;
      case DownloadStatus.cancelled:
        return GlobalTaskPhase.cancelled;
      default:
        return GlobalTaskPhase.idle;
    }
  }

  void addTaskListener(void Function(GlobalTaskInfo) listener) {
    _taskListeners.add(listener);
  }

  void removeTaskListener(void Function(GlobalTaskInfo) listener) {
    _taskListeners.remove(listener);
  }

  void _notifyListeners() {
    final info = GlobalTaskInfo(
      gameId: _activeGameId,
      gameTitle: _activeGameTitle,
      phase: currentPhase,
      downloadPercent: _dlCore.progress?.percent ?? 0.0,
      extractPercent: _dlCore.extractManager.progress?.percent ?? 0.0,
      downloadSpeed: _dlCore.progress?.speed ?? '0 B/s',
      statusMessage: _dlCore.extractManager.progress?.message ?? '',
    );
    for (final l in _taskListeners) {
      l(info);
    }
  }

  void init() {
    _dlCore.addStatusListener(_onDlStatusChanged);
    _dlCore.addProgressListener(_onDlProgressChanged);
    _dlCore.extractManager.addStatusListener(_onExtractStatusChanged);
    _dlCore.extractManager.addProgressListener(_onExtractProgressChanged);
    _dlCore.extractManager.addSuccessListener(_onExtractSuccess);
    _dlCore.extractManager.addFailureListener(_onExtractFailure);
    debugPrint('[GLOBAL-TASK] ✅ 全局任务管理器初始化完成');
  }

  Future<bool> startDownload({
    required String url,
    required String gameId,
    String? fileName,
    String? title,
    String? description,
    String? coverUrl,
    List<String>? tags,
  }) async {
    if (_dlCore.status == DownloadStatus.downloading ||
        ExtractManager.hasActiveTask) {
      debugPrint('[GLOBAL-TASK] ⚠️ 已有任务在执行，拒绝重复请求 | 当前游戏: $_activeGameId');
      return false;
    }

    _autoClearTimer?.cancel();
    _autoClearTimer = null;
    _phaseOverride = null;
    _activeGameId = gameId;
    _activeGameTitle = title ?? gameId;
    debugPrint(
        '[GLOBAL-TASK] 🚀 启动下载任务 | gameId=$gameId | title=$activeGameTitle');

    await _dlCore.start(
      url: url,
      gameId: gameId,
      fileName: fileName,
      title: title,
      description: description,
      coverUrl: coverUrl,
      tags: tags,
    );
    return true;
  }

  bool isGameActive(String gameId) {
    if (gameId.isEmpty || _activeGameId.isEmpty) return false;
    return gameId == _activeGameId && hasActiveTask;
  }

  void cancelCurrent() {
    if (_dlCore.status == DownloadStatus.downloading) {
      debugPrint('[GLOBAL-TASK] 取消当前下载任务');
      _dlCore.cancel();
    } else if (ExtractManager.hasActiveTask) {
      debugPrint('[GLOBAL-TASK] 取消当前解压任务');
      _dlCore.extractManager.cancel();
    }
  }

  void reset() {
    _autoClearTimer?.cancel();
    _autoClearTimer = null;
    _phaseOverride = null;
    _activeGameId = '';
    _activeGameTitle = '';
    _dlCore.reset();
    debugPrint('[GLOBAL-TASK] 状态已重置');
  }

  void _onDlStatusChanged(DownloadStatus status) {
    debugPrint('[GLOBAL-TASK] 下载状态变更: $status | 游戏: $_activeGameTitle');
    _notifyListeners();
  }

  void _onDlProgressChanged(DownloadProgress progress) {
    _notifyListeners();
  }

  void _onExtractStatusChanged(ExtractStatus status) {
    debugPrint('[GLOBAL-TASK] 解压状态变更: $status | 游戏: $_activeGameTitle');
    _notifyListeners();
  }

  void _onExtractProgressChanged(ExtractProgress progress) {
    _notifyListeners();
  }

  void _onExtractSuccess() {
    debugPrint('[GLOBAL-TASK] 🎉 解压成功回调 | 游戏: $_activeGameTitle');

    _phaseOverride = GlobalTaskPhase.completed;
    _notifyListeners();

    _autoClearTimer?.cancel();
    _autoClearTimer = Timer(const Duration(seconds: 3), () {
      debugPrint('[GLOBAL-TASK] ⏰ 完成展示结束，自动清除任务状态');
      _phaseOverride = null;
      _activeGameId = '';
      _activeGameTitle = '';
      _notifyListeners();
    });
  }

  void _onExtractFailure(String errorMsg) {
    debugPrint('[GLOBAL-TASK] ❌ 解压失败回调 | 游戏: $_activeGameTitle | $errorMsg');

    _phaseOverride = GlobalTaskPhase.failed;
    _notifyListeners();

    _autoClearTimer?.cancel();
    _autoClearTimer = Timer(const Duration(seconds: 5), () {
      debugPrint('[GLOBAL-TASK] ⏰ 失败展示结束，自动清除任务状态');
      _phaseOverride = null;
      _activeGameId = '';
      _activeGameTitle = '';
      _notifyListeners();
    });
  }
}
