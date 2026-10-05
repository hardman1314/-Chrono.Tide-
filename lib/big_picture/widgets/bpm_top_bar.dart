import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../modules/auth/user_model.dart';
import '../../services/network_status_service.dart';
import '../../services/user_cache_service.dart';
import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';
import '../bpm_theme_controller.dart';
import '../services/bpm_system_status.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 专属头部栏 (v3.5)
///
/// 取代原来的系统标题栏 (`CustomTitleBar`, 32px 高、含窗口按钮):
/// 大屏模式下窗口按钮毫无意义,且视觉与 Cinema 舞台突兀。
///
/// 布局: **基本透明 + 横向 + 左中留白**, 内容全部靠右:
/// `主题切换 · 在线情况 · 系统状态(电池+时间) · 用户按钮`
///
/// - 左侧留白区保留**窗口拖拽热区** (窗口是 frameless, 不能没有拖拽入口)
/// - 「用户按钮」与桌面模式右下角用户按钮同源: 打开 [UserProfileModal],
///   作为大屏模式下的用户设置入口
/// - 主题切换直接驱动 [BpmThemeController] (深色 Cinema / 浅色地海蔚蓝)
class BpmTopBar extends StatelessWidget {
  /// 当前登录用户 (供头像与资料弹窗)
  final UserModel? user;

  /// 打开用户面板 (由 `MainContainer` 注入, 与桌面用户按钮同源)
  final VoidCallback? onOpenUserPanel;

  const BpmTopBar({
    super.key,
    this.user,
    this.onOpenUserPanel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: BigPictureTheme.topBarHeight,
      decoration: BoxDecoration(
        // 基本透明: 自上而下极淡的玻璃层 + 一根几乎看不见的分隔线
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            BpmColors.topBarGlass,
            BpmColors.topBarGlass.withOpacity(0.28),
            BpmColors.topBarGlass.withOpacity(0.0),
          ],
          stops: const [0.0, 0.62, 1.0],
        ),
      ),
      child: Row(
        children: [
          // 左侧 + 中间留白: 承载窗口拖拽 (frameless 窗口的唯一拖拽入口)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: const SizedBox.expand(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 26),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _ThemeToggleButton(),
                const SizedBox(width: 22),
                const _OnlineIndicator(),
                const SizedBox(width: 22),
                const _SystemStatusCluster(),
                const SizedBox(width: 22),
                _UserButton(user: user, onTap: onOpenUserPanel),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 主题切换按钮: 深色 Cinema ⇄ 浅色地海蔚蓝
class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton();

  @override
  Widget build(BuildContext context) {
    final controller = BpmThemeController.instance;
    // 🔴 必须内建监听: 本组件以 const 挂载于顶栏,父级重建时 identical 短路
    // 跳过子树,没有 listener 图标/底色就永远停留在旧主题(实锤 Bug)。
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final isDark = controller.isDark;
        return BpmInteractiveWrapper(
          onTap: () => controller.toggle(),
          semanticsLabel: controller.mode.label,
          focusScale: 1.08,
          hoverScale: 1.08,
          borderRadius: BorderRadius.circular(22),
          // 两主题共用同一套中性玻璃底,只靠图标形状与颜色区分主题 ——
          // 柔和不抢眼,月亮/太阳语义一目了然。
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: BpmColors.topBarGlass.withOpacity(0.55),
              shape: BoxShape.circle,
              border: Border.all(color: BpmColors.topBarBorder, width: 1),
            ),
            child: Icon(
              // 图标语义 = 当前主题状态: 深色显月亮, 浅色显太阳
              isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              size: 21,
              color: isDark ? BpmColors.topBarInk : BpmColors.navGlowBlue,
            ),
          ),
        );
      },
    );
  }
}

/// 在线情况 (数据源与桌面用户气泡一致: [NetworkStatusService])
class _OnlineIndicator extends StatelessWidget {
  const _OnlineIndicator();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: NetworkStatusService.instance,
      builder: (context, _) {
        final online = NetworkStatusService.instance.isOnline;
        final color = online ? BpmColors.statusOnline : BpmColors.statusOffline;
        return Semantics(
          label: online ? '在线' : '离线',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: color.withOpacity(0.55), blurRadius: 10),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                online ? '在线' : '离线',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: BpmColors.topBarInk.withOpacity(0.85),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 系统状态区: 电池 + 当前时间
class _SystemStatusCluster extends StatelessWidget {
  const _SystemStatusCluster();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BpmSystemStatus.instance,
      builder: (context, _) {
        final status = BpmSystemStatus.instance;
        final battery = status.battery;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (battery.available) ...[
              Icon(
                _batteryIcon(battery),
                size: 23,
                color: _batteryColor(battery),
              ),
              const SizedBox(width: 6),
              Text(
                '${battery.percent}%',
                style: TextStyle(
                  fontFamily: AppStyles.enDecorativeFont,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: BpmColors.topBarInk.withOpacity(0.85),
                ),
              ),
              const SizedBox(width: 20),
            ],
            Text(
              _formatTime(status.now),
              style: TextStyle(
                fontFamily: AppStyles.enDecorativeFont,
                fontSize: 23,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: BpmColors.topBarInk,
              ),
            ),
          ],
        );
      },
    );
  }

  static IconData _batteryIcon(BpmBatteryStatus b) {
    if (b.pluggedIn) return Icons.battery_charging_full_rounded;
    if (b.percent >= 90) return Icons.battery_full_rounded;
    if (b.percent >= 60) return Icons.battery_5_bar_rounded;
    if (b.percent >= 35) return Icons.battery_3_bar_rounded;
    if (b.percent >= 15) return Icons.battery_2_bar_rounded;
    return Icons.battery_alert_rounded;
  }

  static Color _batteryColor(BpmBatteryStatus b) {
    if (b.pluggedIn) return BpmColors.mistBlueSoft;
    if (b.percent <= 15) return BpmColors.statusOffline;
    return BpmColors.topBarInk.withOpacity(0.9);
  }

  static String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// 用户按钮 (与桌面模式用户按钮同源: 头像 + [UserProfileModal])
class _UserButton extends StatelessWidget {
  final UserModel? user;
  final VoidCallback? onTap;

  const _UserButton({this.user, this.onTap});

  @override
  Widget build(BuildContext context) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      semanticsLabel: '用户设置',
      focusScale: 1.08,
      hoverScale: 1.08,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: BpmColors.topBarGlass.withOpacity(0.55),
          border: Border.all(
            color: BpmColors.topBarInk.withOpacity(0.35),
            width: 1.2,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: ClipOval(
          child: UserCacheService.buildUserAvatar(
            size: 37,
            defaultAvatar: Icon(
              Icons.person_rounded,
              size: 22,
              color: BpmColors.topBarInk.withOpacity(0.8),
            ),
            avatarBytes: user?.avatarBytes,
            avatarUrl: user?.avatarUrl,
          ),
        ),
      ),
    );
  }
}
