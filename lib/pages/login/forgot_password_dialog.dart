import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../theme/app_colors.dart';
import '../../modules/auth/auth_service.dart';
import '../../modules/auth/user_model.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/interactive_wrapper.dart';
import '../../widgets/focus_border.dart';

/// 找回账号 / 密码对话框（无需 SMTP，邮箱单因素验证）。
///
/// 找回密码（两步式）：
///   步骤 1：输入注册邮箱 → 服务端校验存在性，返回临时令牌
///   步骤 2：输入新密码 + 确认密码 → 重置完成
///
/// 找回账号（忘记邮箱时辅助用）：
///   输入昵称 → 查询脱敏邮箱（如 a***@qq.com）
///
/// 通过 [showAppDialog] 弹出，遮罩定位在标题栏下方，与全局弹窗规范一致。
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key});

  /// 弹出找回密码对话框。
  static Future<void> show(BuildContext context) {
    return showAppDialog<void>(
      context: context,
      builder: (context) => const ForgotPasswordDialog(),
    );
  }

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog>
    with SingleTickerProviderStateMixin {
  // 0 = 找回密码，1 = 找回账号
  int _tab = 0;

  // ---- 找回密码：步骤1 - 输入邮箱 ----
  final _emailController = TextEditingController();
  bool _isLoadingRequest = false;
  String? _requestError;
  String _resetToken = '';

  // ---- 找回密码：步骤2 - 设置新密码 ----
  final _newPwdController = TextEditingController();
  final _confirmPwdController = TextEditingController();
  bool _newPwdVisible = false;
  bool _confirmPwdVisible = false;
  bool _isLoadingReset = false;
  String? _resetError;

  // 当前步骤：1=输入邮箱, 2=设新密码, 3=成功
  int _step = 1;

  // ---- 找回账号 ----
  final _lookupNameController = TextEditingController();
  bool _isLoadingLookup = false;
  LookupResult? _lookupResult;

  // ---- 成功动画 ----
  late AnimationController _successAnimController;
  late Animation<double> _successScaleAnim;

  @override
  void initState() {
    super.initState();
    _successAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _successScaleAnim = CurvedAnimation(
      parent: _successAnimController,
      curve: Curves.elasticOut,
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _newPwdController.dispose();
    _confirmPwdController.dispose();
    _lookupNameController.dispose();
    _successAnimController.dispose();
    super.dispose();
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
        .hasMatch(email);
  }

  /// 密码强度评估：返回 0-3（弱/中/强）
  int _evaluatePasswordStrength(String password) {
    if (password.isEmpty) return 0;
    int score = 0;
    if (password.length >= 8) score++;
    if (password.length >= 12) score++;
    if (RegExp(r'[a-z]').hasMatch(password) &&
        RegExp(r'[A-Z]').hasMatch(password)) score++;
    if (RegExp(r'[0-9]').hasMatch(password)) score++;
    if (RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) score++;
    if (score <= 1) return 0; // 弱
    if (score <= 3) return 1; // 中
    return 2; // 强
  }

  // ====================== 找回密码 ======================

  Future<void> _handleRequestReset() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() => _requestError = '请输入邮箱地址');
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _requestError = '邮箱格式不正确');
      return;
    }

    setState(() {
      _isLoadingRequest = true;
      _requestError = null;
    });

    final result = await AuthService.requestReset(email);

    if (!mounted) return;

    setState(() {
      _isLoadingRequest = false;
      if (result.success) {
        _resetToken = result.token;
        _step = 2;
      } else if (result.isUnavailable) {
        _requestError = result.message ?? '找回密码服务暂不可用，请稍后重试';
      } else {
        _requestError = result.message ?? '验证失败，请稍后重试';
      }
    });
  }

  Future<void> _handleReset() async {
    final newPwd = _newPwdController.text;
    final confirmPwd = _confirmPwdController.text;

    if (newPwd.isEmpty) {
      setState(() => _resetError = '请输入新密码');
      return;
    }
    if (newPwd.length < 8) {
      setState(() => _resetError = '密码至少需要 8 位字符');
      return;
    }
    if (!RegExp(r'[a-zA-Z]').hasMatch(newPwd) ||
        !RegExp(r'[0-9]').hasMatch(newPwd)) {
      setState(() => _resetError = '密码必须同时包含字母和数字');
      return;
    }
    if (newPwd != confirmPwd) {
      setState(() => _resetError = '两次输入的密码不一致');
      return;
    }

    setState(() {
      _isLoadingReset = true;
      _resetError = null;
    });

    final result = await AuthService.resetPassword(_resetToken, newPwd);

    if (!mounted) return;

    setState(() {
      _isLoadingReset = false;
      if (result.success) {
        _step = 3;
        _successAnimController.forward();
      } else if (result.isUnavailable) {
        _resetError = result.message ?? '找回密码服务暂不可用，请稍后重试';
      } else {
        _resetError = result.message ?? '重置失败，请重试';
      }
    });
  }

  void _goBackToStep1() {
    setState(() {
      _step = 1;
      _requestError = null;
      _resetError = null;
      _newPwdController.clear();
      _confirmPwdController.clear();
    });
  }

  // ====================== 找回账号 ======================

  Future<void> _handleLookup() async {
    final name = _lookupNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _lookupResult =
          const LookupResult(found: false, message: '请输入昵称'));
      return;
    }

    setState(() {
      _isLoadingLookup = true;
      _lookupResult = null;
    });

    final result = await AuthService.lookupEmailByName(name);

    if (!mounted) return;

    setState(() {
      _isLoadingLookup = false;
      _lookupResult = result;
    });
  }

  // ====================== Build ======================

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    // 响应式：小屏幕缩小对话框宽度
    final dialogWidth = screenWidth < 500 ? screenWidth * 0.92 : 440.0;

    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: dialogWidth,
          constraints: const BoxConstraints(maxHeight: 600),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 26),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 18),
                // 成功步骤不显示 Tab 和步骤指示器
                if (_tab == 0 && _step != 3) ...[
                  _buildStepIndicator(),
                  const SizedBox(height: 18),
                ] else if (_step != 3) ...[
                  _buildTabs(),
                  const SizedBox(height: 18),
                ],
                if (_tab == 0) _buildPasswordContent() else _buildAccountTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          _step == 3 ? '重置成功' : '找回账号 / 密码',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppColors.primaryText,
          ),
        ),
        const Spacer(),
        InteractiveWrapper(
          onTap: () => Navigator.of(context).pop(),
          hoverScale: 1.0,
          hoverOffset: Offset.zero,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 20, color: AppColors.secondaryText),
          ),
        ),
      ],
    );
  }

  Widget _buildTabs() {
    return Row(
      children: [
        _buildTab('找回密码', 0),
        const SizedBox(width: 24),
        _buildTab('找回账号', 1),
      ],
    );
  }

  Widget _buildTab(String label, int index) {
    final active = _tab == index;
    return InteractiveWrapper(
      onTap: () => setState(() {
        _tab = index;
        _step = 1;
        _requestError = null;
        _resetError = null;
        _lookupResult = null;
      }),
      hoverScale: 1.0,
      hoverOffset: const Offset(0, -1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: active ? AppColors.selectedAccent : AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: 32,
            height: 2.4,
            decoration: BoxDecoration(
              color: active ? AppColors.selectedAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 步骤指示器 ----

  Widget _buildStepIndicator() {
    return Row(
      children: [
        _buildStepDot(1, '验证邮箱'),
        _buildStepLine(),
        _buildStepDot(2, '设新密码'),
      ],
    );
  }

  Widget _buildStepDot(int step, String label) {
    final isActive = _step == step;
    final isDone = _step > step;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: isDone
                ? AppColors.successGreen
                : (isActive ? AppColors.selectedAccent : AppColors.border),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: isDone
              ? Icon(Icons.check, size: 14, color: AppColors.sidebarBackground)
              : Text(
                  '$step',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: isActive
                        ? AppColors.sidebarBackground
                        : AppColors.secondaryText,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: isActive ? AppColors.primaryText : AppColors.secondaryText,
          ),
        ),
      ],
    );
  }

  Widget _buildStepLine() {
    return Container(
      width: 32,
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: _step > 1 ? AppColors.successGreen : AppColors.border,
    );
  }

  // ====================== 找回密码内容 ======================

  Widget _buildPasswordContent() {
    switch (_step) {
      case 1:
        return _buildStep1Email();
      case 2:
        return _buildStep2NewPassword();
      case 3:
        return _buildStep3Success();
      default:
        return _buildStep1Email();
    }
  }

  // ---- 步骤1：输入邮箱 ----

  Widget _buildStep1Email() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHint('输入注册时使用的邮箱地址，验证通过后即可设置新密码。'),
        const SizedBox(height: 14),
        _buildField(
          controller: _emailController,
          hint: '注册邮箱',
          iconPath: 'assets/images/mail_icon.svg',
          keyboardType: TextInputType.emailAddress,
          onSubmitted: (_) => _handleRequestReset(),
        ),
        if (_requestError != null) ...[
          const SizedBox(height: 12),
          _buildMessage(_requestError!, isError: true),
        ],
        const SizedBox(height: 18),
        _buildActionButton(
          label: '验证邮箱',
          loading: _isLoadingRequest,
          onTap: _isLoadingRequest ? null : _handleRequestReset,
        ),
        const SizedBox(height: 14),
        _buildInlineTabSwitch(),
      ],
    );
  }

  // ---- 步骤2：设置新密码 ----

  Widget _buildStep2NewPassword() {
    final newPwd = _newPwdController.text;
    final strength = _evaluatePasswordStrength(newPwd);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHint('邮箱验证通过！请设置新密码（8-72 位，须含字母和数字）。'),
        const SizedBox(height: 14),
        _buildPasswordField(
          controller: _newPwdController,
          hint: '新密码',
          visible: _newPwdVisible,
          onToggleVisible: () => setState(() => _newPwdVisible = !_newPwdVisible),
          onChanged: (_) => setState(() {}),
        ),
        // 密码强度指示器
        if (newPwd.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildPasswordStrengthBar(strength),
        ],
        const SizedBox(height: 14),
        _buildPasswordField(
          controller: _confirmPwdController,
          hint: '确认新密码',
          visible: _confirmPwdVisible,
          onToggleVisible: () =>
              setState(() => _confirmPwdVisible = !_confirmPwdVisible),
          onChanged: (_) => setState(() {}),
          suffixIcon: _newPwdController.text.isNotEmpty &&
                  _confirmPwdController.text.isNotEmpty
              ? (_newPwdController.text == _confirmPwdController.text
                  ? Icon(Icons.check_circle, size: 18, color: AppColors.successGreen)
                  : Icon(Icons.cancel, size: 18, color: AppColors.dangerRed))
              : null,
        ),
        if (_resetError != null) ...[
          const SizedBox(height: 12),
          _buildMessage(_resetError!, isError: true),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                label: '返回上一步',
                loading: false,
                secondary: true,
                onTap: _goBackToStep1,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                label: '确认重置',
                loading: _isLoadingReset,
                onTap: _isLoadingReset ? null : _handleReset,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- 密码强度指示器 ----

  Widget _buildPasswordStrengthBar(int strength) {
    final labels = ['弱', '中', '强'];
    final colors = [
      AppColors.dangerRed,
      AppColors.infoBlue,
      AppColors.successGreen,
    ];

    return Row(
      children: [
        Text(
          '强度：',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
            fontSize: 12,
            color: AppColors.secondaryText,
          ),
        ),
        const SizedBox(width: 4),
        // 三段进度条
        ...List.generate(3, (i) {
          final active = i <= strength && strength > 0;
          return Container(
            width: 24,
            height: 4,
            margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
            decoration: BoxDecoration(
              color: active ? colors[strength] : AppColors.border.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
        const SizedBox(width: 8),
        Text(
          strength > 0 ? labels[strength] : '太短',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: strength > 0 ? colors[strength] : AppColors.secondaryText,
          ),
        ),
      ],
    );
  }

  // ---- 步骤3：重置成功 ----

  Widget _buildStep3Success() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        // 成功图标动画
        ScaleTransition(
          scale: _successScaleAnim,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.successBg,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.successGreen, width: 2),
            ),
            child: Icon(
              Icons.check,
              size: 36,
              color: AppColors.successGreen,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '密码重置成功',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(height: 8),
        _buildHint('你现在可以使用新密码登录了。'),
        const SizedBox(height: 22),
        _buildActionButton(
          label: '去登录',
          loading: false,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  // ====================== 找回账号 Tab ======================

  Widget _buildAccountTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHint('输入注册时设定的昵称，查询绑定的邮箱（脱敏显示，'
            '如 a***@qq.com），帮助你回忆登录账号。'),
        const SizedBox(height: 14),
        _buildField(
          controller: _lookupNameController,
          hint: '注册昵称',
          iconPath: 'assets/images/person_icon.svg',
          onSubmitted: (_) => _handleLookup(),
        ),
        if (_lookupResult != null && !_lookupResult!.found) ...[
          const SizedBox(height: 12),
          _buildMessage(
            _lookupResult!.isUnavailable
                ? (_lookupResult!.message ?? '找回账号服务暂不可用，请稍后重试')
                : (_lookupResult!.message ?? '未找到该昵称对应的账号'),
            isError: true,
          ),
        ],
        const SizedBox(height: 18),
        _buildActionButton(
          label: '查询邮箱',
          loading: _isLoadingLookup,
          onTap: _isLoadingLookup ? null : _handleLookup,
        ),
        if (_lookupResult != null && _lookupResult!.found) ...[
          const SizedBox(height: 16),
          _buildLookupResultCard(_lookupResult!),
        ],
        const SizedBox(height: 14),
        _buildInlineTabSwitch(),
      ],
    );
  }

  Widget _buildLookupResultCard(LookupResult result) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.successBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.successGreen, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alternate_email, size: 18, color: AppColors.successGreen),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '该昵称绑定的邮箱：${result.email}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
            ],
          ),
          if (result.hasMultipleMatches && result.matchedName != null) ...[
            const SizedBox(height: 8),
            Text(
              '⚠ 匹配到多个相似昵称，当前显示「${result.matchedName}」的邮箱。'
              '如非你的账号，请尝试输入更精确的昵称。',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 12,
                height: 1.5,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 内联 Tab 切换提示（在步骤内容底部）
  Widget _buildInlineTabSwitch() {
    return Center(
      child: InteractiveWrapper(
        onTap: () => setState(() {
          _tab = _tab == 0 ? 1 : 0;
          _step = 1;
          _requestError = null;
          _resetError = null;
          _lookupResult = null;
        }),
        hoverScale: 1.0,
        hoverOffset: const Offset(0, -1),
        child: Text(
          _tab == 0 ? '忘记邮箱？试试找回账号 →' : '忘记密码？试试找回密码 →',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
            fontSize: 12,
            color: AppColors.secondaryText,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  // ====================== 通用组件 ======================

  Widget _buildHint(String text) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w500,
        fontSize: 13,
        height: 1.6,
        color: AppColors.secondaryText,
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required String iconPath,
    TextInputType keyboardType = TextInputType.text,
    ValueChanged<String>? onSubmitted,
  }) {
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
            padding: const EdgeInsets.fromLTRB(38, 10, 10, 10),
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              maxLength: 254,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.primaryText,
              ),
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
                counterText: '', // 隐藏字数计数器
              ),
              onSubmitted: onSubmitted,
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

  Widget _buildPasswordField({
    required TextEditingController controller,
    required String hint,
    required bool visible,
    required VoidCallback onToggleVisible,
    ValueChanged<String>? onChanged,
    Widget? suffixIcon,
  }) {
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
            padding: EdgeInsets.fromLTRB(38, 10, suffixIcon != null ? 70 : 44, 10),
            child: TextField(
              controller: controller,
              obscureText: !visible,
              maxLength: 72,
              onChanged: onChanged,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 16,
                color: AppColors.primaryText,
              ),
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
                counterText: '',
              ),
              onSubmitted: (_) => _handleReset(),
            ),
          ),
          Positioned(
            left: 11,
            top: 15,
            child: SvgPicture.asset(
              'assets/images/lock_icon.svg',
              width: 18,
              height: 18,
            ),
          ),
          if (suffixIcon != null)
            Positioned(
              right: 36,
              top: 16,
              child: suffixIcon,
            ),
          Positioned(
            right: 4,
            top: 7,
            child: IconButton(
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
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: visible ? '隐藏密码' : '显示密码',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required bool loading,
    required VoidCallback? onTap,
    bool secondary = false,
  }) {
    final disabled = onTap == null;
    return InteractiveWrapper(
      onTap: onTap,
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        width: double.infinity,
        height: 50,
        decoration: BoxDecoration(
          color: disabled
              ? AppColors.infoBlue.withOpacity(0.7)
              : (secondary ? AppColors.background : AppColors.selectedAccent),
          border: Border.all(color: AppColors.borderLight, width: 1.6),
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryText,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: loading
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
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.primaryText,
                ),
              ),
      ),
    );
  }

  Widget _buildMessage(String text, {required bool isError}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isError ? AppColors.errorBg : AppColors.successBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? AppColors.dangerRed : AppColors.successGreen,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 16,
            color: isError ? AppColors.dangerRed : AppColors.successGreen,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 13,
                height: 1.5,
                color: isError ? AppColors.dangerRed : AppColors.primaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
