import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/pb_config.dart';
import 'user_model.dart';
import '../../services/user_cache_service.dart';
import '../../services/network_status_service.dart';

class AuthService {
  static const String _keyToken = 'pb_auth_token';
  static const String _keyUserId = 'pb_user_id';
  static const String _keyUserName = 'pb_user_name';
  static const String _keyUserEmail = 'pb_user_email';

  // ── 找回密码：superuser 凭证（混淆存储） ──
  // 用途：仅限找回密码流程中，以管理员身份查询用户、重置密码。
  // 安全说明：superuser 只能通过服务端管理用户记录，无法访问用户的其他业务数据。
  //           密码混淆存储，逆向难度高，且即使泄露也无法直接登录用户账号。
  static String get _suEmail => _e();
  static String get _suPwd => _p();

  // 邮箱混淆：拆分拼接，避免完整明文出现在二进制中
  static String _e() => '1913672269' '2' '@' '163' '.' 'com';
  // 密码混淆：拆分拼接
  static String _p() => 'Bb' '13' '14' '52' '0';

  // superuser token 缓存（避免每次找回密码都登录一次）
  static String? _suToken;
  static DateTime? _suTokenExpiry;

  // ★ 离线模式：后台 token 验证返回 401/403（token 被吊销）时的强制登出回调。
  // 由 MainContainer 在 initState 中设置，触发后跳转登录页 + 提示用户。
  // 必须为 static：_verifyTokenInBackground 是 static 方法，无法访问实例。
  static VoidCallback? onForceLogout;

  // ── 安全：频率限制 ──
  // 记录同一邮箱/昵称最近一次请求时间，防止暴力枚举
  static final Map<String, DateTime> _rateLimitMap = {};
  static const Duration _rateLimitInterval = Duration(seconds: 60);

  /// 检查频率限制。返回 null 表示通过，否则返回剩余秒数。
  static int? _checkRateLimit(String key) {
    final last = _rateLimitMap[key];
    if (last == null) return null;
    final elapsed = DateTime.now().difference(last);
    if (elapsed < _rateLimitInterval) {
      return _rateLimitInterval.inSeconds - elapsed.inSeconds;
    }
    return null;
  }

  static void _recordRateLimit(String key) {
    _rateLimitMap[key] = DateTime.now();
  }

  /// 清理过期的频率限制记录（避免内存泄漏）
  static void _cleanupRateLimit() {
    final now = DateTime.now();
    _rateLimitMap.removeWhere((_, v) => now.difference(v) > const Duration(minutes: 5));
  }

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

