import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/backend_config.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../modules/auth/auth_service.dart';
import '../modules/auth/user_model.dart';
import 'interactive_wrapper.dart';

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

  void _toggleMode() {
    setState(() {
      _mode = _mode == AuthMode.login ? AuthMode.register : AuthMode.login;
      _errorMessage = null;
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

    if (email.isEmpty) {
      setState(() => _errorMessage = '请输入邮箱地址');
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = '请输入密码');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AuthService.login(email, password);

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

    if (name.isEmpty) {
      setState(() => _errorMessage = '请输入昵称');
      return;
    }
    if (email.isEmpty) {
      setState(() => _errorMessage = '请输入邮箱地址');
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _errorMessage = '邮箱格式不正确');
      return;
    }
    if (password.length < 6) {
      setState(() => _errorMessage = '密码至少需要6位字符');
      return;
    }
    if (password != confirmPassword) {
      setState(() => _errorMessage = '两次输入的密码不一致');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AuthService.register(email, password, name);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.code == AuthResultCode.success) {
      widget.onLoginSuccess();
      widget.onClose();
    } else {
      setState(() => _errorMessage = result.message);
    }
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.+]+@([\w-]+\.)+[\w-]{2,8}$').hasMatch(email);
  }

  @override
  void dispose() {
    _loginUidController.dispose();
    _loginPasswordController.dispose();
    _registerNicknameController.dispose();
    _registerEmailController.dispose();
    _registerPasswordController.dispose();
    _registerConfirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!BackendConfig.isBackendAvailable) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 400,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                Text(
                  BackendConfig.unavailableMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppStyles.zhFontFamily,
                    fontSize: 16,
                    height: 24 / 16,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

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
                fontFamily: 'Inter',
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
              border: Border.all(color: const Color(0x1A000000), width: 1.6),
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

  Widget _buildLoginForm({Key? key}) {
    return Column(
      key: key,
      children: [
        _buildTextInput(
          controller: _loginUidController,
          hint: '邮箱地址',
          iconPath: 'assets/images/mail_icon.svg',
        ),
        const SizedBox(height: 16),
        _buildTextInput(
          controller: _loginPasswordController,
          hint: '密码',
          iconPath: 'assets/images/lock_icon.svg',
          obscureText: true,
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
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerEmailController,
          hint: '你的邮箱（用于找回密码）',
          iconPath: 'assets/images/mail_icon.svg',
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerPasswordController,
          hint: '设定密码（至少6位）',
          iconPath: 'assets/images/lock_icon.svg',
          obscureText: true,
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _registerConfirmPasswordController,
          hint: '再次输入密码确认',
          iconPath: 'assets/images/lock_icon.svg',
          obscureText: true,
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
  }) {
    return Container(
      width: double.infinity,
      height: 51,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: const Color(0x1A8B7355),
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(38, 10, 10, 10),
            child: TextField(
              controller: controller,
              obscureText: obscureText,
              enabled: !_isLoading,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.primaryText,
              ),
              onSubmitted: (_) => _handleSubmit(),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w500,
                  fontSize: 16,
                  color: const Color(0x99A08264),
                ),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
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

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE6EA),
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
                fontFamily: 'Inter',
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
          color: _isLoading ? const Color(0xFF9DBAEF) : AppColors.selectedBlue,
          border: Border.all(color: const Color(0x1A000000), width: 1.6),
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
                  fontFamily: 'Inter',
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
            fontFamily: 'Inter',
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
