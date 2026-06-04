import 'package:flutter/foundation.dart';
import '../../core/pb_config.dart';

class UserModel {
  final String id;
  final String email;
  final String name;
  final String bio;
  final String avatarUrl;
  final DateTime created;
  final String token;
  final bool isLoggedIn;

  UserModel({
    required this.id,
    required this.email,
    required this.name,
    this.bio = '',
    this.avatarUrl = '',
    required this.created,
    required this.token,
    required this.isLoggedIn,
  });

  factory UserModel.fromPBRecord(dynamic record, String token) {
    return UserModel(
      id: record.id,
      email: record.getStringValue('email'),
      name: record.getStringValue('name'),
      bio: record.getStringValue('bio'),
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
        final model = PBConfig.pb.authStore.model;
        if (model == null) {
          debugPrint('[USER_MODEL] authStore.model 为空');
          return '';
        }
        final url = PBConfig.pb.getFileUrl(model, avatar).toString();
        debugPrint('[USER_MODEL] 正在生成头像URL（SDK方式）：$url');
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
      created: DateTime.now(),
      token: '',
      isLoggedIn: false,
    );
  }

  bool get hasAvatar => avatarUrl.isNotEmpty;

  UserModel copyWith({
    String? id,
    String? email,
    String? name,
    String? bio,
    String? avatarUrl,
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
