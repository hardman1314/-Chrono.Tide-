// NextMoe 源单元测试（离线，基于真实 API 响应 fixture）
//
// 覆盖：详情解析（多语言标题/简介链、会社角色优先级、多源评分优先级、
// 截图提取、元标签/剧透标签过滤）。fixture 取自
// GET /v2/catalog/works/528（アマツツミ）真实响应（2026-09-06）。
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

void main() {
  group('NextMoeService 基础标识', () {
    test('SourceType.nextmoe 枚举与展示名', () {
      expect(SourceType.nextmoe.displayName, 'NextMoe');
      expect(SourceType.nextmoe.isMix, isFalse);
    });

    test('服务标识', () {
      final service = NextMoeService();
      expect(service.sourceType, SourceType.nextmoe);
      expect(service.sourceName, 'NextMoe');
    });
  });

  group('NextMoe 详情解析（fixture：アマツツミ work id=528）', () {
    // 精简自真实响应，保留被解析的全部字段形态
    final detailFixture = <String, dynamic>{
      'object': 'work',
      'id': '528',
      'medium': 'galgame',
      'display_name': 'アマツツミ',
      'localized': {
        'en': {'value': 'Amatsutsumi', 'is_machine': false},
        'ja': {'value': 'アマツツミ', 'is_machine': false},
        'zh-Hans': {'value': '天津罪', 'is_machine': false},
      },
      'olang': 'ja',
      'content_rating': 'r18',
      'release_date': '2016-04-07',
      'cover': {
        'url': 'https://image.kungal.iloveren.link/f4/44/f444ef04.webp',
        'hash': 'f444ef04',
        'width': 720,
        'height': 1080,
        'source': 'upscale',
      },
      'titles': [
        {'lang': 'en', 'title': 'Amatsutsumi', 'title_kind': 'official'},
        {'lang': 'ja', 'title': 'アマツツミ', 'title_kind': 'official'},
        {'lang': 'zh-Hans', 'title': '天津罪', 'title_kind': 'official'},
        {'lang': '', 'title': 'Tianjin Zui', 'title_kind': 'alias'},
      ],
      'ratings': [
        {'source': 'vndb', 'score': 7.78, 'vote_count': 1958, 'rank': null},
        {'source': 'bangumi', 'score': 7.5, 'vote_count': 3077, 'rank': 1267},
        {'source': 'erogamescape', 'score': 78, 'vote_count': 446},
      ],
      'tags': [
        {
          'id': '4',
          'display_name': 'Galgame',
          'source': 'bangumi',
          'tier': 'hidden',
          'tag_kind': 'meta',
          'spoiler': 'none',
        },
        {
          'id': null,
          'display_name': 'Purplesoftware',
          'source': 'bangumi',
          'tier': null,
          'tag_kind': null,
          'spoiler': 'none',
        },
        {
          'id': '728',
          'display_name': 'PC',
          'source': 'bangumi',
          'tier': 'hidden',
          'tag_kind': 'meta',
          'spoiler': 'none',
        },
        {
          'id': '753',
          'display_name': '下流话',
          'source': 'vndb',
          'tier': 'longtail',
          'tag_kind': 'content',
          'spoiler': 'none',
          'is_sexual': true,
        },
        {
          'id': '999',
          'display_name': '剧透标签',
          'source': 'vndb',
          'tier': 'core',
          'tag_kind': 'content',
          'spoiler': 'heavy',
        },
      ],
      'intros': [
        {'lang': 'en', 'value': 'English intro text.'},
        {'lang': 'zh-Hans', 'value': '中文简介：言灵之力。'},
      ],
      'companies': [
        {
          'object': 'company',
          'id': '107',
          'display_name': 'Purple SOFTWARE',
          'company_kind': 'publisher',
          'attribution_role': 'developer',
        },
        {
          'object': 'company',
          'id': '521',
          'display_name': '株式会社プロトタイプ',
          'company_kind': 'publisher',
          'attribution_role': 'publisher',
        },
      ],
      'screenshots': [
        {
          'url': 'https://image.kungal.iloveren.link/a0/60/a060c5cf.webp',
          'hash': 'a060c5cf',
          'width': 1280,
          'height': 720,
          'source': 'vndb',
        },
        {
          'url': 'https://image.kungal.iloveren.link/08/14/0814fdb9.webp',
          'hash': '0814fdb9',
          'width': 1280,
          'height': 720,
          'source': 'vndb',
        },
      ],
    };

    final service = NextMoeService();
    final result = service.parseDetailForTesting(detailFixture);

    test('主标题取六源对齐中文名（zh-Hans）', () {
      expect(result.isValid, isTrue);
      expect(result.game.name, '天津罪');
    });

    test('副标题取日文官方标题', () {
      expect(result.game.originalTitle, 'アマツツミ');
    });

    test('简介按 zh-Hans 优先（即使 en 排在数组前面）', () {
      expect(result.game.summary, '中文简介：言灵之力。');
    });

    test('封面取裁定后 cover.url', () {
      expect(result.game.coverUrl,
          'https://image.kungal.iloveren.link/f4/44/f444ef04.webp');
    });

    test('会社优先 developer 角色（而非首个 publisher）', () {
      expect(result.game.company, 'Purple SOFTWARE');
    });

    test('评分优先 vndb 源（含投票数），非 bangumi', () {
      expect(result.game.rating, 7.78);
      expect(result.game.voteCount, 1958);
    });

    test('发售日直取 release_date', () {
      expect(result.game.releaseDate, '2016-04-07');
    });

    test('截图提取（url 直链，全部保留）', () {
      expect(result.game.screenshotUrls, hasLength(2));
      expect(result.game.screenshotUrls!.first,
          'https://image.kungal.iloveren.link/a0/60/a060c5cf.webp');
    });

    test('标签过滤：剔除平台元标签（Galgame/PC）与剧透标签', () {
      final names = result.tags.map((t) => t.name).toList();
      expect(names, contains('Purplesoftware'));
      expect(names, contains('下流话'));
      expect(names, isNot(contains('Galgame')));
      expect(names, isNot(contains('PC')));
      expect(names, isNot(contains('剧透标签')));
      expect(result.tags.every((t) => t.source == 'nextmoe'), isTrue);
    });

    test('ID 为十进制字符串且 sourceType 正确', () {
      expect(result.game.id, '528');
      expect(result.game.sourceType, SourceType.nextmoe);
      expect(result.game.sourceId, '528');
    });

    test('缺少 vndb 评分时回退 bangumi（10 分制）', () {
      final fixture = Map<String, dynamic>.from(detailFixture);
      fixture['ratings'] = [
        {'source': 'bangumi', 'score': 7.5, 'vote_count': 3077},
      ];
      final r = service.parseDetailForTesting(fixture);
      expect(r.game.rating, 7.5);
      expect(r.game.voteCount, 3077);
    });

    test('erogamescape 100 分制评分归一化到 10 分制', () {
      final fixture = Map<String, dynamic>.from(detailFixture);
      fixture['ratings'] = [
        {'source': 'erogamescape', 'score': 78, 'vote_count': 446},
      ];
      final r = service.parseDetailForTesting(fixture);
      expect(r.game.rating, 7.8);
    });

    test('无中文简介时回退日文/英文', () {
      final fixture = Map<String, dynamic>.from(detailFixture);
      fixture['intros'] = [
        {'lang': 'ja', 'value': '日本語の紹介文。'},
        {'lang': 'en', 'value': 'English intro.'},
      ];
      final r = service.parseDetailForTesting(fixture);
      expect(r.game.summary, '日本語の紹介文。');
    });

    test('无 localized 中文名时回退 display_name', () {
      final fixture = Map<String, dynamic>.from(detailFixture);
      fixture['localized'] = {
        'ja': {'value': 'アマツツミ'},
      };
      final r = service.parseDetailForTesting(fixture);
      expect(r.game.name, 'アマツツミ');
    });

    test('名称为空返回无效结果', () {
      final r = service.parseDetailForTesting({'id': '1', 'display_name': ''});
      expect(r.isValid, isFalse);
    });
  });

  group('RateLimiter：NextMoe 限流配置', () {
    test('free 档 60/分 → 55/分安全余量（超限触发 429 退避）', () {
      final limiter = RateLimiter.forSource(SourceType.nextmoe);
      expect(limiter.minInterval.inMilliseconds, 1100);
      expect(limiter.maxInWindow, lessThanOrEqualTo(60));
    });
  });
}
