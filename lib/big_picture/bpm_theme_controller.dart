import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_manager.dart';
import '../theme/background_image_config.dart';

/// BPM 主题模式 (v3.5)
///
/// 大屏模式独立于桌面主题系统,自带两套调色板:
/// - [cinemaDark] Cinema 深夜蓝黑 + 樱粉/雾蓝 (v3 沿用)
/// - [oceanLight] QQ 地海蔚蓝风格 (现代白 + 渐变微光蓝)
enum BpmThemeMode {
  cinemaDark,
  oceanLight;

  /// 切换按钮语义标签
  String get label => this == BpmThemeMode.cinemaDark ? '切换浅色主题' : '切换深色主题';
}

/// BPM 调色板 (v3.5)
///
/// 把原先 [BpmColors] 的静态常量收敛为两套 const 实例,
/// 由 [BpmThemeController] 按当前模式选择。
///
/// 命名沿用 v3 令牌名 (deepBase/panelGlass/cherryRose...),
/// 保证约 300 处既有引用零语义变化;
/// 新增令牌用于本次头部栏/侧边栏/底部栏/遮罩改造。
class BpmPalette {
  final BpmThemeMode mode;
  final Brightness brightness;

  // ===== v3 既有令牌 (深色值保持原样,勿改) =====
  final Color deepBase;
  final Color deepPanel;
  final Color panelGlass;
  final Color scrimStrong;
  final Color scrimMid;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color mistBlue;
  final Color mistBlueSoft;
  final Color cherryRose;
  final Color cherryRoseBorder;
  final Color mistBlueBorder;
  final LinearGradient playButtonGradient;
  final Color playButtonForeground;
  final Color micaSurface;
  final Color micaSheen;
  final Color micaBorder;
  final Color micaSection;

  // ===== v3.5 新增令牌 =====
  /// 焦点环/选中描边色 (原由 AppColors.selectedAccent 提供,与主题打架)
  final Color selectedAccent;

  /// 危险/警示强调色
  final Color dangerAccent;

  /// 危险色弱化 (透明度 .20)
  final Color dangerAccentSoft;

  /// 上下文菜单表面色
  final Color menuSurface;

  /// 页面底渐变 (深色主题的"渐变发微光"基底层)
  final List<Color> baseGradientColors;

  /// 页面底微光色 (径向叠加,提升沉浸感)
  final Color glowColor;

  /// backdrop 纵向遮罩 (4 段)
  final List<Color> backdropScrimV;

  /// backdrop 纵向遮罩 —— **OP 视频播放态**（比静态态更轻，视频要「尽可能清晰」）
  final List<Color> backdropScrimVPlaying;

  /// backdrop 横向遮罩 (4 段)
  final List<Color> backdropScrimH;

  /// backdrop 横向遮罩 —— **OP 视频播放态**
  final List<Color> backdropScrimHPlaying;

  /// 底部栏渐变 (首段趋近全透明 → 栏边界消失)
  final List<Color> shelfScrim;

  /// 侧边栏玻璃底色
  final Color railGlass;

  /// 侧边栏环境阴影色 (v3.6-re: 一团半透明暗部的颜色, 中心浓外缘化开)
  final Color railShadow;

  /// 侧边栏选中图标的辉光色 (v3.6-re: 用户指定「柔和蓝色发光」)
  final Color navGlowBlue;

  /// 侧边栏描边
  final Color railBorder;

  /// 头部栏玻璃底色
  final Color topBarGlass;

  /// 头部栏描边
  final Color topBarBorder;

  /// 头部栏文字/图标色
  final Color topBarInk;

  /// 在线状态色
  final Color statusOnline;

  /// 离线状态色
  final Color statusOffline;

  /// 封面占位渐变
  final List<Color> placeholderGradient;

  /// 未选中卡片压暗层色
  final Color cardMask;

  /// hero 大标题阴影 (深底用暗影,浅底用亮影)
  final Color heroTextShadow;

  /// hero 大标题辉光
  final Color heroTextGlow;

  /// 次级文字阴影
  final Color subTextShadow;

  /// 封面底部渐变 (衬白色标题,两套主题一致)
  final Color coverGradientBottom;

  /// 封面标题文字色
  final Color coverLabelText;

  /// 卡片投影色
  final Color cardShadow;

