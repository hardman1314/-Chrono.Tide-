/// `NsfwDetectionStore` 测试。
///
/// ## 这个文件存在的首要理由
///
/// v1 的 P0 bug（线上数据打码完全失效）根因就在这一层：
/// **写入侧用本地文件路径做 key，渲染侧用图片 URL 做 key**，两者永不相等，
/// 于是 `boxesFor()` 永远返回 null，UI 永远按「未判定」放行原图。
///
/// v2 的纪律是：key 只能由 [NsfwDetectionStore.keyForFile] /
/// [NsfwDetectionStore.keyForUrl] 生成，网络图落盘时**双键写入**。
/// 本文件的 `key 规则` 与 `双键写入` 两组用例就是这条纪律的回归守卫，
/// 删掉它们等于把 v1 的 bug 放回来。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_store.dart';

const String _sig = 'censor_detect_v1.0_n/640/0.2';
const String _otherSig = 'censor_detect_v1.0_n/320/0.2';

/// 夹具的默认判定时间 = **本次测试运行时刻**。
///
/// 🔴 不要改回固定历史时间戳（原为 `1700000000000` = 2023-11-14）：
/// P1-4 给缓存加了 `maxAge = 180 天` 的有效期，`flush()` 与 `load()` 都会淘汰
/// 过期条目 —— 用固定历史时间戳会让**夹具自己变成过期数据**，
/// 于是「put → flush → 重新 load」这类用例测的不再是落盘往返，
/// 而是在测淘汰逻辑，全部假失败。
/// 想测淘汰本身请去 `nsfw_store_retention_test.dart`（那里刻意构造过期时间戳）。
final int _recentMs = DateTime.now().millisecondsSinceEpoch;

NsfwDetection _det({
  int imgW = 800,
  int imgH = 600,
  List<NsfwBox> boxes = const <NsfwBox>[],
  int? atMs,
}) =>
    NsfwDetection(
      imgW: imgW,
      imgH: imgH,
      detectedAtMs: atMs ?? _recentMs,
      boxes: boxes,
    );

