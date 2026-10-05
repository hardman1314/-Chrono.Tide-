import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/remember_me_store.dart';
import '../modules/auth/user_model.dart';
import '../pages/login/forgot_password_dialog.dart';
import 'app_snack_bar.dart';
import 'interactive_wrapper.dart';
import 'remember_me_checkbox.dart';

enum AuthMode { login, register }

class AuthModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLoginSuccess;
  const AuthModal(
      {super.key, required this.onClose, required this.onLoginSuccess});

  @override
  State<AuthModal> createState() => _AuthModalState();
}

class _AuthModalState extends State<AuthModal> {
  AuthMode _mode = AuthMode.login;
  bool _isLoading = false;
  String? _errorMessage;

  final _loginUidController = TextEditingController();
  final _loginPasswordController = TextEditingController();
  final _registerNicknameController = TextEditingController();
  final _registerEmailController = TextEditingController();
  final _registerPasswordController = TextEditingController();
  final _registerConfirmPasswordController = TextEditingController();
  // ★ 注册邮箱验证码（2026-09-30 新增）
  final _registerOtpController = TextEditingController();

  // UX-04: 密码可见性切换状态
  bool _loginPwdVisible = false;
  bool _regPwdVisible = false;
  bool _regConfirmPwdVisible = false;

  // ★ 注册验证码状态
  String? _regOtpId;
  bool _regSendingOtp = false;
  int _regResendCountdown = 0;
  Timer? _regResendTimer;

  // UX-05: 字段级实时验证错误
  String? _loginEmailError;
  String? _regNameError;
  String? _regEmailError;
  String? _regPasswordError;
  String? _regConfirmError;

  // 「记住登录」（2026-10-03）：默认勾选——token 过期后静默重登的前提
  bool _rememberMe = true;
  // 本地记住的凭证（有则登录表单顶部提供「快速登录」一键入口）
  RememberedCredentials? _remembered;

  @override
  void initState() {
    super.initState();
    RememberMeStore.load().then((cred) {
      if (cred != null && mounted) setState(() => _remembered = cred);
    });
  }

  /// 「快速登录」：直接使用本地记住的凭证登录（一键，免输入）
  Future<void> _handleQuickLogin() async {
    final cred = _remembered;
    if (cred == null || _isLoading) return;
    debugPrint('[ACTION] 快速登录 | email=${cred.email}');
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final result = await AuthService.login(cred.email, cred.password);
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (result.code == AuthResultCode.success) {
      widget.onLoginSuccess();
      widget.onClose();
    } else {
      // 凭证失效（密码已改等）：清除快捷入口，提示走普通登录
      if (result.code == AuthResultCode.invalidCredentials ||
          result.code == AuthResultCode.userNotFound) {
        await RememberMeStore.clear();
        if (mounted) setState(() => _remembered = null);
      }
      setState(() => _errorMessage = result.message);
    }
  }

  void _toggleMode() {
    setState(() {
      _mode = _mode == AuthMode.login ? AuthMode.register : AuthMode.login;
      _errorMessage = null;
      // UX-05: 切换模式时清空所有字段级错误
      _loginEmailError = null;
      _regNameError = null;
      _regEmailError = null;
      _regPasswordError = null;
      _regConfirmError = null;
    });
  }

  /// ★ 邮箱变更时使已获取的验证码失效（防止「换邮箱后复用旧码」）
  void _invalidateRegOtpIfEmailChanged() {
    if (_regOtpId == null) return;
    setState(() {
      _regOtpId = null;
      _registerOtpController.clear();
      _regResendCountdown = 0;
      _regResendTimer?.cancel();
      _regResendTimer = null;
    });
  }

  /// ★ 第1步：请求邮箱验证码
  Future<void> _handleRequestRegOtp() async {
    if (_regSendingOtp || _isLoading || _regResendCountdown > 0) return;
    final email = _registerEmailController.text.trim();
    if (email.isEmpty) {
      setState(() => _regEmailError = '请先输入邮箱地址');
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _regEmailError = '邮箱格式不正确');
      return;
    }

