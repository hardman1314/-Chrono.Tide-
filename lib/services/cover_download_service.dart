import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/portable_image_cache_manager.dart';
import 'nsfw/nsfw_detection_service.dart';

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

  /// 进程内单调递增的下载 nonce。
  ///
  /// 用于保证不同下载任务在并发场景下生成不同的文件名，
  /// 避免「同一毫秒内多个任务用 DateTime.now().millisecondsSinceEpoch
  /// 生成同名文件 → 后写覆盖前写」的封面错乱问题。
  /// （修复 2026-08：批量/智能导入并发封面下载错乱 bug）
  static int _downloadNonce = 0;

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
  /// [fileName] 保存文件名（不含 nonce 后缀）。为空时使用 'cover.<ext>'。
  ///   最终文件名 = fileName + nonce + ext —— **即使传入了 fileName 也会
  ///   自动追加 nonce**，因为并发场景下仅靠 fileName 仍可能冲突
  ///   （修复 2026-08：批量/智能导入并发封面下载错乱 bug）
  /// [referer] HTTP Referer 头，默认 'https://bgm.tv/'（Bangumi 必须）
  /// [userAgent] HTTP User-Agent 头，默认使用内置 UA
  /// [minAspectRatio] 最小宽高比（宽/高），非空时下载后解码校验——
  ///   实际宽高比不达标（如竖版 CD 图/论坛头图冒充横幅）则**删除落盘
  ///   文件并返回 null**。2026-10-05 横幅修复的兜底闸：源数据缺尺寸
  ///   元数据时（KunGal banner_url / 无尺寸 covers 项），真伪在此裁决。
  ///   解码失败视为损坏文件，同样拒收。
  ///
  /// 返回保存的文件名（如 'cover_1.jpg'）成功，失败返回 null
  Future<String?> downloadCover({
    required String targetDir,
    required String coverUrl,
    String? fileName,
    String? referer,
    String? userAgent,
    double? minAspectRatio,
  }) async {
    if (coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return null;
    }

    final ext = detectExtension(coverUrl);

    // 取下一个 nonce（单调递增，进程内保证唯一）
    final nonce = ++_downloadNonce;

    // 拆解 fileName 为「基础名 + 扩展名」：用户可能传 'batch_cover_12345.jpg'，
    // 我们需要切掉扩展名以便插入 nonce。如果用户没传 fileName，则基础名为 'cover'。
    String baseName;
    if (fileName != null && fileName.isNotEmpty) {
      final dotIdx = fileName.lastIndexOf('.');
      baseName = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
    } else {
      baseName = 'cover';
    }

    // 清理基础名中可能存在的尾随 '_数字'（应对旧代码的 ms 后缀残留），
    // 避免出现 'cover_12345_7.jpg' 这种可读性差的文件名
    baseName = baseName.replaceAll(RegExp(r'_\d{10,}$'), '');

    final savedName = '${baseName}_$nonce.$ext';
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
      if (minAspectRatio != null &&
          !(await _checkAspectRatio(File(destPath), minAspectRatio))) {
        debugPrint('[COVER-DL] ⛔ 横幅宽高比不达标（缓存路径），拒收: $coverUrl');
        _deleteQuietly(File(destPath));
        return null;
      }
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
          // ★ 2026-10-05 横幅宽高比校验：不达标即拒收（删文件 + 返回 null）
          if (minAspectRatio != null &&
              !(await _checkAspectRatio(File(destPath), minAspectRatio))) {
            debugPrint(
                '[COVER-DL] ⛔ 横幅宽高比不达标，拒收: $coverUrl (要求 ≥$minAspectRatio)');
            _deleteQuietly(File(destPath));
            return null;
          }
          // NSFW：新落盘封面自动入检测队列（总开关裁决在服务内部，
          // aliasUrl 使 URL 键与文件键同时可命中，见方案 §4.4 双键规则）
          NsfwDetectionService.instance
              .enqueueFile(destPath, aliasUrl: coverUrl);
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

  /// 横幅下载便捷入口（2026-10-05）：等价 downloadCover(fileName: 'banner')
  /// + 宽高比校验 ≥ [minAspectRatio]（默认 1.15，覆盖 3:2≈1.5 与
  /// Steam 头图 460:215≈2.14 等常见横幅；低于 1.15 视为假横幅拒收）。
  Future<String?> downloadBanner({
    required String targetDir,
    required String bannerUrl,
    String? referer,
    String? userAgent,
    double minAspectRatio = 1.15,
  }) {
    return downloadCover(
      targetDir: targetDir,
      coverUrl: bannerUrl,
      fileName: 'banner',
      referer: referer,
      userAgent: userAgent,
      minAspectRatio: minAspectRatio,
    );
  }

  /// 校验图片实际宽高比 ≥ [min]（用 dart:ui 解码头帧，拒绝损坏文件）
  static Future<bool> _checkAspectRatio(File file, double min) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (h <= 0) return false;
      return w / h >= min;
    } catch (e) {
      debugPrint('[COVER-DL] ⛔ 图片解码失败（视为损坏拒收）: $e');
      return false;
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
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
        // NSFW：缓存复制落盘同样入检测队列（与网络下载路径等价）
        NsfwDetectionService.instance.enqueueFile(destPath, aliasUrl: url);
        return true;
      }
    } catch (e) {
      debugPrint('[COVER-DL] ⚠️ 缓存读取失败，回退到网络下载: $e');
    }
    return false;
  }
}
