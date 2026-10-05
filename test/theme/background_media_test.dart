import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/theme/background_media.dart';

/// 背景图媒体校验层测试（v3.10 动态背景支持，方案 §6）
///
/// 两类夹具并用：
/// 1. **头部夹具**（程序化构造）—— 校验层本质是「魔数 + 头部字段 + 块结构」读取器，
///    不解码像素，因此头部合法的夹具即可精确覆盖门槛与裁决分支；
/// 2. **真实素材**（项目内置 PNG / 参考项目的真实 GIF）—— 验证对真实文件的解析，
///    防止夹具与真实世界格式细节脱节（如真实 GIF 的循环扩展与局部调色板）。
void main() {
  group('格式识别与尺寸解析', () {
    test('JPEG：魔数 + SOF0 尺寸', () {
      final d = buildJpeg(width: 1024, height: 768);
      final info = BackgroundMediaInspector.detect(d);
      expect(info.kind, BackgroundMediaKind.jpeg);
      expect(info.width, 1024);
      expect(info.height, 768);
      expect(info.isAnimated, isFalse);
    });

    test('真实 PNG：1920x1053 解析正确', () {
      final f = File('assets/images/themes/blue_sky.png');
      expect(f.existsSync(), isTrue, reason: '项目内置主题背景图应存在');
      final info = BackgroundMediaInspector.detect(f.readAsBytesSync());
      expect(info.kind, BackgroundMediaKind.png);
      expect(info.width, 1920);
      expect(info.height, 1053);
    });

    test('WebP(VP8X)：尺寸 + 非动画', () {
      final d = buildWebpVp8x(width: 800, height: 600, animated: false);
      final info = BackgroundMediaInspector.detect(d);
      expect(info.kind, BackgroundMediaKind.webp);
      expect(info.width, 800);
      expect(info.height, 600);
    });

    test('WebP(VP8X)：ANIMATION 标志 → animatedWebp', () {
      final d = buildWebpVp8x(width: 800, height: 600, animated: true);
      final info = BackgroundMediaInspector.detect(d);
      expect(info.kind, BackgroundMediaKind.animatedWebp);
      expect(info.isMultiFrame, isTrue);
    });

    test('BMP：尺寸（含负高度自下而上位图）', () {
      final info = BackgroundMediaInspector.detect(
        buildBmp(width: 640, height: 480, topDown: false),
      );
      expect(info.kind, BackgroundMediaKind.bmp);
      expect(info.width, 640);
      expect(info.height, 480);
    });

    test('GIF：帧数 / 累计时长 / 平均帧率', () {
      final d = buildGif(
        width: 320,
        height: 240,
        frameDelaysCs: List<int>.filled(12, 8),
      );
      final info = BackgroundMediaInspector.detect(d);
      expect(info.kind, BackgroundMediaKind.gif);
      expect(info.frameCount, 12);
      expect(info.totalDelayMs, 12 * 80);
      expect(info.averageFps, closeTo(12.5, 0.01));
      expect(info.isAnimated, isTrue);
    });

    test('真实世界 GIF：帧数与引擎口径一致（286 帧）', () {
      final f = File('ludusavi-master/docs/demo-cli.gif');
      if (!f.existsSync()) {
        markTestSkipped('参考项目 GIF 不存在，跳过真实素材校验');
        return;
      }
      final info = BackgroundMediaInspector.detect(f.readAsBytesSync());
      expect(info.kind, BackgroundMediaKind.gif);
      expect(info.frameCount, 286);
      expect(info.width, 581);
      expect(info.height, 370);
    });
  });

  group('伪装与非法输入', () {
    test('GIF 内容 + .png 扩展名 → 拒绝（spoofedExtension）', () {
      final d = buildGif(width: 32, height: 32, frameDelaysCs: [10, 10]);
      final v = BackgroundMediaInspector.inspect(d, extension: 'png');
      expect(v.ok, isFalse);
      expect(v.reject, BackgroundMediaReject.spoofedExtension);
      expect(v.message, contains('不符'));
    });

    test('白名单外扩展名 → 拒绝（unsupportedFormat）', () {
      final d = buildPngHeader(width: 100, height: 100);
      final v = BackgroundMediaInspector.inspect(d, extension: 'mp4');
      expect(v.reject, BackgroundMediaReject.unsupportedFormat);
    });

    test('无法识别的内容 → 拒绝（unreadable）', () {
      final d = Uint8List.fromList(
        List<int>.generate(64, (i) => (i * 7 + 3) & 0xFF),
      );
      final v = BackgroundMediaInspector.inspect(d, extension: 'png');
      expect(v.reject, BackgroundMediaReject.unreadable);
    });

    test('APNG（PNG + acTL）→ 明确拒绝并说明本期只支持 GIF', () {
      final d = buildPngHeader(width: 100, height: 100, withActl: true);
      final v = BackgroundMediaInspector.inspect(d, extension: 'png');
      expect(v.reject, BackgroundMediaReject.unsupportedFormat);
      expect(v.message, contains('APNG'));
    });

    test('动画 WebP → 明确拒绝', () {
      final d = buildWebpVp8x(width: 100, height: 100, animated: true);
      final v = BackgroundMediaInspector.inspect(d, extension: 'webp');
      expect(v.reject, BackgroundMediaReject.unsupportedFormat);
      expect(v.message, contains('动画 WebP'));
    });
  });

  group('门槛裁决', () {
    test('体积超限 → tooLarge', () {
      // 构造「合法 PNG 头 + 超大长度」的缓冲区（校验层不解码像素，头部合法即可）
      final png = buildPngHeader(width: 100, height: 100);
      final big = Uint8List(BackgroundMediaInspector.maxBytes + 1);
      big.setRange(0, png.length, png);
      final v = BackgroundMediaInspector.inspect(big, extension: 'png');
      expect(v.reject, BackgroundMediaReject.tooLarge);
      expect(v.message, contains('10MB'));
    });

    test('静态图 4096x4096 通过，4097x4097 拒绝', () {
      final okV = BackgroundMediaInspector.inspect(
        buildPngHeader(width: 4096, height: 4096),
        extension: 'png',
      );
      expect(okV.ok, isTrue);

      final badV = BackgroundMediaInspector.inspect(
        buildPngHeader(width: 4097, height: 4097),
        extension: 'png',
      );
      expect(badV.reject, BackgroundMediaReject.tooManyPixels);
      expect(badV.message, contains('4096x4096'));
    });

    test('动图 1920x1080 通过，1921x1081 拒绝（动图门槛更严）', () {
      final okV = BackgroundMediaInspector.inspect(
        buildGif(width: 1920, height: 1080, frameDelaysCs: [10, 10]),
        extension: 'gif',
      );
      expect(okV.ok, isTrue);

      final badV = BackgroundMediaInspector.inspect(
        buildGif(width: 1921, height: 1081, frameDelaysCs: [10, 10]),
        extension: 'gif',
      );
      expect(badV.reject, BackgroundMediaReject.tooManyPixels);
      // 拒绝文案必须点明动图为何更严（单帧无法降采样）
      expect(badV.message, contains('1920x1080'));
      expect(badV.message, contains('降采样'));
    });

    test('GIF 恰好 600 帧通过，601 帧拒绝且提示精确到维度', () {
      final okV = BackgroundMediaInspector.inspect(
        buildGif(width: 8, height: 8, frameDelaysCs: List<int>.filled(600, 10)),
        extension: 'gif',
      );
      expect(okV.ok, isTrue);
      expect(okV.info!.frameCount, 600);

      final badV = BackgroundMediaInspector.inspect(
        buildGif(width: 8, height: 8, frameDelaysCs: List<int>.filled(601, 10)),
        extension: 'gif',
      );
      expect(badV.reject, BackgroundMediaReject.tooManyFrames);
      expect(badV.message, contains('601'));
      expect(badV.message, contains('超过上限 600'));
      // 必须同时给出其他维度的合格信息，便于用户判断该改什么
      expect(badV.message, contains('合格'));
    });

    test('警告（不拒绝）：总时长 >60s、平均帧率 >30fps', () {
      final v = BackgroundMediaInspector.inspect(
        buildGif(
          width: 8,
          height: 8,
          // 2cs = 20ms → 50fps；总时长 100×20ms = 2s（不触发时长警告）
          frameDelaysCs: List<int>.filled(100, 2),
        ),
        extension: 'gif',
      );
      expect(v.ok, isTrue);
      expect(v.warnings.any((w) => w.contains('帧率')), isTrue);

      final v2 = BackgroundMediaInspector.inspect(
        buildGif(
          width: 8,
          height: 8,
          frameDelaysCs: List<int>.filled(40, 200), // 200cs = 2s × 40 = 80s
        ),
        extension: 'gif',
      );
      expect(v2.ok, isTrue);
      expect(v2.warnings.any((w) => w.contains('时长')), isTrue);
    });

    test('扩展名大小写不敏感（.GIF / .PNG）', () {
      final v = BackgroundMediaInspector.inspect(
        buildGif(width: 8, height: 8, frameDelaysCs: [10, 10]),
        extension: 'GIF',
      );
      expect(v.ok, isTrue);
      final v2 = BackgroundMediaInspector.inspect(
        buildPngHeader(width: 100, height: 100),
        extension: 'PNG',
      );
      expect(v2.ok, isTrue);
    });
  });

  group('文件级入口', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ct_bgmedia_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('inspectFile：正常文件通过', () async {
      final f = File('${tmp.path}${Platform.pathSeparator}a.gif');
      f.writeAsBytesSync(
        buildGif(width: 64, height: 64, frameDelaysCs: List<int>.filled(3, 10)),
      );
      final v = await BackgroundMediaInspector.inspectFile(
        f.path,
        extension: 'gif',
      );
      expect(v.ok, isTrue);
      expect(v.info!.frameCount, 3);
    });

    test('inspectFile：文件不存在 → 拒绝而不抛异常', () async {
      final v = await BackgroundMediaInspector.inspectFile(
        '${tmp.path}${Platform.pathSeparator}nope.gif',
        extension: 'gif',
      );
      expect(v.reject, BackgroundMediaReject.unreadable);
    });
  });
}

