import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/website_entry.dart';
import 'package:chrono_tide/services/website_icon_service.dart';

/// 站点图标服务测试（板块④网站管理增强）
///
/// 只测纯逻辑：图标格式魔数校验、缓存命中、条目字段序列化；
/// 真实网络抓取（favicon 识别）不进单测（依赖外网）。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_site_icon_test');
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('isDecodableImage（Flutter 可解码格式判定）', () {
    test('PNG / JPEG / GIF / WEBP / BMP 通过', () {
      expect(WebsiteIconService.isDecodableImage(
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), isTrue);
      expect(WebsiteIconService.isDecodableImage(
          [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]), isTrue);
      // GIF89a
      expect(WebsiteIconService.isDecodableImage(
          [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00]), isTrue);
      // WEBP: RIFF....WEBP
      expect(WebsiteIconService.isDecodableImage([
        0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
        0x57, 0x45, 0x42, 0x50, 0x00, 0x00, 0x00, 0x00
      ]), isTrue);
      // BMP
      expect(WebsiteIconService.isDecodableImage(
          [0x42, 0x4D, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00]), isTrue);
    });

    test('ICO 被拒绝（favicon 常见格式，但 Flutter 标准 codec 不支持）', () {
      expect(WebsiteIconService.isDecodableImage(
          [0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x20, 0x20]), isFalse);
    });

    test('SVG / HTML 错误页 / 过短数据被拒绝', () {
      final svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>'.codeUnits;
      expect(WebsiteIconService.isDecodableImage(svg), isFalse);
      final html = '<!DOCTYPE html><html><head></head></html>'.codeUnits;
      expect(WebsiteIconService.isDecodableImage(html), isFalse);
      expect(WebsiteIconService.isDecodableImage([0x89, 0x50]), isFalse);
      expect(WebsiteIconService.isDecodableImage([]), isFalse);
    });
  });

  group('图标缓存', () {
    test('缓存目录存在 host 前缀文件即命中', () {
      final dir =
          Directory(p.join(PathHelper.dataDir, 'cache', 'site_icons'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(p.join(dir.path, 'example.com.png'))
        ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);

      expect(WebsiteIconService.findCachedIcon('example.com'), file.path);
    });

    test('无缓存 / 其他 host 返回 null', () {
      expect(WebsiteIconService.findCachedIcon('not-cached.example'), isNull);
      expect(WebsiteIconService.findCachedIcon(''), isNull);
    });
  });

  group('decodeIco（ICO → Flutter 可解码图片）', () {
    test('内嵌 PNG 帧 → 直接切片返回 PNG', () {
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
      ];
      final ico = _buildIco(
          dims: <int>[16], bpps: <int>[32], frames: <List<int>>[png]);
      final out = WebsiteIconService.decodeIco(ico);
      expect(out, isNotNull);
      expect(out!.take(4).toList(), [0x89, 0x50, 0x4E, 0x47]);
      expect(WebsiteIconService.isDecodableImage(out), isTrue);
    });

    test('DIB 帧 → 包装为标准 BMP（BM 魔数，且高度已修正）', () {
      // 2×2 / 32bpp：stride = ((2*32+31)~/32)*4 = 8 → pixelBytes = 16
      final dib = <int>[
        40, 0, 0, 0, // biSize
        2, 0, 0, 0, // biWidth = 2
        4, 0, 0, 0, // biHeight = 4（ICO 惯例：高度×2，含 AND mask）
        1, 0, // biPlanes
        32, 0, // biBitCount = 32
        0, 0, 0, 0, // biCompression = BI_RGB
        16, 0, 0, 0, // biSizeImage
        ...List<int>.filled(20, 0), // 其余字段置零
      ];
      final frame = <int>[...dib, ...List<int>.filled(16, 0x7F)];
      final ico = _buildIco(
          dims: <int>[2], bpps: <int>[32], frames: <List<int>>[frame]);

      final out = WebsiteIconService.decodeIco(ico);
      expect(out, isNotNull);
      expect(out!.take(2).toList(), [0x42, 0x4D], reason: '应包装为 BMP');
      expect(WebsiteIconService.isDecodableImage(out), isTrue);
      // BITMAPINFOHEADER 的 biHeight 应被改写为 2（原为 4）
      final headerStart = 14;
      final h = out[headerStart + 8] |
          (out[headerStart + 9] << 8) |
          (out[headerStart + 10] << 16);
      expect(h, 2);
    });

    test('非 ICO 输入返回 null', () {
      expect(
          WebsiteIconService.decodeIco(<int>[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
          ]),
          isNull);
      expect(WebsiteIconService.decodeIco(<int>[1, 2, 3]), isNull);
    });
  });

  group('WebsiteEntry 图标字段', () {
    test('icon_path 正常 round-trip', () {
      final e = WebsiteEntry(
        id: 'id1',
        title: 'KunGal',
        url: 'https://www.kungal.com',
        iconPath: 'D:/data/site_icons/icon_1.png',
        createdAtMs: 123,
      );
      final restored = WebsiteEntry.fromJson(e.toJson());
      expect(restored.iconPath, 'D:/data/site_icons/icon_1.png');
    });

    test('旧数据（无 icon_path）兼容为空串', () {
      final restored = WebsiteEntry.fromJson(<String, dynamic>{
        'id': 'old',
        'title': '旧站点',
        'url': 'https://old.example',
        'note': '',
        'created_at': 1,
      });
      expect(restored.iconPath, '');
    });
  });
}

/// 构造最小 ICO 容器（ICONDIR + 目录项 + 帧数据），供 decodeIco 测试
List<int> _buildIco({
  required List<int> dims,
  required List<int> bpps,
  required List<List<int>> frames,
}) {
  final out = <int>[
    0,
    0,
    1,
    0,
    frames.length & 0xFF,
    (frames.length >> 8) & 0xFF
  ];
  var offset = 6 + 16 * frames.length;
  for (var i = 0; i < frames.length; i++) {
    final data = frames[i];
    out
      ..addAll(<int>[dims[i], dims[i], 0, 0]) // width, height, colors, reserved
      ..addAll(<int>[1, 0]) // wPlanes (u16)
      ..addAll(<int>[bpps[i] & 0xFF, (bpps[i] >> 8) & 0xFF]) // wBitCount (u16)
      ..addAll(_u32Bytes(data.length)) // dwBytesInRes (u32)
      ..addAll(_u32Bytes(offset)); // dwImageOffset (u32)
    offset += data.length;
  }
  for (final d in frames) {
    out.addAll(d);
  }
  return out;
}

List<int> _u32Bytes(int v) =>
    <int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
