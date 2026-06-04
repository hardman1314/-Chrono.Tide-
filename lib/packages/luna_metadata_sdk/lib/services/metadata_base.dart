import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/game.dart';
import '../models/tags.dart';

String? safeString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is String) return value.isNotEmpty ? value : null;
  if (value is num) return value.toString();
  return value.toString();
}

double? safeDouble(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? safeInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Map<String, dynamic>? safeMap(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<dynamic>? safeList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is List) return value;
  return null;
}

bool? safeBool(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  if (value is num) return value != 0;
  return null;
}

abstract class MetadataSourceService {
  Future<MetadataResult> fetchByName(String name);
  Future<bool> testConnection();
  SourceType get sourceType;
  String get sourceName;
}