  const BpmPalette({
    required this.mode,
    required this.brightness,
    required this.deepBase,
    required this.deepPanel,
    required this.panelGlass,
    required this.scrimStrong,
    required this.scrimMid,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.mistBlue,
    required this.mistBlueSoft,
    required this.cherryRose,
    required this.cherryRoseBorder,
    required this.mistBlueBorder,
    required this.playButtonGradient,
    required this.playButtonForeground,
    required this.micaSurface,
    required this.micaSheen,
    required this.micaBorder,
    required this.micaSection,
    required this.selectedAccent,
    required this.dangerAccent,
    required this.dangerAccentSoft,
    required this.menuSurface,
    required this.baseGradientColors,
    required this.glowColor,
    required this.backdropScrimV,
    required this.backdropScrimVPlaying,
    required this.backdropScrimH,
    required this.backdropScrimHPlaying,
    required this.shelfScrim,
    required this.railGlass,
    required this.railShadow,
    required this.navGlowBlue,
    required this.railBorder,
    required this.topBarGlass,
    required this.topBarBorder,
    required this.topBarInk,
    required this.statusOnline,
    required this.statusOffline,
    required this.placeholderGradient,
    required this.cardMask,
    required this.heroTextShadow,
    required this.heroTextGlow,
    required this.subTextShadow,
    required this.coverGradientBottom,
    required this.coverLabelText,
    required this.cardShadow,
  });

