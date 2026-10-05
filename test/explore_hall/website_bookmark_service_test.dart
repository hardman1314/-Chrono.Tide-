import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/website_bookmark_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir =
        Directory.systemTemp.createTempSync('chrono_website_bookmark_test');
    // 必须在任何 PathHelper 路径 getter 解析前设置（exeDir 首次访问即缓存）
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('WebsiteBookmarkService.normalizeUrl', () {
    test('无 scheme 自动补 https://', () {
      expect(
        WebsiteBookmarkService.normalizeUrl('example.com/a?b=1'),
        'https://example.com/a?b=1',
      );
    });

    test('http/https 原样放行', () {
      expect(
        WebsiteBookmarkService.normalizeUrl('http://x.cn/'),
        'http://x.cn/',
      );
      expect(
        WebsiteBookmarkService.normalizeUrl('  https://vndb.org/v17  '),
        'https://vndb.org/v17',
      );
    });

    test('非 http(s) scheme 与非法输入返回 null', () {
      expect(WebsiteBookmarkService.normalizeUrl('javascript:alert(1)'), null);
      expect(WebsiteBookmarkService.normalizeUrl('ftp://files.example.com'),
          null);
      expect(WebsiteBookmarkService.normalizeUrl('file:///C:/x'), null);
      expect(WebsiteBookmarkService.normalizeUrl(''), null);
      expect(WebsiteBookmarkService.normalizeUrl('   '), null);
      expect(WebsiteBookmarkService.normalizeUrl('https://'), null); // 无 host
    });
  });

  group('WebsiteBookmarkService CRUD + 持久化', () {
    test('load：文件不存在时保持空表', () async {
      await WebsiteBookmarkService.instance.load();
      expect(WebsiteBookmarkService.instance.entries, isEmpty);
    });

    test('add：title 为空时智能推断站点名（去前后缀），url 归一化落盘', () async {
      await WebsiteBookmarkService.instance
          .add(title: '', url: 'vndb.org', note: ' VNDB ');
      final entries = WebsiteBookmarkService.instance.entries;
      expect(entries.length, 1);
      expect(entries.first.url, 'https://vndb.org');
      expect(entries.first.title, 'vndb', reason: '应过滤 .org 后缀');
      expect(entries.first.note, 'VNDB');
    });

    test('add：非法 url 静默忽略', () async {
      await WebsiteBookmarkService.instance
          .add(title: 'bad', url: 'javascript:alert(1)');
      expect(WebsiteBookmarkService.instance.entries.length, 1);
    });

    test('update：标题/备注可改，非法 url 忽略修改', () async {
      final entry = WebsiteBookmarkService.instance.entries.first;
      await WebsiteBookmarkService.instance
          .update(entry, title: 'VNDB 主站', url: 'javascript:x', note: '查询用');
      expect(entry.title, 'VNDB 主站');
      expect(entry.url, 'https://vndb.org'); // 未被非法 url 覆盖
      expect(entry.note, '查询用');
    });

    test('持久化：data/websites.json 落盘且可回读', () async {
      final file = File(
          '${tempDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}websites.json');
      expect(file.existsSync(), isTrue);
      final data = jsonDecode(file.readAsStringSync()) as List;
      expect(data.length, 1);
      expect((data.first as Map)['url'], 'https://vndb.org');
    });

    test('remove：删除后清空并同步落盘', () async {
      final id = WebsiteBookmarkService.instance.entries.first.id;
      await WebsiteBookmarkService.instance.remove(id);
      expect(WebsiteBookmarkService.instance.entries, isEmpty);
      final file = File(
          '${tempDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}websites.json');
      expect((jsonDecode(file.readAsStringSync()) as List), isEmpty);
    });
  });

  group('deriveTitle（网址智能推断站点名）', () {
    test('去 www 前缀与常规后缀', () {
      expect(WebsiteBookmarkService.deriveTitle('https://www.kungal.com'),
          'kungal');
      expect(WebsiteBookmarkService.deriveTitle('https://www.bilibili.com/video'),
          'bilibili');
    });

    test('m / wap / forum 等前缀同样过滤', () {
      expect(WebsiteBookmarkService.deriveTitle('https://m.example.com'), 'example');
      expect(WebsiteBookmarkService.deriveTitle('https://wap.foo.net'), 'foo');
      expect(WebsiteBookmarkService.deriveTitle('https://forum.example.org'),
          'example');
    });

    test('双段后缀（com.cn / co.jp）连删', () {
      expect(WebsiteBookmarkService.deriveTitle('https://www.example.com.cn'),
          'example');
      expect(WebsiteBookmarkService.deriveTitle('https://www.example.co.jp'),
          'example');
    });

    test('纯域名主体（bgm.tv / vndb.org）', () {
      expect(WebsiteBookmarkService.deriveTitle('https://bgm.tv'), 'bgm');
      expect(WebsiteBookmarkService.deriveTitle('https://vndb.org'), 'vndb');
    });

    test('解析失败回落原串，不会删空', () {
      expect(WebsiteBookmarkService.deriveTitle('not a url'), isNotEmpty);
      expect(WebsiteBookmarkService.deriveTitle(''), '');
    });
  });
}
