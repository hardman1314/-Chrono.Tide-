/// 7z 加密外壳 —— 云备份客户端加密（Phase 5 二期，方案 §7）。
///
/// 用途：上传前把归档目录打成一个**加密 7z**（`-mx=0` 仅存储 + `-mhe=on`
/// 头加密），下载后用密码解包回目录。云端对象是标准 7z —— 即使本应用
/// 哪天不在了，用户拿密码用任意 7-Zip 也能解开（数据主权友好）。
///
/// 为什么不用 `archive` 包的 Zip 加密：全内存操作，GB 级归档会 OOM；
/// 7z 是磁盘到磁盘，内存恒定。为什么不重用 [ArchiveCompressor]：它不支持
/// 密码参数，且本类职责单一（加密/解密，无 verify/SHA 链路），独立实现
/// 保持 cloud_backup 目录「无 flutter 依赖、探针可实测」。
///
/// 已知边缘：密码含英文双引号在 Windows 命令行传参存在 CRT 转义歧义
/// （Dart Process 层转义后 7z 端解析），UI 文档提示避免双引号即可；
/// 空格/中文/常见符号已由探针实测覆盖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 加密/解密结果。
class CryptOutcome {
  final bool ok;
  final String? error;
  final bool wrongPassword; // 解密密码错误（exitCode=2 且输出含 Wrong password）

  const CryptOutcome._(this.ok,
      {this.error, this.wrongPassword = false});

  factory CryptOutcome.fail(String msg, {bool wrongPassword = false}) =>
      CryptOutcome._(false, error: msg, wrongPassword: wrongPassword);
  factory CryptOutcome.success() => const CryptOutcome._(true);
}

/// 进度回调在独立 Isolate 中节流后回传主 isolate。
typedef PercentSink = void Function(int percent);

class ArchiveCryptor {
  ArchiveCryptor({required this.sevenZipPath});

  /// 7z.exe 绝对路径（生产：`PathHelper.bundled7zPath`）。
  final String sevenZipPath;

  /// 把 [sourceDir] 内容打成一个加密 7z（仅存储 + 头加密）。
  ///
  /// 归档内路径相对 [sourceDir]（不含源目录名）。[outputArchive] 若已存在
  /// 会被覆盖；先写 `.partial` 成功后改名（与归档服务同语义）。
  Future<CryptOutcome> packEncrypted({
    required String sourceDir,
    required String outputArchive,
    required String password,
    PercentSink? onProgress,
  }) async {
    final src = Directory(sourceDir);
    if (!await src.exists()) {
      return CryptOutcome.fail('源目录不存在：$sourceDir');
    }
    final partial = '$outputArchive.partial';
    try {
      final old = File(partial);
      if (await old.exists()) await old.delete();
    } catch (_) {}

    // 密码经 isolate 传参（String 拷贝），args 数组交给 Process（Dart 负责引号）
    final r = await _run([
      'a',
      '-t7z',
      '-mx=0', // 仅存储：已压缩的 7z 不再压，速度快
      '-mhe=on', // 头加密：文件名列表也受密码保护
      '-mmt=2',
      '-bsp1',
      '-sccUTF-8',
      '-y',
      '-p$password',
      partial,
      '*',
    ], workingDirectory: sourceDir, onProgress: onProgress);

    if (r.exitCode != 0) {
      await _quietDelete(partial);
      return CryptOutcome.fail('加密打包失败（7z exit=${r.exitCode}）\n${r.tail}');
    }
    final f = File(partial);
    if (!await f.exists()) {
      return CryptOutcome.fail('7z 报告成功但未找到产物：$partial');
    }
    try {
      final target = File(outputArchive);
      if (await target.exists()) await target.delete();
      await f.rename(outputArchive);
    } catch (e) {
      return CryptOutcome.fail('加密包改名失败（半成品保留在 $partial）：$e');
    }
    return const CryptOutcome._(true);
  }

