import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_model.dart';

/// 本地账户服务 —— 「本地状态」的身份中枢。
///
/// 设计文档：`docs/DEV/features/local_account_mode.md`。术语约定：
/// - **本地账户**：仅存于本机（SharedPreferences `local_account_*` 独立 key），
///   无 PocketBase 记录、无 token；id 形如 `local_xxxxxxxx`。
/// - **账号**：已登录的 PocketBase `users` 记录（由 [AuthService] 管理）。
///
/// 🔴 与 `UserCacheService`（`user_*`，云端账号展示缓存）和 `AuthService`
/// 的 `pb_*` 凭据 key **完全隔离**：`AuthService.logout()` 会清空后两者，
/// 绝不能波及本地账户资料 —— 这是「本地/云端资料并存互不覆盖」的基石。
///
/// 使用前置：main.dart 启动时（`UserCacheService.init()` 之后）调用 [init]。
class LocalAccountService {
  LocalAccountService._();

  static const String _keyId = 'local_account_id';
  static const String _keyName = 'local_account_name';
  static const String _keyBio = 'local_account_bio';
  static const String _keyAvatarB64 = 'local_account_avatar_b64';
  static const String _keyCreatedAt = 'local_account_created_at';

  static bool _isInitialized = false;
  static late SharedPreferences _prefs;

  static bool get isInitialized => _isInitialized;

  /// 初始化（幂等）。必须在任何读/写之前完成。
  static Future<void> init() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
    debugPrint('[LOCAL-ACCOUNT] init done');
  }

  static void _ensureInit() {
    if (!_isInitialized) {
      throw StateError('LocalAccountService 尚未 init()，请先在启动时初始化');
    }
  }

  /// 是否已存在本地账户（init 后可同步读取）。
  static bool get exists =>
      _isInitialized && (_prefs.getString(_keyId)?.isNotEmpty ?? false);

  /// 创建本地账户。名字必填（由调用方 UI 校验非空），头像/简介可选。
  /// 返回创建后的 [UserModel]（isLocalAccount=true）。
  static Future<UserModel> create({
    required String name,
    String bio = '',
    Uint8List? avatarBytes,
  }) async {
    _ensureInit();
    final id = 'local_${_randomSuffix()}';
    await _prefs.setString(_keyId, id);
    await _prefs.setString(_keyName, name);
    await _prefs.setString(_keyBio, bio);
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      await _prefs.setString(_keyAvatarB64, base64Encode(avatarBytes));
    } else {
      await _prefs.remove(_keyAvatarB64);
    }
    await _prefs.setString(_keyCreatedAt, DateTime.now().toIso8601String());
    debugPrint('[LOCAL-ACCOUNT] ✅ 本地账户已创建 | id=$id name=$name');
    return load()!;
  }

  /// 加载本地账户；不存在返回 null。
  ///
  /// 头像直接解码进 [UserModel.avatarBytes]（不走 UserCacheService 的
  /// 云端缓存 key，避免「本地/云端头像」两个 base64 来源互相污染）。
  static UserModel? load() {
    if (!exists) return null;
    final id = _prefs.getString(_keyId)!;
    Uint8List? avatarBytes;
    final b64 = _prefs.getString(_keyAvatarB64);
    if (b64 != null && b64.isNotEmpty) {
      try {
        avatarBytes = Uint8List.fromList(base64Decode(b64));
      } catch (e) {
        debugPrint('[LOCAL-ACCOUNT] ⚠️ 头像 base64 解码失败（忽略头像）: $e');
      }
    }
    return UserModel(
      id: id,
      email: '', // 本地账户无邮箱
      name: _prefs.getString(_keyName) ?? '',
      bio: _prefs.getString(_keyBio) ?? '',
      avatarUrl: '', // 无云端头像 URL
      avatarBytes: avatarBytes,
      created:
          DateTime.tryParse(_prefs.getString(_keyCreatedAt) ?? '') ??
              DateTime.now(),
      token: '',
      isLoggedIn: false,
    );
  }

  /// 更新本地资料（名字/简介）。与设置窗口「账号区块」的本地分支共用。
  static Future<void> updateProfile({String? name, String? bio}) async {
    _ensureInit();
    if (name != null) await _prefs.setString(_keyName, name);
    if (bio != null) await _prefs.setString(_keyBio, bio);
    debugPrint('[LOCAL-ACCOUNT] 本地资料已更新');
  }

  /// 更新本地头像（base64 落盘，量级与既有云端头像缓存相同）。
  static Future<void> updateAvatar(Uint8List bytes) async {
    _ensureInit();
    await _prefs.setString(_keyAvatarB64, base64Encode(bytes));
  }

  /// 移除本地头像。
  static Future<void> removeAvatar() async {
    _ensureInit();
    await _prefs.remove(_keyAvatarB64);
  }

  /// 清除本地账户（本期不挂任何 UI，仅供未来「删除本地身份」使用）。
  static Future<void> clear() async {
    _ensureInit();
    await _prefs.remove(_keyId);
    await _prefs.remove(_keyName);
    await _prefs.remove(_keyBio);
    await _prefs.remove(_keyAvatarB64);
    await _prefs.remove(_keyCreatedAt);
    debugPrint('[LOCAL-ACCOUNT] 本地账户已清除');
  }

  /// 8 位十六进制随机后缀。
  static String _randomSuffix() {
    final rnd = Random.secure();
    return List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// 仅供测试：重置内存态（SharedPreferences 实例），配合
  /// `SharedPreferences.setMockInitialValues({})` 实现用例间隔离。
  @visibleForTesting
  static Future<void> resetForTest() async {
    _isInitialized = false;
    await init();
  }
}
