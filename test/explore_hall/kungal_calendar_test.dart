import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/kungal_calendar_game.dart';
import 'package:chrono_tide/services/kungal_calendar_service.dart';

/// KUNGAL 发售月历模型与服务单测
///
/// fixture 取自 2026-09-11 实测 kungal.com 公开接口真实响应（裁剪），
/// 保证解析口径与线上数据一致。
void main() {
  group('KungalCalendarGame 模型解析', () {
    const sampleDayItem = {
      'id': 60936,
      'name': '谜路2 人鱼传说杀人事件',
      'name_original': 'ミステリーの歩き方2 人魚伝説殺人事件',
      'company': 'Toybox Inc.',
      'release_date': '2026-09-01',
      'release_date_tba': false,
      'release_precision': 'day',
      'content_limit': 'sfw',
      'effective_portrait_url':
          'https://image.kungal.iloveren.link/71/ac/71ac.webp',
      'rating': 8.2,
      'rating_count': 42,
    };

    test('day 精度条目：全字段解析正确', () {
      final g = KungalCalendarGame.fromJson(sampleDayItem);
      expect(g.id, 60936);
      expect(g.name, '谜路2 人鱼传说杀人事件');
      expect(g.nameOriginal, contains('人魚伝説'));
      expect(g.company, 'Toybox Inc.');
      expect(g.releasePrecision, 'day');
      expect(g.exactDate, DateTime(2026, 9, 1));
      expect(g.isNsfw, isFalse);
      expect(g.rating, 8.2);
      expect(g.ratingCount, 42);
      expect(g.detailUrl, 'https://www.kungal.com/galgame/60936');
      expect(g.displayName, '谜路2 人鱼传说杀人事件');
    });

    test('nsfw 条目与防御性缺字段', () {
      final g = KungalCalendarGame.fromJson({
        'id': 123,
        'content_limit': 'nsfw',
      });
      expect(g.isNsfw, isTrue);
      expect(g.name, isEmpty);
      expect(g.exactDate, isNull); // 无 release_date → null
      expect(g.detailUrl, 'https://www.kungal.com/galgame/123');

      final bad = KungalCalendarGame.fromJson(const {});
      expect(bad.id, 0);
      expect(bad.detailUrl, isEmpty); // id 无效 → 空串，UI 不展示外跳
      expect(bad.exactDate, isNull);
      expect(bad.rating, isNull);
    });

    test('非 day 精度不产生确切日期（进待定桶）', () {
      for (final p in ['month', 'year', 'tba', 'unknown']) {
        final g = KungalCalendarGame.fromJson({
          'id': 1,
          'release_date': '2026-09-01',
          'release_precision': p,
        });
        expect(g.exactDate, isNull, reason: '精度 $p 不应产出确切日期');
      }
    });

    test('displayName：译名缺失回落原名', () {
      final g = KungalCalendarGame.fromJson({
        'id': 1,
        'name_original': '原題',
      });
      expect(g.displayName, '原題');
    });
  });

  group('标题规范化（本地探索库精确匹配）', () {
    test('空白/标点/全半角不敏感', () {
      expect(
        KungalCalendarGame.normalizeTitle('谜路2 人鱼传说杀人事件'),
        KungalCalendarGame.normalizeTitle('谜路2人鱼传说杀人事件'),
      );
      expect(
        KungalCalendarGame.normalizeTitle('CLANNAD！'), 
        KungalCalendarGame.normalizeTitle('clannad'),
      );
      expect(
        KungalCalendarGame.normalizeTitle('ＡＢＣ　Ｄ'), // 全角字母+全角空格
        KungalCalendarGame.normalizeTitle('abcd'),
      );
    });
  });

  group('parseIsoDate 容错', () {
    test('合法日期与各种非法输入', () {
      expect(KungalCalendarGame.parseIsoDate('2026-09-01'),
          DateTime(2026, 9, 1));
      // 带时间尾巴只取前 10 位
      expect(KungalCalendarGame.parseIsoDate('2026-09-01T12:00:00'),
          DateTime(2026, 9, 1));
      // tryParse 会进位解析的非法日期必须拒绝
      expect(KungalCalendarGame.parseIsoDate('9999-99-99'), isNull);
      // 部分精度 / 文本
      expect(KungalCalendarGame.parseIsoDate('2026-09'), isNull);
      expect(KungalCalendarGame.parseIsoDate('TBA'), isNull);
      expect(KungalCalendarGame.parseIsoDate(null), isNull);
      expect(KungalCalendarGame.parseIsoDate(''), isNull);
    });
  });

  group('KungalMonthData 月度聚合', () {
    test('byDate 按 day 精度分桶；bucket 收纳非 day 条目', () {
      final md = KungalMonthData.fromApi('2026-09', {
        'month': '2026-09',
        'today': '2026-09-11',
        'meta': {
          'prev_month': '2026-08',
          'next_month': '2026-10',
          'has_prev': true,
          'has_next': true,
          'min_month': '1982-00',
          'max_month': '2027-08',
          'count': 3,
        },
        'items': [
          {
            'id': 1,
            'name': 'A',
            'release_date': '2026-09-01',
            'release_precision': 'day',
          },
          {
            'id': 2,
            'name': 'B',
            'release_date': '2026-09-01',
            'release_precision': 'day',
          },
          {
            'id': 3,
            'name': 'C',
            'release_date': '2026-09-15',
            'release_precision': 'day',
          },
          {
            'id': 4,
            'name': 'D',
            'release_date': '2026-09-01',
            'release_precision': 'month',
          },
        ],
      });

      expect(md.month, '2026-09');
      expect(md.items.length, 4);
      expect(md.byDate[DateTime(2026, 9, 1)]!.length, 2);
      expect(md.byDate[DateTime(2026, 9, 15)]!.length, 1);
      expect(md.bucket.map((g) => g.name), ['D']);
      expect(md.hasPrev, isTrue);
      expect(md.hasNext, isTrue);
      expect(md.minMonth, '1982-00');
    });
  });

  group('KungalCalendarService（注入 fetcher，零网络）', () {
    test('ensureMonth：解析存内存，二次调用不发请求', () async {
      var fetchCount = 0;
      final svc = KungalCalendarService.forTest(fetchOverride: (url) async {
        fetchCount++;
        expect(url, contains('/catalog/calendar?month=2026-09'));
        return {
          // NextMoe 条目形状（2026-09-26 数据源切换）
          'items': [
            {
              'id': '1',
              'display_name': 'A',
              'release_date': '2026-09-01',
              'release_date_precision': 'day',
            },
          ],
        };
      });

      await svc.ensureMonth('2026-09');
      expect(fetchCount, 1);
      expect(svc.monthData('2026-09')?.items.length, 1);
      expect(svc.isFailed('month_2026-09'), isFalse);

      await svc.ensureMonth('2026-09'); // 内存命中
      expect(fetchCount, 1);
    });

    test('fetch 失败标记 failed，可 force 重试', () async {
      var fail = true;
      final svc = KungalCalendarService.forTest(fetchOverride: (url) async {
        if (fail) return null;
        return <String, dynamic>{
          'items': <Object>[], // NextMoe 空集合是合法结果
        };
      });

      await svc.ensureMonth('2026-10');
      expect(svc.isFailed('month_2026-10'), isTrue);
      expect(svc.monthData('2026-10'), isNull);

      fail = false;
      await svc.ensureMonth('2026-10', force: true);
      expect(svc.isFailed('month_2026-10'), isFalse);
      expect(svc.monthData('2026-10'), isNotNull);
    });

    test('ensureUpcoming：未来月合成（不再请求独立 upcoming 端点）', () async {
      // 官方 NextMoe 无独立 upcoming 端点：由未来 6 个月的 month 窗口合成；
      // 注入空集合时 upcoming 为空且不阻塞（不标失败之外的副作用）
      final svc = KungalCalendarService.forTest(fetchOverride: (url) async {
        expect(url, isNot(contains('/calendar/upcoming')),
            reason: '不应请求任何独立 upcoming 端点');
        return <String, dynamic>{'items': <Object>[]};
      });

      await svc.ensureUpcoming();
      expect(svc.upcomingGames, isEmpty);
    });

    test('ensurePending / ensureTba 解析', () async {
      final svc = KungalCalendarService.forTest(fetchOverride: (url) async {
        // NextMoe 数据源：待定桶 = year+precision=year，TBA 桶 = status=announced
        if (url.contains('precision=year')) {
          return {
            'items': [
              {
                'id': '9',
                'display_name': 'P',
                'release_date': '2026',
                'release_date_precision': 'month',
              },
            ],
          };
        }
        expect(url, contains('status=announced'));
        return {
          'items': [
            {
              'id': '10',
              'display_name': 'T1',
              'release_date': '',
              'release_date_precision': 'tba',
            },
            {
              'id': '11',
              'display_name': 'T2',
              'release_date': '',
              'release_date_precision': 'tba',
            },
          ],
        };
      });

      await svc.ensurePending('2026');
      expect(svc.pendingGames.length, 1);
      expect(svc.pendingLoadedYear, '2026');

      await svc.ensureTba();
      expect(svc.tbaGames.length, 2);
    });

    test('monthKey 补零格式', () {
      expect(KungalCalendarService.monthKey(DateTime(2026, 9, 11)), '2026-09');
      expect(KungalCalendarService.monthKey(DateTime(2026, 1, 1)), '2026-01');
    });
  });
}
