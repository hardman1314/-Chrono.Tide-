import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/company_alias_store.dart';

void main() {
  group('normalize（归一化三层）', () {
    test('去首尾空白 + 连续空白折叠', () {
      expect(CompanyAliasStore.normalize('  Minori  '), 'minori');
      expect(CompanyAliasStore.normalize('YUZU   SOFT'), 'yuzu soft');
    });

    test('全角空格与全角 ASCII 转半角', () {
      expect(CompanyAliasStore.normalize('　雪碧社　'), '雪碧社');
      expect(CompanyAliasStore.normalize('Ｍｉｎｏｒｉ'), 'minori');
      expect(CompanyAliasStore.normalize('ＹＵＺＵ　ＳＯＦＴ'), 'yuzu soft');
    });

    test('大写折叠（仅匹配层）', () {
      expect(CompanyAliasStore.normalize('Sprite'), 'sprite');
      expect(CompanyAliasStore.normalize('AUGUST'), 'august');
    });

    test('假名与汉字不受影响', () {
      expect(CompanyAliasStore.normalize('ゆずソフト'), 'ゆずソフト');
      expect(CompanyAliasStore.normalize('柚子社'), '柚子社');
    });

    test('空串安全', () {
      expect(CompanyAliasStore.normalize(''), '');
      expect(CompanyAliasStore.normalize('  　  '), '');
    });
  });

  group('resolve（解析命中）', () {
    late CompanyAliasStore store;
    setUpAll(() async {
      store = await CompanyAliasStore.loadFromFile(
        'assets/data/company_aliases.json',
      );
    });

    test('英文名命中（大小写/全角不敏感）', () {
      expect(store.resolve('YUZUSOFT')!.record.companyId, 1);
      expect(store.resolve('Ｍｉｎｏｒｉ')!.record.companyId, 2);
      expect(store.resolve(' Front Wing ')!.record.companyId, 4);
      expect(store.resolve('lump of sugar')!.record.companyId, 10);
    });

    test('日文原名命中', () {
      expect(store.resolve('ゆずソフト')!.record.companyId, 1);
      expect(store.resolve('オーガスト')!.record.companyId, 6);
      expect(store.resolve('ランプオブシュガー')!.record.companyId, 10);
    });

    test('中文译名与圈内昵称命中', () {
      expect(store.resolve('柚子社')!.record.companyId, 1);
      expect(store.resolve('中二社')!.record.companyId, 2);
      expect(store.resolve('巨儒社')!.record.companyId, 2);
      expect(store.resolve('雪碧社')!.record.companyId, 3);
      expect(store.resolve('精灵社')!.record.companyId, 3);
      expect(store.resolve('冷饭社')!.record.companyId, 3);
      expect(store.resolve('苍彼社')!.record.companyId, 3);
      expect(store.resolve('前翼社')!.record.companyId, 4);
      expect(store.resolve('键社')!.record.companyId, 5);
      expect(store.resolve('八月社')!.record.companyId, 6);
      expect(store.resolve('马戏团')!.record.companyId, 8);
      expect(store.resolve('马戏团社')!.record.companyId, 8);
      expect(store.resolve('方糖社')!.record.companyId, 10);
      expect(store.resolve('角砂糖')!.record.companyId, 10);
      // 第二批（2026-09-29 扩批）
      expect(store.resolve('N+社')!.record.companyId, 11);
      expect(store.resolve('nitroplus')!.record.companyId, 11);
      expect(store.resolve('型月社')!.record.companyId, 12);
      expect(store.resolve('F社')!.record.companyId, 13);
      expect(store.resolve('妹控石')!.record.companyId, 14);
      expect(store.resolve('风社')!.record.companyId, 15);
      expect(store.resolve('妹药社')!.record.companyId, 16);
      expect(store.resolve('紫社')!.record.companyId, 17);
      expect(store.resolve('易拉罐')!.record.companyId, 18);
      expect(store.resolve('调色板')!.record.companyId, 19);
      expect(store.resolve('音符社')!.record.companyId, 20);
      expect(store.resolve('IG社')!.record.companyId, 21);
      expect(store.resolve('钟表社')!.record.companyId, 22);
      expect(store.resolve('漩涡社')!.record.companyId, 23);
      expect(store.resolve('枕社')!.record.companyId, 24);
      expect(store.resolve('E社')!.record.companyId, 26);
      expect(store.resolve('骗子社')!.record.companyId, 27);
      expect(store.resolve('绿茶社')!.record.companyId, 28);
      expect(store.resolve('海豹社')!.record.companyId, 29);
      expect(store.resolve('蜂巢社')!.record.companyId, 35);
      expect(store.resolve('夜羊社')!.record.companyId, 36);
    });

    test('未命中与空串返回 null（应进入 pending 队列）', () {
      expect(store.resolve('不存在的会社'), isNull);
      expect(store.resolve(''), isNull);
      expect(store.resolve('   '), isNull);
    });

    test('byVndbId 外部锚点命中', () {
      expect(store.byVndbId('p95')!.companyId, 6);
      expect(store.byVndbId('P98')!.companyId, 1); // 大小写不敏感
      expect(store.byVndbId('p99999'), isNull);
    });

    test('byId 与 status / displayName', () {
      final minori = store.byId(2)!;
      expect(minori.standardName, 'minori');
      expect(minori.isDiscontinued, isTrue);
      expect(store.byId(3)!.isDiscontinued, isFalse);
      expect(store.byId(1)!.displayName, '柚子社'); // 中文译名优先
      expect(store.byId(3)!.displayName, 'sprite'); // 无译名回退标准名
      expect(store.byId(999), isNull);
    });

    test('search 联想搜索', () {
      final hits = store.search('sprite');
      expect(hits.map((r) => r.companyId), contains(3));
      // 「社」应同时命中多个以「社」结尾的昵称（中二社/雪碧社/马戏团社/方糖社…）
      final sheHits = store.search('社');
      expect(sheHits.length, greaterThanOrEqualTo(4));
      expect(store.search(''), isEmpty);
    });
  });

  group('词典文件完整性（种子数据集成测试）', () {
    late CompanyAliasStore store;
    setUpAll(() async {
      store = await CompanyAliasStore.loadFromFile(
        'assets/data/company_aliases.json',
      );
    });

    test('规模与结构', () {
      // 不写死精确数：词典会持续扩批，只锁下限防意外丢失条目
      expect(store.companyCount, greaterThanOrEqualTo(78),
          reason: '主流+流传广会社应已覆盖（2026-09-29 扩批至 78 家）');
      expect(store.formatVersion, CompanyAliasStore.supportedFormatVersion);
      final ids = store.companies.map((r) => r.companyId).toSet();
      expect(ids.length, store.companyCount, reason: 'company_id 必须唯一');
    });

    test('无跨会社别名冲突（重名陷阱预警为空）', () {
      expect(store.ambiguousAliases, isEmpty,
          reason: '同一别名指向多个会社 = 分组会错乱，必须人工裁决后才能入库');
    });

    test('每条记录的主名字段全部可被 resolve 命中自身', () {
      for (final record in store.companies) {
        expect(
          store.resolve(record.standardName)!.record.companyId,
          record.companyId,
          reason: '${record.standardName} 的标准名必须能命中自己',
        );
        if (record.jpName != null) {
          expect(
            store.resolve(record.jpName!)!.record.companyId,
            record.companyId,
            reason: '${record.standardName} 的日文名必须能命中自己',
          );
        }
        for (final alias in record.aliases) {
          expect(
            store.resolve(alias)!.record.companyId,
            record.companyId,
            reason: '${record.standardName} 的别名 "$alias" 必须能命中自己',
          );
        }
      }
    });

    test('status 取值合法', () {
      for (final record in store.companies) {
        expect(
          [CompanyRecord.statusActive, CompanyRecord.statusDiscontinued],
          contains(record.status),
        );
      }
    });
  });

  group('防御性解析', () {
    test('非法 JSON 抛 FormatException', () {
      expect(
        () => CompanyAliasStore.parse('not-json'),
        throwsFormatException,
      );
    });

    test('version 超纲拒绝加载', () {
      const json = '{"format_version": 99, "companies": []}';
      expect(() => CompanyAliasStore.parse(json), throwsFormatException);
    });

    test('company_id 重复拒绝加载', () {
      const json = '{"format_version": 1, "companies": ['
          '{"company_id": 1, "standard_name": "A", "status": "active"},'
          '{"company_id": 1, "standard_name": "B", "status": "active"}]}';
      expect(() => CompanyAliasStore.parse(json), throwsFormatException);
    });

    test('status 非法拒绝加载', () {
      const json = '{"format_version": 1, "companies": ['
          '{"company_id": 1, "standard_name": "A", "status": "closed"}]}';
      expect(() => CompanyAliasStore.parse(json), throwsFormatException);
    });

    test('跨会社同名别名进入 ambiguous 预警（不抛异常，交人工裁决）', () {
      const json = '{"format_version": 1, "companies": ['
          '{"company_id": 1, "standard_name": "A社", "status": "active"},'
          '{"company_id": 2, "standard_name": "B社", "status": "active",'
          ' "aliases": ["a社"]}]}';
      final store = CompanyAliasStore.parse(json);
      expect(store.ambiguousAliases, isNotEmpty);
      // 保留先入索引的一条，保证解析结果仍然确定
      expect(store.resolve('a社')!.record.companyId, 1);
    });
  });
}