    setState(() {
      _regSendingOtp = true;
      _errorMessage = null;
      _regEmailError = null;
    });

    // 预期管理：服务端同步发信，偶发 SMTP 抖动可达 50s+（2026-10-03 用户反馈
    // 「卡在发送中很长时间」），提前说明避免用户误以为卡死而反复点击。
    AppSnackBar.info(
        context, '验证邮件发送中，网络较慢时可能需要约 1 分钟，请耐心等待…');

    final result = await AuthService.requestRegisterOtp(email);

    if (!mounted) return;

    if (result.success) {
      setState(() {
        _regSendingOtp = false;
        _regOtpId = result.otpId;
        _errorMessage = null;
      });
      _startRegResendCountdown(
          result.retryAfterSeconds > 0 ? result.retryAfterSeconds : 60);
    } else {
      setState(() {
        _regSendingOtp = false;
        _errorMessage = result.message;
      });
      if (result.retryAfterSeconds > 0) {
        _startRegResendCountdown(result.retryAfterSeconds);
      }
    }
  }

  /// 启动重发倒计时
  void _startRegResendCountdown(int seconds) {
    _regResendTimer?.cancel();
    setState(() => _regResendCountdown = seconds);
    _regResendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _regResendCountdown--;
        if (_regResendCountdown <= 0) {
          _regResendCountdown = 0;
          timer.cancel();
          _regResendTimer = null;
        }
      });
    });
  }

  // === UX-05: 实时字段验证 ===

  void _validateLoginEmail(String value) {
    setState(() {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        _loginEmailError = null;
      } else if (!_isValidEmail(trimmed)) {
        _loginEmailError = '邮箱格式不正确';
      } else {
        _loginEmailError = null;
      }
    });
  }

  void _validateRegName(String value) {
    setState(() {
      _regNameError = value.trim().isEmpty ? '请输入昵称' : null;
    });
  }

  void _validateRegEmail(String value) {
    setState(() {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        _regEmailError = null;
      } else if (!_isValidEmail(trimmed)) {
        _regEmailError = '邮箱格式不正确';
      } else {
        _regEmailError = null;
      }
    });
  }

  void _validateRegPassword(String value) {
    setState(() {
      if (value.isEmpty) {
        _regPasswordError = null;
      } else if (value.length < 6) {
        _regPasswordError = '密码至少需要6位字符';
      } else {
        _regPasswordError = null;
      }
      // 密码变化时同步校验确认密码
      final confirm = _registerConfirmPasswordController.text;
      if (confirm.isNotEmpty) {
        _regConfirmError = confirm != value ? '两次输入的密码不一致' : null;
      }
    });
  }

  void _validateRegConfirm(String value) {
    setState(() {
      if (value.isEmpty) {
        _regConfirmError = null;
      } else if (value != _registerPasswordController.text) {
        _regConfirmError = '两次输入的密码不一致';
      } else {
        _regConfirmError = null;
      }
    });
  }

  Future<void> _handleSubmit() async {
    if (_isLoading) return;

    if (_mode == AuthMode.login) {
      await _handleLogin();
    } else {
      await _handleRegister();
    }
  }

  Future<void> _handleLogin() async {
    final email = _loginUidController.text.trim();
    final password = _loginPasswordController.text.trim();

    // UX-05: 提交时触发字段级验证
    setState(() {
      _loginEmailError = email.isEmpty
          ? '请输入邮箱地址'
          : (!_isValidEmail(email) ? '邮箱格式不正确' : null);
      _errorMessage = null;
    });
    if (_loginEmailError != null) return;
    if (password.isEmpty) {
      setState(() => _errorMessage = '请输入密码');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result =
        await AuthService.login(email, password, remember: _rememberMe);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.code == AuthResultCode.success) {
      widget.onLoginSuccess();
      widget.onClose();
    } else {
      setState(() => _errorMessage = result.message);
    }
  }

  Future<void> _handleRegister() async {
    final name = _registerNicknameController.text.trim();
    final email = _registerEmailController.text.trim();
    final password = _registerPasswordController.text.trim();
    final confirmPassword = _registerConfirmPasswordController.text.trim();
    final otpCode = _registerOtpController.text.trim();

    // UX-05: 提交时触发字段级验证
    setState(() {
      _regNameError = name.isEmpty ? '请输入昵称' : null;
      _regEmailError = email.isEmpty
          ? '请输入邮箱地址'
          : (!_isValidEmail(email) ? '邮箱格式不正确' : null);
      _regPasswordError = password.length < 6 ? '密码至少需要6位字符' : null;
      _regConfirmError = password != confirmPassword ? '两次输入的密码不一致' : null;
      _errorMessage = null;
    });
    if (_regNameError != null ||
        _regEmailError != null ||
        _regPasswordError != null ||
        _regConfirmError != null) {
      return;
    }

    // ★ 验证码前置校验
    if (_regOtpId == null || _regOtpId!.isEmpty) {
      setState(() => _errorMessage = '请先获取邮箱验证码');
      return;
    }
    if (otpCode.isEmpty) {
      setState(() => _errorMessage = '请输入邮箱验证码');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // ★ 第2步：校验验证码换注册令牌
    final verifyResult =
        await AuthService.verifyRegisterOtp(_regOtpId!, otpCode);

    if (!mounted) return;

    if (!verifyResult.success) {
      setState(() {
        _isLoading = false;
        _errorMessage = verifyResult.message;
        // 验证码已过期/作废 → 清空状态，要求重新获取
        if (verifyResult.message?.contains('过期') == true ||
            verifyResult.message?.contains('错误次数') == true) {
          _regOtpId = null;
          _registerOtpController.clear();
          _regResendCountdown = 0;
          _regResendTimer?.cancel();
          _regResendTimer = null;
        }
      });
      return;
    }

    // ★ 第3步：带令牌提交注册
    final result = await AuthService.register(
      email,
      password,
      name,
      regToken: verifyResult.regToken,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.code == AuthResultCode.success) {
      widget.onLoginSuccess();
      widget.onClose();
    } else {
      setState(() => _errorMessage = result.message);
    }
  }

  /// 显示找回密码对话框（复用 ForgotPasswordDialog 统一组件）。
  void _showForgotPasswordDialog() {
    ForgotPasswordDialog.show(context);
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.+]+@([\w-]+\.)+[\w-]{2,8}$').hasMatch(email);
  }

  @override
  void dispose() {
    // ★ 清理重发倒计时定时器
    _regResendTimer?.cancel();
    _regResendTimer = null;
    _loginUidController.dispose();
    _loginPasswordController.dispose();
    _registerNicknameController.dispose();
    _registerEmailController.dispose();
    _registerPasswordController.dispose();
    _registerConfirmPasswordController.dispose();
    _registerOtpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLogin = _mode == AuthMode.login;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 400,
          constraints: BoxConstraints(
            minHeight: isLogin ? 417 : 551,
          ),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const SizedBox(height: 28),
              isLogin
                  ? _buildLoginForm(key: const ValueKey('login'))
                  : _buildRegisterForm(key: const ValueKey('register')),
              const SizedBox(height: 24),
              _buildToggleLink(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isLogin = _mode == AuthMode.login;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isLogin ? '欢迎回来' : '新玩家登记',
              style: TextStyle(
                fontFamily: AppStyles.zhFontFamily,
                fontSize: 36,
                height: 40 / 36,
                letterSpacing: 1.99,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isLogin ? 'Login to Chrono Tide' : 'Join Chrono Tide',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                height: 20 / 14,
                letterSpacing: 0.7,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ),
        InteractiveWrapper(
          onTap: widget.onClose,
          hoverScale: 1.1,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.borderLight, width: 1.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: SvgPicture.asset(
              'assets/images/auth_close_icon.svg',
              width: 18,
              height: 18,
            ),
          ),
        ),
      ],
    );
  }

  /// 「快速登录」条：闪电图标 + 记住的邮箱 + 前进箭头，整条可点
  Widget _buildQuickLoginBar() {
    final cred = _remembered!;
    return InteractiveWrapper(
      onTap: _handleQuickLogin,
      child: Container(
        width: double.infinity,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.infoBlue.withOpacity(0.08),
          border: Border.all(
              color: AppColors.infoBlue.withOpacity(0.55), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: AppColors.border.withOpacity(0.2),
              offset: const Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.bolt_rounded, size: 18, color: AppColors.infoBlue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '快速登录：${cred.email}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.primaryText,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 13, color: AppColors.secondaryText),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginForm({Key? key}) {
    return Column(
      key: key,
      children: [
        // 「快速登录」（2026-10-03 记住登录）：本地有加密凭证时提供一键登录
        if (_remembered != null) ...[
          _buildQuickLoginBar(),
          const SizedBox(height: 14),
        ],
        _buildTextInput(
          controller: _loginUidController,
          hint: '邮箱地址',
          iconPath: 'assets/images/mail_icon.svg',
          errorText: _loginEmailError,
          onChanged: _validateLoginEmail,
        ),
        const SizedBox(height: 16),
        _buildTextInput(
          controller: _loginPasswordController,
          hint: '密码',
          iconPath: 'assets/images/lock_icon.svg',
          isPassword: true,
          visible: _loginPwdVisible,
          onToggleVisible: () =>
              setState(() => _loginPwdVisible = !_loginPwdVisible),
        ),
        const SizedBox(height: 10),
        // 「记住登录」勾选（默认勾选）与忘记密码同行
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            RememberMeCheckbox(
              value: _rememberMe,
              onChanged: (v) => setState(() => _rememberMe = v),
            ),
            // UX-17: 忘记密码入口
            InteractiveWrapper(
              onTap: _showForgotPasswordDialog,
              hoverScale: 1.0,
              hoverOffset: const Offset(0, -1),
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(
                  '忘记密码？',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.infoBlue,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.infoBlue.withOpacity(0.6),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_errorMessage != null && _mode == AuthMode.login) ...[
          const SizedBox(height: 12),
          _buildErrorMessage(),
        ],
        const SizedBox(height: 24),
        _buildSubmitButton(text: '登入'),
      ],
    );
  }

  Widget _buildRegisterForm({Key? key}) {
    return Column(
      key: key,
      children: [
        _buildTextInput(
          controller: _registerNicknameController,
          hint: '设定一个可爱的昵称',
          iconPath: 'assets/images/person_icon.svg',
          errorText: _regNameError,
          onChanged: _validateRegName,
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerEmailController,
          hint: '你的邮箱（用于找回密码）',
          iconPath: 'assets/images/mail_icon.svg',
          errorText: _regEmailError,
          onChanged: (v) {
            _validateRegEmail(v);
            _invalidateRegOtpIfEmailChanged();
          },
          suffix: _buildRegRequestOtpButton(),
        ),
        const SizedBox(height: 14),
        // ★ 注册邮箱验证码（2026-09-30 新增）
        _buildTextInput(
          controller: _registerOtpController,
          hint: '6 位邮箱验证码',
          iconPath: 'assets/images/lock_icon.svg',
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerPasswordController,
          hint: '设定密码（至少6位）',
          iconPath: 'assets/images/lock_icon.svg',
          isPassword: true,
          visible: _regPwdVisible,
          onToggleVisible: () =>
              setState(() => _regPwdVisible = !_regPwdVisible),
          errorText: _regPasswordError,
          onChanged: _validateRegPassword,
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerConfirmPasswordController,
          hint: '再次输入密码确认',
          iconPath: 'assets/images/lock_icon.svg',
          isPassword: true,
          visible: _regConfirmPwdVisible,
          onToggleVisible: () =>
              setState(() => _regConfirmPwdVisible = !_regConfirmPwdVisible),
          errorText: _regConfirmError,
          onChanged: _validateRegConfirm,
        ),
        if (_errorMessage != null && _mode == AuthMode.register) ...[
          const SizedBox(height: 12),
          _buildErrorMessage(),
        ],
        const SizedBox(height: 22),
        _buildSubmitButton(text: '注册账号'),
      ],
    );
  }

  Widget _buildTextInput({
    required TextEditingController controller,
    required String hint,
    required String iconPath,
    bool obscureText = false,
    // UX-04: 密码可见性切换
    bool isPassword = false,
    bool visible = false,
    VoidCallback? onToggleVisible,
    // UX-05: 实时验证
    String? errorText,
    ValueChanged<String>? onChanged,
    // ★ 新增：右侧附加组件（如「获取验证码」按钮）
    Widget? suffix,
  }) {
    final effectiveObscure = isPassword ? !visible : obscureText;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          height: 51,
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: errorText != null ? AppColors.dangerRed : AppColors.border,
              width: 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.borderLight,
                offset: const Offset(2, 2),
                blurRadius: 0,
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  38,
                  10,
                  suffix != null ? 128 : (isPassword ? 44 : 10),
                  10,
                ),
                child: TextField(
                  controller: controller,
                  obscureText: effectiveObscure,
                  enabled: !_isLoading,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 16,
                    color: AppColors.primaryText,
                  ),
                  onChanged: onChanged,
                  onSubmitted: (_) => _handleSubmit(),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 16,
                      color: AppColors.inputHint,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                    // UX-04: 密码可见性切换按钮
                    suffixIcon: isPassword
                        ? IconButton(
                            icon: Icon(
                              visible
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: AppColors.secondaryText,
                            ),
                            onPressed: onToggleVisible,
                            splashRadius: 16,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 36, minHeight: 36),
                            tooltip: visible ? '隐藏密码' : '显示密码',
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 11,
                top: 15,
                child: SvgPicture.asset(iconPath, width: 18, height: 18),
              ),
              // ★ 右侧附加组件
              if (suffix != null)
                Positioned(
                  right: 6,
                  top: 8,
                  bottom: 8,
                  child: suffix,
                ),
            ],
          ),
        ),
        // UX-05: 字段级错误提示
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              errorText,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 12,
                color: AppColors.dangerRed,
              ),
            ),
          ),
      ],
    );
  }

  /// ★「获取验证码」按钮（带倒计时 / loading 态）
  Widget _buildRegRequestOtpButton() {
    final busy = _isLoading || _regSendingOtp;
    final counting = _regResendCountdown > 0;
    final disabled = busy || counting;

    final String label;
    if (_regSendingOtp) {
      label = '发送中…';
    } else if (counting) {
      label = '$_regResendCountdown s';
    } else if (_regOtpId != null && _regOtpId!.isNotEmpty) {
      label = '重新获取';
    } else {
      label = '获取验证码';
    }

    return InteractiveWrapper(
      onTap: disabled ? null : _handleRequestRegOtp,
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      hoverScale: 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: disabled
              ? AppColors.border.withOpacity(0.18)
              : AppColors.selectedAccent.withOpacity(0.22),
          border: Border.all(
            color: disabled ? AppColors.border : AppColors.selectedAccent,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 12,
            color: disabled ? AppColors.secondaryText : AppColors.primaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.dangerRed, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 16, color: AppColors.dangerRed),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: AppColors.dangerRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton({required String text}) {
    return InteractiveWrapper(
      onTap: _isLoading ? null : _handleSubmit,
      cursor: _isLoading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        width: double.infinity,
        height: 55,
        decoration: BoxDecoration(
          color: _isLoading
              ? AppColors.infoBlue.withOpacity(0.7)
              : AppColors.selectedAccent,
          border: Border.all(color: AppColors.borderLight, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryText,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: _isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.primaryText),
                ),
              )
            : Text(
                text,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  height: 28 / 18,
                  color: AppColors.primaryText,
                ),
              ),
      ),
    );
  }

  Widget _buildToggleLink() {
    final isLogin = _mode == AuthMode.login;
    return Center(
      child: InteractiveWrapper(
        onTap: _toggleMode,
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: Text(
          isLogin ? '还没有账号？去注册（´• ω •`）' : '已有账号？去登录（≧◡≦）',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            height: 20 / 14,
            color: AppColors.secondaryText,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
