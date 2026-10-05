import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../theme/app_colors.dart';
import '../../modules/auth/auth_service.dart';
import '../../modules/auth/remember_me_store.dart';
import '../../modules/auth/user_model.dart';
import '../../widgets/interactive_wrapper.dart';
import '../../widgets/remember_me_checkbox.dart';
import '../../widgets/focus_border.dart';
import 'forgot_password_dialog.dart';

class LoginPage extends StatefulWidget {
  final VoidCallback onLoginSuccess;
  final VoidCallback onGoRegister;

  /// 需求 2：以本地游客进入（创建本地账户，见 local_account_mode.md）。
  final VoidCallback onLocalGuest;

  const LoginPage({
    super.key,
    required this.onLoginSuccess,
    required this.onGoRegister,
    required this.onLocalGuest,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  // UX-04: 密码可见性切换
  bool _passwordVisible = false;
  // 「记住登录」（2026-10-03）：默认勾选——token 过期后静默重登的前提
  bool _rememberMe = true;
  // 本地记住的凭证（有则在表单上方提供「快速登录」一键入口）
  RememberedCredentials? _remembered;

  @override
  void initState() {
    super.initState();
    RememberMeStore.load().then((cred) {
      if (cred != null && mounted) setState(() => _remembered = cred);
    });
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      setState(() => _errorMessage = '请输入邮箱地址');
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = '请输入密码');
      return;
    }

    debugPrint('[ACTION] 用户点击登录按钮 | email=$email');

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AuthService.login(email, password, remember: _rememberMe);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.code == AuthResultCode.success) {
      debugPrint('[ACTION] ✅ 登录成功，跳转主页');
      widget.onLoginSuccess();
    } else {
      debugPrint('[ACTION] ⚠️ 登录失败，显示错误: ${result.message}');
      setState(() => _errorMessage = result.message);
    }
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

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Container(
            width: 420,
            constraints: const BoxConstraints(minHeight: 417),
            decoration: BoxDecoration(
              color: AppColors.sidebarBackground,
              border: Border.all(color: AppColors.border, width: 1.6),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(4, 6),
                  blurRadius: 0,
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                _buildForm(),
                const SizedBox(height: 12),
                _buildLocalGuestButton(),
                const SizedBox(height: 16),
                _buildToggleLink(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '欢迎回来',
              style: TextStyle(
                fontSize: 36,
                height: 40 / 36,
                letterSpacing: 2.0,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Login to Chrono Tide',
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
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        // 「快速登录」（2026-10-03 记住登录）：本地有加密凭证时提供一键登录，
        // 免输邮箱密码——token 失效后重新登录的核心便捷通道
        if (_remembered != null) ...[
          _buildQuickLoginBar(),
          const SizedBox(height: 14),
        ],
        _buildTextInput(
          controller: _emailController,
          hint: '邮箱地址',
          iconPath: 'assets/images/mail_icon.svg',
        ),
        const SizedBox(height: 16),
        _buildTextInput(
          controller: _passwordController,
          hint: '密码',
          iconPath: 'assets/images/lock_icon.svg',
          isPassword: true,
          visible: _passwordVisible,
          onToggleVisible: () =>
              setState(() => _passwordVisible = !_passwordVisible),
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
            _buildForgotPasswordLink(),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Container(
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
          ),
        ],
        const SizedBox(height: 24),
        _buildSubmitButton(),
      ],
    );
  }

  Widget _buildTextInput({
    required TextEditingController controller,
    required String hint,
    required String iconPath,
    bool obscureText = false,
    bool isPassword = false,
    bool visible = false,
    VoidCallback? onToggleVisible,
  }) {
    final effectiveObscure = isPassword ? !visible : obscureText;
    // UX-38: 输入框获得焦点时边框高亮为主题强调色
    return FocusBorder(
      width: double.infinity,
      height: 51,
      bgColor: AppColors.background,
      boxShadow: [
        BoxShadow(
          color: AppColors.borderLight,
          offset: const Offset(2, 2),
          blurRadius: 0,
        ),
      ],
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(38, 10, isPassword ? 44 : 10, 10),
            child: TextField(
              controller: controller,
              obscureText: effectiveObscure,
              enabled: !_isLoading,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.primaryText,
              ),
              onSubmitted: (_) => _handleLogin(),
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
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
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
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return InteractiveWrapper(
      onTap: _isLoading ? null : _handleLogin,
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
                '登入',
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

  /// 需求 2：【以本地游客进入】—— 次级按钮，位于「登入」与「去注册」之间。
  /// 点击后直接进入软件（不注册），再由首帧弹出的 LocalAccountSetupDialog
  /// 填写基础信息并注册为本地账号。
  Widget _buildLocalGuestButton() {
    return InteractiveWrapper(
      onTap: _isLoading ? null : widget.onLocalGuest,
      cursor: _isLoading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        width: double.infinity,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.borderLight, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.borderLight,
              offset: const Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          '以本地游客进入',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            height: 22 / 15,
            color: AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildToggleLink() {
    return Center(
      child: InteractiveWrapper(
        onTap: widget.onGoRegister,
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: Text(
          '还没有账号？去注册（´• ω •`）',
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

  /// UX-FP: 忘记密码入口链接，右对齐小字，点击弹出找回账号/密码对话框。
  Widget _buildForgotPasswordLink() {
    return Align(
      alignment: Alignment.centerRight,
      child: InteractiveWrapper(
        onTap: () => ForgotPasswordDialog.show(context),
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Text(
            '忘记密码？',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
