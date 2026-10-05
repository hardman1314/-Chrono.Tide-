import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/tag_vocabulary_store.dart';

/// 分类匣·标签受控词表：归一化 / 同义归并 / 维度归属 / 派生 / 过滤语义 的单测。
///
/// 纯函数优先（不依赖 asset bundle）；另有一组「随包数据完整性」用例直接读
/// `assets/data/*.json` 校验发布产物。
const _dimsJson = '''
{
  "format_version": 1,
  "dimensions": [
    {"id": "age", "title": "年龄分级", "order": 1, "exclusive": true, "color": "#C96F6F", "desc": "分级"},
    {"id": "theme", "title": "主旨情感", "order": 2, "exclusive": false, "color": "#C97FA0", "desc": "情感"},
    {"id": "setting", "title": "世界观舞台", "order": 3, "exclusive": false, "color": "#7FA76F", "desc": "舞台"}
  ]
}
''';

const _vocabJson = '''
{
  "format_version": 1,
  "concepts": [
    {"id": "age.all", "name": "全年龄", "dim": "age", "aliases": ["全年齢", "非18禁", "R18以外"]},
    {"id": "th.yuri", "name": "百合", "dim": "theme", "aliases": ["GL", "ガールズラブ"]},
    {"id": "th.vanilla", "name": "纯爱", "dim": "theme", "aliases": ["純愛"]},
    {"id": "set.school", "name": "校园", "dim": "setting", "aliases": ["学園"]},
    {"id": "bad.dim", "name": "无维度", "dim": "nonexistent", "aliases": ["x"]}
  ]
}
''';

TagVocabularyStore _store() => TagVocabularyStore.parse(
      dimensionsJson: _dimsJson,
      vocabularyJson: _vocabJson,
    );