  /// 深色主题 — Cinema 深夜蓝黑 (v3 沿用 + v3.5 微光渐变)
  static const BpmPalette dark = BpmPalette(
    mode: BpmThemeMode.cinemaDark,
    brightness: Brightness.dark,
    deepBase: Color(0xFF0C0F16),
    deepPanel: Color(0xFF101620),
    panelGlass: Color(0x6B101620),
    scrimStrong: Color(0xDE0C0F16),
    scrimMid: Color(0x8C0C0F16),
    textPrimary: Color(0xFFFFF7F8),
    textSecondary: Color(0xC0FFF7F8),
    textMuted: Color(0x80FFF7F8),
    mistBlue: Color(0xFF9ED0EA),
    mistBlueSoft: Color(0xFFB8D4E3),
    cherryRose: Color(0xFFE89AA8),
    cherryRoseBorder: Color(0x38E89AA8),
    mistBlueBorder: Color(0x38B8D4E3),
    playButtonGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFFFF2F6), Color(0xFFE89AA8), Color(0xFFB8D4E3)],
    ),
    playButtonForeground: Color(0xFF21141A),
    micaSurface: Color(0x9C0E1420),
    micaSheen: Color(0x1AFFFFFF),
    micaBorder: Color(0x339ED0EA),
    micaSection: Color(0x14101620),
    selectedAccent: Color(0xFF9ED0EA),
    dangerAccent: Color(0xFFFF7B8A),
    dangerAccentSoft: Color(0x33FF8A9B),
    menuSurface: Color(0xF2101620),
    // 深色主题底: 深夜蓝黑 → 深蓝 → 更暗 (微光由 glowColor 径向叠加)
    baseGradientColors: [
      Color(0xFF0C0F16),
      Color(0xFF111A28),
      Color(0xFF0A0D13),
    ],
    glowColor: Color(0x382E6E9E),
    // v3.5: 遮罩整体减轻 (原 0x6B/0xDB 过重,画面发灰)
    backdropScrimV: [
      Color(0x3D0C0F16),
      Color(0x000C0F16),
      Color(0x000C0F16),
      Color(0xA60C0F16),
    ],
    // 播放态：底段 0xA6 → 0x5A（顶段保持，头部栏文字仍可读）
    backdropScrimVPlaying: [
      Color(0x3D0C0F16),
      Color(0x000C0F16),
      Color(0x000C0F16),
      Color(0x5A0C0F16),
    ],
    backdropScrimH: [
      Color(0x8A0C0F16),
      Color(0x3D0C0F16),
      Color(0x000C0F16),
      Color(0x2E0C0F16),
    ],
    // 播放态：左段 0x8A → 0x4A（rail 侧仍有压暗，但视频明显更亮）
    backdropScrimHPlaying: [
      Color(0x4A0C0F16),
      Color(0x2E0C0F16),
      Color(0x000C0F16),
      Color(0x2E0C0F16),
    ],
    // 底部栏: 首段全透明 → 栏边界消失
    shelfScrim: [Color(0x000C0F16), Color(0x610C0F16)],
    // v3.6-re: 玻璃底色 8% 纯为「毛」, 阴影浓度由 _RailAmbientPainter 控制
    railGlass: Color(0x140A0F18),
    railShadow: Color(0xFF04070C),
    navGlowBlue: Color(0xFF6FB4F0),
    railBorder: Color(0x2EE89AA8),
    topBarGlass: Color(0x400C0F16),
    topBarBorder: Color(0x14FFFFFF),
    topBarInk: Color(0xFFFFF7F8),
    statusOnline: Color(0xFF6FD08C),
    statusOffline: Color(0xFFE0879A),
    placeholderGradient: [Color(0xFF3A2230), Color(0xFF0C0F16)],
    cardMask: Color(0xFF0C0F16),
    heroTextShadow: Color(0xE0111620),
    heroTextGlow: Color(0x38E89AA8),
    subTextShadow: Color(0xD9111620),
    coverGradientBottom: Color(0xD9000000),
    coverLabelText: Color(0xFFFFF8EA),
    cardShadow: Color(0xFF0C0F16),
  );

  /// 浅色主题 — QQ 地海蔚蓝 (现代白 + 渐变微光蓝)
  static const BpmPalette light = BpmPalette(
    mode: BpmThemeMode.oceanLight,
    brightness: Brightness.light,
    deepBase: Color(0xFFF1F8FF),
    deepPanel: Color(0xFFFFFFFF),
    panelGlass: Color(0x8CFFFFFF),
    scrimStrong: Color(0xCCE7F3FE),
    scrimMid: Color(0x66E7F3FE),
    textPrimary: Color(0xFF11395C),
    textSecondary: Color(0xFF3D7099),
    textMuted: Color(0xFF7FA8C4),
    mistBlue: Color(0xFF1F87D6),
    mistBlueSoft: Color(0xFF4FB0F0),
    cherryRose: Color(0xFF2E9BE6),
    cherryRoseBorder: Color(0x383AA6F0),
    mistBlueBorder: Color(0x382E9BE6),
    playButtonGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF7ED2FF), Color(0xFF2E9BE6), Color(0xFF5BC8F5)],
    ),
    playButtonForeground: Color(0xFFFFFFFF),
    micaSurface: Color(0xE8FFFFFF),
    micaSheen: Color(0x3DFFFFFF),
    micaBorder: Color(0x333AA6F0),
    micaSection: Color(0x142E9BE6),
    selectedAccent: Color(0xFF2E9BE6),
    dangerAccent: Color(0xFFE4574F),
    dangerAccentSoft: Color(0x33E4574F),
    menuSurface: Color(0xF7FFFFFF),
    baseGradientColors: [
      Color(0xFFF8FCFF),
      Color(0xFFE6F2FE),
      Color(0xFFDCECFB),
    ],
    glowColor: Color(0x2E5FA8D6),
    backdropScrimV: [
      Color(0x30FFFFFF),
      Color(0x00FFFFFF),
      Color(0x00FFFFFF),
      Color(0x6BEDF6FF),
    ],
    // 播放态：底段 0x6B → 0x3D
    backdropScrimVPlaying: [
      Color(0x30FFFFFF),
      Color(0x00FFFFFF),
      Color(0x00FFFFFF),
      Color(0x3DEDF6FF),
    ],
    backdropScrimH: [
      Color(0x61EDF6FF),
      Color(0x2EEDF6FF),
      Color(0x00EDF6FF),
      Color(0x26EDF6FF),
    ],
    // 播放态：左段 0x61 → 0x38
    backdropScrimHPlaying: [
      Color(0x38EDF6FF),
      Color(0x1FEDF6FF),
      Color(0x00EDF6FF),
      Color(0x26EDF6FF),
    ],
    shelfScrim: [Color(0x00EDF6FF), Color(0x5CFFFFFF)],
    railGlass: Color(0x2BF2F9FF),
    railShadow: Color(0xFF7FA8C4),
    navGlowBlue: Color(0xFF5AA7E6),
    railBorder: Color(0x2E3AA6F0),
    topBarGlass: Color(0x59FFFFFF),
    topBarBorder: Color(0x142E9BE6),
    topBarInk: Color(0xFF11395C),
    statusOnline: Color(0xFF2FA36B),
    statusOffline: Color(0xFFD1574F),
    placeholderGradient: [Color(0xFFDCEBF9), Color(0xFFEFF7FE)],
    cardMask: Color(0xFF9BC4E4),
    heroTextShadow: Color(0xE6FFFFFF),
    heroTextGlow: Color(0x333AA6F0),
    subTextShadow: Color(0xD9FFFFFF),
    coverGradientBottom: Color(0xCC000000),
    coverLabelText: Color(0xFFFFFFFF),
    cardShadow: Color(0xFF6E9BC0),
  );

  /// 把当前 BPM 调色板映射为 [CTThemeData]
  ///
  /// 用途: BPM 导入窗口内嵌桌面 `JoinPage`(约 350 处 `AppColors` 引用),
  /// 通过 `AppColors` 的作用域覆盖层推入本结果,使其内容与 BPM 主题一致,
  /// 而无需改动 `lib/pages/join/**` 任何一行。
  CTThemeData toCTThemeData() {
    final isDarkMode = brightness == Brightness.dark;
    return CTThemeData(
      id: 'bpm_${mode.name}',
      source: CTThemeSource.builtin,
      name: isDarkMode ? 'BPM Cinema' : 'BPM 地海蔚蓝',
      emoji: isDarkMode ? '🌙' : '🌊',
      description: '大屏模式内置主题',
      brightness: brightness,
      backgroundImage: const BackgroundImageConfig.none(),
      seedColor: mistBlue,
      background: deepBase,
      sidebarBackground: deepPanel,
      titleBarBackground: deepPanel,
      primaryText: textPrimary,
      secondaryText: textSecondary,
      border: cherryRose,
      borderLight: cherryRoseBorder,
      buttonBackground: panelGlass,
      selectedAccent: selectedAccent,
      dangerRed: dangerAccent,
      placeholderText: textMuted,
      placeholderBg: micaSection,
      addCoverBg: micaSection,
      shadowColor: cardShadow.withOpacity(0.4),
      successGreen: statusOnline,
      successBg: statusOnline.withOpacity(0.16),
      errorBg: dangerAccent.withOpacity(0.16),
      hoverCloseBg: dangerAccentSoft,
      hoverCloseBorder: dangerAccent,
      inputHint: textMuted,
      cardHoverBg: micaSection,
      // v3.6-re: 显式原值 —— 导入窗口的 JoinPage 激活底色不跟随侧栏轻量化
      navActiveBg: identical(this, dark)
          ? const Color(0x52101620)
          : const Color(0x59FFFFFF),
      navActiveBorder: mistBlue,
      navInactiveBorder: railBorder,
      toggleBg: panelGlass,
      toggleBorder: railBorder,
      toggleIcon: textPrimary,
      placeholderCover: micaSection,
      titleBrown: textPrimary,
      starGold: const Color(0xFFD4A017),
      infoBlue: mistBlue,
      brandBlue: cherryRose,
      infoBg: micaSection,
    );
  }
}

