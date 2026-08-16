import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import '../models/watch_folder.dart';
import '../utils/path_normalizer.dart';
import 'auto_import_pipeline.dart';
import 'import_dedup_index.dart';

/// 文件夹监控服务（单例）
///
/// 使用 watch + poll 双保险策略监控指定文件夹，
/// 发现新游戏目录后通过 AutoImportPipeline 处理。
///
/// 关键能力：
/// - 递归扫描（3 层深度）
/// - 启动时全量扫描
/// - 已扫描目录带 TTL（24 小时，过期可重新评估）
/// - 每路径独立处理锁（避免全局阻塞）
/// - 候选队列 / 忽略列表持久化
/// - gameCount 实时更新
/// - watcher 健康检查与自动重连
/// - 扫描状态可观测（isScanning / 进度计数）
class WatchFolderService extends ChangeNotifier {
  static final WatchFolderService _instance = WatchFolderService._internal();
  static WatchFolderService get instance => _instance;

  WatchFolderService._internal();

  // ==================== 持久化 Keys ====================
  static const String _prefsKey = 'watch_folders';
  static const String _modeKey = 'auto_import_mode';
  static const String _intervalKey = 'auto_import_interval';
  static const String _lockTitleKey = 'auto_import_lock_title';
  static const String _thresholdKey = 'auto_import_threshold';
  static const String _candidatesKey = 'watch_folder_candidates';
  static const String _ignoredKey = 'watch_folder_ignored';
  static const String _isImportingKey = 'watch_folder_is_importing';

  /// 已扫描目录缓存的 TTL：24 小时后允许重新评估
  static const Duration _scannedDirTtl = Duration(hours: 24);

  /// 递归扫描最大深度（含根）
  static const int _maxScanDepth = 3;

  // ==================== 状态字段 ====================
  List<WatchFolder> _watchFolders = [];
  AutoImportMode _importMode = AutoImportMode.confirm;
  int _intervalMinutes = 5;
  bool _lockTitle = true;
  double _confidenceThreshold = 0.30;

  /// 发现的候选游戏列表（通知确认模式使用）
  final List<ImportCandidate> _candidates = [];

  /// 忽略的目录路径列表（持久化）
  final Set<String> _ignoredPaths = {};

  /// 每个监控路径对应的 StreamSubscription
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

  /// 事件防抖定时器（3秒合并窗口）
  final Map<String, Timer> _debounceTimers = {};

  /// 轮询定时器
  Timer? _pollTimer;

  /// watcher 健康检查定时器
  Timer? _healthCheckTimer;

  /// 已扫描过的目录缓存（带时间戳，TTL 过期可重新评估）
  final Map<String, DateTime> _scannedDirs = {};

  /// 每路径独立处理锁
  final Set<String> _processingPaths = {};

  /// 扫描状态（供 UI 观测）
  bool _isScanning = false;
  int _scanTotalDirs = 0;
  int _scanProcessedDirs = 0;
  int _scanFoundCount = 0;
  String _currentScanPath = '';

  // ==================== Getters ====================
  List<WatchFolder> get watchFolders => List.unmodifiable(_watchFolders);
  AutoImportMode get importMode => _importMode;
  int get intervalMinutes => _intervalMinutes;
  bool get lockTitle => _lockTitle;
  double get confidenceThreshold => _confidenceThreshold;
  List<ImportCandidate> get candidates => List.unmodifiable(_candidates);
  Set<String> get ignoredPaths => Set.unmodifiable(_ignoredPaths);

  bool get isScanning => _isScanning;
  int get scanTotalDirs => _scanTotalDirs;
  int get scanProcessedDirs => _scanProcessedDirs;
  int get scanFoundCount => _scanFoundCount;
  String get currentScanPath => _currentScanPath;

  /// 扫描进度（0.0 ~ 1.0）
  double get scanProgress {
    if (_scanTotalDirs == 0) return 0.0;
    return (_scanProcessedDirs / _scanTotalDirs).clamp(0.0, 1.0);
  }

  // ==================== 配置加载 / 保存 ====================

