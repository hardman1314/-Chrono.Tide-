import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 左侧栏 (v3.6-re: 「柔和阴影团」形态,回滚 v3.6/v3.7 后重新实现)
///
/// 用户 7 条要求逐条对应:
/// ① 轻量半透明毛玻璃: 两段递减模糊 (外圈 σ3.5 → 本体 σ7,原 v3.5 为 24),
///    底色仅 8%,原画轮廓可辨 —— σ 大会把原画糊成色块,违背「能看到背景」;
/// ② 不是清晰矩形: 玻璃右缘 1px 的「模糊↔清晰」硬过渡由环境阴影团压盖,
///    底色自身水平渐变衰减到 0 (平涂底色的裁剪边 = 色块边,v3.6 实测教训);
/// ③ 底部半凸圆扩散: `_RailAmbientPainter` 的底部 blob 组,圆心贴栏底、
///    半径远超栏宽,向下/向外漫开,由内到外逐渐消失;
/// ④ 阴影非规则矩形投影: 8 组不同圆心/半径的径向渐变叠加,4 段 stops
///    非线性衰减,无一处 BoxShadow 四边均匀投影;
/// ⑤ 图标无底板无背景框无选中高亮: 选中态只有图标变色 + 图标背后一团
///    透明圆形辉光 (navGlowBlue,柔和蓝);`idleShadow: false` 关闭
///    FocusGlow 常驻矩形投影 (否则每个按钮背后出现等宽暗块);
/// ⑥ 与顶部栏零分割线零硬边界: 阴影画布向上外扩 [BigPictureTheme.railShadowSpreadTop],
///    顶部收口 blob 保证侧栏上端不突然变淡。
///
/// 三层结构 (任何一层都不产生矩形硬边):
/// 1. 羽化毛玻璃 (两段 BackdropFilter)
/// 2. 环境阴影团 (`_RailAmbientPainter`,画在玻璃之上 —— 既造体积感,
///    又盖掉羽化带的模糊台阶)
/// 3. 无底板纯图标内容层
///
/// ⚠️ Stack 必须 `clipBehavior: Clip.none`: 阴影画布与玻璃外扩段都要
/// 溢出 [BigPictureTheme.railWidth] 绘制到舞台上。
///
/// 功能项保持不变: 主页 / 我的库 / 添加游戏 + 底部退出按钮
/// (退出按钮为入口,点击弹出三选一 [BpmExitSheet])。
class BigPictureNavBar extends StatelessWidget {
  /// 当前激活的页面
  final int currentPage;

  /// 页面切换回调 (0 = 主页, 1 = 我的库)
  final ValueChanged<int> onPageChanged;

  /// 点击「添加游戏」按钮 (弹出导入模式选择)
  final VoidCallback? onAddGame;

  /// 点击底部按钮 (弹出退出选择面板: 退出大屏/关闭软件/最小化)
  final VoidCallback? onExitBpm;

  const BigPictureNavBar({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    this.onAddGame,
    this.onExitBpm,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: BigPictureTheme.railWidth,
      // Clip.none: 阴影团与玻璃外扩段溢出到舞台侧绘制
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── 层 1: 两段羽化毛玻璃 ──
          ..._buildFeatheredGlass(),

          // ── 层 2: 环境阴影团 (CustomPaint,盖住羽化带台阶并造体积感) ──
          Positioned(
            left: 0,
            top: -BigPictureTheme.railShadowSpreadTop,
            bottom: 0,
            width: BigPictureTheme.railWidth +
                BigPictureTheme.railShadowSpreadRight,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RailAmbientPainter(),
              ),
            ),
          ),

