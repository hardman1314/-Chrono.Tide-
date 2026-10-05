// NextMoe 源集成测试（真实 API，需网络）
//
// 验证：鉴权（nmk_ 密钥）、搜索→详情全链路、MIX 源 NextMoe 首位优先级、
// 一键抓取多源共存、截图优先级、连接测试、二次调用缓存命中性能。
// 密钥内置源码常量（NextMoeService.apiKey），无需外部配置。
//
// 🔴 全仓唯一需联网的测试：已打 network 标签，日常全量跑用
//    `flutter test --exclude-tags network`（离线，秒级~分钟级），
//    需验证联网集成时单独跑 `flutter test --tags network`。
@Tags(['network'])
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/metadata_fetcher.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  group('NextMoeService 真实 API', () {
    test('连接测试（匿名 stats 端点）', () async {
      final ok = await NextMoeService().testConnection();
      expect(ok, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('按名抓取：中文名搜索 → 六源对齐详情', () async {
      final result = await NextMoeService().fetchByName('天津罪');
      expect(result.isValid, isTrue);
      expect(result.game.sourceType, SourceType.nextmoe);
      expect(result.game.name, '天津罪');
      expect(result.game.originalTitle, 'アマツツミ');
      expect(result.game.rating, greaterThan(0));
      expect(result.game.voteCount, greaterThan(0));
      expect(result.game.coverUrl, isNotEmpty);
      expect(result.game.screenshotUrls, isNotEmpty);
      // ignore: avoid_print
      print('NextMoe: ${result.game.name} / ${result.game.originalTitle} / '
          'rating=${result.game.rating} votes=${result.game.voteCount} / '
          'tags=${result.tags.take(5).map((t) => t.name).join(",")}');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('日文原名搜索同样命中（副标题回退场景）', () async {
      final result = await NextMoeService().fetchByName('アマツツミ');
      expect(result.isValid, isTrue);
      expect(result.game.name, '天津罪');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('MIX 源：NextMoe 全字段最高优先级', () {
    test('fetchGameMixed 整合结果以 NextMoe 数据为第一来源', () async {
      final result =
          await MetadataFetcher.fetchGameMixed('天津罪', useCache: false);
      expect(result, isNotNull);
      expect(result!['platform'], 'MIX源');
      // NextMoe 参与整合（排重映射含 NextMoe）
      final sources = result['source_platforms'] as Map;
      // ignore: avoid_print
      print('MIX 整合来源: $sources');
      expect(sources.containsKey('NextMoe'), isTrue,
          reason: 'NextMoe 应参与 MIX 整合');
      // 主标题由 NextMoe 提供（zh-Hans 对齐名优先于 KunGal）
      expect(result['game_name'], '天津罪');
      expect(result['summary'], isNotEmpty);
      expect(result['cover_url'], isNotEmpty);
      expect(result['screenshot_urls'], isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('缓存命中：二次调用 50ms 内返回（性能验证）', () async {
      final sw = Stopwatch()..start();
      final result = await MetadataFetcher.fetchGameMixed('天津罪');
      sw.stop();
      expect(result, isNotNull);
      // ignore: avoid_print
      print('缓存命中耗时: ${sw.elapsedMilliseconds}ms');
      expect(sw.elapsedMilliseconds, lessThan(50),
          reason: '缓存命中路径不应发起网络请求');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('一键抓取：NextMoe 条目与其他平台共存', () {
    test('结果含 NextMoe 独立条目', () async {
      final results =
          await MetadataFetcher.fetchGame('天津罪', useCache: false);
      final platforms = results.map((r) => r['platform'].toString()).toList();
      // ignore: avoid_print
      print('一键抓取结果: $platforms');
      expect(platforms, contains('NextMoe'));
      // MIX 仍为首位
      expect(platforms.first, 'MIX源');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('截图抓取：NextMoe 优先', () {
    test('fetchScreenshots 默认源首位为 NextMoe', () async {
      final urls = await MetadataFetcher.fetchScreenshots('天津罪',
          useCache: false);
      // ignore: avoid_print
      print('截图 ${urls.length} 张，首张: ${urls.isEmpty ? "无" : urls.first}');
      expect(urls, isNotEmpty);
      // NextMoe 截图为 image.kungal.iloveren.link CDN（hash 命名 webp）
      expect(urls.first.contains('image.kungal.iloveren.link'), isTrue,
          reason: '首位截图应来自 NextMoe（优先级第一）');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