const NsfwBox _box = NsfwBox(
  x0: 100,
  y0: 120,
  x1: 180,
  y1: 200,
  label: 0,
  conf: 0.85, // 刻意用 3 位以内小数：落盘时 conf 会被量化到 3 位
);

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ct_nsfw_store_');
    // 必须在任何路径 getter 被解析前设置
    PathHelper.exeDirOverride = tmpRoot.path;
    NsfwDetectionStore.resetForTest();
  });

  tearDown(() async {
    NsfwDetectionStore.resetForTest();
    PathHelper.exeDirOverride = null;
    if (await tmpRoot.exists()) {
      try {
        await tmpRoot.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发文件占用，忽略即可，systemTemp 会被系统回收
      }
    }
  });

  File cacheFile() => File(PathHelper.nsfwDetectionsFilePath);

  // =========================================================================
  group('key 规则（v1 P0 bug 的回归守卫）', () {
    test('本地路径 key：分隔符 / 大小写 / 冗余段 / 尾部斜杠 全部归一', () {
      final String canonical =
          NsfwDetectionStore.keyForFile(r'C:\Games\Foo\cover.jpg');

      // 正斜杠
      expect(NsfwDetectionStore.keyForFile('C:/Games/Foo/cover.jpg'), canonical);
      // 大小写
      expect(NsfwDetectionStore.keyForFile(r'c:\games\FOO\Cover.JPG'), canonical);
      // 冗余 .. 与 .
      expect(
        NsfwDetectionStore.keyForFile(r'C:\Games\Bar\..\Foo\.\cover.jpg'),
        canonical,
      );
      // 混合分隔符
      expect(NsfwDetectionStore.keyForFile(r'C:\Games/Foo\cover.jpg'), canonical);
    });

    test('空路径返回空 key，且空 key 不可写入（防止污染出一条 "" 记录）', () {
      expect(NsfwDetectionStore.keyForFile(''), '');
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{});
      s.put('', _det(boxes: <NsfwBox>[_box]));
      expect(s.count, 0);
    });

    test('URL key：只去首尾空白，**不小写**（URL path 段大小写敏感）', () {
      expect(
        NsfwDetectionStore.keyForUrl('  https://t.vndb.org/cv/12/AbC.jpg  '),
        'https://t.vndb.org/cv/12/AbC.jpg',
      );
      // 大小写不同必须是两个不同的 key
      expect(
        NsfwDetectionStore.keyForUrl('https://x/A.jpg'),
        isNot(NsfwDetectionStore.keyForUrl('https://x/a.jpg')),
      );
    });

    test('URL key 不会被路径规范化误伤（// 不能被折叠成 /）', () {
      const String url = 'https://t.vndb.org/cv/12/1234.jpg';
      expect(NsfwDetectionStore.keyForUrl(url), url);
      expect(NsfwDetectionStore.keyForUrl(url), contains('//'));
    });
  });

  // =========================================================================
  group('三态查询语义（null / [] / 非空）', () {
    test('未判定 → boxesFor 返回 null；已判定干净 → 返回空列表', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      const String kClean = 'k_clean';
      s.seedForTest(_sig, <String, NsfwDetection>{
        kClean: NsfwDetection.clean(imgW: 800, imgH: 600, atMs: 1),
      });

      // 未判定
      expect(s.boxesFor('k_unknown'), isNull);
      expect(s.has('k_unknown'), isFalse);

      // 已判定且干净 —— 必须是空列表而不是 null，否则每次启动都会重扫
      expect(s.boxesFor(kClean), isNotNull);
      expect(s.boxesFor(kClean), isEmpty);
      expect(s.has(kClean), isTrue);
      expect(s.detectionFor(kClean)!.hasNsfw, isFalse);
    });

    test('有敏感内容 → 返回非空 bbox 列表', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{
        'k': _det(boxes: <NsfwBox>[_box]),
      });
      expect(s.boxesFor('k'), hasLength(1));
      expect(s.detectionFor('k')!.hasNsfw, isTrue);
    });

    test('空 key 查询返回 null 而不是抛异常', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{});
      expect(s.detectionFor(''), isNull);
      expect(s.boxesFor(''), isNull);
      expect(s.has(''), isFalse);
    });

    test('flaggedCount 只统计含敏感内容的条目', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{
        'a': _det(boxes: <NsfwBox>[_box]),
        'b': NsfwDetection.clean(imgW: 1, imgH: 1, atMs: 1),
        'c': _det(boxes: <NsfwBox>[_box]),
      });
      expect(s.count, 3);
      expect(s.flaggedCount, 2);
    });
  });

  // =========================================================================
  group('双键写入（网络图打码能生效的关键）', () {
    test('put + aliasKeys → 本地路径 key 与 URL key 都能查到同一结果', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{});

      final String pathKey =
          NsfwDetectionStore.keyForFile(r'C:\data\cache\images\abc.jpg');
      final String urlKey =
          NsfwDetectionStore.keyForUrl('https://t.vndb.org/cv/12/abc.jpg');
      final NsfwDetection d = _det(boxes: <NsfwBox>[_box]);

      s.put(pathKey, d, aliasKeys: <String>[urlKey]);

      // 这两行是 v1 失效的直接原因，必须同时成立
      expect(s.boxesFor(pathKey), hasLength(1));
      expect(s.boxesFor(urlKey), hasLength(1));
      expect(identical(s.detectionFor(pathKey), s.detectionFor(urlKey)), isTrue);
      expect(s.count, 2); // 主键 + 别名各占一条
    });

    test('aliasKeys 中的空串与与主键重复项被忽略', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      s.seedForTest(_sig, <String, NsfwDetection>{});
      s.put('main', _det(), aliasKeys: <String>['', 'main', 'alias']);
      expect(s.itemsForTest.keys.toSet(), <String>{'main', 'alias'});
    });

    test('detectionForAny 按给定顺序回退，取第一个命中', () {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      final NsfwDetection viaPath = _det(imgW: 111, boxes: <NsfwBox>[_box]);
      final NsfwDetection viaUrl = _det(imgW: 222, boxes: <NsfwBox>[_box]);
      s.seedForTest(_sig, <String, NsfwDetection>{
        'pathKey': viaPath,
        'urlKey': viaUrl,
      });

      // 先 url 后 path → 命中 url
      expect(
        s.detectionForAny(<String>['urlKey', 'pathKey'])!.imgW,
        222,
      );
      // 前面全部 miss → 回退到后面
      expect(
        s.detectionForAny(<String>['nope', 'alsoNope', 'pathKey'])!.imgW,
        111,
      );
      // 全 miss → null
      expect(s.detectionForAny(<String>['x', 'y']), isNull);
      expect(s.detectionForAny(const <String>[]), isNull);
    });
  });

  // =========================================================================
  group('落盘与加载', () {
    test('put → flush → 重新 load 后数据完整（含 bbox 字段）', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      await s1.load(_sig);
      final String k = NsfwDetectionStore.keyForFile(r'C:\g\cover.jpg');
      s1.put(k, _det(imgW: 1280, imgH: 960, boxes: <NsfwBox>[_box]));
      await s1.flush();

      expect(await cacheFile().exists(), isTrue);

      // 换一个全新实例来读，模拟重启
      NsfwDetectionStore.resetForTest();
      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      await s2.load(_sig);

      expect(s2.count, 1);
      final NsfwDetection? d = s2.detectionFor(k);
      expect(d, isNotNull);
      expect(d!.imgW, 1280);
      expect(d.imgH, 960);
      expect(d.boxes, hasLength(1));
      final NsfwBox b = d.boxes.single;
      expect(<int>[b.x0, b.y0, b.x1, b.y1, b.label],
          <int>[100, 120, 180, 200, 0]);
      expect(b.conf, closeTo(0.85, 1e-9));
    });

    test('conf 落盘时被量化到 3 位小数（缓存体积换精度，属刻意设计）', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      await s1.load(_sig);
      s1.put(
        'k',
        _det(boxes: <NsfwBox>[
          const NsfwBox(
              x0: 1, y0: 1, x1: 9, y1: 9, label: 1, conf: 0.7412345886230469),
        ]),
      );
      await s1.flush();

      NsfwDetectionStore.resetForTest();
      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      await s2.load(_sig);
      expect(s2.detectionFor('k')!.boxes.single.conf, 0.741);
    });

    test('模型签名不匹配 → 整表作废（阈值/分辨率变了旧结果无意义）', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      await s1.load(_sig);
      s1.put('k', _det(boxes: <NsfwBox>[_box]));
      await s1.flush();

      NsfwDetectionStore.resetForTest();
      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      final bool invalidated = await s2.load(_otherSig); // 换签名

      expect(invalidated, isTrue,
          reason: '调用方据此重置全量扫描标记，让存量图被重新补判（v2.1.3）');
      expect(s2.count, 0);
      expect(s2.boxesFor('k'), isNull); // 回到「未判定」而不是误用旧 bbox
    });

    test('签名匹配 / 无缓存文件时 load 返回 false（不触发全扫重置）', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      expect(await s1.load(_sig), isFalse, reason: '无缓存文件不算签名失效');

      s1.put('k', _det(boxes: <NsfwBox>[_box]));
      await s1.flush();
      NsfwDetectionStore.resetForTest();

      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      expect(await s2.load(_sig), isFalse, reason: '签名匹配正常加载');
      expect(s2.count, 1);
    });

    test('签名不匹配后写入并 flush，文件里的签名被更新为新签名', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      await s1.load(_sig);
      s1.put('old', _det(boxes: <NsfwBox>[_box]));
      await s1.flush();

      NsfwDetectionStore.resetForTest();
      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      await s2.load(_otherSig);
      await s2.flush(); // 签名不匹配时 _dirty 被置真，这里应真的写出去

      final Map<String, dynamic> json =
          jsonDecode(await cacheFile().readAsString()) as Map<String, dynamic>;
      expect(json['model_ver'], _otherSig);
      expect((json['items'] as Map).containsKey('old'), isFalse);
    });

    test('缓存文件损坏 / 非法内容 → 从空表开始，不抛异常', () async {
      final File f = cacheFile();
      await f.parent.create(recursive: true);
      await f.writeAsString('{ this is not json ');

      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig); // 不应抛
      expect(s.count, 0);
      expect(s.loaded, isTrue);
    });

    test('缓存文件为空 / 顶层不是 Map → 从空表开始', () async {
      final File f = cacheFile();
      await f.parent.create(recursive: true);

      await f.writeAsString('   ');
      NsfwDetectionStore.resetForTest();
      await NsfwDetectionStore.instance.load(_sig);
      expect(NsfwDetectionStore.instance.count, 0);

      await f.writeAsString('[1,2,3]');
      NsfwDetectionStore.resetForTest();
      await NsfwDetectionStore.instance.load(_sig);
      expect(NsfwDetectionStore.instance.count, 0);
    });

    test('无缓存文件时 load 成功且不创建文件', () async {
      expect(await cacheFile().exists(), isFalse);
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      expect(s.count, 0);
      expect(s.loaded, isTrue);
      expect(await cacheFile().exists(), isFalse); // load 不该有副作用
    });

    test('单条记录损坏时只丢那一条，其余正常加载', () async {
      final File f = cacheFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'model_ver': _sig,
        'items': <String, dynamic>{
          'good': <String, dynamic>{
            'w': 100,
            'h': 100,
            't': _recentMs,
            'boxes': <dynamic>[],
          },
          'bad_missing_wh': <String, dynamic>{'t': _recentMs},
          'bad_zero_w': <String, dynamic>{'w': 0, 'h': 100, 't': _recentMs},
          'bad_not_map': 'oops',
        },
      }));

      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      expect(s.itemsForTest.keys.toList(), <String>['good']);
    });

    test('退化 bbox（宽或高 <= 0）在反序列化时被丢弃', () async {
      final File f = cacheFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'model_ver': _sig,
        'items': <String, dynamic>{
          'k': <String, dynamic>{
            'w': 200,
            'h': 200,
            't': _recentMs,
            'boxes': <dynamic>[
              <String, dynamic>{
                'x0': 10,
                'y0': 10,
                'x1': 50,
                'y1': 50,
                'l': 0,
                'c': 0.9
              }, // 正常
              <String, dynamic>{
                'x0': 10,
                'y0': 10,
                'x1': 10,
                'y1': 50,
                'l': 0,
                'c': 0.9
              }, // 宽 0
              <String, dynamic>{
                'x0': 10,
                'y0': 60,
                'x1': 50,
                'y1': 20,
                'l': 0,
                'c': 0.9
              }, // 高负
            ],
          },
        },
      }));

      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      expect(s.boxesFor('k'), hasLength(1));
      expect(s.boxesFor('k')!.single.x1, 50);
    });

    test('原子写：flush 完成后不残留 .tmp 文件', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.put('k', _det(boxes: <NsfwBox>[_box]));
      await s.flush();

      expect(await cacheFile().exists(), isTrue);
      expect(await File('${cacheFile().path}.tmp').exists(), isFalse);
    });

    test('重复 flush 覆盖而非追加，且 JSON 始终可解析', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      for (int i = 0; i < 5; i++) {
        s.put('k$i', _det(boxes: <NsfwBox>[_box]));
        await s.flush();
      }
      final Map<String, dynamic> json =
          jsonDecode(await cacheFile().readAsString()) as Map<String, dynamic>;
      expect((json['items'] as Map).length, 5);
    });

    test('未变脏时 flush 是空操作（不产生文件）', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      await s.flush();
      expect(await cacheFile().exists(), isFalse);
    });
  });

  // =========================================================================
  group('remove / clear', () {
    test('remove 删除指定 key，但不会连带删掉别名', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.put('main', _det(boxes: <NsfwBox>[_box]), aliasKeys: <String>['alias']);
      s.remove('main');
      expect(s.has('main'), isFalse);
      // 已知行为：别名是独立条目，需要各自 remove。
      // 记录在此以免将来误认为是 bug。
      expect(s.has('alias'), isTrue);
    });

    test('remove 不存在的 key 是安全的空操作', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.remove('nothing');
      expect(s.count, 0);
    });

    test('clear 清空并立即落盘，重新 load 后确实为空', () async {
      final NsfwDetectionStore s1 = NsfwDetectionStore.instance;
      await s1.load(_sig);
      s1.put('a', _det(boxes: <NsfwBox>[_box]));
      s1.put('b', _det(boxes: <NsfwBox>[_box]));
      await s1.flush();
      expect(s1.count, 2);

      await s1.clear();
      expect(s1.count, 0);

      NsfwDetectionStore.resetForTest();
      final NsfwDetectionStore s2 = NsfwDetectionStore.instance;
      await s2.load(_sig);
      expect(s2.count, 0);
    });
  });

  // =========================================================================
  group('监听通知', () {
    test('put 会触发去抖后的一次通知（多次写入合并）', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);

      int notifications = 0;
      void listener() => notifications++;
      s.addListener(listener);
      addTearDown(() => s.removeListener(listener));

      for (int i = 0; i < 50; i++) {
        s.put('k$i', _det(boxes: <NsfwBox>[_box]));
      }
      expect(notifications, 0, reason: '去抖窗口内不应立即通知');

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(notifications, 1, reason: '50 次写入应合并成 1 次通知');
    });

    test('clear 走立即通知路径', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.put('a', _det());
      await Future<void>.delayed(const Duration(milliseconds: 350));

      int notifications = 0;
      void listener() => notifications++;
      s.addListener(listener);
      addTearDown(() => s.removeListener(listener));

      await s.clear();
      expect(notifications, 1, reason: 'clear 不应等去抖窗口');
    });
  });

  // =========================================================================
  group('load 幂等性', () {
    test('同签名重复 load 不清表', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.put('k', _det(boxes: <NsfwBox>[_box]));
      await s.load(_sig); // 应该早退
      expect(s.count, 1);
    });

    test('换签名再 load 会清表', () async {
      final NsfwDetectionStore s = NsfwDetectionStore.instance;
      await s.load(_sig);
      s.put('k', _det(boxes: <NsfwBox>[_box]));
      await s.load(_otherSig);
      expect(s.count, 0);
    });
  });
}
