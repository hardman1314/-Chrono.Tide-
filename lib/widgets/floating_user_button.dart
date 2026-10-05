import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../modules/auth/user_model.dart';
import '../services/user_cache_service.dart';
import '../services/network_status_service.dart';
import 'interactive_wrapper.dart';

/// 用户头像悬浮按钮。
///
/// 位于内容区右下角。除原有头像点击入口外，新增网络状态提示：
/// - 持久小圆点（QQ 式）：头像右下角 10px 状态圆点，始终可见。
/// - 悬停浮动气泡（微信式）：鼠标悬停 ~300ms 后在头像上方弹出气泡，
///   显示在线/离线状态 + 下指三角指针。
/// 两种提示均监听 [NetworkStatusService] 实时刷新，收起/展开侧边栏态均生效。
class FloatingUserButton extends StatefulWidget {
  final VoidCallback onTap;
  final UserModel? user;

  const FloatingUserButton({super.key, required this.onTap, this.user});

  @override
  State<FloatingUserButton> createState() => _FloatingUserButtonState();
}

class _FloatingUserButtonState extends State<FloatingUserButton> {
  Timer? _bubbleTimer;
  bool _showBubble = false;

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    super.dispose();
  }

  void _onEnter(dynamic _) {
    // 延迟显示气泡，避免鼠标快速划过时闪烁
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showBubble = true);
    });
  }

  void _onExit(dynamic _) {
    setState(() => _showBubble = false);
    _bubbleTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 40,
      bottom: 40,
      // 外层 MouseRegion 检测 hover 用于气泡显隐；与内层 InteractiveWrapper 的
      // MouseRegion 共存（Flutter 中祖先与后代 MouseRegion 都收 enter/exit）。
      child: MouseRegion(
        onEnter: _onEnter,
        onExit: _onExit,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            InteractiveWrapper(
              onTap: widget.onTap,
              hoverScale: 1.08,
              child: _buildAvatar(),
            ),
            // 持久状态圆点（QQ 式）
            _buildStatusBadge(),
            // 悬停浮动气泡（微信式）
            Positioned(
              right: 0,
              bottom: 66,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                opacity: _showBubble ? 1.0 : 0.0,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  offset: _showBubble ? Offset.zero : const Offset(0, 0.3),
                  child: IgnorePointer(
                    // 气泡不拦截鼠标事件，避免影响头像 hover
                    ignoring: !_showBubble,
                    child: _buildStatusBubble(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // v3.9 Aurora：发丝边 + 柔光海拔（经典档硬影保留）
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e2
            : [
                BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
        color: AppColors.placeholderCover,
      ),
      padding: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border, width: 1),
          color: AppColors.sidebarBackground,
        ),
        alignment: Alignment.center,
        child: ClipOval(
          child: UserCacheService.buildUserAvatar(
            size: 44,
            defaultAvatar: _buildDefaultAvatar(),
            avatarBytes: widget.user?.avatarBytes,
            avatarUrl: widget.user?.avatarUrl,
          ),
        ),
      ),
    );
  }

  /// 持久状态圆点（头像右下角），始终可见，监听 NetworkStatusService 实时刷新。
  Widget _buildStatusBadge() {
    return AnimatedBuilder(
      animation: NetworkStatusService.instance,
      builder: (context, _) {
        final online = NetworkStatusService.instance.isOnline;
        final color = online ? AppColors.successGreen : AppColors.dangerRed;
        return Positioned(
          right: 2,
          bottom: 2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: AppColors.sidebarBackground,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.5), blurRadius: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 悬停浮动气泡：圆点 + 文字 + 下指三角指针。
  Widget _buildStatusBubble() {
    return AnimatedBuilder(
      animation: NetworkStatusService.instance,
      builder: (context, _) {
        final online = NetworkStatusService.instance.isOnline;
        final color = online ? AppColors.successGreen : AppColors.dangerRed;
        final label = online ? '在线' : '离线';
        return Semantics(
          label: online ? '在线' : '离线',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withOpacity(0.4), width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border.withOpacity(0.15),
                      offset: const Offset(0, 2),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: color.withOpacity(0.5), blurRadius: 3),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              // 下指三角指针（朝向头像）
              CustomPaint(
                size: const Size(10, 5),
                painter: _BubbleTailPainter(
                  color: AppColors.buttonBackground,
                  borderColor: color.withOpacity(0.4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDefaultAvatar() {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: 20,
        height: 20,
        colorFilter: ColorFilter.mode(AppColors.inputHint, BlendMode.srcIn),
      ),
    );
  }
}

/// 气泡下指三角指针绘制器。指针朝下，对齐头像中心。
class _BubbleTailPainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  const _BubbleTailPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 填充三角
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w / 2, h)
      ..close();
    canvas.drawPath(path, fillPaint);
    // 左右两边描边（与气泡边框衔接，底边不描边避免与头像重叠）
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final leftPath = Path()..moveTo(0, 0)..lineTo(w / 2, h);
    final rightPath = Path()..moveTo(w, 0)..lineTo(w / 2, h);
    canvas.drawPath(leftPath, borderPaint);
    canvas.drawPath(rightPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) =>
      color != oldDelegate.color || borderColor != oldDelegate.borderColor;
}
