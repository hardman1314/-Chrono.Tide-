import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import 'interactive_wrapper.dart';

class FloatingUserButton extends StatelessWidget {
  final VoidCallback onTap;
  final UserModel? user;

  const FloatingUserButton({super.key, required this.onTap, this.user});

  @override
  Widget build(BuildContext context) {
    final hasAvatar = user?.hasAvatar == true;
    return Positioned(
      right: 40,
      bottom: 40,
      child: InteractiveWrapper(
        onTap: onTap,
        hoverScale: 1.08,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF8B7355), width: 1.6),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B7355),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
            color: const Color(0xFFF0E6D2),
          ),
          padding: const EdgeInsets.all(5.5),
          child: Container(
            width: 45,
            height: 45,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF8B7355), width: 1),
              color: const Color(0xFFFBF6EF),
            ),
            child: ClipOval(
              child: UserCacheService.buildUserAvatar(
                size: 45,
                defaultAvatar: _buildDefaultAvatar(),
                avatarUrl: user?.avatarUrl,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 20,
        height: 20,
        colorFilter: const ColorFilter.mode(Color(0xFFA08264), BlendMode.srcIn),
      ),
    );
  }
}
