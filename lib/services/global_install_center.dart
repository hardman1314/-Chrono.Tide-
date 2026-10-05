import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'download_core.dart';
import 'extract_manager.dart';
import 'local_game_registry.dart';
import 'game_data_format.dart';
import 'path_validator.dart';
import 'install_stats_service.dart';
import 'unpack_plan.dart';
import 'unpack_store.dart';
import '../core/path_helper.dart';
import 'interrupt_cleanup.dart';
import 'network_status_service.dart';
import 'storage/cleanup_utils.dart';

enum InstallPhase {
  idle,
  downloading,
  extracting,
  // ★ 解压流水线（join_unpack_install_center_pipeline.md）：本地压缩包解压
  // 完成、等待用户在「确认文件夹名」弹窗中决策。此相位队列不推进——
  // 成功终态 = 确认入库完成（或明确放弃入库），而非解压 completed。
  awaitingConfirmation,
  completed,
  failed,
  cancelled
}

/// 任务类型：download = 探索页云端下载安装；localArchive = 单文件导入的
/// 本地压缩包解压入库（解压流水线重构，2026-10-05 用户拍板）。
enum InstallTaskKind { download, localArchive }

/// 本地压缩包解压完成后「确认文件夹名」弹窗的用户决策
/// （服务层等价物；UI 层的 ExtractFinishDecision 由 main_container 转换）。
class UnpackFinishOutcome {
  /// 用户编辑后的最终文件夹名；null/空 = 保持原名
  final String? finalDirName;

  /// 是否删除源压缩包（弹窗勾选，默认保留）
  final bool deleteSourceArchive;

  const UnpackFinishOutcome({this.finalDirName, this.deleteSourceArchive = false});
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

  /// 横幅封面 URL（云端 games.bannerUrl，2026-10-05）：入库写 game.json
  /// banner_file，与本地横幅封面系统对齐；缺失时正常回退竖封面。
  final String? bannerUrl;
  final List<String>? tags;

  /// ★ 解压流水线：云端下载任务的直链；localArchive 任务为 null
  /// （源压缩包路径走 [localArchivePath]）。
  final String? downloadUrl;
  final String? developer;
  final String? customGameLocation;
  final List<String>? screenshotUrls;
  // 副标题：通常为日文原版标题，入库时写入 game.json 的 subtitle 字段
  final String? subtitle;

  /// ★ 解压流水线：任务类型（默认云端下载，存量调用点零改动）
  final InstallTaskKind kind;

  /// ★ 解压流水线：本地压缩包/分卷首卷路径（kind == localArchive 时必填；
  /// 解压输入源 = 计划驱动的 ExtractManager.start(archivePath)）。
  final String? localArchivePath;

  /// ★ 解压流水线：计划窗确认产出的解压计划（null = 无计划直解）。
  final UnpackPlan? unpackPlan;

  /// ★ 解压流水线：表单本地封面文件路径（区别于云端 [coverUrl]），
  /// 入库写 game.json 时作为 coverFilePath。
  final String? localCoverFilePath;

  /// ★ 解压流水线：导入原标题（从文件名/文件夹名提取，双标题持久化用）
  final String? originalTitle;

  /// ★ 解压流水线：元数据抓取的标准名（双标题切换选项，可空）
  final String? metadataTitle;
  final String? metadataSource;
  final String? metadataSourceId;

  /// ★ P0-4：云盘签名直链会过期。提供该回调后，下载重试遇到 401/403/404/416
  /// 时会重新解析直链，避免长时间安装中途失败后无法自愈。
  final Future<String?> Function()? urlResolver;

  /// ★ 2026-09-26 安装审计 P1-1：下载包预期体积（字节）。
  /// 由 UI 层经 FileSizePrefetchService 预取后填入；用于安装前的磁盘空间
  /// 门槛校验。null = 未知（仅校验磁盘可访问性）。
  final int? expectedSizeBytes;

  const InstallTask({
    required this.gameId,
    required this.title,
    this.description,
    this.coverUrl,
    this.bannerUrl,
    this.tags,
    this.downloadUrl,
    this.developer,
    this.customGameLocation,
    this.screenshotUrls,
    this.subtitle,
    this.kind = InstallTaskKind.download,
    this.localArchivePath,
    this.unpackPlan,
    this.localCoverFilePath,
    this.originalTitle,
    this.metadataTitle,
    this.metadataSource,
    this.metadataSourceId,
    this.urlResolver,
    this.expectedSizeBytes,
  });
}

/// 排队中的安装任务包装：持有 Completer 让 submitTask 的 Future
/// 在该任务实际执行完毕（而非入队）时才 resolve，保持调用方语义不变
class _QueuedInstallTask {
  final InstallTask task;
  final Completer<bool> completer;

  _QueuedInstallTask(this.task, this.completer);
}

class GlobalInstallCenter {
  static final GlobalInstallCenter _instance = GlobalInstallCenter._internal();
  static GlobalInstallCenter get instance => _instance;

  GlobalInstallCenter._internal();

  /// 兜底空实例：无活跃任务时 dlCore getter 返回它
  /// （custom_title_bar 退出清理等只读引用需要非空 DownloadCore）
  final DownloadCore _dlCore = DownloadCore();

  /// 当前活跃任务的下载核心：每个任务独立实例，
  /// 彻底隔离 ExtractManager 状态（targetGameDir/actualGameDir），
  /// 避免任务 B 回滚时误读任务 A 残留目录导致误删
  DownloadCore? _activeDlCore;

  /// 串行安装队列：一次只执行一个任务，其余排队依次推进
  final List<_QueuedInstallTask> _queue = [];

  /// 终态展示后自动推进队列的定时器
  Timer? _queueAdvanceTimer;

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
  final List<void Function()> _queueListeners = [];

