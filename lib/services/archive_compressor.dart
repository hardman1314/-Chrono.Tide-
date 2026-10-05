/// 7-Zip 进程封装：压缩 / 校验 / 解包 / 哈希。
///
/// ## 设计约束
///
/// 🔴 **本文件不 import `package:flutter/*`**，`sevenZipPath` 由调用方注入
/// （生产环境传 `PathHelper.bundled7zPath`）。这样 `dart.exe` 能直接加载真实类
/// 做运行期验证 —— 本环境 `flutter test` 跑不通，纯 Dart 探针是唯一能"真的跑一遍"
/// 的手段。改动时请保持这一约束。
///
/// ## 命令形态（Phase 0 实测结论，2026-10-02）
///
/// - **cwd + `*` 形式**：`workdir = 源目录`、实参用 `*`。若写成
///   `7z a out.7z "<srcDir>\*"`，归档内部会**多一层目录名前缀**，解包后多一个套娃。
/// - **`-sccUTF-8` 必需**：中文 Windows 上 7z 控制台输出默认 GBK，会让 Dart 侧
///   `utf8.decoder` 抛 FormatException 打断进度流（本项目实测复现）。
/// - **不用 `-sdel`**：实测会把源**连目录一起删光**（805 → 0 文件）。
///   「压缩后删源」必须在 Dart 侧于 `7z t` 校验通过后再自行执行。
/// - **不用 `-v` 分卷**：`extract_manager._detectFormats` 的格式表只认 RAR 分卷
///   （`extract_manager.dart:737-779`），不认 `.7z.001`；用了会直接解压失败。
/// - **`-mmt=2`**：压缩是 CPU 密集任务，不限线程会把机器拖到没法用。
///
/// ## 半成品标记（M3）
///
/// 7z **直接写最终文件名、不产生 `.tmp`**（Phase 0 实测：中断后残留的是
/// `interrupted.7z`，与正常归档同名、无法区分）。因此这里把产物先写到
/// `<最终名>.partial`，成功后校验再改名 —— 残留的 `.partial` 即"半成品"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'seven_zip_progress.dart';

/// 压缩档位（对应用户可见的「平衡 / 极致」）
enum ArchiveCompressionLevel {
  /// `-mx=5 -md=64m`：默认档，速度与体积的平衡点
  balanced,

  /// `-mx=9 -md=128m -mfb=273 -ms=on`：极致压缩，明显更慢
  max,
  ;

  /// 持久化用字符串（`ArchiveLibraryPreference` 的取值）
  String get wire => this == ArchiveCompressionLevel.max ? 'max' : 'balanced';

  static ArchiveCompressionLevel fromWire(String? s) =>
      s == 'max' ? ArchiveCompressionLevel.max : ArchiveCompressionLevel.balanced;
}

/// 压缩结果。
class ArchiveCompressOutcome {
  /// 是否成功产出可用归档（**已通过 `7z t` 校验**）
  final bool ok;

  /// 是否被用户取消
  final bool cancelled;

  /// 最终归档绝对路径（失败时为空串）
  final String archivePath;

  /// 残留的半成品路径（失败且未清理干净时有值，用于提示用户）
  final String partialPath;

  final int bytes;
  final String sha256;
  final int exitCode;

  /// 失败原因（面向用户的中文描述）
  final String? error;

  /// 归档内文件数（`7z t` 输出解析所得，-1 = 未解析出）
  final int fileCount;

  const ArchiveCompressOutcome({
    required this.ok,
    this.cancelled = false,
    this.archivePath = '',
    this.partialPath = '',
    this.bytes = 0,
    this.sha256 = '',
    this.exitCode = 0,
    this.error,
    this.fileCount = -1,
  });

  static ArchiveCompressOutcome fail(
    String error, {
    bool cancelled = false,
    String partialPath = '',
    int exitCode = 0,
  }) =>
      ArchiveCompressOutcome(
        ok: false,
        cancelled: cancelled,
        error: error,
        partialPath: partialPath,
        exitCode: exitCode,
      );
}

/// 归档校验结果（`7z t`）。
class ArchiveVerifyOutcome {
  final bool ok;
  final int exitCode;

  /// 归档内**文件**数（不含目录，取自 `7z t` 的 `Files:` 行）；-1 = 未解析出
  final int fileCount;

  /// 归档内目录数（取自 `Folders:` 行）；-1 = 未解析出
  final int folderCount;

  /// 失败详情（取输出尾部若干行）
  final String detail;

  const ArchiveVerifyOutcome({
    required this.ok,
    this.exitCode = 0,
    this.fileCount = -1,
    this.folderCount = -1,
    this.detail = '',
  });
}

