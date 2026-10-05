import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/archive_manifest.dart';

/// 归档清单 `meta.json` 的序列化与自洽校验回归。
///
/// 这份清单是归档目录的**唯一事实源**：`game.json` 只存"指针 + 状态"，
/// 归档包要能独立迁移到别的机器，所以清单必须跟着包走、必须能容忍字段缺省。
void main() {
  final shaA = List.filled(64, 'a').join();
  final shaB = List.filled(64, 'b').join();
  final shaC = List.filled(64, 'c').join();

  ArchiveManifest full() => ArchiveManifest(
        gameId: 'e2c1aaaa-bbbb-4ccc-8ddd-eeeeffff0000',
        title: 'サンプルゲーム 中文标题',
        state: ArchiveManifest.statePacked,
        createdAt: '2026-10-02T20:45:11.000+08:00',
        appVersion: '2.5.3',
        appdata: ArchivePartInfo(
          archive: 'appdata.7z',
          bytes: 1234567,
          fileCount: 42,
          sha256: shaA,
          root: 'Games/sample',
          excluded: const ['.ctgame', 'saves/'],
        ),
        saves: ArchivePartInfo(
          archive: 'saves.7z',
          bytes: 123456,
          fileCount: 12,
          sha256: shaB,
          entries: const [
            SaveEntryRef(
              path: r'C:\Users\x\AppData\Roaming\Game\save.dat',
              size: 111,
              stage: 'f0/save.dat',
            ),
            SaveEntryRef(
              path: r'D:\Games\x\savedata',
              size: 222,
              stage: 'd1',
              isDir: true,
            ),
          ],
        ),
        body: ArchiveBodyInfo(
          archive: 'body.7z',
          bytes: 3200000000,
          unpackedBytes: 8100000000,
          fileCount: 1234,
          sha256: shaC,
          originalDir: r'D:\Games\sample',
          launchPath: 'sample.exe',
        ),
      );

  group('序列化往返', () {
    test('全字段往返无损', () {
      final m = full();
      final back = ArchiveManifest.tryParse(m.toPrettyJson());
      expect(back, isNotNull);
      expect(back!.gameId, m.gameId);
      expect(back.title, m.title, reason: '中日文标题必须原样存活');
      expect(back.state, m.state);
      expect(back.createdAt, m.createdAt);
      expect(back.appVersion, '2.5.3');
      expect(back.appdata!.fileCount, 42);
      expect(back.appdata!.excluded, ['.ctgame', 'saves/']);
      expect(back.saves!.entries, hasLength(2));
      expect(back.body!.unpackedBytes, 8100000000,
          reason: '大整数不能被截断/浮点化');
    });

    test('存档的原始绝对路径完整保留（还原唯一依据）', () {
      final back = ArchiveManifest.tryParse(full().toPrettyJson())!;
      expect(back.saves!.entries.first.path,
          r'C:\Users\x\AppData\Roaming\Game\save.dat');
      expect(back.saves!.entries.first.stage, 'f0/save.dat');
      expect(back.saves!.entries[1].isDir, isTrue);
      expect(back.saves!.entries[1].stage, 'd1');
    });

    test('汇总与分片清单', () {
      final m = full();
      expect(m.declaredFileCount, 42 + 12 + 1234);
      expect(m.partArchives, ['appdata.7z', 'saves.7z', 'body.7z']);
    });

    test('toPrettyJson 是给人看的（带缩进、可直接打开排查）', () {
      final text = full().toPrettyJson();
      expect(text.contains('\n  '), isTrue);
      expect(text.contains('"schema": 1'), isTrue);
    });
  });

  group('宽容解析（字段缺省不能让整个功能崩）', () {
    test('非法/空输入返回 null，不抛异常', () {
      expect(ArchiveManifest.tryParse('{ not json'), isNull);
      expect(ArchiveManifest.tryParse(''), isNull);
      expect(ArchiveManifest.tryParse('   '), isNull);
      expect(ArchiveManifest.tryParse('[]'), isNull, reason: '数组不是清单');
    });

    test('缺 state 视为无效清单（它是"有没有归档"的判据）', () {
      expect(ArchiveManifest.tryParse('{"schema":1,"game_id":"x"}'), isNull);
    });

    test('fromJson 全缺字段时走默认值', () {
      final m = ArchiveManifest.fromJson(const {});
      expect(m.schema, ArchiveManifest.currentSchema);
      expect(m.state, isEmpty);
      expect(m.gameId, isEmpty);
      expect(m.appdata, isNull);
      expect(m.partArchives, isEmpty);
    });

    test('未知 schema 号不拒绝（向前兼容的读取策略）', () {
      final m = ArchiveManifest.tryParse(
          '{"schema":99,"game_id":"g","title":"t","state":"sealed",'
          '"created_at":"2026-10-02T00:00:00+08:00"}');
      expect(m, isNotNull);
      expect(m!.schema, 99);
    });
  });

  group('自洽校验', () {
    test('完整清单零问题', () {
      expect(full().validate(), isEmpty);
    });

    test('state 非法要报出来', () {
      final m = ArchiveManifest(
        gameId: 'g',
        title: 't',
        state: 'weird',
        createdAt: '2026-10-02T00:00:00+08:00',
        appdata: const ArchivePartInfo(archive: 'appdata.7z', fileCount: 1),
      );
      expect(m.validate().any((e) => e.contains('state 非法')), isTrue);
    });

    test('state=packed 但没有 body 段 = 不自洽', () {
      final m = ArchiveManifest.tryParse(
          '{"schema":1,"game_id":"g","title":"t","state":"packed",'
          '"created_at":"2026-10-02T00:00:00+08:00",'
          '"appdata":{"archive":"appdata.7z","file_count":1}}')!;
      expect(m.validate().any((e) => e.contains('缺少 body')), isTrue);
    });

    test('三段全空 = 不是有效归档', () {
      final m = ArchiveManifest(
        gameId: 'g',
        title: 't',
        state: ArchiveManifest.stateSealed,
        createdAt: '2026-10-02T00:00:00+08:00',
      );
      expect(m.validate().any((e) => e.contains('不是一份有效归档')), isTrue);
    });

    test('存档条目缺 path/stage 要报出来', () {
      final m = ArchiveManifest(
        gameId: 'g',
        title: 't',
        state: ArchiveManifest.stateSealed,
        createdAt: '2026-10-02T00:00:00+08:00',
        saves: const ArchivePartInfo(
          archive: 'saves.7z',
          fileCount: 1,
          entries: [SaveEntryRef(path: '', stage: 'f0/x')],
        ),
      );
      expect(m.validate().any((e) => e.contains('path/stage')), isTrue);
    });
  });
}
