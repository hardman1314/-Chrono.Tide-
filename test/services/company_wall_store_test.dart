// 会社墙存储（CompanyWallStore v2）单元测试
//
// 覆盖需求（会社墙升级批次）：
// 1. v1 旧文件兼容读取（display_names / logo_files 缺失 = 空覆盖，零回归）
// 2. v2 写穿：显示名覆盖 / 图标记录 / 移除（含孤儿文件清理）
// 3. 显示名空串 = 清除覆盖（回退词典展示名）
// 4. P1-4b：加载失败不覆写磁盘（loadFailed 标记 + 磁盘原文保留）
// 5. CompanyLogoService 静态工具（extOfUrl / fileNameKey）

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/company_logo_service.dart';
import 'package:chrono_tide/services/company_wall_store.dart';

Directory? _tmpRoot;

String get _wallFile =>
    '${PathHelper.dataDir}${Platform.pathSeparator}company_wall.json';

String get _logoDir =>
    '${PathHelper.dataDir}${Platform.pathSeparator}company_logos';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _tmpRoot = await Directory.systemTemp.createTemp('ct_company_wall_test');
    PathHelper.exeDirOverride = _tmpRoot!.path;
    await Directory(PathHelper.dataDir).create(recursive: true);
    CompanyWallStore.instance.resetForTest();
  });

  tearDown(() async {
    if (_tmpRoot != null && await _tmpRoot!.exists()) {
      await _tmpRoot!.delete(recursive: true);
    }
  });

  group('v1 兼容读取', () {
    test('v1 旧文件（无 v2 字段）加载后覆盖表为空，功能零回归', () async {
      await File(_wallFile).writeAsString(jsonEncode({
        'format_version': 1,
        'followed_ids': ['98', '27'],
        'custom_companies': [
          {'id': 'custom_x', 'name': '测试社', 'created_at': '2026-01-01'},
        ],
      }));
      await CompanyWallStore.instance.load();
      final wall = CompanyWallStore.instance;
      expect(wall.loadFailed, isFalse);
      expect(wall.isFollowed('98'), isTrue);
      expect(wall.customCompanies.single.id, 'custom_x');
      expect(wall.displayNameOf('98'), isNull);
      expect(wall.logoPathOf('98'), isNull);
    });
  });

  group('v2 显示名覆盖', () {
    test('setDisplayName 写穿 + 重载后仍在', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await wall.setDisplayName('98', '柚子社');
      expect(wall.displayNameOf('98'), '柚子社');

      // 重载（模拟重启）
      wall.resetForTest();
      await CompanyWallStore.instance.load();
      expect(CompanyWallStore.instance.displayNameOf('98'), '柚子社');
    });

    test('空串/空格清除覆盖（回退词典展示名）', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await wall.setDisplayName('98', '柚子社');
      await wall.setDisplayName('98', '   ');
      expect(wall.displayNameOf('98'), isNull);
    });

    test('落盘 JSON 含 format_version=2 与 display_names', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await wall.setDisplayName('98', '柚子社');
      final disk = jsonDecode(await File(_wallFile).readAsString())
          as Map<String, dynamic>;
      expect(disk['format_version'], 2);
      expect((disk['display_names'] as Map)['98'], '柚子社');
    });
  });

  group('v2 图标记录', () {
    test('setLogo 记录文件名，logoPathOf 拼绝对路径；重载后仍在', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await Directory(_logoDir).create(recursive: true);
      await File('$_logoDir${Platform.pathSeparator}98.webp')
          .writeAsBytes([1, 2, 3]);
      await wall.setLogo('98', '98.webp');
      expect(wall.logoPathOf('98'), contains('company_logos'));

      wall.resetForTest();
      await CompanyWallStore.instance.load();
      expect(CompanyWallStore.instance.logoFileOf('98'), '98.webp');
    });

    test('换新图标时旧文件被清理（不留孤儿）', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await Directory(_logoDir).create(recursive: true);
      final oldFile = File('$_logoDir${Platform.pathSeparator}98.png');
      await oldFile.writeAsBytes([1]);
      await wall.setLogo('98', '98.png');
      await wall.setLogo('98', '98.webp');
      expect(await oldFile.exists(), isFalse, reason: '旧图标应被删除');
      expect(wall.logoFileOf('98'), '98.webp');
    });

    test('clearLogo 删文件 + 清记录', () async {
      final wall = CompanyWallStore.instance;
      await wall.load();
      await Directory(_logoDir).create(recursive: true);
      final f = File('$_logoDir${Platform.pathSeparator}98.webp');
      await f.writeAsBytes([1]);
      await wall.setLogo('98', '98.webp');
      await wall.clearLogo('98');
      expect(await f.exists(), isFalse);
      expect(wall.logoPathOf('98'), isNull);
    });
  });

  group('P1-4b 加载失败保护', () {
    test('磁盘坏 JSON：loadFailed 标记 + 不覆写磁盘原文', () async {
      await File(_wallFile).writeAsString('{ broken json !!!');
      final wall = CompanyWallStore.instance;
      await wall.load();
      expect(wall.loadFailed, isTrue);
      // 写操作不应把坏文件覆盖掉（保留人工恢复机会）
      await wall.setDisplayName('98', '柚子社');
      final raw = await File(_wallFile).readAsString();
      expect(raw, contains('broken json'),
          reason: '加载失败后磁盘原文必须原样保留');
    });
  });

  group('CompanyLogoService 静态工具', () {
    test('extOfUrl：识别常见扩展并归一化 jpeg→jpg', () {
      expect(CompanyLogoService.extOfUrl('https://x/a/b.webp'), 'webp');
      expect(CompanyLogoService.extOfUrl('https://x/a.png?token=1'), 'png');
      expect(CompanyLogoService.extOfUrl('https://x/a.jpeg'), 'jpg');
      expect(CompanyLogoService.extOfUrl('https://x/a'), 'webp',
          reason: '无扩展回退 webp（NextMoe CDN 默认）');
    });

    test('fileNameKey：清洗非法字符，空键兜底', () {
      expect(CompanyLogoService.fileNameKey('98'), '98');
      expect(CompanyLogoService.fileNameKey('custom_1_2'), 'custom_1_2');
      expect(CompanyLogoService.fileNameKey('a/b\\c:d'), 'a_b_c_d');
      expect(CompanyLogoService.fileNameKey('///'), 'company');
    });
  });
}
