// 下载链路韧性回归测试
//
// 覆盖 2026-09-08 「探索页云端安装经常失败」修复：
//   P0-1 分片断点续传（重试不再从 0 开始）
//   P0-2 分片字节数校验（流提前断流不再被误判为完成）
//   P0-3 HEAD 抖动重试
//   P0-4 云盘签名直链过期 → urlResolver 刷新后重试
//
// 所有用例用本地 HttpServer 模拟，不发真实网络请求。
//
// 注意：不要调用 TestWidgetsFlutterBinding.ensureInitialized() —— 它会安装
// HttpOverrides 让所有 HttpClient 请求直接返回 400。本测试不需要 widget 环境。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/download_core.dart';

/// 本地测试服务器，可注入各种故障。
class _FlakyServer {
  final HttpServer server;
  final int port;
  final int totalSize;

  /// 每个 Range 区间的请求次数（按 "start-end" 计数）
  final Map<String, int> _rangeAttempts = {};

  /// 是否把每个区间的第一次请求截断到一半后关闭连接（模拟服务器提前断流）
  final bool truncateFirstAttempt;

  /// 前 N 次 HEAD 返回 500
  int failHeadTimes = 0;
  int _headCount = 0;

  /// 以此前缀开头的路径一律返回 403（模拟签名直链过期）
  String expiredPrefix = '';

  /// 记录收到过的 Range 起始位置，用于断言「确实发生了续传」
  final List<int> rangeStarts = [];

  _FlakyServer._(this.server, this.port, this.totalSize,
      {required this.truncateFirstAttempt});

