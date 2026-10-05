import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../models/game_model.dart';
import '../repositories/game_repository.dart';
import '../widgets/explore_hall/calendar_grid.dart';
import 'discover_metadata_service.dart';

/// 探索库全量快照 + 发售月历聚合 + 后台预热（探索大厅 · 板块①②数据源）
///
/// - 全量游戏：[GameRepository.getAllGames] 拉取（服务端分页驱动 + 去重）
/// - 发售日期：[DiscoverMetadataService] 的 releaseDate（视口懒加载 →
///   预热补全）。v2.1.17 起优先取云端沉淀的 `GameModel.releaseDate`
///   （GameModel 只描述云端记录、不参与 game.json 的 format_version 迁移链，
///   故扩展字段安全），云端没有的才需要预热补抓
/// - 预热节流：24h 状态文件（`data/cache/explore_calendar_warmup.json`）；
///   「抓取失败/空结果」以 attemptedIds 记录，24h 内不重试，避免反复打源站
/// - 渐进填充：每抓 5 部重聚合 + notifyListeners，月历逐步点亮
class ExploreCalendarService extends ChangeNotifier {
  ExploreCalendarService._();

  static final ExploreCalendarService _instance = ExploreCalendarService._();
  static ExploreCalendarService get instance => _instance;

  /// 仅供测试：创建独立实例（不触发任何网络请求）
  @visibleForTesting
  ExploreCalendarService.forTest();

  static const int _perPage = 100;
  static const Duration _warmupThrottle = Duration(hours: 24);
  static const int _maxAttemptedIds = 6000;

  final List<GameModel> _games = [];
  final Map<DateTime, List<GameModel>> _byDate = {};
  final List<GameModel> _undated = [];
  bool _gamesLoaded = false;
  bool _loadingGames = false;
  bool _gamesFailed = false;

  int _warmTotal = -1;
  int _warmFilled = 0;
  bool _warming = false;
  final Set<String> _attempted = {};
  DateTime? _lastWarmupAt;

  // ---- 快照访问 ----

  List<GameModel> get games => List.unmodifiable(_games);
  Map<DateTime, List<GameModel>> get gamesByDate => Map.unmodifiable(_byDate);
  List<GameModel> get undatedGames => List.unmodifiable(_undated);
  bool get gamesLoaded => _gamesLoaded;

  /// 全量列表最近一次加载是否失败（UI 据此显示「点击重试」）
  bool get gamesFailed => _gamesFailed;

  /// 已取得发售日的游戏数
  int get datedCount => _games.length - _undated.length;

  bool get isWarming => _warming;
  int get warmTotal => _warmTotal;
  int get warmFilled => _warmFilled;

  String get _stateFilePath =>
      p.join(PathHelper.dataDir, 'cache', 'explore_calendar_warmup.json');

