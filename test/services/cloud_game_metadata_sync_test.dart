import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_model.dart';
import 'package:chrono_tide/repositories/game_repository.dart';
import 'package:chrono_tide/services/discover_metadata_service.dart';

/// [GameModel.fromPBRecord] 的桩：只实现模型真正用到的取值方法。
///
/// 真实 RecordModel 需先连服务端，这里用鸭子类型（参数是 dynamic）绕开。
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

GameModel _game(
  String id,
  Map<String, dynamic> data,
) =>
    GameModel.fromPBRecord(_FakeRecord(id, data));

void main() {
  group('GameModel 云端元数据字段', () {
    test('解析完整的云端元数据', () {
      final g = _game('g1', {
        'title': '测试作品',
        'rating': 8.4,
        'voteCount': 1234,
        'releaseDate': '2023-05-19',
        'metaSource': 'VNDB',
        'estimatedMinutes': 1420,
      });

      expect(g.rating, 8.4);
      expect(g.voteCount, 1234);
      expect(g.releaseDate, '2023-05-19');
      expect(g.metaSource, 'VNDB');
      expect(g.estimatedMinutes, 1420);
      expect(g.hasCloudMetadata, isTrue);
    });

    test('仅预计时长也能命中云端登记（hasCloudMetadata 含 estimatedMinutes）', () {
      final g = _game('g1b', {'title': '只有时长', 'estimatedMinutes': 300});
      expect(g.estimatedMinutes, 300);
      expect(g.hasCloudMetadata, isTrue);
    });

    test('字段缺失 / 0 值 / 空串一律视为「云端无数据」', () {
      final empty = _game('g2', {'title': '空数据'});
      expect(empty.rating, isNull);
      expect(empty.voteCount, isNull);
      expect(empty.releaseDate, '');
      expect(empty.hasCloudMetadata, isFalse);

      // PB number 字段默认 0，不能误判成有效评分
      final zero = _game('g3', {'rating': 0, 'voteCount': 0, 'estimatedMinutes': 0});
      expect(zero.estimatedMinutes, isNull);
      expect(zero.hasCloudMetadata, isFalse);
    });

    test('字符串型数字也能解析（PB 改字段类型时的兼容）', () {
      final g = _game('g4', {'rating': '7.5', 'voteCount': '88'});
      expect(g.rating, 7.5);
      expect(g.voteCount, 88);
    });

    test('预计时长：字符串型数字与 0 值', () {
      expect(
          _game('g5', {'estimatedMinutes': '95'}).estimatedMinutes, 95);
      expect(_game('g6', {'estimatedMinutes': '0'}).estimatedMinutes, isNull);
    });
  });

  group('GameRepository.buildMetadataBody', () {
    test('只写有效值，0/空串不写（避免覆盖云端已有数据）', () {
      final body = GameRepository.buildMetadataBody(
        rating: 8.1,
        voteCount: 0,
        releaseDate: '',
        metaSource: 'VNDB',
        estimatedMinutes: 0,
      );
      expect(body, {'rating': 8.1, 'metaSource': 'VNDB'});
    });

    test('预计时长有效值写入云端键 estimatedMinutes', () {
      final body = GameRepository.buildMetadataBody(estimatedMinutes: 1420);
      expect(body, {'estimatedMinutes': 1420});
    });

    test('全空 → 空 body（调用方据此跳过请求）', () {
      expect(GameRepository.buildMetadataBody(), isEmpty);
      expect(
          GameRepository.buildMetadataBody(
              rating: 0, voteCount: -1, releaseDate: '  ', metaSource: ''),
          isEmpty);
    });
  });

  group('DiscoverMetadataService 云端登记', () {
    test('云端有数据 → 直接进缓存且标记 fromCloud', () {
      final svc = DiscoverMetadataService.instance;
      final g = _game('cloud-1', {
        'rating': 9.0,
        'voteCount': 500,
        'releaseDate': '2021-11-27',
        'metaSource': 'VNDB',
      });

      svc.registerCloudMetadata(g);

      final meta = svc.getMetadata('cloud-1');
      expect(meta, isNotNull);
      expect(meta!.fromCloud, isTrue);
      expect(meta.rating, 9.0);
      expect(meta.releaseYear, 2021);
      expect(meta.sourcePlatform, 'VNDB');
    });

    test('云端条目携带预计时长（详情页/探索页可直接展示）', () {
      final svc = DiscoverMetadataService.instance;
      svc.registerCloudMetadata(
        _game('cloud-1b', {'estimatedMinutes': 720, 'metaSource': 'VNDB'}),
      );
      final meta = svc.getMetadata('cloud-1b');
      expect(meta, isNotNull);
      expect(meta!.fromCloud, isTrue);
      expect(meta.estimatedMinutes, 720);
    });

    test('云端无数据 → 不登记（保持未抓取状态）', () {
      final svc = DiscoverMetadataService.instance;
      svc.registerCloudMetadata(_game('cloud-2', {'title': '无元数据'}));
      expect(svc.getMetadata('cloud-2'), isNull);
    });

    test('本地已抓取的结果不被云端覆盖（本地优先）', () {
      final svc = DiscoverMetadataService.instance;
      final local = DiscoverGameMetadata(
        gameId: 'cloud-3',
        rating: 6.6,
        cachedAt: DateTime.now(),
      );
      // 直接写入缓存模拟「已抓取」
      svc.registerCloudMetadata(
        _game('cloud-3', {'rating': 1.0}),
      );
      expect(svc.getMetadata('cloud-3')!.rating, 1.0);

      // 再塞入本地结果后，云端不得覆盖
      svc.putForTest(local);
      svc.registerCloudMetadata(_game('cloud-3', {'rating': 9.9}));
      expect(svc.getMetadata('cloud-3')!.rating, 6.6);
      expect(svc.getMetadata('cloud-3')!.fromCloud, isFalse);
    });

    test('批量登记只补空洞并整体通知一次', () {
      final svc = DiscoverMetadataService.instance;
      var notified = 0;
      svc.addListener(() => notified++);

      svc.registerCloudMetadataAll([
        _game('batch-1', {'rating': 7.0}),
        _game('batch-2', {'releaseDate': '2020-01-01'}),
        _game('batch-3', {'title': '无元数据'}),
      ]);

      expect(svc.getMetadata('batch-1')!.rating, 7.0);
      expect(svc.getMetadata('batch-2')!.releaseYear, 2020);
      expect(svc.getMetadata('batch-3'), isNull);
      expect(notified, 1);

      // 重复登记同批数据不再通知（全部命中已有条目）
      svc.registerCloudMetadataAll([
        _game('batch-1', {'rating': 7.0}),
      ]);
      expect(notified, 1);

      svc.removeListener(() => notified++);
    });
  });

  group('云端条目缺预计时长的缺口回填判定', () {
    test('来自云端且缺 estimatedMinutes → 需要补抓', () {
      final svc = DiscoverMetadataService.instance;
      // 云端老记录：estimatedMinutes 为 0（字段后上云）→ 模型归一为 null
      svc.registerCloudMetadata(_game('bf-1', {'rating': 8.0}));
      final meta = svc.getMetadata('bf-1');
      expect(meta!.fromCloud, isTrue);
      expect(meta.estimatedMinutes, isNull);
      expect(
          DiscoverMetadataService.needsEstimatedMinutesBackfill(meta), isTrue);
    });

    test('云端条目已有时长 → 不补抓', () {
      final svc = DiscoverMetadataService.instance;
      svc.registerCloudMetadata(
        _game('bf-2', {'rating': 8.0, 'estimatedMinutes': 600}),
      );
      expect(
          DiscoverMetadataService.needsEstimatedMinutesBackfill(
              svc.getMetadata('bf-2')),
          isFalse);
    });

    test('本地抓取的条目 → 不补抓（本地结果优先，不会被重抓覆盖）', () {
      final svc = DiscoverMetadataService.instance;
      svc.putForTest(DiscoverGameMetadata(
        gameId: 'bf-3',
        rating: 7.0,
        cachedAt: DateTime.now(),
      ));
      expect(
          DiscoverMetadataService.needsEstimatedMinutesBackfill(
              svc.getMetadata('bf-3')),
          isFalse);
    });

    test('无缓存条目 → 判定为不补抓（该路径由 ensureMetadata 常规处理）', () {
      expect(
          DiscoverMetadataService.needsEstimatedMinutesBackfill(null),
          isFalse);
    });
  });
}