  static Future<_FlakyServer> start({
    required int totalSize,
    bool truncateFirstAttempt = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _FlakyServer._(server, server.port, totalSize,
        truncateFirstAttempt: truncateFirstAttempt);
    server.listen(s._handle);
    return s;
  }

  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> _handle(HttpRequest req) async {
    try {
      if (expiredPrefix.isNotEmpty &&
          req.uri.path.startsWith(expiredPrefix)) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }

      if (req.method == 'HEAD') {
        _headCount++;
        if (_headCount <= failHeadTimes) {
          req.response.statusCode = 500;
          await req.response.close();
          return;
        }
        req.response.headers
          ..set('content-length', '$totalSize')
          ..set('accept-ranges', 'bytes');
        await req.response.close();
        return;
      }

      final rangeHeader = req.headers.value('range');
      var start = 0;
      var end = totalSize - 1;
      if (rangeHeader != null) {
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
        if (m != null) {
          start = int.parse(m.group(1)!);
          end = int.parse(m.group(2)!);
        }
      }
      rangeStarts.add(start);

      final key = '$start-$end';
      final attempt = (_rangeAttempts[key] ?? 0) + 1;
      _rangeAttempts[key] = attempt;

      final remaining = end - start + 1;
      // 只截断「文件开头(0)的首次请求」一次，模拟真实网络的一次短暂断流；
      // 续传请求（start>0）正常补全。否则新分片策略下续传起点每次变化，
      // 会被「每个新区间都截断」的旧逻辑无限重新截断。
      final sendAll = !(truncateFirstAttempt && start == 0 && attempt == 1);
      final sendBytes = sendAll ? remaining : remaining ~/ 2;

      req.response.statusCode = rangeHeader == null ? 200 : 206;
      req.response.headers
        ..set('content-length', '$remaining')
        ..set('accept-ranges', 'bytes');

      // 只写 sendBytes 就关闭：模拟「Content-Length 说满、实际提前断流」。
      // 修复前 DownloadCore 会把这种情况当成分片成功 → 合并后大小不符。
      const chunkSize = 8192;
      var written = 0;
      while (written < sendBytes) {
        final n = (sendBytes - written) < chunkSize
            ? (sendBytes - written)
            : chunkSize;
        req.response.add(List<int>.filled(n, start & 0xFF));
        written += n;
      }
      await req.response.close();
    } catch (_) {
      // 客户端提前断开（取消/重试）时会走到这里，忽略
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Directory tmpDir;
  final servers = <_FlakyServer>[];

  setUpAll(() async {
    // 下载成功后 DownloadCore 会触发解压链路，其内部会读 SharedPreferences。
    // 没有 widget binding 时 platform channel 不可用，需用项目既有的 mock 方式。
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('ct_dl_test_');
    // 必须在任何路径 getter 首次解析之前设置
    PathHelper.exeDirOverride = tmpDir.path;
  });

  tearDownAll(() async {
    for (final s in servers) {
      await s.close();
    }
    PathHelper.exeDirOverride = null;
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<_FlakyServer> spinUp({
    required int totalSize,
    bool truncateFirstAttempt = false,
  }) async {
    final s = await _FlakyServer.start(
      totalSize: totalSize,
      truncateFirstAttempt: truncateFirstAttempt,
    );
    servers.add(s);
    return s;
  }

  group('DownloadCore 韧性', () {
    test('P0-1/P0-2 分片中途断流 → 续传补全且文件完整', () async {
      const size = 400 * 1024; // 400KB / 4 分片 = 100KB 每片
      final server =
          await spinUp(totalSize: size, truncateFirstAttempt: true);

      final core = DownloadCore();
      final errors = <String>[];
      core.addErrorListener(errors.add);

      await core.start(
        url: server.url('/game.rar'),
        gameId: 'resume-test',
        fileName: 'resume_test.bin',
      );

      expect(errors, isEmpty, reason: '不应报错: ${errors.join(" / ")}');
      expect(core.status, DownloadStatus.completed);

      // 续传断言：分片策略已改为差网络自适应档位（不再固定 4 分片），
      // 但断点续传语义不变——应出现「起点 > 0」（从已下载字节继续、而非从头）
      // 的 Range 请求。起点 0 表示从头开始（含吞吐探测请求）。
      final resumed = server.rangeStarts.where((s) => s > 0).toList();
      expect(resumed, isNotEmpty,
          reason: '应发生续传（出现起点大于 0 的 Range 请求，从已下载处继续）');

      final file = File(core.savedPath!);
      expect(await file.exists(), isTrue);
      expect(await file.length(), size,
          reason: '断流续传后最终文件大小必须精确等于 Content-Length');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('P0-3 HEAD 抖动 → 重试后成功', () async {
      const size = 64 * 1024;
      final server = await spinUp(totalSize: size);
      server.failHeadTimes = 2; // 前两次 HEAD 返回 500

      final core = DownloadCore();
      final errors = <String>[];
      core.addErrorListener(errors.add);

      await core.start(
        url: server.url('/game2.rar'),
        gameId: 'head-retry-test',
        fileName: 'head_retry.bin',
      );

      expect(errors, isEmpty, reason: '不应报错: ${errors.join(" / ")}');
      expect(core.status, DownloadStatus.completed);
      expect(await File(core.savedPath!).length(), size);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('P0-4 直链过期(403) → urlResolver 刷新后重试成功', () async {
      const size = 64 * 1024;
      final server = await spinUp(totalSize: size);
      server.expiredPrefix = '/old'; // 旧签名直链一律 403

      var resolved = 0;
      final core = DownloadCore();
      final errors = <String>[];
      core.addErrorListener(errors.add);

      await core.start(
        url: server.url('/old/game3.rar'),
        gameId: 'url-refresh-test',
        fileName: 'url_refresh.bin',
        urlResolver: () async {
          resolved++;
          return server.url('/new/game3.rar');
        },
      );

      expect(resolved, greaterThan(0),
          reason: '403 时应调用 urlResolver 刷新直链');
      expect(errors, isEmpty, reason: '不应报错: ${errors.join(" / ")}');
      expect(core.status, DownloadStatus.completed);
      expect(await File(core.savedPath!).length(), size);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
