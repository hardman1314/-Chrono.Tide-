import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CTTheme {
  warmSun,
  darkNight,
  mint,
  sakura,
  ocean,
  twilight,
}

class CTThemeData {
  final String name;
  final String emoji;
  final String? description;
  final bool isFeatured;
  final String? backgroundImagePath;
  final double backgroundOverlayOpacity;
  final Color background;
  final Color sidebarBackground;
  final Color titleBarBackground;
  final Color primaryText;
  final Color secondaryText;
  final Color border;
  final Color borderLight;
  final Color buttonBackground;
  final Color selectedBlue;
  final Color dangerRed;
  final Color placeholderText;
  final Color placeholderBg;
  final Color addCoverBg;
  final Color shadowColor;
  final Color successGreen;
  final Color successBg;
  final Color errorBg;
  final Color hoverCloseBg;
  final Color hoverCloseBorder;
  final Color inputHint;
  final Color cardHoverBg;
  final Color navActiveBg;
  final Color navActiveBorder;
  final Color navInactiveBorder;
  final Color toggleBg;
  final Color toggleBorder;
  final Color toggleIcon;
  final Brightness brightness;

  const CTThemeData({
    required this.name,
    required this.emoji,
    this.description,
    this.isFeatured = false,
    this.backgroundImagePath,
    this.backgroundOverlayOpacity = 0.0,
    required this.background,
    required this.sidebarBackground,
    required this.titleBarBackground,
    required this.primaryText,
    required this.secondaryText,
    required this.border,
    required this.borderLight,
    required this.buttonBackground,
    required this.selectedBlue,
    required this.dangerRed,
    required this.placeholderText,
    required this.placeholderBg,
    required this.addCoverBg,
    required this.shadowColor,
    required this.successGreen,
    required this.successBg,
    required this.errorBg,
    required this.hoverCloseBg,
    required this.hoverCloseBorder,
    required this.inputHint,
    required this.cardHoverBg,
    required this.navActiveBg,
    required this.navActiveBorder,
    required this.navInactiveBorder,
    required this.toggleBg,
    required this.toggleBorder,
    required this.toggleIcon,
    required this.brightness,
  });

  bool get hasBackgroundImage =>
      backgroundImagePath != null && backgroundImagePath!.isNotEmpty;
}

class AppThemeManager extends ChangeNotifier {
  static AppThemeManager? _instance;
  static AppThemeManager get instance => _instance ??= AppThemeManager._();

  AppThemeManager._();

  CTTheme _currentTheme = CTTheme.warmSun;
  CTTheme get currentTheme => _currentTheme;

