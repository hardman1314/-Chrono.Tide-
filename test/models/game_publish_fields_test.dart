import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_model.dart';
import 'package:chrono_tide/models/game_resource_model.dart';

/// [GameModel.fromPBRecord] / [GameResourceModel.fromPBRecord] 的桩。
///
/// 真实 RecordModel 需先连服务端，这里用鸭子类型（模型侧参数是 dynamic）绕开。
/// 与 `test/models/game_model_test.dart` 同款桩。
class _FakeRecord {
  _FakeRecord(this.id, this.data, {this.expand = const {}});

  final String id;
  final Map<String, dynamic> data;
  final Map<String, dynamic> expand;

  // GameModel 走 dynamic 读取这两个字段，缺了会抛 NoSuchMethodError
  final String created = '2026-01-01 00:00:00.000Z';
  final String updated = '2026-01-01 00:00:00.000Z';

  String getStringValue(String field) => (data[field] ?? '').toString();

  List<dynamic> getListValue(String field) {
    final value = data[field];
    return value is List ? value : const [];
  }
}

GameModel _game(String id, Map<String, dynamic> data) =>
    GameModel.fromPBRecord(_FakeRecord(id, data));

void main() {
  // explore_resource_sources_plan.md §8.7 / §8.9：
  // 「发布」链路的权限预判必须与 PB 规则逐条同构，否则点了按钮才 404。
  group('GameModel — 发布来源与审核状态', () {
    test('origin 缺省为 official（既有 298 条记录行为不变）', () {
      expect(_game('g1', {'title': '作品'}).origin, 'official');
      expect(_game('g1', {'title': '作品'}).isUserWork, isFalse);
    });

    test('origin = user → isUserWork', () {
      final g = _game('g1', {'title': '作品', 'origin': 'user'});
      expect(g.origin, 'user');
      expect(g.isUserWork, isTrue);
    });

    test('review_status 缺省为 approved（既有记录不受影响）', () {
      final g = _game('g1', {'title': '作品'});
      expect(g.reviewStatus, 'approved');
      expect(g.isReviewApproved, isTrue);
      expect(g.isReviewPending, isFalse);
      expect(g.isReviewRejected, isFalse);
    });

    test('review_status 三态解析', () {
      expect(_game('g1', {'review_status': 'pending'}).isReviewPending, isTrue);
      expect(_game('g1', {'review_status': 'rejected'}).isReviewRejected, isTrue);
      expect(_game('g1', {'review_status': 'approved'}).isReviewApproved, isTrue);
    });

    test('owner / creator_name / community_count 解析', () {
      final g = _game('g1', {
        'owner': 'user1234567890a',
        'creator_name': '某位发布者',
        'community_count': 3,
      });
      expect(g.ownerId, 'user1234567890a');
      expect(g.creatorName, '某位发布者');
      expect(g.communityCount, 3);
    });
  });

  group('GameModel — 繁中标题与别名', () {
    test('traditionalChineseTitle 解析', () {
      final g = _game('g1', {'traditionalChineseTitle': '繁體中文名'});
      expect(g.traditionalChineseTitle, '繁體中文名');
    });

    test('字段缺失 → 空串', () {
      expect(_game('g1', {'title': '作品'}).traditionalChineseTitle, '');
    });

    test('aliasTitles 汇总日 / 英 / 繁中，自动剔除空值并去重', () {
      final g = _game('g1', {
        'originalTitle': '日本語タイトル',
        'englishTitle': 'English Title',
        'traditionalChineseTitle': '繁體中文名',
      });
      expect(g.aliasTitles,
          ['日本語タイトル', 'English Title', '繁體中文名']);

      final partial = _game('g2', {'englishTitle': 'Only English'});
      expect(partial.aliasTitles, ['Only English']);

      expect(_game('g3', {'title': '作品'}).aliasTitles, isEmpty);

      final dup = _game('g4', {
        'originalTitle': 'Same',
        'englishTitle': 'Same',
      });
      expect(dup.aliasTitles, ['Same']);
    });
  });

  group('GameModel.canEditAsOwner / canDeleteAsOwner — 与 PB 规则同构', () {
    // updateRule = owner = @request.auth.id && origin = "user" && review_status != "approved"
    test('本人 + user + 非 approved → 可编辑', () {
      final g = _game('g1', {
        'origin': 'user',
        'owner': 'me',
        'review_status': 'pending',
      });
      expect(g.canEditAsOwner('me'), isTrue);
    });

    test('已 approved → 不可编辑（服务端会返 404）', () {
      final g = _game('g1', {
        'origin': 'user',
        'owner': 'me',
        'review_status': 'approved',
      });
      expect(g.canEditAsOwner('me'), isFalse);
    });

    test('他人作品 / 官方作品 / 未登录 → 不可编辑', () {
      final other = _game('g1', {
        'origin': 'user',
        'owner': 'someone',
        'review_status': 'pending',
      });
      expect(other.canEditAsOwner('me'), isFalse);

      final official = _game('g2', {
        'origin': 'official',
        'owner': 'me',
        'review_status': 'pending',
      });
      expect(official.canEditAsOwner('me'), isFalse);

      final mine = _game('g3', {
        'origin': 'user',
        'owner': 'me',
        'review_status': 'pending',
      });
      expect(mine.canEditAsOwner(''), isFalse);
    });

    // deleteRule = owner = @request.auth.id && origin = "user"
    test('删除不受审核状态影响（approved 也能删 = 撤下）', () {
      final g = _game('g1', {
        'origin': 'user',
        'owner': 'me',
        'review_status': 'approved',
      });
      expect(g.canDeleteAsOwner('me'), isTrue);
      expect(g.canDeleteAsOwner('someone'), isFalse);
    });
  });

  // 【我的】管理页要显示「《作品名》」，但 game 只是 relation id，
  // 必须靠 expand 带出标题（§8.6-④）。
  group('GameResourceModel.gameTitle — expand 带出作品名', () {
    test('maxSelect:1 → expand.game 是单条记录', () {
      final rec = _FakeRecord(
        'res1234567890ab',
        {'game': 'game1234567890a', 'kind': 'community', 'title': '资源'},
        expand: {
          'game': _FakeRecord('game1234567890a', {'title': '命运石之门'}),
        },
      );
      expect(GameResourceModel.fromPBRecord(rec).gameTitle, '命运石之门');
    });

    test('多选形态 → expand.game 是列表', () {
      final rec = _FakeRecord(
        'res1234567890ab',
        {'game': 'game1234567890a', 'kind': 'community', 'title': '资源'},
        expand: {
          'game': [
            _FakeRecord('game1234567890a', {'title': '命运石之门'}),
          ],
        },
      );
      expect(GameResourceModel.fromPBRecord(rec).gameTitle, '命运石之门');
    });

    test('未 expand → 空串（UI 回退显示短 id，不报错）', () {
      final rec = _FakeRecord(
        'res1234567890ab',
        {'game': 'game1234567890a', 'kind': 'community', 'title': '资源'},
      );
      expect(GameResourceModel.fromPBRecord(rec).gameTitle, '');
    });

    test('expand 存在但 game 为 null → 空串', () {
      final rec = _FakeRecord(
        'res1234567890ab',
        {'game': 'game1234567890a', 'kind': 'community', 'title': '资源'},
        expand: {'game': null},
      );
      expect(GameResourceModel.fromPBRecord(rec).gameTitle, '');
    });
  });
}
