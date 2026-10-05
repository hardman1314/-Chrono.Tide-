// 标签库用户覆盖层（TagLibraryOverrideStore）单元测试
//
// 覆盖需求（标签库内联编辑批次）：
// 1. 落盘往返：维度改名 / 用户维度 / 概念归属 / 未归类归属 / 隐藏
// 2. 用户维度改名（直接改标题）与 asset 维度改名（覆盖表）分流
// 3. migrateKey：写穿重命名后隐藏键/归属键跟随迁移
// 4. filterVisibleTags：全局隐藏按归一化匹配（容忍变体）
// 5. P1-4b：加载失败不覆写磁盘

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/tag_library_override_store.dart';
import 'package:chrono_tide/services/tag_vocabulary_store.dart';

Directory? _tmpRoot;

String get _file => '${PathHelper.dataDir}${Platform.pathSeparator}'
    'tag_library_overrides.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_tag_override_test');
    PathHelper.exeDirOverride = _tmpRoot!.path;
    await Directory(PathHelper.dataDir).create(recursive: true);
    TagLibraryOverrideStore.instance.resetForTest();
  });

  tearDown(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  group('落盘往返', () {
    test('asset 维度改名：写覆盖表，重载后仍在；空串清除', () async {
      final store = TagLibraryOverrideStore.instance;
      await store.load();
      await store.renameDimension('age', '分龄');
      expect(store.dimensionTitleOverride('age'), '分龄');

      store.resetForTest();
      await TagLibraryOverrideStore.instance.load();
      expect(TagLibraryOverrideStore.instance.dimensionTitleOverride('age'),
          '分龄');

      await TagLibraryOverrideStore.instance.renameDimension('age', '  ');
      expect(TagLibraryOverrideStore.instance.dimensionTitleOverride('age'),
          isNull);
    });

    test('用户维度：新增（重名拒绝）→ 改名（直接改标题）', () async {
      final store = TagLibraryOverrideStore.instance;
      await store.load();
      final dim = await store.addCustomDimension('我的口味');
      expect(dim, isNotNull);
      expect(await store.addCustomDimension('我的口味'), isNull,
          reason: '重名应拒绝');

      await store.renameDimension(dim!.id, '口味偏好');
      expect(store.customDimensions.single.title, '口味偏好');
      expect(store.customDimensions.single.id, dim.id,
          reason: '改名不改 id（归属键稳定）');
    });

    test('概念归属覆盖 + 未归类归属 + 重载往返', () async {
      final store = TagLibraryOverrideStore.instance;
      await store.load();
      await store.setConceptDim('age.all', 'u_test_dim');
      await store.setUnclassifiedDim(
          TagVocabularyStore.normalizeTag('轮回'), 'u_test_dim');
      expect(store.effectiveConceptDim('age.all', 'age'), 'u_test_dim');
      expect(
          store.unclassifiedDimOf(TagVocabularyStore.normalizeTag('轮回')),
          'u_test_dim');

      store.resetForTest();
      await TagLibraryOverrideStore.instance.load();
      expect(TagLibraryOverrideStore.instance
          .effectiveConceptDim('age.all', 'age'), 'u_test_dim');
      expect(TagLibraryOverrideStore.instance
          .unclassifiedDimOf(TagVocabularyStore.normalizeTag('轮回')),
          'u_test_dim');
    });
  });

  group('migrateKey（写穿重命名后的键迁移）', () {
    test('隐藏键与归属键跟随迁移', () async {
      final store = TagLibraryOverrideStore.instance;
      await store.load();
      await store.hideTag(TagVocabularyStore.normalizeTag('拔作'));
      await store.setUnclassifiedDim(
          TagVocabularyStore.normalizeTag('拔作'), 'u_x');
      await store.migrateKey(
        TagVocabularyStore.normalizeTag('拔作'),
        TagVocabularyStore.normalizeTag('抜きゲー'),
      );
      expect(store.isHidden(TagVocabularyStore.normalizeTag('抜きゲー')), isTrue);
      expect(
          store.unclassifiedDimOf(TagVocabularyStore.normalizeTag('抜きゲー')),
          'u_x');
      expect(store.isHidden(TagVocabularyStore.normalizeTag('拔作')), isFalse);
    });
  });

  group('filterVisibleTags（全局隐藏唯一出口）', () {
    test('按归一化匹配过滤，容忍变体', () {
      final store = TagLibraryOverrideStore.instance;
      store.resetForTest();
      // 不经 load 直接写内存（模拟已加载态）
      store.hideTag(TagVocabularyStore.normalizeTag('NTR'));
      expect(
        store.filterVisibleTags(['NTR', '纯爱', 'ｎｔｒ！', '百合']),
        ['纯爱', '百合'],
        reason: '全角/标点变体（ｎｔｒ！）也应被过滤',
      );
    });
  });

  group('P1-4b 加载失败保护', () {
    test('坏 JSON：loadFailed + 磁盘原文不覆写', () async {
      await File(_file).writeAsString('{ broken');
      final store = TagLibraryOverrideStore.instance;
      await store.load();
      expect(store.loadFailed, isTrue);
      await store.hideTag('x');
      expect(await File(_file).readAsString(), contains('broken'),
          reason: '加载失败后磁盘原文必须原样保留');
    });
  });
}