  InstallPhase get phase => _phase;
  InstallTask? get currentTask => _currentTask;
  String? get downloadedFilePath => _downloadedFilePath;
  String? get errorMessage => _errorMessage;
  bool get isBusy => _isBusy;
  bool get isRunning =>
      _phase == InstallPhase.downloading ||
      _phase == InstallPhase.extracting ||
      _phase == InstallPhase.awaitingConfirmation;
  InstallProgress get progress => _progress;

  // ============ ★ 解压流水线回调（main_container 注入）============

  /// 执行期统一决策弹窗（password/strategy/ambiguity/corrupt/body）。
  /// 每个任务的独立 ExtractManager 在解压前接线到此；未注入时决策请求
  /// 返回 null（流程按用户放弃处理，与旧行为一致）。
  Future<ExtractDecisionResult?> Function(ExtractDecisionRequest request)?
      onUnpackDecisionRequest;

  /// 解压完成后的「确认文件夹名 + 是否删源包」弹窗。
  /// 返回决策（改名/删源包）；null = 用户取消（产物保留、不入库）。
  /// ★ 此 Future 挂起期间任务停在 awaitingConfirmation 相位，队列不推进。
  Future<UnpackFinishOutcome?> Function({
    required InstallTask task,
    required String extractedDir,
    required String sourceArchivePath,
  })? onUnpackFinishConfirm;

  /// 本地压缩包确认入库完成（game.json 已写、注册表已登记）→ 成功提示
  void Function(String title)? onUnpackImportCompleted;

  /// 本地压缩包解压完成但用户放弃入库 → 说明性提示
  void Function(String message)? onUnpackImportCancelled;

  /// ★ 2026-10-05 实机反馈（流程语义修正）：解压完成 ≠ 入库。
  /// 确认窗（改名/删源包）只是**解压流程**的收尾——确认后产物交给
  /// 添加页表单，数据填写与「确认入库」完全由用户自行操作。
  /// main_container 收到后切到添加页并预填产物目录（JoinController
  /// .pendingExtractedDir 通道），toast 引导用户审核数据。
  void Function(String extractedDir, String suggestedName)?
      onUnpackReadyForManualImport;

  // ============ ★ 系统操作日志（2026-10-05 需求 #6）============
  //
  // 仅内存环形缓冲（上限 200 行），**不落盘**；语义 = 当前任务的操作
  // 日志（新任务开始时清空）。内容来自 ExtractManager.onOpLog 钩子：
  // 改后缀试解、调用解压工具、密码队列组装、系统判定等用户可读动作。
  // 密码明文**禁止**进入此通道（与 _log 同一安全纪律）。

  static const int _maxOpLogLines = 200;
  final List<String> _opLog = <String>[];
  final List<void Function()> _opLogListeners = [];

  /// 当前任务的操作日志（时间戳前缀，旧→新）
  List<String> get opLog => List.unmodifiable(_opLog);

  void addOpLogListener(void Function() listener) =>
      _opLogListeners.add(listener);

  void removeOpLogListener(void Function() listener) =>
      _opLogListeners.remove(listener);

  void _notifyOpLogChanged() {
    for (final l in _opLogListeners) {
      l();
    }
  }

