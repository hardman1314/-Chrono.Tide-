import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// 后端服务可用性检测与配置
///
/// 开源版本中，所有依赖私有后端的功能（登录、发现页、下载等）
/// 都会根据此配置决定是否启用。
///
/// 当后端不可用时，软件会自动跳过登录，直接进入主界面，
/// 仅启用本地功能（游戏库管理、手动入库、存档备份等）。
class BackendConfig {
  BackendConfig._();

  // ─── PocketBase 服务器地址 ───
  // 开源版本：留空，表示未配置私有后端
  // 正式版本：填入实际的服务器地址，如 'http://your-server:8090'
  static const String pbBaseUrl = '';

  // ─── OpenList 配置 ───
  // 开源版本：留空，表示未配置
  static const String openlistConfigRecordId = '';
  static const String openlistAdminUsername = '';
  static const String openlistAdminPassword = '';

  // ─── 解压默认密码 ───
  // 开源版本：留空，表示未配置
  static const String defaultExtractionPassword = '';

  // ─── 后端可用性状态 ───
  static bool _isBackendAvailable = false;
  static bool _hasChecked = false;

  /// 后端是否可用
  static bool get isBackendAvailable => _isBackendAvailable;

  /// 是否已完成检测
  static bool get hasChecked => _hasChecked;

  /// 提示信息：后端不可用时显示
  static const String unavailableMessage =
      '如果要正常使用请使用作者开放的正式版软件。\n如果开发者想要开发，请自行参考后端开发报告。';

  /// 检测后端服务是否可用
  ///
  /// 尝试连接 PocketBase 健康检查接口，
  /// 成功则标记为可用，失败则标记为不可用。
  static Future<bool> checkAvailability() async {
    if (_hasChecked) return _isBackendAvailable;

    // 如果没有配置服务器地址，直接标记为不可用
    if (pbBaseUrl.isEmpty) {
      debugPrint('[BackendConfig] 未配置服务器地址，后端功能已禁用');
      _isBackendAvailable = false;
      _hasChecked = true;
      return false;
    }

    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 5);
      dio.options.receiveTimeout = const Duration(seconds: 5);

      final response = await dio.get('$pbBaseUrl/api/health');

      if (response.statusCode == 200) {
        debugPrint('[BackendConfig] 后端服务可用');
        _isBackendAvailable = true;
      } else {
        debugPrint('[BackendConfig] 后端服务响应异常: ${response.statusCode}');
        _isBackendAvailable = false;
      }
    } catch (e) {
      debugPrint('[BackendConfig] 后端服务不可用: $e');
      _isBackendAvailable = false;
    }

    _hasChecked = true;
    return _isBackendAvailable;
  }

  /// 重置检测状态（用于重新检测）
  static void reset() {
    _isBackendAvailable = false;
    _hasChecked = false;
  }

  /// 是否配置了 OpenList
  static bool get isOpenlistConfigured =>
      openlistConfigRecordId.isNotEmpty &&
      openlistAdminUsername.isNotEmpty &&
      openlistAdminPassword.isNotEmpty;
}
