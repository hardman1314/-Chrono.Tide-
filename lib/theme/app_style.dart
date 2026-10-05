import 'package:flutter/material.dart';

import 'app_theme_manager.dart';

/// v3.9 Aurora：主题风格档门面
///
/// 主题从"只带调色板"升级为"带形状语言"。本门面与 [AppColors] 同款静态模式，
/// 从当前激活主题读取风格档并给出对应档位的几何/阴影/派生色取值：
/// - classicHanddrawn（默认）：全部取值与历史硬编码**逐值一致**
///   （回归测试 test/theme/app_style_test.dart 锁定，任何漂移测试即红）；
/// - aurora：现代极光档——发丝线、柔和海拔、交互辉光、大圆角。
///
/// 调用点替换规则（见 modern_theme_aurora_redesign.md §8/§11）：
/// 组件中**只有**几何/阴影/交互反馈参数需要换成 AppStyle 取值，
/// 颜色仍走 AppColors（未列出的颜色语义不变）。
class AppStyle {
  AppStyle._();

  static CTThemeData get _t => AppThemeManager.colors;
  static Brightness get _b => _t.brightness;

  /// 当前主题风格档
  static CTVisualStyle get style => _t.visualStyle;

  /// 是否为 aurora 现代档（氛围层/辉光等按此开关）
  static bool get isModern => style == CTVisualStyle.aurora;

  static int _alpha(double opacity) => (opacity * 255).round();

  // ============ 线宽档案 ============
  /// 选中/激活描边（经典 2.0 / 极光 1.0）
  static double get wStrong => isModern ? 1.0 : 2.0;

  /// 常规勾边（经典 1.6 / 极光 0.8）
  static double get wNormal => isModern ? 0.8 : 1.6;

  /// 发丝线（经典 1.0 / 极光 0.5）
  static double get wHairline => isModern ? 0.5 : 1.0;

  // ============ 圆角档案 ============
  static double get rSm => isModern ? 6.0 : 6.0;
  static double get rMd => isModern ? 10.0 : 8.0;
  static double get rLg => isModern ? 14.0 : 10.0;
  static double get rXl => isModern ? 18.0 : 12.0;

  // ============ 海拔阴影体系 ============
  /// e1：卡面静息（极光 0,1,3 / 经典 = 硬贴纸影 offset(2,2) blur 0）
  static List<BoxShadow> get e1 => isModern
      ? [
          BoxShadow(
            color: Colors.black.withAlpha(_alpha(_b == Brightness.dark ? 0.20 : 0.06)),
            offset: const Offset(0, 1),
            blurRadius: 3,
          ),
        ]
      : [
          BoxShadow(
            color: _t.shadowColor,
            offset: const Offset(2, 2),
            blurRadius: 0,
          ),
        ];

  /// e2：卡面悬停（极光 0,2,8 / 经典 = 硬贴纸影）
  static List<BoxShadow> get e2 => isModern
      ? [
          BoxShadow(
            color: Colors.black.withAlpha(_alpha(_b == Brightness.dark ? 0.30 : 0.10)),
            offset: const Offset(0, 2),
            blurRadius: 8,
          ),
        ]
      : e1;

  /// e3：浮层（弹窗/菜单，极光 0,8,24 / 经典 = 硬贴纸影）
  static List<BoxShadow> get e3 => isModern
      ? [
          BoxShadow(
            color: Colors.black.withAlpha(_alpha(_b == Brightness.dark ? 0.45 : 0.14)),
            offset: const Offset(0, 8),
            blurRadius: 24,
          ),
        ]
      : e1;

