import 'dart:async';
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
import 'remember_me_store.dart';

class AuthService {
  static const String _keyToken = 'pb_auth_token';
  static const String _keyUserId = 'pb_user_id';
  static const String _keyUserName = 'pb_user_name';
  static const String _keyUserEmail = 'pb_user_email';

  // ── 找回密码/找回账号：2026-10-02 起全部改走服务端 Hook ──
  // （/api/ct/request-reset-otp → verify-reset-otp → reset-password，
  //   /api/ct/lookup-email-by-name），客户端不再持有任何 superuser 凭证。
  // 原因：原实现把混淆的 superuser 账密随 app 分发 + HTTP 明文传输，
  // 抓包/逆向即可完全接管 PocketBase，属 P0 安全漏洞（本次消灭）。

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

  static Future<AuthResult> login(String email, String password,
      {bool remember = true}) async {
    // ★ P3：日志脱敏，避免完整邮箱（属个人敏感信息）写入调试日志/崩溃上报
    debugPrint('[AUTH] 开始请求PocketBase登录 | email=${_maskEmail(email)}');
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

      // 「记住登录」（2026-10-03）：凭证经 DPAPI 加密落盘，供 token 过期后
      // 静默重登与登录页快速登录；未勾选时清除旧凭证（不留残留）。
      if (remember) {
        await RememberMeStore.save(email, password);
      } else {
        await RememberMeStore.clear();
      }

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

  // ======================== 找回密码（邮箱验证码 OTP，服务端 Hook） ========================
  // 三步流程（2026-10-02 起，与注册验证码同构）：
  //   ① requestResetOtp(email)                      → { otpId }
  //   ② verifyResetOtp(otpId, code)                 → { resetToken }
  //   ③ resetPasswordWithToken(resetToken, newPwd)  → 服务端改密+踢旧会话
  // 密码重置在服务端以超管通道完成，客户端零管理员凭证。

  /// 找回密码 - 第1步：请求邮箱验证码（走 /api/ct/request-reset-otp）。
  ///
  /// 安全措施（服务端负责）：未注册邮箱 404 明确提示（帮助用户发现填错）、
  /// 60s 重发冷却、验证码 HMAC 摘要存储、180s 有效。
  static Future<ResetOtpRequestResult> requestResetOtp(String email) async {
    final trimmed = email.trim();
    debugPrint('[AUTH] 找回密码-请求验证码 | email=${_maskEmail(trimmed)}');

    if (trimmed.isEmpty) {
      return const ResetOtpRequestResult(success: false, message: '请输入邮箱地址');
    }
    if (trimmed.length > 254) {
      return const ResetOtpRequestResult(success: false, message: '邮箱地址过长');
    }
    if (!_isValidEmailFormat(trimmed)) {
      return const ResetOtpRequestResult(success: false, message: '邮箱格式不正确');
    }

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/request-reset-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': trimmed}),
          )
          // 🔴 服务端同步发信，偶发 SMTP 抖动可达 50s+（同注册验证码接口，
          //    2026-09-30 实测 51.79s）→ 超时留足 90s，防止「服务端发信成功
          //    但客户端先报错」。
          .timeout(const Duration(seconds: 90));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final otpId = (data['otpId'] ?? '').toString();
        if (otpId.isEmpty) {
          return const ResetOtpRequestResult(
            success: false,
            message: '服务器响应异常，请稍后重试',
          );
        }
        debugPrint('[AUTH] ✅ 重置验证码已发送');
        return ResetOtpRequestResult(
          success: true,
          otpId: otpId,
          expiresInSeconds:
              (data['expiresInSeconds'] as num?)?.toInt() ?? 180,
        );
      }

      // 404：该邮箱未注册（服务端明确提示；区分「接口未部署」的裸 404）
      if (res.statusCode == 404) {
        final data = _tryDecodeJson(res.body);
        final code = (data?['code'] ?? '').toString();
        if (code == 'email_not_found') {
          debugPrint('[AUTH] ⚠️ 该邮箱未注册');
          return const ResetOtpRequestResult(
            success: false,
            emailNotFound: true,
            message: '该邮箱未注册，请检查输入，或先注册账号',
          );
        }
        return const ResetOtpRequestResult(
          success: false,
          isUnavailable: true,
          message: '找回密码服务暂不可用，请稍后重试',
        );
      }

