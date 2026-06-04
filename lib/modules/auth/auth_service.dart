import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/pb_config.dart';
import 'user_model.dart';
import '../../services/user_cache_service.dart';

class AuthService {
  static const String _keyToken = 'pb_auth_token';
  static const String _keyUserId = 'pb_user_id';
  static const String _keyUserName = 'pb_user_name';
  static const String _keyUserEmail = 'pb_user_email';

  static Future<AuthResult> login(String email, String password) async {
    debugPrint('[AUTH] 开始请求PocketBase登录 | email=$email');
    try {
      final authData = await PBConfig.pb
          .collection('users')
          .authWithPassword(email, password);

      debugPrint('[AUTH] ✅ 登录成功');
      debugPrint(
          '[AUTH]    Token: ${authData.token.length > 20 ? "${authData.token.substring(0, 20)}..." : authData.token}');
      debugPrint('[AUTH]    Record ID: ${authData.record.id}');
      debugPrint(
          '[AUTH]    authStore.isValid: ${PBConfig.pb.authStore.isValid}');

      await _saveAuthState(authData);

      final model = PBConfig.pb.authStore.model;
      String avatarUrl = '';

      if (model != null) {
        final avatarFieldValue = model.getStringValue('avatar');
        if (avatarFieldValue != null && avatarFieldValue.isNotEmpty) {
          avatarUrl =
              PBConfig.pb.getFileUrl(model, avatarFieldValue).toString();
        }
      }

      final user = UserModel(
        id: authData.record.id,
        email: authData.record.getStringValue('email'),
        name: authData.record.getStringValue('name'),
        bio: authData.record.getStringValue('description'),
        avatarUrl: avatarUrl,
        created: DateTime.tryParse(authData.record.created) ?? DateTime.now(),
        token: authData.token,
        isLoggedIn: true,
      );

      await UserCacheService.saveUserInfo(
        userId: user.id,
        name: user.name,
        bio: user.bio,
        avatarUrl: user.avatarUrl,
      );

      return AuthResult.success(user);
    } on ClientException catch (e) {
      if (e.statusCode == 400) {
        final response = e.response;
        if (response is Map<String, dynamic>) {
          final data = response['data'] ?? response;
          if (data is Map<String, dynamic>) {
            final msg = (data['message'] ?? '').toString().toLowerCase();
            if (msg.contains('invalid') || msg.contains('failed')) {
              debugPrint('[ERROR] ❌ 登录失败 (400): 邮箱或密码错误，请重新输入 | raw: $e');
              return AuthResult.failure(
                AuthResultCode.invalidCredentials,
                '邮箱或密码错误，请重新输入',
              );
            }
          }
        }
        debugPrint('[ERROR] ❌ 登录失败 (400): 邮箱或密码错误，请重新输入 | raw: $e');
        return AuthResult.failure(
          AuthResultCode.invalidCredentials,
          '邮箱或密码错误，请重新输入',
        );
      }
      debugPrint(
          '[ERROR] ❌ 登录失败 (${e.statusCode}): ${_handleClientException(e).message} | raw: $e');
      return _handleClientException(e);
    } catch (e) {
      debugPrint('[ERROR] ❌ 登录失败 (未知异常): $e');
      return _handleUnknownError(e);
    }
  }