// ── 夹具构造（仅头部/块结构合法即可，校验层不解码像素）──────────────

void _u16le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _u32le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}

void _u32be(BytesBuilder b, int v) {
  b.addByte((v >> 24) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte(v & 0xFF);
}

/// 合法 GIF89a（真 LZW 数据，采用码长恒定的「无压缩」编码）
Uint8List buildGif({
  required int width,
  required int height,
  required List<int> frameDelaysCs,
}) {
  Uint8List lzw(List<int> pixels) {
    const clear = 4, end = 5, codeSize = 3;
    final codes = <int>[];
    var i = 0;
    while (i < pixels.length) {
      codes.add(clear);
      codes.add(pixels[i]);
      i++;
      if (i < pixels.length) {
        codes.add(pixels[i]);
        i++;
      }
    }
    codes.add(clear);
    codes.add(end);
    final out = BytesBuilder();
    var acc = 0, accBits = 0;
    for (final c in codes) {
      acc |= c << accBits;
      accBits += codeSize;
      while (accBits >= 8) {
        out.addByte(acc & 0xFF);
        acc >>= 8;
        accBits -= 8;
      }
    }
    if (accBits > 0) out.addByte(acc & 0xFF);
    return out.toBytes();
  }

  final b = BytesBuilder();
  b.add('GIF89a'.codeUnits);
  _u16le(b, width);
  _u16le(b, height);
  b.addByte(0xF0);
  b.addByte(0);
  b.addByte(0);
  b.add([0, 0, 0, 255, 255, 255]);
  b.add([0x21, 0xFF, 0x0B]);
  b.add('NETSCAPE2.0'.codeUnits);
  b.addByte(0x03);
  b.addByte(0x01);
  _u16le(b, 0);
  b.addByte(0x00);
  for (var f = 0; f < frameDelaysCs.length; f++) {
    b.add([0x21, 0xF9, 0x04, 0x08]);
    _u16le(b, frameDelaysCs[f]);
    b.addByte(0);
    b.addByte(0);
    b.addByte(0x2C);
    _u16le(b, 0);
    _u16le(b, 0);
    _u16le(b, width);
    _u16le(b, height);
    b.addByte(0x00);
    b.addByte(0x02);
    final data = lzw(List<int>.filled(width * height, f % 2));
    for (var off = 0; off < data.length; off += 255) {
      final n = (data.length - off) < 255 ? data.length - off : 255;
      b.addByte(n);
      b.add(Uint8List.sublistView(data, off, off + n));
    }
    b.addByte(0x00);
  }
  b.addByte(0x3B);
  return b.toBytes();
}

/// PNG 头（signature + IHDR [+ acTL] + IEND），尺寸可任意指定
Uint8List buildPngHeader({
  required int width,
  required int height,
  bool withActl = false,
}) {
  List<int> chunk(String type, List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in <int>[...type.codeUnits, ...data]) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    crc ^= 0xFFFFFFFF;
    final out = BytesBuilder();
    _u32be(out, data.length);
    out.add(type.codeUnits);
    out.add(data);
    _u32be(out, crc);
    return out.toBytes();
  }

  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = BytesBuilder();
  _u32be(ihdr, width);
  _u32be(ihdr, height);
  ihdr.add([8, 0, 0, 0, 0]);
  b.add(chunk('IHDR', ihdr.toBytes()));
  if (withActl) {
    final actl = BytesBuilder();
    _u32be(actl, 2); // num_frames
    _u32be(actl, 0); // num_plays
    b.add(chunk('acTL', actl.toBytes()));
  }
  b.add(chunk('IDAT', [0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]));
  b.add(chunk('IEND', []));
  return b.toBytes();
}