  /// 服务层动作日志入口（ExtractManager.onOpLog 接线到此）
  void emitOpLog(String message) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}'
        ':${now.minute.toString().padLeft(2, '0')}'
        ':${now.second.toString().padLeft(2, '0')}';
    _opLog.add('[$ts] $message');
    while (_opLog.length > _maxOpLogLines) {
      _opLog.removeAt(0);
    }
    _notifyOpLogChanged();
  }

  /// 新任务开始时清空（面板只看当前任务）
  void clearOpLog() {
    if (_opLog.isEmpty) return;
    _opLog.clear();
    _notifyOpLogChanged();
  }

  /// 兼容旧引用（custom_title_bar 退出清理）：优先返回活跃实例
  DownloadCore get dlCore => _activeDlCore ?? _dlCore;

  /// 排队中的任务列表（不含当前正在执行的）
  List<InstallTask> get queuedTasks =>
      _queue.map((q) => q.task).toList(growable: false);

  int get queueLength => _queue.length;

  /// 指定游戏是否在排队中
  bool isQueued(String gameId) => _queue.any((q) => q.task.gameId == gameId);

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

  /// 队列变更通知（入队/出队/移除/清空时触发，供安装中心等 UI 刷新队列列表）
  void addQueueListener(void Function() listener) =>
      _queueListeners.add(listener);

  void removeQueueListener(void Function() listener) =>
      _queueListeners.remove(listener);

  void _notifyQueueChanged() {
    for (final l in _queueListeners) {
      l();
    }
  }

  void removeAllListeners() {
    _phaseListeners.clear();
    _progressListeners.clear();
    _errorListeners.clear();
    _successListeners.clear();
    _queueListeners.clear();
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

  /// 提交安装任务（串行队列入口）。
  ///
  /// - 空闲时：立即执行
  /// - 忙碌时：加入队列等待依次执行（不再拒绝）
  /// - 重复提交（正在安装或已在队列中）：拒绝并返回 false
  ///
  /// ★ 2026-09-26 P1-4：提交前的重复性快速查询（与 [submitTask] 内部判据
  /// 一致）。供共享安装流在同步段使用——检查与提交之间无 await，
  /// 单 isolate 下无竞态，可把「已在队列」作为同步结果返回给调用方。
  bool isQueuedOrRunning(String gameId) =>
      (_currentTask?.gameId == gameId && _isBusy) || isQueued(gameId);

  /// 返回的 Future 在该任务实际执行完毕时 resolve，
  /// 入队任务与直接执行任务的调用方语义完全一致。
  Future<bool> submitTask(InstallTask task) async {
    // 去重：同一游戏正在安装或已在队列中 → 拒绝
    final duplicated = (_currentTask?.gameId == task.gameId && _isBusy) ||
        isQueued(task.gameId);
    if (duplicated) {
      debugPrint(
          '[INSTALL-CENTER] ⚠️ 重复提交，拒绝 | 游戏: ${task.title} | ID: ${task.gameId}');
      return false;
    }

    if (_isBusy) {
      // 忙碌：入队等待，终态展示后自动依次推进
      final queued = _QueuedInstallTask(task, Completer<bool>());
      _queue.add(queued);
      _notifyQueueChanged();
      debugPrint(
          '[INSTALL-CENTER] 📋 任务入队 | 游戏: ${task.title} | 队列位置: ${_queue.length} | 当前执行: ${_currentTask?.title}');
      return queued.completer.future;
    }

    debugPrint(
        '[INSTALL-CENTER] ✅ 接收新安装任务 | 游戏: ${task.title} | ID: ${task.gameId}');
    return _executeTask(task);
  }

  /// 执行单个安装任务（原 submitTask 主体）
  Future<bool> _executeTask(InstallTask task,
      {Completer<bool>? completer}) async {
    _currentTask = task;
    _errorMessage = null;
    _downloadedFilePath = null;
    _isBusy = true;
    _customGameLocation = task.customGameLocation;
    // 每任务独立下载核心：隔离 ExtractManager 状态，防止回滚误删其他任务目录
    _activeDlCore = DownloadCore();
    // ★ 系统操作日志接线（安装中心日志面板实时展示，仅内存不落盘）；
    //   新任务开始时清空上一任务的日志。
    _activeDlCore!.extractManager.onOpLog = emitOpLog;
    clearOpLog();

    // ★ 2026-09-26 安装审计 P2-4：安装提交此前无网络前置校验——离线时白进
    // 下载阶段再失败。探索库资源经 OpenList 转发到公网网盘，公网不可达则
    // 下载必败，提前拦截并说明。
    // ★ 解压流水线：网络预检仅对云端下载任务——本地压缩包导入离线必须可用。
    if (task.kind == InstallTaskKind.download) {
      if (!NetworkStatusService.instance.isOnline) {
        _isBusy = false;
        _errorMessage = '当前处于离线状态，无法连接云端资源，请检查网络后重试';
        _emitPhase(InstallPhase.failed);
        _emitError(_errorMessage!);
        _completeTask(completer, false);
        _resetBusyState();
        return false;
      }
      if (task.downloadUrl == null || task.downloadUrl!.isEmpty) {
        _isBusy = false;
        _errorMessage = '下载任务缺少下载地址';
        _emitPhase(InstallPhase.failed);
        _emitError(_errorMessage!);
        _completeTask(completer, false);
        _resetBusyState();
        return false;
      }
    } else if (task.localArchivePath == null ||
        task.localArchivePath!.isEmpty) {
      _isBusy = false;
      _errorMessage = '本地解压任务缺少源压缩包路径';
      _emitPhase(InstallPhase.failed);
      _emitError(_errorMessage!);
      _completeTask(completer, false);
      _resetBusyState();
      return false;
    }

    // ★ 2026-09-26 安装审计 P1-1：磁盘空间预检此前是双缺口——
    // ① path_validator.getDiskSpaceInfo 是桩（恒 -1，真实磁盘从未被查询）；
    // ② 仅自定义路径走检查分支，默认安装路径完全不预检。
    // 现统一对「实际落盘盘符」做真实空间校验；下载包体积未知
    // （expectedSizeBytes 为空）时仅校验磁盘可访问性。
    final hasCustomLocation =
        _customGameLocation != null && _customGameLocation!.isNotEmpty;
    if (hasCustomLocation) {
      debugPrint('[INSTALL-CENTER] 🆕 自定义本体位置: $_customGameLocation');

      final pathValidation =
          PathValidator.validateCustomGameLocation(_customGameLocation);
      if (!pathValidation.isValid) {
        _isBusy = false;
        _errorMessage = '路径验证失败: ${pathValidation.message}';
        _emitPhase(InstallPhase.failed);
        _emitError(_errorMessage!);
        _completeTask(completer, false);
        _resetBusyState();
        return false;
      }
    } else {
      debugPrint('[INSTALL-CENTER] 使用默认安装路径');
    }

    final targetDirForSpace = hasCustomLocation
        ? _customGameLocation!
        : LocalGameRegistry.gamesBaseDir;
    final diskSpace = await PathValidator.getDiskSpaceInfo(targetDirForSpace);
    if (!diskSpace.isAvailable) {
      _isBusy = false;
      _errorMessage = '无法访问目标磁盘: ${diskSpace.error}';
      _emitPhase(InstallPhase.failed);
      _emitError(_errorMessage!);
      _completeTask(completer, false);
      _resetBusyState();
      return false;
    }
    final expectedBytes = task.expectedSizeBytes ?? 0;
    if (expectedBytes > 0 &&
        diskSpace.freeSpaceBytes >= 0 &&
        diskSpace.freeSpaceBytes < (expectedBytes * 1.05).round()) {
      _isBusy = false;
      _errorMessage = '目标磁盘空间不足：下载包约 '
          '${PathValidator.formatFileSize(expectedBytes)}，目标盘仅剩 '
          '${PathValidator.formatFileSize(diskSpace.freeSpaceBytes)}'
          '（解压后还需额外空间）';
      _emitPhase(InstallPhase.failed);
      _emitError(_errorMessage!);
      _completeTask(completer, false);
      _resetBusyState();
      return false;
    }

    try {
      // ★ 解压流水线：下载段仅云端下载任务执行；本地压缩包任务直接进解压。
      if (task.kind == InstallTaskKind.download) {
        _setupDownloadListeners();
        _emitPhase(InstallPhase.downloading);
        _emitProgress(const InstallProgress(statusMessage: '正在获取链接...'));

        debugPrint('[INSTALL-CENTER] 步骤1/3：开始下载...');
        await _startDownload(task);

        if (_phase == InstallPhase.cancelled) {
          _completeTask(completer, false);
          return false;
        }
      }

      debugPrint('[INSTALL-CENTER] 步骤2/3：开始解压...');
      _emitPhase(InstallPhase.extracting);
      await _startExtraction();

      if (_phase == InstallPhase.cancelled) {
        _completeTask(completer, false);
        return false;
      }

      // ★ 解压流水线：本地压缩包任务不在此直接终态——解压完成后进入
      // 确认入库环节（文件夹名确认 + 元数据写入 + 注册 + 习惯记忆 +
      // 删源包勾选），确认窗收口才算任务完成。
      if (task.kind == InstallTaskKind.localArchive) {
        return await _finishLocalArchive(task, completer: completer);
      }

      debugPrint('[INSTALL-CENTER] 步骤3/3：入库完成！');
      _emitPhase(InstallPhase.completed);
      _emitProgress(const InstallProgress(
        downloadPercent: 100.0,
        extractPercent: 100.0,
        statusMessage: '安装完成',
      ));

      await _onInstallSuccess(task);
      _emitSuccess();
      _completeTask(completer, true);
      _resetBusyState();
      return true;
    } catch (e) {
      debugPrint('[INSTALL-CENTER] ⚠️ 安装流程捕获异常: $e');

      // ★ 解压流水线：本地压缩包任务以确认入库窗为成功闸门——走到 catch
      // 即解压/入库链路真实失败。跳过「目录已存在」式终极兜底验证
      //（半途而废的产物目录会让兜底误判成功），直接回滚清理；
      // 源压缩包不受回滚影响（_rollback 只扫 downloads 目录孤儿包）。
      if (task.kind == InstallTaskKind.localArchive) {
        debugPrint('[INSTALL-CENTER] ❌ 本地解压任务失败：回滚清理');
        await _rollback(e.toString());
        _completeTask(completer, false);
        return false;
      }

      debugPrint('[INSTALL-CENTER] 开始终极兜底验证...');

      final ultimateCheck = await _ultimateSuccessVerification();
      if (ultimateCheck) {
        debugPrint('[INSTALL-CENTER] ✅ 终极兜底验证通过：游戏已成功安装，忽略异常');
        // ★ 2026-09-26 安装审计 P2-1：兜底命中说明解压/入库至少一环回报过
        // 异常——不能静默当成完美成功，把保留意见透出到进度文案。
        // （判据保持 OR：收窄为 AND 会让「解压成功但注册失败」被回滚删目录，
        // 风险大于收益。）
        _emitPhase(InstallPhase.completed);
        _emitProgress(const InstallProgress(
          downloadPercent: 100.0,
          extractPercent: 100.0,
          statusMessage: '安装完成（解压环节回报过异常，已按目录与注册表校验确认）',
        ));
        await _onInstallSuccess(task);
        _emitSuccess();
        _completeTask(completer, true);
        _resetBusyState();
        return true;
      }

      debugPrint('[INSTALL-CENTER] ❌ 终极兜底验证失败：确认安装失败');
      await _rollback(e.toString());
      _completeTask(completer, false);
      return false;
    }
  }

  /// resolve 任务的 Completer（入队任务的 submitTask Future 在此完成）
  void _completeTask(Completer<bool>? completer, bool success) {
    if (completer != null && !completer.isCompleted) {
      completer.complete(success);
    }
  }

  void _setupDownloadListeners() {
    final core = _activeDlCore!;
    core.removeAllListeners();

    core.addStatusListener((status) {
      if (!mounted) return;
      if (status == DownloadStatus.completed) {
        debugPrint('[INSTALL-CENTER]   下载完成，准备解压...');
      }
    });

    core.addProgressListener((prog) {
      if (!mounted) return;
      _emitProgress(InstallProgress(
        downloadPercent: prog.percent,
        downloadSpeed: prog.speed,
        // ★ 2026-09-26 稳定性批B2：看门狗等自愈事件的用户可见说明由下载核心
        // 携带在事件里；常规进度仍显示默认文案。
        statusMessage: (prog.statusMessage?.isNotEmpty ?? false)
            ? prog.statusMessage!
            : '正在获取... ${prog.percent.toStringAsFixed(1)}%',
      ));
    });

    core.addCompleteListener((path) {
      if (!mounted) return;
      _downloadedFilePath = path;
      debugPrint('[INSTALL-CENTER]   文件下载保存到: $path');
    });

    core.addErrorListener((msg) {
      if (!mounted) return;
      _emitError(msg);
    });
  }

  Future<void> _startDownload(InstallTask task) async {
    final core = _activeDlCore!;
    await core.start(
      // downloadUrl 已可空化（localArchive 任务为 null）；download 分支
      // 在 _executeTask 预检已保证非空。
      url: task.downloadUrl!,
      gameId: task.gameId,
      fileName: task.title,
      title: task.title,
      description: task.description,
      coverUrl: task.coverUrl,
      bannerUrl: task.bannerUrl,
      tags: task.tags,
      customGameLocation: task.customGameLocation ?? _customGameLocation,
      urlResolver: task.urlResolver,
      // ★ 2026-09-26 安装审计 P1-5：解压编排权收归安装中心（避免双层触发）；
      // 云端主键随任务透传，入库时写入 game.json（P1-4 已安装判定用）。
      autoExtract: false,
      cloudGameId: task.gameId,
    );

    if (core.status == DownloadStatus.failed) {
      throw Exception(core.errorMessage ?? '获取失败');
    }
    if (core.status == DownloadStatus.cancelled) {
      _emitPhase(InstallPhase.cancelled);
      _resetBusyState();
      return;
    }
  }

  Future<void> _startExtraction() async {
    // ★ 解压流水线：输入源按任务类型取——localArchive 用用户选择的本地
    // 压缩包，download 用下载完成的临时文件。
    final isLocal = _currentTask?.kind == InstallTaskKind.localArchive;
    final String archivePath;
    if (isLocal) {
      final p = _currentTask?.localArchivePath;
      if (p == null || p.isEmpty) {
        throw Exception('本地压缩包路径为空');
      }
      archivePath = p;
    } else {
      if (_downloadedFilePath == null || _downloadedFilePath!.isEmpty) {
        throw Exception('下载文件路径为空');
      }
      archivePath = _downloadedFilePath!;
    }

    final extractMgr = _activeDlCore!.extractManager;
    extractMgr.removeListeners();

    // ★ 解压流水线：密码/策略/歧义/损坏/本体缺失五类决策请求透传到
    // main_container 注入的弹窗回调；未注入（null）时 extract_manager
    // 走内部默认决策（自动尝试推荐路径），行为与现状一致。
    extractMgr.onExtractDecision = (request) async {
      final hook = onUnpackDecisionRequest;
      if (hook == null) return null;
      return hook(request);
    };

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
      archivePath: archivePath,
      gameTitle: _currentTask?.title ?? _currentTask?.gameId ?? 'UnknownGame',
      gameDescription: _currentTask?.description,
      gameCoverUrl: _currentTask?.coverUrl,
      gameBannerUrl: _currentTask?.bannerUrl,
      gameTags: _currentTask?.tags,
      // 修复数据缺失：会社信息与截图数据需随基础数据一并写入 game.json
      gameDeveloper: _currentTask?.developer,
      screenshotUrls: _currentTask?.screenshotUrls,
      gameSubtitle: _currentTask?.subtitle,
      customGameLocation: _customGameLocation,
      // ★ 2026-10-05 实机反馈：计划窗确认的解压计划（层序/密码/后缀映射）
      //   必须透传给执行层。C1 改造时漏传此参数，extract_manager 退回
      //   「从文件名猜格式」老路——.7z.lz4 被猜成「第一层 .7z」，7z 打不开
      //   lz4 壳文件（Cannot open the file as [7z] archive），解压零进展即失败。
      unpackPlan: _currentTask?.unpackPlan,
      // ★ 2026-09-26 安装审计 P1-4：云端主键落库，供「是否已安装」按稳定
      // 外部 ID 判定（标题精确匹配对改名/译名差异不可靠，且与 ADR-011 冲突）。
      cloudGameId: _currentTask?.gameId,
    );

    final extractStatus = extractMgr.status;
    debugPrint('[INSTALL-CENTER] 解压完成 | 状态: $extractStatus');

    // 修复：extractManager.cancel() 现在会发出 ExtractStatus.failed（终态，
    // 用于让添加页的进度遮罩收敛）。此处若不加区分，用户点「取消」后会误入
    // 失败分支 → 抛异常 → 外层 _rollback 删除已下载的压缩包，并把 UI 相位
    // 从「已取消」改写为「安装失败」。取消不是失败，显式排除。
    if (extractStatus == ExtractStatus.failed &&
        _phase != InstallPhase.cancelled) {
      // ★ 解压流水线：本地压缩包任务以确认入库窗为成功闸门，failed 即
      // 失败（抛给外层 catch 走回滚），不做「目录已存在」式二次验证——
      // 半途而废的产物目录会被误判为成功。
      if (isLocal) {
        debugPrint(
            '[INSTALL-CENTER] ❌ 本地解压任务失败: ${extractMgr.errorMessage}');
        throw Exception(extractMgr.errorMessage ?? '解压失败');
      }
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

  // ═══════════════════════════════════════════════════════════════════
  // ★ 解压流水线：本地压缩包（localArchive）任务收尾链
  // join_unpack_install_center_pipeline.md §C1——确认入库、元数据写入、
  // 注册、习惯记忆与删源包，从添加页 join_controller 迁移为安装中心
  // 服务层实现（确认窗回调由 main_container 注入）。
  // ═══════════════════════════════════════════════════════════════════

  /// 本地压缩包解压完成后的确认收尾（★ 2026-10-05 流程语义修正）。
  ///
  /// 相位先切到 [InstallPhase.awaitingConfirmation]（队列不推进），随后
  /// await [onUnpackFinishConfirm] 弹窗决策：
  /// - 返回 null（用户关闭确认窗）＝ 放弃：产物与源包均保留，任务按
  ///   completed 收口（不回滚——解压本身是成功的，只放弃后续流程）。
  /// - 返回 [UnpackFinishOutcome] ＝ 确认解压完成：改名（可选）→ 习惯记忆
  ///   → 删源包（按勾选）→ **交接添加页**（[onUnpackReadyForManualImport]）
  ///   → completed。
  ///
  /// ★ 解压完成 ≠ 入库：确认窗只收口解压流程；元数据写入与注册进库由
  /// 用户回到添加页表单自行填写数据、自行点「确认入库」（startCopyFlow
  /// 轻量注册，游戏本体留在原位不复制）后完成。旧实现确认后自动写
  /// game.json 并注册进库，用户来不及审核数据即被入库（实机反馈）。
  Future<bool> _finishLocalArchive(InstallTask task,
      {Completer<bool>? completer}) async {
    final extractMgr = _activeDlCore!.extractManager;
    final bodyDir = extractMgr.actualGameDir;
    if (bodyDir == null ||
        bodyDir.isEmpty ||
        !Directory(bodyDir).existsSync()) {
      throw Exception('解压完成但未获得产物目录');
    }

    debugPrint('[INSTALL-CENTER] ⏸ 解压完成，进入解压结果确认 | 产物: $bodyDir');
    _emitPhase(InstallPhase.awaitingConfirmation);

    final outcome = await onUnpackFinishConfirm?.call(
      task: task,
      extractedDir: bodyDir,
      sourceArchivePath: task.localArchivePath ?? '',
    );

    if (outcome == null) {
      // 用户关闭确认窗：产物与源包都保留，不回滚。
      debugPrint('[INSTALL-CENTER] 用户放弃后续流程，产物保留: $bodyDir');
      _emitPhase(InstallPhase.completed);
      _emitProgress(InstallProgress(
        downloadPercent: 100.0,
        extractPercent: 100.0,
        statusMessage: '已放弃后续流程，解压产物保留在原位置',
      ));
      onUnpackImportCancelled?.call('已放弃后续流程，解压产物保留在：$bodyDir');
      _completeTask(completer, true);
      _resetBusyState();
      return true;
    }

    // ① 最终文件夹名确认（用户编辑了目录名 → 真实重命名本体目录）
    var adoptedDir = bodyDir;
    final newName = outcome.finalDirName?.trim();
    if (newName != null &&
        newName.isNotEmpty &&
        newName != _baseNameOf(bodyDir)) {
      final renamed = _renameExtractedDir(bodyDir, newName);
      if (renamed != null) {
        adoptedDir = renamed;
        debugPrint('[INSTALL-CENTER] 产物已按确认改名: $bodyDir → $adoptedDir');
      }
    }

    // ② 习惯记忆：本次成功解压的设定转存（同结构去重、LRU 10 条）
    _recordUnpackHabit(task);

    // ③ 按确认窗勾选删除源压缩包（默认保留；失败保留并提示）
    final sourceArchive = task.localArchivePath;
    if (outcome.deleteSourceArchive &&
        sourceArchive != null &&
        sourceArchive.isNotEmpty) {
      try {
        final f = File(sourceArchive);
        if (f.existsSync()) {
          f.deleteSync();
          debugPrint('[INSTALL-CENTER] 已按用户确认删除源压缩包: $sourceArchive');
        }
      } catch (e) {
        debugPrint('[INSTALL-CENTER] ✗ 删除源压缩包失败（保留）: $e');
        onUnpackImportCancelled?.call('删除源压缩包失败，文件已保留');
      }
    }

    // ④ 解压流程收口 → 交接添加页（数据填写与确认入库由用户自行操作）
    debugPrint('[INSTALL-CENTER] 步骤3/3：解压流程完成，交接添加页: $adoptedDir');
    _emitPhase(InstallPhase.completed);
    _emitProgress(InstallProgress(
      downloadPercent: 100.0,
      extractPercent: 100.0,
      statusMessage: '解压完成，请回添加页完成数据审核与入库',
    ));
    onUnpackReadyForManualImport?.call(
        adoptedDir, _baseNameOf(adoptedDir));
    _completeTask(completer, true);
    _resetBusyState();
    return true;
  }

  /// 习惯记忆：确认入库成功后把本次解压设定转存（同结构去重、LRU 10 条）
  void _recordUnpackHabit(InstallTask task) {
    final plan = task.unpackPlan;
    if (plan == null) return;
    try {
      UnpackStore.instance.recordHabit(UnpackPreset(
        name: '习惯 · ${_habitLabel(plan)}',
        auto: true,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
        layers: _habitLayers(plan),
        mappings: plan.suffixMappings,
        extractToSource: task.customGameLocation?.isNotEmpty ?? false,
      ));
    } catch (e) {
      debugPrint('[INSTALL-CENTER] 习惯记录失败（不影响主流程）: $e');
    }
  }

  /// 习惯条目名：首层格式 + 层数（合并 lz4 双嵌套后）
  String _habitLabel(UnpackPlan plan) {
    final layers = _habitLayers(plan);
    final first = layers.isEmpty
        ? 'ZIP'
        : layers.first.format.split('+').last.toUpperCase();
    return '$first${layers.length > 1 ? ' ${layers.length}层' : ''}';
  }

  /// 从确认计划的探测层 + 逐层密码序列逆推预设层（lz4 壳 + 内层合并），
  /// 与解压计划弹窗的「加一层」设定行同构。
  List<PresetLayer> _habitLayers(UnpackPlan plan) {
    final layers = <PresetLayer>[];
    final seq = plan.passwordSequence;
    for (var i = 0; i < plan.layers.length; i++) {
      final f = plan.layers[i].realFormat;
      if (f == 'lz4') {
        final inner =
            i + 1 < plan.layers.length ? plan.layers[i + 1].realFormat : 'zip';
        final innerPw = i + 1 < seq.length ? seq[i + 1] : '';
        layers.add(PresetLayer(format: 'lz4+$inner', password: innerPw));
        i++;
      } else {
        layers.add(PresetLayer(format: f, password: i < seq.length ? seq[i] : ''));
      }
    }
    return layers;
  }

  /// 重命名解压产物目录（§4.7 最终文件夹名确认）。
  ///
  /// 非法字符清洗 + 重名 `_1/_2` 递增避让（对齐 extract_manager 的
  /// `_resolveCustomGameDir` 命名规则）。改名失败不中断入库流程：
  /// 返回 null（保持原名——本体已解压完成，改名是锦上添花）。
  String? _renameExtractedDir(String extractedDir, String newName) {
    final dir = Directory(extractedDir);
    if (!dir.existsSync()) return null;
    var safe = newName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safe.isEmpty) return null;
    final currentName = _baseNameOf(extractedDir);
    if (safe == currentName) return extractedDir; // 未变
    final sep = extractedDir.contains('/') ? '/' : '\\';
    final parent =
        extractedDir.substring(0, extractedDir.length - currentName.length - 1);
    var candidate = '$parent$sep$safe';
    var i = 1;
    while (Directory(candidate).existsSync()) {
      candidate = '$parent$sep${safe}_$i';
      i++;
    }
    try {
      dir.renameSync(candidate);
      return candidate;
    } catch (e) {
      debugPrint('[INSTALL-CENTER] ✗ 重命名解压目录失败（保持原名）: $e');
      return null;
    }
  }

  /// 路径末段目录名（兼容 / 与 \ 分隔符）
  static String _baseNameOf(String dirPath) =>
      dirPath.split('/').last.split('\\').last;

  /// 安装成功后的清理与校验钩子。
  ///
  /// 1. 删除 downloads 里的游戏压缩包(无条件删除,用户已决策)。
  ///    注:extract_manager.start() 已删过一次,此处是兜底确保删除。
  /// 2. 完整性校验:检查解压目标目录文件数 ≥ 阈值且至少含 1 个 .exe。
  ///    校验失败仅记录日志,不回滚(安装已成功,仅警告)。
  /// 3. 上报安装统计到 PocketBase（fire-and-forget，失败不影响安装）。
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

    // 3. 安装统计上报（不 await，统计失败不影响安装主流程）
    unawaited(InstallStatsService.instance.reportInstall(
      gameId: task.gameId,
      gameTitle: task.title,
    ));
  }

  /// 校验解压结果完整性。
  ///
  /// 检查项:目标目录存在、文件数 ≥ 4、至少含 1 个 .exe。
  /// 校验失败记录 CleanupLog 但不抛错(安装已成功,仅警告)。
  Future<void> _verifyInstallIntegrity(InstallTask task) async {
    final checkDir = _activeDlCore?.extractManager.actualGameDir ??
        _activeDlCore?.extractManager.targetGameDir;
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
      final targetDir = _activeDlCore?.extractManager.targetGameDir;
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
      final targetDir = _activeDlCore?.extractManager.targetGameDir;
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
      final extractStatus = _activeDlCore?.extractManager.status;
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

    // ★ 2026-10-05 实机反馈：先发错误信息、再切 failed 相位。原顺序相反
    //   ——页面在 phase 回调里同步读 errorMessage 时拿到旧值（null），
    //   失败卡片永远显示兜底文案「操作过程中发生异常」，真实原因被埋进日志。
    //   顺带去掉 Exception: 前缀，UI 显示更干净。
    _emitError(reason.replaceFirst(RegExp(r'^(Exception|Error):\s*'), ''));
    _emitPhase(InstallPhase.failed);

    try {
      final core = _activeDlCore;
      if (core != null && core.status == DownloadStatus.downloading) {
        debugPrint('[INSTALL-CENTER]   回滚步骤1：取消进行中的下载...');
        core.cancel();
      }

      debugPrint('[INSTALL-CENTER]   回滚步骤2：清理已下载文件...');
      if (_downloadedFilePath != null && _downloadedFilePath!.isNotEmpty) {
        final dlFile = File(_downloadedFilePath!);
        if (await dlFile.exists()) {
          await dlFile.delete();
          debugPrint('[INSTALL-CENTER]   ✅ 已删除: $_downloadedFilePath');
        }
      }

      // 步骤2.5:清理 downloads 目录里**由本任务产生**的孤儿压缩包残留
      // ★ IMP-08（2026-09-12 导入审查）：旧实现按"文件名包含 gameId 或标题"
      // + 24h 时间窗删除，会误删用户自己放在 downloads 目录、名字恰好撞上标题的
      // 压缩包。现改为只清理"与本次下载文件同基名"的变体（下载器产生的
      // xxx.zip.1 / xxx.zip.part 之流）；拿不到本任务下载路径时一律不删。
      debugPrint('[INSTALL-CENTER]   回滚步骤2.5：清理本任务产生的孤儿压缩包...');
      try {
        final dlDir = Directory(PathHelper.downloadsDir);
        final recorded = _downloadedFilePath;
        if (await dlDir.exists() && recorded != null && recorded.isNotEmpty) {
          final recordedBase =
              recorded.split('/').last.split('\\').last.toLowerCase();
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
              // ★ IMP-08: 只匹配"与本次下载文件同基名"的变体
              final baseName = name.split('/').last.split('\\').last;
              if (!baseName.startsWith(recordedBase)) continue;
              // 仅清理 24 小时内修改的文件(避免误删旧的无关压缩包)
              try {
                final stat = await entity.stat();
                if (now.difference(stat.modified).inHours < 24) {
                  await CleanupUtils.deleteWithRetry(entity,
                      retries: 1, reason: 'install_rollback_orphan_archive');
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
      final actualDir = core?.extractManager.actualGameDir;
      final targetDir = core?.extractManager.targetGameDir;

      if (actualDir != null && actualDir.isNotEmpty) {
        final dir = Directory(actualDir);
        if (await dir.exists()) {
          // ★ IMP-21 数据安全护栏（2026-09-12 导入审查，与 ADR-007 / IMP-02 一致）：
          // ① 只允许删除**应用自有目录内**的路径 —— actualDir 可能是用户在"安装位置"
          //    里挑选的任意目录，越界递归删除即用户数据丢失；
          // ② 游戏数据判定改为**递归**（原实现只看顶层文件，exe 位于 bin/ 等子目录的
          //    目录会被误判为"无游戏数据"而遭整目录删除）。
          if (!PathHelper.isInsideAppStorage(actualDir)) {
            debugPrint(
                '[INSTALL-CENTER]   ⛔ 跳过删除实际解压目录(位于应用自有目录之外): $actualDir');
          } else {
            try {
              final hasGameData =
                  await InterruptCleanup.hasGameDataRecursively(dir);
              if (!hasGameData) {
                await CleanupUtils.deleteWithRetry(dir,
                    retries: 1, reason: 'install_rollback_actual_dir');
                debugPrint('[INSTALL-CENTER]   ✅ 已删除实际解压目录: $actualDir');
              } else {
                debugPrint('[INSTALL-CENTER]   ⚠️ 实际解压目录含游戏数据,保留: $actualDir');
              }
            } catch (e) {
              debugPrint('[INSTALL-CENTER]   ⚠️ 清理实际解压目录异常: $actualDir | $e');
            }
          }
        }
      }

      // 清理元数据目录(若与实际解压目录不同)
      if (targetDir != null && targetDir.isNotEmpty && targetDir != actualDir) {
        final dir = Directory(targetDir);
        if (await dir.exists()) {
          // ★ IMP-21: 元数据目录同样只允许在应用自有目录内删除
          //（原实现此处完全无校验，直接递归删除）
          if (!PathHelper.isInsideAppStorage(targetDir)) {
            debugPrint(
                '[INSTALL-CENTER]   ⛔ 跳过删除元数据目录(位于应用自有目录之外): $targetDir');
          } else {
            try {
              await CleanupUtils.deleteWithRetry(dir,
                  retries: 1, reason: 'install_rollback_target_dir');
              debugPrint('[INSTALL-CENTER]   ✅ 已删除元数据目录: $targetDir');
            } catch (e) {
              debugPrint('[INSTALL-CENTER]   ⚠️ 清理元数据目录异常: $targetDir | $e');
            }
          }
        }
      }

      for (int i = 0;; i++) {
        final tempDir = Directory(
            '${core?.extractManager.gamesBaseDir ?? PathHelper.gamesDir}/._temp_layer_$i');
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

  /// 取消当前正在执行的任务（不影响队列，队列随后自动推进）
  void cancelCurrentTask() {
    if (!_isBusy) {
      debugPrint('[INSTALL-CENTER] ⚠️ 当前无活动任务，无法取消');
      return;
    }

    debugPrint('[INSTALL-CENTER] ❌ 用户主动取消安装任务 | 游戏: ${_currentTask?.title}');

    // ★ 解压流水线：确认入库窗挂起期间不响应取消——弹窗自身有关闭路径
    //（关闭 = 放弃入库），强行取消会与弹窗收口互相改写终态。
    if (_phase == InstallPhase.awaitingConfirmation) {
      debugPrint('[INSTALL-CENTER] ⚠️ 确认入库挂起中，忽略取消请求');
      return;
    }

    if (_phase == InstallPhase.downloading) {
      _activeDlCore?.cancel();
    } else if (_phase == InstallPhase.extracting) {
      _activeDlCore?.extractManager.cancel();
    }

    _emitPhase(InstallPhase.cancelled);
    _emitProgress(const InstallProgress(statusMessage: '已取消'));
    _resetBusyState();
  }

  /// 从队列移除指定游戏（未开始的任务，直接取消排队）
  ///
  /// 返回是否成功移除（不在队列中返回 false）
  bool removeQueuedTask(String gameId) {
    final idx = _queue.indexWhere((q) => q.task.gameId == gameId);
    if (idx < 0) return false;

    final removed = _queue.removeAt(idx);
    _completeTask(removed.completer, false);
    _notifyQueueChanged();
    debugPrint('[INSTALL-CENTER] 🗑️ 已移除排队任务 | 游戏: ${removed.task.title}');
    return true;
  }

  /// 清空整个队列（未开始的任务全部取消排队）
  void clearQueue() {
    if (_queue.isEmpty) return;
    for (final q in _queue) {
      _completeTask(q.completer, false);
    }
    final count = _queue.length;
    _queue.clear();
    _notifyQueueChanged();
    debugPrint('[INSTALL-CENTER] 🗑️ 清空安装队列 | 共移除 $count 个任务');
  }

  void _resetBusyState() {
    _isBusy = false;
    if (_phase == InstallPhase.completed ||
        _phase == InstallPhase.failed ||
        _phase == InstallPhase.cancelled) {
      // 队列非空：终态展示 2 秒后自动推进下一个任务（不经过 idle，无缝衔接）
      if (_queue.isNotEmpty) {
        _queueAdvanceTimer?.cancel();
        _queueAdvanceTimer = Timer(const Duration(seconds: 2), () {
          _advanceQueue();
        });
        return;
      }

      Future.delayed(const Duration(seconds: 2), () {
        // 防御：若期间新任务已开始（phase 已变），不再重置
        if (_phase == InstallPhase.completed ||
            _phase == InstallPhase.failed ||
            _phase == InstallPhase.cancelled) {
          _emitPhase(InstallPhase.idle);
          _currentTask = null;
          _downloadedFilePath = null;
          _errorMessage = null;
          _activeDlCore = null;
          _emitProgress(const InstallProgress());
          debugPrint('[INSTALL-CENTER] 状态重置为空闲');
        }
      });
    }
  }

  /// 队列推进：取出队首任务并立即执行
  void _advanceQueue() {
    if (_isBusy || _queue.isEmpty) return;

    final next = _queue.removeAt(0);
    _notifyQueueChanged();
    // 清理上一个任务的痕迹，让新任务以干净状态启动
    _currentTask = null;
    _downloadedFilePath = null;
    _errorMessage = null;
    _activeDlCore = null;
    _emitProgress(const InstallProgress());

    debugPrint(
        '[INSTALL-CENTER] ▶️ 队列推进 | 剩余 ${_queue.length} 个排队 | 开始: ${next.task.title}');
    unawaited(_executeTask(next.task, completer: next.completer));
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
    _queueAdvanceTimer?.cancel();
    _queueAdvanceTimer = null;
    // 队列中未开始的任务直接取消（无资源占用）
    clearQueue();
    cancelCurrentTask();
    removeAllListeners();
    _activeDlCore?.removeAllListeners();
    _activeDlCore?.extractManager.removeListeners();
    _activeDlCore = null;
  }
}
