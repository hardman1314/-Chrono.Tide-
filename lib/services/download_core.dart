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
  static const int _mergeBufferSize = 256 * 1024;

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
  String? _customGameLocation;

  final ExtractManager _extractManager = ExtractManager();

  final List<_ChunkTask> _chunks = [];
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
    String? customGameLocation,
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
    _customGameLocation = customGameLocation;
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

      debugPrint(
          '[DOWNLOAD-CORE] ✅ 下载成功 | 本地路径: $filePath | 大小: ${_formatBytes(size)}');

      _emitProgress(DownloadProgress(
        percent: 100.0,
        downloadedBytes: size,
        totalBytes: size,
        speed: '0 B/s',
      ));

      _emitStatus(DownloadStatus.completed);
      if (_activeTaskCount > 0) _activeTaskCount--;
      _emitComplete(filePath);

      await _triggerExtraction(filePath);

      debugPrint('[DOWNLOAD-CORE] ✅ 下载+解压流程全部完成');
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

    final raf = outFile.openSync(mode: FileMode.write);
    int receivedBytes = 0;

    try {
      final response = await dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: CancelToken(),
      );

      final buffer = <int>[];
      await for (final data in response.data!.stream) {
        if (_status != DownloadStatus.downloading) break;
        final bytes = data is List<int> ? data : (data as List).cast<int>();
        buffer.addAll(bytes);
        if (buffer.length >= _ioBufferSize) {
          raf.writeFromSync(buffer);
          buffer.clear();
        }
        receivedBytes += bytes.length;
      }

      if (buffer.isNotEmpty) {
        raf.writeFromSync(buffer);
        buffer.clear();
      }

      raf.flushSync();
    } finally {
      raf.closeSync();
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

        final raf = file.openSync(mode: FileMode.write);
        try {
          final buffer = <int>[];
          await for (final data in response.data!.stream) {
            if (_status != DownloadStatus.downloading) break;
            final bytes = data is List<int> ? data : (data as List).cast<int>();
            buffer.addAll(bytes);
            if (buffer.length >= _ioBufferSize) {
              raf.writeFromSync(buffer);
              buffer.clear();
            }
            chunk.receivedBytes += bytes.length;
          }
          if (buffer.isNotEmpty) {
            raf.writeFromSync(buffer);
            buffer.clear();
          }

          raf.flushSync();
        } finally {
          raf.closeSync();
        }

        if (_status == DownloadStatus.downloading) {
          chunk.completed = true;
          debugPrint(
              '[DOWNLOAD-CORE]   ✅ 分片${chunk.index}完成 | ${_formatBytes(chunk.receivedBytes)}');
        }
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (attempt < maxRetries) {
          final backoff = min(2000 * pow(1.5, attempt), 8000).toInt();
          debugPrint(
              '[DOWNLOAD-CORE]   ⚠️ 分片${chunk.index}第${attempt + 1}次失败: ${e.message} | ${backoff}ms后重试...');
          await Future.delayed(Duration(milliseconds: backoff));
          if (_status != DownloadStatus.downloading) return;
        } else {
          debugPrint('[DOWNLOAD-CORE]   ❌ 分片${chunk.index}重试耗尽 | ${e.message}');
          rethrow;
        }
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final isNetworkError = msg.contains('connection closed') ||
            msg.contains('socket') ||
            msg.contains('httpexception') ||
            msg.contains('reset by peer');
        if ((isNetworkError || true) && attempt < maxRetries) {
          final backoff = min(2000 * pow(1.5, attempt), 8000).toInt();
          debugPrint(
              '[DOWNLOAD-CORE]   ⚠️ 分片${chunk.index}异常(${attempt + 1}): $e | ${backoff}ms后重试...');
          await Future.delayed(Duration(milliseconds: backoff));
          if (_status != DownloadStatus.downloading) return;
        } else {
          debugPrint('[DOWNLOAD-CORE]   ❌ 分片${chunk.index}重试耗尽 | $e');
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
      debugPrint('[DOWNLOAD-CORE] 开始高速流式合并...');

      final outRaf = outFile.openSync(mode: FileMode.write);
      int totalWritten = 0;
      final totalChunks = _chunks.length;
      int yieldCounter = 0;

      try {
        for (int i = 0; i < _chunks.length; i++) {
          final chunkFile = File(_chunks[i].tempPath);
          if (!await chunkFile.exists()) {
            throw Exception('分片$i临时文件无法合并');
          }

          final actualSize = await chunkFile.length();

          final inRaf = chunkFile.openSync(mode: FileMode.read);
          try {
            final buffer = List<int>.filled(_mergeBufferSize, 0);
            int bytesRead;

            while ((bytesRead = inRaf.readIntoSync(buffer)) > 0) {
              if (bytesRead < buffer.length) {
                outRaf.writeFromSync(buffer.sublist(0, bytesRead));
              } else {
                outRaf.writeFromSync(buffer);
              }
              totalWritten += bytesRead;

              yieldCounter++;
              if (yieldCounter >= 4) {
                yieldCounter = 0;
                await Future.delayed(Duration.zero);
              }
            }
          } finally {
            inRaf.closeSync();
          }

          await chunkFile.delete();

          final mergePct = _mergeStartPercent +
              ((i + 1) / totalChunks * (100.0 - _mergeStartPercent));
          _emitProgress(DownloadProgress(
            percent: mergePct.clamp(_mergeStartPercent, 99.9),
            downloadedBytes: totalWritten,
            totalBytes: expectedSize,
            speed: '合并中...',
          ));
        }

        outRaf.flushSync();

        final mergedLength = outRaf.lengthSync();
        if (mergedLength != expectedSize) {
          if (mergedLength > expectedSize) {
            outRaf.truncateSync(expectedSize);
          }
          outRaf.flushSync();
        }

        outRaf.closeSync();
      } catch (e) {
        outRaf.closeSync();
        rethrow;
      }

      final finalSize = await outFile.length();
      if (finalSize != expectedSize) {
        throw Exception(
            '文件大小校验失败: 最终${_formatBytes(finalSize)} ≠ 预期${_formatBytes(expectedSize)}');
      }

      for (final c in _chunks) {
        final tmp = File(c.tempPath);
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      }

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
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (_status != DownloadStatus.downloading) return;

        int totalReceived = 0;
        bool allDone = true;
        for (final c in _chunks) {
          totalReceived += c.receivedBytes;
          if (!c.completed) allDone = false;
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

        final shouldLog = _shouldLogProgress(rawPct);
        if (shouldLog) {
          debugPrint(
              '[DOWNLOAD-CORE] 进度 | ${pct.toStringAsFixed(1)}% | $speedStr | ${_formatBytes(totalReceived)}/${_formatBytes(totalSize)}');
          _lastLogTime = now;
          _lastLoggedPercent = pct;
        }

        final shouldEmit =
            now.difference(_lastProgressEmitTime ?? now).inMilliseconds >=
                _progressThrottleMs;
        if (shouldEmit || pct >= 99.9 || allDone) {
          _emitProgress(DownloadProgress(
            percent: pct,
            downloadedBytes: totalReceived,
            totalBytes: totalSize,
            speed: speedStr,
          ));
          _lastProgressEmitTime = now;
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

  bool _shouldLogProgress(double pct) {
    final now = DateTime.now();
    final timeSinceLastLog = now.difference(_lastLogTime ?? now).inSeconds;
    final percentSinceLast = (pct - _lastLoggedPercent).abs();
    return timeSinceLastLog >= 3 || percentSinceLast >= _logThrottlePercent;
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
    if (_activeTaskCount > 0) _activeTaskCount--;
    _emitStatus(DownloadStatus.cancelled);

    _emitProgress(const DownloadProgress(
      percent: 0,
      downloadedBytes: 0,
      totalBytes: 0,
      speed: '0 B/s',
    ));

    debugPrint('[DOWNLOAD-CORE] 取消下载｜终止所有分片请求...');
    for (final c in _chunks) {
      c.cancelToken?.cancel('用户主动取消');
    }

    debugPrint('[DOWNLOAD-CORE] 删除临时文件...');
    _cleanupTempFiles();
    debugPrint('[DOWNLOAD-CORE] ✅ 取消完成');
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
    if (_activeTaskCount > 0) _activeTaskCount--;
    final cnMsg = _standardizeError(rawMsg);
    _emitStatus(DownloadStatus.failed);
    _emitError(cnMsg);
    debugPrint('[DOWNLOAD-CORE] ❌ 下载失败 | $cnMsg');
    debugPrint('[DOWNLOAD-CORE]   自动清理残留临时文件...');
    _cleanupTempFiles();
    if (_savedPath != null) {
      try {
        final f = File(_savedPath!);
        if (f.existsSync()) {
          f.deleteSync();
          debugPrint('[DOWNLOAD-CORE]   ✅ 已清理不完整文件: $_savedPath');
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
        customGameLocation: _customGameLocation,
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
