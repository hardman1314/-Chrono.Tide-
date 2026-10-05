import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_model.dart';

/// [GameModel.fromPBRecord] 的桩：只实现模型真正用到的取值方法。
///
/// 真实 RecordModel 需先连服务端，这里用鸭子类型（参数是 dynamic）绕开。
/// （与 `test/services/cloud_game_metadata_sync_test.dart` 同款桩）
class _FakeRecord {
  _FakeRecord(this.id, this.data);

  final String id;
  final Map<String, dynamic> data;

  // GameModel 通过 dynamic 读取这两个字段（真实 RecordModel 同名字段），
  // 缺了会抛 NoSuchMethodError，故桩里必须保留
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
  // 方案 explore_resource_sources_plan.md §2.3 / §6.1：
  // has_official 是探索库卡片「可安装」角标的**唯一**判据。
  group('GameModel.has_official（可安装角标判据）', () {
    test('true → hasOfficial = true', () {
      final g = _game('g1', {'title': '作品', 'has_official': true});
      expect(g.hasOfficial, isTrue);
    });

    test('false → hasOfficial = false', () {
      final g = _game('g1', {'title': '作品', 'has_official': false});
      expect(g.hasOfficial, isFalse);
    });

    test('字段缺失 → 兜底 false（不抛异常）', () {
      final g = _game('g1', {'title': '作品'});
      expect(g.hasOfficial, isFalse);
    });

    test('number 形态（0/1）也认，兼容 PB 的宽松返回', () {
      expect(_game('g1', {'has_official': 1}).hasOfficial, isTrue);
      expect(_game('g1', {'has_official': 0}).hasOfficial, isFalse);
    });

    test('string 形态（"true"/"false"/"1"/"0"）也认', () {
      expect(_game('g1', {'has_official': 'true'}).hasOfficial, isTrue);
      expect(_game('g1', {'has_official': 'TRUE'}).hasOfficial, isTrue);
      expect(_game('g1', {'has_official': '1'}).hasOfficial, isTrue);
      expect(_game('g1', {'has_official': 'false'}).hasOfficial, isFalse);
      expect(_game('g1', {'has_official': '0'}).hasOfficial, isFalse);
    });

    test('类型不符（如 list）→ 兜底 false（不抛异常）', () {
      expect(_game('g1', {'has_official': <int>[1]}).hasOfficial, isFalse);
    });

    test('copyWith 可显式覆盖，未传则保留原值', () {
      final t = _game('g1', {'has_official': true});
      expect(t.copyWith(title: '改名').hasOfficial, isTrue);
      expect(t.copyWith(hasOfficial: false).hasOfficial, isFalse);
    });
  });
}