  static Future<AuthResult> register(
    String email,
    String password,
    String name,
  ) async {
    debugPrint('[AUTH] 开始请求PocketBase注册 | email=$email, name=$name');
    try {
      final body = <String, dynamic>{
        'email': email,
        'password': password,
        'passwordConfirm': password,
        'name': name,
      };

      await PBConfig.pb.collection('users').create(body: body);

      debugPrint('[AUTH] ✅ 注册成功，自动登录...');
      return login(email, password);
    } on ClientException catch (e) {
      if (e.statusCode == 400) {
        final response = e.response;
        if (response is Map<String, dynamic>) {
          final data = response['data'] ?? response;
          if (data is Map<String, dynamic>) {
            final emailError = data['email'];
            if (emailError != null) {
              final msg = emailError.toString().toLowerCase();
              if (msg.contains('unique') ||
                  msg.contains('already') ||
                  msg.contains('exists')) {
                debugPrint('[ERROR] ❌ 注册失败 (400): 该邮箱已被注册 | raw: $e');
                return AuthResult.failure(
                  AuthResultCode.emailAlreadyExists,
                  '该邮箱已被注册，请直接登录',
                );
              }
              if (msg.contains('invalid') || msg.contains('format')) {
                debugPrint('[ERROR] ❌ 注册失败 (400): 邮箱格式不正确 | raw: $e');
                return AuthResult.failure(
                  AuthResultCode.invalidEmail,
                  '邮箱格式不正确',
                );
              }
            }
            final passwordError = data['password'];
            if (passwordError != null) {
              debugPrint('[ERROR] ❌ 注册失败 (400): 密码强度不足 | raw: $e');
              return AuthResult.failure(
                AuthResultCode.weakPassword,
                '密码强度不足，至少6位字符',
              );
            }
          }
        }
        debugPrint('[ERROR] ❌ 注册失败 (400): 注册信息有误 | raw: $e');
        return AuthResult.failure(
          AuthResultCode.unknownError,
          '注册信息有误，请检查后重试',
        );
      }
      debugPrint(
          '[ERROR] ❌ 注册失败 (${e.statusCode}): ${_handleClientException(e).message} | raw: $e');
      return _handleClientException(e);
    } catch (e) {
      debugPrint('[ERROR] ❌ 注册失败 (未知异常): $e');
      return _handleUnknownError(e);
    }
  }

  static Future<void> logout() async {
    debugPrint('[AUTH] 用户退出登录，清除Token和本地缓存');
    try {
      PBConfig.pb.authStore.clear();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserEmail);

    await UserCacheService.clearAll();

    debugPrint(
        '[AUTH] ✅ 退出登录完成，authStore.isValid: ${PBConfig.pb.authStore.isValid}');
  }

