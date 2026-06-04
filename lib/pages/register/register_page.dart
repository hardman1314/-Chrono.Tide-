import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../theme/app_colors.dart';
import '../../modules/auth/auth_service.dart';
import '../../modules/auth/user_model.dart';
import '../../widgets/interactive_wrapper.dart';

class RegisterPage extends StatefulWidget {
  final VoidCallback onRegisterSuccess;
  final VoidCallback onGoLogin;

  const RegisterPage({
    super.key,
    required this.onRegisterSuccess,
    required this.onGoLogin,
  });

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  bool get _isFormValid {
    if (_nameController.text.trim().isEmpty) return false;
    if (_emailController.text.trim().isEmpty) return false;
    if (_passwordController.text.length < 6) return false;
    if (_confirmPasswordController.text != _passwordController.text)
      return false;
    return true;
  }

  Future<void> _handleRegister() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

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
      widget.onRegisterSuccess();
    } else {
      setState(() => _errorMessage = result.message);
    }
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.+]+@([\w-]+\.)+[\w-]{2,8}$').hasMatch(email);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
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
            constraints: const BoxConstraints(minHeight: 551),
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
                const SizedBox(height: 24),
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
              '新玩家登记',
              style: TextStyle(
                fontFamily: 'ZhiMangXing',
                fontSize: 36,
                height: 40 / 36,
                letterSpacing: 2.0,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Join Chrono Tide',
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
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        _buildTextInput(
          controller: _nameController,
          hint: '设定一个可爱的昵称',
          iconPath: 'assets/images/person_icon.svg',
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _emailController,
          hint: '你的邮箱（用于找回密码）',
          iconPath: 'assets/images/mail_icon.svg',
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _passwordController,
          hint: '设定密码（至少6位）',
          iconPath: 'assets/images/lock_icon.svg',
          obscureText: true,
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _confirmPasswordController,
          hint: '再次输入密码确认',
          iconPath: 'assets/images/lock_icon.svg',
          obscureText: true,
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Container(
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
          ),
        ],
        const SizedBox(height: 22),
        _buildSubmitButton(),
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
              onSubmitted: (_) => _handleRegister(),
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

  Widget _buildSubmitButton() {
    return InteractiveWrapper(
      onTap: _isLoading ? null : _handleRegister,
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
                '注册账号',
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
    return Center(
      child: InteractiveWrapper(
        onTap: widget.onGoLogin,
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: Text(
          '已有账号？去登录（≧◡≦）',
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