/// 7-Zip 进程封装。
class ArchiveCompressor {
  ArchiveCompressor({required this.sevenZipPath, this.onLog});

  /// 7z.exe 绝对路径（生产：`PathHelper.bundled7zPath`）
  final String sevenZipPath;

  /// 诊断日志回调（避免依赖 flutter 的 `debugPrint`）
  final void Function(String message)? onLog;

  Process? _current;
  bool _cancelRequested = false;

  /// 是否已有任务在跑
  bool get isRunning => _current != null;

  void _log(String msg) => onLog?.call(msg);

  /// 请求取消当前任务（幂等）。实际中止在 [compressDirectory] 的返回值里体现。
  Future<void> cancel() async {
    _cancelRequested = true;
    final proc = _current;
    if (proc == null) return;
    _log('[ARCHIVE] 收到取消请求，正在终止 7z 进程 (pid=${proc.pid})');
    proc.kill();
  }

  // ==================== 压缩 ====================

  /// 把 [sourceDir] 的内容压成一个 `.7z` 归档。
  ///
  /// 归档内的路径**相对于 [sourceDir]**（不包含源目录名本身）。
  ///
  /// [outputArchive] 必须是**源目录之外**的绝对/相对路径 —— 否则 7z 会把自己
  /// 也装进去（这里会直接拒绝）。
  ///
  /// 成功 = `exitCode == 0` **且** `7z t` 校验通过。任何一步不过都会删掉半成品
  /// 并返回失败（方案 §4.6：宁可不做，不留半成品）。
  Future<ArchiveCompressOutcome> compressDirectory({
    required String sourceDir,
    required String outputArchive,
    ArchiveCompressionLevel level = ArchiveCompressionLevel.balanced,
    List<String> recursiveExcludes = const [],
    List<String> topLevelExcludes = const [],
    void Function(int percent)? onProgress,
    Duration throttle = const Duration(milliseconds: 150),
  }) async {
    if (isRunning) {
      return ArchiveCompressOutcome.fail('已有压缩任务正在运行，请等待其完成');
    }

    final srcAbs = p.normalize(p.absolute(sourceDir));
    final srcDir = Directory(srcAbs);
    if (!await srcDir.exists()) {
      return ArchiveCompressOutcome.fail('源目录不存在: $srcAbs');
    }

    final outAbs = p.normalize(p.absolute(outputArchive));
    if (p.isWithin(srcAbs, outAbs)) {
      return ArchiveCompressOutcome.fail(
          '归档输出路径不能位于源目录内部（会造成自包含递归）: $outAbs');
    }

    final outParent = Directory(p.dirname(outAbs));
    if (!await outParent.exists()) {
      try {
        await outParent.create(recursive: true);
      } catch (e) {
        return ArchiveCompressOutcome.fail('无法创建归档目录: ${outParent.path} | $e');
      }
    }

    final partial = '$outAbs.partial';
    // 清掉上一次的同名残留，避免 7z 走 "-u 更新"分支
    try {
      final f = File(partial);
      if (await f.exists()) await f.delete();
    } catch (_) {}

    final args = <String>[
      'a',
      '-t7z',
      ..._levelSwitches(level),
      '-mmt=2',
      '-bsp1',
      '-bb1',
      '-sccUTF-8',
      '-y',
      for (final e in topLevelExcludes) '-x!$e',
      for (final e in recursiveExcludes) '-xr!$e',
      partial,
      '*',
    ];

    _log('[ARCHIVE] 压缩: $srcAbs -> $partial');
    _log('[ARCHIVE] 参数: ${args.join(' ')}');

    final run = await _run(
      args,
      workingDirectory: srcAbs,
      onProgress: onProgress,
      throttle: throttle,
    );

    if (run.cancelled) {
      await _safeDelete(partial);
      return ArchiveCompressOutcome.fail(
        '已取消',
        cancelled: true,
        exitCode: run.exitCode,
      );
    }

    if (run.exitCode != 0) {
      final desc = SevenZipProgressParser.describeExitCode(run.exitCode);
      await _safeDelete(partial);
      return ArchiveCompressOutcome.fail(
        '压缩失败：$desc${run.tail.isNotEmpty ? '\n${run.tail}' : ''}',
        exitCode: run.exitCode,
      );
    }

    // 产物存在性自检（exitCode=0 但没文件 = 环境异常）
    final partialFile = File(partial);
    if (!await partialFile.exists()) {
      return ArchiveCompressOutcome.fail(
        '7z 报告成功但未找到产物：$partial',
        exitCode: run.exitCode,
      );
    }

    // 🔴 校验前置：不通过就不改名、不返回成功，更不允许后续删源
    final verify = await testArchive(partial);
    if (!verify.ok) {
      await _safeDelete(partial);
      return ArchiveCompressOutcome.fail(
        '归档自检未通过（7z t: exit=${verify.exitCode}）'
        '${verify.detail.isNotEmpty ? '\n${verify.detail}' : ''}',
        exitCode: run.exitCode,
      );
    }

    final bytes = await partialFile.length();
    final sha = await sha256OfFile(partial);

    // 校验通过 → 改名成最终产物（改名即"转正"，此后不会再被判为半成品）
    try {
      final target = File(outAbs);
      if (await target.exists()) await target.delete();
      await partialFile.rename(outAbs);
    } catch (e) {
      return ArchiveCompressOutcome.fail(
        '归档改名失败（半成品已保留在 $partial）: $e',
        partialPath: partial,
        exitCode: run.exitCode,
      );
    }

    _log('[ARCHIVE] 压缩完成: $outAbs  ${bytes}B  files=${verify.fileCount}');

    // 显式补一发 100：7z 的进度在 solid 归档里常停在 99%，UI 需要明确的"完成"信号
    onProgress?.call(100);

    return ArchiveCompressOutcome(
      ok: true,
      archivePath: outAbs,
      bytes: bytes,
      sha256: sha,
      exitCode: run.exitCode,
      fileCount: verify.fileCount,
    );
  }

