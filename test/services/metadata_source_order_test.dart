// 抓取数据源排序单元测试
//
// 覆盖需求（添加页 → 抓取数据源设定窗口）：
// 1. 平台源按约定顺序展示：MIX源 → VNDB → KunGal → Hikarinagi →
//    月幕GAL → Steam → Bangumi → DLsite → ErogameScape（TouchGal 置末）
// 2. 无重复、无遗漏（除 local 外的每个源恰好出现一次）
// 3. 任意乱序输入都能被规范化为同一顺序（抓取结果顺序与展示顺序一致）

import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:chrono_tide/services/metadata_fetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 约定的展示顺序（TouchGal 未列入产品清单，统一排在最末）
  const expectedOrder = [
    SourceType.mix,
    SourceType.nextmoe,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
    SourceType.dlsite,
    SourceType.erogamescape,
    SourceType.touchgal,
  ];

  test('getAvailableSources 按约定顺序返回平台源', () {
    final available = MetadataFetcher.getAvailableSources();
    expect(available, expectedOrder,
        reason: '数据源列表顺序必须与产品约定的展示顺序一致');
  });

  test('平台源无重复、无遗漏', () {
    final available = MetadataFetcher.getAvailableSources();
    final all = SourceType.values.where((s) => s != SourceType.local);
    expect(available.length, all.length);
    expect(available.toSet().length, available.length, reason: '不应出现重复源');
    for (final source in all) {
      expect(available.contains(source), isTrue,
          reason: '源 ${source.name} 不应从列表中丢失');
    }
    expect(available.contains(SourceType.local), isFalse,
        reason: '本地源不参与抓取设定');
  });

  test('MIX源置于最顶部，NextMoe为第二平台', () {
    final available = MetadataFetcher.getAvailableSources();
    expect(available.first, SourceType.mix);
    expect(available[1], SourceType.nextmoe,
        reason: 'NextMoe 为六源对齐目录，约定排在第二平台');
  });

  test('乱序输入被规范化为约定顺序', () {
    final shuffled = <SourceType>[
      SourceType.bangumi,
      SourceType.touchgal,
      SourceType.steam,
      SourceType.vndb,
      SourceType.erogamescape,
      SourceType.mix,
      SourceType.ymgal,
      SourceType.dlsite,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.nextmoe,
    ];
    expect(MetadataFetcher.sortSourcesByDisplayOrder(shuffled), expectedOrder);
  });

  test('部分子集保持相对顺序，且 local 被剔除', () {
    final subset = <SourceType>[
      SourceType.local,
      SourceType.bangumi,
      SourceType.mix,
      SourceType.steam,
    ];
    expect(
      MetadataFetcher.sortSourcesByDisplayOrder(subset),
      [SourceType.mix, SourceType.steam, SourceType.bangumi],
    );
  });
}