/// 最小 JPEG（FF D8 + APP0 + SOF0 + EOI），尺寸写入 SOF0
Uint8List buildJpeg({required int width, required int height}) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]);
  b.add([0xFF, 0xE0, 0x00, 0x10]);
  b.add('JFIF\u0000'.codeUnits);
  b.add([0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  b.add([0xFF, 0xC0, 0x00, 0x11, 0x08]);
  b.add([(height >> 8) & 0xFF, height & 0xFF]);
  b.add([(width >> 8) & 0xFF, width & 0xFF]);
  b.add([0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

/// WebP：RIFF + VP8X（可带 ANIMATION 标志）+ 最小 VP8L 载荷
Uint8List buildWebpVp8x({
  required int width,
  required int height,
  required bool animated,
}) {
  final vp8x = BytesBuilder();
  vp8x.addByte(animated ? 0x02 : 0x00); // flags: ANIMATION
  vp8x.add([0, 0, 0]); // reserved
  final w = width - 1, h = height - 1;
  vp8x.add([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF]);
  vp8x.add([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  final payload = vp8x.toBytes();
  final size = payload.length;
  final b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  final total = 4 + 8 + size;
  _u32le(b, total);
  b.add('WEBP'.codeUnits);
  b.add('VP8X'.codeUnits);
  _u32le(b, size);
  b.add(payload);
  return b.toBytes();
}

/// BMP：BM + BITMAPINFOHEADER（topDown=false 时高度为负）
Uint8List buildBmp({
  required int width,
  required int height,
  bool topDown = true,
}) {
  final b = BytesBuilder();
  b.add('BM'.codeUnits);
  _u32le(b, 54);
  _u32le(b, 0);
  _u32le(b, 54);
  _u32le(b, 40);
  _u32le(b, width);
  _u32le(b, topDown ? -height : height);
  b.add([0x01, 0x00, 0x18, 0x00]);
  _u32le(b, 0);
  _u32le(b, 0);
  _u32le(b, 2835);
  _u32le(b, 2835);
  _u32le(b, 0);
  _u32le(b, 0);
  return b.toBytes();
}
