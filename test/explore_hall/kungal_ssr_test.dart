// SSR 数据源测试：真实 Nuxt devalue payload 解析（用实测抓取的页面片段重建）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/kungal_calendar_service.dart';

/// KUNGAL SSR 数据源测试（2026-09-13 起：REST 登录墙 → SSR 页面解析）
///
/// fixture 按 2026-09-13 实测 www.kungal.com/galgame-calendar 的
/// __NUXT_DATA__ 真实结构重建（devalue 扁平数组：字符串内联、布尔/数字
/// 裸 int 索引、对象内联字段值可为索引）。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_kungal_ssr_test');
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // 构造最小 Nuxt 页面（devalue 扁平数组，字段值索引化，与实测编码一致）
  String nuxtHtml({
    required String ym,
    required List<Map<String, dynamic>> works,
  }) {
    final payload = <dynamic>[];
    int alloc(Object? v) {
      payload.add(v);
      return payload.length - 1;
    }

    for (final w in works) {
      final obj = <String, dynamic>{
        'object': alloc('work'),
        'id': alloc(w['id']),
        'display_name': alloc(w['display_name']),
        'localized': {
          'ja': {
            'value': alloc(w['ja']),
            'is_machine': alloc(false),
          },
          if (w['zh'] != null)
            'zh-Hans': {
              'value': alloc(w['zh']),
              'is_machine': alloc(false),
            },
        },
        'cover': {'url': alloc(w['cover'])},
        'is_nsfw': alloc(w['nsfw'] == true),
        'release_date': alloc('$ym-${w['day']}'),
        'release_date_precision': alloc(w['precision'] ?? 'day'),
        'maker': {'display_name': alloc(w['company'])},
        'rating_score':
            w['rating'] == null ? alloc(null) : alloc(w['rating']),
        'rating_count':
            w['count'] == null ? alloc(null) : alloc(w['count']),
      };
      payload.add(obj);
    }
    final json = const JsonEncoder().convert(payload);
    return '<html><body><script type="application/json" id="__NUXT_DATA__">$json</script></body></html>';
  }

  test('parseNuxtCalendarItems：字段映射 + 月份过滤 + 译文优先', () {
    final html = nuxtHtml(ym: '2026-09', works: [
      {
        'id': '56041',
        'display_name': '深窓の病',
        'ja': '深窓の病',
        'zh': '深闺之病',
        'cover': 'https://image.kungal.example/a.webp',
        'company': 'Tedopoyo',
        'rating': 8.2,
        'count': 42,
        'nsfw': false,
        'day': '01',
      },
      {
        'id': '56042',
        'display_name': '隣の家のアレ',
        'ja': '隣の家のアレ',
        'zh': null, // 无译文 → name 回落 display_name
        'cover': 'https://image.kungal.example/b.webp',
        'company': 'norin',
        'rating': null,
        'count': null,
        'nsfw': true,
        'day': '15',
      },
      {
        // 10 月的作品：不应进入 2026-09 结果
        'id': '56043',
        'display_name': '十月作品',
        'ja': '十月作品',
        'zh': null,
        'cover': 'https://image.kungal.example/c.webp',
        'company': 'X',
        'rating': null,
        'count': null,
        'nsfw': false,
        'day': '05',
      },
    ]);
    // 第三条的 release_date 需要是 10 月——nuxtHtml 只支持单 ym，
    // 这里直接对 HTML 字符串做日期替换验证月份过滤（该日期字符串唯一）
    final filteredHtml = html.replaceAll('2026-09-05', '2026-10-05');
    final items =
        KungalCalendarService.parseNuxtCalendarItems(filteredHtml, '2026-09')!;

    expect(items, hasLength(2), reason: '10 月作品应被月份过滤剔除');
    final first = items[0];
    expect(first['name'], '深闺之病', reason: '译名优先');
    expect(first['name_original'], '深窓の病');
    expect(first['company'], 'Tedopoyo');
    expect(first['release_date'], '2026-09-01');
    expect(first['release_precision'], 'day');
    expect(first['content_limit'], 'sfw');
    expect(first['effective_portrait_url'], 'https://image.kungal.example/a.webp');
    expect(first['rating'], 8.2);
    expect(first['rating_count'], 42);

    final second = items[1];
    expect(second['name'], '隣の家のアレ', reason: '无译文回落 display_name');
    expect(second['content_limit'], 'nsfw', reason: 'is_nsfw 索引解引用');
    expect(second['rating'], isNull);
  });

  test('parseNuxtCalendarItems：非 Nuxt 页返回 null', () {
    expect(KungalCalendarService.parseNuxtCalendarItems(
        '<html><body>plain</body></html>', '2026-09'), isNull);
  });

  test('ensureMonth 走 SSR 数据源', () async {
    final html = nuxtHtml(ym: '2026-09', works: [
      {
        'id': '56041',
        'display_name': '深窓の病',
        'ja': '深窓の病',
        'zh': '深闺之病',
        'cover': 'https://image.kungal.example/a.webp',
        'company': 'Tedopoyo',
        'rating': 8.2,
        'count': 42,
        'nsfw': false,
        'day': '01',
      },
    ]);
    final svc = KungalCalendarService.forTest(
      htmlOverride: (url) =>
          url.contains('/galgame-calendar?month=2026-09') ? html : null,
      // 旧 API 不应被走到（防回归：若走了会返回 null 而非抛网络）
      fetchOverride: (url) => Future.value(null),
    );
    await svc.ensureMonth('2026-09');
    expect(svc.isFailed('month_2026-09'), isFalse);
    expect(svc.monthData('2026-09')?.items, hasLength(1));
    expect(svc.monthData('2026-09')?.items.first.name, '深闺之病');
  });

  test('ensureUpcoming：未来 6 个月合成 + 过滤已发售 + 排序', () async {
    final now = DateTime.now();
    String ymOf(int plusMonths) => KungalCalendarService.monthKey(
        DateTime(now.year, now.month + plusMonths, 1));
    final svc = KungalCalendarService.forTest(
      htmlOverride: (url) {
        final m = RegExp(r'month=(\d{4}-\d{2})').firstMatch(url);
        if (m == null) return null;
        final ym = m.group(1)!;
        if (ym == ymOf(0)) {
          // 当月：一条已发售（昨天）+ 一条未发售（28 号，若当天 <=27）
          return nuxtHtml(ym: ym, works: [
            {
              'id': '1', 'display_name': '当月已发售', 'ja': 'a', 'zh': null,
              'cover': 'u', 'company': 'c', 'rating': null, 'count': null,
              'nsfw': false, 'day': '01',
            },
            {
              'id': '2', 'display_name': '当月未发售', 'ja': 'b', 'zh': null,
              'cover': 'u', 'company': 'c', 'rating': null, 'count': null,
              'nsfw': false, 'day': '28',
            },
          ]);
        }
        if (ym == ymOf(1)) {
          return nuxtHtml(ym: ym, works: [
            {
              'id': '3', 'display_name': '下月新作', 'ja': 'c', 'zh': null,
              'cover': 'u', 'company': 'c', 'rating': null, 'count': null,
              'nsfw': false, 'day': '10',
            },
          ]);
        }
        return nuxtHtml(ym: ym, works: const []);
      },
      fetchOverride: (url) => Future.value(null),
    );

    await svc.ensureUpcoming();

    // 当月 01 号必然已发售（除非今天是 1 号）——用相对断言：
    final names = svc.upcomingGames.map((g) => g.displayName).toList();
    expect(names.contains('当月已发售'), isFalse,
        reason: '已发售（release_date <= 今天）不应出现在 upcoming');
    // 严格排序：全部 exactDate 递增
    final dates = svc.upcomingGames
        .map((g) => g.exactDate!)
        .toList();
    for (var i = 1; i < dates.length; i++) {
      expect(dates[i].isBefore(dates[i - 1]), isFalse, reason: '应按日期升序');
    }
    if (now.day <= 27) {
      expect(names.contains('当月未发售'), isTrue);
      expect(names.contains('下月新作'), isTrue);
    }
  });


  group('NextMoe 官方 API（月历首选数据源）', () {
    test('nextmoeToItem：字段映射（display_name / claim id / developer / vndb 评分）', () {
      // fixture 取自 2026-09-26 实测 /v2/catalog/calendar 响应结构
      final item = KungalCalendarService.nextmoeToItem(<String, dynamic>{
        'object': 'work',
        'id': '226743',
        'display_name': '少女/一场雨',
        'localized': <String, dynamic>{},
        'latin': null,
        'content_limit': 'nsfw',
        'release_date': '2026-09-01',
        'release_date_precision': 'day',
        'cover': {'url': 'https://image.kungal.iloveren.link/a.webp'},
        'claim': {'site': 'kungal', 'site_work_id': '226743'},
        'companies': [
          {'display_name': 'Tedopoyo', 'attribution_role': 'developer'},
          {'display_name': 'Publisher', 'attribution_role': 'publisher'},
        ],
        'ratings': [
          {'source': 'erogamescape', 'score': 75, 'vote_count': 10},
          {'source': 'vndb', 'score': 8.2, 'vote_count': 42},
        ],
      })!;
      expect(item['id'], 226743, reason: 'claim.site=kungal 时取站内 id');
      expect(item['name'], '少女/一场雨');
      expect(item['company'], 'Tedopoyo', reason: 'developer 角色优先');
      expect(item['content_limit'], 'nsfw');
      expect(item['release_precision'], 'day');
      expect(item['effective_portrait_url'], contains('iloveren'));
      expect(item['rating'], 8.2, reason: 'vndb 优先且刻度原样');
      expect(item['rating_count'], 42);
    });

    test('nextmoeToItem：无 kungal claim → id 0；erogamescape 100 分制归一', () {
      final item = KungalCalendarService.nextmoeToItem(<String, dynamic>{
        'id': '999',
        'display_name': 'X',
        'localized': {
          'ja': {'value': 'エックス'},
        },
        'release_date': '2026',
        'release_date_precision': 'year',
        'ratings': [
          {'source': 'erogamescape', 'score': 75, 'vote_count': 10},
        ],
      })!;
      expect(item['id'], 0, reason: '未认领 → detailUrl 为空，避免错误外跳');
      expect(item['name_original'], 'エックス');
      expect(item['rating'], 7.5, reason: 'erogamescape 100 分制除 10');
      expect(item['release_precision'], 'year');
    });

    test('ensureMonth：走 NextMoe calendar（参数正确 + cursor 翻页合并）', () async {
      final urls = <String>[];
      final svc = KungalCalendarService.forTest(
        htmlOverride: (url) => null,
        fetchOverride: (url) {
          urls.add(url);
          if (url.contains('cursor=cur_1')) {
            return Future.value(<String, dynamic>{
              'items': [
                {
                  'display_name': '第二页作品',
                  'release_date': '2026-09-20',
                  'release_date_precision': 'day',
                },
              ],
            });
          }
          return Future.value(<String, dynamic>{
            'items': [
              {
                'display_name': '第一页作品',
                'release_date': '2026-09-01',
                'release_date_precision': 'day',
              },
            ],
            'next_cursor': 'cur_1',
          });
        },
      );
      await svc.ensureMonth('2026-09');
      expect(urls.first, contains('/catalog/calendar?month=2026-09'));
      expect(urls.first, contains('precision=day'),
          reason: '月历网格只取 day 精度');
      expect(urls.first, contains('nsfw=true'));
      expect(urls.first, contains('include=companies,ratings'));
      expect(urls, hasLength(2), reason: '应跟随 next_cursor 翻页');
      expect(svc.monthData('2026-09')?.items, hasLength(2));
      expect(svc.isFailed('month_2026-09'), isFalse);
    });

    test('ensureTba / ensurePending：官方窗口参数（status=announced / year+precision）',
        () async {
      final urls = <String>[];
      final svc = KungalCalendarService.forTest(
        htmlOverride: (url) => null,
        fetchOverride: (url) {
          urls.add(url);
          return Future.value(<String, dynamic>{'items': <Object>[]});
        },
      );
      await svc.ensureTba();
      await svc.ensurePending('2026');
      expect(urls.any((u) => u.contains('status=announced')), isTrue,
          reason: 'TBA 桶用 status=announced');
      expect(urls.any((u) => u.contains('year=2026&precision=year')), isTrue,
          reason: '待定桶用 year + precision=year（官方 v1 pending 等价窗口）');
      expect(svc.isFailed('tba'), isFalse, reason: '空 items 是合法结果');
      expect(svc.isFailed('pending:2026'), isFalse);
    });
  });
}
