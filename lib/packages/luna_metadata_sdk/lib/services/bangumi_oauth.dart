import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bangumi 个人访问令牌存储
///
/// 用户从 bgm.tv 个人设置页创建个人访问令牌（Personal Access Token），
/// 粘贴到设置弹窗的 TOKEN 输入框中。本类负责持久化到 SharedPreferences。
///
/// 使用方式：
/// - [loadToken]：读取已存储的令牌（返回 null 表示未配置）
/// - [saveToken]：保存用户输入的令牌
/// - [clearToken]：清除令牌
///
/// 令牌以 `Authorization: Bearer <token>` 方式发送给 Bangumi API，
/// 获得更高的速率限额。未配置时 [BangumiMirrorService] 自动降级为匿名访问。
class BangumiTokenStore {
  static const String _prefsKey = 'bangumi_personal_access_token';

  /// 读取已存储的令牌
  ///
  /// 返回令牌字符串，未配置时返回 null。
  static Future<String?> loadToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_prefsKey);
      if (token == null || token.trim().isEmpty) return null;
      return token.trim();
    } catch (e) {
      debugPrint('[BangumiTokenStore] 加载失败: $e');
      return null;
    }
  }

  /// 保存令牌
  static Future<void> saveToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, token.trim());
      debugPrint('[BangumiTokenStore] ✅ 令牌已保存');
    } catch (e) {
      debugPrint('[BangumiTokenStore] 保存失败: $e');
    }
  }

  /// 清除令牌
  static Future<void> clearToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
      debugPrint('[BangumiTokenStore] 令牌已清除');
    } catch (e) {
      debugPrint('[BangumiTokenStore] 清除失败: $e');
    }
  }
}
