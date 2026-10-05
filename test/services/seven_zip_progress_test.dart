import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/seven_zip_progress.dart';

/// 7z 进度解析回归。
///
/// 背景（Phase 0 实测，2026-10-02）：旧正则 `^\s*(\d+)\s` 要求数字后跟**空白**，
/// 而 7z 实际输出是 `\r 94% 31 - src\file`（`%` 紧跟数字），命中率 1/37。
/// 结果就是**解压进度条从来没被真实百分比驱动过**。
void main() {
  group('SevenZipProgressParser.parse（行级）', () {
    test('压缩进度行：数字紧贴 %', () {
      expect(SevenZipProgressParser.parse('  5% 1 + src\\big.dat'), 5);
      expect(SevenZipProgressParser.parse(' 12% 1 + src\\big.dat'), 12);
      expect(SevenZipProgressParser.parse('100% 1 + src\\big.dat'), 100);
    });

    test('解压进度行：`- ` 前缀', () {
      expect(SevenZipProgressParser.parse(' 94% 31 - src\\rand_1.bin'), 94);
    });

    test('只有百分号、没有文件名', () {
      expect(SevenZipProgressParser.parse('  0%'), 0);
    });

    test('容忍数字与 % 之间的空白（不同版本表现有差异）', () {
      expect(SevenZipProgressParser.parse('  42 %'), 42);
    });

    test('信息行一律不误判（旧实现正是在这里踩坑）', () {
      // 旧正则会把这两行读成 1 / 135716363 → 被 <=100 拦掉一个、误报一个
      expect(SevenZipProgressParser.parse('1 file, 135716363 bytes (130 MiB)'),
          isNull);
      expect(SevenZipProgressParser.parse('Compressed: 135716363'), isNull);
      expect(SevenZipProgressParser.parse('Everything is Ok'), isNull);
      expect(SevenZipProgressParser.parse('Folders: 26'), isNull);
      expect(SevenZipProgressParser.parse(''), isNull);
      expect(SevenZipProgressParser.parse('                    '), isNull);
    });

    test('锚定行首，文件名里的 % 不误判', () {
      // 7z 的进度行永远在行首；裸 `(\d+)%` 会把这种行读成 50
      expect(SevenZipProgressParser.parse('- src\\year50%_off.dat'), isNull);
      expect(SevenZipProgressParser.parse('+ src\\v1.5%patch.xp3'), isNull);
    });

    test('超过 100 的值不返回', () {
      expect(SevenZipProgressParser.parse('999%'), isNull);
    });
  });

  group('SevenZipProgressParser.toPercentStream（流级）', () {
    Stream<List<int>> feed(String text, {int chunkSize = 3}) async* {
      final bytes = utf8.encode(text);
      for (var i = 0; i < bytes.length; i += chunkSize) {
        yield bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length));
      }
    }

    test('单调过滤：回退读数被丢弃', () async {
      final out = await SevenZipProgressParser.toPercentStream(
        feed(' 10%\r 30%\r 20%\r 50%\r'),
        throttle: Duration.zero,
      ).toList();
      expect(out, [10, 30, 50]);
    });

    test('末值必定补齐（小任务不被节流吃掉）', () async {
      // 一整段在一个节流窗口内到达：中间值被合并，但**末值必须发出**
      final out = await SevenZipProgressParser.toPercentStream(
        feed('  1%\r 40%\r 99%\r'),
        throttle: const Duration(minutes: 5),
      ).toList();
      expect(out.last, 99, reason: '收尾补齐：否则进度条会永远停在中间值');
    });

    test('100% 立即发出，不等节流窗口', () async {
      final out = await SevenZipProgressParser.toPercentStream(
        feed('  1%\r100%\r'),
        throttle: const Duration(minutes: 5),
      ).toList();
      expect(out.contains(100), isTrue);
    });

    test('GBK 字节不会打断流（allowMalformed 兜底）', () async {
      // 模拟未加 -sccUTF-8 时的 7z 输出：中文目录名的 GBK 字节
      final bytes = <int>[
        ...utf8.encode('  7% 1 + '),
        0xd6, 0xd0, 0xce, 0xc4, // 「中文」的 GBK
        ...utf8.encode('\r 88%\r'),
      ];
      final out = await SevenZipProgressParser
          .toPercentStream(Stream.fromIterable([bytes]))
          .toList();
      expect(out, [7, 88], reason: '非 UTF-8 字节不应抛异常，进度仍要走到 88');
    });

    test('多字节字符被切成两半也不崩', () async {
      final bytes = utf8.encode('  9% 1 + 日本語ファイル\r');
      final out = await SevenZipProgressParser.toPercentStream(
        Stream.fromIterable([
          bytes.sublist(0, 9),
          bytes.sublist(9),
        ]),
      ).toList();
      expect(out, [9]);
    });
  });

  group('退出码语义', () {
    test('0 成功 / 1 警告 / 其余非零', () {
      expect(SevenZipProgressParser.isSuccessCode(0), isTrue);
      expect(SevenZipProgressParser.isSuccessCode(1), isFalse);
      expect(SevenZipProgressParser.isWarningCode(1), isTrue);
    });

    test('退出码有可读描述，不把裸数字丢给用户', () {
      expect(SevenZipProgressParser.describeExitCode(0), '成功');
      expect(SevenZipProgressParser.describeExitCode(8), contains('内存'));
      expect(SevenZipProgressParser.describeExitCode(255), contains('中止'));
      expect(SevenZipProgressParser.describeExitCode(42), contains('42'));
    });
  });
}
