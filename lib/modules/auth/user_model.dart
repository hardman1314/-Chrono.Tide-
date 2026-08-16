import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/pb_config.dart';

class UserModel {
  final String id;
  final String email;
  final String name;
  final String bio;
  final String avatarUrl;
  final Uint8List? avatarBytes; // 头像原始字节（已下载）
  final DateTime created;
  final String token;
  final bool isLoggedIn;

  UserModel({
    required this.id,
    required this.email,
    required this.name,
    this.bio = '',
    this.avatarUrl = '',
    this.avatarBytes,
    required this.created,
    required this.token,
    required this.isLoggedIn,
  });

  factory UserModel.fromPBRecord(dynamic record, String token) {
    return UserModel(
      id: record.id,
      email: record.getStringValue('email'),
      name: record.getStringValue('name'),
      bio: record.getStringValue('description'),
      avatarUrl: _extractAvatarUrl(record),
      created: DateTime.tryParse(record.created) ?? DateTime.now(),
      token: token,
      isLoggedIn: true,
    );
  }

  static String _extractAvatarUrl(dynamic record) {
    try {
      final avatar = record.getStringValue('avatar');
      if (avatar != null && avatar.isNotEmpty) {
        // 和 GameModel 一样直接拼接 URL，不依赖 authStore.model
        final url = '${PBConfig.baseUrl}/api/files/users/${record.id}/$avatar';
        debugPrint('[USER_MODEL] ✅ 生成头像URL（直接拼接）：$url');
        return url;
      }
      debugPrint('[USER_MODEL] 头像字段为空');
    } catch (e) {
      debugPrint('[USER_MODEL] 提取头像URL异常: $e');
    }
    return '';
  }

  factory UserModel.empty() {
    return UserModel(
      id: '',
      email: '',
      name: '',
      bio: '',
      avatarUrl: '',
      avatarBytes: null,
      created: DateTime.now(),
      token: '',
      isLoggedIn: false,
    );
  }

  bool get hasAvatar => avatarUrl.isNotEmpty;

  bool get hasAvatarBytes => avatarBytes != null && avatarBytes!.isNotEmpty;

  /// 用带认证头的 HTTP 请求下载头像字节
  static Future<Uint8List?> downloadAvatarBytes(
      String url, String token) async {
    if (url.isEmpty || token.isEmpty) return null;
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        debugPrint('[USER_MODEL] ✅ 头像下载成功 | 大小: ${response.bodyBytes.length}B');
        return response.bodyBytes;
      }
      debugPrint('[USER_MODEL] ❌ 头像下载失败 | 状态码: ${response.statusCode}');
    } catch (e) {
      debugPrint('[USER_MODEL] ❌ 头像下载异常: $e');
    }
    return null;
  }

  UserModel copyWith({
    String? id,
    String? email,
    String? name,
    String? bio,
    String? avatarUrl,
    Uint8List? avatarBytes,
    DateTime? created,
    String? token,
    bool? isLoggedIn,
  }) {
    return UserModel(
      id: id ?? this.id,
      email: email ?? this.email,
      name: name ?? this.name,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      created: created ?? this.created,
      token: token ?? this.token,
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
    );
  }
}

enum AuthResultCode {
  success,
  networkError,
  invalidCredentials,
  userNotFound,
  passwordIncorrect,
  emailAlreadyExists,
  weakPassword,
  invalidEmail,
  unknownError,
}

class AuthResult {
  final AuthResultCode code;
  final String message;
  final UserModel? user;

  const AuthResult({required this.code, required this.message, this.user});

  factory AuthResult.success(UserModel user) {
    return AuthResult(
        code: AuthResultCode.success, message: '操作成功', user: user);
  }

  factory AuthResult.failure(AuthResultCode code, String message) {
    return AuthResult(code: code, message: message);
  }
}

/// 找回账号查询结果
class LookupResult {
  /// 是否找到匹配用户
  final bool found;

  /// 脱敏邮箱（如 a***@qq.com），found=true 时有效
  final String email;

  /// 提示/错误信息（found=false 且非未部署时使用）
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true，UI 据此显示"联系管理员"
  final bool isUnavailable;

  /// 模糊匹配命中时，实际匹配到的昵称（多条结果时用于提示用户）
  final String? matchedName;

  /// 是否有多条匹配结果
  final bool hasMultipleMatches;

  const LookupResult({
    required this.found,
    this.email = '',
    this.message,
    this.isUnavailable = false,
    this.matchedName,
    this.hasMultipleMatches = false,
  });
}

/// 找回密码 - 请求重置结果
class RequestResetResult {
  /// 是否请求成功（邮箱存在并已生成令牌）
  final bool success;

  /// 临时重置令牌（success=true 时有效，10 分钟内有效）
  final String token;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const RequestResetResult({
    required this.success,
    this.token = '',
    this.message,
    this.isUnavailable = false,
  });
}

/// 找回密码 - 重置密码结果
class ResetResult {
  /// 是否重置成功
  final bool success;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const ResetResult({
    required this.success,
    this.message,
    this.isUnavailable = false,
  });
}