  /// 交互/选中辉光环（经典 = 无；极光 = 柔和外扩辉光）
  static List<BoxShadow> focusGlow(Color color) => isModern
      ? [
          BoxShadow(
            color: color.withAlpha(_alpha(0.25)),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ]
      : const [];

  /// 派生色：强调色悬停态（浅色系变深 / 深色系变亮）
  static Color get accentHover => _b == Brightness.dark
      ? Color.lerp(_t.selectedAccent, Colors.white, 0.08)!
      : Color.lerp(_t.selectedAccent, Colors.black, 0.10)!;

  /// 派生色：强调色按压态
  static Color get accentPressed => _b == Brightness.dark
      ? Color.lerp(_t.selectedAccent, Colors.white, 0.16)!
      : Color.lerp(_t.selectedAccent, Colors.black, 0.18)!;

  /// 派生色：强调色软底（选中行/图标容器底）
  static Color get accentSoftBg =>
      _t.selectedAccent.withAlpha(_alpha(_b == Brightness.dark ? 0.16 : 0.10));

  /// 派生色：选中环辉光色
  static Color get ringColor => _t.selectedAccent.withAlpha(_alpha(0.45));

  // ============ 语义按钮派生色（v3.9 按钮体系，classic 档锁定现值） ============
  // 根因修复：历史按钮把 border 令牌当主色用，暖阳（border=暖棕）成立，
  // 极光档 border=中性灰 → 按钮看不清。语义变体改由本组派生色驱动。

  /// primary 按钮底色：classic=border 色（暖阳棕底米白字历史原味）/
  /// aurora=强调色（浅=科技蓝底白字，深=亮蓝底白字）
  static Color get primaryButtonFill =>
      isModern ? _t.selectedAccent : _t.border;

  /// primary 按钮文字/图标色
  static Color get primaryButtonInk =>
      isModern ? Colors.white : _t.background;

  /// primary 悬停底色
  static Color get primaryButtonFillHover => isModern
      ? accentHover
      : Color.lerp(_t.border, Colors.black, 0.10)!;

  /// primary 按压底色
  static Color get primaryButtonFillPressed => isModern
      ? accentPressed
      : Color.lerp(_t.border, Colors.black, 0.18)!;

  /// danger 按钮软底：classic=errorBg / aurora=危险色 8%
  static Color get dangerSoftBg =>
      isModern ? _t.dangerRed.withAlpha(_alpha(0.08)) : _t.errorBg;

  // ============ 组件专项（经典档 = 各组件现行硬编码值） ============

  /// 侧栏展开大导航项（175×144）边框。
  /// 极光档静息态 = 白卡面 + 可见发丝描边（石英白画布与卡面同色系，
  /// 无描边会导致按钮隐形——2026-09-12 用户实测反馈修复）。
  static Border navHeroBorder({required bool active, required bool hovered}) {
    if (isModern) {
      return Border.fromBorderSide(BorderSide(
        color: active
            ? _t.selectedAccent
            : (hovered ? _t.border : _t.borderLight),
        width: active ? wStrong : wHairline,
      ));
    }
    return Border.fromBorderSide(BorderSide(
      color: _t.border,
      width: active || hovered ? 2.0 : 1.6,
    ));
  }

  /// 侧栏展开大导航项阴影（经典 = hover 高亮投影/激活硬影，优先 hover；
  /// 极光档 = 静息 e1 / 悬停抬升 e2 / 激活 e2 + 强调辉光）
  static List<BoxShadow>? navHeroShadow({required bool active, required bool hovered}) {
    if (isModern) {
      return active
          ? [
              ...e2,
              BoxShadow(
                color: _t.selectedAccent.withAlpha(_alpha(0.28)),
                offset: const Offset(0, 2),
                blurRadius: 8,
              ),
            ]
          : (hovered ? e2 : e1);
    }
    if (!active && !hovered) return null;
    return [
      BoxShadow(
        color: hovered ? _t.borderLight : _t.border,
        offset: hovered ? const Offset(0, 3) : const Offset(2, 3),
        blurRadius: hovered ? 10.0 : 0,
      ),
    ];
  }

  /// 侧栏收起胶囊/主页按钮圆角（经典 14 / 极光 12）
  static double get rNavItem => isModern ? 12.0 : 14.0;

  /// 侧栏展开大导航项/主页扁条圆角（经典 = null 保持直角手绘感 / 极光 rLg）
  static BorderRadius? get navHeroRadius =>
      isModern ? BorderRadius.circular(rLg) : null;

  /// 侧栏主页扁条按钮（展开 175×56）边框——极光档静息态与导航项同规：
  /// 白卡面 + 可见发丝描边（防石英白画布上隐形）
  static Border homeHeroBorder({required bool active, required bool hovered}) {
    if (isModern) {
      return Border.fromBorderSide(BorderSide(
        color: active
            ? _t.selectedAccent
            : (hovered ? _t.border : _t.borderLight),
        width: active ? wStrong : wHairline,
      ));
    }
    return Border.fromBorderSide(BorderSide(
      color: _t.border,
      width: active || hovered ? 2.0 : 1.6,
    ));
  }

  /// 侧栏主页扁条按钮阴影——经典档与大导航项有差异（hover 无高亮投影，
  /// 恒为 (2,3) blur 0 硬影），不可复用 [navHeroShadow]；
  /// 极光档与导航项同规（静息 e1 / 悬停 e2 / 激活 e2+辉光）
  static List<BoxShadow>? homeHeroShadow({required bool active, required bool hovered}) {
    if (isModern) {
      return active
          ? [
              ...e2,
              BoxShadow(
                color: _t.selectedAccent.withAlpha(_alpha(0.28)),
                offset: const Offset(0, 2),
                blurRadius: 8,
              ),
            ]
          : (hovered ? e2 : e1);
    }
    if (!active && !hovered) return null;
    return [
      BoxShadow(
        color: _t.border,
        offset: const Offset(2, 3),
        blurRadius: 0,
      ),
    ];
  }

  /// 侧栏主页按钮图标色（经典 = titleBrown 系 / 极光 = 强调色系）
  static Color homeIconColor({required bool active, required bool hovered}) {
    if (isModern) {
      return active
          ? _t.selectedAccent
          : (hovered ? _t.primaryText : _t.secondaryText);
    }
    return active
        ? _t.titleBrown
        : (hovered ? _t.titleBrown : _t.border);
  }

  /// 侧栏胶囊边框
  static Border navPillBorder({required bool active, required bool hovered}) {
    if (isModern) {
      return Border.fromBorderSide(BorderSide(
        color: active
            ? _t.navActiveBorder
            : (hovered ? _t.navInactiveBorder : Colors.transparent),
        width: active ? 1.0 : wHairline,
      ));
    }
    return Border.fromBorderSide(BorderSide(
      color: active
          ? _t.navActiveBorder
          : (hovered ? _t.navInactiveBorder : _t.navInactiveBorder.withAlpha(128)),
      width: 1.0,
    ));
  }

  /// 侧栏胶囊阴影（经典 = 激活 (0,1,6)@10%；极光 = e1 + 强调辉光）
  static List<BoxShadow>? navPillShadow({required bool active}) {
    if (!active) return null;
    if (isModern) {
      return [
        ...e1,
        BoxShadow(
          color: _t.selectedAccent.withAlpha(_alpha(0.28)),
          offset: const Offset(0, 2),
          blurRadius: 8,
        ),
      ];
    }
    return [
      BoxShadow(
        color: _t.shadowColor.withAlpha(_alpha(0.10)),
        offset: const Offset(0, 1),
        blurRadius: 6,
      ),
    ];
  }

  /// 侧栏胶囊/主页按钮图标色
  static Color navIconColor({required bool active, required bool hovered}) {
    if (isModern) {
      return active
          ? _t.navActiveBorder
          : (hovered ? _t.primaryText : _t.secondaryText);
    }
    return active
        ? _t.navActiveBorder
        : (hovered ? _t.border : _t.navInactiveBorder);
  }
}
