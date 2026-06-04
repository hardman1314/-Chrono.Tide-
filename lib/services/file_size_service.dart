import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'openlist_service.dart';

class FileSizeInfo {
  final int sizeBytes;
  final DateTime fetchedAt;
  final String? sourceUrl;

  const FileSizeInfo({
    required this.sizeBytes,
    required this.fetchedAt,
    this.sourceUrl,
  });

  String get formatted {
    if (sizeBytes <= 0) return '未知';
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  bool get isExpired {
    return DateTime.now().difference(fetchedAt).inDays > 7;
  }

  Map<String, dynamic> toJson() => {
        'size_bytes': sizeBytes,
        'fetched_at': fetchedAt.toIso8601String(),
        'source_url': sourceUrl,
      };

  factory FileSizeInfo.fromJson(Map<String, dynamic> json) => FileSizeInfo(
        sizeBytes: json['size_bytes'] ?? 0,
        fetchedAt: DateTime.parse(json['fetched_at']),
        sourceUrl: json['source_url'],
      );
}

class FileSizePrefetchService {
  static final FileSizePrefetchService _instance =
      FileSizePrefetchService._internal();
  static FileSizePrefetchService get instance => _instance;

  FileSizePrefetchService._internal();

  final Map<String, FileSizeInfo> _memoryCache = {};
  static const Duration _cacheTTL = Duration(days: 7);

  Future<FileSizeInfo?> prefetchSize(String gameId, String gamePath) async {
    if (_memoryCache.containsKey(gameId)) {
      final cached = _memoryCache[gameId]!;
      if (!cached.isExpired) {
        debugPrint('[SIZE-PREFETCH] ✅ 命中内存缓存: $gameId');
        return cached;
      } else {
        _memoryCache.remove(gameId);
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('file_size_$gameId');

      if (cachedJson != null) {
        final data = jsonDecode(cachedJson);
        final info = FileSizeInfo.fromJson(data);

        if (!info.isExpired) {
          _memoryCache[gameId] = info;
          debugPrint('[SIZE-PREFETCH] ✅ 命中磁盘缓存: $gameId');
          return info;
        } else {
          await prefs.remove('file_size_$gameId');
        }
      }
    } catch (e) {
      debugPrint('[SIZE-PREFETCH] ⚠️ 缓存读取失败: $e');
    }

    try {
      debugPrint('[SIZE-PREFETCH] 🔄 开始网络获取 | gameId=$gameId | path=$gamePath');

      if (!OpenListService.isRunning) {
        debugPrint('[SIZE-PREFETCH] ⚠️ OpenList未运行，跳过');
        return null;
      }

      final directUrl = await OpenListService.getGameDownloadUrl(gamePath);

      if (directUrl == null || directUrl.isEmpty) {
        debugPrint('[SIZE-PREFETCH] ❌ 无法获取下载直链');
        return null;
      }

      debugPrint('[SIZE-PREFETCH] ✅ 获取到直链 (${directUrl.length}字符)');

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        followRedirects: true,
        validateStatus: (status) => status != null && status < 500,
      ));

      final headResponse = await dio.head(directUrl);
      final contentLengthStr = headResponse.headers.value('content-length');

      if (contentLengthStr == null || contentLengthStr.isEmpty) {
        debugPrint('[SIZE-PREFETCH] ⚠️ 服务器未返回Content-Length');
        return null;
      }

      final sizeBytes = int.parse(contentLengthStr);

      if (sizeBytes <= 0) {
        debugPrint('[SIZE-PREFETCH] ❌ 文件大小无效: $sizeBytes');
        return null;
      }

      final info = FileSizeInfo(
        sizeBytes: sizeBytes,
        fetchedAt: DateTime.now(),
        sourceUrl: directUrl,
      );

      _memoryCache[gameId] = info;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('file_size_$gameId', jsonEncode(info.toJson()));
        debugPrint('[SIZE-PREFETCH] 💾 已持久化到磁盘');
      } catch (e) {
        debugPrint('[SIZE-PREFETCH] ⚠️ 持久化失败（不影响使用）: $e');
      }

      debugPrint('[SIZE-PREFETCH] ✅ 获取成功: $gameId | ${info.formatted}');

      return info;
    } catch (e) {
      debugPrint('[SIZE-PREFETCH] ❌ 网络获取失败: $e');
      return null;
    }
  }

  Future<void> clearCache(String gameId) async {
    _memoryCache.remove(gameId);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('file_size_$gameId');
    } catch (e) {
      debugPrint('[SIZE-CACHE] 清除失败: $e');
    }
  }

  Future<void> clearAllCache() async {
    _memoryCache.clear();

    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('file_size_'));
      for (final key in keys) {
        await prefs.remove(key);
      }
      debugPrint('[SIZE-CACHE] ✅ 已清除所有缓存');
    } catch (e) {
      debugPrint('[SIZE-CACHE] 清除失败: $e');
    }
  }

  Future<int?> getCachedSizeOnly(String gameId) async {
    if (_memoryCache.containsKey(gameId)) {
      final cached = _memoryCache[gameId]!;
      if (!cached.isExpired) return cached.sizeBytes;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('file_size_$gameId');

      if (cachedJson != null) {
        final data = jsonDecode(cachedJson);
        final info = FileSizeInfo.fromJson(data);

        if (!info.isExpired) {
          _memoryCache[gameId] = info;
          return info.sizeBytes;
        }
      }
    } catch (e) {}

    return null;
  }

  static Future<int> calculateDirectorySize(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    int totalSize = 0;

    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            totalSize += stat.size;
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[SIZE-CALC] 计算目录大小失败: $e');
    }

    return totalSize;
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