  List<String> _levelSwitches(ArchiveCompressionLevel level) {
    switch (level) {
      case ArchiveCompressionLevel.max:
        return const ['-mx=9', '-md=128m', '-mfb=273', '-ms=on'];
      case ArchiveCompressionLevel.balanced:
        return const ['-mx=5', '-md=64m'];
    }
  }

  // ==================== 校验 / 列举 / 哈希 ====================

  /// `7z t`：完整读取并校验归档（含内部 CRC）。
  ///
  /// Phase 0 实测：校验 129.4 MB 归档仅 **0.26 秒**，成本可忽略 ⇒
  /// 「删本体前必过校验」这条策略可以放心做成强制前置。
  Future<ArchiveVerifyOutcome> testArchive(
    String archivePath, {
    void Function(int percent)? onProgress,
  }) async {
    final f = File(archivePath);
    if (!await f.exists()) {
      return ArchiveVerifyOutcome(ok: false, exitCode: -1, detail: '归档不存在: $archivePath');
    }
    final run = await _run(
      ['t', '-bsp1', '-bb0', '-sccUTF-8', '-y', archivePath],
      onProgress: onProgress,
    );
    final files = _parseCount(run.all, 'Files:');
    final folders = _parseCount(run.all, 'Folders:');
    final ok = run.exitCode == 0;
    return ArchiveVerifyOutcome(
      ok: ok,
      exitCode: run.exitCode,
      fileCount: files,
      folderCount: folders,
      detail: ok ? '' : run.tail,
    );
  }

