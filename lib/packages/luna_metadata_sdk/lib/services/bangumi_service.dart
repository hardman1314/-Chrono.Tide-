import 'dart:convert' as convert;
import 'package:dio/dio.dart';
import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// Bangumi 镜像站服务（匿名版本）
///
/// 特点：
/// 1. 支持多个镜像站点自动切换
/// 2. 无需用户 Token
/// 3. 智能错误处理和重试
/// 4. 自动将图片URL替换为镜像站域名
class BangumiMirrorService implements MetadataSourceService {
  final Dio _dio;
  final List<String> _mirrorURLs;
  int _currentMirrorIndex = 0;

  static const List<String> _defaultMirrors = [
    'https://api.bangumi.one', // 主镜像站
    'https://api.bgm.tv', // 原站
  ];

  BangumiMirrorService({
    Dio? dio,
    List<String>? mirrorURLs,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Accept': 'application/json',
                'Origin': 'https://bangumi.one',
                'Referer': 'https://bangumi.one/',
              },
            )),
        _mirrorURLs = mirrorURLs ?? _defaultMirrors;

  /// 获取当前使用的镜像站点
  String get currentMirror => _mirrorURLs[_currentMirrorIndex];

  /// 获取所有镜像站点
  List<String> get allMirrors => List.from(_mirrorURLs);

  /// 设置自定义镜像站点
  void setCustomMirrors(List<String> mirrors) {
    if (mirrors.isNotEmpty) {
      _mirrorURLs.clear();
      _mirrorURLs.addAll(mirrors);
      _currentMirrorIndex = 0;
    }
  }

  @override
  String get sourceName => 'Bangumi (镜像)';

  @override
  SourceType get sourceType => SourceType.bangumi;

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.head(currentMirror);
      return response.statusCode == 200 ||
          response.statusCode == 404 ||
          response.statusCode == 405;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    if (name.isEmpty) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.bangumi));
    }

    Exception? lastError;

    for (int i = 0; i < _mirrorURLs.length; i++) {
      try {
        final result = await _searchFromCurrentMirror(name);
        return result;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());

        // 切换到下一个镜像
        _currentMirrorIndex = (_currentMirrorIndex + 1) % _mirrorURLs.length;

        // 如果是限流错误，不再尝试其他镜像
        if (e.toString().contains('429') ||
            e.toString().contains('rate limit')) {
          break;
        }
      }
    }

    throw lastError ?? Exception('所有镜像站点均无法访问');
  }

  Future<MetadataResult> _searchFromCurrentMirror(String keyword) async {
    final baseURL = _mirrorURLs[_currentMirrorIndex];
    final url = '$baseURL/v0/search/subjects?limit=5&offset=0';

    try {
      final response = await _dio.post(
        url,
        data: {
          'keyword': keyword,
          'sort': 'rank',
          'filter': {
            'type': [4], // 只搜索游戏类型
            'nsfw': true,
          },
        },
      );

      if (response.statusCode == 200) {
        final data = response.data is String
            ? convert.jsonDecode(response.data)
            : response.data;
        final results = data['data'] as List<dynamic>? ?? [];

        if (results.isEmpty) {
          return MetadataResult(
              game: Game(id: '', name: '', sourceType: SourceType.bangumi));
        }

        return _parseGameResponse(results.first is Map
            ? Map<String, dynamic>.from(results.first)
            : {});
      } else if (response.statusCode == 429) {
        throw Exception('请求过于频繁，请稍后重试');
      } else {
        throw Exception('搜索 API 返回错误: ${response.statusCode}');
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout) {
        throw Exception('搜索连接超时: $baseURL');
      } else if (e.type == DioExceptionType.connectionError) {
        throw Exception('搜索连接失败: $baseURL');
      } else {
        throw Exception('搜索网络错误: ${e.message}');
      }
    }
  }

  MetadataResult _parseGameResponse(Map<String, dynamic> json) {
    // 检查是否为游戏类型（type=4）
    final type = safeInt(json, 'type') ?? 0;
    if (type != 4) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.bangumi));
    }

    // 提取图片（修复相对路径问题）
    final images = safeMap(json, 'images') ?? {};
    String coverUrl = _normalizeImageUrl(safeString(images, 'large') ?? '');
    if (coverUrl.isEmpty) {
      coverUrl = _normalizeImageUrl(safeString(images, 'common') ?? '');
    }

    // 提取名称（优先中文名）
    String name = safeString(json, 'name_cn') ?? '';
    if (name.isEmpty) name = safeString(json, 'name') ?? '';

    // 提取评分
    final ratingData = safeMap(json, 'rating') ?? {};
    double rating = safeDouble(ratingData, 'score') ?? 0.0;

    // 提取标签
    final tags = _extractTags(safeList(json, 'tags'));

    return MetadataResult(
      game: Game(
        id: safeString(json, 'id') ?? '',
        name: name,
        coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
        company: _extractCompany(safeList(json, 'infobox')),
        summary: safeString(json, 'summary'),
        rating: rating,
        releaseDate: safeString(json, 'date')?.trim(),
        sourceType: SourceType.bangumi,
        sourceId: safeString(json, 'id') ?? '',
      ),
      tags: tags,
    );
  }

  String? _extractCompany(dynamic infobox) {
    if (infobox is! List) return null;

    for (final item in infobox) {
      if (item is! Map) continue;

      final itemMap = Map<String, dynamic>.from(item);
      final key = safeString(itemMap, 'key') ?? '';
      if (key.contains('开发商') || key.contains('开发')) {
        final value = itemMap['value'];

        if (value is String) return value;
        if (value is List && value.isNotEmpty) {
          final first = value.first;
          if (first is String) return first;
          if (first is Map)
            return safeString(Map<String, dynamic>.from(first), 'v');
        }
      }
    }

    return null;
  }

  List<TagItem> _extractTags(dynamic tagsData) {
    if (tagsData is! List) return [];

    final rawTags = <Map<String, dynamic>>[];

    for (final tag in tagsData) {
      if (tag is! Map) continue;
      final tagMap = Map<String, dynamic>.from(tag);
      final count = safeInt(tagMap, 'count') ?? 0;
      if (count >= 3) {
        // 降低阈值以适应匿名模式
        rawTags.add(tagMap);
      }
    }

    // 按 count 降序排序
    rawTags.sort((a, b) {
      final countA = safeInt(a, 'count') ?? 0;
      final countB = safeInt(b, 'count') ?? 0;
      return countB.compareTo(countA);
    });

    // 取前10个标签
    final limitedTags = rawTags.take(10).toList();
    if (limitedTags.isEmpty) return [];

    final maxCount = safeInt(limitedTags.first, 'count') ?? 1;

    return limitedTags.map((tag) {
      final count = safeInt(tag, 'count') ?? 0;
      final weight = maxCount > 0 ? count / maxCount : 1.0;

      return TagItem(
        name: safeString(tag, 'name') ?? '',
        source: 'bangumi',
        weight: weight,
        isSpoiler: false,
      );
    }).toList();
  }

  /// 修复图片 URL（处理相对路径 + 域名替换）
  ///
  /// 重要：根据 mirrox 项目镜像映射表，
  /// 所有 bgm.tv 域名必须替换为 bangumi.one 才能在国内访问
  String _normalizeImageUrl(String url) {
    if (url.isEmpty) return '';

    var result = url;

    // 替换所有 bgm.tv 相关域名为镜像站
    result =
        result.replaceAll('https://lain.bgm.tv', 'https://lain.bangumi.one');
    result =
        result.replaceAll('http://lain.bgm.tv', 'https://lain.bangumi.one');
    result = result.replaceAll('//lain.bgm.tv', '//lain.bangumi.one');
    result = result.replaceAll('bgm.tv', 'bangumi.one');

    // 处理协议相对 URL（// 开头）
    if (result.startsWith('//')) {
      return 'https:$result';
    }

    // 处理相对路径（/ 开头）
    if (result.startsWith('/') && !result.startsWith('//')) {
      return 'https://lain.bangumi.one$result';
    }

    return result;
  }
}
