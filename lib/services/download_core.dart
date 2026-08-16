import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'extract_manager.dart';
import '../core/path_helper.dart';

enum DownloadStatus {
  idle,
  downloading,
  completed,
  failed,
  cancelled,
}

/// Isolate 合并参数
class _MergeParams {
  final List<String> chunkPaths;
  final String finalPath;
  final int expectedSize;
  final int bufferSize;

  const _MergeParams({
    required this.chunkPaths,
    required this.finalPath,
    required this.expectedSize,
    required this.bufferSize,
  });
}

/// Isolate 合并结果
class _MergeResult {
  final bool success;
  final String? error;

  const _MergeResult({required this.success, this.error});
}

/// 在独立 Isolate 中执行分片合并，避免同步 I/O 阻塞主 Isolate
_MergeResult _mergeChunksInIsolate(_MergeParams params) {
  try {
    final outFile = File(params.finalPath);
    final outRaf = outFile.openSync(mode: FileMode.write);

    try {
      for (int i = 0; i < params.chunkPaths.length; i++) {
        final chunkFile = File(params.chunkPaths[i]);
        if (!chunkFile.existsSync()) {
          throw Exception('分片$i临时文件无法合并');
        }

        final inRaf = chunkFile.openSync(mode: FileMode.read);
        try {
          final buffer = List<int>.filled(params.bufferSize, 0);
          int bytesRead;

          while ((bytesRead = inRaf.readIntoSync(buffer)) > 0) {
            if (bytesRead < buffer.length) {
              outRaf.writeFromSync(buffer.sublist(0, bytesRead));
            } else {
              outRaf.writeFromSync(buffer);
            }
          }
        } finally {
          inRaf.closeSync();
        }
      }

      outRaf.flushSync();

      final mergedLength = outRaf.lengthSync();
      if (mergedLength != params.expectedSize) {
        if (mergedLength > params.expectedSize) {
          outRaf.truncateSync(params.expectedSize);
        }
        outRaf.flushSync();
      }

      outRaf.closeSync();
    } catch (e) {
      outRaf.closeSync();
      return _MergeResult(success: false, error: e.toString());
    }

    final finalSize = outFile.lengthSync();
    if (finalSize != params.expectedSize) {
      return _MergeResult(
        success: false,
        error: '文件大小校验失败: 最终$finalSize ≠ 预期${params.expectedSize}',
      );
    }

    return const _MergeResult(success: true);
  } catch (e) {
    return _MergeResult(success: false, error: e.toString());
  }
}

class DownloadProgress {
  final double percent;
  final int downloadedBytes;
  final int totalBytes;
  final String speed;

  const DownloadProgress({
    required this.percent,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speed,
  });
}

class _ChunkTask {
  final int index;
  final int startByte;
  final int endByte;
  String tempPath;
  int receivedBytes = 0;
  bool completed = false;
  CancelToken? cancelToken;

  _ChunkTask({
    required this.index,
    required this.startByte,
    required this.endByte,
    required this.tempPath,
  });

  int get totalBytes => endByte - startByte + 1;
}

class DownloadCore {
  static final String _downloadBaseDir = PathHelper.downloadsDir;
  static const int _chunkCount = 4;
  static const double _downloadMaxPercent = 95.0;
  static const double _mergeStartPercent = 95.0;
  static const int _speedWindowSize = 5;
  static const int _progressThrottleMs = 500;
  static const int _logThrottlePercent = 5;
  static const int _ioBufferSize = 1024 * 1024;
  static const int _mergeBufferSize = 4 * 1024 * 1024; // 4MB，减少 I/O 调用次数

  static int _activeTaskCount = 0;
  static bool get hasActiveTask => _activeTaskCount > 0;

