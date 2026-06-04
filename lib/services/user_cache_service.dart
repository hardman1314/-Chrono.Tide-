import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../core/pb_config.dart';

class UserCacheService {
  static const String _keyUserId = 'user_id';
  static const String _keyUserName = 'user_name';
  static const String _keyUserBio = 'user_bio';
  static const String _keyUserAvatarBase64 = 'user_avatar_base64';

  static bool _isInitialized = false;
  static late SharedPreferences _prefs;

  static bool get isInitialized => _isInitialized;

  static Future<void> init() async {
    if (_isInitialized) return;

    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;

    debugPrint('[USER-CACHE] ✅ 缓存服务初始化完成');
  }

  static Future<bool> saveUserInfo({
    required String userId,
    required String name,
    String bio = '',
    String? avatarUrl,
  }) async {
    if (!_isInitialized) await init();

    try {
      await _prefs.setString(_keyUserId, userId);
      await _prefs.setString(_keyUserName, name);
      await _prefs.setString(_keyUserBio, bio);

      debugPrint('[USER-CACHE] 💾 已保存用户基本信息：');
      debugPrint('   ID: $userId');
      debugPrint('   昵称: $name');
      debugPrint(
          '   简介: ${bio.isNotEmpty ? bio.substring(0, bio.length.clamp(0, 20)) + (bio.length > 20 ? "..." : "") : "(空)"}');

      if (avatarUrl != null && avatarUrl!.isNotEmpty) {
        await _downloadAndSaveAvatar(avatarUrl!);
      } else {
        await _prefs.remove(_keyUserAvatarBase64);
        debugPrint('[USER-CACHE]   头像: (已清除)');
      }

      return true;
    } catch (e) {
      debugPrint('[USER-CACHE] ❌ 保存用户信息失败: $e');
      return false;
    }
  }

  static Future<void> _downloadAndSaveAvatar(String url) async {
    try {
      debugPrint('[CACHE DEBUG] 正在下载头像用于Base64转换...');
      debugPrint('   URL: $url');

      final token = PBConfig.pb.authStore.token;
      final headers = <String, String>{};
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http.get(Uri.parse(url), headers: headers);

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final base64String = base64Encode(response.bodyBytes);
        await _prefs.setString(_keyUserAvatarBase64, base64String);

        debugPrint('[CACHE DEBUG] ✅ 写入头像缓存成功，长度=${base64String.length}');
      } else {
        debugPrint(
            '[CACHE DEBUG] ❌ 头像下载失败 | URL: $url | 状态码: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[CACHE DEBUG] ❌ 头像下载异常 | URL: $url | 错误: $e');
    }
  }

  static String? get userId =>
      _isInitialized ? _prefs.getString(_keyUserId) : null;

  static String get userName =>
      _isInitialized ? _prefs.getString(_keyUserName) ?? '' : '';

  static String get userBio =>
      _isInitialized ? _prefs.getString(_keyUserBio) ?? '' : '';

  static String? get userAvatarBase64 =>
      _isInitialized ? _prefs.getString(_keyUserAvatarBase64) : null;

  static bool get hasCachedData =>
      _isInitialized && userId != null && userId!.isNotEmpty;

  static bool get hasCachedAvatar =>
      userAvatarBase64 != null && userAvatarBase64!.isNotEmpty;

  static Future<void> updateName(String newName) async {
    if (!_isInitialized) return;
    await _prefs.setString(_keyUserName, newName);
    debugPrint('[USER-CACHE] ✏️ 已更新缓存昵称: $newName');
  }

  static Future<void> updateBio(String newBio) async {
    if (!_isInitialized) return;
    await _prefs.setString(_keyUserBio, newBio);
    debugPrint(
        '[USER-CACHE] ✏️ 已更新缓存简介: ${newBio.isNotEmpty ? newBio.substring(0, newBio.length.clamp(0, 20)) : "(空)"}');
  }

  static Future<void> updateAvatarFromUrl(String avatarUrl) async {
    if (!_isInitialized) return;
    await _downloadAndSaveAvatar(avatarUrl);
  }

  static Future<void> updateAvatarFromBytes(List<int> bytes) async {
    if (!_isInitialized) return;
    try {
      final base64String = base64Encode(bytes);
      await _prefs.setString(_keyUserAvatarBase64, base64String);
      debugPrint(
          '[USER-CACHE] ✏️ 已更新缓存头像 | 大小: ${(base64String.length / 1024).toStringAsFixed(1)}KB');
    } catch (e) {
      debugPrint('[USER-CACHE] ❌ 更新头像缓存失败: $e');
    }
  }

  static Future<void> clearAll() async {
    if (!_isInitialized) return;

    await _prefs.remove(_keyUserId);
    await _prefs.remove(_keyUserName);
    await _prefs.remove(_keyUserBio);
    await _prefs.remove(_keyUserAvatarBase64);

    debugPrint('[USER-CACHE] 🗑️ 全部用户缓存已清空');
  }

  static void printCacheStatus() {
    debugPrint('');
    debugPrint('[USER-CACHE] ════════════════════════════════');
    debugPrint('[USER-CACHE] 当前缓存状态:');
    debugPrint('   用户ID: ${userId ?? "(空)"}');
    debugPrint('   昵称: ${userName.isEmpty ? "(空)" : userName}');
    debugPrint(
        '   简介: ${userBio.isEmpty ? "(空)" : userBio.substring(0, userBio.length.clamp(0, 30)) + "..."}');
    debugPrint('   头像: ${hasCachedAvatar ? "✅ 已缓存" : "❌ 无缓存"}');
    debugPrint('[USER-CACHE] ════════════════════════════════');
    debugPrint('');
  }

  static Widget buildUserAvatar({
    double size = 50,
    required Widget defaultAvatar,
    String? avatarUrl,
  }) {
    // 优先从本地base64缓存读取（最可靠，和SettingsModal一致的路径）
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return defaultAvatar;
        }

        final prefs = snapshot.data!;
        final base64Str = prefs.getString('user_avatar_base64');

        // 有本地缓存 → 直接显示（最可靠）
        if (base64Str != null && base64Str.isNotEmpty) {
          try {
            final imageBytes = base64Decode(base64Str);
            return Image.memory(
              imageBytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => defaultAvatar,
            );
          } catch (e) {
            debugPrint('[USER-CACHE] ⚠️ base64解码失败，尝试网络加载');
          }
        }

        // 无缓存但有URL → 用带认证头的Image.network加载（PB的Auth集合文件需要token）
        if (avatarUrl != null && avatarUrl.isNotEmpty) {
          final token = PBConfig.pb.authStore.token;
          final headers = <String, String>{};
          if (token.isNotEmpty) {
            headers['Authorization'] = 'Bearer $token';
          }
          return Image.network(
            avatarUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: size.toInt() * 2,
            filterQuality: FilterQuality.medium,
            headers: headers,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('[USER-CACHE] ⚠️ 头像网络加载失败: $error');
              return defaultAvatar;
            },
            loadingBuilder: (context, child, loadingProgress) =>
                loadingProgress == null ? child : defaultAvatar,
          );
        }

        // 都没有 → 默认头像
        return defaultAvatar;
      },
    );
  }
}