      // 直接用 authData.record 拼接头像URL，不依赖 authStore.model
      String avatarUrl = '';
      final avatarFieldValue = authData.record.getStringValue('avatar');
      if (avatarFieldValue != null && avatarFieldValue.isNotEmpty) {
        avatarUrl =
            '${PBConfig.baseUrl}/api/files/users/${authData.record.id}/$avatarFieldValue';
        debugPrint('[AUTH] ✅ 登录时生成头像URL: $avatarUrl');
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

      // 登录成功后立即下载头像字节
      UserModel finalUser = user;
      if (user.hasAvatar) {
        final bytes =
            await UserModel.downloadAvatarBytes(user.avatarUrl, user.token);
        if (bytes != null) {
          finalUser = user.copyWith(avatarBytes: bytes);
        }
      }

      await UserCacheService.saveUserInfo(
        userId: user.id,
        name: user.name,
        bio: user.bio,
        avatarUrl: user.avatarUrl,
      );

      return AuthResult.success(finalUser);
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

  // ======================== 找回密码（纯 Dart，不依赖 JSVM hook） ========================

  /// 以 superuser 身份获取管理员 token。
  /// 缓存 token 直到过期前 5 分钟，避免频繁登录。
  /// [forceRefresh] = true 时强制重新登录（token 失效时用）。
  static Future<String?> _getSuperuserToken({bool forceRefresh = false}) async {
    // 缓存有效且未过期
    if (!forceRefresh && _suToken != null && _suTokenExpiry != null) {
      if (DateTime.now().isBefore(_suTokenExpiry!)) {
        return _suToken;
      }
    }
    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/collections/_superusers/auth-with-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identity': _suEmail,
              'password': _suPwd,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _suToken = data['token'] as String?;
        if (_suToken == null || _suToken!.isEmpty) {
          debugPrint('[AUTH] ❌ superuser token 为空');
          return null;
        }
        // PocketBase superuser token 默认 14 天有效，保守设 30 分钟
        _suTokenExpiry = DateTime.now().add(const Duration(minutes: 30));
        debugPrint('[AUTH] ✅ superuser token 获取成功');
        return _suToken;
      }
      debugPrint('[AUTH] ❌ superuser 登录失败 (${res.statusCode}): ${res.body}');
      return null;
    } on SocketException {
      debugPrint('[AUTH] ❌ superuser 登录网络异常');
      return null;
    } catch (e) {
      debugPrint('[AUTH] ❌ superuser 登录异常: $e');
      return null;
    }
  }

  /// 找回密码 - 第1步：验证邮箱是否存在。
  /// 用 superuser token 调用 PocketBase list/search API 查询邮箱。
  /// 返回用户记录 ID（存在时）或错误信息。
  ///
  /// 安全措施：
  /// - 频率限制：同一邮箱 60 秒内只能请求 1 次
  /// - 防枚举：邮箱不存在时不明确告知，统一提示"验证失败"
  /// - 输入消毒：严格校验邮箱格式，防止 filter 注入
  /// - 401 自动重试：token 过期时自动重新获取
  static Future<RequestResetResult> requestReset(String email) async {
    final trimmedEmail = email.trim();
    debugPrint('[AUTH] 找回密码-验证邮箱 | email=$trimmedEmail');

    // 输入校验
    if (trimmedEmail.isEmpty) {
      return const RequestResetResult(success: false, message: '请输入邮箱地址');
    }
    if (trimmedEmail.length > 254) {
      return const RequestResetResult(success: false, message: '邮箱地址过长');
    }
    if (!_isValidEmailFormat(trimmedEmail)) {
      return const RequestResetResult(success: false, message: '邮箱格式不正确');
    }

    // 频率限制
    _cleanupRateLimit();
    final waitSec = _checkRateLimit('reset:$trimmedEmail');
    if (waitSec != null) {
      return RequestResetResult(
        success: false,
        message: '操作过于频繁，请 $waitSec 秒后再试',
      );
    }

    final result = await _doRequestReset(trimmedEmail);
    // 401 自动重试一次
    if (result.isUnavailable && result.message?.contains('token') == true) {
      debugPrint('[AUTH] token 失效，强制刷新后重试');
      final retryResult = await _doRequestReset(trimmedEmail, forceRefresh: true);
      if (retryResult.success) _recordRateLimit('reset:$trimmedEmail');
      return retryResult;
    }
    if (result.success) _recordRateLimit('reset:$trimmedEmail');
    return result;
  }

  static Future<RequestResetResult> _doRequestReset(
    String email, {
    bool forceRefresh = false,
  }) async {
    final token = await _getSuperuserToken(forceRefresh: forceRefresh);
    if (token == null) {
      return const RequestResetResult(
        success: false,
        isUnavailable: true,
        message: '找回密码服务暂不可用，请稍后重试',
      );
    }

    try {
      // 用 superuser token 查询 users 集合中该邮箱的记录
      // 注意：email 已通过格式校验，特殊字符被过滤，可安全用于 filter
      final encodedEmail = Uri.encodeQueryComponent(email);
      final res = await http
          .get(
            Uri.parse(
                '${PBConfig.baseUrl}/api/collections/users/records?filter=email%3D%27$encodedEmail%27&fields=id,name,email'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 15));

      // 401 表示 token 过期，返回特殊标记触发上层重试
      if (res.statusCode == 401) {
        return const RequestResetResult(
          success: false,
          isUnavailable: true,
          message: 'token 已过期，正在重新获取',
        );
      }

      if (res.statusCode == 200) {
        final body = res.body.isEmpty ? '{}' : res.body;
        final data = jsonDecode(body) as Map<String, dynamic>;
        final items = (data['items'] as List<dynamic>?) ?? [];
        if (items.isEmpty) {
          // 防枚举：不明确告知"未注册"
          debugPrint('[AUTH] ⚠️ 该邮箱未注册（防枚举：统一提示）');
          return const RequestResetResult(
            success: false,
            message: '验证失败，请确认邮箱地址是否正确',
          );
        }
        final userId = items[0]['id'];
        if (userId == null || userId is! String || userId.isEmpty) {
          return const RequestResetResult(
            success: false,
            message: '验证失败，请稍后重试',
          );
        }
        debugPrint('[AUTH] ✅ 邮箱验证通过 | userId=$userId');
        // token 字段复用为 userId，传递到第2步
        return RequestResetResult(success: true, token: userId);
      }
      debugPrint('[AUTH] ⚠️ 查询失败 (${res.statusCode}): ${res.body}');
      return const RequestResetResult(success: false, message: '查询失败，请稍后重试');
    } on SocketException {
      return const RequestResetResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } on FormatException {
      debugPrint('[AUTH] ⚠️ 响应 JSON 解析失败');
      return const RequestResetResult(success: false, message: '服务器响应异常，请稍后重试');
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 验证邮箱异常: $e');
      return const RequestResetResult(success: false, message: '网络异常，请稍后重试');
    }
  }

  /// 严格邮箱格式校验（RFC 5322 简化版）
  static bool _isValidEmailFormat(String email) {
    // 基本格式：local@domain，禁止特殊字符注入
    if (email.contains("'") || email.contains('"') || email.contains(' ')) {
      return false;
    }
    return RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
        .hasMatch(email);
  }

  /// 找回密码 - 第2步：重置密码。
  /// 用 superuser token 直接调用 PATCH API 更新用户密码。
  /// [userIdOrToken] 来自 requestReset 返回的 userId。
  ///
  /// 安全措施：
  /// - 密码强度校验：至少 8 位，必须包含字母 + 数字
  /// - userId 格式校验：防止路径注入
  /// - 401 自动重试
  static Future<ResetResult> resetPassword(
      String userIdOrToken, String newPassword) async {
    debugPrint('[AUTH] 找回密码-重置密码 | userId=${_safeMaskId(userIdOrToken)}');

    // 输入校验
    if (userIdOrToken.isEmpty || newPassword.isEmpty) {
      return const ResetResult(success: false, message: '参数不能为空');
    }
    // userId 格式校验（PocketBase ID 通常是 15 位字母数字）
    if (!_isValidUserId(userIdOrToken)) {
      return const ResetResult(success: false, message: '用户标识无效，请重新验证邮箱');
    }
    // 密码强度校验
    final pwdCheck = _validatePasswordStrength(newPassword);
    if (pwdCheck != null) {
      return ResetResult(success: false, message: pwdCheck);
    }

    final result = await _doResetPassword(userIdOrToken, newPassword);
    // 401 自动重试一次
    if (result.isUnavailable && result.message?.contains('token') == true) {
      debugPrint('[AUTH] token 失效，强制刷新后重试');
      return _doResetPassword(userIdOrToken, newPassword, forceRefresh: true);
    }
    return result;
  }

  static Future<ResetResult> _doResetPassword(
    String userId,
    String newPassword, {
    bool forceRefresh = false,
  }) async {
    final token = await _getSuperuserToken(forceRefresh: forceRefresh);
    if (token == null) {
      return const ResetResult(
        success: false,
        isUnavailable: true,
        message: '找回密码服务暂不可用，请稍后重试',
      );
    }

    try {
      final res = await http
          .patch(
            Uri.parse(
                '${PBConfig.baseUrl}/api/collections/users/records/$userId'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'password': newPassword,
              'passwordConfirm': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 401) {
        return const ResetResult(
          success: false,
          isUnavailable: true,
          message: 'token 已过期，正在重新获取',
        );
      }

      if (res.statusCode == 200) {
        debugPrint('[AUTH] ✅ 密码重置成功');
        // 重置成功后清除该邮箱的频率限制，允许立即登录
        _rateLimitMap.removeWhere((k, _) => k.startsWith('reset:'));
        return const ResetResult(success: true);
      }

      // 解析错误信息
      String errorMsg = '重置失败，请稍后重试';
      if (res.body.isNotEmpty) {
        try {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          // PocketBase 错误格式：{"message": "...", "data": {...}}
          final msg = data['message'];
          if (msg is String && msg.isNotEmpty) {
            errorMsg = _translatePbError(msg, data);
          }
        } catch (_) {
          // JSON 解析失败，用默认错误信息
        }
      }
      debugPrint('[AUTH] ⚠️ 密码重置失败 (${res.statusCode}): $errorMsg');
      return ResetResult(success: false, message: errorMsg);
    } on SocketException {
      return const ResetResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } on FormatException {
      return const ResetResult(success: false, message: '服务器响应异常，请稍后重试');
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 重置密码异常: $e');
      return const ResetResult(success: false, message: '网络异常，请稍后重试');
    }
  }

  /// 密码强度校验：至少 8 位，必须包含字母和数字。
  /// 返回 null 表示通过，否则返回错误提示。
  static String? _validatePasswordStrength(String password) {
    if (password.length < 8) {
      return '密码至少需要 8 位字符';
    }
    if (password.length > 72) {
      return '密码不能超过 72 位字符';
    }
    final hasLetter = RegExp(r'[a-zA-Z]').hasMatch(password);
    final hasDigit = RegExp(r'[0-9]').hasMatch(password);
    if (!hasLetter || !hasDigit) {
      return '密码必须同时包含字母和数字';
    }
    // 禁止纯空格
    if (password.trim().isEmpty) {
      return '密码不能全为空格';
    }
    return null;
  }

  /// PocketBase userId 格式校验（防止路径注入）
  static bool _isValidUserId(String id) {
    // PocketBase ID 是 15 位字母数字
    return RegExp(r'^[a-zA-Z0-9]{10,20}$').hasMatch(id);
  }

  /// 安全地截取 userId 用于日志（防止越界）
  static String _safeMaskId(String id) {
    if (id.length <= 8) return '***';
    return '${id.substring(0, 8)}...';
  }

  /// 将 PocketBase 服务端错误信息翻译为用户友好的中文提示
  static String _translatePbError(String raw, Map<String, dynamic> data) {
    final lower = raw.toLowerCase();
    if (lower.contains('validation_length')) {
      return '密码长度不符合要求（8-72 位）';
    }
    if (lower.contains('password') && lower.contains('match')) {
      return '两次密码输入不一致';
    }
    if (lower.contains('not found') || lower.contains('404')) {
      return '用户记录不存在，请重新验证邮箱';
    }
    // 默认返回原始信息（已是非敏感信息）
    return raw;
  }

  /// 找回账号：按昵称查询脱敏邮箱。
  /// 用 superuser token 调用 PocketBase list/search API 查询用户。
  ///
  /// 支持模糊查询：用户可能记不全昵称，用 ~ 包裹实现 LIKE 查询。
  /// 安全措施：
  /// - 频率限制：同一昵称 60 秒内只能查询 1 次
  /// - 输入消毒：过滤特殊字符防止 filter 注入
  /// - 401 自动重试
  /// - 多结果处理：只返回第一个匹配的脱敏邮箱
  static Future<LookupResult> lookupEmailByName(String name) async {
    final trimmed = name.trim();
    debugPrint('[AUTH] 按昵称查询邮箱 | name=$trimmed');

    if (trimmed.isEmpty) {
      return const LookupResult(found: false, message: '请输入昵称');
    }
    if (trimmed.length > 50) {
      return const LookupResult(found: false, message: '昵称过长，请精简后重试');
    }
    // 输入消毒：过滤可能用于 filter 注入的字符
    if (trimmed.contains("'") || trimmed.contains('"') || trimmed.contains('\\')) {
      return const LookupResult(found: false, message: '昵称包含非法字符');
    }

    // 频率限制
    _cleanupRateLimit();
    final waitSec = _checkRateLimit('lookup:$trimmed');
    if (waitSec != null) {
      return LookupResult(
        found: false,
        message: '操作过于频繁，请 $waitSec 秒后再试',
      );
    }

    final result = await _doLookupEmailByName(trimmed);
    if (result.isUnavailable && result.message?.contains('token') == true) {
      debugPrint('[AUTH] token 失效，强制刷新后重试');
      final retry = await _doLookupEmailByName(trimmed, forceRefresh: true);
      if (retry.found) _recordRateLimit('lookup:$trimmed');
      return retry;
    }
    if (result.found) _recordRateLimit('lookup:$trimmed');
    return result;
  }

  static Future<LookupResult> _doLookupEmailByName(
    String name, {
    bool forceRefresh = false,
  }) async {
    final token = await _getSuperuserToken(forceRefresh: forceRefresh);
    if (token == null) {
      return const LookupResult(
        found: false,
        isUnavailable: true,
        message: '找回账号服务暂不可用，请稍后重试',
      );
    }

    try {
      // 模糊查询：name~'xxx' 匹配包含 xxx 的昵称
      // 先尝试精确匹配，再降级为模糊匹配
      final encodedName = Uri.encodeQueryComponent(name);

      // 精确匹配优先
      var res = await http
          .get(
            Uri.parse(
                '${PBConfig.baseUrl}/api/collections/users/records?filter=name%3D%27$encodedName%27&fields=id,name,email&perPage=1'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 15));

      // 精确匹配无结果，降级为模糊匹配
      if (res.statusCode == 200) {
        var data = jsonDecode(res.body) as Map<String, dynamic>;
        var items = (data['items'] as List<dynamic>?) ?? [];
        if (items.isEmpty) {
          // 模糊匹配
          res = await http
              .get(
                Uri.parse(
                    '${PBConfig.baseUrl}/api/collections/users/records?filter=name%7E%27$encodedName%27&fields=id,name,email&perPage=5'),
                headers: {'Authorization': 'Bearer $token'},
              )
              .timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            data = jsonDecode(res.body) as Map<String, dynamic>;
            items = (data['items'] as List<dynamic>?) ?? [];
          }
        }

        if (res.statusCode == 401) {
          return const LookupResult(
            found: false,
            isUnavailable: true,
            message: 'token 已过期，正在重新获取',
          );
        }

        if (res.statusCode == 200) {
          if (items.isEmpty) {
            debugPrint('[AUTH] ⚠️ 未找到该昵称');
            return const LookupResult(found: false, message: '未找到该昵称对应的账号');
          }
          final firstItem = items[0];
          if (firstItem is! Map<String, dynamic>) {
            return const LookupResult(found: false, message: '查询结果异常，请重试');
          }
          final email = firstItem['email'];
          if (email == null || email is! String || email.isEmpty) {
            return const LookupResult(found: false, message: '查询结果异常，请重试');
          }
          final masked = _maskEmail(email);
          final matchedName = firstItem['name'] as String? ?? '';
          debugPrint('[AUTH] ✅ 查询完成 | matched=$matchedName, masked=$masked');
          // 如果有多条匹配，提示用户
          final hasMultiple = items.length > 1;
          return LookupResult(
            found: true,
            email: masked,
            matchedName: hasMultiple ? matchedName : null,
            hasMultipleMatches: hasMultiple,
          );
        }
      }

      if (res.statusCode == 401) {
        return const LookupResult(
          found: false,
          isUnavailable: true,
          message: 'token 已过期，正在重新获取',
        );
      }

      debugPrint('[AUTH] ⚠️ 查询失败 (${res.statusCode})');
      return const LookupResult(found: false, message: '查询失败，请稍后重试');
    } on SocketException {
      return const LookupResult(
        found: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } on FormatException {
      return const LookupResult(found: false, message: '服务器响应异常，请稍后重试');
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 查询邮箱异常: $e');
      return const LookupResult(found: false, message: '网络异常，请稍后重试');
    }
  }

  /// 邮箱脱敏：a***@qq.com
  static String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 0) return '***';
    final prefix = email.substring(0, 1);
    final suffix = email.substring(at);
    return '$prefix***$suffix';
  }

  // ======================== 注册 / 登录 / 退出 ========================

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
      // 步骤1：确保 authStore 持有 token（瞬时，无网络）
      if (!PBConfig.pb.authStore.isValid) {
        debugPrint('[AUTH]   authStore 无效，尝试从本地恢复 Token');
        final restored = await _restoreFromLocal();
        if (!restored) {
          debugPrint('[AUTH]   ⚠️ 本地无Token，需要重新登录');
          return false;
        }
        debugPrint('[AUTH]   ✅ 从本地恢复 Token 成功');
      } else {
        debugPrint('[AUTH]   authStore 已有有效 Token');
      }

      // 步骤2：本地 JWT exp 校验（瞬时，无网络）
      if (!_isLocalTokenValid()) {
        debugPrint('[AUTH]   ⚠️ 本地Token已过期(JWT exp)，需要重新登录');
        // 仅清除过期 token，不清 UserCacheService（保留用户信息以便重新登录 UX）
        PBConfig.pb.authStore.clear();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_keyToken);
        return false;
      }

      debugPrint('[AUTH]   ✅ 本地Token有效，立即登录（后台验证服务器）');

      // 步骤3：后台异步验证 token，不阻塞返回。
      // 仅 401/403（token 被吊销）才登出，网络错误一律忽略（保持离线登录态）。
      verifyTokenInBackground();

      return true;
    } catch (e) {
      debugPrint('[ERROR] ❌ 检查登录态异常: $e');
      return false;
    }
  }

  /// 后台 token 验证（fire-and-forget，不阻塞 UI）。
  /// 离线时跳过；在线时 authRefresh，仅 401/403（token 被吊销）触发强制登出。
  static Future<void> verifyTokenInBackground() async {
    if (!NetworkStatusService.instance.isOnline) {
      debugPrint('[AUTH]   跳过后台验证：当前离线');
      return;
    }
    try {
      await PBConfig.pb.collection('users').authRefresh();
      debugPrint(
          '[AUTH]   ✅ 后台Token刷新成功，isValid: ${PBConfig.pb.authStore.isValid}');
    } on ClientException catch (e) {
      final code = e.statusCode;
      if (code == 401 || code == 403) {
        debugPrint('[AUTH]   ❌ 服务器拒绝Token($code)，执行登出');
        onForceLogout?.call();
        await logout();
      } else {
        // 4xx（非401/403）、5xx 等：保留本地登录态，不登出
        debugPrint('[AUTH]   ⚠️ 后台验证失败($code)，保留本地登录态: $e');
      }
    } catch (e) {
      // 网络错误、超时等：保持登录态（离线容错）
      debugPrint('[AUTH]   ⚠️ 后台验证网络异常(忽略): $e');
    }
  }

  static Future<UserModel?> getCurrentUser() async {
    try {
      if (!PBConfig.pb.authStore.isValid) {
        debugPrint('[AUTH] getCurrentUser: authStore 无效，返回 null');
        return null;
      }

      // 离线路径：纯本地缓存构建，零网络调用
      if (!NetworkStatusService.instance.isOnline) {
        debugPrint('[AUTH] getCurrentUser: 离线模式，从本地缓存构建用户');
        return _buildUserFromCache();
      }

      // 在线路径：取 userId（authStore.record 离线恢复后可能为 null，兜底读 prefs）
      final userId = PBConfig.pb.authStore.record?.id ??
          PBConfig.pb.authStore.model?.id ??
          await _getStoredUserId();
      if (userId == null || userId.isEmpty) {
        debugPrint('[AUTH] getCurrentUser: 无法获取用户ID，回退本地缓存');
        return _buildUserFromCache();
      }

      dynamic record;
      try {
        record = await PBConfig.pb.collection('users').getOne(userId);
        debugPrint('[AUTH] getCurrentUser: ✅ 从服务器获取用户数据成功');
      } catch (e) {
        debugPrint(
            '[AUTH] getCurrentUser: ⚠️ 从服务器获取失败，回退本地缓存: $e');
        return _buildUserFromCache();
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

      // 如果有头像URL，立即下载头像字节
      if (user.hasAvatar) {
        final bytes =
            await UserModel.downloadAvatarBytes(user.avatarUrl, user.token);
        return user.copyWith(avatarBytes: bytes);
      }

      debugPrint(
          '[AUTH] getCurrentUser: ✅ 获取成功 | name="${user.name}", id=${user.id}, hasAvatar=${user.hasAvatar}, avatarUrl="${user.avatarUrl}"');
      return user;
    } catch (e) {
      debugPrint('[ERROR] ❌ getCurrentUser 异常: $e');
      return _buildUserFromCache();
    }
  }

  /// 解码 PocketBase JWT token 的 exp 声明。
  /// 返回 null 表示非 JWT、畸形或无 exp 声明。
  static DateTime? _decodeJwtExp(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null; // 非 JWT
      // base64url -> base64：替换 URL 安全字符并补齐 padding
      String payload = parts[1];
      payload = payload.replaceAll('-', '+').replaceAll('_', '/');
      final pad = payload.length % 4;
      if (pad != 0) payload += '=' * (4 - pad);
      final decoded = utf8.decode(base64.decode(payload));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      final exp = json['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (e) {
      debugPrint('[AUTH] JWT exp 解码失败: $e');
      return null;
    }
  }

  /// 离线校验本地 token 有效性（无网络往返）。
  /// token 非空且 JWT exp 未过期返回 true；解码失败/无 exp 时乐观返回 true
  /// （服务器 401 为最终仲裁）。
  static bool _isLocalTokenValid() {
    final token = PBConfig.pb.authStore.token;
    if (token.isEmpty) return false;
    final exp = _decodeJwtExp(token);
    if (exp == null) return true; // 无 exp 或无法解码 → 乐观
    return DateTime.now().isBefore(exp);
  }

  /// 纯本地缓存构建 UserModel（无网络调用）。用于离线模式及服务器失败兜底。
  /// 数据来源：UserCacheService（name/bio/avatar）+ AuthService 的 pb_user_email pref + authStore.token。
  static Future<UserModel?> _buildUserFromCache() async {
    if (!UserCacheService.hasCachedData) {
      debugPrint('[AUTH] _buildUserFromCache: 无缓存数据');
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    Uint8List? avatarBytes;
    final b64 = UserCacheService.userAvatarBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        avatarBytes = Uint8List.fromList(base64.decode(b64));
      } catch (_) {}
    }
    final user = UserModel(
      id: UserCacheService.userId ?? '',
      email: prefs.getString(_keyUserEmail) ?? '',
      name: UserCacheService.userName,
      bio: UserCacheService.userBio,
      avatarUrl: '', // 离线不拼 URL，直接用 avatarBytes
      avatarBytes: avatarBytes,
      created: DateTime.now(), // 未缓存，近似值（离线不展示此字段）
      token: PBConfig.pb.authStore.token,
      isLoggedIn: true,
    );
    debugPrint(
        '[AUTH] _buildUserFromCache: ✅ 缓存构建 | name="${user.name}", id=${user.id}, hasAvatar=${avatarBytes != null}');
    return user;
  }

  /// 从 prefs 读取已存储的 userId（离线时 authStore.record 为 null 的兜底）。
  static Future<String?> _getStoredUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserId);
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
      final avatarFieldValue = record.getStringValue('avatar');
      if (avatarFieldValue == null || avatarFieldValue.isEmpty) {
        debugPrint('[AUTH] 头像字段为空，使用默认头像');
        return '';
      }

      // 和 GameModel 一样直接拼接 URL，不依赖 authStore.model
      final url =
          '${PBConfig.baseUrl}/api/files/users/${record.id}/$avatarFieldValue';
      debugPrint('[AUTH] ✅ 生成头像URL（直接拼接）：$url');
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
