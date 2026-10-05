import 'package:flutter/material.dart';
import 'app_theme_manager.dart';

class AppColors {
  AppColors._();

  // ============ v3.5: 作用域主题覆盖 ============
  //
  // 背景：大屏模式 (BPM) 的导入窗口内嵌的是**桌面** `JoinPage`
  // (`lib/pages/join/**` 约 350 处 `AppColors` 引用、0 处 `Theme.of`),
  // 若不做处理，深色 Cinema 窗口里会突然出现一整块浅色桌面 UI。
  //
  // 方案：给 `AppColors` 加一层可推入/弹出的覆盖调色板——
  // - 桌面模式恒为空栈 → 所有 getter 行为与改造前**完全一致**，零风险；
  // - BPM 导入窗口打开期间推入由 `BpmPalette.toCTThemeData()` 生成的
  //   主题数据，`JoinPage` 及其子组件即刻呈现 BPM 配色；
  // - 窗口关闭时弹出，恢复桌面主题。
  //
  // ⚠️ 该栈是进程级静态状态，必须成对 push/pop (见 `_BpmImportWindow`)。
  static final List<CTThemeData> _overrideStack = <CTThemeData>[];

  /// 当前生效的主题数据（覆盖优先，否则取全局主题）
  static CTThemeData get _active => _overrideStack.isNotEmpty
      ? _overrideStack.last
      : AppThemeManager.colors;

  /// 推入覆盖主题
  static void pushOverride(CTThemeData data) {
    _overrideStack.add(data);
  }

  /// 弹出指定覆盖主题（按引用精确匹配，避免误弹他人）
  static void popOverride(CTThemeData data) {
    for (var i = _overrideStack.length - 1; i >= 0; i--) {
      if (identical(_overrideStack[i], data)) {
        _overrideStack.removeAt(i);
        return;
      }
    }
    if (_overrideStack.isNotEmpty) _overrideStack.removeLast();
  }

  /// 当前是否有覆盖生效（供调试/测试）
  static bool get hasOverride => _overrideStack.isNotEmpty;

  static Color get background => _active.background;
  static Color get pageBackground =>
      _active.hasBackgroundImage ? Colors.transparent : _active.background;
  static Color get sidebarBackground => _active.sidebarBackground;
  static Color get titleBarBackground => _active.titleBarBackground;
  static Color get primaryText => _active.primaryText;
  static Color get secondaryText => _active.secondaryText;
  static Color get border => _active.border;
  static Color get borderLight => _active.borderLight;
  static Color get buttonBackground => _active.buttonBackground;
  static Color get selectedAccent => _active.selectedAccent;
  static Color get dangerRed => _active.dangerRed;
  static Color get placeholderText => _active.placeholderText;
  static Color get placeholderBg => _active.placeholderBg;
  static Color get addCoverBg => _active.addCoverBg;
  static Color get shadowColor => _active.shadowColor;
  static Color get successGreen => _active.successGreen;
  static Color get successBg => _active.successBg;
  static Color get errorBg => _active.errorBg;
  static Color get hoverCloseBg => _active.hoverCloseBg;
  static Color get hoverCloseBorder => _active.hoverCloseBorder;
  static Color get inputHint => _active.inputHint;
  static Color get cardHoverBg => _active.cardHoverBg;
  static Color get navActiveBg => _active.navActiveBg;
  static Color get navActiveBorder => _active.navActiveBorder;
  static Color get navInactiveBorder => _active.navInactiveBorder;
  static Color get toggleBg => _active.toggleBg;
  static Color get toggleBorder => _active.toggleBorder;
  static Color get toggleIcon => _active.toggleIcon;
  static Brightness get brightness => _active.brightness;
  static bool get isDark => brightness == Brightness.dark;

  // --- 新增语义化令牌 ---
  static Color get placeholderCover => _active.placeholderCover;
  static Color get titleBrown => _active.titleBrown;
  static Color get starGold => _active.starGold;
  static Color get infoBlue => _active.infoBlue;
  static Color get brandBlue => _active.brandBlue;

  /// BUG-06: 信息按钮浅色背景（下载/前往库等 info 变体按钮使用）
  static Color get infoBg => _active.infoBg;

  /// v3.9 Aurora：警告语义色。
  ///
  /// 老主题未定义 warningAmber → 回退 starGold（与历史 SnackBar 警告档
  /// 使用 starGold 的行为逐像素一致）；aurora 档主题显式定义琥珀色。
  static Color get warningAmber => _active.warningAmber ?? _active.starGold;

  // ============ v4.0 探索详情页新增令牌 ============
  //
  // 回退策略分两类：
  // - 品牌新色（青蓝/紫）：无既有等价令牌 → 回退设计稿原值常量；
  // - 语义色（中性按钮底 / 强调分割线 / 红心 / 成功绿）：存在既有等价令牌
  //   → 回退到语义令牌，天然随主题明暗自适应（深色主题不会出现"近黑按钮"）。

  /// 「获取」主行动按钮底色（回退：设计稿青蓝 #2DA6D4）
  static Color get accentCyan => _active.accentCyan ?? const Color(0xFF2DA6D4);

  /// 「分享」中性按钮底色。
  ///
  /// 回退到 [primaryText]——浅色主题得到深色按钮面（配白色文字），
  /// 深色主题得到浅色按钮面（配深色文字），避免固定近黑在深色主题下"消失"。
  static Color get accentInk => _active.accentInk ?? _active.primaryText;

  /// 「上传」次行动按钮底色（回退：设计稿紫 #6841C4）
  static Color get accentViolet =>
      _active.accentViolet ?? const Color(0xFF6841C4);

  /// 头部区强调分割线（回退：[primaryText]）
  static Color get dividerStrong => _active.dividerStrong ?? _active.primaryText;

  /// 点赞（已点亮）色（回退：[dangerRed]）
  static Color get heartRed => _active.heartRed ?? _active.dangerRed;

  /// 反馈 / 成功语义绿（回退：[successGreen]）
  static Color get feedbackGreen =>
      _active.feedbackGreen ?? _active.successGreen;

  /// 实心强调按钮上的文字色（青蓝 / 紫底 → 恒为白色）
  static Color get onAccentSolid => Colors.white;

  /// [accentInk] 表面上的文字色：取其反色（浅色主题的文字用页面底色）
  static Color get onAccentInk =>
      _active.brightness == Brightness.dark ? _active.background : Colors.white;
}
