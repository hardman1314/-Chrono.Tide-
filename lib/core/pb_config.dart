import 'package:pocketbase/pocketbase.dart';
import 'package:flutter/material.dart';

class PBConfig {
  PBConfig._();

  static const String _baseUrl = 'http://117.72.115.30:8090';

  static final PocketBase instance = PocketBase(_baseUrl);

  static PocketBase get pb => instance;

  /// PocketBase 服务器基础 URL（公开访问，用于拼接文件URL等）
  static String get baseUrl => _baseUrl;

  static String get token => pb.authStore.token;

  static bool get isLoggedIn => pb.authStore.isValid;
}