/// BPM 主题控制器 (v3.5)
///
/// 单例 [ChangeNotifier],仿 [AppThemeManager] 的用法:
/// - [BpmColors] 静态门面通过 [palette] 取色,既有 300 处引用零改动
/// - 头部栏主题切换按钮调用 [toggle]
/// - 模式持久化到 SharedPreferences (键 `bpm_theme_mode`)
class BpmThemeController extends ChangeNotifier {
  BpmThemeController._();
  static final BpmThemeController instance = BpmThemeController._();

  static const String prefKey = 'bpm_theme_mode';

  BpmThemeMode _mode = BpmThemeMode.cinemaDark;

  BpmThemeMode get mode => _mode;

  bool get isDark => _mode == BpmThemeMode.cinemaDark;

  BpmPalette get palette => isDark ? BpmPalette.dark : BpmPalette.light;

  /// 启动时恢复上次选择 (异常/无记录 → 深色)
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefKey);
      if (saved != null) {
        for (final m in BpmThemeMode.values) {
          if (m.name == saved) {
            _mode = m;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('[BPM] 主题模式读取失败(忽略): $e');
    }
    notifyListeners();
  }

  Future<void> setMode(BpmThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKey, mode.name);
    } catch (e) {
      debugPrint('[BPM] 主题模式持久化失败: $e');
    }
  }

  Future<void> toggle() => setMode(
        isDark ? BpmThemeMode.oceanLight : BpmThemeMode.cinemaDark,
      );
}
