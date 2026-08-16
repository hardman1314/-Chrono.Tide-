import 'package:flutter/material.dart';
import '../core/pb_config.dart';

class GameModel {
  final String id;
  final String title;
  final String description;
  final String coverUrl;
  final List<String> tags;
  final String downloadUrl;
  final String status;
  final String developer;
  final List<String> screenshotUrls; // PB screenshots 字段（多文件）
  final DateTime created;
  final DateTime updated;

  const GameModel({
    required this.id,
    required this.title,
    this.description = '',
    this.coverUrl = '',
    this.tags = const [],
    this.downloadUrl = '',
    this.status = '',
    this.developer = '',
    this.screenshotUrls = const [],
    required this.created,
    required this.updated,
  });

  factory GameModel.fromPBRecord(dynamic record) {
    debugPrint('   🔍 解析游戏记录: id=${record.id}');

    final title = _safeGetString(record, 'title');
    final description = _safeGetString(record, 'description');
    final coverUrl = _extractCoverUrl(record);
    final tags = _parseTags(record);
    final downloadUrl = _safeGetString(record, 'downloadUrl');
    final status = _safeGetString(record, 'status');
    final developer = _safeGetStringFallback(record, ['developer', 'Developer']);
    final screenshotUrls = _extractScreenshotUrls(record);

    debugPrint('      → title: "$title"');
    debugPrint(
        '      → description: ${description.isNotEmpty ? '"${description.length > 30 ? "${description.substring(0, 30)}..." : description}"' : "(空)"}');
    debugPrint('      → coverUrl: ${coverUrl.isNotEmpty ? coverUrl : "(空)"}');
    debugPrint('      → tags: $tags');
    debugPrint(
        '      → downloadUrl: ${downloadUrl.isNotEmpty ? downloadUrl : "(空)"}');
    debugPrint(
        '      → developer: ${developer.isNotEmpty ? developer : "(空)"}');
    debugPrint(
        '      → screenshotUrls: ${screenshotUrls.isNotEmpty ? "${screenshotUrls.length}张" : "(空)"}');

    return GameModel(
      id: record.id,
      title: title,
      description: description,
      coverUrl: coverUrl,
      tags: tags,
      downloadUrl: downloadUrl,
      status: status,
      developer: developer,
      screenshotUrls: screenshotUrls,
      created: DateTime.tryParse(record.created) ?? DateTime.now(),
      updated: DateTime.tryParse(record.updated) ?? DateTime.now(),
    );
  }

  static String _safeGetString(dynamic record, String field) {
    try {
      return record.getStringValue(field);
    } catch (_) {
      return '';
    }
  }

  /// 按优先级依次尝试多个字段名，返回第一个非空值
  /// 用于兼容 PB 字段命名变更（如 Developer → developer）
  static String _safeGetStringFallback(dynamic record, List<String> fields) {
    for (final field in fields) {
      final value = _safeGetString(record, field);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  /// 从 PB record 提取封面 URL
  /// 优先尝试 'cover'（标准命名），再回退 'coverUrl'（旧命名）
  static String _extractCoverUrl(dynamic record) {
    for (final field in ['cover', 'coverUrl']) {
      try {
        final value = record.getStringValue(field);
        if (value != null && value.isNotEmpty) {
          return '$_pbBaseUrl/api/files/games/${record.id}/$value';
        }
      } catch (_) {}
    }
    return '';
  }

  /// 从 PB record 的 screenshots 多文件字段提取完整 URL 列表
  static List<String> _extractScreenshotUrls(dynamic record) {
    final urls = <String>[];
    try {
      // PB 多文件字段：getListValue 返回文件名列表
      final files = record.getListValue('screenshots');
      if (files != null && files is List && files.isNotEmpty) {
        for (final file in files) {
          final fileName = file.toString();
          if (fileName.isNotEmpty) {
            urls.add('$_pbBaseUrl/api/files/games/${record.id}/$fileName');
          }
        }
      }
    } catch (e) {
      debugPrint('[MODEL] ⚠️ screenshots字段解析异常: $e');
    }

    if (urls.isNotEmpty) {
      debugPrint('[MODEL] ✅ 截图URL解析成功: ${urls.length}张');
    }
    return urls;
  }

  static List<String> _parseTags(dynamic record) {
    debugPrint('[MODEL]   解析tags字段...');

    try {
      final rawTags = record.getListValue('tags');
      debugPrint(
          '[MODEL]     getListValue结果: $rawTags (类型: ${rawTags.runtimeType})');

      if (rawTags != null && rawTags is List && rawTags.isNotEmpty) {
        final result = List<String>.from(rawTags.map((t) => t.toString()));
        debugPrint('[MODEL]   ✅ tags解析成功 (List<String>.from): $result');
        return result;
      }
    } catch (e, stackTrace) {
      debugPrint('[MODEL]     ⚠️ getListValue异常: $e');
      debugPrint('[MODEL]     堆栈: $stackTrace');
    }

    try {
      final tagsStr = record.getStringValue('tags');
      debugPrint('[MODEL]     getStringValue结果: "$tagsStr"');
      if (tagsStr != null && tagsStr.isNotEmpty) {
        final result = tagsStr
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        debugPrint('[MODEL]   ✅ tags(字符串)解析成功: $result');
        return result;
      }
    } catch (e) {
      debugPrint('[MODEL]     ⚠️ getStringValue失败: $e');
    }

    debugPrint('[MODEL]   ⚠️ tags字段为空或不存在，返回空数组');
    return [];
  }

  static String get _pbBaseUrl => PBConfig.baseUrl;

  bool get hasCover => coverUrl.isNotEmpty;
  bool get hasScreenshots => screenshotUrls.isNotEmpty;

  GameModel copyWith({
    String? id,
    String? title,
    String? description,
    String? coverUrl,
    List<String>? tags,
    String? downloadUrl,
    String? status,
    String? developer,
    List<String>? screenshotUrls,
    DateTime? created,
    DateTime? updated,
  }) {
    return GameModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      tags: tags ?? this.tags,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      status: status ?? this.status,
      developer: developer ?? this.developer,
      screenshotUrls: screenshotUrls ?? this.screenshotUrls,
      created: created ?? this.created,
      updated: updated ?? this.updated,
    );
  }
}
