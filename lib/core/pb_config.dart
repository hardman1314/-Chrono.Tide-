import 'package:pocketbase/pocketbase.dart';
import 'package:flutter/material.dart';
import 'backend_config.dart';

class PBConfig {
  PBConfig._();

  /// PocketBase 服务器地址
  /// 开源版本从 BackendConfig 读取，未配置则为空字符串
  static final String _baseUrl = BackendConfig.pbBaseUrl;

  static final PocketBase instance = PocketBase(_baseUrl);

  static PocketBase get pb => instance;

  static String get token => pb.authStore.token;

  static bool get isLoggedIn => pb.authStore.isValid;
}
