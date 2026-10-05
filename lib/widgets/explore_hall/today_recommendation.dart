// 每日推荐纯计算（探索大厅 · 板块②相关话题）—— v2 维度轮换制
//
// 机制（2026-09-11 晚重设计，档案 §18；用户口径）：
// - 推荐数据四类：游戏标签 / 游戏会社 / 游戏星级 / 评分人数；
// - 每天系统从「维度池」确定性随机选一个维度：
//   · 星级 / 评分人数 → 全库按该字段降序取 8 部；
//   · 标签 / 会社（如「恋爱」「key 社」）→ 筛出该维度全部作品，
//     再按元数据星级降序排 8 部（无星级排尾部）；
// - 标签/会社维度池按全库出现频次取 Top [poolSize]，避免冷门值浪费当日名额；
// - 同日同数据 → 结果恒定（日期种子确定性选维度 + 确定性排序）；
//   服务层另以当日快照持久化做双保险（见 daily_recommendation_service.dart）；
// - 前置约束：仅在探索库数据就绪后由服务层调用，纯函数不感知加载状态。
//
// 纯 Dart 模块：输入是轻量候选结构，不直接依赖服务单例，便于单元测试。
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 参与推荐的候选（探索库游戏 + 元数据快照）
class RecommendedCandidate {
  final String gameId;
  final String title;
  final String coverUrl;
  final List<String> tags;
  final String developer;

  /// 星级（元数据平台，0-10）；null = 暂无评分数据
  final double? rating;

  /// 评分人数（热度代理）；null 视作 0
  final int? voteCount;

  const RecommendedCandidate({
    required this.gameId,
    required this.title,
    this.coverUrl = '',
    this.tags = const [],
    this.developer = '',
    this.rating,
    this.voteCount,
  });
}

/// 推荐结果条目
///
/// [score] 是该维度下的排序值（星级 / 评分人数），仅用于展示；
/// [tags]/[developer] 由生成路径填充；从当日快照恢复时可为空
/// （UI 用本地探索库 GameModel 按 gameId 回补）。
class RecommendedGame {
  final String gameId;
  final String title;
  final String coverUrl;
  final List<String> tags;
  final String developer;

  /// 该维度下的排序值（星级 / 评分人数）
  final double score;

  const RecommendedGame({
    required this.gameId,
    required this.title,
    this.coverUrl = '',
    this.tags = const [],
    this.developer = '',
    required this.score,
  });

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'title': title,
        'coverUrl': coverUrl,
        'tags': tags,
        'developer': developer,
        'score': score,
      };

  static RecommendedGame fromJson(Map<String, dynamic> j) => RecommendedGame(
        gameId: j['gameId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        coverUrl: j['coverUrl'] as String? ?? '',
        tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
        developer: j['developer'] as String? ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 0,
      );
}

/// 推荐维度
enum RecommendationDimension { rating, voteCount, tag, developer }

/// 一天的完整推荐方案（维度 + 结果 + 展示标签 + 序列化）
class RecommendationPlan {
  final DateTime day;
  final RecommendationDimension dimension;

  /// tag / developer 维度的具体值；全局维度为 null
  final String? dimensionValue;

  /// 展示用主题标签（如「恋爱」标签 · 按星级），机制对用户透明
  final String label;

  final List<RecommendedGame> items;

  const RecommendationPlan({
    required this.day,
    required this.dimension,
    this.dimensionValue,
    required this.label,
    required this.items,
  });

  Map<String, dynamic> toJson() => {
        // 快照格式版本：v2 起要求预热结束后生成（早于该修复的残缺快照
        // 无此字段，读入时被丢弃重生成——2026-09-11 晚补丁）
        'version': 2,
        'day':
            '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        'dimension': dimension.name,
        'dimensionValue': dimensionValue,
        'label': label,
        'items': [for (final g in items) g.toJson()],
      };

  static RecommendationPlan fromJson(Map<String, dynamic> j) {
    if (j['version'] != 2) {
      throw FormatException('快照版本过旧（version=${j['version']}），丢弃重生成');
    }
    final dayStr = j['day'] as String? ?? '';
    final parts = dayStr.split('-');
    if (parts.length != 3) {
      // day 异常直接抛给调用方（load 会捕获并丢弃快照重新生成），
      // 避免 fallback 到 now() 把过期快照误判为当日
      throw FormatException('快照 day 字段异常: $dayStr');
    }
    final day = DateTime(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    return RecommendationPlan(
      day: day,
      dimension: RecommendationDimension.values.firstWhere(
        (d) => d.name == j['dimension'],
        orElse: () => RecommendationDimension.rating,
      ),
      dimensionValue: j['dimensionValue'] as String?,
      label: j['label'] as String? ?? '',
      items: [
        for (final it in (j['items'] as List? ?? const []))
          RecommendedGame.fromJson(it as Map<String, dynamic>),
      ],
    );
  }
}

class DailyRecommendationPlanner {
  DailyRecommendationPlanner._();

  /// 最终展示数量
  static const int takeCount = 8;

  /// 标签 / 会社维度池大小（按全库出现频次取 Top N）
  static const int poolSize = 24;

