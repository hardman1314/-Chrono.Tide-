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

  /// 本地账户（「本地状态」身份）：非云端登录、id 以 `local_` 开头。
  /// 设计文档：docs/DEV/features/local_account_mode.md §2.2。
  bool get isLocalAccount => !isLoggedIn && id.startsWith('local_');

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

/// 找回密码 - 请求验证码结果（第 1 步，2026-10-02 改邮箱 OTP 流程）
class ResetOtpRequestResult {
  /// 是否请求成功（验证码已发出）
  final bool success;

  /// 验证码记录 ID（success=true 时有效，供第 2 步校验使用）
  final String otpId;

  /// 验证码有效秒数（success=true 时有效）
  final int expiresInSeconds;

  /// 该邮箱未注册（服务端 404 明确提示，帮助用户发现填错邮箱）
  final bool emailNotFound;

  /// 触发频率限制时的剩余等待秒数（>0 表示需等待）
  final int retryAfterSeconds;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404 且无业务 code / 网络不可达）时为 true
  final bool isUnavailable;

  const ResetOtpRequestResult({
    required this.success,
    this.otpId = '',
    this.expiresInSeconds = 0,
    this.emailNotFound = false,
    this.retryAfterSeconds = 0,
    this.message,
    this.isUnavailable = false,
  });
}

/// 找回密码 - 校验验证码结果（第 2 步）
class ResetOtpVerifyResult {
  /// 是否校验通过
  final bool success;

  /// 重置令牌（success=true 时有效，第 3 步重置密码时回传）
  final String resetToken;

  /// 令牌归属邮箱（success=true 时有效）
  final String email;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const ResetOtpVerifyResult({
    required this.success,
    this.resetToken = '',
    this.email = '',
    this.message,
    this.isUnavailable = false,
  });
}

/// 找回密码 - 重置密码结果（第 3 步）
class ResetPasswordResult {
  /// 是否重置成功
  final bool success;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const ResetPasswordResult({
    required this.success,
    this.message,
    this.isUnavailable = false,
  });
}

/// 注册验证码 - 请求验证码结果（第 1 步）
class RegisterOtpRequestResult {
  /// 是否请求成功（验证码已发出）
  final bool success;

  /// 验证码记录 ID（success=true 时有效，供第 2 步校验使用）
  final String otpId;

  /// 验证码有效秒数（success=true 时有效）
  final int expiresInSeconds;

  /// 该邮箱已被注册（决策 A：明确提示用户直接登录）
  final bool emailAlreadyExists;

  /// 触发频率限制时的剩余等待秒数（>0 表示需等待）
  final int retryAfterSeconds;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const RegisterOtpRequestResult({
    required this.success,
    this.otpId = '',
    this.expiresInSeconds = 0,
    this.emailAlreadyExists = false,
    this.retryAfterSeconds = 0,
    this.message,
    this.isUnavailable = false,
  });
}

/// 注册验证码 - 校验结果（第 2 步）
class RegisterOtpVerifyResult {
  /// 是否校验通过
  final bool success;

  /// 注册令牌（success=true 时有效，提交注册时回传）
  final String regToken;

  /// 令牌归属邮箱（success=true 时有效）
  final String email;

  /// 提示/错误信息
  final String? message;

  /// 服务端接口未部署（404/网络不可达）时为 true
  final bool isUnavailable;

  const RegisterOtpVerifyResult({
    required this.success,
    this.regToken = '',
    this.email = '',
    this.message,
    this.isUnavailable = false,
  });
}