  static const Map<CTTheme, CTThemeData> _themes = {
    CTTheme.warmSun: CTThemeData(
      name: '暖阳',
      emoji: '🌞',
      description: '经典暖棕复古风格',
      isFeatured: false,
      brightness: Brightness.light,
      background: Color(0xFFFDFBF7),
      sidebarBackground: Color(0xFFFBF6EF),
      titleBarBackground: Color(0xFFFBF6EF),
      primaryText: Color(0xFF5C4A3D),
      secondaryText: Color(0xFFA08264),
      border: Color(0xFF8B7355),
      borderLight: Color(0x338B7355),
      buttonBackground: Color(0xFFF0E6D2),
      selectedBlue: Color(0xFFB4D4FF),
      dangerRed: Color(0xFFD4183D),
      placeholderText: Color(0xFFC4B3A1),
      placeholderBg: Color(0xFFF5F1E8),
      addCoverBg: Color(0xFFE9E0D1),
      shadowColor: Color(0x408B7355),
      successGreen: Color(0xFF4CAF50),
      successBg: Color(0xFFE8F5E9),
      errorBg: Color(0xFFFFE6EA),
      hoverCloseBg: Color(0xFFFFEBEE),
      hoverCloseBorder: Color(0xFFEF5350),
      inputHint: Color(0x99A08264),
      cardHoverBg: Color(0xFFF5EDE6),
      navActiveBg: Color(0xFFFFFFFF),
      navActiveBorder: Color(0xFFA07840),
      navInactiveBorder: Color(0xFFC8B49A),
      toggleBg: Color(0xFFE8E0D0),
      toggleBorder: Color(0xFFC8B49A),
      toggleIcon: Color(0xFF5C3A1A),
    ),
    CTTheme.darkNight: CTThemeData(
      name: '暗夜',
      emoji: '🌙',
      description: '深色护眼模式',
      isFeatured: false,
      brightness: Brightness.dark,
      background: Color(0xFF1A1714),
      sidebarBackground: Color(0xFF242019),
      titleBarBackground: Color(0xFF242019),
      primaryText: Color(0xFFE8E0D0),
      secondaryText: Color(0xFF9B9080),
      border: Color(0xFF3D3530),
      borderLight: Color(0x333D3530),
      buttonBackground: Color(0xFF2D2824),
      selectedBlue: Color(0xFF5A7A9B),
      dangerRed: Color(0xFFE05555),
      placeholderText: Color(0xFF6D6358),
      placeholderBg: Color(0xFF2A2520),
      addCoverBg: Color(0xFF2D2824),
      shadowColor: Color(0x40000000),
      successGreen: Color(0xFF66BB6A),
      successBg: Color(0xFF1B3A1B),
      errorBg: Color(0xFF3A1B1B),
      hoverCloseBg: Color(0xFF3A1B1B),
      hoverCloseBorder: Color(0xFFE05555),
      inputHint: Color(0x999B9080),
      cardHoverBg: Color(0xFF2D2824),
      navActiveBg: Color(0xFFFFFFFF),
      navActiveBorder: Color(0xFF5A4A3A),
      navInactiveBorder: Color(0xFF3D3530),
      toggleBg: Color(0xFF2D2824),
      toggleBorder: Color(0xFF3D3530),
      toggleIcon: Color(0xFFC4B3A1),
    ),
    CTTheme.mint: CTThemeData(
      name: '墨绿金',
      emoji: '🌊',
      description: '神秘墨绿流金，奢华魔幻',
      isFeatured: true,
      backgroundImagePath: 'assets/images/themes/dark_emerald_gold.png',
      backgroundOverlayOpacity: 0.20,
      brightness: Brightness.dark,
      background: Color(0xFF1A3D35),
      sidebarBackground: Color(0xFF15302A),
      titleBarBackground: Color(0xFF15302A),
      primaryText: Color(0xFFF0F4EC),
      secondaryText: Color(0xFFB8D4C0),
      border: Color(0xFF4A9B6A),
      borderLight: Color(0x334A9B6A),
      buttonBackground: Color(0x99D4AF37),
      selectedBlue: Color(0xFFE8C84A),
      dangerRed: Color(0xFFE86A6A),
      placeholderText: Color(0xFF7A9B88),
      placeholderBg: Color(0x25D4AF37),
      addCoverBg: Color(0x30D4AF37),
      shadowColor: Color(0x70D4AF37),
      successGreen: Color(0xFF8DDD8D),
      successBg: Color(0x252A5A3E),
      errorBg: Color(0x255A2A2A),
      hoverCloseBg: Color(0x255A2A2A),
      hoverCloseBorder: Color(0xFFE86A6A),
      inputHint: Color(0x99B8D4C0),
      cardHoverBg: Color(0x18FFFFFF),
      navActiveBg: Color(0xD01A3D35),
      navActiveBorder: Color(0xFFE8C84A),
      navInactiveBorder: Color(0x604A9B6A),
      toggleBg: Color(0x99D4AF37),
      toggleBorder: Color(0xFF4A9B6A),
      toggleIcon: Color(0xFFE8C84A),
    ),
    CTTheme.sakura: CTThemeData(
      name: '樱花浪漫',
      emoji: '🌸',
      description: '粉色樱花飘落，梦幻唯美',
      isFeatured: true,
      backgroundImagePath: 'assets/images/themes/sakura.png',
      backgroundOverlayOpacity: 0.25,
      brightness: Brightness.light,
      background: Color(0xFFFDF2F6),
      sidebarBackground: Color(0xFFF9ECF1),
      titleBarBackground: Color(0xFFF9ECF1),
      primaryText: Color(0xFF5C2E3E),
      secondaryText: Color(0xFFB07A90),
      border: Color(0xFFD4849A),
      borderLight: Color(0x33D4849A),
      buttonBackground: Color(0xCCFFB7C5),
      selectedBlue: Color(0xFFE88BA0),
      dangerRed: Color(0xFFC44060),
      placeholderText: Color(0xFFCC99AA),
      placeholderBg: Color(0x1AFFB7C5),
      addCoverBg: Color(0x25FFB7C5),
      shadowColor: Color(0x40D4849A),
      successGreen: Color(0xFF4CAF50),
      successBg: Color(0x20E8F5E9),
      errorBg: Color(0x20FFE6EA),
      hoverCloseBg: Color(0x20FFE6EA),
      hoverCloseBorder: Color(0xFFEF5350),
      inputHint: Color(0x99B07A90),
      cardHoverBg: Color(0x10FFB7C5),
      navActiveBg: Color(0xE0FDF2F6),
      navActiveBorder: Color(0xFFE88BA0),
      navInactiveBorder: Color(0x80D4849A),
      toggleBg: Color(0xCCFFB7C5),
      toggleBorder: Color(0xFFD4849A),
      toggleIcon: Color(0xFFC44060),
    ),
    CTTheme.ocean: CTThemeData(
      name: '蓝天白云',
      emoji: '☁️',
      description: '清新蓝天白云，自由开阔',
      isFeatured: true,
      backgroundImagePath: 'assets/images/themes/blue_sky.png',
      backgroundOverlayOpacity: 0.20,
      brightness: Brightness.light,
      background: Color(0xFFE8F4FC),
      sidebarBackground: Color(0xFFDEEBF7),
      titleBarBackground: Color(0xFFDEEBF7),
      primaryText: Color(0xFF2A4A6A),
      secondaryText: Color(0xFF6A8FA8),
      border: Color(0xFF7BAACC),
      borderLight: Color(0x337BAACC),
      buttonBackground: Color(0xBFE8F4FC),
      selectedBlue: Color(0xFF4A90D9),
      dangerRed: Color(0xFFD44040),
      placeholderText: Color(0xFF8BB8CC),
      placeholderBg: Color(0x1587CEEB),
      addCoverBg: Color(0x2087CEEB),
      shadowColor: Color(0x407BAACC),
      successGreen: Color(0xFF3A9D5A),
      successBg: Color(0x20E8F5E9),
      errorBg: Color(0x20FFE6EA),
      hoverCloseBg: Color(0x20FFE6EA),
      hoverCloseBorder: Color(0xFFEF5350),
      inputHint: Color(0x996A8FA8),
      cardHoverBg: Color(0x1087CEEB),
      navActiveBg: Color(0xDDE8F4FC),
      navActiveBorder: Color(0xFF4A90D9),
      navInactiveBorder: Color(0x607BAACC),
      toggleBg: Color(0xBFE8F4FC),
      toggleBorder: Color(0xFF7BAACC),
      toggleIcon: Color(0xFF2A5A8A),
    ),
    CTTheme.twilight: CTThemeData(
      name: '暮光',
      emoji: '🔮',
      description: '深邃紫调优雅',
      isFeatured: false,
      brightness: Brightness.dark,
      background: Color(0xFF1A1520),
      sidebarBackground: Color(0xFF241D2A),
      titleBarBackground: Color(0xFF241D2A),
      primaryText: Color(0xFFE0D8E8),
      secondaryText: Color(0xFF9B8AA8),
      border: Color(0xFF4A3D55),
      borderLight: Color(0x334A3D55),
      buttonBackground: Color(0xFF2D2435),
      selectedBlue: Color(0xFF7A6A9B),
      dangerRed: Color(0xFFE05555),
      placeholderText: Color(0xFF6D5E7A),
      placeholderBg: Color(0xFF2A2230),
      addCoverBg: Color(0xFF2D2435),
      shadowColor: Color(0x40000000),
      successGreen: Color(0xFF66BB6A),
      successBg: Color(0xFF1B3A1B),
      errorBg: Color(0xFF3A1B2A),
      hoverCloseBg: Color(0xFF3A1B2A),
      hoverCloseBorder: Color(0xFFE05555),
      inputHint: Color(0x999B8AA8),
      cardHoverBg: Color(0xFF2D2435),
      navActiveBg: Color(0xFFFFFFFF),
      navActiveBorder: Color(0xFF6A5580),
      navInactiveBorder: Color(0xFF4A3D55),
      toggleBg: Color(0xFF2D2435),
      toggleBorder: Color(0xFF4A3D55),
      toggleIcon: Color(0xFFC4B3D4),
    ),
  };

  CTThemeData get current => _themes[_currentTheme]!;

  static CTThemeData get colors => instance.current;

  static CTThemeData themeData(CTTheme theme) => _themes[theme]!;

  static List<CTTheme> get allThemes => CTTheme.values;

  static List<CTTheme> get featuredThemes =>
      CTTheme.values.where((t) => _themes[t]!.isFeatured).toList();

  static List<CTTheme> get standardThemes =>
      CTTheme.values.where((t) => !_themes[t]!.isFeatured).toList();

  Future<void> setTheme(CTTheme theme) async {
    if (_currentTheme == theme) return;
    _currentTheme = theme;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme', theme.name);
  }

  Future<void> loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_theme');
    if (saved != null) {
      final theme = CTTheme.values.firstWhere(
        (t) => t.name == saved,
        orElse: () => CTTheme.warmSun,
      );
      _currentTheme = theme;
      notifyListeners();
    }
  }
}
