// 封面下载并发安全回归测试
//
// 验证 2026-08 修复：并发下载场景下生成不同的文件名，
// 避免后写覆盖前写导致封面错乱。
//
// 测试方法：起一个本地 HTTP server 响应图片字节，
// 调用真实的 CoverDownloadService.downloadCover，
// 验证生成的 savedName 唯一性 + 文件实际写入 + 内容正确。
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/cover_download_service.dart';

void main() {
  group('CoverDownloadService 并发安全', () {
    late HttpServer server;
    late String baseUrl;
    late Directory tempDir;

    // 区分不同 URL 响应的字节内容，方便断言"哪个游戏拿到哪个文件"
    final Map<String, Uint8List> responses = {};
    int requestCount = 0;

    setUp(() async {
      // 起本地 HTTP server，固定返回 1KB 测试图片字节
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';

      server.listen((request) async {
        requestCount++;
        final url = request.requestedUri.toString();
        // 取出 URL 末尾的 id 字段作为响应内容
        final id = url.split('/').last;
        final bytes = Uint8List.fromList(
            'COVER_FOR_$id'.codeUnits + List.filled(1024, 0));
        responses[url] = bytes;
        request.response.statusCode = 200;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });

      tempDir = await Directory.systemTemp.createTemp('cover_dl_test_');
    });

    tearDown(() async {
      await server.close(force: true);
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('并发调用同一 baseName 应生成不同文件名', () async {
      // 5 个并发下载，使用相同 baseName 'cover'
      // 旧代码会全部写到 cover.jpg 导致互相覆盖
      // 新代码：nonce 保证唯一，最终 5 个文件名各不相同
      final futures = <Future<String?>>[];
      for (int i = 0; i < 5; i++) {
        futures.add(CoverDownloadService.instance.downloadCover(
          targetDir: tempDir.path,
          coverUrl: '$baseUrl/cover_$i.jpg',
          fileName: 'cover',
        ));
      }
      final names = await Future.wait(futures);

      // 断言：5 个文件名都非空且互不相同
      expect(names.where((n) => n != null).length, 5);
      expect(names.toSet().length, 5,
          reason: '5 个并发下载应得到 5 个不同的文件名，实际: $names');

      // 断言：5 个文件都实际写入了磁盘
      for (final name in names) {
        final file = File('${tempDir.path}/$name');
        expect(file.existsSync(), isTrue,
            reason: '封面文件应实际写入磁盘: $name');
      }
    });

    test('并发调用不同 baseName 仍能保证唯一', () async {
      // 模拟批量导入场景：5 个游戏各自带 id 前缀
      final futures = <Future<String?>>[];
      for (int i = 0; i < 5; i++) {
        futures.add(CoverDownloadService.instance.downloadCover(
          targetDir: tempDir.path,
          coverUrl: '$baseUrl/cover_$i.jpg',
          fileName: 'batch_cover_$i',
        ));
      }
      final names = await Future.wait(futures);
      expect(names.toSet().length, 5, reason: '不同 baseName + nonce 也应互不冲突');

      // 断言文件名前缀正确保留
      for (int i = 0; i < names.length; i++) {
        expect(names[i], startsWith('batch_cover_$i'),
            reason: '应保留 baseName 前缀: ${names[i]}');
      }
    });

    test('fileName 含扩展名时应正确剥离并使用 URL 的扩展名', () async {
      // 旧代码风格：传完整 fileName 'cover.jpg'，
      // 新代码应切掉 .jpg，只把 cover 作为 baseName 插入 nonce，
      // 扩展名用 URL 检测出的（这里 URL 是 .png）
      final name = await CoverDownloadService.instance.downloadCover(
        targetDir: tempDir.path,
        coverUrl: '$baseUrl/cover.png',
        fileName: 'cover.jpg',
      );
      expect(name, isNotNull);
      expect(name, matches(r'^cover_\d+\.png$'),
          reason: '应切掉 .jpg 扩展名，并以 URL 检测出的 .png 结尾，实际: $name');
    });

    test('fileName 残留的 ms 后缀应被清理', () async {
      // 旧代码风格：'batch_cover_1234567890123.jpg'
      // 新代码应切掉 .jpg，且清理 _13位数字 后缀，避免出现 'cover_1234567890123_5.jpg'
      final name = await CoverDownloadService.instance.downloadCover(
        targetDir: tempDir.path,
        coverUrl: '$baseUrl/cover.jpg',
        fileName: 'batch_cover_1234567890123.jpg',
      );
      expect(name, isNotNull);
      expect(name, matches(r'^batch_cover_\d+\.jpg$'),
          reason: '应清理 _13位数字 残留后缀，实际: $name');
      expect(name, isNot(contains('1234567890123_')),
          reason: '残留的 13 位 ms 后缀应被清理');
    });

    test('无 fileName 时使用 cover 作为 baseName', () async {
      final name = await CoverDownloadService.instance.downloadCover(
        targetDir: tempDir.path,
        coverUrl: '$baseUrl/cover.jpg',
        fileName: null,
      );
      expect(name, isNotNull);
      expect(name, matches(r'^cover_\d+\.jpg$'),
          reason: '无 fileName 时默认 baseName 为 cover，实际: $name');
    });

    test('空 URL 应返回 null 不写文件', () async {
      final name = await CoverDownloadService.instance.downloadCover(
        targetDir: tempDir.path,
        coverUrl: '',
        fileName: 'cover',
      );
      expect(name, isNull);
    });

    test('HTTP 200 响应内容应被正确写入文件', () async {
      final name = await CoverDownloadService.instance.downloadCover(
        targetDir: tempDir.path,
        coverUrl: '$baseUrl/cover_content_test.jpg',
        fileName: 'content_test',
      );
      expect(name, isNotNull);
      final file = File('${tempDir.path}/$name');
      expect(file.existsSync(), isTrue);
      final content = await file.readAsBytes();
      // 响应内容以 'COVER_FOR_cover_content_test' 开头
      final prefix = 'COVER_FOR_cover_content_test'.codeUnits;
      expect(content.length >= prefix.length, isTrue);
      for (int i = 0; i < prefix.length; i++) {
        expect(content[i], prefix[i],
            reason: '写入内容与 HTTP 响应内容应一致，第 $i 字节不匹配');
      }
    });
  });
}
