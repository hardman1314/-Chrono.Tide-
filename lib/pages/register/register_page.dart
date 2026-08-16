import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:file_picker/file_picker.dart';
import '../../theme/app_colors.dart';
import '../../modules/auth/auth_service.dart';
import '../../modules/auth/user_model.dart';
import '../../widgets/interactive_wrapper.dart';
import '../../widgets/focus_border.dart';

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
  // UX-04: 密码可见性切换
  bool _passwordVisible = false;
  bool _confirmPasswordVisible = false;

  // ★ 可选头像：用户在注册时选择的头像（字节 + 文件名）。
  // 为 null 表示未选择，注册成功后由系统分配默认头像。
  Uint8List? _avatarBytes;
  String? _avatarFileName;
  // 头像上传中标记（注册提交后上传头像阶段）
  bool _isUploadingAvatar = false;

  // UX-30: 输入变化时触发按钮禁用态实时刷新
  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onInputChanged);
    _emailController.addListener(_onInputChanged);
    _passwordController.addListener(_onInputChanged);
    _confirmPasswordController.addListener(_onInputChanged);
  }

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
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

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

    if (result.code == AuthResultCode.success) {
      // ★ 可选头像上传：注册已成功（register 内部已自动登录），
      // 此时 authStore 已持有有效 token，可调用 uploadAvatar。
      // best-effort：上传失败不阻断注册流程，用户可后续在设置中重传。
      if (_avatarBytes != null && _avatarFileName != null) {
        setState(() {
          _isLoading = false;
          _isUploadingAvatar = true;
        });
        try {
          final avatarResult = await AuthService.uploadAvatar(
            fileName: _avatarFileName!,
            bytes: _avatarBytes!,
          );
          if (avatarResult.code != AuthResultCode.success) {
            debugPrint('[REGISTER] 头像上传失败(不阻断注册): ${avatarResult.message}');
          }
        } catch (e) {
          debugPrint('[REGISTER] 头像上传异常(不阻断注册): $e');
        }
        if (!mounted) return;
      }
      setState(() => _isUploadingAvatar = false);
      widget.onRegisterSuccess();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = result.message;
      });
    }
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.+]+@([\w-]+\.)+[\w-]{2,8}$').hasMatch(email);
  }

  // ★ 头像选择：支持 jpg/jpeg/png，≤2MB。可选，未选择则使用系统默认头像。
  Future<void> _pickAvatar() async {
    if (_isLoading || _isUploadingAvatar) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowedExtensions: const ['jpg', 'jpeg', 'png'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null || file.bytes!.isEmpty) return;

      // 扩展名校验（allowedExtensions 在部分平台不完全可靠，二次确认）
      final ext = file.extension?.toLowerCase() ??
          file.path?.split('.').last.toLowerCase() ??
          '';
      if (!['jpg', 'jpeg', 'png'].contains(ext)) {
        setState(() => _errorMessage = '仅支持 JPG / PNG 格式的图片');
        return;
      }

      // 大小校验（≤2MB）。withData:true 已将字节读入内存，直接用其长度最可靠。
      final sizeBytes = file.bytes!.length;
      if (sizeBytes > 2 * 1024 * 1024) {
        setState(() => _errorMessage = '头像过大，请选择 2MB 以内的图片');
        return;
      }

      setState(() {
        _avatarBytes = file.bytes;
        _avatarFileName = file.name;
        _errorMessage = null;
      });
    } catch (e) {
      debugPrint('[REGISTER] 选择头像失败: $e');
      setState(() => _errorMessage = '选择头像失败，请重试');
    }
  }

  void _removeAvatar() {
    if (_isLoading || _isUploadingAvatar) return;
    setState(() {
      _avatarBytes = null;
      _avatarFileName = null;
    });
  }

  /// ★ 头像选择器：圆形头像 + 相机/编辑角标 + 预览 + 移除。
  /// 未选择时显示默认头像图标，点击进入选择；已选择时显示预览，可编辑/移除。
  Widget _buildAvatarPicker() {
    final hasAvatar = _avatarBytes != null;
    final busy = _isLoading || _isUploadingAvatar;
    return Column(
      children: [
        GestureDetector(
          onTap: busy ? null : _pickAvatar,
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.6),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (hasAvatar)
                  ClipOval(
                    child: Image.memory(
                      _avatarBytes!,
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  )
                else
                  Center(
                    child: SvgPicture.asset(
                      'assets/images/user_avatar_icon.svg',
                      width: 44,
                      height: 44,
                    ),
                  ),
                // 右下角角标：未选→相机，已选→编辑
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.selectedAccent,
                      border: Border.all(
                          color: AppColors.sidebarBackground, width: 2),
                    ),
                    child: Icon(
                      hasAvatar ? Icons.edit : Icons.camera_alt,
                      size: 16,
                      color: AppColors.primaryText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 提示文字 / 移除链接
        if (hasAvatar)
          InteractiveWrapper(
            onTap: busy ? null : _removeAvatar,
            hoverScale: 1.0,
            child: Text(
              '移除头像',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 12,
                color: AppColors.secondaryText,
                decoration: TextDecoration.underline,
              ),
            ),
          )
        else
          Text(
            '点击设置头像（可选）',
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 12,
              color: AppColors.secondaryText,
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    // UX-30: 移除监听器后再释放 controller
    _nameController.removeListener(_onInputChanged);
    _emailController.removeListener(_onInputChanged);
    _passwordController.removeListener(_onInputChanged);
    _confirmPasswordController.removeListener(_onInputChanged);
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
        // ★ 可选头像选择器（置顶）：未选择时注册成功后使用系统默认头像
        _buildAvatarPicker(),
        const SizedBox(height: 20),
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
          isPassword: true,
          visible: _passwordVisible,
          onToggleVisible: () =>
              setState(() => _passwordVisible = !_passwordVisible),
        ),
        const SizedBox(height: 14),
        _buildTextInput(
          controller: _confirmPasswordController,
          hint: '再次输入密码确认',
          iconPath: 'assets/images/lock_icon.svg',
          isPassword: true,
          visible: _confirmPasswordVisible,
          onToggleVisible: () => setState(
              () => _confirmPasswordVisible = !_confirmPasswordVisible),
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
    // UX-30: 表单未通过基础校验时按钮禁用（onTap=null），
    // 由 InteractiveWrapper 的禁用态分支自动取消 hover 效果并改用 basic 光标。
    final disabled = _isLoading || _isUploadingAvatar || !_isFormValid;
    final busy = _isLoading || _isUploadingAvatar;
    final busyText = _isUploadingAvatar ? '上传头像中…' : '注册账号';
    return InteractiveWrapper(
      onTap: disabled ? null : _handleRegister,
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        width: double.infinity,
        height: 55,
        decoration: BoxDecoration(
          color: disabled
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
        child: busy
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.primaryText),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    busyText,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      height: 24 / 16,
                      color: AppColors.primaryText,
                    ),
                  ),
                ],
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
