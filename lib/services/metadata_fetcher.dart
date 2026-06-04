import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

class MetadataFetcher {
  static String? _proxyUrl;
  static Dio? _dio;
  static final Map<String, Map<String, dynamic>> _cache = {};
  static const Duration _cacheTtl = Duration(hours: 24);

  static Future<void> init() async {
    await _loadProxySettings();
    _initDio();
  }

  static Future<void> _loadProxySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _proxyUrl = prefs.getString('proxy_url');
      if (_proxyUrl != null && _proxyUrl!.isNotEmpty) {
        debugPrint('[MetadataFetcher] ✅ 已加载代理: $_proxyUrl');
      }
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载代理设置失败: $e');
    }
  }

  static void _initDio() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
      },
    ));

    if (_proxyUrl != null && _proxyUrl!.isNotEmpty) {
      (_dio!.httpClientAdapter as DefaultHttpClientAdapter).onHttpClientCreate =
          (client) {
        client.findProxy = (uri) => 'PROXY $_proxyUrl';
        return client;
      };
    }
  }

  static Future<void> updateProxy(String? proxyUrl) async {
    _proxyUrl = proxyUrl;

    final prefs = await SharedPreferences.getInstance();
    if (proxyUrl != null && proxyUrl.isNotEmpty) {
      await prefs.setString('proxy_url', proxyUrl);
      debugPrint('[MetadataFetcher] ✅ 代理已保存: $proxyUrl');
    } else {
      await prefs.remove('proxy_url');
      debugPrint('[MetadataFetcher] ✅ 代理已清除');
    }

    _initDio();
  }

  static Future<List<Map<String, dynamic>>> fetchGame(
    String gameName, {
    SourceType? preferredSource,
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) {
      return [];
    }

    final cacheKey = '${preferredSource?.name ?? "all"}:$gameName';

    if (useCache && _cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      final cachedAt = DateTime.parse(cached['_cached_at']);
      if (DateTime.now().difference(cachedAt) < _cacheTtl) {
        debugPrint('[MetadataFetcher] 📦 使用缓存: $gameName');
        return [Map<String, dynamic>.from(cached)..remove('_cached_at')];
      }
      _cache.remove(cacheKey);
    }

    try {
      final sources =
          preferredSource != null ? [preferredSource] : _getDefaultSources();

      final results = <Map<String, dynamic>>[];

      for (final source in sources) {
        try {
          final service = _createService(source);
          final result = await service.fetchByName(gameName);

          if (result.isValid) {
            final uiFormat = _convertToLegacyFormat(result);
            results.add(uiFormat);

            if (preferredSource != null) {
              _cache[cacheKey] = {
                ...uiFormat,
                '_cached_at': DateTime.now().toIso8601String(),
              };
            }
          }
        } catch (e) {
          debugPrint('[MetadataFetcher] [$source] 查询失败: $e');
        }
      }

      if (results.isNotEmpty && preferredSource == null) {
        _cache[cacheKey] = {
          ...results.first,
          '_cached_at': DateTime.now().toIso8601String(),
        };
      }

      debugPrint('[MetadataFetcher] ✅ 查询完成: $gameName → ${results.length} 条结果');
      return results;
    } catch (e) {
      debugPrint('[MetadataFetcher] ❌ 总体错误: $e');
      return [];
    }
  }

  static MetadataSourceService _createService(SourceType sourceType) {
    switch (sourceType) {
      case SourceType.bangumi:
        return BangumiMirrorService(dio: _dio);
      case SourceType.vndb:
        return VNDBService(dio: _dio);
      case SourceType.steam:
        return SteamService(dio: _dio);
      case SourceType.ymgal:
        return YmgalService(dio: _dio);
      case SourceType.dlsite:
        return DLsiteService(dio: _dio);
      case SourceType.erogamescape:
        return ErogameScapeService(dio: _dio);
      default:
        throw ArgumentError('不支持的数据源: $sourceType');
    }
  }

  static List<SourceType> _getDefaultSources() => [
        SourceType.vndb,
        SourceType.bangumi,
        SourceType.ymgal,
        SourceType.steam,
      ];

  static Map<String, dynamic> _convertToLegacyFormat(MetadataResult result) {
    final game = result.game;

    return {
      'game_name': game.name,
      'platform': game.sourceType.name,
      'platform_id': game.sourceId ?? game.id,
      'tags': result.tags.map((tag) => tag.name).toList(),
      'summary': game.summary ?? '',
      'cover_url': game.coverUrl ?? '',
      'release_date': game.releaseDate ?? '',
      'developer': game.company ?? '',
    };
  }

  static Future<bool> testConnection(SourceType source) async {
    try {
      final service = _createService(source);
      return await service.testConnection();
    } catch (e) {
      debugPrint('[MetadataFetcher] 连接测试失败 [$source]: $e');
      return false;
    }
  }

  static Future<Map<SourceType, bool>> testAllConnections() async {
    final sources = SourceType.values.where((s) => s != SourceType.local);
    final results = <SourceType, bool>{};

    for (final source in sources) {
      results[source] = await testConnection(source);
    }

    return results;
  }

  static void clearCache() {
    _cache.clear();
    debugPrint('[MetadataFetcher] 🗑️ 缓存已清空');
  }

  static String? get currentProxy => _proxyUrl;
}
