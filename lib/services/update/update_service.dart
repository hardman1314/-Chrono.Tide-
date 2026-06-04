import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:math';
import 'dart:async'; // 添加Timer支持
import 'update_models.dart';

// 正确的相对路径导入日志工具
import '../../app_log_helper.dart';

// 导入进程清理服务
import '../process_cleanup_service.dart';

import '../../core/backend_config.dart';

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();
  BuildContext? appContext;

  /// 更新服务器地址
  /// 开源版本：如果后端可用则使用同一服务器的更新端口，否则为空
  static String get _serverUrl {
    if (BackendConfig.pbBaseUrl.isEmpty) return '';
    // 从 PB 地址推导更新服务地址（同IP，端口8000）
    return BackendConfig.pbBaseUrl.replaceFirst(':8090', ':8000') +
        '/version.json';
  }

  static const int _skipDurationDays = 7;
  static const int _threadCount = 4; // 4线程并行下载
  static const int _maxRetriesPerChunk = 5; // 每个分片最多重试5次
  static const int _connectTimeoutSeconds = 60; // 连接超时60秒
  static const int _receiveTimeoutMinutes = 15; // 接收超时15分钟
  static const int _ioBufferSize = 1024 * 1024; // 1MB IO缓冲区

  static int _compareVersions(String v1, String v2) {
    final p1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final p2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = p1.length > p2.length ? p1.length : p2.length;
    for (int i = 0; i < len; i++) {
      final a = i < p1.length ? p1[i] : 0;
      final b = i < p2.length ? p2[i] : 0;
      if (a > b) return 1;
      if (a < b) return -1;
    }
    return 0;
  }

  Future<String> _getLocalVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      AppLogHelper.info('✅ 获取本地版本成功: ${info.version}');
      return info.version;
    } catch (e, stack) {
      AppLogHelper.error('❌ 获取本地版本失败', e, stack);
      rethrow;
    }
  }

  /// 清理JSON字符串中的控制字符
  String _cleanJsonString(String rawJson) {
    // 移除所有控制字符（除了正常的换行符和制表符，它们会在字符串值中被转义）
    final buffer = StringBuffer();
    bool inString = false;
    bool escapeNext = false;

    for (int i = 0; i < rawJson.length; i++) {
      final char = rawJson[i];
      final code = rawJson.codeUnitAt(i);

      if (escapeNext) {
        buffer.write(char);
        escapeNext = false;
        continue;
      }

      if (char == '\\') {
        buffer.write(char);
        escapeNext = true;
        continue;
      }

      if (char == '"') {
        inString = !inString;
        buffer.write(char);
        continue;
      }

      if (inString) {
        // 在字符串内部，将控制字符转义或移除
        if (code == 10) {
          // 换行符 \n
          buffer.write('\\n');
        } else if (code == 13) {
          // 回车符 \r
          buffer.write('\\r');
        } else if (code == 9) {
          // 制表符 \t
          buffer.write('\\t');
        } else if (code < 32) {
          // 其他控制字符，直接忽略
          AppLogHelper.info('⚠️ 移除控制字符: $code (位置 $i)');
        } else {
          buffer.write(char);
        }
      } else {
        // 在字符串外部，移除所有空白控制字符
        if (code >= 32 ||
            char == ' ' ||
            code == 10 ||
            code == 13 ||
            code == 9) {
          buffer.write(char);
        }
      }
    }

    return buffer.toString();
  }

  Future<VersionInfo> _fetchServerVersion() async {
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 10);
    dio.options.receiveTimeout = const Duration(seconds: 15);

    AppLogHelper.info('🌐 开始请求服务器版本信息...');
    AppLogHelper.info('📍 请求URL: $_serverUrl');

    try {
      final response = await dio.get(
        _serverUrl,
        options: Options(responseType: ResponseType.plain),
      );

      AppLogHelper.info('✅ HTTP请求成功');
      AppLogHelper.info('📊 状态码: ${response.statusCode}');
      AppLogHelper.info('📏 响应大小: ${response.data?.length ?? 0} 字节');

      if (response.statusCode != 200) {
        throw Exception('HTTP错误: ${response.statusCode}');
      }

      final rawData = response.data.toString();

      AppLogHelper.info(
          '📝 原始响应数据(前200字符): ${rawData.substring(0, rawData.length > 200 ? 200 : rawData.length)}');

      // 清理控制字符
      final cleanedJson = _cleanJsonString(rawData);

      AppLogHelper.info('🧹 JSON已清理控制字符');

      // 解析JSON
      Map<String, dynamic> jsonData;
      try {
        jsonData = jsonDecode(cleanedJson) as Map<String, dynamic>;
        AppLogHelper.info('✅ JSON解析成功');
      } on FormatException catch (e) {
        AppLogHelper.error('❌ JSON解析失败（清理后仍然失败）', e, StackTrace.current);
        AppLogHelper.error(
            '📄 清理后的JSON(前500字符)',
            cleanedJson.substring(
                0, cleanedJson.length > 500 ? 500 : cleanedJson.length),
            StackTrace.current);

        // 尝试更激进的清理方式：只保留必要的字段
        AppLogHelper.info('🔄 尝试宽松模式解析...');
        jsonData = _parseJsonLenient(cleanedJson);
      }

      AppLogHelper.info('📦 解析到的数据:');
      AppLogHelper.info('   - latestVersion: ${jsonData['latestVersion']}');
      AppLogHelper.info(
          '   - updateLog长度: ${(jsonData['updateLog'] as String? ?? '').length} 字符');
      AppLogHelper.info('   - downloadUrl: ${jsonData['downloadUrl']}');

      final versionInfo = VersionInfo.fromJson(jsonData);

      AppLogHelper.info('✅ VersionInfo对象创建成功:');
      AppLogHelper.info('   - 版本号: ${versionInfo.latestVersion}');
      AppLogHelper.info('   - 下载链接: ${versionInfo.downloadUrl}');

      return versionInfo;
    } on DioException catch (e) {
      AppLogHelper.error('❌ 网络请求失败', e, StackTrace.current);
      AppLogHelper.error(
          '   错误类型: ${e.type}', e.type.toString(), StackTrace.current);
      AppLogHelper.error(
          '   错误消息: ${e.message}', e.message ?? '', StackTrace.current);
      rethrow;
    } catch (e, stack) {
      AppLogHelper.error('❌ 获取服务器版本失败', e, stack);
      rethrow;
    }
  }

  /// 宽松模式JSON解析 - 提取关键字段，忽略格式问题
  Map<String, dynamic> _parseJsonLenient(String dirtyJson) {
    final result = <String, dynamic>{};

    // 使用正则提取最新版本号
    final versionRegex = RegExp(r'"latestVersion"\s*:\s*"([^"]+)"');
    final versionMatch = versionRegex.firstMatch(dirtyJson);
    if (versionMatch != null) {
      result['latestVersion'] = versionMatch.group(1) ?? '';
      AppLogHelper.info('✅ 宽松模式提取到版本号: ${result['latestVersion']}');
    }

    // 使用正则提取下载URL
    final urlRegex = RegExp(r'"downloadUrl"\s*:\s*"([^"]+)"');
    final urlMatch = urlRegex.firstMatch(dirtyJson);
    if (urlMatch != null) {
      result['downloadUrl'] = urlMatch.group(1) ?? '';
      AppLogHelper.info('✅ 宽松模式提取到下载URL: ${result['downloadUrl']}');
    }

    // 提取更新日志（处理多行内容）
    final logRegex =
        RegExp(r'"updateLog"\s*:\s*"((?:[^"\\]|\\.)*)"', dotAll: true);
    final logMatch = logRegex.firstMatch(dirtyJson);
    if (logMatch != null) {
      var logText = logMatch.group(1) ?? '';
      // 反转义
      logText = logText
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\r', '\r')
          .replaceAll(r'\t', '\t')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', '\\');
      result['updateLog'] = logText;
      AppLogHelper.info('✅ 宽松模式提取到更新日志: ${logText.length} 字符');
    }

    if (result.isEmpty) {
      AppLogHelper.error('❌ 宽松模式也无法解析JSON', '无法提取任何有效字段', StackTrace.current);
      throw FormatException('JSON格式严重损坏，无法解析');
    }

    return result;
  }

  Future<bool> isVersionSkipped(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'skipped_version_$version';
    final expiryTimestamp = prefs.getInt(key);
    if (expiryTimestamp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now < expiryTimestamp;
  }

  Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'skipped_version_$version';
    final expiry = DateTime.now()
        .add(Duration(days: _skipDurationDays))
        .millisecondsSinceEpoch;
    await prefs.setInt(key, expiry);
    AppLogHelper.info('⏭️ 用户跳过版本: $version (有效期 $_skipDurationDays 天)');
  }

  Future<UpdateCheckResult> checkForUpdate({bool silent = false}) async {
    AppLogHelper.info('═══════════════════════════════════════');
    AppLogHelper.info('🔄 开始检查更新 (静默模式: $silent)');
    AppLogHelper.info('═══════════════════════════════════════');

    try {
      // 步骤1: 获取本地版本
      AppLogHelper.info('📋 步骤1/4: 获取本地版本...');
      final localVersion = await _getLocalVersion();
      AppLogHelper.info('   本地版本: $localVersion');

      // 步骤2: 获取服务器版本
      AppLogHelper.info('📋 步骤2/4: 获取服务器版本...');
      final serverInfo = await _fetchServerVersion();
      AppLogHelper.info('   服务器版本: ${serverInfo.latestVersion}');

      // 步骤3: 版本比较
      AppLogHelper.info('📋 步骤3/4: 版本比较...');
      final cmp = _compareVersions(serverInfo.latestVersion, localVersion);
      AppLogHelper.info(
          '   比较结果: $cmp (${cmp > 0 ? "需要更新" : cmp == 0 ? "已是最新" : "本地版本更新"})');

      if (cmp <= 0) {
        AppLogHelper.info('✅ 检查完成: 已是最新版本 (或本地版本更新)');
        return UpdateCheckResult(
          result:
              cmp < 0 ? UpdateResult.alreadyLatest : UpdateResult.alreadyLatest,
          localVersion: localVersion,
          versionInfo: serverInfo,
        );
      }

      // 步骤4: 检查是否被跳过
      AppLogHelper.info('📋 步骤4/4: 检查是否被用户跳过...');
      final skipped = await isVersionSkipped(serverInfo.latestVersion);
      if (skipped && silent) {
        AppLogHelper.info('⏭️ 版本已被用户跳过，且为静默模式，不提示');
        return UpdateCheckResult(
          result: UpdateResult.skipped,
          localVersion: localVersion,
          versionInfo: serverInfo,
        );
      }

      AppLogHelper.info(
          '🎉 发现新版本! ${localVersion} → ${serverInfo.latestVersion}');
      return UpdateCheckResult(
        result: UpdateResult.updateAvailable,
        localVersion: localVersion,
        versionInfo: serverInfo,
      );
    } catch (e, stack) {
      AppLogHelper.error('❌ 检查更新失败', e, stack);
      return UpdateCheckResult(
        result: UpdateResult.error,
        errorMessage: e.toString(),
      );
    } finally {
      AppLogHelper.info('═══════════════════════════════════════\n');
    }
  }

  Future<String> downloadUpdate({
    required String url,
    required void Function(double progress) onProgress,
    CancelToken? cancelToken,
  }) async {
    AppLogHelper.info('🚀 开始4线程多线程下载更新包...');
    AppLogHelper.info('📍 下载URL: $url');
    AppLogHelper.info('⚡ 线程数: $_threadCount | 重试次数: $_maxRetriesPerChunk/分片');

    final dir = await getTemporaryDirectory();
    final fileName = url.split('/').last.split('?').first;
    final savePath = '${dir.path}\\$fileName';

    AppLogHelper.info('💾 保存路径: $savePath');

    // 创建专用的 Dio 实例（针对大文件优化）
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: _connectTimeoutSeconds),
      receiveTimeout: Duration(minutes: _receiveTimeoutMinutes),
      sendTimeout: Duration(seconds: _connectTimeoutSeconds),
      receiveDataWhenStatusError: true,
      headers: {
        'User-Agent': 'ChronoTide-Updater/2.0',
        'Connection': 'keep-alive',
        'Keep-Alive': 'timeout=300, max=1000',
      },
    ));

    try {
      // 步骤1：获取文件大小并检查Range支持
      AppLogHelper.info('📡 步骤1/5: 探测服务器支持...');
      final headResponse = await dio.head(url);
      final contentLength = headResponse.headers.value('content-length');

      if (contentLength == null || contentLength!.isEmpty) {
        AppLogHelper.info('⚠️ 服务器未返回Content-Length，降级为单线程下载');
        return await _fallbackSingleThreadDownload(
            dio, url, savePath, onProgress, cancelToken);
      }

      final totalSize = int.parse(contentLength!);
      final acceptRanges =
          headResponse.headers.value('accept-ranges')?.toLowerCase() ?? '';
      final supportsRange = acceptRanges == 'bytes';

      AppLogHelper.info('📊 文件大小: ${_formatBytes(totalSize)}');
      AppLogHelper.info(
          '🔧 Range支持: ${supportsRange ? "✅ 支持（启用多线程）" : "❌ 不支持（降级单线程）"}');

      if (!supportsRange || totalSize < 1024 * 1024) {
        // 文件小于1MB或服务器不支持Range时使用单线程
        AppLogHelper.info('📌 使用单线程模式（小文件或不支持Range）');
        return await _fallbackSingleThreadDownload(
            dio, url, savePath, onProgress, cancelToken);
      }

      // 步骤2：计算分片计划
      AppLogHelper.info('✂️ 步骤2/5: 计算分片计划...');
      final chunkSize = (totalSize / _threadCount).ceil();
      final chunks = <_UpdateChunk>[];

      for (int i = 0; i < _threadCount; i++) {
        final start = i * chunkSize;
        final end =
            (i == _threadCount - 1) ? totalSize - 1 : start + chunkSize - 1;
        chunks.add(_UpdateChunk(
          index: i,
          startByte: start,
          endByte: end,
          tempPath: '$savePath.part_$i.tmp',
        ));
        AppLogHelper.info(
            '   分片$i: ${_formatBytes(start)}-${_formatBytes(end)} (${_formatBytes(end - start + 1)})');
      }

      // 步骤3：并行下载所有分片
      AppLogHelper.info('⚡ 步骤3/5: 启动$_threadCount线程并行下载...');

      // 进度跟踪
      DateTime? lastProgressTime;
      Timer? progressTimer;

      progressTimer = Timer.periodic(Duration(milliseconds: 300), (_) {
        // 计算总进度（每次重新计算，不累加）
        int totalReceived = 0;
        for (final chunk in chunks) {
          totalReceived += chunk.receivedBytes;
        }
        final progress = totalReceived / totalSize;
        onProgress(progress.clamp(0.0, 1.0));

        // 每3秒记录一次日志
        final now = DateTime.now();
        if (lastProgressTime == null ||
            now.difference(lastProgressTime!).inSeconds >= 3) {
          lastProgressTime = now;
          AppLogHelper.info(
              '⬇️ 下载进度: ${(progress * 100).toStringAsFixed(1)}% | '
              '${_formatBytes(totalReceived)}/${_formatBytes(totalSize)} | '
              '速度: ${_calculateSpeed(chunks, totalReceived)}');
        }
      });

      try {
        // 并行执行所有分片下载
        await Future.wait(
          chunks.map((chunk) => _downloadChunkWithRetry(dio, url, chunk)),
        );
      } finally {
        progressTimer?.cancel();
      }

      // 验证所有分片是否完成
      for (final chunk in chunks) {
        if (!chunk.completed) {
          throw Exception('分片${chunk.index}下载不完整');
        }
      }

      AppLogHelper.info('✅ 所有分片下载完成！');

      // 步骤4：合并分片文件
      AppLogHelper.info('📦 步骤4/5: 合并分片文件...');
      onProgress(0.95); // 开始合并

      await _mergeChunks(chunks, savePath, totalSize, (progress) {
        onProgress(progress); // 实时更新合并进度 95% → 100%
      });

      // 步骤5：验证最终文件
      AppLogHelper.info('✅ 步骤5/5: 验证文件完整性...');
      final file = File(savePath);
      final fileSize = await file.length();

      if (fileSize != totalSize) {
        throw Exception(
            '文件大小校验失败: 实际${_formatBytes(fileSize)} ≠ 预期${_formatBytes(totalSize)}');
      }

      AppLogHelper.info('🎉 更新包下载完成！');
      AppLogHelper.info(
          '   文件大小: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB');
      AppLogHelper.info('   保存路径: $savePath');
      onProgress(1.0);

      return savePath;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        AppLogHelper.info('❌ 用户取消下载');
        rethrow;
      }
      AppLogHelper.error('❌ 多线程下载失败', e, StackTrace.current);
      AppLogHelper.info('   错误类型: ${e.type} | ${e.type.toString()}');
      AppLogHelper.info('   错误消息: ${e.message ?? ""}');

      // 尝试降级到单线程重试一次
      AppLogHelper.info('🔄 尝试降级为单线程下载...');
      final fallbackDio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: _connectTimeoutSeconds * 2), // 双倍超时
        receiveTimeout: Duration(minutes: _receiveTimeoutMinutes * 2),
      ));
      return await _fallbackSingleThreadDownload(
          fallbackDio, url, savePath, onProgress, cancelToken);
    } catch (e, stack) {
      AppLogHelper.error('❌ 下载异常', e, stack);
      rethrow;
    }
  }

  /// 单线程降级方案（当多线程不可用时使用）
  Future<String> _fallbackSingleThreadDownload(
    Dio dio,
    String url,
    String savePath,
    void Function(double progress) onProgress,
    CancelToken? cancelToken,
  ) async {
    AppLogHelper.info('🔄 使用单线程降级模式下载...');

    try {
      await dio.download(
        url,
        savePath,
        cancelToken: cancelToken,
        options: Options(receiveTimeout: Duration(minutes: 20)), // 单线程给更长超时
        onReceiveProgress: (received, total) {
          if (total > 0 && total != -1) {
            final progress = received / total;
            onProgress(progress.clamp(0.0, 1.0));
            if ((progress * 100).toInt() % 10 == 0) {
              AppLogHelper.info(
                  '⬇️ [单线程] 下载进度: ${(progress * 100).toInt()}% ($received/$total bytes)');
            }
          }
        },
      );

      final file = File(savePath);
      final fileSize = await file.length();

      AppLogHelper.info('✅ [单线程] 下载完成!');
      AppLogHelper.info(
          '📁 文件大小: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB');
      AppLogHelper.info('📍 文件路径: $savePath');

      return savePath;
    } catch (e, stack) {
      AppLogHelper.error('❌ [单线程] 下载也失败了', e, stack);
      rethrow;
    }
  }

  /// 带智能重试的分片下载
  Future<void> _downloadChunkWithRetry(
    Dio dio,
    String url,
    _UpdateChunk chunk,
  ) async {
    for (int attempt = 0; attempt <= _maxRetriesPerChunk; attempt++) {
      try {
        chunk.cancelToken = CancelToken();

        AppLogHelper.info(
            '🔽 分片${chunk.index}: 开始${attempt == 0 ? "首次" : "第${attempt}次"}下载...');

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

        // 写入临时文件
        final file = File(chunk.tempPath);
        if (await file.exists()) await file.delete();

        final raf = file.openSync(mode: FileMode.write);
        try {
          final buffer = <int>[];
          await for (final data in response.data!.stream) {
            if (chunk.cancelToken?.isCancelled ?? false) break;

            final bytes = data is List<int> ? data : (data as List).cast<int>();
            buffer.addAll(bytes);

            if (buffer.length >= _ioBufferSize) {
              raf.writeFromSync(buffer);
              buffer.clear();
            }
            chunk.receivedBytes += bytes.length;
          }

          // 写入剩余数据
          if (buffer.isNotEmpty) {
            raf.writeFromSync(buffer);
            buffer.clear();
          }

          raf.flushSync();
        } finally {
          raf.closeSync();
        }

        // 标记完成
        if (!(chunk.cancelToken?.isCancelled ?? false)) {
          chunk.completed = true;
          AppLogHelper.info(
              '✅ 分片${chunk.index}完成 | ${_formatBytes(chunk.receivedBytes)}');
        }

        return; // 成功，退出重试循环
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          AppLogHelper.info('⛔ 分片${chunk.index}被用户取消');
          rethrow;
        }

        if (attempt < _maxRetriesPerChunk) {
          // 指数退避策略：2s → 4s → 8s → 16s → 最大30s
          final backoff = min(2000 * pow(1.8, attempt), 30000).toInt();
          AppLogHelper.info(
              '⚠️ 分片${chunk.index}第${attempt + 1}次失败: ${_mapError(e)} | '
              '${backoff ~/ 1000}秒后重试 (${attempt + 1}/$_maxRetriesPerChunk)...');

          await Future.delayed(Duration(milliseconds: backoff));
        } else {
          AppLogHelper.error(
              '❌ 分片${chunk.index}重试耗尽 (${_maxRetriesPerChunk}次): ${_mapError(e)}',
              e,
              StackTrace.current);
          rethrow;
        }
      } catch (e) {
        if (attempt < _maxRetriesPerChunk) {
          final backoff = min(2000 * pow(1.8, attempt), 30000).toInt();
          AppLogHelper.info('⚠️ 分片${chunk.index}异常(${attempt + 1}): $e | '
              '${backoff ~/ 1000}秒后重试...');
          await Future.delayed(Duration(milliseconds: backoff));
        } else {
          AppLogHelper.error(
              '❌ 分片${chunk.index}重试耗尽: $e', e, StackTrace.current);
          rethrow;
        }
      }
    }
  }

  /// 合并所有分片文件（带进度回调）
  Future<void> _mergeChunks(
    List<_UpdateChunk> chunks,
    String finalPath,
    int expectedSize,
    void Function(double progress)? onMergeProgress,
  ) async {
    final outFile = File(finalPath);
    if (await outFile.exists()) await outFile.delete();

    final outRaf = outFile.openSync(mode: FileMode.write);
    int totalWritten = 0;

    try {
      for (int i = 0; i < chunks.length; i++) {
        final chunkFile = File(chunks[i].tempPath);

        if (!await chunkFile.exists()) {
          throw Exception('分片$i临时文件丢失');
        }

        final inRaf = chunkFile.openSync(mode: FileMode.read);
        try {
          final buffer = List<int>.filled(_ioBufferSize, 0);
          int bytesRead;

          while ((bytesRead = inRaf.readIntoSync(buffer)) > 0) {
            outRaf.writeFromSync(buffer.sublist(0, bytesRead));
            totalWritten += bytesRead;
          }
        } finally {
          inRaf.closeSync();
        }

        // 删除已合并的分片临时文件
        await chunkFile.delete();

        // 计算合并进度：95% + (已完成分片数/总分片数 * 5%)
        if (onMergeProgress != null) {
          final mergeProgress = 0.95 + ((i + 1) / chunks.length * 0.05);
          onMergeProgress(mergeProgress.clamp(0.95, 1.0));
        }

        AppLogHelper.info(
            '📦 已合并分片$i/$chunks.length | 累计: ${_formatBytes(totalWritten)}');
      }

      outRaf.flushSync();
      outRaf.closeSync();
    } catch (e) {
      outRaf.closeSync();
      if (await outFile.exists()) await outFile.delete();
      rethrow;
    }

    // 清理可能残留的临时文件
    for (final chunk in chunks) {
      final tmp = File(chunk.tempPath);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }

    AppLogHelper.info('✅ 合并完成 | 最终大小: ${_formatBytes(totalWritten)}');
  }

  /// 计算当前下载速度
  String _calculateSpeed(List<_UpdateChunk> chunks, int totalReceived) {
    // 简化版速度计算（基于总接收字节数）
    // 实际项目中应该用滑动窗口算法
    return '${_formatBytes(totalReceived ~/ 10)}/s (估算)';
  }

  /// 格式化错误信息
  String _mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.sendTimeout:
        return '发送超时';
      case DioExceptionType.receiveTimeout:
        return '接收超时';
      case DioExceptionType.badResponse:
        return 'HTTP ${e.response?.statusCode}';
      case DioExceptionType.connectionError:
        return '连接失败';
      default:
        return e.message ?? '未知错误';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  Future<void> installUpdate(String exePath) async {
    AppLogHelper.info('⚙️ 准备安装更新...');
    AppLogHelper.info('📍 安装程序路径: $exePath');

    final file = File(exePath);
    if (await file.exists()) {
      AppLogHelper.info('✅ 安装程序文件存在，开始清理进程...');

      try {
        AppLogHelper.info('🧹 步骤1/3: 关闭所有对接程序...');
        await ProcessCleanupService.cleanupAll();
        AppLogHelper.info('✅ 所有对接程序已关闭');

        AppLogHelper.info('🚀 步骤2/3: 启动安装程序...');
        await Process.start(exePath, [], runInShell: true);
        AppLogHelper.info('✅ 安装程序已启动');

        await Future.delayed(const Duration(milliseconds: 500));

        AppLogHelper.info('🔒 步骤3/3: 关闭主程序...');
        await Process.run('taskkill', ['/F', '/IM', 'chrono_tide.exe'],
            runInShell: true);

        AppLogHelper.info('✅ 主程序已关闭，安装程序接管更新');
      } catch (e, stack) {
        AppLogHelper.error('❌ 安装过程出错', e, stack);
        rethrow;
      }
    } else {
      AppLogHelper.error('❌ 安装程序文件不存在', exePath, StackTrace.current);
      throw Exception('安装程序文件不存在: $exePath');
    }
  }
}

/// 分片下载数据模型
class _UpdateChunk {
  final int index;
  final int startByte;
  final int endByte;
  final String tempPath;
  int receivedBytes = 0;
  bool completed = false;
  CancelToken? cancelToken;

  _UpdateChunk({
    required this.index,
    required this.startByte,
    required this.endByte,
    required this.tempPath,
  });

  int get totalBytes => endByte - startByte + 1;
}
