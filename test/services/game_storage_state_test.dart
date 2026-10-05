import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/models/archive_manifest.dart';
import 'package:chrono_tide/services/game_storage_state_controller.dart';

/// 游戏存储状态机回归（方案 §4.4）。
///
/// 重点保护两件事：
/// ① `display_only` 是**派生态**、不写盘，`normal <-> display_only` 完全由
///    「本体目录在不在」推导 —— 用户重新定位本体后必须自动回到 normal；
/// ② 显式值（`sealed` / `packed`）**不可无条件信任** —— 用户把归档删了要降级，
///    而且要如实说明原因，不能假装还是健康状态。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_state_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });

  Future<GameStorageResolution> resolve({
    String? stored,
    required String bodyDir,
    String archiveDir = '',
  }) =>
      GameStorageStateController.resolveVerified(
        storedStorageState: stored,
        directoryPath: bodyDir,
        archiveDir: archiveDir,
      );

  /// 造一个"健康的归档目录"
  Future<String> makeArchive({
    required String name,
    required String state,
    bool includeBody = false,
    bool writeMeta = true,
    bool writeParts = true,
    bool bodySection = true,
  }) async {
    final dir = p.join(tmp.path, name);
    await Directory(dir).create(recursive: true);
    final manifest = ArchiveManifest(
      gameId: 'g-$name',
      title: 't-$name',
      state: state,
      createdAt: '2026-10-02T20:00:00+08:00',
      appdata: const ArchivePartInfo(
          archive: 'appdata.7z', bytes: 10, fileCount: 1),
      body: (includeBody && bodySection)
          ? const ArchiveBodyInfo(
              archive: 'body.7z', bytes: 100, unpackedBytes: 500, fileCount: 3)
          : null,
    );
    if (writeMeta) {
      await File(p.join(dir, ArchiveManifest.fileName))
          .writeAsString(manifest.toPrettyJson());
    }
    if (writeParts) {
      await File(p.join(dir, 'appdata.7z')).writeAsBytes(List.filled(10, 1));
      if (includeBody && bodySection) {
        await File(p.join(dir, 'body.7z')).writeAsBytes(List.filled(100, 1));
      }
    }
    return dir;
  }

  Future<String> makeBody(String name) async {
    final dir = p.join(tmp.path, name);
    await Directory(dir).create(recursive: true);
    await File(p.join(dir, 'game.exe')).writeAsString('x');
    return dir;
  }

  group('resolveFast —— 零磁盘 I/O（库页卡片专用）', () {
    test('老数据 / 空值 / 未知值一律归 normal', () {
      expect(GameStorageStateController.resolveFast(null),
          GameStorageState.normal);
      expect(GameStorageStateController.resolveFast(''),
          GameStorageState.normal);
      expect(GameStorageStateController.resolveFast('garbage'),
          GameStorageState.normal);
    });

    test('显式值如实返回', () {
      expect(GameStorageStateController.resolveFast('sealed'),
          GameStorageState.sealed);
      expect(GameStorageStateController.resolveFast('packed'),
          GameStorageState.packed);
    });

    test('枚举语义：display_only 是派生态，只有 sealed/packed 带归档', () {
      expect(GameStorageState.displayOnly.isDerived, isTrue);
      expect(GameStorageState.normal.isDerived, isFalse);
      expect(GameStorageState.normal.hasArchive, isFalse);
      expect(GameStorageState.sealed.hasArchive, isTrue);
      expect(GameStorageState.packed.hasArchive, isTrue);
    });

    test('wire 取值与 game.json 的 storage_state 对齐', () {
      expect(GameStorageState.displayOnly.wire, 'display_only');
      expect(GameStorageState.fromWire('display_only'),
          GameStorageState.displayOnly);
      expect(GameStorageState.sealed.label, isNotEmpty);
    });
  });

  group('resolveVerified —— normal / display_only 派生', () {
    test('本体存在 → normal', () async {
      final body = await makeBody('b1');
      final r = await resolve(bodyDir: body);
      expect(r.state, GameStorageState.normal);
      expect(r.bodyExists, isTrue);
      expect(r.degraded, isFalse);
    });

    test('本体不存在 → display_only（派生态，不改盘）', () async {
      final r = await resolve(bodyDir: p.join(tmp.path, 'ghost'));
      expect(r.state, GameStorageState.displayOnly);
      expect(r.bodyExists, isFalse);
      expect(r.reason, contains('本体'));
    });

    test('directoryPath 为空串 → display_only（不炸）', () async {
      final r = await resolve(bodyDir: '');
      expect(r.state, GameStorageState.displayOnly);
    });
  });

  group('resolveVerified —— sealed', () {
    test('归档健康 + 本体不在 → sealed，且带上清单', () async {
      final arch = await makeArchive(
          name: 's1', state: ArchiveManifest.stateSealed);
      final r = await resolve(
          stored: 'sealed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.sealed);
      expect(r.degraded, isFalse);
      expect(r.manifest, isNotNull);
    });

    test('本体又回来了 → normal（状态机没有"卡死"的洞）', () async {
      final arch = await makeArchive(
          name: 's2', state: ArchiveManifest.stateSealed);
      final body = await makeBody('b2');
      final r =
          await resolve(stored: 'sealed', bodyDir: body, archiveDir: arch);
      expect(r.state, GameStorageState.normal);
      expect(r.degraded, isFalse);
    });

    test('归档缺 meta.json → 降级 display_only，并说明原因', () async {
      final arch = await makeArchive(
          name: 's3',
          state: ArchiveManifest.stateSealed,
          writeMeta: false);
      final r = await resolve(
          stored: 'sealed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
      expect(r.reason, contains('meta.json'));
    });

    test('归档分片被删 → 降级（只判 meta 存在是不够的）', () async {
      final arch = await makeArchive(
          name: 's4',
          state: ArchiveManifest.stateSealed,
          writeParts: false);
      final r = await resolve(
          stored: 'sealed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
      expect(r.reason, contains('分片缺失'));
    });

    test('归档坏了但本体在 → normal（能玩优先），仍标记降级', () async {
      final arch = await makeArchive(
          name: 's5',
          state: ArchiveManifest.stateSealed,
          writeMeta: false);
      final body = await makeBody('b5');
      final r =
          await resolve(stored: 'sealed', bodyDir: body, archiveDir: arch);
      expect(r.state, GameStorageState.normal);
      expect(r.degraded, isTrue);
    });

    test('archive_dir 为空 → 降级', () async {
      final r = await resolve(
          stored: 'sealed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: '');
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
    });
  });

  group('resolveVerified —— packed', () {
    test('归档含 body 段且分片齐全 → packed', () async {
      final arch = await makeArchive(
        name: 'p1',
        state: ArchiveManifest.statePacked,
        includeBody: true,
      );
      final r = await resolve(
          stored: 'packed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.packed);
      expect(r.degraded, isFalse);
    });

    test('meta 里没有 body 段 → 降级（packed 的定义就是本体也在归档里）',
        () async {
      final arch = await makeArchive(
        name: 'p2',
        state: ArchiveManifest.statePacked,
        includeBody: false,
      );
      final r = await resolve(
          stored: 'packed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
    });

    test('body.7z 文件缺失 → 降级', () async {
      final arch = await makeArchive(
        name: 'p3',
        state: ArchiveManifest.statePacked,
        includeBody: true,
        writeParts: false,
      );
      final r = await resolve(
          stored: 'packed', bodyDir: p.join(tmp.path, 'ghost'), archiveDir: arch);
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
    });

    test('归档目录整个不存在 → 降级', () async {
      final r = await resolve(
          stored: 'packed',
          bodyDir: p.join(tmp.path, 'ghost'),
          archiveDir: p.join(tmp.path, 'nope'));
      expect(r.state, GameStorageState.displayOnly);
      expect(r.degraded, isTrue);
    });
  });
}