  static Future<bool> checkAutoLogin() async {
    debugPrint('[AUTH] 检查本地登录态...');
    try {
      if (!PBConfig.pb.authStore.isValid) {
        debugPrint('[AUTH]   authStore 无效，尝试从本地恢复 Token');
        final restored = await _restoreFromLocal();
        if (!restored) {
          debugPrint('[AUTH]   ⚠️ 本地无有效Token，需要重新登录');
          return false;
        }
        debugPrint('[AUTH]   ✅ 从本地恢复 Token 成功');
      } else {
        debugPrint('[AUTH]   authStore 已有有效 Token');
      }

      try {
        debugPrint('[AUTH]   正在刷新 Token 验证有效性...');
        await PBConfig.pb.collection('users').authRefresh();
        debugPrint(
            '[AUTH]   ✅ Token 刷新成功，isValid: ${PBConfig.pb.authStore.isValid}');
        debugPrint(
            '[AUTH]   当前Token: ${_maskToken(PBConfig.pb.authStore.token)}');
        return true;
      } on ClientException catch (e) {
        debugPrint('[ERROR] ❌ Token 刷新失败 (${e.statusCode}): $e');
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('[ERROR] ❌ 检查登录态异常: $e');
      return false;
    }
  }

  static Future<UserModel?> getCurrentUser() async {
    try {
      if (!PBConfig.pb.authStore.isValid) {
        debugPrint('[AUTH] getCurrentUser: authStore 无效，返回 null');
        return null;
      }
      final record = PBConfig.pb.authStore.record;
      if (record == null) {
        debugPrint('[AUTH] getCurrentUser: authStore 无 record，返回 null');
        return null;
      }
      final user = UserModel(
        id: record.id,
        email: record.getStringValue('email'),
        name: record.getStringValue('name'),
        bio: record.getStringValue('description'),
        avatarUrl: _extractAvatarUrl(record),
        created: DateTime.tryParse(record.created) ?? DateTime.now(),
        token: PBConfig.pb.authStore.token,
        isLoggedIn: true,
      );
      debugPrint(
          '[AUTH] getCurrentUser: ✅ 获取成功 | name="${user.name}", id=${user.id}, hasAvatar=${user.hasAvatar}');
      return user;
    } catch (e) {
      debugPrint('[ERROR] ❌ getCurrentUser 异常: $e');
      return null;
    }
  }

  static Future<bool> _restoreFromLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_keyToken);
      if (token == null || token.isEmpty) return false;
      PBConfig.pb.authStore.save(token, null);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _saveAuthState(RecordAuth authData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyToken, authData.token);
      await prefs.setString(_keyUserId, authData.record.id);
      await prefs.setString(
        _keyUserName,
        authData.record.getStringValue('name'),
      );
      await prefs.setString(
        _keyUserEmail,
        authData.record.getStringValue('email'),
      );
    } catch (_) {}
  }

  static Future<AuthResult> updateProfile({
    required String name,
    String description = '',
  }) async {
    debugPrint(
        '[AUTH] 更新用户资料 | name="$name", description="${description.isNotEmpty ? description.substring(0, 20) + "..." : "(空)"}"');
    try {
      final recordId = PBConfig.pb.authStore.record?.id;
      if (recordId == null || recordId.isEmpty) {
        debugPrint('[ERROR] ❌ 更新资料失败: 用户未登录');
        return AuthResult.failure(
          AuthResultCode.unknownError,
          '用户未登录，无法更新资料',
        );
      }

      final body = <String, dynamic>{'name': name, 'description': description};

      final updatedRecord =
          await PBConfig.pb.collection('users').update(recordId, body: body);

      debugPrint('[AUTH] ✅ 服务器返回状态码: 200 (成功)');

      final user = UserModel(
        id: updatedRecord.id,
        email: updatedRecord.getStringValue('email'),
        name: updatedRecord.getStringValue('name'),
        bio: updatedRecord.getStringValue('description'),
        avatarUrl: _extractAvatarUrl(updatedRecord),
        created: DateTime.tryParse(updatedRecord.created) ?? DateTime.now(),
        token: PBConfig.pb.authStore.token,
        isLoggedIn: true,
      );

      debugPrint(
          '[AUTH] ✅ 用户资料更新成功 | 新名称: "${user.name}", 新简介: "${user.bio.isNotEmpty ? user.bio.substring(0, user.bio.length.clamp(0, 20)) + (user.bio.length > 20 ? "..." : "") : "(空)"}"');
      return AuthResult.success(user);
    } on ClientException catch (e) {
      debugPrint('[ERROR] ❌ 更新资料失败 (状态码: ${e.statusCode}): $e');
      debugPrint('[ERROR]   服务器返回: ${e.response}');
      return _handleClientException(e);
    } catch (e) {
      debugPrint('[ERROR] ❌ 更新资料失败 (未知异常): $e');
      return _handleUnknownError(e);
    }
  }

  static Future<AuthResult> uploadAvatar({
    required String fileName,
    required List<int> bytes,
  }) async {
    try {
      final recordId = PBConfig.pb.authStore.record?.id;
      if (recordId == null || recordId.isEmpty) {
        debugPrint('[ERROR] ❌ 上传头像失败: 用户未登录');
        return AuthResult.failure(
          AuthResultCode.unknownError,
          '用户未登录，无法上传头像',
        );
      }

      final uri = Uri.parse(
          '${PBConfig.pb.baseUrl}/api/collections/users/records/$recordId');

      final request = http.MultipartRequest('PATCH', uri);
      request.headers['Authorization'] =
          'Bearer ${PBConfig.pb.authStore.token}';

      final multipartFile = http.MultipartFile.fromBytes(
        'avatar',
        bytes,
        filename: fileName,
      );

      request.files.add(multipartFile);

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        debugPrint('[ERROR] ❌ 头像上传失败 (状态码: ${response.statusCode})');
        return AuthResult.failure(
          AuthResultCode.unknownError,
          '头像上传失败 (状态码: ${response.statusCode})',
        );
      }

      await PBConfig.pb.collection('users').authRefresh();

      final record = PBConfig.pb.authStore.record;
      if (record == null) {
        return AuthResult.failure(
          AuthResultCode.unknownError,
          '获取用户记录失败',
        );
      }

      final user = UserModel(
        id: record.id,
        email: record.getStringValue('email'),
        name: record.getStringValue('name'),
        bio: record.getStringValue('description'),
        avatarUrl: _extractAvatarUrl(record),
        created: DateTime.tryParse(record.created) ?? DateTime.now(),
        token: PBConfig.pb.authStore.token,
        isLoggedIn: true,
      );

      debugPrint(
          '[AUTH] ✅ 头像上传成功 | name="${user.name}", hasAvatar=${user.hasAvatar}');

      return AuthResult.success(user);
    } on ClientException catch (e) {
      debugPrint('[ERROR] ❌ 头像上传失败 (状态码: ${e.statusCode}): $e');
      debugPrint('[ERROR]   完整错误堆栈: $e');
      debugPrint('[ERROR]   服务器返回: ${e.response}');
      return _handleClientException(e);
    } catch (e) {
      debugPrint('[ERROR] ❌ 头像上传失败 (未知异常): $e');
      debugPrint('[ERROR]   完整错误堆栈: $e');
      return _handleUnknownError(e);
    }
  }

  static String _extractAvatarUrl(dynamic record) {
    try {
      final model = PBConfig.pb.authStore.model;
      if (model == null) {
        debugPrint('[AUTH] authStore.model 为空，无法生成头像URL');
        return '';
      }

      final avatarFieldValue = model.getStringValue('avatar');
      if (avatarFieldValue == null || avatarFieldValue.isEmpty) {
        debugPrint('[AUTH] 头像字段为空，使用默认头像');
        return '';
      }

      final url = PBConfig.pb.getFileUrl(model, avatarFieldValue).toString();

      debugPrint('[AUTH] ✅ 生成头像URL（SDK方式）：$url');
      return url;
    } catch (e) {
      debugPrint('[AUTH] 提取头像URL异常: $e');
      return '';
    }
  }

  static AuthResult _handleClientException(ClientException e) {
    final statusCode = e.statusCode;

    if (statusCode == 401 || statusCode == 403) {
      return AuthResult.failure(
        AuthResultCode.invalidCredentials,
        '鉴权失败，请检查账号密码',
      );
    }

    if (statusCode == 404) {
      return AuthResult.failure(
        AuthResultCode.userNotFound,
        '用户不存在，请先注册',
      );
    }

    if (_isNetworkError(e)) {
      return AuthResult.failure(
        AuthResultCode.networkError,
        '网络连接失败，请检查网络后重试',
      );
    }

    return AuthResult.failure(
      AuthResultCode.unknownError,
      '服务器响应异常 ($statusCode)，请稍后重试',
    );
  }

  static bool _isNetworkError(ClientException e) {
    final originalError = e.originalError;
    if (originalError is SocketException) return true;
    if (originalError is IOException) return true;
    final responseStr = e.toString().toLowerCase();
    return responseStr.contains('connection') ||
        responseStr.contains('timeout') ||
        responseStr.contains('network') ||
        responseStr.contains('socket') ||
        responseStr.contains('failed to connect');
  }

  static AuthResult _handleUnknownError(dynamic e) {
    if (e is SocketException || e is IOException) {
      return AuthResult.failure(
        AuthResultCode.networkError,
        '无法连接服务器，请检查网络连接',
      );
    }
    return AuthResult.failure(
      AuthResultCode.unknownError,
      '发生未知错误，请稍后重试',
    );
  }

  static String _maskToken(String token) {
    if (token.isEmpty) return '(空)';
    if (token.length <= 20) return '$token...';
    return '${token.substring(0, 20)}...';
  }
}
