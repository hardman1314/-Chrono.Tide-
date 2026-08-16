import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/portable_image_cache_manager.dart';

/// 统一封面下载服务
///
/// Phase 3.1: 合并原有 5 处分散的封面下载实现：
/// - game_data_format._downloadAndSaveCover (HttpClient + 缓存优先)
/// - auto_import_pipeline._downloadCoverToMetaDir (HttpClient, 无缓存, 不写 game.json)
/// - game_detail_dialog._downloadCoverFromUrl (Dio, 无缓存, 硬编码 png)
/// - batch_import_controller.downloadCover (Dio, 无缓存, 临时文件)
/// - join_controller.downloadAndSetCover (Dio + 缓存优先 + UA/Referer)
///
/// 统一能力：
/// 1. 缓存优先：先查 CachedNetworkImage 的磁盘缓存，命中则直接复制，省流量
/// 2. 标准请求头：默认 User-Agent + Referer(https://bgm.tv/)，避免 Bangumi 403
/// 3. 扩展名检测：从 URL 路径识别 jpg/jpeg/png/gif/webp/bmp
/// 4. 失败重试：最多 3 次尝试（含首次），指数退避 1s/2s，仅对瞬态错误重试
/// 5. 超时控制：连接 15s，接收 30s
///
/// 设计原则：
/// - 服务只负责"下载到文件"，不负责 game.json 写入（由调用方决定持久化策略）
/// - 返回保存的文件名（如 'cover.jpg'），失败返回 null
/// - 单例共享 Dio 连接池，减少握手开销
class CoverDownloadService {
  CoverDownloadService._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    ));
  }

  static final CoverDownloadService instance = CoverDownloadService._();

  late final Dio _dio;

  /// 最大尝试次数（含首次）
  static const int _maxAttempts = 3;

  /// 退避基础间隔
  static const Duration _baseBackoff = Duration(seconds: 1);

  /// 从 URL 检测图片扩展名
  ///
  /// 返回 jpg/jpeg/png/gif/webp/bmp 之一，无法识别时返回 'jpg'
  static String detectExtension(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.path.contains('.')) {
      final ext = uri.path.split('.').last.toLowerCase();
      if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
        return ext;
      }
    }
    return 'jpg';
  }

  /// 下载封面到指定目录
  ///
  /// [targetDir] 目标目录（不存在则创建）
  /// [coverUrl] 封面图片 URL
  /// [fileName] 保存文件名，为空时使用 'cover.<ext>'
  /// [referer] HTTP Referer 头，默认 'https://bgm.tv/'（Bangumi 必须）
  /// [userAgent] HTTP User-Agent 头，默认使用内置 UA
  ///
  /// 返回保存的文件名（如 'cover.jpg'）成功，失败返回 null
  Future<String?> downloadCover({
    required String targetDir,
    required String coverUrl,
    String? fileName,
    String? referer,
    String? userAgent,
  }) async {
    if (coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return null;
    }

    final ext = detectExtension(coverUrl);
    final savedName = fileName ?? 'cover.$ext';
    final destPath = '$targetDir/$savedName';

    // 确保目标目录存在
    try {
      final dir = Directory(targetDir);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('[COVER-DL] ⚠️ 创建目录失败: $targetDir | $e');
      return null;
    }

    // ===== 1. 缓存优先：从 CachedNetworkImage 磁盘缓存复制 =====
    if (await _tryCopyFromCache(coverUrl, destPath)) {
      return savedName;
    }

    // ===== 2. 网络下载 + 重试 =====
    final headers = <String, String>{
      'Referer': referer ?? 'https://bgm.tv/',
    };
    if (userAgent != null && userAgent.isNotEmpty) {
      headers['User-Agent'] = userAgent;
    }

    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final response = await _dio.get<List<int>>(
          coverUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: headers,
          ),
        );

        if (response.statusCode == 200 &&
            response.data != null &&
            response.data!.isNotEmpty) {
          await File(destPath).writeAsBytes(response.data!);
          debugPrint(
              '[COVER-DL] ✅ 封面已下载: $destPath (${(response.data!.length / 1024).toStringAsFixed(1)}KB) [attempt $attempt]');
          return savedName;
        }

        // 4xx（非 429）不重试
        final code = response.statusCode ?? 0;
        if (code >= 400 && code < 500 && code != 429) {
          debugPrint('[COVER-DL] ⚠️ HTTP $code，不重试: $coverUrl');
          return null;
        }
        // 5xx / 429 落入重试
        debugPrint('[COVER-DL] ⚠️ HTTP $code，准备重试 ($attempt/$_maxAttempts)');
      } on DioException catch (e) {
        // 瞬态错误：超时 / 连接失败 → 重试
        final transient = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.sendTimeout;
        if (!transient || attempt == _maxAttempts) {
          debugPrint('[COVER-DL] ❌ 下载失败 (${e.type}): $coverUrl | ${e.message}');
          return null;
        }
        debugPrint(
            '[COVER-DL] ⚠️ 瞬态错误 (${e.type})，准备重试 ($attempt/$_maxAttempts)');
      } catch (e) {
        debugPrint('[COVER-DL] ❌ 下载异常: $coverUrl | $e');
        return null;
      }

      // 指数退避：1s, 2s
      if (attempt < _maxAttempts) {
        final backoff = _baseBackoff * (1 << (attempt - 1));
        await Future.delayed(backoff);
      }
    }

    return null;
  }

  /// 尝试从 CachedNetworkImage 的磁盘缓存复制到目标路径
  ///
  /// 命中缓存可省去网络请求，复用 UI 已下载的图片
  Future<bool> _tryCopyFromCache(String url, String destPath) async {
    try {
      final cachedFile =
          await PortableImageCacheManager().getFileFromCache(url);
      if (cachedFile != null && cachedFile.file.existsSync()) {
        await cachedFile.file.copy(destPath);
        debugPrint(
            '[COVER-DL] ✅ 封面从缓存复制: $destPath (${(cachedFile.file.lengthSync() / 1024).toStringAsFixed(1)}KB)');
        return true;
      }
    } catch (e) {
      debugPrint('[COVER-DL] ⚠️ 缓存读取失败，回退到网络下载: $e');
    }
    return false;
  }
}
