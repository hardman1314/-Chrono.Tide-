import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/widgets/explore_hall/today_recommendation.dart';

/// 每日推荐纯函数测试（v2 维度轮换制，档案 §18）
///
/// 覆盖：四维度排序口径 / 截断与次级排序 / 同日恒定与跨日轮换 /
/// 空维度 fallback / 序列化 round-trip / 维度池构建。
RecommendedCandidate _c(
  String id, {
  double? rating,
  int? votes,
  List<String> tags = const [],
  String developer = '',
}) =>
    RecommendedCandidate(
      gameId: id,
      title: '游戏$id',
      tags: tags,
      developer: developer,
      rating: rating,
      voteCount: votes,
    );

void main() {
  final day = DateTime(2026, 9, 11);

  group('planFor · 星级维度', () {
    test('全库按星级降序，无星级不参与', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('a', rating: 8.0),
          _c('b', rating: 9.5),
          _c('c', rating: 7.1),
          _c('d'), // 无星级 → 排除
        ],
        day: day,
        dimension: RecommendationDimension.rating,
      );
      expect(plan.items.map((g) => g.gameId).toList(), ['b', 'a', 'c']);
      expect(plan.label, contains('星级'));
    });

    test('超过 8 部截断；同分按评分人数降序', () {
      final candidates = [
        for (var i = 0; i < 12; i++) _c('g$i', rating: 8.0, votes: 100 - i),
        _c('top', rating: 9.9),
      ];
      final plan = DailyRecommendationPlanner.planFor(
        candidates: candidates,
        day: day,
        dimension: RecommendationDimension.rating,
      );
      expect(plan.items, hasLength(8));
      expect(plan.items.first.gameId, 'top');
      // 同分组内：票多的在前（g0 100 票 > g11 89 票）
      expect(plan.items[1].gameId, 'g0');
    });
  });

  group('planFor · 评分人数维度', () {
    test('按评分人数降序，星级为次级排序', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('hot1', votes: 5000, rating: 7.0),
          _c('hot2', votes: 5000, rating: 9.0), // 同票数星级优先
          _c('cold', votes: 10),
          _c('novote'), // 无票数 → 排除
        ],
        day: day,
        dimension: RecommendationDimension.voteCount,
      );
      expect(plan.items.map((g) => g.gameId).toList(), ['hot2', 'hot1', 'cold']);
    });
  });

  group('planFor · 标签维度', () {
    test('筛选标签后按星级降序，无星级排尾部不剔除', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('a', rating: 6.0, tags: ['恋爱']),
          _c('b', rating: 9.0, tags: ['恋爱']),
          _c('c', tags: ['恋爱']), // 无星级 → 尾部
          _c('d', rating: 9.9, tags: ['奇幻']), // 非目标标签 → 排除
        ],
        day: day,
        dimension: RecommendationDimension.tag,
        dimensionValue: '恋爱',
      );
      expect(plan.items.map((g) => g.gameId).toList(), ['b', 'a', 'c']);
      expect(plan.label, contains('恋爱'));
    });

    test('不足 8 部时全部保留', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('a', rating: 8.0, tags: ['废萌']),
          _c('b', rating: 7.0, tags: ['废萌']),
        ],
        day: day,
        dimension: RecommendationDimension.tag,
        dimensionValue: '废萌',
      );
      expect(plan.items, hasLength(2));
    });
  });

  group('planFor · 会社维度', () {
    test('按会社精确筛选后按星级排序', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('key1', rating: 8.8, developer: 'Key'),
          _c('key2', rating: 9.2, developer: 'Key'),
          _c('other', rating: 9.9, developer: 'AliceSoft'),
        ],
        day: day,
        dimension: RecommendationDimension.developer,
        dimensionValue: 'Key',
      );
      expect(plan.items.map((g) => g.gameId).toList(), ['key2', 'key1']);
      expect(plan.label, contains('Key'));
    });
  });

  group('plan · 每日维度选择', () {
    test('同日恒定：同数据同日两次生成完全一致', () {
      final candidates = [
        for (var i = 0; i < 20; i++)
          _c('g$i', rating: 5.0 + i / 10, votes: 100 * i, tags: ['tag$i']),
      ];
      final p1 = DailyRecommendationPlanner.plan(
          candidates: candidates, day: day);
      final p2 = DailyRecommendationPlanner.plan(
          candidates: candidates, day: day);
      expect(p1.dimension, p2.dimension);
      expect(p1.dimensionValue, p2.dimensionValue);
      expect(
        p1.items.map((g) => g.gameId).toList(),
        p2.items.map((g) => g.gameId).toList(),
      );
    });

    test('跨日轮换：无标签/会社数据时 60 天内两个全局维度都被选中', () {
      // 无 tags/developer → 池只剩 rating + voteCount 两项
      final candidates = [
        _c('a', rating: 9.0, votes: 100),
        _c('b', rating: 8.0, votes: 200),
      ];
      final dims = <RecommendationDimension>{};
      for (var i = 0; i < 60; i++) {
        final d = DateTime(2026, 1, 1).add(Duration(days: i));
        dims.add(DailyRecommendationPlanner.plan(
                candidates: candidates, day: d)
            .dimension);
      }
      expect(
          dims, containsAll([RecommendationDimension.rating, RecommendationDimension.voteCount]));
    });

    test('fallback：选中维度筛不出作品时顺延到有结果的维度', () {
      // 全库只有「恋爱」标签作品且都无星级 → rating/voteCount 维度皆空，
      // 种子命中全局维度时必须 fallback 到 tag 维度
      final candidates = [
        _c('a', tags: ['恋爱']),
        _c('b', tags: ['恋爱']),
        _c('c', tags: ['恋爱']),
      ];
      var sawTagResult = false;
      for (var i = 0; i < 100; i++) {
        final d = DateTime(2027, 3, 1).add(Duration(days: i));
        final plan =
            DailyRecommendationPlanner.plan(candidates: candidates, day: d);
        expect(plan.items, isNotEmpty, reason: '任何一天都不该产出空推荐');
        if (plan.dimension == RecommendationDimension.tag) {
          sawTagResult = true;
        }
      }
      expect(sawTagResult, isTrue);
    });
  });

  group('维度池', () {
    test('标签/会社按频次入池且有 poolSize 上限', () {
      final candidates = [
        for (var i = 0; i < 30; i++) _c('g$i', tags: ['t$i'], developer: 'd$i'),
      ];
      final pool = DailyRecommendationPlanner.buildPool(candidates);
      // rating + voteCount + 标签 24 + 会社 24
      expect(pool.length, 2 + DailyRecommendationPlanner.poolSize * 2);
    });
  });

  group('序列化', () {
    test('RecommendationPlan toJson/fromJson round-trip 保真', () {
      final plan = DailyRecommendationPlanner.planFor(
        candidates: [
          _c('a', rating: 9.1, votes: 120, tags: ['恋爱'], developer: 'Key'),
          _c('b', rating: 8.2, tags: ['恋爱']),
        ],
        day: day,
        dimension: RecommendationDimension.tag,
        dimensionValue: '恋爱',
      );
      final restored = RecommendationPlan.fromJson(plan.toJson());
      expect(restored.day, day);
      expect(restored.dimension, RecommendationDimension.tag);
      expect(restored.dimensionValue, '恋爱');
      expect(restored.label, plan.label);
      expect(restored.items.length, plan.items.length);
      expect(restored.items.first.gameId, plan.items.first.gameId);
      expect(restored.items.first.score, plan.items.first.score);
      expect(restored.items.first.tags, plan.items.first.tags);
    });
  });
}
