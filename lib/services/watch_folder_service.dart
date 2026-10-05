import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import '../models/watch_folder.dart';
import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';
import '../utils/title_cleaner.dart';
import '../pages/join/utils/game_folder_scanner.dart';
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
/// - 忽略列表持久化（候选队列已内存化，2026-10-03）
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

  /// 发现的候选游戏列表（两种模式统一入队：确认模式等用户处理，
  /// 静默模式富化成功后自动入库、失败转入确认队列等用户处理）
  final List<ImportCandidate> _candidates = [];

  /// 正在元数据富化中的候选目录（并发控制）
  final Set<String> _enrichingPaths = {};

  /// 元数据富化最大并发数（与批量导入抓取并发一致）
  static const int _maxConcurrentEnrich = 3;

  /// 当前选中的候选目录路径（左侧表单联动编辑，持久于服务单例，
  /// 避免模式切换/页面切换丢失选中状态）
  String? _selectedCandidatePath;

  /// 忽略的目录路径列表（持久化）
  final Set<String> _ignoredPaths = {};

  /// 每个监控路径对应的 StreamSubscription
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

  /// ★ 2026-09-26 NAS 适配：仅靠轮询兜底的路径（UNC / 映射网络驱动器）。
  ///
  /// 这类路径**不建立 `Directory.watch` 订阅**（原因见 [_startWatching]），
  /// 也不参与 watcher 健康检查；其变更检测完全由 [_pollTimer] 承担。
  final Set<String> _pollOnlyPaths = {};

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

  /// ★ IMP-11（2026-09-12 导入审查）：批量入库互斥锁。
  /// 防止并发重入（双击 / UI 守卫失效）对同一批候选重复执行 importCandidate。
  bool _isImportingAll = false;

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

  /// 通知徽标计数：等待用户处理的候选数量（发现队列实时大小）。
  /// 确认模式 = 全部队列；静默模式 = 自动入库后的残留（失败/待处理）。
  int get notificationCount => _candidates.length;

  /// 当前选中的候选（左侧表单联动编辑），未选中返回 null
  ImportCandidate? get selectedCandidate {
    final path = _selectedCandidatePath;
    if (path == null) return null;
    for (final c in _candidates) {
      if (c.dirPath == path) return c;
    }
    return null;
  }

  /// 待用户决策的候选（就绪 + 失败，排除处理中）
  List<ImportCandidate> get actionableCandidates => _candidates
      .where((c) =>
          c.taskStatus == CandidateTaskStatus.ready ||
          c.taskStatus == CandidateTaskStatus.failed)
      .toList();

  /// 选中候选（联动左侧表单编辑）
  void selectCandidate(String? dirPath) {
    _selectedCandidatePath = dirPath;
    notifyListeners();
  }

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

      // ★ 候选队列已完全内存化（2026-10-03 产品决策）：启动即空，
      //   由 startAll() 的启动全量扫描重新发现——不再从磁盘读回。
      //   智能导入的语义是"实时"：候选是扫描的瞬时产物，不是用户数据。
      //   持久化曾导致：① data/watch_candidates.json 连同完整元数据被
      //   打进安装包，别人的机器上出现"我的"待导入游戏；② 目录已删 /
      //   已导入的候选反复复活，时时刻刻提示（拉杆关闭也拦不住——
      //   候选根本不是扫出来的，是从文件里读回来的）。

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

  /// 候选队列持久化 — 已停用（2026-10-03 产品决策：完全内存化）
  ///
  /// 候选是扫描的瞬时产物，退出软件即消失，下次启动由 startAll() 的
  /// 全量扫描重新发现。13 个调用点保留此空壳收口（未来若要恢复持久化，
  /// 只改这一处，不必逐个找调用点）。
  Future<void> _saveCandidates() async {}

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
    // ★ 2026-09-26 NAS 适配：改用异步 exists()。
    // 旧实现用 existsSync()，映射网络盘未连接/高延迟时会**同步阻塞 UI isolate**
    // 直到 SMB 超时（数十秒）→ 表现为「点添加后软件未响应」。
    bool exists;
    try {
      exists = await Directory(stored).exists();
    } catch (e) {
      debugPrint('[WATCH] 路径检查异常: $stored | $e');
      return false;
    }
    if (!exists) {
      debugPrint('[WATCH] 路径不存在或不可访问: $stored');
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
      // ★ 拉杆语义补强（2026-10-03）：关 = 该路径彻底不出现。
      //   候选已完全内存化，这里同步移除该路径的全部候选——
      //   用户关拉杆后提示立即消失（此前旧候选会一直挂着）。
      //   重开拉杆后由 watcher / 轮询重新扫描发现。
      final before = _candidates.length;
      _candidates.removeWhere(
          (c) => PathNormalizer.forCompare(c.dirPath) == normalized);
      if (_candidates.length != before) {
        debugPrint('[WATCH] 🔕 路径已停用，移除其候选 '
            '${before - _candidates.length} 条: ${folder.path}');
      }
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

    // 切换到静默模式：已就绪候选立即自动入库，
    // pending 候选在富化完成后由 _enrichOne 自动入库
    if (mode == AutoImportMode.silent) {
      final readyList = _candidates
          .where((c) =>
              c.taskStatus == CandidateTaskStatus.ready &&
              !c.isHardDuplicate)
          .toList();
      if (readyList.isNotEmpty) {
        await confirmAllCandidates();
      }
      // 硬重复候选静默跳过（加入忽略列表防止重扫）
      for (final c in _candidates.where((c) => c.isHardDuplicate).toList()) {
        await ignoreCandidate(c);
      }
    }
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

    // ★ 启动队列自愈（2026-09-13 排重修复）：跨轮次扫描可能留下
    // 存量重复（父子包含 / 同名副本 / 已入库路径冲突），在启动
    // 全量扫描前清除一次。候选队列已内存化，空队列上这是 no-op，
    // 保留以防御未来恢复持久化时的存量重复。
    _compactQueueOnStartup();

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

    // 处理上次残留的 pending 候选（崩溃恢复 / 上次未完成富化）
    _pumpEnrichmentQueue();
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

  /// 启动时压缩候选队列（2026-09-13 排重修复）
  ///
  /// 清除三类存量重复（语义与扫描管线各阶段一一对应）：
  /// 1. 路径与已入库游戏包含冲突（= 扫描阶段 2a 的 pathConflict 硬跳过）
  /// 2. 队列内父子包含（= 扫描阶段四，保留祖先目录）
  /// 3. 队列内同名副本（= 扫描阶段 4.5，保留识别度最高者，引擎冲突不合并）
  ///
  /// 只改内存队列与持久化，不触碰磁盘文件；被移除候选的路径**不会**加入
  /// 忽略列表（下轮 TTL 过期后仍可正常重新评估）。
  void _compactQueueOnStartup() {
    try {
      final before = _candidates.length;
      if (before == 0) return;

      // 1. 已入库路径冲突
      final dedupIndex = ImportDedupIndex.fromRegistry();
      _candidates.removeWhere((c) {
        final v = dedupIndex.check(c.dirPath);
        return v.isHardConflict && v.kind == DedupConflictKind.pathConflict;
      });
      final afterImported = _candidates.length;

      // 2 + 3. 队列内父子包含 / 同名副本
      final compacted = compactCandidates(_candidates);
      final changed = compacted.length != _candidates.length ||
          afterImported != before;
      if (!changed) return;

      _candidates
        ..clear()
        ..addAll(compacted);

      // 选中态失效修正
      if (_selectedCandidatePath != null &&
          !_candidates.any((c) => c.dirPath == _selectedCandidatePath)) {
        _selectedCandidatePath = null;
      }

      debugPrint('[WATCH] 🧹 启动队列自愈: $before → ${_candidates.length}'
          '（已入库路径冲突 ${before - afterImported} 个、'
          '队列内重复 ${afterImported - _candidates.length} 个）');
      _saveCandidates(); // 立即落盘（不走防抖）
      notifyListeners();
    } catch (e) {
      debugPrint('[WATCH] 启动队列自愈异常: $e');
    }
  }

  /// 队列压缩纯函数（与扫描阶段 4a/4b 语义对齐，供启动自愈与测试复用）
  ///
  /// 第 1 步（= 扫描 4a）：按 [TitleCleaner.normalizeForCompare] 推断标题键
  /// 分组，组内保留识别度最高者（平手取路径更浅者）；引擎明确不同不合并。
  /// 第 2 步（= 扫描 4b）：深度升序遍历，保留祖先、跳过后代；此外两份副本
  /// 各自抓到**同一条元数据**（title/metadataTitle 键相交）也视为同一游戏。
  ///
  /// 注意：不包含扫描阶段 4c（救援包装传播）——候选模型没有直接签名标记，
  /// 该场景由下一轮 TTL 过期后的重新扫描兜底。
  @visibleForTesting
  static List<ImportCandidate> compactCandidates(
      List<ImportCandidate> input) {
    // -- 第 1 步：同名分组选优
    final groups = <String, List<ImportCandidate>>{};
    for (final c in input) {
      final k = TitleCleaner.normalizeForCompare(c.title);
      if (k.isEmpty) continue;
      (groups[k] ??= []).add(c);
    }
    final losers = <ImportCandidate>{};
    groups.forEach((key, members) {
      if (members.length < 2) return;
      final engines = members
          .map((m) => m.engineType)
          .where((e) => e.isNotEmpty && e != 'unknown')
          .toSet();
      if (engines.length > 1) return; // 引擎冲突保守不合并
      ImportCandidate best = members.first;
      for (final m in members.skip(1)) {
        final mDepth = PathNormalizer.forCompare(m.dirPath).split('\\').length;
        final bDepth =
            PathNormalizer.forCompare(best.dirPath).split('\\').length;
        if (m.confidence > best.confidence ||
            (m.confidence == best.confidence && mDepth < bDepth)) {
          best = m;
        }
      }
      for (final m in members) {
        if (!identical(m, best)) losers.add(m);
      }
    });

    // -- 第 2 步：父子包含 + 元数据同名
    final ordered = input.where((c) => !losers.contains(c)).toList()
      ..sort((a, b) {
        final da = PathNormalizer.forCompare(a.dirPath).split('\\').length;
        final db = PathNormalizer.forCompare(b.dirPath).split('\\').length;
        if (da != db) return da - db;
        return PathNormalizer.forCompare(a.dirPath)
            .compareTo(PathNormalizer.forCompare(b.dirPath));
      });

    final kept = <ImportCandidate>[];
    // key -> 贡献者的引擎类型：判重时须过引擎门（与第 1 步一致），
    // 否则第 1 步判定"引擎冲突不合并"的候选会在第 2 步被标题键误杀。
    final keptKeys = <String, String>{};
    for (final c in ordered) {
      final pathKey = PathNormalizer.forCompare(c.dirPath);
      if (pathKey.isEmpty) continue;
      final overlapped = kept.any((k) {
        final kKey = PathNormalizer.forCompare(k.dirPath);
        return pathKey.startsWith('$kKey\\') || kKey.startsWith('$pathKey\\');
      });
      if (overlapped) continue;

      final keys = <String>{
        TitleCleaner.normalizeForCompare(c.title),
        TitleCleaner.normalizeForCompare(c.metadataTitle ?? ''),
      }..removeWhere((k) => k.isEmpty);
      final engine = c.engineType;
      final dup = keys.any((k) {
        final keptEngine = keptKeys[k];
        if (keptEngine == null) return false;
        final conflict = engine.isNotEmpty &&
            keptEngine.isNotEmpty &&
            engine != 'unknown' &&
            keptEngine != 'unknown' &&
            engine != keptEngine;
        return !conflict;
      });
      if (dup) continue;
      for (final k in keys) {
        keptKeys.putIfAbsent(k, () => engine);
      }
      kept.add(c);
    }
    return kept;
  }

  /// 停止所有监控
  void stopAll() {
    for (final path in {..._watchers.keys, ..._pollOnlyPaths}.toList()) {
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
  ///
  /// ★ 2026-09-26 NAS 映射网络驱动器适配：网络路径（UNC / 映射盘）**不做**
  /// `Directory.watch`，退化为纯轮询。
  ///
  /// 原因（Windows 事实）：
  /// ① `Directory.watch` 底层是 `ReadDirectoryChangesW`，在 SMB 共享上事件
  ///    常静默丢失或不触发 —— 建立了订阅也拿不到变更通知；
  /// ② 建立订阅需要打开目录句柄，盘离线时会**同步阻塞**在 SMB 超时上，
  ///    而本方法运行在 UI isolate（`existsSync` 同理）；
  /// ③ 变更检测本就有 `_pollTimer` 双保险，轮询是网络盘上唯一可靠的通道。
  ///
  /// 因此这里不再对网络路径做任何同步 IO，直接登记为「仅轮询」。
  void _startWatching(String path) {
    if (_watchers.containsKey(path) || _pollOnlyPaths.contains(path)) return;

    if (NetworkPath.isNetwork(path)) {
      _pollOnlyPaths.add(path);
      debugPrint('[WATCH] 🌐 网络路径改用轮询监听（SMB 实时事件不可靠）: $path');
      return;
    }

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
    _pollOnlyPaths.remove(path);
    _debounceTimers[path]?.cancel();
    _debounceTimers.remove(path);
  }

  /// watcher 健康检查：每 5 分钟检查一次，失效路径自动重连
  ///
  /// ★ 2026-09-26 NAS 适配：跳过网络路径。它们没有 watcher 需要重连
  /// （纯轮询兜底），且此处 `existsSync` 会在映射盘离线时同步阻塞 UI isolate。
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      for (final folder in _watchFolders) {
        if (!folder.enabled) continue;
        if (NetworkPath.isNetwork(folder.path)) continue;
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
      final allDirs = <String>[];
      await _collectCandidateDirs(dir, allDirs, watchPath,
          depth: 0, excludePatterns: folder.excludePatterns);

      if (allDirs.isEmpty) return;

      // 增量过滤：忽略列表 + TTL 已扫描目录（24h 内不重复评估）
      final candidates = allDirs.where((c) {
        if (_ignoredPaths.contains(PathNormalizer.forCompare(c))) {
          return false;
        }
        return !_isScannedRecently(c);
      }).toList();

      if (candidates.isEmpty) return;

      // ★ 批次级构建排重索引：与批量导入一致的多维排重
      //（路径包含硬冲突 + 同名软警告），跳过已入库游戏
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

      // ★ 五阶段共享扫描管线（与批量导入完全一致）：
      // 严格识别（主程序门槛+通用名拦截）→ 包装文件夹救援 → 归纳文件夹剔除
      // → 父子重叠去重 → 共享启动程序去重。
      // 替代旧的逐目录 processCandidate 独立判定——旧方式缺失后四个阶段，
      // 导致同一游戏的多个子程序被重复识别、启动器合集连带子游戏重复导入、
      // 游戏命名取错目录层级等问题（本轮优化核心修复点）。
      await GameFolderScanner.scanGames(
        rootPath: watchPath,
        candidates: candidates,
        excludePatterns: folder.excludePatterns,
        maxDepth: _maxScanDepth,
        dedupIndex: dedupIndex,
        minConfidence: _confidenceThreshold,
        onEvaluateStart: (dirPath) {
          _scanProcessedDirs++;
          _currentScanPath = dirPath;
          // ★ 时间节流：至少 500ms 间隔才 notifyListeners
          final now = DateTime.now();
          if (now.difference(lastNotifyTime) >= notifyThrottle) {
            notifyListeners();
            lastNotifyTime = now;
          }
        },
        onDecision: (dirPath, decision) {
          if (!decision.accepted || decision.game == null) return;
          final game = decision.game!;

          // 入队防重：与已入队候选拒绝路径重叠（父子包含）的目录不再入队。
          // 跨批次场景（父目录先前已入队、本次新增其子目录）下，
          // 五阶段管线看不到历史入队候选，须在此兜底防重复。
          final overlapsQueued = _candidates.any((c) =>
              PathNormalizer.forCompare(c.dirPath) ==
                  PathNormalizer.forCompare(game.path) ||
              PathNormalizer.isSubdirectory(c.dirPath, game.path) ||
              PathNormalizer.isSubdirectory(game.path, c.dirPath));
          if (overlapsQueued) {
            debugPrint('[WATCH] ✗ 跳过与已入队候选路径重叠的目录: '
                '${game.path}');
            return;
          }

          // ★ 入队防重（同名维度，2026-09-13 排重修复）：与已入队候选
          // 清洗后同题 → 视为同一游戏的另一份副本，跳过（先入队者优先）。
          // 跨轮次场景（本轮只重评估 TTL 过期的目录）下扫描管线看不到
          // 前一轮已入队的候选，路径重叠检查覆盖不到"同名但互不包含"
          // 的副本，须在此兜底。
          final titleKey = TitleCleaner.normalizeForCompare(game.title);
          final sameTitleQueued = titleKey.isNotEmpty &&
              _candidates.any((c) =>
                  TitleCleaner.normalizeForCompare(c.title) == titleKey ||
                  TitleCleaner.normalizeForCompare(c.metadataTitle ?? '') ==
                      titleKey);
          if (sameTitleQueued) {
            debugPrint('[WATCH] ✗ 跳过与已入队候选同名的目录'
                '（同一游戏的另一份副本）: ${game.path}');
            return;
          }

          final candidate = ImportCandidate(
            dirPath: game.path,
            // 扫描器标题 = TitleCleaner 清洗文件夹名（清洗为空回退文件夹名，
            // 与批量导入命名规则一致，修复旧方式清洗为空时的空标题问题）
            inferredTitle: game.title,
            confidence: game.detection.confidence,
            discoveredAt: DateTime.now(),
            engineType: game.detection.engineType,
            mainExeName: game.detection.mainExeName,
            reasonSummary: game.detection.reasonSummary,
            duplicateWarning: game.duplicateWarning,
          );
          // 两种模式统一入队，由后台富化队列处理：
          // - 确认模式：富化完成后等用户确认
          // - 静默模式：富化成功自动入库 / 失败转确认队列
          _candidates.add(candidate);
          _scanFoundCount++;
          foundInThisScan++;
          notifyListeners();
          // 触发后台元数据富化（3 并发）
          _pumpEnrichmentQueue();
        },
      );

      // 标记本轮评估过的候选为已扫描（TTL 内不再重复评估）
      for (final candidatePath in candidates) {
        _markScanned(candidatePath);
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

  /// 元数据富化队列调度（worker 池模式，最多 3 并发）
  ///
  /// 每当有新的 pending 候选入队时调用；每个 worker 完成后会自动补充下一个。
  void _pumpEnrichmentQueue() {
    while (_enrichingPaths.length < _maxConcurrentEnrich) {
      ImportCandidate? next;
      for (final c in _candidates) {
        if (c.taskStatus == CandidateTaskStatus.pending &&
            !_enrichingPaths.contains(c.dirPath)) {
          next = c;
          break;
        }
      }
      if (next == null) break;

      _enrichingPaths.add(next.dirPath);
      next.taskStatus = CandidateTaskStatus.processing;
      notifyListeners();

      // final 拷贝：闭包内无法对可变局部变量做类型提升
      final current = next;
      // fire-and-forget worker，完成后补充下一个任务
      _enrichOne(current).whenComplete(() {
        _enrichingPaths.remove(current.dirPath);
        _pumpEnrichmentQueue();
      });
    }
  }

  /// 富化单个候选并按模式处理结果
  ///
  /// - 失败：留在队列（failed 状态），两种模式下均等用户处理
  ///   （静默模式富化失败转入确认队列 = 用户决策 1）
  /// - 就绪 + 静默模式：自动入库；硬重复自动忽略（加入忽略列表防重扫）
  /// - 就绪 + 确认模式：等用户确认
  Future<void> _enrichOne(ImportCandidate candidate) async {
    final ok = await AutoImportPipeline.enrichCandidate(
      candidate: candidate,
      onCoverDownloaded: () {
        // 封面下载完成，刷新卡片/表单
        notifyListeners();
      },
    );

    if (!ok) {
      debugPrint('[WATCH] ⚠️ 富化失败，等待用户处理: ${candidate.title}');
      notifyListeners();
      return;
    }

    if (_importMode == AutoImportMode.silent) {
      if (candidate.isHardDuplicate) {
        // 静默模式硬重复：自动忽略并持久化（避免 TTL 过期后重扫）
        debugPrint('[WATCH] 静默模式跳过硬重复: ${candidate.title}');
        await ignoreCandidate(candidate);
      } else if (candidate.missingCoreFields.isNotEmpty) {
        // 数据完整性闸口（2026-10-03）：静默模式不自动入库数据不全的候选
        //（封面/简介任一缺失），留在队列由用户自行处理。
        debugPrint('[WATCH] 静默模式数据不全不自动入库: ${candidate.title}'
            '（缺${candidate.missingCoreFields.join('、')}）');
        notifyListeners();
      } else {
        debugPrint('[WATCH] 静默模式自动入库: ${candidate.title}');
        await confirmCandidate(candidate);
      }
    } else {
      notifyListeners();
    }
  }

  /// 重试富化失败的候选
  Future<void> retryCandidate(ImportCandidate candidate) async {
    if (candidate.taskStatus != CandidateTaskStatus.failed) return;
    candidate.taskStatus = CandidateTaskStatus.pending;
    candidate.errorMessage = null;
    // 清空旧抓取结果，重新抓取
    candidate.metadata = null;
    candidate.metadataTitle = null;
    candidate.isHardDuplicate = false;
    await _saveCandidates();
    notifyListeners();
    _pumpEnrichmentQueue();
  }

  /// 重试所有失败候选
  Future<void> retryAllFailed() async {
    for (final c in _candidates) {
      if (c.taskStatus == CandidateTaskStatus.failed) {
        c.taskStatus = CandidateTaskStatus.pending;
        c.errorMessage = null;
        c.metadata = null;
        c.metadataTitle = null;
        c.isHardDuplicate = false;
      }
    }
    await _saveCandidates();
    notifyListeners();
    _pumpEnrichmentQueue();
  }

  /// 确认入库候选游戏（完整字段入库，允许 failed 状态强制入库）
  Future<bool> confirmCandidate(ImportCandidate candidate) async {
    final success = await AutoImportPipeline.importCandidate(
      candidate: candidate,
      lockTitle: _lockTitle,
    );
    if (success) {
      candidate.imported = true;
      // 清理选中状态（若选中的正是该候选）
      if (_selectedCandidatePath == candidate.dirPath) {
        _selectedCandidatePath = null;
      }
      _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);
      await _saveCandidates();
      // 更新对应监控路径的 gameCount
      _refreshGameCountForPath(candidate.dirPath);
      notifyListeners();
    }
    return success;
  }

  /// 批量确认入库所有候选（仅就绪且非硬重复，对齐批量导入 submitBatchImport）
  ///
  /// ★ 关键修复：
  /// 1. 每处理完一个候选立即从 _candidates 移除并持久化，
  ///    而不是最后才 clear()。这样即使中途退出软件，已入库的不会残留。
  /// 2. 持久化 _isScanning 状态，重启后可检测到异常中断并清理。
  /// 3. 使用 try-finally 确保状态始终被正确重置。
  Future<int> confirmAllCandidates() async {
    // ★ IMP-11（2026-09-12 导入审查）：服务级互斥。
    // 本方法在入口**同步快照** toConfirm 之后才 await，两次并发调用（双击、或
    // UI 守卫失效）会对同一批候选各跑一遍 importCandidate —— 重复写 game.json、
    // 重复注册库条目。UI 侧已加守卫，这里再兜一层，保证服务被直接调用时也安全。
    if (_isImportingAll) {
      debugPrint('[WATCH] ⚠️ 批量入库已在进行中，忽略重复请求');
      return 0;
    }
    _isImportingAll = true;
    try {
      // 仅入库就绪候选；失败候选留在队列（用户可逐个重试/强制入库）
      // 数据完整性闸口（2026-10-03）：封面/简介任一缺失 = 数据不全，
      // 不批量入库、留在队列由用户处理（表单补全后再次「全部入库」即通过）。
      final toConfirm = _candidates
          .where((c) =>
              c.taskStatus == CandidateTaskStatus.ready &&
              !c.isHardDuplicate &&
              c.missingCoreFields.isEmpty)
          .toList();

      if (toConfirm.isEmpty) return 0;

      // 持久化导入状态（用于异常退出检测）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_isImportingKey, true);

      int successCount = 0;

      _isScanning = true;
      _scanTotalDirs = toConfirm.length;
      _scanProcessedDirs = 0;
      _scanFoundCount = 0;
      notifyListeners();

      try {
        int processed = 0;
        bool countDirty = false;
        for (final candidate in toConfirm) {
          _scanProcessedDirs++;
          _currentScanPath = candidate.title;

          final ok = await AutoImportPipeline.importCandidate(
            candidate: candidate,
            lockTitle: _lockTitle,
          );

          if (ok) {
            candidate.imported = true;
            successCount++;
            countDirty = true; // ★ P0-2: gameCount 收尾统一刷新，不再逐条
          }

          if (_selectedCandidatePath == candidate.dirPath) {
            _selectedCandidatePath = null;
          }
          _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);

          // ★ P0-2（2026-09-16 稳定性审计）：落盘与通知改为**每 N 条一次**。
          // 旧实现每条都 `await _saveCandidates()` + `notifyListeners()`：
          // 2000 条时是全量 JSON 编码 2000 次 + UI 全量重建 2000 次 → 卡死主因。
          // 崩溃恢复语义不退化：`_isImportingKey` 仍为 true，重启后
          // `_cleanupCrashedImportState` 会按"已入库路径"清掉残留候选。
          processed++;
          if (processed % _importPersistInterval == 0) {
            await _saveCandidates();
            notifyListeners();
          }
        }

        // 收尾：确保最终状态落盘 + 计数刷新 + 通知
        await _saveCandidates();
        if (countDirty) _refreshAllGameCounts();
        notifyListeners();
      } catch (e) {
        debugPrint('[WATCH] 批量入库异常: $e');
      } finally {
        // ★ try-finally 确保状态始终被重置
        _isScanning = false;
        _currentScanPath = '';
        await prefs.setBool(_isImportingKey, false);
        notifyListeners();
      }

      return successCount;
    } finally {
      // ★ IMP-11: 无论成功/失败/异常都释放互斥，避免永久锁死后续入库操作
      _isImportingAll = false;
    }
  }

  /// 忽略候选游戏（加入持久化忽略列表）
  Future<void> ignoreCandidate(ImportCandidate candidate) async {
    candidate.ignored = true;
    if (_selectedCandidatePath == candidate.dirPath) {
      _selectedCandidatePath = null;
    }
    _candidates.removeWhere((c) => c.dirPath == candidate.dirPath);
    _ignoredPaths.add(PathNormalizer.forCompare(candidate.dirPath));
    AutoImportPipeline.cleanupTempCover(candidate);
    await _saveCandidates();
    await _saveIgnored();
    notifyListeners();
  }

  /// 批量忽略所有候选
  Future<void> ignoreAllCandidates() async {
    for (final c in _candidates) {
      _ignoredPaths.add(PathNormalizer.forCompare(c.dirPath));
      AutoImportPipeline.cleanupTempCover(c);
    }
    _candidates.clear();
    _selectedCandidatePath = null;
    await _saveCandidates();
    await _saveIgnored();
    notifyListeners();
  }

  /// 清空所有候选（不加入忽略列表）
  Future<void> clearCandidates() async {
    for (final c in _candidates) {
      AutoImportPipeline.cleanupTempCover(c);
    }
    _candidates.clear();
    _selectedCandidatePath = null;
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

  /// 批量入库的落盘/通知间隔（★ P0-2）：2000 条时通知 2000 次 → 100 次
  static const int _importPersistInterval = 20;

  /// 收尾统一刷新所有监控路径的 gameCount（★ P0-2）
  ///
  /// 替代"每入库一条就 `_refreshGameCountForPath`"：后者每次都要遍历全库
  /// (`_countGamesUnderPath`) 且命中变化即 `_saveSettings()`，2000 条时是
  /// O(n²) 的遍历 + 上千次 prefs 写。现改为收尾一次遍历完成。
  void _refreshAllGameCounts() {
    try {
      final imported = AutoImportPipeline.allImportedDirectoryPaths
          .map((p) => PathNormalizer.forCompare(p))
          .toList();
      bool changed = false;
      for (int i = 0; i < _watchFolders.length; i++) {
        final folder = _watchFolders[i];
        final root = PathNormalizer.forCompare(folder.path);
        if (root.isEmpty) continue;
        final count = imported.where((p) => p.startsWith(root)).length;
        if (count != folder.gameCount) {
          _watchFolders[i] = folder.copyWith(
            gameCount: count,
            lastScanAt: DateTime.now(),
          );
          changed = true;
        }
      }
      if (changed) _saveSettings();
    } catch (e) {
      debugPrint('[WATCH] 刷新监控路径计数异常: $e');
    }
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