  /// 加载持久化配置
  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_prefsKey);
      if (jsonStr != null) {
        final list = jsonDecode(jsonStr) as List;
        _watchFolders = list
            .map((e) => WatchFolder.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      _importMode = AutoImportMode.values.firstWhere(
        (m) => m.name == prefs.getString(_modeKey),
        orElse: () => AutoImportMode.confirm,
      );
      _intervalMinutes = prefs.getInt(_intervalKey) ?? 5;
      _lockTitle = prefs.getBool(_lockTitleKey) ?? true;
      _confidenceThreshold = prefs.getDouble(_thresholdKey) ?? 0.30;

      // 加载候选队列
      final candidatesStr = prefs.getString(_candidatesKey);
      if (candidatesStr != null) {
        final list = jsonDecode(candidatesStr) as List;
        _candidates.clear();
        _candidates.addAll(list
            .map((e) => ImportCandidate.fromJson(e as Map<String, dynamic>)));
      }

      // 加载忽略列表
      final ignoredStr = prefs.getString(_ignoredKey);
      if (ignoredStr != null) {
        final list = jsonDecode(ignoredStr) as List;
        _ignoredPaths.clear();
        _ignoredPaths.addAll(list.map((e) => e.toString()));
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[WATCH] 加载配置失败: $e');
    }
  }

  /// 保存配置到持久化存储
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_watchFolders.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsKey, jsonStr);
      await prefs.setString(_modeKey, _importMode.name);
      await prefs.setInt(_intervalKey, _intervalMinutes);
      await prefs.setBool(_lockTitleKey, _lockTitle);
      await prefs.setDouble(_thresholdKey, _confidenceThreshold);
    } catch (e) {
      debugPrint('[WATCH] 保存配置失败: $e');
    }
  }

  /// 持久化候选队列
  Future<void> _saveCandidates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_candidates.map((e) => e.toJson()).toList());
      await prefs.setString(_candidatesKey, jsonStr);
    } catch (e) {
      debugPrint('[WATCH] 保存候选队列失败: $e');
    }
  }

  /// 持久化忽略列表
  Future<void> _saveIgnored() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_ignoredPaths.toList());
      await prefs.setString(_ignoredKey, jsonStr);
    } catch (e) {
      debugPrint('[WATCH] 保存忽略列表失败: $e');
    }
  }

  // ==================== 监控路径管理 ====================

  /// 按规范化路径查找 WatchFolder（大小写不敏感）
  WatchFolder? _findFolder(String path) {
    final normalized = PathNormalizer.forCompare(path);
    for (final f in _watchFolders) {
      if (PathNormalizer.forCompare(f.path) == normalized) return f;
    }
    return null;
  }

  /// 添加监控路径
  ///
  /// 使用 forStore 保留原始大小写用于显示，匹配时统一用 forCompare。
  Future<bool> addWatchFolder(String path) async {
    final stored = PathNormalizer.forStore(path);
    if (!Directory(stored).existsSync()) {
      debugPrint('[WATCH] 路径不存在: $stored');
      return false;
    }
    if (_findFolder(stored) != null) {
      debugPrint('[WATCH] 路径已存在: $stored');
      return false;
    }

    _watchFolders.add(WatchFolder(
      path: stored,
      addedAt: DateTime.now(),
    ));
    await _saveSettings();
    _startWatching(stored);
    _restartPolling();
    notifyListeners();
    debugPrint('[WATCH] ✅ 添加监控路径: $stored');
    return true;
  }

  /// 移除监控路径
  Future<void> removeWatchFolder(String path) async {
    final folder = _findFolder(path);
    if (folder == null) {
      debugPrint('[WATCH] 移除失败：路径未找到: $path');
      return;
    }
    final normalized = PathNormalizer.forCompare(path);
    _watchFolders.removeWhere(
        (f) => PathNormalizer.forCompare(f.path) == normalized);
    _stopWatching(folder.path); // 使用实际存储路径停止 watcher
    await _saveSettings();
    _restartPolling();
    notifyListeners();
    debugPrint('[WATCH] 🗑️ 移除监控路径: ${folder.path}');
  }

  /// 切换单个路径的启用状态
  Future<void> toggleFolderEnabled(String path) async {
    final folder = _findFolder(path);
    if (folder == null) return;
    final normalized = PathNormalizer.forCompare(path);
    final idx = _watchFolders
        .indexWhere((f) => PathNormalizer.forCompare(f.path) == normalized);
    if (idx < 0) return;
    _watchFolders[idx] = folder.copyWith(enabled: !folder.enabled);
    await _saveSettings();
    if (_watchFolders[idx].enabled) {
      _startWatching(folder.path);
    } else {
      _stopWatching(folder.path);
    }
    _restartPolling();
    notifyListeners();
  }

  /// 更新路径的排除规则
  Future<void> updateExcludePatterns(String path, List<String> patterns) async {
    final normalized = PathNormalizer.forCompare(path);
    final idx = _watchFolders
        .indexWhere((f) => PathNormalizer.forCompare(f.path) == normalized);
    if (idx < 0) return;
    _watchFolders[idx] = _watchFolders[idx].copyWith(excludePatterns: patterns);
    await _saveSettings();
    // 排除规则变化后，清除该路径的扫描缓存以重新评估
    _scannedDirs.removeWhere((k, _) => k.startsWith(normalized));
    notifyListeners();
  }

  // ==================== 设置项 ====================

  Future<void> setImportMode(AutoImportMode mode) async {
    _importMode = mode;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setIntervalMinutes(int minutes) async {
    _intervalMinutes = minutes.clamp(1, 60);
    await _saveSettings();
    _restartPolling();
    notifyListeners();
  }

  Future<void> setLockTitle(bool value) async {
    _lockTitle = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setConfidenceThreshold(double value) async {
    _confidenceThreshold = value.clamp(0.05, 0.95);
    await _saveSettings();
    // 阈值变化后，清除扫描缓存以重新评估所有目录
    _scannedDirs.clear();
    notifyListeners();
  }

  // ==================== 监控生命周期 ====================

  /// 启动所有监控（应用启动时调用）
  ///
  /// 关键修复：
  /// 1. 启动后立即执行一次全量扫描，确保已存在的游戏能被发现。
  /// 2. 清理上次异常退出残留的 _isScanning 状态，防止导入进程永久卡住。
  /// 3. 校正候选队列中可能已入库的候选（上次中断残留）。
  Future<void> startAll() async {
    await loadSettings();
    _scannedDirs.clear(); // 启动时重置扫描缓存，确保全量评估

    // ★ 关键修复：清理上次异常退出残留的导入状态
    await _cleanupCrashedImportState();

    for (final folder in _watchFolders) {
      if (folder.enabled) {
        _startWatching(folder.path);
      }
    }
    _restartPolling();
    _startHealthCheck();
    debugPrint('[WATCH] 🚀 所有监控已启动 (${_watchFolders.length}个路径)');

    // 启动后立即全量扫描一次
    if (_watchFolders.any((f) => f.enabled)) {
      await scanAllNow();
    }
  }

  /// 清理上次异常退出残留的导入状态
  ///
  /// 场景：用户在批量导入过程中退出软件，_isScanning 被持久化为 true，
  /// 但导入循环已中断。重启后需要：
  /// 1. 重置 _isScanning 为 false
  /// 2. 校正候选队列：移除已实际入库的候选（上次中断前已入库但未从队列移除）
  Future<void> _cleanupCrashedImportState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wasImporting = prefs.getBool(_isImportingKey) ?? false;
      if (wasImporting) {
        debugPrint('[WATCH] 🧹 检测到上次异常退出（导入被中断），清理残留状态');
        _isScanning = false;
        _currentScanPath = '';
        await prefs.setBool(_isImportingKey, false);

        // 校正候选队列：移除已入库的候选
        final beforeCount = _candidates.length;
        _candidates.removeWhere((c) =>
            AutoImportPipeline.isAlreadyImported(c.dirPath));
        if (_candidates.length != beforeCount) {
          debugPrint(
              '[WATCH] 🧹 清理已入库候选: ${beforeCount - _candidates.length}个');
          await _saveCandidates();
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[WATCH] 清理异常状态失败: $e');
      _isScanning = false;
    }
  }

  /// 停止所有监控
  void stopAll() {
    for (final path in _watchers.keys.toList()) {
      _stopWatching(path);
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    debugPrint('[WATCH] 🛑 所有监控已停止');
  }

  /// 启动单个路径的监控
  void _startWatching(String path) {
    if (_watchers.containsKey(path)) return;

    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        debugPrint('[WATCH] 路径不存在，跳过: $path');
        return;
      }

      final subscription = dir.watch(recursive: true).listen(
        (event) => _onFileSystemEvent(path, event),
        onError: (e) {
          debugPrint('[WATCH] 监控错误 $path: $e');
          _watchers.remove(path);
          // 错误后定时尝试重连
          Timer(const Duration(seconds: 30), () {
            if (_watchFolders.any((f) => f.path == path && f.enabled)) {
              debugPrint('[WATCH] 尝试重连监控: $path');
              _startWatching(path);
            }
          });
        },
      );
      _watchers[path] = subscription;
      debugPrint('[WATCH] 👁️ 开始监控: $path');
    } catch (e) {
      debugPrint('[WATCH] 启动监控失败 $path: $e');
    }
  }

  /// 停止单个路径的监控
  void _stopWatching(String path) {
    _watchers[path]?.cancel();
    _watchers.remove(path);
    _debounceTimers[path]?.cancel();
    _debounceTimers.remove(path);
  }

  /// watcher 健康检查：每 5 分钟检查一次，失效路径自动重连
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      for (final folder in _watchFolders) {
        if (!folder.enabled) continue;
        final pathExists = Directory(folder.path).existsSync();
        final hasWatcher = _watchers.containsKey(folder.path);

        if (pathExists && !hasWatcher) {
          debugPrint('[WATCH] 💊 健康检查：重连失效监控: ${folder.path}');
          _startWatching(folder.path);
        } else if (!pathExists && hasWatcher) {
          debugPrint('[WATCH] 💊 健康检查：路径已失效，停止监控: ${folder.path}');
          _stopWatching(folder.path);
        }
      }
    });
  }

  /// 文件系统事件处理（带3秒防抖）
  void _onFileSystemEvent(String watchPath, FileSystemEvent event) {
    // 只关注创建和移动事件
    if (event.type != FileSystemEvent.create &&
        event.type != FileSystemEvent.move) {
      return;
    }

    // 3秒防抖：同一监控路径的事件合并处理
    _debounceTimers[watchPath]?.cancel();
    _debounceTimers[watchPath] = Timer(const Duration(seconds: 3), () {
      _scanWatchFolder(watchPath);
    });
  }

  // ==================== 扫描核心 ====================

  /// 扫描监控文件夹下的子目录（递归 3 层）
  ///
  /// ★ 优化：notifyListeners 改为时间节流（至少 500ms 间隔），
  /// 避免扫描期间频繁 setState 导致 UI 重建丢失按钮点击事件。
  Future<void> _scanWatchFolder(String watchPath) async {
    // 每路径独立锁，避免全局阻塞
    if (_processingPaths.contains(watchPath)) {
      debugPrint('[WATCH] 路径正在处理中，跳过: $watchPath');
      return;
    }

    final folderIdx = _watchFolders.indexWhere((f) => f.path == watchPath);
    if (folderIdx < 0) return;
    final folder = _watchFolders[folderIdx];
    if (!folder.enabled) return;

    _processingPaths.add(watchPath);
    try {
      final dir = Directory(watchPath);
      if (!await dir.exists()) return;

      // 先收集所有候选子目录（递归 3 层）
      final candidates = <String>[];
      await _collectCandidateDirs(dir, candidates, watchPath,
          depth: 0, excludePatterns: folder.excludePatterns);

      if (candidates.isEmpty) return;

      // ★ 批次级构建排重索引：扫描前一次性构建，传入 processCandidate 复用，
      // 避免逐目录调用 isAlreadyImported 全量遍历（与批量导入一致的多维排重：
      // 路径包含硬冲突 + 同名软警告）。processCandidate 内部前置去重，跳过已入库游戏。
      final dedupIndex = ImportDedupIndex.fromRegistry();

      // 更新扫描状态
      final wasTopLevelScan = !_isScanning;
      if (wasTopLevelScan) {
        _isScanning = true;
        _scanTotalDirs = candidates.length;
        _scanProcessedDirs = 0;
        _scanFoundCount = 0;
        notifyListeners();
      }

      // ★ 时间节流：避免频繁 notifyListeners 导致 UI 重建丢失点击
      DateTime lastNotifyTime = DateTime.now();
      const notifyThrottle = Duration(milliseconds: 500);

      int foundInThisScan = 0;
      for (final candidatePath in candidates) {
        _scanProcessedDirs++;
        _currentScanPath = candidatePath;

        // 检查忽略列表
        if (_ignoredPaths.contains(PathNormalizer.forCompare(candidatePath))) {
          continue;
        }

        // 检查扫描缓存（带 TTL）
        if (_isScannedRecently(candidatePath)) {
          continue;
        }

        // 处理候选目录（去重由 processCandidate 内部用 dedupIndex 完成，
        // 替代原 isAlreadyImported 预检查，支持路径包含冲突与同名软警告）
        await AutoImportPipeline.processCandidate(
          dirPath: candidatePath,
          lockTitle: _lockTitle,
          autoMode: _importMode == AutoImportMode.silent,
          confidenceThreshold: _confidenceThreshold,
          dedupIndex: dedupIndex,
          onCandidate: (candidate) {
            if (_importMode == AutoImportMode.confirm) {
              // 避免重复加入候选队列
              if (!_candidates.any((c) => c.dirPath == candidate.dirPath)) {
                _candidates.add(candidate);
                _saveCandidates();
                _scanFoundCount++;
                foundInThisScan++;
                notifyListeners();
              }
            } else {
              _scanFoundCount++;
              foundInThisScan++;
              notifyListeners();
            }
          },
        );

        _markScanned(candidatePath);

        // ★ 时间节流：至少 500ms 间隔才 notifyListeners
        final now = DateTime.now();
        if (now.difference(lastNotifyTime) >= notifyThrottle) {
          notifyListeners();
          lastNotifyTime = now;
        }
      }

      // 更新 gameCount
      final newCount = _countGamesUnderPath(watchPath);
      if (newCount != folder.gameCount) {
        _watchFolders[folderIdx] = folder.copyWith(
          gameCount: newCount,
          lastScanAt: DateTime.now(),
        );
        await _saveSettings();
      }

      if (wasTopLevelScan) {
        _isScanning = false;
        _currentScanPath = '';
        notifyListeners();
      }

      if (foundInThisScan > 0) {
        debugPrint('[WATCH] 扫描完成 $watchPath: 新发现 $foundInThisScan 个游戏');
      }
    } catch (e) {
      debugPrint('[WATCH] 扫描异常 $watchPath: $e');
    } finally {
      _processingPaths.remove(watchPath);
    }
  }

  /// 递归收集候选子目录（限制深度避免过深）
  Future<void> _collectCandidateDirs(
    Directory dir,
    List<String> candidates,
    String rootPath, {
    required int depth,
    required List<String> excludePatterns,
  }) async {
    if (depth >= _maxScanDepth) return;

    try {
      final entities = await dir.list(followLinks: false).toList();
      for (final entity in entities) {
        if (entity is! Directory) continue;

        final dirName = p.basename(entity.path);

        // 排除规则
        if (_isExcluded(dirName, excludePatterns)) continue;

        // 跳过隐藏目录
        if (dirName.startsWith('.') && dirName.length > 1) continue;

        candidates.add(entity.path);

        // 递归下一层
        await _collectCandidateDirs(
          Directory(entity.path),
          candidates,
          rootPath,
          depth: depth + 1,
          excludePatterns: excludePatterns,
        );
      }
    } catch (e) {
      debugPrint('[WATCH] 收集候选目录异常: $e');
    }
  }

  /// 检查目录名是否匹配排除规则
  bool _isExcluded(String dirName, List<String> patterns) {
    final lower = dirName.toLowerCase();
    for (final pattern in patterns) {
      if (lower.contains(pattern.toLowerCase())) return true;
    }
    return false;
  }

  /// 判断目录是否在 TTL 内已扫描过
  bool _isScannedRecently(String dirPath) {
    final normalized = PathNormalizer.forCompare(dirPath);
    final scannedAt = _scannedDirs[normalized];
    if (scannedAt == null) return false;
    if (DateTime.now().difference(scannedAt) > _scannedDirTtl) {
      _scannedDirs.remove(normalized);
      return false;
    }
    return true;
  }

  /// 标记目录为已扫描
  void _markScanned(String dirPath) {
    _scannedDirs[PathNormalizer.forCompare(dirPath)] = DateTime.now();
  }

  /// 统计某监控路径下已入库的游戏数量
  int _countGamesUnderPath(String watchPath) {
    final normalized = PathNormalizer.forCompare(watchPath);
    int count = 0;
    for (final game in AutoImportPipeline.allImportedDirectoryPaths) {
      if (PathNormalizer.forCompare(game).startsWith(normalized)) {
        count++;
      }
    }
    return count;
  }

  /// 重启轮询定时器
  void _restartPolling() {
    _pollTimer?.cancel();
    if (_watchFolders.isEmpty) return;

    _pollTimer = Timer.periodic(
      Duration(minutes: _intervalMinutes),
      (timer) async {
        for (final folder in _watchFolders) {
          if (folder.enabled) {
            await _scanWatchFolder(folder.path);
          }
        }
      },
    );
  }

  /// 立即扫描所有监控路径
  Future<void> scanAllNow() async {
    for (final folder in _watchFolders) {
      if (folder.enabled) {
        await _scanWatchFolder(folder.path);
      }
    }
  }

  // ==================== 候选管理 ====================

  /// 确认入库候选游戏
  Future<bool> confirmCandidate(ImportCandidate candidate) async {
    final success = await AutoImportPipeline.importCandidate(
      candidate: candidate,
      lockTitle: _lockTitle,
    );
    if (success) {
      candidate.imported = true;
      _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);
      await _saveCandidates();
      // 更新对应监控路径的 gameCount
      _refreshGameCountForPath(candidate.dirPath);
      notifyListeners();
    }
    return success;
  }

  /// 批量确认入库所有候选
  ///
  /// ★ 关键修复：
  /// 1. 每处理完一个候选立即从 _candidates 移除并持久化，
  ///    而不是最后才 clear()。这样即使中途退出软件，已入库的不会残留。
  /// 2. 持久化 _isScanning 状态，重启后可检测到异常中断并清理。
  /// 3. 使用 try-finally 确保状态始终被正确重置。
  Future<int> confirmAllCandidates() async {
    if (_candidates.isEmpty) return 0;

    // 持久化导入状态（用于异常退出检测）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isImportingKey, true);

    final toConfirm = List<ImportCandidate>.from(_candidates);
    int successCount = 0;

    _isScanning = true;
    _scanTotalDirs = toConfirm.length;
    _scanProcessedDirs = 0;
    _scanFoundCount = 0;
    notifyListeners();

    try {
      for (final candidate in toConfirm) {
        _scanProcessedDirs++;
        _currentScanPath = candidate.inferredTitle;

        final ok = await AutoImportPipeline.importCandidate(
          candidate: candidate,
          lockTitle: _lockTitle,
        );

        if (ok) {
          candidate.imported = true;
          successCount++;
          _refreshGameCountForPath(candidate.dirPath);
        }

        // ★ 关键修复：每处理完一个立即从队列移除并持久化
        // 这样即使中途退出软件，已入库的候选不会残留在队列中
        _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);
        await _saveCandidates();

        notifyListeners();
      }
    } catch (e) {
      debugPrint('[WATCH] 批量入库异常: $e');
    } finally {
      // ★ 关键修复：try-finally 确保状态始终被重置
      _isScanning = false;
      _currentScanPath = '';
      await prefs.setBool(_isImportingKey, false);
      notifyListeners();
    }

    return successCount;
  }

  /// 忽略候选游戏（加入持久化忽略列表）
  Future<void> ignoreCandidate(ImportCandidate candidate) async {
    candidate.ignored = true;
    _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);
    _ignoredPaths.add(PathNormalizer.forCompare(candidate.dirPath));
    await _saveCandidates();
    await _saveIgnored();
    notifyListeners();
  }

  /// 批量忽略所有候选
  Future<void> ignoreAllCandidates() async {
    for (final c in _candidates) {
      _ignoredPaths.add(PathNormalizer.forCompare(c.dirPath));
    }
    _candidates.clear();
    await _saveCandidates();
    await _saveIgnored();
    notifyListeners();
  }

  /// 清空所有候选（不加入忽略列表）
  Future<void> clearCandidates() async {
    _candidates.clear();
    await _saveCandidates();
    notifyListeners();
  }

  /// 从忽略列表移除指定路径
  Future<void> unignorePath(String path) async {
    _ignoredPaths.remove(PathNormalizer.forCompare(path));
    await _saveIgnored();
    // 清除扫描缓存以允许重新评估
    _scannedDirs.remove(PathNormalizer.forCompare(path));
    notifyListeners();
  }

  /// 清空忽略列表
  Future<void> clearIgnored() async {
    _ignoredPaths.clear();
    await _saveIgnored();
    notifyListeners();
  }

  /// 刷新某路径所属监控文件夹的 gameCount
  void _refreshGameCountForPath(String gamePath) {
    for (int i = 0; i < _watchFolders.length; i++) {
      final folder = _watchFolders[i];
      if (PathNormalizer.forCompare(gamePath)
          .startsWith(PathNormalizer.forCompare(folder.path))) {
        final newCount = _countGamesUnderPath(folder.path);
        if (newCount != folder.gameCount) {
          _watchFolders[i] = folder.copyWith(gameCount: newCount);
          _saveSettings();
        }
        break;
      }
    }
  }

  @override
  void dispose() {
    stopAll();
    super.dispose();
  }
}
