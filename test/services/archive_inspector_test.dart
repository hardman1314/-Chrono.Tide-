import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/archive_inspector.dart';

/// ArchiveInspector 魔数嗅探回归 —— 重点覆盖 2026-10-05 实机反馈的
/// 「尾部拼接 zip」（网盘过审壳：真视频头 + 尾部拼 zip 包着 rar）。
///
/// 结构与算法依据：lib/services/archive_inspector.dart _sniffTrailingZip
/// 注释 + dev_probe/_probe_7z_mp4.txt（内置 7z 23.01 对 2.6GB mp4 壳
/// 按 EOCD 直解成功的实测记录）。
void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('ct_sniff_test');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  /// 小端 u32 字节序列
  List<int> u32le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];

  /// 真 MP4 文件头 16 字节（ftyp isom，取自实机样本前 16 字节）
  final mp4Header = <int>[
    0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
    0x69, 0x73, 0x6f, 0x6d, 0x00, 0x00, 0x02, 0x00,
  ];

  /// 最小 EOCD（22 字节，字段全按小端拼装）
  List<int> eocd({
    required int cdSize,
    required int cdOffset,
    int totalEntries = 1,
  }) =>
      [
        0x50, 0x4B, 0x05, 0x06, // 签名
        0x00, 0x00, // disk number
        0x00, 0x00, // cd start disk
        0x00, 0x00, // entries this disk
        ...u32le(totalEntries).sublist(0, 2), // total entries（低 2 字节）
        ...u32le(cdSize), // central directory size
        ...u32le(cdOffset), // central directory offset
        0x00, 0x00, // comment length
      ];

  /// ZIP64 locator（20 字节定长，标准布局紧贴 EOCD 前方）
  List<int> zip64Locator({required int z64EocdOffset}) => [
        0x50, 0x4B, 0x06, 0x07, // 签名
        0x00, 0x00, 0x00, 0x00, // total disks
        ...u32le(z64EocdOffset & 0xFFFFFFFF), // offset 低 32 位
        ...u32le((z64EocdOffset >> 32) & 0xFFFFFFFF), // 高 32 位
        0x01, 0x00, 0x00, 0x00, // total disks (zip64)
      ];

  Future<ArchiveSniffResult> sniffBytes(String fileName, List<int> bytes) async {
    final f = File('${tmpDir.path}${Platform.pathSeparator}$fileName');
    await f.writeAsBytes(bytes);
    return ArchiveInspector.sniffSync(f.path);
  }

  group('尾部拼接 zip 嗅探（网盘过审壳）', () {
    test('路径 A：真 mp4 头 + 尾部 zip（EOCD 结构合法）→ 判 zip + 伪装标记', () async {
      const fillerLen = 1024;
      final zipDataStart = mp4Header.length + fillerLen;
      final zipData = <int>[0x50, 0x4B, 0x03, 0x04, ...List.filled(31, 0x33)];
      final tailGarbage = List.filled(113, 0x22); // 模拟 mp4 收尾结构
      final bytes = <int>[
        ...mp4Header,
        ...List.filled(fillerLen, 0x11),
        ...zipData,
        ...eocd(cdSize: zipData.length, cdOffset: zipDataStart),
        ...tailGarbage,
      ];

      final r = await sniffBytes('game.mp4', bytes);
      expect(r.format, 'zip');
      expect(r.isArchive, isTrue);
      expect(r.declaredExt, '.mp4');
      expect(r.disguised, isTrue, reason: '.mp4 对 zip 不合理 → 伪装包');
    });

    test('路径 B：ZIP64 占位 EOCD（0xFFFFFFFF）+ 紧前方 locator → 判 zip', () async {
      final locator = zip64Locator(z64EocdOffset: 2754231076);
      final bytes = <int>[
        ...mp4Header,
        ...List.filled(512, 0x11),
        ...locator,
        ...eocd(cdSize: 0xFFFFFFFF, cdOffset: 0xFFFFFFFF),
      ];

      final r = await sniffBytes('video.mp4', bytes);
      expect(r.format, 'zip');
      expect(r.disguised, isTrue);
    });

    test('EOCD 签名存在但结构非法（offset+size 超文件长且无 locator）→ 不误报', () async {
      final bytes = <int>[
        ...mp4Header,
        ...List.filled(512, 0x11),
        ...eocd(cdSize: 0x7FFFFFFF, cdOffset: 0x7FFFFFFF),
      ];

      final r = await sniffBytes('broken.mp4', bytes);
      expect(r.format, isNull, reason: '随机撞签名但结构不通不过校验');
    });

    test('普通 mp4（尾部无 EOCD）→ 不误报', () async {
      final bytes = <int>[
        ...mp4Header,
        ...List.filled(4096, 0x55),
        0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x65, 0x65, // free box 收尾
      ];

      final r = await sniffBytes('pure.mp4', bytes);
      expect(r.format, isNull);
      expect(r.isArchive, isFalse);
    });
  });

  group('既有判定回归（头部魔数不受尾部扫描影响）', () {
    test('正常 zip 头 → zip 且非伪装', () async {
      final bytes = <int>[0x50, 0x4B, 0x03, 0x04, ...List.filled(64, 0x11)];
      final r = await sniffBytes('normal.zip', bytes);
      expect(r.format, 'zip');
      expect(r.disguised, isFalse);
    });

    test('7z 魔数 → 7z', () async {
      final bytes = <int>[
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, ...List.filled(64, 0x11),
      ];
      final r = await sniffBytes('normal.7z', bytes);
      expect(r.format, '7z');
    });

    test('.zip.lz4 双后缀 → lz4 且非伪装', () async {
      final bytes = <int>[0x04, 0x22, 0x4D, 0x18, ...List.filled(64, 0x11)];
      final r = await sniffBytes('game.zip.lz4', bytes);
      expect(r.format, 'lz4');
      expect(r.disguised, isFalse);
    });

    test('文件不存在 → format null 不抛异常', () async {
      final r = ArchiveInspector
          .sniffSync('${tmpDir.path}${Platform.pathSeparator}nope.zip');
      expect(r.format, isNull);
    });

    test('极小文件（< 22 字节）→ format null 不抛异常', () async {
      final r = await sniffBytes('tiny.mp4', [0x50, 0x4B, 0x05]);
      expect(r.format, isNull);
    });
  });
}