  /// 源目录递归文件数（**不含**目录），用于与归档内容做交叉比对。
  ///
  /// 纯 Dart 流式遍历，不物化列表；符号链接不跟随（与 `FsScan` 同策略）。
  static Future<int> countFilesRecursive(String dirPath) async {
    var n = 0;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) n++;
    }
    return n;
  }

  /// 用 7z 自带的 `-scrcSHA256` 算文件哈希。
  ///
  /// 为什么不用 Dart 实现：项目**没有 `crypto` 依赖**，而 §12 明确禁止为新功能
  /// 加依赖。7z 内置 SHA256，实测输出与 RFC 标准向量完全一致
  /// （`abc` → `ba7816bf…20015ad`）。大文件会多一次完整读盘，接受。
  Future<String> sha256OfFile(String filePath) async {
    try {
      final run = await _run(
        ['h', '-scrcSHA256', '-sccUTF-8', filePath],
        captureLimit: 400,
      );
      if (run.exitCode != 0) return '';
      // 优先取汇总行 "SHA256 for data:  <hex>"
      for (final line in run.all) {
        final idx = line.indexOf('SHA256 for data:');
        if (idx >= 0) {
          final hex = line.substring(idx + 'SHA256 for data:'.length).trim();
          if (hex.length == 64) return hex.toLowerCase();
        }
      }
      // 兜底：抓任意 64 位十六进制
      final re = RegExp(r'\b[0-9a-fA-F]{64}\b');
      for (final line in run.all) {
        final m = re.firstMatch(line);
        if (m != null) return m.group(0)!.toLowerCase();
      }
    } catch (e) {
      _log('[ARCHIVE] SHA256 计算失败: $filePath | $e');
    }
    return '';
  }

  // ==================== 解包 ====================

  /// `7z x`：把归档解到 [outputDir]（不存在则创建）。
  ///
  /// 归档内的路径结构原样还原。仅供**应用自有数据**（归档库内的 appdata/saves）
  /// 使用；游戏本体的解包走 `ExtractManager`（方案 §7 Phase 3）。
  Future<ArchiveCompressOutcome> extractArchive({
    required String archivePath,
    required String outputDir,
    void Function(int percent)? onProgress,
    Duration throttle = const Duration(milliseconds: 150),
    bool overwrite = true,
  }) async {
    if (isRunning) {
      return ArchiveCompressOutcome.fail('已有 7z 任务正在运行，请等待其完成');
    }
    final f = File(archivePath);
    if (!await f.exists()) {
      return ArchiveCompressOutcome.fail('归档不存在: $archivePath');
    }
    try {
      await Directory(outputDir).create(recursive: true);
    } catch (e) {
      return ArchiveCompressOutcome.fail('无法创建解包目录: $outputDir | $e');
    }

    final run = await _run(
      [
        'x',
        '-o$outputDir', // 🔴 `-o` 与路径之间**不能有空格**
        '-bsp1',
        '-sccUTF-8',
        overwrite ? '-aoa' : '-aos',
        '-y',
        archivePath,
      ],
      onProgress: onProgress,
      throttle: throttle,
    );

    if (run.cancelled) {
      return ArchiveCompressOutcome.fail('已取消', cancelled: true, exitCode: run.exitCode);
    }
    if (run.exitCode != 0) {
      return ArchiveCompressOutcome.fail(
        '解包失败：${SevenZipProgressParser.describeExitCode(run.exitCode)}'
        '${run.tail.isNotEmpty ? '\n${run.tail}' : ''}',
        exitCode: run.exitCode,
      );
    }
    return ArchiveCompressOutcome(ok: true, archivePath: archivePath, exitCode: run.exitCode);
  }

  // ==================== 内部 ====================

  Future<_RunResult> _run(
    List<String> args, {
    String? workingDirectory,
    void Function(int percent)? onProgress,
    Duration throttle = const Duration(milliseconds: 150),
    int captureLimit = 120,
  }) async {
    _cancelRequested = false;
    Process proc;
    try {
      proc = await Process.start(
        sevenZipPath,
        args,
        workingDirectory: workingDirectory,
        runInShell: false, // 不经 cmd，避免 `*` 被 shell 提前展开
      );
    } catch (e) {
      return _RunResult(exitCode: -2, cancelled: false, tail: '无法启动 7z: $e', all: const []);
    }

    _current = proc;
    final lines = <String>[];
    final sub = SevenZipProgressParser.toPercentStream(
      proc.stdout,
      throttle: throttle,
      onLine: (line) {
        lines.add(line);
        // 环形缓冲：只留末尾若干行做诊断，避免长任务把内存吃光
        if (lines.length > captureLimit) lines.removeAt(0);
      },
    ).listen(
      (percent) => onProgress?.call(percent),
      onError: (Object e) => _log('[ARCHIVE] 进度流异常(已忽略): $e'),
      cancelOnError: false,
    );

    final errBuf = StringBuffer();
    final errSub = proc.stderr
        // 与 stdout 同策略：`-sccUTF-8` 已让 7z 输出 UTF-8；再兜一层
        // allowMalformed 保证任何编码意外都不会打断流程（诊断信息允许花掉）。
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      if (errBuf.length < 8000) errBuf.write(chunk);
    }, onError: (_) {}, cancelOnError: false);

    final exitCode = await proc.exitCode;
    await sub.cancel();
    await errSub.cancel();
    _current = null;

    final cancelled = _cancelRequested;
    _cancelRequested = false;

    if (errBuf.isNotEmpty) {
      lines.addAll(errBuf.toString().split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty));
    }

    return _RunResult(
      exitCode: exitCode,
      cancelled: cancelled,
      tail: lines.takeLast(6).join('\n'),
      all: List<String>.unmodifiable(lines),
    );
  }

  static int _parseCount(List<String> lines, String prefix) {
    for (final line in lines.reversed) {
      final idx = line.indexOf(prefix);
      if (idx < 0) continue;
      final rest = line.substring(idx + prefix.length).trim();
      final m = RegExp(r'\d+').firstMatch(rest);
      if (m != null) return int.tryParse(m.group(0)!) ?? -1;
    }
    return -1;
  }

  static Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _RunResult {
  final int exitCode;
  final bool cancelled;
  final String tail;
  final List<String> all;
  const _RunResult({
    required this.exitCode,
    required this.cancelled,
    required this.tail,
    required this.all,
  });
}

extension on List<String> {
  List<String> takeLast(int n) => length <= n ? this : sublist(length - n);
}