  static Dio? _sharedDio;
  static Dio get _dio {
    if (_sharedDio == null) {
      _sharedDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 300),
        sendTimeout: const Duration(seconds: 20),
        receiveDataWhenStatusError: true,
        headers: {
          'User-Agent': 'ChronoTide/2.0',
          'Connection': 'keep-alive',
          'Keep-Alive': 'timeout=120, max=100',
        },
      ));
    }
    return _sharedDio!;
  }

  DownloadStatus _status = DownloadStatus.idle;
  DownloadProgress? _progress;
  String? _savedPath;
  String? _errorMessage;
  String _currentGameId = '';
  String? _gameTitle;
  String? _gameDescription;
  String? _gameCoverUrl;
  List<String>? _gameTags;
  String? _gameDeveloper;
  String? _customGameLocation;
  List<String>? _screenshotUrls;

  final ExtractManager _extractManager = ExtractManager();

  final List<_ChunkTask> _chunks = [];
  int _singleStreamReceived = 0; // 单流下载的已接收字节数
  int _lastReceivedBytes = 0;
  DateTime? _lastSpeedTime;
  DateTime? _lastProgressEmitTime;
  DateTime? _lastLogTime;
  double _lastLoggedPercent = -1;

  final List<int> _speedWindow = [];
  int _speedWindowSum = 0;

  Timer? _progressTimer;
  Completer<void>? _extractionCompleter;

  final List<void Function(DownloadStatus)> _statusListeners = [];
  final List<void Function(DownloadProgress)> _progressListeners = [];
  final List<void Function(String path)> _completeListeners = [];
  final List<void Function(String message)> _errorListeners = [];

  DownloadStatus get status => _status;
  DownloadProgress? get progress => _progress;
  String? get savedPath => _savedPath;
  String? get errorMessage => _errorMessage;

  void addStatusListener(void Function(DownloadStatus) listener) {
    _statusListeners.add(listener);
  }

  void addProgressListener(void Function(DownloadProgress) listener) {
    _progressListeners.add(listener);
  }

  void addCompleteListener(void Function(String) listener) {
    _completeListeners.add(listener);
  }

  void addErrorListener(void Function(String) listener) {
    _errorListeners.add(listener);
  }

  void removeAllListeners() {
    _statusListeners.clear();
    _progressListeners.clear();
    _completeListeners.clear();
    _errorListeners.clear();
  }

  void _emitStatus(DownloadStatus s) {
    _status = s;
    for (final l in _statusListeners) {
      l(s);
    }
  }

  void _emitProgress(DownloadProgress p) {
    _progress = p;
    for (final l in _progressListeners) {
      l(p);
    }
  }

  void _emitComplete(String path) {
    _savedPath = path;
    for (final l in _completeListeners) {
      l(path);
    }
  }

  void _emitError(String msg) {
    _errorMessage = msg;
    for (final l in _errorListeners) {
      l(msg);
    }
  }

  Future<String> _resolveSaveDir(String gameId) async {
    final dir = Directory(_downloadBaseDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> start({
    required String url,
    required String gameId,
    String? fileName,
    String? title,
    String? description,
    String? coverUrl,
    List<String>? tags,
    String? developer,
    String? customGameLocation,
    List<String>? screenshotUrls,
  }) async {
    debugPrint(
        '[DOWNLOAD-CORE] 发起智能下载 | 游戏ID=$gameId | 直链=${url.length > 60 ? "${url.substring(0, 60)}..." : url}');

    if (_status == DownloadStatus.downloading) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 已有任务在执行，忽略重复请求');
      return;
    }

    _currentGameId = gameId;
    _gameTitle = title;
    _gameDescription = description;
    _gameCoverUrl = coverUrl;
    _gameTags = tags;
    _gameDeveloper = developer;
    _customGameLocation = customGameLocation;
    _screenshotUrls = screenshotUrls;
    _errorMessage = null;
    _savedPath = null;
    _extractionCompleter = Completer<void>();
    _lastReceivedBytes = 0;
    _lastSpeedTime = DateTime.now();
    _lastProgressEmitTime = DateTime.now();
    _lastLogTime = DateTime.now();
    _lastLoggedPercent = -1;
    _speedWindow.clear();
    _speedWindowSum = 0;
    _chunks.clear();
    _singleStreamReceived = 0;
    _emitStatus(DownloadStatus.downloading);
    _activeTaskCount++;

    try {
      final saveDir = await _resolveSaveDir(gameId);
      final dio = _dio;

      final headResponse = await dio.head(url);
      final contentLength = headResponse.headers.value('content-length');
      if (contentLength == null || contentLength!.isEmpty) {
        throw Exception('无法获取文件大小 服务器未返回Content-Length');
      }
      final totalSize = int.parse(contentLength!);

      if (totalSize <= 0) {
        throw Exception('文件大小无效：$totalSize');
      }

      final acceptRanges =
          headResponse.headers.value('accept-ranges')?.toLowerCase() ?? '';
      final supportsRange = acceptRanges == 'bytes';

      final name =
          _extractFileName(headResponse, url, fileName) ?? '$gameId.bin';
      final filePath = '$saveDir/$name';

      debugPrint('[DOWNLOAD-CORE]   保存路径: $filePath');
      debugPrint(
          '[DOWNLOAD-CORE]   文件大小: ${_formatBytes(totalSize)} | Range支持: $supportsRange');

      if (supportsRange) {
        debugPrint('[DOWNLOAD-CORE]   策略: 4线程分片下载');
        await _startMultiChunkDownload(
            dio, url, filePath, totalSize, _chunkCount);
      } else {
        debugPrint('[DOWNLOAD-CORE]   策略: 单流直连 (服务器不支持Range)');
        await _startSingleStreamDownload(dio, url, filePath, totalSize);
      }

      final size = await File(filePath).length();
      if (size == 0) {
        throw Exception('下载后文件大小为0');
      }

      // 文件大小容差校验：夸克云盘等网盘的 Content-Length 可能不准确
      // 允许 ±1% 误差，仅当差异超过 5% 时才判定失败
      if (totalSize > 0 && size > 0) {
        final diffRatio = (size - totalSize).abs() / totalSize;
        if (diffRatio > 0.05) {
          throw Exception(
              '文件大小差异过大: 实际${_formatBytes(size)} vs 预期${_formatBytes(totalSize)} (差异${(diffRatio * 100).toStringAsFixed(1)}%)');
        } else if (diffRatio > 0.01) {
          debugPrint(
              '[DOWNLOAD-CORE] ⚠️ 文件大小存在轻微差异(${(diffRatio * 100).toStringAsFixed(2)}%)，在容差范围内，继续处理');
        }
      }

      debugPrint(
          '[DOWNLOAD-CORE] ✅ 下载成功 | 本地路径: $filePath | 大小: ${_formatBytes(size)}');

      _emitProgress(DownloadProgress(
        percent: 100.0,
        downloadedBytes: size,
        totalBytes: size,
        speed: '0 B/s',
      ));

      // 先减少活跃任务计数，确保 completed 状态不会被后续异常覆盖
      if (_activeTaskCount > 0) _activeTaskCount--;

      // 发出 completed 状态 — 这是不可逆的，下载已确认成功
      _emitStatus(DownloadStatus.completed);
      _emitComplete(filePath);

      // 触发解压 — 即使解压失败，下载状态仍保持 completed
      // 之前的 bug：_triggerExtraction 抛异常会被 catch 捕获并覆盖 completed 为 failed
      try {
        await _triggerExtraction(filePath);
        debugPrint('[DOWNLOAD-CORE] ✅ 下载+解压流程全部完成');
      } catch (extractErr) {
        debugPrint(
            '[DOWNLOAD-CORE] ⚠️ 解压流程异常，但下载状态保持 completed | 错误: $extractErr');
        // 不覆盖 completed 状态，解压失败由 ExtractManager 自身的状态管理处理
      }
    } on DioException catch (e) {
      _stopProgressTimer();
      if (e.type == DioExceptionType.cancel) {
        _handleCancel();
        return;
      }
      _handleError(_mapDioError(e));
    } catch (e) {
      _stopProgressTimer();
      _handleError(e.toString());
    }
  }

  Future<void> _startSingleStreamDownload(
      Dio dio, String url, String filePath, int totalSize) async {
    _startProgressTimer(totalSize);

    final outFile = File(filePath);
    if (await outFile.exists()) {
      await outFile.delete();
    }

    // 使用 IOSink 异步写入，避免 writeFromSync 阻塞主 Isolate
    // IOSink.add() 将写入调度到 I/O 线程池，立即返回不阻塞事件循环
    final sink = outFile.openWrite();

    try {
      final response = await dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: CancelToken(),
      );

      await for (final data in response.data!.stream) {
        if (_status != DownloadStatus.downloading) break;
        // 直接将 Dio 流数据块写入 IOSink，无需中间缓冲
        // IOSink 内部有自己的缓冲，避免 addAll 造成的 GC 压力
        sink.add(data);
        _singleStreamReceived += data.length;
      }

      await sink.flush();
    } finally {
      await sink.close();
    }

    _stopProgressTimer();
  }

  Future<void> _startMultiChunkDownload(Dio dio, String url, String filePath,
      int totalSize, int chunkCount) async {
    final chunkSize = (totalSize / chunkCount).ceil();

    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? totalSize - 1 : start + chunkSize - 1;
      _chunks.add(_ChunkTask(
        index: i,
        startByte: start,
        endByte: end,
        tempPath: '${filePath}.part_$i.tmp',
      ));
    }

    debugPrint('[DOWNLOAD-CORE]   分片计划:');
    for (final c in _chunks) {
      debugPrint(
          '[DOWNLOAD-CORE]     分片${c.index}: ${_formatBytes(c.startByte)}-${_formatBytes(c.endByte)} (${_formatBytes(c.totalBytes)})');
    }

    _startProgressTimer(totalSize);

    await Future.wait(_chunks.map((c) => _downloadChunk(dio, url, c)));

    _stopProgressTimer();

    if (_status != DownloadStatus.downloading) return;

    debugPrint('[DOWNLOAD-CORE]   所有分片下载完成，开始合并...');

    _savedPath = filePath;
    await _mergeChunks(filePath, totalSize);
  }

  Future<void> _downloadChunk(Dio dio, String url, _ChunkTask chunk) async {
    const maxRetries = 3;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        chunk.cancelToken = CancelToken();

        final response = await dio.get<ResponseBody>(
          url,
          options: Options(
            headers: {
              'Range': 'bytes=${chunk.startByte}-${chunk.endByte}',
            },
            responseType: ResponseType.stream,
          ),
          cancelToken: chunk.cancelToken,
        );

        final file = File(chunk.tempPath);
        if (await file.exists()) await file.delete();

        // 使用 IOSink 异步写入，避免 writeFromSync 阻塞主 Isolate
        final sink = file.openWrite();
        try {
          await for (final data in response.data!.stream) {
            if (_status != DownloadStatus.downloading) break;
            // 直接写入 IOSink，不阻塞事件循环
            sink.add(data);
            chunk.receivedBytes += data.length;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        if (_status == DownloadStatus.downloading) {
          chunk.completed = true;
        }
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (attempt < maxRetries) {
          final backoff = min(2000 * pow(1.5, attempt), 8000).toInt();
          await Future.delayed(Duration(milliseconds: backoff));
          if (_status != DownloadStatus.downloading) return;
        } else {
          rethrow;
        }
      } catch (e) {
        if (attempt < maxRetries) {
          final backoff = min(2000 * pow(1.5, attempt), 8000).toInt();
          await Future.delayed(Duration(milliseconds: backoff));
          if (_status != DownloadStatus.downloading) return;
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _mergeChunks(String finalPath, int expectedSize) async {
    final outFile = File(finalPath);
    if (await outFile.exists()) {
      await outFile.delete();
    }

    try {
      debugPrint('[DOWNLOAD-CORE] 开始 Isolate 合并（不阻塞 UI）...');

      // 使用 Isolate 执行合并，避免同步 I/O 阻塞主 Isolate
      final chunkPaths = _chunks.map((c) => c.tempPath).toList();
      final mergeResult = await compute(
        _mergeChunksInIsolate,
        _MergeParams(
          chunkPaths: chunkPaths,
          finalPath: finalPath,
          expectedSize: expectedSize,
          bufferSize: _mergeBufferSize,
        ),
      );

      if (!mergeResult.success) {
        throw Exception(mergeResult.error);
      }

      // 清理临时分片文件
      for (final c in _chunks) {
        final tmp = File(c.tempPath);
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      }

      // 发送合并完成进度
      _emitProgress(DownloadProgress(
        percent: 99.9,
        downloadedBytes: expectedSize,
        totalBytes: expectedSize,
        speed: '合并完成',
      ));

      final finalSize = await outFile.length();
      debugPrint('[DOWNLOAD-CORE] ✅ 合并完成 | 大小: ${_formatBytes(finalSize)}');
    } catch (e) {
      if (await outFile.exists()) {
        try {
          await outFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  void _startProgressTimer(int totalSize) {
    _progressTimer?.cancel();
    // 性能优化：从 500ms 降低到 1000ms，减少 50% 的 UI 重建
    // 在 20MB/s 下，1秒间隔足以提供流畅的进度反馈
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) {
        if (_status != DownloadStatus.downloading) return;

        // 同时计算分片下载和单流下载的已接收字节数
        int totalReceived = _singleStreamReceived;
        bool allDone = _chunks.isEmpty ? false : true;
        for (final c in _chunks) {
          totalReceived += c.receivedBytes;
          if (!c.completed) allDone = false;
        }
        // 单流下载模式下，allDone 由 totalReceived >= totalSize 判定
        if (_chunks.isEmpty && totalReceived >= totalSize) {
          allDone = true;
        }

        final now = DateTime.now();
        final timeDelta = now.difference(_lastSpeedTime ?? now).inMilliseconds;
        final byteDelta = totalReceived - _lastReceivedBytes;

        int instantBps = 0;
        if (timeDelta >= 500 && byteDelta >= 0) {
          instantBps = (byteDelta / timeDelta * 1000).toInt();
          _pushSpeedSample(instantBps);
          _lastReceivedBytes = totalReceived;
          _lastSpeedTime = now;
        } else if (_speedWindow.isNotEmpty) {
          instantBps = (_speedWindowSum ~/ _speedWindow.length);
        }

        final smoothBps = _getSmoothedSpeed();
        final speedStr = _formatSpeed(smoothBps);

        final rawPct = (totalReceived / totalSize * 100).clamp(0.0, 100.0);
        final pct = (rawPct / 100.0 * _downloadMaxPercent)
            .clamp(0.0, _downloadMaxPercent);

        // 性能优化：仅当百分比变化 >=1% 或下载完成时才发射进度
        // 避免微小变化触发不必要的 UI 重建
        final lastEmitPct = _progress?.percent ?? -1.0;
        final pctChanged = (pct - lastEmitPct).abs() >= 1.0;

        if (pctChanged || pct >= 99.9 || allDone) {
          _emitProgress(DownloadProgress(
            percent: pct,
            downloadedBytes: totalReceived,
            totalBytes: totalSize,
            speed: speedStr,
          ));
        }
      },
    );
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _pushSpeedSample(int bps) {
    if (_speedWindow.length >= _speedWindowSize) {
      _speedWindowSum -= _speedWindow.removeAt(0);
    }
    _speedWindow.add(bps);
    _speedWindowSum += bps;
  }

  int _getSmoothedSpeed() {
    if (_speedWindow.isEmpty) return 0;
    return (_speedWindowSum ~/ _speedWindow.length).clamp(0, 104857600);
  }

  void cancel() {
    if (_status != DownloadStatus.downloading) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 当前无下载任务，无法取消');
      return;
    }

    debugPrint('[DOWNLOAD-CORE] 取消下载｜终止所有分片请求...');
    _stopProgressTimer();

    _handleCancel();
  }

  void _handleCancel() {
    // 防止重复处理：如果已经处于 cancelled 状态，直接返回
    if (_status == DownloadStatus.cancelled) return;

    if (_activeTaskCount > 0) _activeTaskCount--;
    _emitStatus(DownloadStatus.cancelled);

    _emitProgress(const DownloadProgress(
      percent: 0,
      downloadedBytes: 0,
      totalBytes: 0,
      speed: '0 B/s',
    ));

    for (final c in _chunks) {
      c.cancelToken?.cancel('用户主动取消');
    }

    _cleanupTempFiles();
  }

  Future<void> _cleanupTempFiles() async {
    debugPrint('[DOWNLOAD-CORE] 清理临时文件...');

    try {
      final dir = Directory(_downloadBaseDir);
      if (await dir.exists()) {
        int deletedCount = 0;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            if (name.contains('.chunk_') && name.endsWith('.tmp') ||
                name.contains('.part_') && name.endsWith('.tmp')) {
              await entity.delete();
              deletedCount++;
            }
          }
        }
        if (deletedCount > 0) {
          debugPrint('[DOWNLOAD-CORE] ✅ 已删除 $deletedCount 个临时文件');
        }
      }
    } catch (e) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 清理异常（可忽略）: $e');
    }
  }

  void _handleError(String rawMsg) {
    // 防止覆盖已设置的 cancelled 或 completed 状态
    if (_status == DownloadStatus.cancelled ||
        _status == DownloadStatus.completed) {
      return;
    }

    if (_activeTaskCount > 0) _activeTaskCount--;
    final cnMsg = _standardizeError(rawMsg);
    _emitStatus(DownloadStatus.failed);
    _emitError(cnMsg);
    _cleanupTempFiles();
    if (_savedPath != null) {
      try {
        final f = File(_savedPath!);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
      _savedPath = null;
    }
  }

  Future<void> _triggerExtraction(String filePath) async {
    debugPrint('[DOWNLOAD-CORE] 📦 下载完成，开始解压流程...');

    try {
      _extractManager.start(
        archivePath: filePath,
        gameTitle: _gameTitle ?? _currentGameId,
        gameDescription: _gameDescription,
        gameCoverUrl: _gameCoverUrl,
        gameTags: _gameTags,
        gameDeveloper: _gameDeveloper,
        customGameLocation: _customGameLocation,
        screenshotUrls: _screenshotUrls,
      );

      while (_extractManager.status == ExtractStatus.extracting) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (_extractManager.status == ExtractStatus.failed) {
        debugPrint('[DOWNLOAD-CORE] ❌ 解压失败: ${_extractManager.errorMessage}');
      } else {
        debugPrint('[DOWNLOAD-CORE] ✅ 解压流程已结束');
      }
    } catch (e) {
      debugPrint('[DOWNLOAD-CORE] ❌ 解压触发异常: $e');
    }

    if (!_extractionCompleter!.isCompleted) {
      _extractionCompleter!.complete();
    }
  }

  Future<void> waitForExtraction() async {
    return _extractionCompleter?.future ?? Future.value();
  }

  ExtractManager get extractManager => _extractManager;

  void reset() {
    _status = DownloadStatus.idle;
    _progress = null;
    _savedPath = null;
    _errorMessage = null;
    _currentGameId = '';
    _lastReceivedBytes = 0;
    _lastSpeedTime = null;
    _lastProgressEmitTime = null;
    _lastLogTime = null;
    _lastLoggedPercent = -1;
    _speedWindow.clear();
    _speedWindowSum = 0;
    _chunks.clear();
    _extractionCompleter = null;
    _stopProgressTimer();
    debugPrint('[DOWNLOAD-CORE] 状态已重置为空闲');
  }

  String _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '网络连接超时';
      case DioExceptionType.sendTimeout:
        return '请求发送超时';
      case DioExceptionType.receiveTimeout:
        return '服务器响应超时';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code >= 500) return '服务器内部错误 ($code)';
        if (code == 404) return '下载链接已失效 (404)';
        if (code == 403) return '没有下载权限 (403)';
        if (code == 416) return '服务器不支持分片下载 (Range请求失败)';
        return '请求失败 (HTTP $code)';
      case DioExceptionType.connectionError:
        return '无法连接到服务器';
      default:
        return e.message ?? '未知网络错误';
    }
  }

  String _standardizeError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('permission') || lower.contains('denied')) {
      return '文件写入失败：权限不足';
    }
    if (lower.contains('no space') || lower.contains('disk')) {
      return '磁盘空间不足';
    }
    if (lower.contains('socket') && lower.contains('refused')) {
      return '连接被拒绝，请检查OpenList服务是否运行';
    }
    if (lower.contains('connection closed') ||
        lower.contains('reset by peer') ||
        lower.contains('httpexception')) {
      return '下载过程中连接中断，网络不稳定';
    }
    if (lower.contains('大小不符') || lower.contains('临时文件丢失')) {
      return '分片数据不完整，下载可能被中断，请重新下载';
    }
    return raw;
  }

  String _extractFileName(Response headResponse, String url, String? fallback) {
    final uri = Uri.tryParse(url);
    String name = '';
    if (uri != null && uri.pathSegments.isNotEmpty) {
      name = uri.pathSegments.last;
    }
    if (name.isEmpty || !name.contains('.')) {
      final parts = url.split('/');
      for (var i = parts.length - 1; i >= 0; i--) {
        final seg = parts[i].split('?').first;
        if (seg.contains('.') && seg.isNotEmpty) {
          name = seg;
          break;
        }
      }
    }
    if (name.isEmpty || !name.contains('.')) {
      if (fallback != null && fallback.isNotEmpty) {
        name = fallback;
      } else {
        name = 'download.bin';
      }
    }

    debugPrint('[DOWNLOAD-CORE]   提取文件名: $name');
    return name;
  }

  String _formatSpeed(int bytes) {
    if (bytes < 1024) return '$bytes B/s';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytes / 1048576).toStringAsFixed(2)} MB/s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}