  /// 加载预热状态（24h 节流时间戳 + attemptedIds）
  Future<void> loadState() async {
    try {
      final file = File(_stateFilePath);
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        final ts = (data['last_warmup_at'] as num?)?.toInt();
        if (ts != null) _lastWarmupAt = DateTime.fromMillisecondsSinceEpoch(ts);
        final ids = data['attempted_ids'];
        if (ids is List) {
          _attempted
            ..clear()
            ..addAll(ids.whereType<String>());
        }
      }
    } catch (e) {
      debugPrint('[ExploreCalendar] ⚠️ 加载预热状态失败: $e');
    }
  }

  Future<void> _persistState() async {
    try {
      final file = File(_stateFilePath);
      await file.parent.create(recursive: true);
      // attemptedIds 防膨胀：超上限时保留最新一段
      final ids = _attempted.length > _maxAttemptedIds
          ? _attempted.skip(_attempted.length - _maxAttemptedIds).toList()
          : _attempted.toList();
      final tmp = File('$_stateFilePath.tmp');
      await tmp.writeAsString(jsonEncode({
        'last_warmup_at': _lastWarmupAt?.millisecondsSinceEpoch,
        'attempted_ids': ids,
      }));
      await tmp.rename(_stateFilePath);
    } catch (e) {
      debugPrint('[ExploreCalendar] ⚠️ 持久化预热状态失败: $e');
    }
  }

  /// 后台全量拉取探索库游戏列表（幂等；失败置 gamesFailed 供 UI 重试）
  ///
  /// 走 [GameRepository.getAllGames]：服务端 totalPages 驱动翻页 + 单页
  /// 失败重试 + 按 id 去重（game_repository.dart:128 的历史教训——
  /// 「返回条数 == perPage」推断会在服务端钳制 perPage 时误判加载完成）。
  Future<void> ensureGamesLoaded() async {
    if (_gamesLoaded || _loadingGames) return;
    _loadingGames = true;
    _gamesFailed = false;
    try {
      final result = await GameRepository.getAllGames(perPage: _perPage);
      _games
        ..clear()
        ..addAll(result.games);
      // v2.1.17：云端已沉淀的评分/发售日直接入缓存 → 预热只需补抓真正缺失的
      DiscoverMetadataService.instance.registerCloudMetadataAll(result.games);
      _reaggregate();
      _gamesLoaded = true;
      debugPrint(
          '[ExploreCalendar] ✅ 全量加载 ${_games.length} 部（完整=${result.isComplete}）');
      notifyListeners();
    } catch (e) {
      _gamesFailed = true;
      notifyListeners();
      debugPrint('[ExploreCalendar] ❌ 全量加载失败: $e');
    } finally {
      _loadingGames = false;
    }
  }

  void _reaggregate() {
    _byDate.clear();
    _undated.clear();
    for (final g in _games) {
      final meta = DiscoverMetadataService.instance.getMetadata(g.id);
      final date = CalendarGrid.parseIsoDate(meta?.releaseDate);
      if (date == null) {
        _undated.add(g);
      } else {
        _byDate.putIfAbsent(date, () => []).add(g);
      }
    }
  }

  /// 后台预热：对缺失元数据的游戏逐个补抓
  /// （DiscoverMetadataService 内部全局串行 + 7 天磁盘缓存）。
  ///
  /// [force] 忽略 24h 节流强制重试（调试用）。
  ///
  /// 🔴 进入即置 [_warming]、结束才清零（2026-09-11 晚修复）：全量列表
  /// 加载完成的 notify 发生在预热期内，DailyRecommendationService 等
  /// 下游以「gamesLoaded && !isWarming」判定数据完全可读——若此处延迟
  /// 置位，列表加载完成的那次 notify 会漏判为就绪，锁定一份缺元数据
  /// 的当日快照（正是"推荐数据不完整"的根因）。
  Future<void> startWarmup({bool force = false}) async {
    if (_warming) return;
    _warming = true;
    notifyListeners();
    var gained = 0; // 本次预热实际新增「有元数据」的数量
    try {
      await DiscoverMetadataService.instance.init();
      await loadState();
      await ensureGamesLoaded();
      if (_games.isEmpty) return;

      final throttled = !force &&
          _lastWarmupAt != null &&
          DateTime.now().difference(_lastWarmupAt!) < _warmupThrottle;
      if (throttled) {
        debugPrint('[ExploreCalendar] ⏱️ 24h 节流：跳过全量预热');
        return;
      }

      final missing = _games
          .where((g) =>
              !_attempted.contains(g.id) &&
              DiscoverMetadataService.instance.getMetadata(g.id) == null)
          .toList();

      _warmTotal = missing.length;
      _warmFilled = 0;
      notifyListeners();

      for (final g in missing) {
        _attempted.add(g.id);
        try {
          await DiscoverMetadataService.instance.ensureMetadata(g.id, g.title);
        } catch (_) {
          // ensureMetadata 内部已全兜底，这里防御性吞掉
        }
        if (DiscoverMetadataService.instance.getMetadata(g.id) != null) {
          gained++;
        }
        _warmFilled++;
        if (_warmFilled % 5 == 0 || _warmFilled == _warmTotal) {
          _reaggregate();
          notifyListeners();
        }
      }
    } finally {
      _warming = false;
      // 全军覆没视为网络级失败：不写节流戳、不持久化 attempted，
      // 下次启动自动整轮重试（避免一次断网把日历/推荐自锁 24h）。
      // 有成功则照旧持久化（attempted 屏蔽源站真缺失的条目反复重打）。
      if (gained > 0) {
        _lastWarmupAt = DateTime.now();
        await _persistState();
      } else {
        _attempted.clear();
      }
      _reaggregate();
      notifyListeners();
      debugPrint(
          '[ExploreCalendar] ✅ 预热流程结束（本次新增 $gained），有发售日 $datedCount 部');
    }
  }

  /// 测试注入：直接塞入游戏列表（绕过网络）
  @visibleForTesting
  void debugInjectGames(List<GameModel> games) {
    _games
      ..clear()
      ..addAll(games);
    _gamesLoaded = true;
    _reaggregate();
    notifyListeners();
  }
}