  /// 把加密 7z 解包到 [targetDir]（目录自动创建；已有同路径文件被覆盖）。
  Future<CryptOutcome> unpackDecrypted({
    required String archive,
    required String targetDir,
    required String password,
    PercentSink? onProgress,
  }) async {
    final f = File(archive);
    if (!await f.exists()) {
      return CryptOutcome.fail('加密包不存在：$archive');
    }
    await Directory(targetDir).create(recursive: true);

    final r = await _run([
      'x',
      '-p$password',
      '-o$targetDir',
      '-bsp1',
      '-y',
      archive,
    ], onProgress: onProgress);

    if (r.exitCode != 0) {
      final wrong = r.tail.contains('Wrong password') ||
          r.tail.contains('ERROR: Data Error') ||
          r.tail.contains('Cannot open encrypted archive');
      return CryptOutcome.fail(
        '解密失败（7z exit=${r.exitCode}）${wrong ? '\n密码错误或归档损坏' : '\n${r.tail}'}',
        wrongPassword: wrong,
      );
    }
    return const CryptOutcome._(true);
  }

  // ---------------------------------------------------------------------------
  // 进程封装（简版 _run；进度解析同 SevenZipProgressParser 的 `^\s*(\d+)%`）
  // ---------------------------------------------------------------------------

  Future<_CryptRun> _run(
    List<String> args, {
    String? workingDirectory,
    PercentSink? onProgress,
  }) async {
    Process proc;
    try {
      proc = await Process.start(
        sevenZipPath,
        args,
        workingDirectory: workingDirectory,
        runInShell: false,
      );
    } catch (e) {
      return _CryptRun(exitCode: -2, tail: '无法启动 7z: $e');
    }

    final lines = <String>[];
    final outSub = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitterCompat())
        .listen((line) {
      if (line.trim().isEmpty) return;
      lines.add(line);
      if (lines.length > 120) lines.removeAt(0);
      if (onProgress != null) {
        final m = RegExp(r'^\s*(\d+)%').firstMatch(line);
        if (m != null) {
          final pct = int.tryParse(m.group(1)!);
          if (pct != null) onProgress(pct.clamp(0, 100));
        }
      }
    }, onError: (_) {}, cancelOnError: false);

    final errBuf = StringBuffer();
    final errSub = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      if (errBuf.length < 8000) errBuf.write(chunk);
    }, onError: (_) {}, cancelOnError: false);

    final exitCode = await proc.exitCode;
    await outSub.cancel();
    await errSub.cancel();
    if (errBuf.isNotEmpty) {
      lines.addAll(errBuf.toString().split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty));
    }
    return _CryptRun(
      exitCode: exitCode,
      tail: lines.length <= 6 ? lines.join('\n') : lines.sublist(lines.length - 6).join('\n'),
    );
  }

  Future<void> _quietDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _CryptRun {
  final int exitCode;
  final String tail;
  const _CryptRun({required this.exitCode, required this.tail});
}

/// 简易按行切分（stdout 是块流，按 \r|\n 都切；7z 进度条用 \r 刷新）。
class LineSplitterCompat
    extends StreamTransformerBase<String, String> {
  const LineSplitterCompat();

  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buf = '';
    await for (final chunk in stream) {
      buf += chunk;
      var idx = _nextBreak(buf, 0);
      while (idx >= 0) {
        final line = buf.substring(0, idx);
        buf = buf.substring(idx + 1);
        if (line.trim().isNotEmpty) yield line;
        idx = _nextBreak(buf, 0);
      }
    }
    if (buf.trim().isNotEmpty) yield buf;
  }

  int _nextBreak(String s, int from) {
    final cr = s.indexOf('\r', from);
    final lf = s.indexOf('\n', from);
    if (cr < 0) return lf;
    if (lf < 0) return cr;
    return cr < lf ? cr : lf;
  }
}