void main() {
  group('normalizeTag', () {
    test('trim + 去噪声字符 + 小写', () {
      expect(TagVocabularyStore.normalizeTag('  纯爱 '), '纯爱');
      expect(TagVocabularyStore.normalizeTag('RPG'), 'rpg');
      expect(TagVocabularyStore.normalizeTag('纯爱・路线'), '纯爱路线');
      expect(TagVocabularyStore.normalizeTag('（百合）'), '百合');
      expect(TagVocabularyStore.normalizeTag('ADV冒险/アニメ'), 'adv冒险アニメ');
    });

    test('全角转半角', () {
      expect(TagVocabularyStore.normalizeTag('ＲＰＧ'), 'rpg');
      expect(TagVocabularyStore.normalizeTag('ＧＬ'), 'gl');
      expect(TagVocabularyStore.normalizeTag('全角　空格'), '全角空格');
    });

    test('空串 / 纯噪声返回空', () {
      expect(TagVocabularyStore.normalizeTag(''), '');
      expect(TagVocabularyStore.normalizeTag('  '), '');
      expect(TagVocabularyStore.normalizeTag('--..'), '');
    });
  });

  group('parse + resolve（同义归并）', () {
    test('别名与规范名都解析到同一概念', () {
      final s = _store();
      expect(s.resolve('全年齢')!.id, 'age.all');
      expect(s.resolve('全年龄')!.id, 'age.all');
      expect(s.resolve('非18禁')!.id, 'age.all');
      expect(s.resolve('GL')!.id, 'th.yuri');
      expect(s.resolve('百合')!.id, 'th.yuri');
    });

    test('大小写/全半角/空白不敏感', () {
      final s = _store();
      expect(s.resolve('gl')!.id, 'th.yuri');
      expect(s.resolve('ＧＬ')!.id, 'th.yuri');
      expect(s.resolve('  纯爱 ')!.id, 'th.vanilla');
      expect(s.resolve('純愛')!.id, 'th.vanilla');
    });

    test('未命中返回 null（进未归类）', () {
      final s = _store();
      expect(s.resolve('不存在的标签'), isNull);
      expect(s.resolve(''), isNull);
      expect(s.containsTag('杂谈'), isFalse);
    });

    test('维度未注册的概念被跳过', () {
      final s = _store();
      expect(s.concepts.any((c) => c.id == 'bad.dim'), isFalse);
      expect(s.resolve('无维度'), isNull);
    });

    test('维度按 order 排序 + 概念可反查维度', () {
      final s = _store();
      expect(s.dimensions.map((d) => d.id).toList(), ['age', 'theme', 'setting']);
      expect(s.dimensionById('age')!.exclusive, isTrue);
      expect(s.conceptById('th.yuri')!.dimensionId, 'theme');
      expect(s.conceptById('th.yuri')!.key,
          TagVocabularyStore.conceptKey('th.yuri'));
    });

    test('别名键冲突时先到先得（保守不错合并）', () {
      const vocab = '''
      {
        "format_version": 1,
        "concepts": [
          {"id": "a", "name": "甲", "dim": "theme", "aliases": ["共用"]},
          {"id": "b", "name": "乙", "dim": "theme", "aliases": ["共用"]}
        ]
      }
      ''';
      final s = TagVocabularyStore.parse(
          dimensionsJson: _dimsJson, vocabularyJson: vocab);
      expect(s.resolve('共用')!.id, 'a');
    });
  });

  group('derive（自动派生计数）', () {
    test('概念计数 + 同游戏去重', () {
      final s = _store();
      final d = TagVocabularyStore.derive([
        ['纯爱', 'GL', 'GL'], // 同游戏重复 GL 只计一次
        ['百合', ' 纯爱 '], // trim 后与「纯爱」同概念
        ['未知标签', '未知标签'],
      ], s);
      expect(d.countOf('th.vanilla'), 2);
      expect(d.countOf('th.yuri'), 2);
    });

    test('未归类标签归并计数并按计数降序', () {
      final s = _store();
      final d = TagVocabularyStore.derive([
        ['神秘', '神秘', '杂项'],
        ['神秘'],
      ], s);
      expect(d.unclassified.length, 2);
      expect(d.unclassified.first.name, '神秘');
      expect(d.unclassified.first.count, 2);
    });

    test('词表为 null 时全部进未归类', () {
      final d = TagVocabularyStore.derive([
        ['纯爱']
      ], null);
      expect(d.conceptCounts, isEmpty);
      expect(d.unclassified.single.name, '纯爱');
    });
  });

  group('过滤语义（维度内并集 · 维度间交集）', () {
    test('维度内取并集', () {
      final sel = {
        'theme': {'th.yuri', 'th.vanilla'},
      };
      expect(TagVocabularyStore.matchesSelection({'th.yuri'}, sel), isTrue);
      expect(TagVocabularyStore.matchesSelection({'th.vanilla'}, sel), isTrue);
      expect(TagVocabularyStore.matchesSelection({'age.all'}, sel), isFalse);
    });

    test('维度间取交集', () {
      final sel = {
        'theme': {'th.yuri'},
        'setting': {'set.school'},
      };
      expect(
          TagVocabularyStore.matchesSelection({'th.yuri', 'set.school'}, sel),
          isTrue);
      expect(TagVocabularyStore.matchesSelection({'th.yuri'}, sel), isFalse);
      expect(
          TagVocabularyStore.matchesSelection({'set.school'}, sel), isFalse);
    });

    test('空选择匹配所有', () {
      expect(TagVocabularyStore.matchesSelection({'th.yuri'}, {}), isTrue);
    });

    test('conceptIdsOfGame 口径与 derive 一致', () {
      final s = _store();
      expect(TagVocabularyStore.conceptIdsOfGame(['GL', ' 纯爱 ', '未知'], s),
          {'th.yuri', 'th.vanilla'});
    });
  });

  group('随包数据完整性', () {
    test('tag_dimensions.json / tag_vocabulary.json 可解析且自洽', () {
      final dims = File('assets/data/tag_dimensions.json').readAsStringSync();
      final vocab = File('assets/data/tag_vocabulary.json').readAsStringSync();
      final s = TagVocabularyStore.parse(
          dimensionsJson: dims, vocabularyJson: vocab);

      // 9 个维度（P0 扩充新增 adult，2026-10-03）
      expect(s.dimensions.length, 9);
      expect(s.dimensions.first.id, 'age');
      expect(s.dimensions.last.id, 'adult');

      // 概念规模（主流受控词表）
      expect(s.concepts.length, greaterThanOrEqualTo(400));

      // 每个概念的维度都必须已注册（边界互斥的前提）
      final dimIds = s.dimensions.map((d) => d.id).toSet();
      for (final c in s.concepts) {
        expect(dimIds.contains(c.dimensionId), isTrue,
            reason: '概念 ${c.id} 的维度 ${c.dimensionId} 未注册');
      }

      // 归一化后别名不得跨概念冲突
      final owners = <String, String>{};
      var conflicts = 0;
      for (final c in s.concepts) {
        for (final a in <String>[c.name, ...c.aliases]) {
          final n = TagVocabularyStore.normalizeTag(a);
          if (n.isEmpty) continue;
          final prev = owners[n];
          if (prev != null && prev != c.id) conflicts++;
          owners[n] = c.id;
        }
      }
      expect(conflicts, 0, reason: '词表存在跨概念别名冲突');

      // 抽查若干主流标签可解析
      expect(s.resolve('纯爱')!.dimensionId, 'theme');
      expect(s.resolve('NTR')!.dimensionId, 'theme');
      expect(s.resolve('18禁')!.dimensionId, 'age');
      expect(s.resolve('傲娇')!.dimensionId, 'character');
      expect(s.resolve('视觉小说')!.dimensionId, 'playstyle');
    });
  });
}
