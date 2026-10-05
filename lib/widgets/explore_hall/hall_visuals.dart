/// 探索大厅共享装饰组件（纯视觉层，无业务逻辑）
///
/// 设计口径（features/explore_hall_implementation_plan.md §17）：
/// - 所有取色走 [AppColors] 主题 getter（深/浅双分支），不硬编码深色——
///   浅色主题与背景图模式下必须同样可读（v3.8 教训）；
/// - 辉光/光斑一律用径向渐变贴形，禁止圆形 BoxShadow 底块；
/// - 封面压字 scrim 固定用黑色渐变（白字在深浅主题的图片上都需要暗底），
///   属于图片压字惯例，不受主题分支约束。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../theme/app_theme_manager.dart';

/// 品牌渐变工具：主色 → 主色偏绿（青），随主题令牌联动。
class HallGradients {
  HallGradients._();

  /// 主双色（brandBlue → 青绿），用于强调条 / 开始按钮 / 字母徽章
  static List<Color> get accent => [
        AppColors.brandBlue,
        Color.lerp(AppColors.brandBlue, AppColors.successGreen, 0.55)!,
      ];

  static LinearGradient get accentLinear => LinearGradient(
        colors: accent,
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

  /// 封面底部信息条渐变（透明 → 黑 70%），压白字用，主题无关
  static const LinearGradient coverScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0xB3000000)],
  );
}

/// 板块 / 内嵌面板统一装饰（深浅双分支集中在这里，避免各板块散落硬编码）
class HallDecor {
  HallDecor._();

  /// 板块大卡片面：垂直微渐变 + 暖调描边 + 柔和投影（xl 圆角）
  ///
  /// 浅色主题把 titleBrown 以 5% 掺入白色得到「暖纸」底色，
  /// 呼应设计稿的奶油纸面；深色主题用白的高透明度微渐变。
  static BoxDecoration get card {
    final cream = Color.lerp(Colors.white, AppColors.titleBrown, 0.05)!;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: AppColors.isDark
            ? [Colors.white.withOpacity(0.055), Colors.white.withOpacity(0.028)]
            : [cream.withOpacity(0.72), cream.withOpacity(0.46)],
      ),
      border: Border.all(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.09)
            : AppColors.titleBrown.withOpacity(0.22),
      ),
      borderRadius: BorderRadius.circular(AppRadius.xl),
      boxShadow: [
        BoxShadow(
          color: AppColors.shadowColor
              .withOpacity(AppColors.isDark ? 0.32 : 0.08),
          blurRadius: 16,
          offset: const Offset(0, 5),
        ),
      ],
    );
  }

  /// 板块内嵌小面板（日期面板 / 随机面板 / 列表行底）
  static BoxDecoration get panel => BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.035)
            : Colors.black.withOpacity(0.025),
        border: Border.all(
          color: (AppColors.isDark ? Colors.white : Colors.black)
              .withOpacity(0.05),
        ),
        borderRadius: BorderRadius.circular(AppRadius.md + 2),
      );
}

/// 页面级氛围光：左上主色 + 右下暖色两团径向光斑垫底（BPM 侧栏同思路）。
///
/// 用户设置了背景图时自动关闭（[CTThemeData.hasBackgroundImage]），
/// 不与背景图打架；光斑是径向渐变淡出，不是 BoxShadow 圆块。
class HallAmbientBackdrop extends StatelessWidget {
  final Widget child;

  const HallAmbientBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (AppThemeManager.colors.hasBackgroundImage) {
      // 背景图模式：只保留页面底色（pageBackground 此时为透明）
      return Container(color: AppColors.pageBackground, child: child);
    }
    return Container(
      color: AppColors.pageBackground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: const Alignment(-0.9, -1.05),
                  child: _blob(AppColors.brandBlue, 0.10, 360),
                ),
                Align(
                  alignment: const Alignment(0.95, 1.1),
                  child: _blob(AppColors.titleBrown, 0.09, 320),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  static Widget _blob(Color color, double alpha, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withOpacity(alpha), color.withOpacity(0)],
        ),
      ),
    );
  }
}

/// 板块标题图标徽章：圆角方块 + 主题色淡底 + 主题色图标
class HallIconBadge extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final double size;

  const HallIconBadge({
    super.key,
    required this.icon,
    required this.accent,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withOpacity(0.13),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: accent.withOpacity(0.25)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.62, color: accent),
    );
  }
}

/// 站点首字母渐变徽章（无 favicon 场景的站点标识，取标题首字符）
class HallLetterAvatar extends StatelessWidget {
  final String title;
  final List<Color>? colors;
  final double size;

  const HallLetterAvatar({
    super.key,
    required this.title,
    this.colors,
    this.size = 20,
  });

  static String _letterOf(String title) {
    final t = title.trim();
    if (t.isEmpty) return '?';
    return String.fromCharCode(t.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors ?? HallGradients.accent,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      alignment: Alignment.center,
      child: Text(
        _letterOf(title),
        style: TextStyle(
          fontFamily: AppStyles.enDecorativeFont,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w600,
          height: 1,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 月历格子的发售圆点（1-3 颗，超出截断；呼应设计稿的日期下小点）
class HallReleaseDots extends StatelessWidget {
  final int count;
  final Color color;

  const HallReleaseDots({
    super.key,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final n = count.clamp(1, 3);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Container(
            width: 3.2,
            height: 3.2,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ],
      ],
    );
  }
}

/// 标题渐变下划线条（笔触感，F1 标题的固定搭档）
class HallAccentUnderline extends StatelessWidget {
  final double width;

  const HallAccentUnderline({super.key, this.width = 46});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        gradient: HallGradients.accentLinear,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// 横向列表的桌面鼠标拖拽支持：Flutter 桌面默认 dragDevices 不含鼠标，
/// 横向 ListView 无法用鼠标拖动——包一层放开（左键长按 / 中键拖动，
/// 触屏不受影响；拖动超过 slop 自动取消 tap，子项点击不受干扰）。
class HallHScroll extends StatelessWidget {
  final Widget child;

  const HallHScroll({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: <PointerDeviceKind>{
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: child,
    );
  }
}
