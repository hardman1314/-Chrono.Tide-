import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../core/path_helper.dart';
import 'openlist_service.dart';

/// OpenList 半移植化（2026-10-02）：按需「对接」服务。
///
/// 背景：安装包不再内置 OpenList（原内置 openlist.exe 148MB，占安装包
/// 体积大头）。改为：已登录用户在用户窗口点「对接」，或首次走官方下载
/// 时，从官方服务器下载整合包（zip ≈53MB）自动解压到 `runtime/`，
/// 解压后与既有运行时路径完全吻合（zip 顶层即 `openlist/`）。
///
/// 「已对接」判定 = `openlist.exe` 存在 —— 与 OpenListService boot 的
/// 文件检查同源，天然幂等，不新增持久化状态（重复对接即全量覆盖修复）。
class OpenListProvision {
  OpenListProvision._();

  /// OpenList 整合包下载地址（官方静态资源服务器）
  static const String packageUrl = 'http://117.72.115.30:8000/openlist.zip';

  /// 临时下载文件（data/tmp/ 中转；解压成功后删除，失败也要清理）
  static String get _tmpZipPath =>
      path.join(PathHelper.portableTmpDir, 'openlist.zip');

  /// 是否已对接（异步）
  static Future<bool> isPaired() async {
    try {
      return await File(PathHelper.openlistExePath).exists();
    } catch (_) {
      return false;
    }
  }

