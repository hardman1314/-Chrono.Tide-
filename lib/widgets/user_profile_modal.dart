import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import '../core/backend_config.dart';
import '../theme/app_colors.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import 'interactive_wrapper.dart';

class UserProfileModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLogout;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onCharge;
  final UserModel? user;
  const UserProfileModal(
      {super.key,
      required this.onClose,
      required this.onLogout,
      this.onOpenSettings,
      this.onCharge,
      this.user});

  @override
  State<UserProfileModal> createState() => _UserProfileModalState();
}

class _UserProfileModalState extends State<UserProfileModal> {
  bool _closeHovered = false;
  String get _displayName => widget.user?.name ?? 'Kiyoko';
  String get _displayUid => widget.user?.id.isNotEmpty == true
      ? 'UID: ${widget.user!.id}'
      : 'UID: --';

  @override
  Widget build(BuildContext context) {
    debugPrint(
        '[USER_PROFILE] 加载用户信息：昵称=${_displayName}，UID=${_displayUid}，头像状态=${widget.user?.hasAvatar == true ? "已加载" : "无头像"}');

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 500,
          height: 548,
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
          padding: const EdgeInsets.fromLTRB(24, 24, 22, 49),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              const SizedBox(height: 77),
              if (BackendConfig.isBackendAvailable) _buildChargeSection(),
              if (BackendConfig.isBackendAvailable) const SizedBox(height: 73),
              _buildBottomButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      width: 449,
      height: 80,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0E6D2),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: const Color(0xFF8B7355), width: 1.6),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0xFF8B7355),
                      offset: Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(3.5, 3.5, 3.5, 1.6),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFBF6EF),
                    border:
                        Border.all(color: const Color(0xFF8B7355), width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(1, 1, 1, 0.8),
                  child: ClipOval(
                    child: UserCacheService.buildUserAvatar(
                      size: 71,
                      defaultAvatar: _buildDefaultAvatar(),
                      avatarUrl: widget.user?.avatarUrl,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _displayName,
                    style: TextStyle(
                      fontFamily: 'ZhiMangXing',
                      fontSize: 36,
                      height: 40 / 36,
                      letterSpacing: 1.99,
                      color: AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _displayUid,
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
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _closeHovered = true),
            onExit: (_) => setState(() => _closeHovered = false),
            child: GestureDetector(
              onTap: widget.onClose,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _closeHovered
                      ? AppColors.primaryText.withOpacity(0.1)
                      : AppColors.background,
                  border: Border.all(
                    color: _closeHovered
                        ? AppColors.border
                        : AppColors.border.withOpacity(0.5),
                    width: _closeHovered ? 2 : 1.6,
                  ),
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border,
                      offset: _closeHovered
                          ? const Offset(1, 2)
                          : const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: _closeHovered
                      ? AppColors.primaryText
                      : AppColors.secondaryText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChargeSection() {
    return Container(
      width: 450,
      height: 186,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: const Color(0x338B7355),
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.all(17.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset('assets/images/lightning_icon.svg',
                  width: 18, height: 18),
              const SizedBox(width: 8),
              Text(
                '为小站充电',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  height: 27 / 18,
                  color: AppColors.dangerRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Text(
              '如果 Chrono Tide 给你带来了快乐，请不要吝啬地用零花钱喂饱开发者吧！您的支持是我们持续为纯爱发光发热的动力～（´,,•ω•,,）♡',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 14,
                height: 22.75 / 14,
                color: AppColors.primaryText,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildChargeButton(),
        ],
      ),
    );
  }

  Widget _buildChargeButton() {
    return InteractiveWrapper(
      onTap: widget.onCharge ?? () {},
      child: Container(
        width: 414,
        height: 55,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE6EA),
          border: Border.all(color: AppColors.dangerRed, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.dangerRed,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset('assets/images/charge_lightning_icon.svg',
                width: 18, height: 18),
            const SizedBox(width: 8),
            Text(
              '立刻为服务器充能',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                fontSize: 18,
                height: 28 / 18,
                color: AppColors.dangerRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomButtons() {
    final isBackendAvailable = BackendConfig.isBackendAvailable;
    return SizedBox(
      width: 449,
      height: 55,
      child: Row(
        children: [
          Expanded(
            child: _ProfileButton(
              label: '个人设置',
              onTap: widget.onOpenSettings ?? () {},
              baseColor: AppColors.selectedBlue,
              textColor: AppColors.primaryText,
              shadowColor: AppColors.primaryText,
            ),
          ),
          if (isBackendAvailable) ...[
            const SizedBox(width: 12),
            Expanded(
              child: _ProfileButton(
                label: '退出登录',
                onTap: widget.onLogout,
                baseColor: AppColors.background,
                textColor: AppColors.border,
                shadowColor: AppColors.border,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 28,
        height: 28,
        colorFilter: const ColorFilter.mode(Color(0xFFA08264), BlendMode.srcIn),
      ),
    );
  }
}

class _ProfileButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color baseColor;
  final Color textColor;
  final Color shadowColor;

  const _ProfileButton({
    required this.label,
    required this.onTap,
    required this.baseColor,
    required this.textColor,
    required this.shadowColor,
  });

  @override
  State<_ProfileButton> createState() => _ProfileButtonState();
}

class _ProfileButtonState extends State<_ProfileButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _hovered = true),
        onTapUp: (_) => setState(() => _hovered = false),
        onTapCancel: () => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 55,
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF5EDE6) : widget.baseColor,
            border: Border.all(
              color:
                  _hovered ? const Color(0xFF8B7355) : const Color(0x1A000000),
              width: _hovered ? 2.0 : 1.6,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: const Color(0x338B7355),
                      offset: const Offset(0, 2),
                      blurRadius: 8,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: widget.shadowColor,
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
              fontSize: 18,
              height: 28 / 18,
              color: widget.textColor,
            ),
          ),
        ),
      ),
    );
  }
}
