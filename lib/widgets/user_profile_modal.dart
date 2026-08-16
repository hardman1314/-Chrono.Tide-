import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import '../theme/app_colors.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import 'interactive_wrapper.dart';

class UserProfileModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onLogout;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onCharge;
  final VoidCallback? onOpenBigPicture;
  final UserModel? user;
  const UserProfileModal(
      {super.key,
      required this.onClose,
      required this.onLogout,
      this.onOpenSettings,
      this.onCharge,
      this.onOpenBigPicture,
      this.user});

  @override
  State<UserProfileModal> createState() => _UserProfileModalState();
}

class _UserProfileModalState extends State<UserProfileModal> {
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
              _buildChargeSection(),
              const SizedBox(height: 73),
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
                  color: AppColors.placeholderCover,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.border, width: 1.6),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.shadowColor,
                      offset: Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(3.5),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.sidebarBackground,
                    border: Border.all(color: AppColors.border, width: 1),
                  ),
                  alignment: Alignment.center,
                  child: ClipOval(
                    child: SizedBox(
                      width: 71,
                      height: 71,
                      child: UserCacheService.buildUserAvatar(
                        size: 71,
                        defaultAvatar: _buildDefaultAvatar(),
                        avatarBytes: widget.user?.avatarBytes,
                        avatarUrl: widget.user?.avatarUrl,
                      ),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // v1.2: 大屏模式入口改为右上角小图标按钮,与关闭按钮并列
              //       不再作为底部第三按钮挤压原布局
              if (widget.onOpenBigPicture != null) ...[
                _HeaderIconButton(
                  icon: Icons.fullscreen_rounded,
                  onTap: widget.onOpenBigPicture!,
                  tooltip: '大屏模式 (F11)',
                ),
                const SizedBox(width: 8),
              ],
              _HeaderIconButton(
                icon: Icons.close,
                onTap: widget.onClose,
                tooltip: '关闭',
              ),
            ],
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
            color: AppColors.shadowColor,
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
    // v1.2: 大屏模式入口已移至右上角图标按钮,底部恢复原两按钮布局
    return SizedBox(
      width: 449,
      height: 55,
      child: Row(
        children: [
          Expanded(
            child: _ProfileButton(
              label: '个人设置',
              onTap: widget.onOpenSettings ?? () {},
              baseColor: AppColors.selectedAccent,
              textColor: AppColors.primaryText,
              shadowColor: AppColors.primaryText,
            ),
          ),
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
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 28,
        height: 28,
        colorFilter: ColorFilter.mode(AppColors.secondaryText, BlendMode.srcIn),
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
            color: _hovered ? AppColors.cardHoverBg : widget.baseColor,
            border: Border.all(
              color: _hovered ? AppColors.border : AppColors.borderLight,
              width: _hovered ? 2.0 : 1.6,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: AppColors.shadowColor,
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

/// 用户窗口右上角小图标按钮 (v1.2)
///
/// 32x32 带悬停态的工具图标按钮,用于关闭按钮与大屏模式入口,
/// 复用同一视觉规范避免重复代码。
class _HeaderIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.primaryText.withOpacity(0.1)
                  : AppColors.background,
              border: Border.all(
                color: _hovered
                    ? AppColors.border
                    : AppColors.border.withOpacity(0.5),
                width: _hovered ? 2 : 1.6,
              ),
              borderRadius: BorderRadius.circular(5),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border,
                  offset: _hovered ? const Offset(1, 2) : const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 18,
              color: _hovered ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
