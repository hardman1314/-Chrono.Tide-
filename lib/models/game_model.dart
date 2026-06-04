import 'package:flutter/material.dart';
import '../core/pb_config.dart';
import '../core/backend_config.dart';

class GameModel {
  final String id;
  final String title;
  final String description;
  final String coverUrl;
  final List<String> tags;
  final String downloadUrl;
  final String status;
  final String developer;
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
    final developer = _safeGetString(record, 'Developer');

    debugPrint('      → title: "$title"');
    debugPrint(
        '      → description: ${description.isNotEmpty ? '"${description.length > 30 ? "${description.substring(0, 30)}..." : description}"' : "(空)"}');
    debugPrint('      → coverUrl: ${coverUrl.isNotEmpty ? coverUrl : "(空)"}');
    debugPrint('      → tags: $tags');
    debugPrint(
        '      → downloadUrl: ${downloadUrl.isNotEmpty ? downloadUrl : "(空)"}');
    debugPrint(
        '      → developer: ${developer.isNotEmpty ? developer : "(空)"}');

    return GameModel(
      id: record.id,
      title: title,
      description: description,
      coverUrl: coverUrl,
      tags: tags,
      downloadUrl: downloadUrl,
      status: status,
      developer: developer,
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

  static String _extractCoverUrl(dynamic record) {
    try {
      final cover = record.getStringValue('coverUrl');
      if (cover != null && cover.isNotEmpty) {
        return '${_pbBaseUrl}/api/files/games/${record.id}/$cover';
      }
    } catch (_) {}
    try {
      final cover = record.getStringValue('cover');
      if (cover != null && cover.isNotEmpty) {
        return '${_pbBaseUrl}/api/files/games/${record.id}/$cover';
      }
    } catch (_) {}
    return '';
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

  /// 从 BackendConfig 获取 PocketBase 基础 URL
  static String get _pbBaseUrl => BackendConfig.pbBaseUrl;

  bool get hasCover => coverUrl.isNotEmpty;

  GameModel copyWith({
    String? id,
    String? title,
    String? description,
    String? coverUrl,
    List<String>? tags,
    String? downloadUrl,
    String? status,
    String? developer,
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
      created: created ?? this.created,
      updated: updated ?? this.updated,
    );
  }
}