          // ── 层 3: 内容 ──
          //
          // ⚠️ 必须用 Positioned.fill —— Stack 的**非定位**子节点只会被
          // 收缩到自身内容宽度 (最宽的子项 = 68px 按钮) 并按 topStart 对齐,
          // 于是整列图标会贴左、不居中 (实测中心 x≈28 而非 52)。
          // fill 之后 Column 拿到 104px 满宽,子项才能真正水平居中。
          Positioned.fill(
            child: Column(
              children: [
                // 让开头部栏 (悬浮于侧栏上方,无分割线)
                const SizedBox(height: BigPictureTheme.topBarHeight + 6),
                // 应用 Logo (替换原「CT」字样:桌面端侧边栏已是软件图标语义,
                // BPM 全屏沉浸场景下用真实图标而非文字缩写更易识别)。
                // 资源为 app_icon.ico 转出的 PNG (Flutter 的 Image 不支持 .ico),
                // 256px 原生尺寸由 38px 显示尺寸缩绘,故显式 high 采样质量。
                Semantics(
                  label: 'Chrono Tide',
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: BigPictureTheme.railLogoSize,
                    height: BigPictureTheme.railLogoSize,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                // 导航组: 竖向居中
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildNavItem(
                        icon: Icons.home_rounded,
                        semanticsLabel: '主页',
                        index: 0,
                      ),
                      const SizedBox(height: BigPictureTheme.railItemSpacing),
                      _buildNavItem(
                        iconAsset: 'assets/images/library_icon_new.svg',
                        semanticsLabel: '我的库',
                        index: 1,
                      ),
                      const SizedBox(height: BigPictureTheme.railItemSpacing),
                      // 添加游戏 (功能入口,保留 rose 作为 CTA 辨识色;
                      // hover/焦点反馈与导航按钮同款辉光语言)
                      _railButton(
                        icon: Icons.add_rounded,
                        semanticsLabel: '添加游戏',
                        isActive: false,
                        iconColor: BpmColors.cherryRose,
                        onTap: onAddGame,
                      ),
                    ],
                  ),
                ),
                // 底部退出按钮 (入口: 退出大屏 / 关闭软件 / 最小化)
                _railButton(
                  icon: Icons.power_settings_new_rounded,
                  semanticsLabel: '退出大屏模式',
                  isActive: false,
                  iconColor: BpmColors.mistBlueSoft,
                  onTap: onExitBpm,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 两段羽化毛玻璃。
  ///
  /// 单段 BackdropFilter 的裁剪边界必然留下「模糊↔清晰」的 1px 硬过渡;
  /// 两段递减 (外圈 σ3.5 +32px → 本体 σ7) 让过渡分两级摊开,段差小到
  /// 肉眼难辨,且无三段式的高频莫尔风险。
  ///
  /// 🔴 底色必须是**渐变**且衰减到 0 —— 平涂底色的裁剪边就是色块边,
  /// 在 x=railWidth 处会留下一条肉眼可见的硬竖线 (v3.6 实测 11 级台阶)。
  /// ⚠️ 调半透明浓度用 `withAlpha((alpha * k).round())`:
  /// `withOpacity(x)` 是**替换** alpha 而非相乘。
  List<Widget> _buildFeatheredGlass() {
    const extents = BigPictureTheme.railFeatherExtents;
    const sigmas = BigPictureTheme.railFeatherSigmas;
    // 末段索引: `List.length` 不能出现在常量表达式中,保留 final
    final last = extents.length - 1;
    // 底色三段衰减 (左实 → 右无)
    final tint = BpmColors.railGlass;
    final tintMid = tint.withAlpha((tint.alpha * 0.55).round());
    final tintZero = tint.withAlpha(0);

    return <Widget>[
      for (var i = 0; i < extents.length; i++)
        Positioned(
          // 末段贴 0 (本体 0..railWidth),外段向右外扩
          left: i == last ? 0 : BigPictureTheme.railWidth,
          top: 0,
          bottom: 0,
          width: BigPictureTheme.railWidth + extents[i],
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: sigmas[i],
                sigmaY: sigmas[i],
              ),
              child: DecoratedBox(
                decoration: i == last
                    ? BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [tint, tintMid, tintZero],
                          stops: const [0.0, 0.52, 1.0],
                        ),
                      )
                    : const BoxDecoration(color: Colors.transparent),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildNavItem({
    IconData? icon,
    String? iconAsset,
    required String semanticsLabel,
    required int index,
  }) {
    final active = currentPage == index;
    return _railButton(
      icon: icon,
      iconAsset: iconAsset,
      semanticsLabel: semanticsLabel,
      isActive: active,
      iconColor: BpmColors.textSecondary,
      onTap: () => onPageChanged(index),
    );
  }

  /// 无底板图标按钮 (需求 ⑤) — v3.8 四按钮统一辉光语言。
  ///
  /// 四个按钮 (主页/库/添加/退出) 走**同一条**渲染路径:
  /// - 选中: 字形三层辉光 (内聚 6px / 中散 16px / 外漫 34px,非线性衰减)
  ///   + `AnimatedScale` 1.12 呼吸放大 —— 不再只有"图标变个色";
  /// - hover/键盘焦点预览: 同款三层辉光按 0.38 系数降档 + 1.06 微放大,
  ///   添加/退出按钮此前完全没有 hover 反馈 (不统一的根因),现在与
  ///   导航按钮一致;
  /// - 辉光颜色跟随字形自身颜色 (导航=navGlowBlue,添加=rose,退出=mistBlue),
  ///   CTA 辨识色仅保留在图标常态色;
  /// - 浅色主题整体降档 0.75 (白底上高浓度光晕显脏)。
  ///
  /// 光晕完全跟随字形,没有任何圆形/矩形底块 (第一版的圆形 BoxShadow
  /// 辉光被否决: 两档叠加后中心不透明度 ~64%,在画面上是一坨实心蓝圆,
  /// 正是用户说的"背景块")。无选中矩形高亮、无指示条。
  Widget _railButton({
    IconData? icon,
    String? iconAsset,
    required bool isActive,
    required Color iconColor,
    required VoidCallback? onTap,
    required String semanticsLabel,
  }) {
    return _RailGlyphButton(
      icon: icon,
      iconAsset: iconAsset,
      isActive: isActive,
      iconColor: iconColor,
      onTap: onTap,
      semanticsLabel: semanticsLabel,
    );
  }
}

/// 单个 rail 图标按钮 (v3.8 拆出 StatefulWidget 管理 hover 辉光预览)。
class _RailGlyphButton extends StatefulWidget {
  const _RailGlyphButton({
    this.icon,
    this.iconAsset,
    required this.isActive,
    required this.iconColor,
    required this.onTap,
    required this.semanticsLabel,
  });

  final IconData? icon;
  final String? iconAsset;
  final bool isActive;
  final Color iconColor;
  final VoidCallback? onTap;
  final String semanticsLabel;

  @override
  State<_RailGlyphButton> createState() => _RailGlyphButtonState();
}

class _RailGlyphButtonState extends State<_RailGlyphButton> {
  bool _hover = false;

  /// 字形三层辉光 (内聚/中散/外漫)。[k] 为整体强度系数:
  /// 选中 1.0,hover/焦点预览 0.38;浅色主题再乘 0.75。
  List<Shadow> _shadows(Color glow, double k) {
    if (k <= 0) return const <Shadow>[];
    Shadow tier(double factor, double blur) => Shadow(
          color: glow.withAlpha((glow.alpha * factor * k).round()),
          blurRadius: blur,
        );
    return <Shadow>[tier(0.62, 6), tier(0.34, 16), tier(0.15, 34)];
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.isActive;
    // 辉光强度: 选中满档 / hover 预览降档;浅色整体再降
    final lightK = BpmColors.isDark ? 1.0 : 0.75;
    final k = selected ? lightK : (_hover ? 0.38 * lightK : 0.0);
    // 选中发光色统一 navGlowBlue;非选中 hover 预览用字形自身色
    final glow = selected ? BpmColors.navGlowBlue : widget.iconColor;
    // 选中图标亮色;hover 时非选中字形微亮
    final color = selected
        ? BpmColors.navGlowBlue
        : (_hover ? Color.alphaBlend(widget.iconColor.withOpacity(0.35), BpmColors.textSecondary) : widget.iconColor);

    final size = BigPictureTheme.railIconSize.toDouble();
    Widget glyph;
    if (widget.iconAsset != null) {
      glyph = SvgPicture.asset(
        widget.iconAsset!,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
      if (k > 0) {
        // SVG 无 shadows: 底层同色模糊发光 + 顶层清晰字形
        glyph = Stack(
          alignment: Alignment.center,
          children: [
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: SvgPicture.asset(
                widget.iconAsset!,
                width: size,
                height: size,
                colorFilter: ColorFilter.mode(
                  glow.withAlpha((glow.alpha * 0.75 * k).round()),
                  BlendMode.srcIn,
                ),
              ),
            ),
            glyph,
          ],
        );
      }
    } else {
      glyph = Icon(
        widget.icon,
        size: size,
        color: color,
        shadows: _shadows(glow, k),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: BpmInteractiveWrapper(
        onTap: widget.onTap,
        semanticsLabel: widget.semanticsLabel,
        borderRadius: BorderRadius.circular(20),
        // 焦点环收窄到 2px: 保留键盘/手柄可达性,但不再是"边框"
        ringWidth: 2,
        // 🔴 关闭 FocusGlow 非焦点态常驻矩形投影 —— 否则每个图标背后
        // 都有一块与按钮等宽 (68px) 的暗色方块,看起来仍是"方形底板"
        idleShadow: false,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          scale: selected ? 1.12 : (_hover ? 1.06 : 1.0),
          child: SizedBox(
            width: BigPictureTheme.railItemSize + 12,
            height: BigPictureTheme.railItemSize,
            child: Center(child: glyph),
          ),
        ),
      ),
    );
  }
}

/// 侧边栏环境阴影画家 (v3.6-re)。
///
/// 画布 = (railWidth + [BigPictureTheme.railShadowSpreadRight]) 宽、
/// (屏幕高 + [BigPictureTheme.railShadowSpreadTop]) 高,顶部溢出 30px
/// 与头部栏衔接。由 8 组不同圆心/半径的径向渐变叠加而成:
/// 主体椭圆(中心略暗) / 上下柔化 / **底部半凸圆×2**(需求 ③ 主体) /
/// 底部外侧左扩(打破对称 → 半圆/胶囊感) / 舞台侧扩散 / 顶部收口。
///
/// 每组 4 段 stops 做非线性衰减 → 不规则柔软暗部,不是规则矩形投影。
/// 🔴 所有 blob 的渐变都必须在画布右缘之前归零 (spreadRight=200 是按
/// 最大半径 1.8×railWidth 预留的余量),否则画布边界切出硬边。
class _RailAmbientPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    // 栏体在画布内的纵向范围 (画布顶部 30px 是与头部栏的衔接余量)
    const bodyTop = BigPictureTheme.railShadowSpreadTop;
    final bodyBottom = h;
    final color = BpmColors.railShadow;

    // 单个柔光斑: 4 段非线性衰减的径向渐变
    void blob(Offset center, double radius, double strength) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withOpacity(strength),
            color.withOpacity(strength * 0.55),
            color.withOpacity(strength * 0.22),
            color.withOpacity(0.0),
          ],
          stops: const [0.0, 0.42, 0.72, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    final rw = BigPictureTheme.railWidth.toDouble();
    final bodyH = bodyBottom - bodyTop;

    // 1) 主体: 中心略暗的椭圆暗部 (竖向拉长由上下两段补足)
    blob(Offset(rw * 0.72, bodyTop + bodyH * 0.45), rw * 1.50, 0.11);
    // 2) 上段柔化
    blob(Offset(rw * 0.65, bodyTop + bodyH * 0.20), rw * 1.20, 0.06);
    // 3) 下段柔化
    blob(Offset(rw * 0.78, bodyTop + bodyH * 0.74), rw * 1.30, 0.09);
    // 4) 底部半凸圆扩散 (主层次): 圆心贴栏底、半径远超栏宽 → 向下向外漫开。
    //    窗口底边天然裁掉下半圆,留下的正是需求要的「半凸圆」。
    blob(Offset(rw * 0.82, bodyBottom - 30), rw * 1.80, 0.20);
    // 5) 底部内层: 让底部暗部更"实",形成由内到外的层次
    blob(Offset(rw * 0.82, bodyBottom - 60), rw * 1.00, 0.10);
    // 6) 底部外侧(左)外扩: 不规则柔软暗部,打破对称 → 半圆/胶囊感
    blob(Offset(rw * 0.28, bodyBottom - 80), rw * 1.40, 0.11);
    // 7) 外侧(舞台侧)扩散: 与舞台无缝衔接
    blob(Offset(rw * 1.44, bodyTop + bodyH * 0.50), rw * 1.20, 0.05);
    // 8) 顶部收口: 与头部栏之间不留硬边界
    blob(Offset(rw * 0.72, bodyTop + 20), rw * 0.90, 0.04);
  }

  @override
  bool shouldRepaint(covariant _RailAmbientPainter oldDelegate) {
    // 颜色来自 BpmColors (随主题切换整体重建),painter 本身无独立状态
    return false;
  }
}
