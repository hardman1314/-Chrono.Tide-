// 排重索引 ImportDedupIndex 单元测试
//
// 测试覆盖：
// 1. 路径包含冲突（精确匹配 + 父/子目录包含）
// 2. 源 ID 冲突（大小写不敏感 + 空值边界）
// 3. 同名软警告（hasWarning=true, isHardConflict=false）
// 4. 向后兼容（空源 ID 不影响 bySource 索引）
// 5. sessionContains 静态方法（会话内路径包含去重）

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/import_dedup_index.dart';
import 'package:chrono_tide/services/local_game_registry.dart';

/// 构造仅供测试用的 LibraryGame 实例。
/// 仅填充排重索引关注的字段（title/directoryPath/metadataSource/metadataSourceId），
/// 其余必填字段（metaDataDir/installedAt）用空字符串占位。
LibraryGame _makeGame({
  required String title,
  required String directoryPath,
  String metadataSource = '',
  String metadataSourceId = '',
}) {
  return LibraryGame(
    title: title,
    directoryPath: directoryPath,
    metaDataDir: '',
    installedAt: '',
    metadataSource: metadataSource,
    metadataSourceId: metadataSourceId,
  );
}

void main() {
  group('测试 1：路径包含冲突', () {
    test('路径精确匹配 → 硬冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      final verdict = index.check(r'E:\GAL\ATRI');
      expect(verdict.isHardConflict, isTrue);
      expect(verdict.kind, DedupConflictKind.pathConflict);
      expect(verdict.existingGameTitle, 'ATRI');
    });

    test('新路径是已入库路径的子目录 → 硬冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      // ATRI 是父，新路径 ATRI\sub 是子
      final verdict = index.check(r'E:\GAL\ATRI\sub');
      expect(verdict.isHardConflict, isTrue);
      expect(verdict.kind, DedupConflictKind.pathConflict);
    });

    test('新路径是已入库路径的父目录 → 硬冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      // ATRI 是子，新路径 E:\GAL 是父
      final verdict = index.check(r'E:\GAL');
      expect(verdict.isHardConflict, isTrue);
      expect(verdict.kind, DedupConflictKind.pathConflict);
    });

    test('无重叠的兄弟路径 → 无冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      final verdict = index.check(r'E:\GAL\OtherGame');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });
  });

  group('测试 2：源 ID 冲突', () {
    test('源 ID 完全匹配 → 硬冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: 'VNDB',
          metadataSourceId: 'v12345',
        ),
      ]);

      final verdict = index.checkWithSource('VNDB', 'v12345');
      expect(verdict.isHardConflict, isTrue);
      expect(verdict.kind, DedupConflictKind.sourceConflict);
      expect(verdict.existingGameTitle, 'ATRI');
    });

    test('源 ID 大小写不敏感 → 硬冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: 'VNDB',
          metadataSourceId: 'v12345',
        ),
      ]);

      final verdict = index.checkWithSource('vndb', 'V12345');
      expect(verdict.isHardConflict, isTrue);
      expect(verdict.kind, DedupConflictKind.sourceConflict);
    });

    test('源 ID 不同 → 无冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: 'VNDB',
          metadataSourceId: 'v12345',
        ),
      ]);

      final verdict = index.checkWithSource('VNDB', 'v99999');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });

    test('空 source 不参与排重 → 无冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: 'VNDB',
          metadataSourceId: 'v12345',
        ),
      ]);

      final verdict = index.checkWithSource('', 'v12345');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });

    test('空 sourceId 不参与排重 → 无冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: 'VNDB',
          metadataSourceId: 'v12345',
        ),
      ]);

      final verdict = index.checkWithSource('VNDB', '');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });
  });

  group('测试 3：同名软警告', () {
    test('路径不同但标题相同 → 软警告', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      final verdict = index.check(r'E:\GAL\ATRI2', title: 'ATRI');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isTrue);
      expect(verdict.kind, DedupConflictKind.possibleDuplicate);
      expect(verdict.existingGameTitle, 'ATRI');
    });

    test('路径不同且标题不同 → 无冲突', () {
      final index = ImportDedupIndex.fromGameList([
        _makeGame(title: 'ATRI', directoryPath: r'E:\GAL\ATRI'),
      ]);

      final verdict = index.check(r'E:\GAL\Other', title: 'DifferentGame');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });
  });

  group('测试 4：向后兼容（空源 ID）', () {
    test('已入库游戏源 ID 为空时不影响 bySource 索引', () {
      // 旧 game.json 无 metadataSource/metadataSourceId 字段，均为 ''
      final index = ImportDedupIndex.fromGameList([
        _makeGame(
          title: 'ATRI',
          directoryPath: r'E:\GAL\ATRI',
          metadataSource: '',
          metadataSourceId: '',
        ),
      ]);

      // 任意源 ID 查询都不应命中空源索引
      final verdict = index.checkWithSource('VNDB', 'v12345');
      expect(verdict.isHardConflict, isFalse);
      expect(verdict.hasWarning, isFalse);
    });
  });

  group('测试 5：sessionContains 静态方法', () {
    test('新路径是已有路径的子目录 → true', () {
      final result = ImportDedupIndex.sessionContains(
        [r'E:\GAL\ATRI'],
        r'E:\GAL\ATRI\sub',
      );
      expect(result, isTrue);
    });

    test('新路径与已有路径无包含关系 → false', () {
      final result = ImportDedupIndex.sessionContains(
        [r'E:\GAL\ATRI'],
        r'E:\GAL\Other',
      );
      expect(result, isFalse);
    });
  });
}
