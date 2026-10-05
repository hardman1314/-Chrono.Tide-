import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../widgets/explore_hall/today_recommendation.dart';
import 'discover_metadata_service.dart';
import 'explore_calendar_service.dart';

/// 当日推荐快照 + 持久化 + 就绪编排（探索大厅 · 板块②相关话题）
///
/// 稳定性设计（用户痛点：推荐「莫名其妙就变了」）：
/// - 旧实现每次元数据补全都触发全量重算，列表随评分补全不断闪变；
/// - 现在生成后整份快照落盘 `data/daily_recommendation.json`，
///   **当日一律读快照、绝不重算**——元数据后续补全不影响当日结果；
/// - 生成本身也是确定性的（日期种子选维度 + 确定性排序），
///   即使缓存丢失，重算同样得到一致结果（双保险）；
/// - 生成前置：探索库数据就绪（全量列表加载完成且预热流程结束，
///   见 [_isCalendarReady]），符合「先等数据完全可读再安排推荐」的口径。
class DailyRecommendationService extends ChangeNotifier {
  DailyRecommendationService._()
      : _reader = null,
        _writer = null;

  static final DailyRecommendationService instance =
      DailyRecommendationService._();

  /// 测试注入：内存读写，不碰磁盘
  @visibleForTesting
  DailyRecommendationService.forTest({
    String? Function()? reader,
    void Function(String)? writer,
  })  : _reader = reader,
        _writer = writer;

  final String? Function()? _reader;
  final void Function(String)? _writer;

  static String get _filePath =>
      p.join(PathHelper.dataDir, 'daily_recommendation.json');
  RecommendationPlan? _plan;
  bool _attached = false;
  ExploreCalendarService? _calendar;

  /// 当日快照（无则 null，UI 显示「整理中」）
  RecommendationPlan? get plan => _plan;

  /// 快照是否属于今天
  bool get _hasToday {
    final s = _plan;
    if (s == null) return false;
    final n = DateTime.now();
    return s.day.year == n.year && s.day.month == n.month && s.day.day == n.day;
  }

  /// 启动读取持久化快照；仅当日快照生效，旧快照静默丢弃
  Future<void> load() async {
    String? raw;
    try {
      raw = _reader != null ? _reader() : _readDisk();
    } catch (e) {
      debugPrint('[DailyRecommendation] ⚠️ 读取快照失败: $e');
      raw = null;
    }
    if (raw == null || raw.isEmpty) return;
    try {
      final plan = RecommendationPlan.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      final n = DateTime.now();
      final isToday = plan.day.year == n.year &&
          plan.day.month == n.month &&
          plan.day.day == n.day;
      if (!isToday) {
        debugPrint('[DailyRecommendation] ⏭️ 快照非今日（${plan.day}），丢弃');
        return;
      }
      _plan = plan;
      notifyListeners();
      debugPrint(
          '[DailyRecommendation] ✅ 命中当日快照：${plan.label}（${plan.items.length} 部）');
    } catch (e) {
      debugPrint('[DailyRecommendation] ⚠️ 快照解析失败，将重新生成: $e');
    }
  }

  String? _readDisk() {
    final file = File(_filePath);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }

  void _writeDisk(String raw) {
    try {
      final file = File(_filePath);
      file.parent.createSync(recursive: true);
      final tmp = File('$_filePath.tmp');
      tmp.writeAsStringSync(raw);
      tmp.rename(_filePath); // 原子替换，防写一半损坏
    } catch (e) {
      debugPrint('[DailyRecommendation] ⚠️ 快照写入失败: $e');
    }
  }

  /// 绑定探索库快照服务：监听其状态，当日无快照时在数据就绪后自动生成
  ///
  /// 大厅页面 initState 调用；[detach] 于 dispose。
  void attach(ExploreCalendarService calendar) {
    if (_attached) return;
    _attached = true;
    _calendar = calendar;
    calendar.addListener(_onCalendarChanged);
    _onCalendarChanged();
  }

  void detach() {
    _calendar?.removeListener(_onCalendarChanged);
    _calendar = null;
    _attached = false;
  }

  void _onCalendarChanged() {
    if (_hasToday) return; // 当日已定 → 永不重算（稳定性核心）
    final c = _calendar;
    if (c == null) return;
    if (!_isCalendarReady(c)) return;
    _generate(c);
  }

  /// 数据就绪口径（用户：「先等探索库数据彻底加载好再安排推荐」）：
  /// 全量列表加载完成（或失败但已有存量数据）且预热补抓流程结束。
  static bool _isCalendarReady(ExploreCalendarService c) =>
      (c.gamesLoaded || (c.gamesFailed && c.games.isNotEmpty)) && !c.isWarming;

  void _generate(ExploreCalendarService calendar) {
    final meta = DiscoverMetadataService.instance;
    final candidates = [
      for (final g in calendar.games)
        RecommendedCandidate(
          gameId: g.id,
          title: g.title,
          coverUrl: g.coverUrl,
          tags: g.tags,
          developer: g.developer,
          rating: meta.getMetadata(g.id)?.rating,
          voteCount: meta.getMetadata(g.id)?.voteCount,
        )
    ];
    final plan = DailyRecommendationPlanner.plan(
        candidates: candidates, day: DateTime.now());
    _plan = plan;
    notifyListeners();
    debugPrint(
        '[DailyRecommendation] 🎲 生成当日推荐：${plan.label}（${plan.items.length} 部）');
    final raw = jsonEncode(plan.toJson());
    if (_writer != null) {
      _writer(raw);
    } else {
      _writeDisk(raw);
    }
  }

  /// 手动重算（调试/长按刷新用；正常路径不该走到）
  @visibleForTesting
  void debugRegenerate() {
    final c = _calendar;
    if (c == null || !_isCalendarReady(c)) return;
    _generate(c);
  }
}