  /// 当日方案入口：建维度池 → 日期种子选维度 → 生成；
  /// 选中维度筛不出作品（如全库无星级）时从种子位顺延尝试其余维度，
  /// 全部为空则返回空方案（服务层照常持久化，当日不再反复重算）。
  static RecommendationPlan plan({
    required List<RecommendedCandidate> candidates,
    required DateTime day,
    int take = takeCount,
  }) {
    final pool = _buildPool(candidates);
    final seed = day.year * 10000 + day.month * 100 + day.day;
    final startIndex = pool.isEmpty ? 0 : Random(seed).nextInt(pool.length);

    RecommendationPlan? fallback;
    for (var k = 0; k < pool.length; k++) {
      final (dim, value) = pool[(startIndex + k) % pool.length];
      final plan = planFor(
        candidates: candidates,
        day: day,
        dimension: dim,
        dimensionValue: value,
        take: take,
      );
      if (plan.items.isNotEmpty) return plan;
      fallback ??= plan;
    }
    return fallback ??
        RecommendationPlan(
          day: DateTime(day.year, day.month, day.day),
          dimension: RecommendationDimension.rating,
          label: '今日暂无推荐数据',
          items: const [],
        );
  }

  /// 指定维度生成（公开以便单测直接断言排序行为）
  static RecommendationPlan planFor({
    required List<RecommendedCandidate> candidates,
    required DateTime day,
    required RecommendationDimension dimension,
    String? dimensionValue,
    int take = takeCount,
  }) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final List<RecommendedGame> items;
    final String label;
    switch (dimension) {
      case RecommendationDimension.rating:
        label = '全库高星 · 按星级排序';
        items = _rank(
          candidates.where((c) => (c.rating ?? 0) > 0),
          scoreOf: (c) => c.rating!,
          tiebreakVoteFirst: false,
        );
      case RecommendationDimension.voteCount:
        label = '全库热议 · 按评分人数排序';
        items = _rank(
          candidates.where((c) => (c.voteCount ?? 0) > 0),
          scoreOf: (c) => (c.voteCount ?? 0).toDouble(),
          tiebreakVoteFirst: false, // 主排序已是票数，同票按星级分高下
        );
      case RecommendationDimension.tag:
        final v = dimensionValue ?? '';
        label = '「$v」标签 · 按星级排序';
        items = _rank(
          candidates.where((c) => c.tags.contains(v)),
          scoreOf: (c) => c.rating ?? 0, // 无星级排尾部，不剔除
          tiebreakVoteFirst: true,
        );
      case RecommendationDimension.developer:
        final v = dimensionValue ?? '';
        label = '$v · 精选（按星级排序）';
        items = _rank(
          candidates.where((c) => c.developer == v),
          scoreOf: (c) => c.rating ?? 0,
          tiebreakVoteFirst: true,
        );
    }
    return RecommendationPlan(
      day: normalizedDay,
      dimension: dimension,
      dimensionValue: dimensionValue,
      label: label,
      items: items.take(take).toList(),
    );
  }

  /// 统一排序：主排序字段降序 → 次级（voteCount 或 rating）降序 →
  /// gameId 升序兜底（保证同数据结果完全确定）
  static List<RecommendedGame> _rank(
    Iterable<RecommendedCandidate> source, {
    required double Function(RecommendedCandidate) scoreOf,
    required bool tiebreakVoteFirst,
  }) {
    final candidates = source.toList()
      ..sort((a, b) {
        final byScore = scoreOf(b).compareTo(scoreOf(a));
        if (byScore != 0) return byScore;
        if (tiebreakVoteFirst) {
          final byVotes = (b.voteCount ?? 0).compareTo(a.voteCount ?? 0);
          if (byVotes != 0) return byVotes;
        } else {
          final byRating = (b.rating ?? 0).compareTo(a.rating ?? 0);
          if (byRating != 0) return byRating;
        }
        return a.gameId.compareTo(b.gameId);
      });
    return [
      for (final c in candidates)
        RecommendedGame(
          gameId: c.gameId,
          title: c.title,
          coverUrl: c.coverUrl,
          tags: c.tags,
          developer: c.developer,
          score: scoreOf(c),
        )
    ];
  }

  /// 维度池：rating / voteCount 两个全局维度 + 高频标签 / 会社 Top N
  ///
  /// 池元素确定性排序（频次降序 → 名称升序），同数据同池。
  @visibleForTesting
  static List<(RecommendationDimension, String?)> buildPool(
      List<RecommendedCandidate> candidates) {
    return _buildPool(candidates);
  }

  static List<(RecommendationDimension, String?)> _buildPool(
      List<RecommendedCandidate> candidates) {
    final tagCounts = <String, int>{};
    final devCounts = <String, int>{};
    for (final c in candidates) {
      for (final t in c.tags) {
        final key = t.trim();
        if (key.isEmpty) continue;
        tagCounts[key] = (tagCounts[key] ?? 0) + 1;
      }
      final d = c.developer.trim();
      if (d.isNotEmpty) devCounts[d] = (devCounts[d] ?? 0) + 1;
    }
    List<String> topKeys(Map<String, int> counts) {
      final keys = counts.keys.toList()
        ..sort((a, b) {
          final byCount = counts[b]!.compareTo(counts[a]!);
          if (byCount != 0) return byCount;
          return a.compareTo(b);
        });
      return keys.take(poolSize).toList();
    }

    return [
      (RecommendationDimension.rating, null),
      (RecommendationDimension.voteCount, null),
      ...[for (final t in topKeys(tagCounts)) (RecommendationDimension.tag, t)],
      ...[
        for (final d in topKeys(devCounts))
          (RecommendationDimension.developer, d)
      ],
    ];
  }
}
