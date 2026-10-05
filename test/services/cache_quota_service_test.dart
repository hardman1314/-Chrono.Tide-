// CacheQuotaService 字节配额淘汰回归测试
//
// 覆盖 2026-09-13 「媒体缓存生命周期治理」：
//   - 超配额时按 CacheObject.touched（最后使用）升序淘汰
//   - 释放至 targetBytes、且「索引与文件同时消失」
//   - 配额以内不删除
//   - ADR-007：应用自有目录之外的文件不删
//
// 用 CacheManager.putFile 种子真实文件+索引（不联网），
// PathHelper.exeDirOverride 隔离到临时目录。

import 'dart:io';
import 'dart:typed_data';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/core/portable_image_cache_manager.dart';
import 'package:chrono_tide/services/storage/cache_quota_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  late Directory imageCacheDir;
  late CacheManager manager;

  setUpAll(() async {
    // exeDirOverride 必须在任何 PathHelper getter 首次解析之前设置。
    tempRoot = await Directory.systemTemp.createTemp('ct_cache_quota_test_');
    PathHelper.exeDirOverride = tempRoot.path;
    imageCacheDir = Directory(p.join(PathHelper.imageCacheDir, 'libCachedImageData'));
    manager = PortableImageCacheManager();
  });

  tearDownAll(() async {
    PathHelper.exeDirOverride = null;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  /// 种子：写一个指定字节数的缓存对象。
  Future<String> seedCache(String url, int bytes) async {
    final data = Uint8List(bytes);
    data.fillRange(0, bytes, 1);
    await manager.putFile(
      url,
      data,
      fileExtension: 'png',
    );
    return url;
  }

  /// 读取 repo 全部对象（供断言 touched / length）。
  Future<List<CacheObject>> repoObjects() async {
    final repo = manager.config.repo;
    return repo.getAllObjects();
  }

  /// 目录真实字节。
  Future<int> dirBytes() async {
    var size = 0;
    await for (final f in imageCacheDir.list(followLinks: false)) {
      if (f is File) size += await f.length();
    }
    return size;
  }

  tearDown(() async {
    // 清空 cache 目录 + 索引，保证用例间隔离（emptyCache 会清索引+文件）。
    await manager.emptyCache();
    final dir = imageCacheDir;
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  });

  test('超配额时按最后使用时间升序淘汰至目标值，索引与文件同时消失', () async {
    // 种子 3 个对象：10B / 20B / 30B，共 60B。
    await seedCache('https://a/1.png', 10);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await seedCache('https://a/2.png', 20);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await seedCache('https://a/3.png', 30);

    // 配额 50B、目标 30B → 需释放 30B → 最早使用的 10B+20B 应被淘汰。
    await CacheQuotaService.instance
        .runMaintenance(quotaBytesOverride: 50, targetBytesOverride: 30);

    final remaining = await repoObjects();
    expect(remaining, hasLength(1));
    expect(remaining.single.url, 'https://a/3.png'); // 最晚使用的保留
    expect(await dirBytes(), lessThanOrEqualTo(30));
    // 索引与文件一致：剩下的对象文件仍存在。
    final path = p.join(imageCacheDir.path, remaining.single.relativePath);
    expect(File(path).existsSync(), isTrue);
  });

  test('配额以内不触发任何删除', () async {
    await seedCache('https://b/1.png', 10);
    await seedCache('https://b/2.png', 20);

    // 总量 30B ≤ 配额 50B。
    await CacheQuotaService.instance
        .runMaintenance(quotaBytesOverride: 50, targetBytesOverride: 10);

    expect(await repoObjects(), hasLength(2));
    expect(await dirBytes(), 30);
  });

  test('ADR-007：应用自有目录之外的相对路径不删', () async {
    // 直接向 repo 写入一个 relativePath 指向应用目录之外的对象
    // （模拟数据异常：索引指向外部文件）。配额服务必须跳过它。
    // 6 级 .. 从 <tempRoot>/data/cache/images/libCachedImageData 回退到
    // 系统临时目录之外，确保解析后不在 exeDir 内。
    final repo = manager.config.repo;
    final outside = CacheObject(
      'https://outside/x.png',
      relativePath: p.joinAll([
        '..', '..', '..', '..', '..', '..', 'outside.png'
      ]),
      validTill: DateTime.now().add(const Duration(days: 30)),
      length: 100,
    );
    await repo.insert(outside);

    // 同时种子一个应用内的 60B 对象。
    await seedCache('https://b/1.png', 60);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await seedCache('https://b/2.png', 10);

    // 配额 50B → 触发淘汰。外部对象不应被删除（也不应导致异常）。
    await CacheQuotaService.instance
        .runMaintenance(quotaBytesOverride: 50, targetBytesOverride: 30);

    // 外部对象仍在 repo 中（未被 removeFile）。
    final all = await repo.getAllObjects();
    expect(all.any((o) => o.url == 'https://outside/x.png'), isTrue);
  });
}
