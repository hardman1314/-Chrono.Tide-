/// 7-Zip stdout 进度解析（压缩 / 解压共用）。
///
/// ## 为什么需要这个文件
///
/// `extract_manager.dart` 原本自带一个私有解析器 `_parse7zLine`，正则写作
/// `^\s*(\d+)\s` —— 它要求**数字后面跟空白**。但 7z 在 `-bsp1` 下输出的进度行是：
///
/// ```
/// \r  5% 1 + src\big_compre...        ← 压缩（a 命令）
/// \r 94% 31 - src\big_incom...        ← 解压（x 命令）
/// ```
///
/// `%` 是**紧跟在数字后面**的，因此旧正则几乎永不命中。Phase 0 实测（2026-10-02）：
/// 用 Dart `LineSplitter` 切分真实 7z stdout，得到 173 段（压缩）/ 37 段（解压），
/// 旧正则命中 **1/173** 与 **1/37**，而那一两次命中还是把
/// `1 file, 135716363 bytes` 这类普通信息行误读成了百分比。
///
/// ⇒ **现有解压进度条从来没有被真实百分比驱动过**，只是在骨架值之间跳动。
///
/// 新正则 `^\s*(\d{1,3})\s*%` 实测命中 **76/173** 与 **4/37**，解析出的百分比序列
/// **单调不减**（见 `dev_probe/phase1_progress_parser_probe.dart` 与
/// `test/services/seven_zip_progress_test.dart`）。
///
/// 🔴 本文件**刻意不 import `package:flutter/*`**，以便用 `dart.exe` 直接加载真实类
/// 做运行期验证（本环境 `flutter test` 跑不通）。改动时请保持这一约束。
library;

import 'dart:async';
import 'dart:convert';

/// 7z 进度行解析器。
class SevenZipProgressParser {
  SevenZipProgressParser._();

  /// 进度行形如 `  5% 1 + file` / ` 94% 31 - file` / `  0%`。
  ///
  /// - `^\s*` 允许行首的补白空格（7z 会右对齐数字）；
  /// - `(\d{1,3})` 百分比最大三位；
  /// - `\s*%` 容忍数字与 `%` 之间可能的空白（不同版本表现有差异）。
  ///
  /// 之所以**锚定行首**而不是用裸 `(\d{1,3})%`：避免把文件名里恰好出现的
  /// `50%`（例如 `- src\year50%.dat`）误读成进度。7z 的进度行永远在行首。
  static final RegExp _percentPattern = RegExp(r'^\s*(\d{1,3})\s*%');

  /// 解析单行，返回 0..100 的百分比；不是进度行则返回 `null`。
  static int? parse(String line) {
    if (line.isEmpty) return null;
    // 只扫行首一小段：进度行极短，长行一定是文件清单/信息行
    final head = line.length > 64 ? line.substring(0, 64) : line;
    final m = _percentPattern.firstMatch(head);
    if (m == null) return null;
    final v = int.tryParse(m.group(1)!);
    if (v == null || v < 0 || v > 100) return null;
    return v;
  }

  /// 把 7z 的 stdout 字节流转换为「单调不减 + 节流」的百分比流。
  ///
  /// - **单调过滤**：7z 在 solid 归档里会回退重扫，直接透传会让进度条抖动；
  ///   这里丢弃所有 `<= 上次数值` 的读数。
  /// - **节流**：`throttle` 内的读数合并，只发最后一个；`100` 永远立即发出，
  ///   避免最后一格被节流吃掉。
  /// - 父流结束时关闭；`onCancel` 会取消对父流的订阅（进程被 kill 时能收干净）。
  ///
  /// [onLine] 是**诊断旁路**：`process.stdout` 是单订阅流，不能既 listen 进度
  /// 又 listen 原始行。因此这里把原始行顺带回传，调用方用它保留末尾若干行做
  /// 失败排查，而不必再挂第二个 listener（挂了会抛
  /// `Bad state: Stream has already been listened to`）。
  static Stream<int> toPercentStream(
    Stream<List<int>> stdout, {
    Duration throttle = const Duration(milliseconds: 150),
    void Function(String line)? onLine,
  }) {
    final controller = StreamController<int>();
    // 首帧必定发出，让 UI 立刻知道任务开始了
    var lastSeen = -1;
    var lastEmitted = -1;
    var lastEmittedAt = DateTime.fromMillisecondsSinceEpoch(0);
    late StreamSubscription<String> sub;

    sub = stdout
        // 🔴 `allowMalformed: true` 是必需的：7z 在中文 Windows 上的控制台输出
        // 默认是 **GBK** 字节（实测 `7z a -bb1` 输出 `\xd6\xd0\xce\xc4` 而非
        // UTF-8），而 `utf8.decoder` 默认 `allowMalformed: false` 会直接抛
        // FormatException 打断整条流。调用方应同时给 7z 传 `-sccUTF-8`
        // 让输出真正变成 UTF-8；这里再兜一层，保证任何编码异常都不会
        // 掀掉进度流（进度行本身是纯 ASCII，不受影响）。
        .transform(const Utf8Decoder(allowMalformed: true))
        // LineSplitter 同时切 `\r` 与 `\n`（Phase 0 实测），
        // 而 7z 正是用 `\r` 刷新进度、用 `\r\n` 输出普通行。
        .transform(const LineSplitter())
        .listen(
      (line) {
        onLine?.call(line);
        final v = parse(line);
        if (v == null || v <= lastSeen) return;
        lastSeen = v;
        final now = DateTime.now();
        final mustFlush =
            v >= 100 || now.difference(lastEmittedAt) >= throttle;
        if (!mustFlush) return;
        lastEmittedAt = now;
        lastEmitted = v;
        if (!controller.isClosed) controller.add(v);
      },
      onError: (Object e, StackTrace st) {
        if (!controller.isClosed) controller.addError(e, st);
      },
      onDone: () {
        // 🔴 收尾补齐（2026-10-02 探针实测踩出来的）：
        // 小任务往往在**同一个节流窗口内**就跑完了，末值会被节流吃掉；
        // 而 stdout 一关流就结束，下游永远收不到更高的值 ——
        // 实测现象是进度条停在 53% 不动。这里在流结束时补发最后的读数。
        if (lastSeen > lastEmitted && !controller.isClosed) {
          controller.add(lastSeen);
        }
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: false,
    );

    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  /// 7z 退出码语义（7-Zip 官方文档 `Exit codes`）。
  ///
  /// `0` 正常；`1` 警告（如"文件被占用跳过"）——**归档通常仍可用**，但调用方
  /// 必须结合 `7z t` 校验决定是否接受（见 `ArchiveCompressor`）。
  static bool isSuccessCode(int exitCode) => exitCode == 0;

  /// `1` = 有警告，产物可能不完整；调用方应视为「需校验」而非「直接失败」。
  static bool isWarningCode(int exitCode) => exitCode == 1;

  /// 人类可读的退出码说明（用于错误提示，避免用户只看到数字）。
  static String describeExitCode(int exitCode) {
    switch (exitCode) {
      case 0:
        return '成功';
      case 1:
        return '完成但有警告（部分文件被跳过）';
      case 2:
        return '致命错误（7z 无法完成操作）';
      case 7:
        return '命令行参数错误';
      case 8:
        return '内存不足';
      case 255:
        return '用户中止';
      default:
        return '未知错误（退出码 $exitCode）';
    }
  }
}