  /// 是否已对接（同步；用户窗口按钮区等 UI 处使用）
  static bool isPairedSync() {
    try {
      return File(PathHelper.openlistExePath).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 执行对接：下载整合包 → 内置 7z 解压到 runtime/ → 校验 exe。
  ///
  /// [onProgress] 下载进度 0.0~1.0（contentLength 未知时不回调）。
  /// [onStage] 阶段文案（「下载中…」「解压中…」）。
  ///
  /// 成功返回 null；失败返回可直接展示给用户的错误描述，
  /// 并保证不留下临时 zip（半解压目录由下次对接的全量覆盖 `-y` 修复）。
  static Future<String?> pair({
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('准备中…');

    // ① 前置检查：内置 7z 必须在（解压依赖它）
    if (!await File(PathHelper.bundled7zPath).exists()) {
      return '解压工具缺失（runtime/tools/7z.exe），请重新安装本程序';
    }

    // ② 下载到 data/tmp/ 中转
    try {
      await _download(onProgress);
    } catch (e) {
      debugPrint('[OL-PAIR] ❌ 下载失败: $e');
      await _cleanupTmp();
      return '下载失败：$e';
    }

    // ③ 解压（zip 顶层即 openlist/ → runtime/openlist/…）
    onStage?.call('解压中…');
    try {
      final runtimeDir = PathHelper.runtimeDir;
      await Directory(runtimeDir).create(recursive: true);
      final result = await Process.run(PathHelper.bundled7zPath, [
        'x',
        _tmpZipPath,
        '-o$runtimeDir',
        '-y', // 全量覆盖：重复对接 = 修复
      ]);
      if (result.exitCode != 0) {
        debugPrint(
            '[OL-PAIR] ❌ 7z 退出码 ${result.exitCode}: ${result.stdout}');
        await _cleanupTmp();
        return '解压失败（7z 退出码 ${result.exitCode}），请重试';
      }
    } catch (e) {
      debugPrint('[OL-PAIR] ❌ 解压异常: $e');
      await _cleanupTmp();
      return '解压失败：$e';
    }

    // ④ 校验 + 清理临时包
    onStage?.call('校验中…');
    if (!await isPaired()) {
      await _cleanupTmp();
      return '解压完成但服务组件不完整，整合包可能已损坏，请重试';
    }
    await _cleanupTmp();

    // ⑤ 写入新流程标记：此后更新/迁移逻辑将其识别为「用户主动对接的
    //    新流程资产」，永不自动清除（旧版安装包硬内置遗留则无此标记）。
    try {
      final marker = File(PathHelper.openlistProvisionMarkerPath);
      if (!await marker.exists()) {
        await marker.create(recursive: true);
      }
    } catch (e) {
      // 标记写失败不影响对接本身（下次「更新对接」会补写），只留日志
      debugPrint('[OL-PAIR] ⚠️ 对接标记写入失败: $e');
    }

    debugPrint('[OL-PAIR] ✅ 对接完成');
    return null;
  }

  /// 旧内置迁移（2026-10-04）：清除旧版安装包硬内置的 OpenList。
  ///
  /// 背景：2026-10-02 半移植化之前，安装包直接内置 `runtime/openlist/`；
  /// 这批用户升级后 `openlist.exe` 仍在，会被 `isPaired()` 误判为「已对接」。
  /// 产品决策：旧内置遗留统一清除，要求用户走新流程重新对接（下载整合包）。
  ///
  /// 判定 = 有 `openlist.exe` 但无 `.provisioned` 标记 → 视为旧内置遗留。
  /// 标记由 [pair] 成功后写入，生命周期与 OpenList 资产目录完全一致——
  /// 新流程对接用户（有标记）更新/重装后均保留，不受影响。
  ///
  /// 启动早期 fire-and-forget 调用；任何失败只留日志，绝不阻断启动。
  ///
  /// 内部用同步 IO（几个 stat 微秒级）：本方法在启动序列跑，无并发竞争，
  /// 同步实现还天然免疫 flutter_tester 直跑通道「异步 IO 完成回调永不
  /// 返回」的怪癖（2026-10-04 实测，与 ui.Image.toByteData 同类）。
  static Future<void> migrateLegacyIfNeeded() async {
    try {
      final exe = File(PathHelper.openlistExePath);
      if (!exe.existsSync()) return; // 未对接/已清除，无事可做

      final marker = File(PathHelper.openlistProvisionMarkerPath);
      if (marker.existsSync()) return; // 新流程资产，保留

      // 旧内置遗留：先停服务（防文件锁），再整目录删除
      debugPrint('[OL-MIGRATE] 检测到旧版内置 OpenList（无对接标记）→ 清除，待用户重新对接');
      OpenListService.stop();
      final dir = Directory(PathHelper.openlistDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      debugPrint('[OL-MIGRATE] ✅ 旧内置 OpenList 已清除');
    } catch (e) {
      // 清除失败不阻断启动：下次启动重试；OpenList 本身仍可正常运行
      debugPrint('[OL-MIGRATE] ⚠️ 迁移失败（下次启动重试）: $e');
    }
  }

  /// 下载：优先多连接分块并行（快），服务器不支持 Range 时退回单线程。
  ///
  /// 探测方式：先发 `Range: bytes=0-0` 的 GET——
  /// - 返回 206 → 支持 Range，解析 Content-Range 得到总大小，分块并行；
  /// - 返回 200 → 服务器忽略 Range（响应体即完整文件），直接单线程下载，
  ///   不浪费这次连接。
  ///
  /// 全程直连不走系统代理（代理环境会劫持内网地址）。
  static Future<void> _download(void Function(double)? onProgress) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = (uri) => 'DIRECT';

    try {
      final uri = Uri.parse(packageUrl);
      final probe = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      probe.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final resp = await probe.close().timeout(const Duration(seconds: 30));

      if (resp.statusCode == 206) {
        // 支持 Range：丢弃 1 字节探针体，解析总大小后分块并行
        await resp.drain<void>();
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final slash = cr.lastIndexOf('/');
        final total = slash == -1 ? -1 : int.tryParse(cr.substring(slash + 1)) ?? -1;
        if (total > 0) {
          await _downloadChunked(
              client: client, uri: uri, total: total, onProgress: onProgress);
          return;
        }
        // 总大小未知（异常服务器），退回单线程重新下载
        await _downloadSimple(client, uri, onProgress);
      } else if (resp.statusCode == 200) {
        // 服务器忽略 Range：这次响应体就是完整文件，直接保存
        await _saveStream(resp, onProgress);
      } else {
        throw '服务器返回 HTTP ${resp.statusCode}';
      }
    } finally {
      client.close();
    }
  }

  /// 多连接分块并行下载：6 个并发连接，每块写独立分片文件，全部完成后
  /// 按偏移合并为最终 zip。单块失败自动重试 2 次；任一块最终失败即整体
  /// 失败（清理所有分片，不留半成品）。
  static const int _chunkConcurrency = 6;

  static Future<void> _downloadChunked({
    required HttpClient client,
    required Uri uri,
    required int total,
    void Function(double)? onProgress,
  }) async {
    await Directory(PathHelper.portableTmpDir).create(recursive: true);
    final chunkSize = total ~/ _chunkConcurrency;
    String partPath(int i) => '${_tmpZipPath}.p$i';

    // 各块已收字节数 + 节流进度回调（多连接下回调频率高，150ms 节流防刷帧）
    final received = List<int>.filled(_chunkConcurrency, 0);
    var lastTick = DateTime.now();
    void report() {
      final now = DateTime.now();
      if (now.difference(lastTick).inMilliseconds >= 150) {
        lastTick = now;
        var sum = 0;
        for (final r in received) {
          sum += r;
        }
        onProgress?.call((sum / total).clamp(0.0, 1.0));
      }
    }

    Future<void> fetchChunk(int idx) async {
      final start = idx * chunkSize;
      final end = idx == _chunkConcurrency - 1 ? total - 1 : start + chunkSize - 1;
      final expect = end - start + 1;
      final part = File(partPath(idx));

      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          if (await part.exists()) await part.delete();
          final req = await client.getUrl(uri);
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
          final resp = await req.close().timeout(const Duration(seconds: 30));
          if (resp.statusCode != 206) {
            throw '分块下载返回 HTTP ${resp.statusCode}（期望 206）';
          }
          final sink = part.openWrite();
          var got = 0;
          try {
            await for (final chunk in resp) {
              sink.add(chunk);
              got += chunk.length;
              received[idx] = got;
              report();
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (got != expect) {
            throw '分块数据不完整（$got/$expect 字节）';
          }
          return;
        } catch (e) {
          if (attempt == 3) rethrow;
          debugPrint('[OL-PAIR] 分块 $idx 第 $attempt 次失败，重试: $e');
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }

    try {
      await Future.wait(
          [for (var i = 0; i < _chunkConcurrency; i++) fetchChunk(i)]);
    } catch (e) {
      await _cleanupChunks();
      rethrow;
    }

    // 按偏移合并分片 → 最终 zip（顺序写单个 RandomAccessFile，无并发竞争）
    final finalFile = File(_tmpZipPath);
    if (await finalFile.exists()) await finalFile.delete();
    final raf = await finalFile.open(mode: FileMode.write);
    try {
      for (var i = 0; i < _chunkConcurrency; i++) {
        final bytes = await File(partPath(i)).readAsBytes();
        await raf.setPosition(i * chunkSize);
        await raf.writeFrom(bytes);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    await _cleanupChunks();
    onProgress?.call(1.0);
    debugPrint(
        '[OL-PAIR] ✅ 分块下载完成 ${(total / 1048576).toStringAsFixed(1)}MB × $_chunkConcurrency 连接');
  }

  static Future<void> _cleanupChunks() async {
    for (var i = 0; i < _chunkConcurrency; i++) {
      try {
        final f = File('${_tmpZipPath}.p$i');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 单线程流式下载（Range 不可用时的兜底）
  static Future<void> _downloadSimple(
      HttpClient client, Uri uri, void Function(double)? onProgress) async {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 30));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw '服务器返回 HTTP ${response.statusCode}';
    }
    await _saveStream(response, onProgress);
  }

  /// 把响应体写入临时 zip（建目录 / 删旧文件 / 进度回调）
  static Future<void> _saveStream(
      HttpClientResponse response, void Function(double)? onProgress) async {
    await Directory(PathHelper.portableTmpDir).create(recursive: true);
    final tmp = File(_tmpZipPath);
    if (await tmp.exists()) await tmp.delete();

    final total = response.contentLength; // 未知时为 -1
    final sink = tmp.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    debugPrint(
        '[OL-PAIR] 下载完成（单线程）${(received / 1048576).toStringAsFixed(1)}MB');
  }

  static Future<void> _cleanupTmp() async {
    try {
      final f = File(_tmpZipPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