      // 429：频率限制
      if (res.statusCode == 429) {
        final data = _tryDecodeJson(res.body);
        final wait = (data?['retryAfterSeconds'] as num?)?.toInt() ?? 60;
        debugPrint('[AUTH] ⚠️ 请求过于频繁，需等待 $wait 秒');
        return ResetOtpRequestResult(
          success: false,
          retryAfterSeconds: wait,
          message: data?['message']?.toString() ?? '请求过于频繁，请 $wait 秒后再试',
        );
      }

      // 其它 4xx/5xx：取服务端 message
      final data = _tryDecodeJson(res.body);
      final msg = data?['message']?.toString();
      debugPrint('[AUTH] ⚠️ 请求验证码失败 (${res.statusCode}): $msg');
      return ResetOtpRequestResult(
        success: false,
        message: msg?.isNotEmpty == true ? msg! : '验证码发送失败，请稍后重试',
      );
    } on SocketException {
      return const ResetOtpRequestResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } on TimeoutException {
      // 同注册验证码：超时 ≠ 网络断，服务端可能仍在投递（90s 预算先到）
      return const ResetOtpRequestResult(
        success: false,
        message: '邮件发送超时，请稍等片刻后再试',
      );
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 请求验证码异常: $e');
      return const ResetOtpRequestResult(
        success: false,
        message: '网络异常，请稍后重试',
      );
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

  /// 找回密码 - 第2步：校验验证码，换取重置令牌。
  /// 走 /api/ct/verify-reset-otp（服务端验码 + 防爆破 + 一次性消费）。
  static Future<ResetOtpVerifyResult> verifyResetOtp(
      String otpId, String code) async {
    final trimmedId = otpId.trim();
    final trimmedCode = code.trim();
    debugPrint('[AUTH] 找回密码-校验验证码 | otpId=${_safeMaskId(trimmedId)}');

    if (trimmedId.isEmpty || trimmedCode.isEmpty) {
      return const ResetOtpVerifyResult(
        success: false,
        message: '请先获取验证码并填写',
      );
    }

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/verify-reset-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'otpId': trimmedId, 'code': trimmedCode}),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final resetToken = (data['resetToken'] ?? '').toString();
        if (resetToken.isEmpty) {
          return const ResetOtpVerifyResult(
            success: false,
            message: '服务器响应异常，请稍后重试',
          );
        }
        debugPrint('[AUTH] ✅ 验证码校验通过，已获取重置令牌');
        return ResetOtpVerifyResult(
          success: true,
          resetToken: resetToken,
          email: (data['email'] ?? '').toString(),
        );
      }

      if (res.statusCode == 404) {
        return const ResetOtpVerifyResult(
          success: false,
          isUnavailable: true,
          message: '找回密码服务暂不可用，请稍后重试',
        );
      }

      final data = _tryDecodeJson(res.body);
      final msg = data?['message']?.toString();
      debugPrint('[AUTH] ⚠️ 校验验证码失败 (${res.statusCode}): $msg');
      return ResetOtpVerifyResult(
        success: false,
        message: msg?.isNotEmpty == true ? msg! : '验证码校验失败，请重新获取',
      );
    } on SocketException {
      return const ResetOtpVerifyResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 校验验证码异常: $e');
      return const ResetOtpVerifyResult(
        success: false,
        message: '网络异常，请稍后重试',
      );
    }
  }

  /// 找回密码 - 第3步：凭重置令牌设置新密码。
  /// 走 /api/ct/reset-password（服务端超管通道改密 + 轮换 tokenKey 踢旧会话）。
  static Future<ResetPasswordResult> resetPasswordWithToken(
      String resetToken, String newPassword) async {
    debugPrint('[AUTH] 找回密码-重置密码 | token=${_safeMaskId(resetToken)}');

    if (resetToken.isEmpty || newPassword.isEmpty) {
      return const ResetPasswordResult(success: false, message: '参数不能为空');
    }
    // 密码强度校验（与服务端规则一致）
    final pwdCheck = _validatePasswordStrength(newPassword);
    if (pwdCheck != null) {
      return ResetPasswordResult(success: false, message: pwdCheck);
    }

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/reset-password'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'resetToken': resetToken,
              'newPassword': newPassword,
              'passwordConfirm': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        debugPrint('[AUTH] ✅ 密码重置成功');
        // 重置成功后清除该邮箱的频率限制，允许立即登录
        _rateLimitMap.removeWhere((k, _) => k.startsWith('reset:'));
        return const ResetPasswordResult(success: true);
      }

      if (res.statusCode == 404) {
        return const ResetPasswordResult(
          success: false,
          isUnavailable: true,
          message: '找回密码服务暂不可用，请稍后重试',
        );
      }

      final data = _tryDecodeJson(res.body);
      final msg = data?['message']?.toString();
      debugPrint('[AUTH] ⚠️ 密码重置失败 (${res.statusCode}): $msg');
      return ResetPasswordResult(
        success: false,
        message: msg?.isNotEmpty == true ? msg! : '重置失败，请稍后重试',
      );
    } on SocketException {
      return const ResetPasswordResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 重置密码异常: $e');
      return const ResetPasswordResult(success: false, message: '网络异常，请稍后重试');
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

  /// 安全地截取 ID 用于日志（防止越界）
  static String _safeMaskId(String id) {
    if (id.length <= 8) return '***';
    return '${id.substring(0, 8)}...';
  }

  /// 找回账号：按昵称查询脱敏邮箱（2026-10-02 起走服务端 Hook）。
  /// /api/ct/lookup-email-by-name：服务端查询 + 服务端脱敏（首字符***@域名），
  /// 客户端只拿脱敏结果，不再持任何管理员凭证。
  /// 频率限制仍由客户端负责（同一昵称 60 秒 1 次）。
  static Future<LookupResult> lookupEmailByName(String name) async {
    final trimmed = name.trim();
    debugPrint('[AUTH] 按昵称查询邮箱 | name=$trimmed');

    if (trimmed.isEmpty) {
      return const LookupResult(found: false, message: '请输入昵称');
    }
    if (trimmed.length > 50) {
      return const LookupResult(found: false, message: '昵称过长，请精简后重试');
    }
    // 输入消毒：过滤可能用于 filter 注入的字符（服务端也做一层，双保险）
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

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/lookup-email-by-name'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'name': trimmed}),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final found = data['found'] == true;
        _recordRateLimit('lookup:$trimmed');
        if (!found) {
          return LookupResult(
            found: false,
            message: data['message']?.toString() ?? '未找到该昵称对应的账号',
          );
        }
        final masked = (data['email'] ?? '').toString();
        if (masked.isEmpty) {
          return const LookupResult(found: false, message: '查询结果异常，请重试');
        }
        final hasMultiple = data['hasMultipleMatches'] == true;
        debugPrint('[AUTH] ✅ 查询完成 | masked=$masked');
        return LookupResult(
          found: true,
          email: masked,
          matchedName:
              hasMultiple ? (data['matchedName']?.toString() ?? '') : null,
          hasMultipleMatches: hasMultiple,
        );
      }

      if (res.statusCode == 404) {
        return const LookupResult(
          found: false,
          isUnavailable: true,
          message: '找回账号服务暂不可用，请稍后重试',
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

  /// 注册 - 第1步：请求邮箱验证码。
  ///
  /// 走 Hook 自建的 `/api/ct/request-register-otp`（**不是** PB 内置的
  /// `users/request-otp`）。原因：内置接口只对「已存在的用户」发码，
  /// 新用户注册时邮箱必然不存在 → 永远收不到验证码（2026-09-30 实测确认）。
  ///
  /// 成功时返回 `otpId`，供第2步 [verifyRegisterOtp] 校验使用。
  static Future<RegisterOtpRequestResult> requestRegisterOtp(
      String email) async {
    final trimmed = email.trim();
    debugPrint('[AUTH] 注册-请求验证码 | email=${_maskEmail(trimmed)}');

    if (trimmed.isEmpty) {
      return const RegisterOtpRequestResult(
        success: false,
        message: '请输入邮箱地址',
      );
    }
    if (!_isValidEmailFormat(trimmed)) {
      return const RegisterOtpRequestResult(
        success: false,
        message: '邮箱格式不正确',
      );
    }

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/request-register-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': trimmed}),
          )
          // 🔴 超时必须留足：此接口在服务端**同步**发信（$app.newMailClient().send()）。
          //    实测常态 1.7–4.5s，但偶发 SMTP 抖动可达 50s+（2026-09-30 实测 51.79s）。
          //    若超时设 30s，会在服务端最终发信成功的情况下先报错 →
          //    用户以为失败、实际收到邮件（还会撞上 60s 冷却）。
          .timeout(const Duration(seconds: 90));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final otpId = (data['otpId'] ?? '').toString();
        if (otpId.isEmpty) {
          return const RegisterOtpRequestResult(
            success: false,
            message: '服务器响应异常，请稍后重试',
          );
        }
        debugPrint('[AUTH] ✅ 注册验证码已发送');
        return RegisterOtpRequestResult(
          success: true,
          otpId: otpId,
          expiresInSeconds:
              (data['expiresInSeconds'] as num?)?.toInt() ?? 180,
        );
      }

      // 409：该邮箱已被注册（决策 A：明确提示）
      if (res.statusCode == 409) {
        debugPrint('[AUTH] ⚠️ 该邮箱已被注册');
        return const RegisterOtpRequestResult(
          success: false,
          emailAlreadyExists: true,
          message: '该邮箱已被注册，请直接登录',
        );
      }

      // 429：频率限制
      if (res.statusCode == 429) {
        final data = _tryDecodeJson(res.body);
        final wait = (data?['retryAfterSeconds'] as num?)?.toInt() ?? 60;
        debugPrint('[AUTH] ⚠️ 请求过于频繁，需等待 $wait 秒');
        return RegisterOtpRequestResult(
          success: false,
          retryAfterSeconds: wait,
          message: data?['message']?.toString() ?? '请求过于频繁，请 $wait 秒后再试',
        );
      }

      // 404：接口未部署（Hook 未加载）
      if (res.statusCode == 404) {
        return const RegisterOtpRequestResult(
          success: false,
          isUnavailable: true,
          message: '注册验证码服务暂不可用，请稍后重试',
        );
      }

      // 其它 4xx/5xx：取服务端 message
      final data = _tryDecodeJson(res.body);
      final msg = data?['message']?.toString();
      debugPrint('[AUTH] ⚠️ 请求验证码失败 (${res.statusCode}): $msg');
      return RegisterOtpRequestResult(
        success: false,
        message: msg?.isNotEmpty == true ? msg! : '验证码发送失败，请稍后重试',
      );
    } on SocketException {
      return const RegisterOtpRequestResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } on TimeoutException {
      // 服务端同步发信，偶发 SMTP 抖动可达 50s+；90s 超时先到时服务端可能
      // 仍在投递 → 不能误导为「网络异常」（2026-10-03 用户反馈：误判网络错误）。
      // 重新获取会签发新码（旧码服务端 3 分钟后自然过期），安全。
      return const RegisterOtpRequestResult(
        success: false,
        message: '邮件发送超时，请稍等片刻后点「重新获取」再试',
      );
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 请求验证码异常: $e');
      return const RegisterOtpRequestResult(
        success: false,
        message: '网络异常，请稍后重试',
      );
    }
  }

  /// 注册 - 第2步：校验验证码，换取注册令牌。
  ///
  /// 成功时返回 `regToken`，提交注册时通过请求体 `regToken` 字段回传
  /// （⛔ 不用请求头：Hook 的 header 读取修复尚未部署，body 路径已验证可用）。
  static Future<RegisterOtpVerifyResult> verifyRegisterOtp(
      String otpId, String code) async {
    final trimmedId = otpId.trim();
    final trimmedCode = code.trim();
    debugPrint('[AUTH] 注册-校验验证码 | otpId=${_safeMaskId(trimmedId)}');

    if (trimmedId.isEmpty || trimmedCode.isEmpty) {
      return const RegisterOtpVerifyResult(
        success: false,
        message: '请先获取验证码并填写',
      );
    }

    try {
      final res = await http
          .post(
            Uri.parse('${PBConfig.baseUrl}/api/ct/verify-register-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'otpId': trimmedId, 'code': trimmedCode}),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final regToken = (data['regToken'] ?? '').toString();
        if (regToken.isEmpty) {
          return const RegisterOtpVerifyResult(
            success: false,
            message: '服务器响应异常，请稍后重试',
          );
        }
        debugPrint('[AUTH] ✅ 验证码校验通过，已获取注册令牌');
        return RegisterOtpVerifyResult(
          success: true,
          regToken: regToken,
          email: (data['email'] ?? '').toString(),
        );
      }

      if (res.statusCode == 404) {
        return const RegisterOtpVerifyResult(
          success: false,
          isUnavailable: true,
          message: '注册验证码服务暂不可用，请稍后重试',
        );
      }

      final data = _tryDecodeJson(res.body);
      final msg = data?['message']?.toString();
      debugPrint('[AUTH] ⚠️ 校验验证码失败 (${res.statusCode}): $msg');
      return RegisterOtpVerifyResult(
        success: false,
        message: msg?.isNotEmpty == true ? msg! : '验证码校验失败，请重新获取',
      );
    } on SocketException {
      return const RegisterOtpVerifyResult(
        success: false,
        isUnavailable: true,
        message: '无法连接服务器，请检查网络',
      );
    } catch (e) {
      debugPrint('[AUTH] ⚠️ 校验验证码异常: $e');
      return const RegisterOtpVerifyResult(
        success: false,
        message: '网络异常，请稍后重试',
      );
    }
  }

  /// 安全解析 JSON（失败返回 null，不抛异常）
  static Map<String, dynamic>? _tryDecodeJson(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Future<AuthResult> register(
    String email,
    String password,
    String name, {
    String? regToken,
  }) async {
    // ★ P3：日志脱敏
    debugPrint(
        '[AUTH] 开始请求PocketBase注册 | email=${_maskEmail(email)}, name=$name');
    try {
      final body = <String, dynamic>{
        'email': email,
        'password': password,
        'passwordConfirm': password,
        'name': name,
      };
      // ★ 注册令牌：由 verifyRegisterOtp 签发，Hook 校验通过才允许落库。
      //   走请求体（⛔ 不用请求头，理由见 verifyRegisterOtp 注释）。
      if (regToken != null && regToken.isNotEmpty) {
        body['regToken'] = regToken;
      }

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
        // ★ 注册令牌相关错误（Hook 抛出的 BadRequestError）：
        //   服务端 message 形如「注册需要邮箱验证码…」「注册令牌无效…」等，
        //   直接透传给用户，比笼统的「注册信息有误」更有指导意义。
        final serverMsg = _extractServerMessage(e.response);
        if (serverMsg != null &&
            (serverMsg.contains('验证码') || serverMsg.contains('注册令牌'))) {
          debugPrint('[ERROR] ❌ 注册失败 (400): $serverMsg | raw: $e');
          return AuthResult.failure(AuthResultCode.unknownError, serverMsg);
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

  /// 从 PocketBase ClientException 响应中提取服务端 message 文本。
  /// PB 的 400 响应形如 {"message":"...","data":{...}}，message 为顶层字段。
  static String? _extractServerMessage(dynamic response) {
    try {
      if (response is Map<String, dynamic>) {
        final m = response['message'];
        if (m is String && m.isNotEmpty) {
          // PB 会在自定义错误消息末尾附加一个句点，去掉更整洁
          return m.replaceAll(RegExp(r'\.$'), '');
        }
      }
    } catch (_) {}
    return null;
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

    // 「记住登录」：主动退出 = 明确不想保持登录，清除加密凭证
    // （与 token 过期的静默重登场景区分——那才是记住凭证的用武之地）
    await RememberMeStore.clear();

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
        debugPrint('[AUTH]   ⚠️ 本地Token已过期(JWT exp)');
        // 「记住登录」（2026-10-03）：token 过期后用本地加密凭证静默重登，
        // 满足「以月为周期不要求重新登录」——即使超过 authDuration 未打开
        // 软件，只要记住过登录就能无感恢复在线态。
        final silentOk = await _trySilentRelogin();
        if (silentOk) return true;
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

  /// 「记住登录」静默重登：token 过期时用本地 DPAPI 加密凭证自动登录。
  ///
  /// - 离线时跳过（保持本地游客态，下次联网启动再试）；
  /// - 成功 → 无感恢复在线态，返回 true；
  /// - 凭证失效（密码已改/账号已删）→ 清除凭证，返回 false；
  /// - 网络等临时错误 → 保留凭证，返回 false（下次再试）。
  static Future<bool> _trySilentRelogin() async {
    if (!NetworkStatusService.instance.isOnline) {
      debugPrint('[AUTH]   离线，跳过静默重登');
      return false;
    }
    final cred = await RememberMeStore.load();
    if (cred == null) return false;
    debugPrint('[AUTH]   尝试静默重登 | email=${_maskEmail(cred.email)}');
    final result = await login(cred.email, cred.password, remember: true);
    if (result.code == AuthResultCode.success) {
      debugPrint('[AUTH]   ✅ 静默重登成功，无感恢复在线态');
      return true;
    }
    if (result.code == AuthResultCode.invalidCredentials ||
        result.code == AuthResultCode.userNotFound) {
      // 凭证确定失效（而非网络抖动）：清除，避免下次继续撞错
      debugPrint('[AUTH]   ⚠️ 记住的凭证已失效，清除');
      await RememberMeStore.clear();
    }
    return false;
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
      // 🔴 新 token 必须回写本地持久化（2026-10-03 修复「一段时间不用就掉线」）：
      //    authRefresh 签发的新 token 此前只存在于内存 authStore，下次启动
      //    _restoreFromLocal 恢复的仍是首次登录时的旧 token——超过服务端
      //    authDuration 后本地 JWT 校验即拦截，强制要求重新登录。
      //    回写后：每次打开软件都续期，只要两个有效期内开过一次就永不断线。
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyToken, PBConfig.pb.authStore.token);
      } catch (_) {}
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
}
