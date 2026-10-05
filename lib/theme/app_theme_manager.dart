import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'background_image_config.dart';
import 'theme_registry.dart';
import 'theme_storage.dart';

/// 内置主题枚举（保留作为内置主题 id 来源与分组依据）
///
/// v3.0 P0 重构说明：
/// - `CTTheme` 枚举保留，每个枚举值的 name 即为对应内置主题的 String id
///   （例如 CTTheme.warmSun.name == 'warmSun'）
/// - `AppThemeManager` 内部从 `CTTheme` 改为 `String` id 驱动
/// - 内置主题 id = 枚举 name；用户主题 id = UUID
/// - 公开 API `currentTheme` / `setTheme(CTTheme)` / `standardThemes` /
///   `featuredThemes` / `themeData(CTTheme)` 全部保留，向后兼容
enum CTTheme {
  warmSun,
  frost,
  obsidian,
  mint,
  sakura,
  ocean,
}

/// 主题来源
enum CTThemeSource {
  /// 内置主题（编译期 const 定义）
  builtin,

  /// 用户自定义主题（runtime fromJson 构造）
  user,
}

/// v3.9 Aurora：主题风格档
///
/// 主题不仅带调色板，还带"形状语言"（线宽/圆角/阴影/交互反馈/氛围层）：
/// - [classicHanddrawn]：现有手绘风（默认值）——6 套老主题不写此字段，
///   `AppStyle` 全部取值与历史硬编码逐像素一致（有回归测试锁定）；
/// - [aurora]：现代极光档——纯净表面 + 发丝线 + 柔和海拔 + 交互辉光 + 氛围层。
///   设计方案：docs/DEV/features/modern_theme_aurora_redesign.md
enum CTVisualStyle {
  classicHanddrawn,
  aurora,
}

class CTThemeData {
  /// 主题唯一 id。内置主题 = CTTheme 枚举 name；用户主题 = UUID
  final String id;

  /// 主题来源
  final CTThemeSource source;

  final String name;
  final String emoji;
  final String? description;
  final bool isFeatured;

  /// 背景图配置（v3.0 P0：收敛原 backgroundImagePath + backgroundOverlayOpacity）
  final BackgroundImageConfig backgroundImage;

  /// Material 3 ColorScheme 的种子色，用于动态生成与主题配套的配色方案
  /// 修复 BUG-01：原实现中 ColorScheme.fromSeed 硬编码为 0xFF8B7355，
  /// 导致 Material 组件在所有主题中显示暖棕色
  final Color seedColor;
  final Color background;
  final Color sidebarBackground;
  final Color titleBarBackground;
  final Color primaryText;
  final Color secondaryText;
  final Color border;
  final Color borderLight;
  final Color buttonBackground;
  final Color selectedAccent;
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
  final Color placeholderCover;
  final Color titleBrown;
  final Color starGold;
  final Color infoBlue;
  final Color brandBlue;

  /// BUG-06: 信息按钮背景色（浅蓝系），用于下载/前往库等 info 变体按钮
  final Color infoBg;

  /// v3.9 Aurora：警告语义色（可空）。
  ///
  /// 为保证老主题观感逐像素不变，采用"可空 + 解析回退"设计：
  /// 未定义时 `AppColors.warningAmber` 回退到 [starGold]（= 历史 SnackBar 警告档行为）；
  /// 仅 aurora 档主题显式定义自己的琥珀色。
  final Color? warningAmber;

  /// v4.0 探索详情页重构：新增 6 个语义色令牌（可空 + 解析回退）。
  ///
  /// 同样采用"可空 + 回退"设计，保证**旧主题 / 旧 .cttheme JSON 零影响**：
  /// 未定义时由 [AppColors] 回退到语义最接近的既有令牌（见各 getter 注释），
  /// 暖阳主题显式给出设计稿原值（#2DA6D4 / #262626 / #6841C4 / #2B2B2B /
  /// #DD1B24 / #00AD38），从而在新探索详情页做到 1:1 复刻。
  ///
  /// - [accentCyan]   「获取」主行动按钮底色
  /// - [accentInk]    「分享」中性按钮底色（浅色主题=近黑，深色主题=近白）
  /// - [accentViolet] 「上传」次行动按钮底色
  /// - [dividerStrong] 头部与内容之间的强调分割线
  /// - [heartRed]     点赞（已点亮）色
  /// - [feedbackGreen] 反馈 / 成功语义绿
  final Color? accentCyan;
  final Color? accentInk;
  final Color? accentViolet;
  final Color? dividerStrong;
  final Color? heartRed;
  final Color? feedbackGreen;

  /// v3.9 Aurora：风格档（默认 = 现有手绘档，老主题零影响）
  final CTVisualStyle visualStyle;

  final Brightness brightness;

  const CTThemeData({
    required this.id,
    this.source = CTThemeSource.builtin,
    required this.name,
    required this.emoji,
    this.description,
    this.isFeatured = false,
    this.backgroundImage = const BackgroundImageConfig.none(),
    this.warningAmber,
    this.accentCyan,
    this.accentInk,
    this.accentViolet,
    this.dividerStrong,
    this.heartRed,
    this.feedbackGreen,
    this.visualStyle = CTVisualStyle.classicHanddrawn,
    required this.seedColor,
    required this.background,
    required this.sidebarBackground,
    required this.titleBarBackground,
    required this.primaryText,
    required this.secondaryText,
    required this.border,
    required this.borderLight,
    required this.buttonBackground,
    required this.selectedAccent,
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
    required this.placeholderCover,
    required this.titleBrown,
    required this.starGold,
    required this.infoBlue,
    required this.brandBlue,
    required this.infoBg,
    required this.brightness,
  });

  // ============ 兼容旧 API（backgroundImagePath / backgroundOverlayOpacity / hasBackgroundImage） ============

  /// 兼容旧 API：返回 bundled asset 路径
  /// 注意：仅 bundled 来源时返回路径；file 来源应通过 BackgroundImageResolver 处理
  String? get backgroundImagePath => backgroundImage.legacyAssetPath;

  /// 兼容旧 API：背景遮罩透明度
  double get backgroundOverlayOpacity => backgroundImage.legacyOverlayOpacity;

  /// 兼容旧 API：是否有背景图
  bool get hasBackgroundImage => backgroundImage.hasImage;

  bool get isUserTheme => source == CTThemeSource.user;

  /// BUG-04: 主题切换颜色插值，用于实现 250ms 渐变过渡动画。
  /// 所有 Color 字段通过 Color.lerp 线性插值；
  /// 非颜色字段（id/name/emoji/路径/brightness/source）在 t=0.5 时切换。
  static CTThemeData lerp(CTThemeData a, CTThemeData b, double t) {
    // 非颜色字段在过渡中点切换
    final useB = t >= 0.5;
    return CTThemeData(
      id: useB ? b.id : a.id,
      source: useB ? b.source : a.source,
      name: useB ? b.name : a.name,
      emoji: useB ? b.emoji : a.emoji,
      description: useB ? b.description : a.description,
      isFeatured: useB ? b.isFeatured : a.isFeatured,
      backgroundImage: useB ? b.backgroundImage : a.backgroundImage,
      seedColor: Color.lerp(a.seedColor, b.seedColor, t)!,
      background: Color.lerp(a.background, b.background, t)!,
      sidebarBackground:
          Color.lerp(a.sidebarBackground, b.sidebarBackground, t)!,
      titleBarBackground:
          Color.lerp(a.titleBarBackground, b.titleBarBackground, t)!,
      primaryText: Color.lerp(a.primaryText, b.primaryText, t)!,
      secondaryText: Color.lerp(a.secondaryText, b.secondaryText, t)!,
      border: Color.lerp(a.border, b.border, t)!,
      borderLight: Color.lerp(a.borderLight, b.borderLight, t)!,
      buttonBackground: Color.lerp(a.buttonBackground, b.buttonBackground, t)!,
      selectedAccent: Color.lerp(a.selectedAccent, b.selectedAccent, t)!,
      dangerRed: Color.lerp(a.dangerRed, b.dangerRed, t)!,
      placeholderText: Color.lerp(a.placeholderText, b.placeholderText, t)!,
      placeholderBg: Color.lerp(a.placeholderBg, b.placeholderBg, t)!,
      addCoverBg: Color.lerp(a.addCoverBg, b.addCoverBg, t)!,
      shadowColor: Color.lerp(a.shadowColor, b.shadowColor, t)!,
      successGreen: Color.lerp(a.successGreen, b.successGreen, t)!,
      successBg: Color.lerp(a.successBg, b.successBg, t)!,
      errorBg: Color.lerp(a.errorBg, b.errorBg, t)!,
      hoverCloseBg: Color.lerp(a.hoverCloseBg, b.hoverCloseBg, t)!,
      hoverCloseBorder: Color.lerp(a.hoverCloseBorder, b.hoverCloseBorder, t)!,
      inputHint: Color.lerp(a.inputHint, b.inputHint, t)!,
      cardHoverBg: Color.lerp(a.cardHoverBg, b.cardHoverBg, t)!,
      navActiveBg: Color.lerp(a.navActiveBg, b.navActiveBg, t)!,
      navActiveBorder: Color.lerp(a.navActiveBorder, b.navActiveBorder, t)!,
      navInactiveBorder:
          Color.lerp(a.navInactiveBorder, b.navInactiveBorder, t)!,
      toggleBg: Color.lerp(a.toggleBg, b.toggleBg, t)!,
      toggleBorder: Color.lerp(a.toggleBorder, b.toggleBorder, t)!,
      toggleIcon: Color.lerp(a.toggleIcon, b.toggleIcon, t)!,
      placeholderCover: Color.lerp(a.placeholderCover, b.placeholderCover, t)!,
      titleBrown: Color.lerp(a.titleBrown, b.titleBrown, t)!,
      starGold: Color.lerp(a.starGold, b.starGold, t)!,
      infoBlue: Color.lerp(a.infoBlue, b.infoBlue, t)!,
      brandBlue: Color.lerp(a.brandBlue, b.brandBlue, t)!,
      infoBg: Color.lerp(a.infoBg, b.infoBg, t)!,
      // 非颜色字段在过渡中点切换：风格档一次交割，避免中途混合态
      warningAmber: useB ? b.warningAmber : a.warningAmber,
      // v4.0 新增令牌同为「非颜色字段」处理：过渡中点一次交割，
      // 避免中途出现"半混合"的中间色（这些是实心按钮底色，插值会脏）
      accentCyan: useB ? b.accentCyan : a.accentCyan,
      accentInk: useB ? b.accentInk : a.accentInk,
      accentViolet: useB ? b.accentViolet : a.accentViolet,
      dividerStrong: useB ? b.dividerStrong : a.dividerStrong,
      heartRed: useB ? b.heartRed : a.heartRed,
      feedbackGreen: useB ? b.feedbackGreen : a.feedbackGreen,
      visualStyle: useB ? b.visualStyle : a.visualStyle,
      brightness: useB ? b.brightness : a.brightness,
    );
  }

  // ============ JSON 序列化（v3.0 P0 新增） ============

  static const int schemaVersion = 1;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'source': source.name,
        'name': name,
        'emoji': emoji,
        'description': description,
        'isFeatured': isFeatured,
        'brightness': brightness.name,
        // v3.9: 风格档仅在非默认值时写出（旧版应用读取新 JSON 时安全忽略未知键）
        if (visualStyle != CTVisualStyle.classicHanddrawn)
          'style': visualStyle.name,
        // 顶层 seedColor 保留：与旧版本应用的 .cttheme 交换兼容
        'seedColor': _colorToJson(seedColor),
        'colors': {
          // v3.9 修复：seedColor 同时写入 colors 内——
          // 历史 bug：toJson 写顶层而 fromJson 只读 colors['seedColor']，
          // 导致用户主题保存/加载后种子色丢失（回退暖棕默认）。
          'seedColor': _colorToJson(seedColor),
          'background': _colorToJson(background),
          'sidebarBackground': _colorToJson(sidebarBackground),
          'titleBarBackground': _colorToJson(titleBarBackground),
          'primaryText': _colorToJson(primaryText),
          'secondaryText': _colorToJson(secondaryText),
          'border': _colorToJson(border),
          'borderLight': _colorToJson(borderLight),
          'buttonBackground': _colorToJson(buttonBackground),
          'selectedAccent': _colorToJson(selectedAccent),
          'dangerRed': _colorToJson(dangerRed),
          'placeholderText': _colorToJson(placeholderText),
          'placeholderBg': _colorToJson(placeholderBg),
          'addCoverBg': _colorToJson(addCoverBg),
          'shadowColor': _colorToJson(shadowColor),
          'successGreen': _colorToJson(successGreen),
          'successBg': _colorToJson(successBg),
          'errorBg': _colorToJson(errorBg),
          'hoverCloseBg': _colorToJson(hoverCloseBg),
          'hoverCloseBorder': _colorToJson(hoverCloseBorder),
          'inputHint': _colorToJson(inputHint),
          'cardHoverBg': _colorToJson(cardHoverBg),
          'navActiveBg': _colorToJson(navActiveBg),
          'navActiveBorder': _colorToJson(navActiveBorder),
          'navInactiveBorder': _colorToJson(navInactiveBorder),
          'toggleBg': _colorToJson(toggleBg),
          'toggleBorder': _colorToJson(toggleBorder),
          'toggleIcon': _colorToJson(toggleIcon),
          'placeholderCover': _colorToJson(placeholderCover),
          'titleBrown': _colorToJson(titleBrown),
          'starGold': _colorToJson(starGold),
          'infoBlue': _colorToJson(infoBlue),
          'brandBlue': _colorToJson(brandBlue),
          'infoBg': _colorToJson(infoBg),
          if (warningAmber != null) 'warningAmber': _colorToJson(warningAmber!),
          // v4.0：仅在有值时写出，旧版应用读取安全忽略未知键
          if (accentCyan != null) 'accentCyan': _colorToJson(accentCyan!),
          if (accentInk != null) 'accentInk': _colorToJson(accentInk!),
          if (accentViolet != null) 'accentViolet': _colorToJson(accentViolet!),
          if (dividerStrong != null)
            'dividerStrong': _colorToJson(dividerStrong!),
          if (heartRed != null) 'heartRed': _colorToJson(heartRed!),
          if (feedbackGreen != null)
            'feedbackGreen': _colorToJson(feedbackGreen!),
        },
        if (backgroundImage.hasImage)
          'backgroundImage': backgroundImage.toJson(),
      };

  factory CTThemeData.fromJson(Map<String, dynamic> json) {
    final colors = (json['colors'] as Map<String, dynamic>?) ?? {};
    final bgJson = json['backgroundImage'] as Map<String, dynamic>?;
    return CTThemeData(
      id: json['id'] as String,
      source: CTThemeSource.values.firstWhere(
        (e) => e.name == (json['source'] as String? ?? 'user'),
        orElse: () => CTThemeSource.user,
      ),
      name: json['name'] as String,
      emoji: json['emoji'] as String,
      description: json['description'] as String?,
      isFeatured: (json['isFeatured'] as bool?) ?? false,
      backgroundImage: bgJson != null
          ? BackgroundImageConfig.fromJson(bgJson)
          : const BackgroundImageConfig.none(),
      brightness: (json['brightness'] as String?) == 'dark'
          ? Brightness.dark
          : Brightness.light,
      // v3.9：风格档——缺省（旧 JSON）= classicHanddrawn
      visualStyle:
          (json['style'] as String?) == CTVisualStyle.aurora.name
              ? CTVisualStyle.aurora
              : CTVisualStyle.classicHanddrawn,
      // v3.9 修复：优先读 colors 内（现行 toJson 位置），回退顶层（历史 JSON），
      // 兜底默认暖棕——历史"种子色往返丢失"缺陷在此闭环
      seedColor: _colorFromJson(colors['seedColor']) ??
          _colorFromJson(json['seedColor']) ??
          const Color(0xFF8B7355),
      warningAmber: _colorFromJson(colors['warningAmber']),
      // v4.0：缺省 = null，由 AppColors 回退到既有语义令牌（旧主题零影响）
      accentCyan: _colorFromJson(colors['accentCyan']),
      accentInk: _colorFromJson(colors['accentInk']),
      accentViolet: _colorFromJson(colors['accentViolet']),
      dividerStrong: _colorFromJson(colors['dividerStrong']),
      heartRed: _colorFromJson(colors['heartRed']),
      feedbackGreen: _colorFromJson(colors['feedbackGreen']),
      background:
          _colorFromJson(colors['background']) ?? const Color(0xFFFDFBF7),
      sidebarBackground: _colorFromJson(colors['sidebarBackground']) ??
          const Color(0xFFFBF6EF),
      titleBarBackground: _colorFromJson(colors['titleBarBackground']) ??
          const Color(0xFFFBF6EF),
      primaryText:
          _colorFromJson(colors['primaryText']) ?? const Color(0xFF5C4A3D),
      secondaryText:
          _colorFromJson(colors['secondaryText']) ?? const Color(0xFF7D6348),
      border: _colorFromJson(colors['border']) ?? const Color(0xFF8B7355),
      borderLight:
          _colorFromJson(colors['borderLight']) ?? const Color(0x338B7355),
      buttonBackground:
          _colorFromJson(colors['buttonBackground']) ?? const Color(0xFFF0E6D2),
      selectedAccent:
          _colorFromJson(colors['selectedAccent']) ?? const Color(0xFFB4D4FF),
      dangerRed: _colorFromJson(colors['dangerRed']) ?? const Color(0xFFD4183D),
      placeholderText:
          _colorFromJson(colors['placeholderText']) ?? const Color(0xFF9A8A76),
      placeholderBg:
          _colorFromJson(colors['placeholderBg']) ?? const Color(0xFFF5F1E8),
      addCoverBg:
          _colorFromJson(colors['addCoverBg']) ?? const Color(0xFFE9E0D1),
      shadowColor:
          _colorFromJson(colors['shadowColor']) ?? const Color(0x408B7355),
      successGreen:
          _colorFromJson(colors['successGreen']) ?? const Color(0xFF4CAF50),
      successBg: _colorFromJson(colors['successBg']) ?? const Color(0xFFE8F5E9),
      errorBg: _colorFromJson(colors['errorBg']) ?? const Color(0xFFFFE6EA),
      hoverCloseBg:
          _colorFromJson(colors['hoverCloseBg']) ?? const Color(0xFFFFEBEE),
      hoverCloseBorder:
          _colorFromJson(colors['hoverCloseBorder']) ?? const Color(0xFFEF5350),
      inputHint: _colorFromJson(colors['inputHint']) ?? const Color(0x997D6348),
      cardHoverBg:
          _colorFromJson(colors['cardHoverBg']) ?? const Color(0xFFF5EDE6),
      navActiveBg:
          _colorFromJson(colors['navActiveBg']) ?? const Color(0xFFFFFFFF),
      navActiveBorder:
          _colorFromJson(colors['navActiveBorder']) ?? const Color(0xFFA07840),
      navInactiveBorder: _colorFromJson(colors['navInactiveBorder']) ??
          const Color(0xFFC8B49A),
      toggleBg: _colorFromJson(colors['toggleBg']) ?? const Color(0xFFE8E0D0),
      toggleBorder:
          _colorFromJson(colors['toggleBorder']) ?? const Color(0xFFC8B49A),
      toggleIcon:
          _colorFromJson(colors['toggleIcon']) ?? const Color(0xFF5C3A1A),
      placeholderCover:
          _colorFromJson(colors['placeholderCover']) ?? const Color(0xFFE9E0D1),
      titleBrown:
          _colorFromJson(colors['titleBrown']) ?? const Color(0xFF5C4A3D),
      starGold: _colorFromJson(colors['starGold']) ?? const Color(0xFFD4A017),
      infoBlue: _colorFromJson(colors['infoBlue']) ?? const Color(0xFF4A72A5),
      brandBlue: _colorFromJson(colors['brandBlue']) ?? const Color(0xFF6B9EAD),
      infoBg: _colorFromJson(colors['infoBg']) ?? const Color(0xFFE6F0FF),
    );
  }

  /// 将 CTThemeData 的某个颜色字段替换为新值，返回新实例（immutable 模式）
  /// [tokenField] 为字段名（如 'background' / 'sidebarBackground'）
  CTThemeData withColor(String tokenField, Color newColor) {
    switch (tokenField) {
      case 'seedColor':
        return _copyWith(seedColor: newColor);
      case 'background':
        return _copyWith(background: newColor);
      case 'sidebarBackground':
        return _copyWith(sidebarBackground: newColor);
      case 'titleBarBackground':
        return _copyWith(titleBarBackground: newColor);
      case 'primaryText':
        return _copyWith(primaryText: newColor);
      case 'secondaryText':
        return _copyWith(secondaryText: newColor);
      case 'border':
        return _copyWith(border: newColor);
      case 'borderLight':
        return _copyWith(borderLight: newColor);
      case 'buttonBackground':
        return _copyWith(buttonBackground: newColor);
      case 'selectedAccent':
        return _copyWith(selectedAccent: newColor);
      case 'dangerRed':
        return _copyWith(dangerRed: newColor);
      case 'placeholderText':
        return _copyWith(placeholderText: newColor);
      case 'placeholderBg':
        return _copyWith(placeholderBg: newColor);
      case 'addCoverBg':
        return _copyWith(addCoverBg: newColor);
      case 'shadowColor':
        return _copyWith(shadowColor: newColor);
      case 'successGreen':
        return _copyWith(successGreen: newColor);
      case 'successBg':
        return _copyWith(successBg: newColor);
      case 'errorBg':
        return _copyWith(errorBg: newColor);
      case 'hoverCloseBg':
        return _copyWith(hoverCloseBg: newColor);
      case 'hoverCloseBorder':
        return _copyWith(hoverCloseBorder: newColor);
      case 'inputHint':
        return _copyWith(inputHint: newColor);
      case 'cardHoverBg':
        return _copyWith(cardHoverBg: newColor);
      case 'navActiveBg':
        return _copyWith(navActiveBg: newColor);
      case 'navActiveBorder':
        return _copyWith(navActiveBorder: newColor);
      case 'navInactiveBorder':
        return _copyWith(navInactiveBorder: newColor);
      case 'toggleBg':
        return _copyWith(toggleBg: newColor);
      case 'toggleBorder':
        return _copyWith(toggleBorder: newColor);
      case 'toggleIcon':
        return _copyWith(toggleIcon: newColor);
      case 'placeholderCover':
        return _copyWith(placeholderCover: newColor);
      case 'titleBrown':
        return _copyWith(titleBrown: newColor);
      case 'starGold':
        return _copyWith(starGold: newColor);
      case 'infoBlue':
        return _copyWith(infoBlue: newColor);
      case 'brandBlue':
        return _copyWith(brandBlue: newColor);
      case 'infoBg':
        return _copyWith(infoBg: newColor);
      // v4.0 探索详情页新增令牌（供主题编辑器 / 元素注册表按名改色）
      case 'accentCyan':
        return _copyWith(accentCyan: newColor);
      case 'accentInk':
        return _copyWith(accentInk: newColor);
      case 'accentViolet':
        return _copyWith(accentViolet: newColor);
      case 'dividerStrong':
        return _copyWith(dividerStrong: newColor);
      case 'heartRed':
        return _copyWith(heartRed: newColor);
      case 'feedbackGreen':
        return _copyWith(feedbackGreen: newColor);
      default:
        return this;
    }
  }

  /// 浅拷贝（用于编辑器预览修改）
  CTThemeData _copyWith({
    Color? seedColor,
    Color? background,
    Color? sidebarBackground,
    Color? titleBarBackground,
    Color? primaryText,
    Color? secondaryText,
    Color? border,
    Color? borderLight,
    Color? buttonBackground,
    Color? selectedAccent,
    Color? dangerRed,
    Color? placeholderText,
    Color? placeholderBg,
    Color? addCoverBg,
    Color? shadowColor,
    Color? successGreen,
    Color? successBg,
    Color? errorBg,
    Color? hoverCloseBg,
    Color? hoverCloseBorder,
    Color? inputHint,
    Color? cardHoverBg,
    Color? navActiveBg,
    Color? navActiveBorder,
    Color? navInactiveBorder,
    Color? toggleBg,
    Color? toggleBorder,
    Color? toggleIcon,
    Color? placeholderCover,
    Color? titleBrown,
    Color? starGold,
    Color? infoBlue,
    Color? brandBlue,
    Color? infoBg,
    Color? warningAmber,
    Color? accentCyan,
    Color? accentInk,
    Color? accentViolet,
    Color? dividerStrong,
    Color? heartRed,
    Color? feedbackGreen,
    CTVisualStyle? visualStyle,
    BackgroundImageConfig? backgroundImage,
    String? name,
    String? emoji,
    String? description,
  }) {
    return CTThemeData(
      id: id,
      source: source,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      description: description ?? this.description,
      isFeatured: isFeatured,
      backgroundImage: backgroundImage ?? this.backgroundImage,
      brightness: brightness,
      seedColor: seedColor ?? this.seedColor,
      background: background ?? this.background,
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      titleBarBackground: titleBarBackground ?? this.titleBarBackground,
      primaryText: primaryText ?? this.primaryText,
      secondaryText: secondaryText ?? this.secondaryText,
      border: border ?? this.border,
      borderLight: borderLight ?? this.borderLight,
      buttonBackground: buttonBackground ?? this.buttonBackground,
      selectedAccent: selectedAccent ?? this.selectedAccent,
      dangerRed: dangerRed ?? this.dangerRed,
      placeholderText: placeholderText ?? this.placeholderText,
      placeholderBg: placeholderBg ?? this.placeholderBg,
      addCoverBg: addCoverBg ?? this.addCoverBg,
      shadowColor: shadowColor ?? this.shadowColor,
      successGreen: successGreen ?? this.successGreen,
      successBg: successBg ?? this.successBg,
      errorBg: errorBg ?? this.errorBg,
      hoverCloseBg: hoverCloseBg ?? this.hoverCloseBg,
      hoverCloseBorder: hoverCloseBorder ?? this.hoverCloseBorder,
      inputHint: inputHint ?? this.inputHint,
      cardHoverBg: cardHoverBg ?? this.cardHoverBg,
      navActiveBg: navActiveBg ?? this.navActiveBg,
      navActiveBorder: navActiveBorder ?? this.navActiveBorder,
      navInactiveBorder: navInactiveBorder ?? this.navInactiveBorder,
      toggleBg: toggleBg ?? this.toggleBg,
      toggleBorder: toggleBorder ?? this.toggleBorder,
      toggleIcon: toggleIcon ?? this.toggleIcon,
      placeholderCover: placeholderCover ?? this.placeholderCover,
      titleBrown: titleBrown ?? this.titleBrown,
      starGold: starGold ?? this.starGold,
      infoBlue: infoBlue ?? this.infoBlue,
      brandBlue: brandBlue ?? this.brandBlue,
      infoBg: infoBg ?? this.infoBg,
      warningAmber: warningAmber ?? this.warningAmber,
      accentCyan: accentCyan ?? this.accentCyan,
      accentInk: accentInk ?? this.accentInk,
      accentViolet: accentViolet ?? this.accentViolet,
      dividerStrong: dividerStrong ?? this.dividerStrong,
      heartRed: heartRed ?? this.heartRed,
      feedbackGreen: feedbackGreen ?? this.feedbackGreen,
      visualStyle: visualStyle ?? this.visualStyle,
    );
  }

  /// 用于编辑器：复制此主题为新的用户主题（新 id、source=user）
  CTThemeData asUserThemeCopy({
    required String newId,
    String? name,
    String? emoji,
    String? description,
  }) {
    return CTThemeData(
      id: newId,
      source: CTThemeSource.user,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      description: description ?? this.description,
      isFeatured: false,
      backgroundImage: backgroundImage,
      brightness: brightness,
      seedColor: seedColor,
      background: background,
      sidebarBackground: sidebarBackground,
      titleBarBackground: titleBarBackground,
      primaryText: primaryText,
      secondaryText: secondaryText,
      border: border,
      borderLight: borderLight,
      buttonBackground: buttonBackground,
      selectedAccent: selectedAccent,
      dangerRed: dangerRed,
      placeholderText: placeholderText,
      placeholderBg: placeholderBg,
      addCoverBg: addCoverBg,
      shadowColor: shadowColor,
      successGreen: successGreen,
      successBg: successBg,
      errorBg: errorBg,
      hoverCloseBg: hoverCloseBg,
      hoverCloseBorder: hoverCloseBorder,
      inputHint: inputHint,
      cardHoverBg: cardHoverBg,
      navActiveBg: navActiveBg,
      navActiveBorder: navActiveBorder,
      navInactiveBorder: navInactiveBorder,
      toggleBg: toggleBg,
      toggleBorder: toggleBorder,
      toggleIcon: toggleIcon,
      placeholderCover: placeholderCover,
      titleBrown: titleBrown,
      starGold: starGold,
      infoBlue: infoBlue,
      brandBlue: brandBlue,
      infoBg: infoBg,
      warningAmber: warningAmber,
      accentCyan: accentCyan,
      accentInk: accentInk,
      accentViolet: accentViolet,
      dividerStrong: dividerStrong,
      heartRed: heartRed,
      feedbackGreen: feedbackGreen,
      visualStyle: visualStyle,
    );
  }

  /// v3.0 P1：替换背景图配置，返回新实例（用于"应用自定义背景"功能）
  CTThemeData withBackgroundImage(BackgroundImageConfig newConfig) {
    return _copyWith(backgroundImage: newConfig);
  }

  static String _colorToJson(Color c) {
    return '#${c.value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  static Color? _colorFromJson(dynamic v) {
    if (v == null) return null;
    if (v is String) {
      var s = v.trim();
      if (s.startsWith('#')) s = s.substring(1);
      if (s.length == 6) s = 'FF$s';
      if (s.length == 8) {
        final argb = int.tryParse(s, radix: 16);
        if (argb != null) return Color(argb);
      }
    } else if (v is int) {
      return Color(v);
    }
    return null;
  }
}

class AppThemeManager extends ChangeNotifier {
  static AppThemeManager? _instance;
  static AppThemeManager get instance => _instance ??= AppThemeManager._();

  AppThemeManager._();

  /// 当前激活主题 id（v3.0 P0：从 CTTheme 改为 String）
  /// 内置主题 id = CTTheme 枚举 name；用户主题 id = UUID
  String _currentThemeId = CTTheme.warmSun.name;
  String get currentThemeId => _currentThemeId;

  /// v3.9：「跟随系统主题」开关（默认 false——软件默认暖白，用户自行开启）。
  /// 开启时按设备深浅色自动加载 浅色(frost)/深色(obsidian)。
  bool _followSystemTheme = false;
  bool get followSystemTheme => _followSystemTheme;

  /// 当前平台亮度（封装一处，便于测试环境复用 TestBinding 默认值）
  Brightness get _currentPlatformBrightness =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  /// 设备亮度 → 系统主题 id（浅色→frost / 深色→obsidian）
  String _systemThemeIdFor(Brightness brightness) =>
      brightness == Brightness.dark ? CTTheme.obsidian.name : CTTheme.frost.name;

  /// v3.9：设置「跟随系统主题」。
  /// 开启时立即按当前平台亮度切换一次；关闭时不改变当前主题。
  Future<void> setFollowSystemTheme(bool value) async {
    if (_followSystemTheme == value) return;
    _followSystemTheme = value;
    await ThemeStorage.saveFollowSystemTheme(value);
    if (value) {
      await setThemeById(_systemThemeIdFor(_currentPlatformBrightness),
          fromSystem: true);
    }
  }

  /// v3.9：设备深浅色变化回调（main.dart 的 WidgetsBindingObserver 转发）。
  /// 仅在跟随系统开启时切换主题。
  Future<void> onSystemBrightnessChanged() async {
    if (!_followSystemTheme) return;
    await setThemeById(_systemThemeIdFor(_currentPlatformBrightness),
        fromSystem: true);
  }

  /// v3.0 P0：所有主题（内置 + 用户）的统一注册表
  /// 由 ThemeRegistry 维护，AppThemeManager 通过 register/unregister 接口接收
  final Map<String, CTThemeData> _themes = {};

  /// 注册主题（由 ThemeRegistry 启动时调用）
  void registerTheme(CTThemeData data) {
    _themes[data.id] = data;
  }

  /// v3.0.1 修复：公开的通知接口
  ///
  /// `notifyListeners` 是 ChangeNotifier 的 @protected 方法，
  /// 外部直接调用会产生 `invalid_use_of_protected_member` warning。
  /// 本方法作为公开入口供外部调用方（如设置页、主题编辑器）触发刷新，
  /// 同时保留未来在通知前插入日志/批量合并等扩展点。
  void notifyThemeChanged() => notifyListeners();

  /// 取消注册
  ///
  /// v3.0.1 修复：若被删除的是当前激活主题，原实现直接 notifyListeners
  /// 无过渡动画，视觉上会"跳"到 warmSun。本版本通过 setThemeById 走标准
  /// 250ms 过渡（setThemeById 内部会处理 _themes 已不含 id 的降级）。
  Future<void> unregisterTheme(String id) async {
    final wasActive = _currentThemeId == id;
    _themes.remove(id);
    if (wasActive) {
      // 切换到 warmSun 并触发过渡动画
      await setThemeById(CTTheme.warmSun.name);
    }
  }

  /// 获取所有已注册主题 id
  List<String> get allThemeIds => _themes.keys.toList();

  /// 通过 id 获取主题数据
  CTThemeData? themeDataById(String id) => _themes[id];

  // ============ 兼容旧 API ============

  /// 兼容旧 API：返回当前激活的 CTTheme 枚举
  /// 若当前是用户主题，则回退到 warmSun
  CTTheme get currentTheme {
    for (final t in CTTheme.values) {
      if (t.name == _currentThemeId) return t;
    }
    return CTTheme.warmSun;
  }

  /// 兼容旧 API：通过 CTTheme 枚举获取主题数据
  static CTThemeData themeData(CTTheme theme) =>
      instance._themes[theme.name] ?? instance._themes[CTTheme.warmSun.name]!;

  /// 兼容旧 API：所有内置 CTTheme 枚举
  static List<CTTheme> get allThemes => CTTheme.values;

  /// 兼容旧 API：特色主题（isFeatured=true）
  static List<CTTheme> get featuredThemes => CTTheme.values.where((t) {
        final data = instance._themes[t.name];
        return data != null && data.isFeatured;
      }).toList();

  /// 兼容旧 API：标准主题（isFeatured=false）
  static List<CTTheme> get standardThemes => CTTheme.values.where((t) {
        final data = instance._themes[t.name];
        return data != null && !data.isFeatured;
      }).toList();

  // ============ 过渡动画状态（保留原逻辑） ============

  static const Duration _transitionDuration = Duration(milliseconds: 250);
  bool _isTransitioning = false;
  Duration? _transitionStartTimestamp;
  CTThemeData? _transitionFrom;
  CTThemeData? _transitionTo;
  CTThemeData? _currentInterpolated;
  int? _frameCallbackId;

  /// 当前生效的主题数据。过渡动画期间返回插值结果，否则返回目标主题。
  CTThemeData get current {
    if (_isTransitioning && _currentInterpolated != null) {
      return _currentInterpolated!;
    }
    return _themes[_currentThemeId] ?? _themes[CTTheme.warmSun.name]!;
  }

  /// 过渡动画期间返回插值后的 CTThemeData，否则返回目标主题。
  static CTThemeData get colors => instance.current;

  // ============ 主题切换 API ============

  /// 兼容旧 API：通过 CTTheme 枚举设置主题
  Future<void> setTheme(CTTheme theme) async {
    await setThemeById(theme.name);
  }

  /// v3.0 P0 新增：通过 String id 设置主题
  ///
  /// v3.9：[fromSystem] 供跟随系统链路使用；用户手动选择非系统对应主题时
  /// 自动退出跟随模式（否则点击会因后续亮度变化被覆盖，行为不一致）。
  Future<void> setThemeById(String id, {bool fromSystem = false}) async {
    if (!fromSystem &&
        _followSystemTheme &&
        id != _systemThemeIdFor(_currentPlatformBrightness)) {
      // 手动选择与系统亮度不对应主题 → 自动退出跟随
      _followSystemTheme = false;
      await ThemeStorage.saveFollowSystemTheme(false);
    }
    if (_currentThemeId == id) return;
    if (!_themes.containsKey(id)) {
      debugPrint('[Theme] 主题 id 不存在: $id, 回退到 warmSun');
      id = CTTheme.warmSun.name;
    }

    _cancelFrameCallback();

    final fromData = _isTransitioning && _currentInterpolated != null
        ? _currentInterpolated!
        : (_themes[_currentThemeId] ?? _themes[CTTheme.warmSun.name]!);

    _currentThemeId = id;
    _transitionFrom = fromData;
    _transitionTo = _themes[id]!;
    _isTransitioning = true;
    _transitionStartTimestamp = null;

    _frameCallbackId =
        SchedulerBinding.instance.scheduleFrameCallback(_onTransitionFrame);

    notifyListeners();

    await ThemeStorage.saveActiveThemeId(id);
  }

  /// v3.0 P0 新增：应用自定义主题（编辑器"应用"按钮调用）
  ///
  /// 接收一个完整的 CTThemeData（通常是编辑器预览状态的快照），
  /// 注册到 _themes（若 id 不存在）并切换为激活主题。
  ///
  /// v3.0.1 修复（严重 BUG）：原实现直接调用 setThemeById(data.id)，
  /// 但 setThemeById 在 `_currentThemeId == id` 时会提前 return 不触发
  /// notifyListeners，导致编辑当前激活主题点"应用"后 UI 不刷新。
  /// 本版本显式区分两种场景：
  /// - 同 id（编辑当前主题）：直接 notifyListeners，触发全应用重建
  /// - 不同 id（切换主题）：走 setThemeById 触发 250ms 过渡动画
  Future<void> applyCustomTheme(CTThemeData data) async {
    final isCurrentlyActive = _currentThemeId == data.id;
    _themes[data.id] = data;

    if (isCurrentlyActive) {
      // 编辑当前激活主题：数据已更新，直接通知监听者重建 UI
      // （无过渡动画，因为是同一主题的颜色调整，过渡反而会让用户困惑）
      notifyListeners();
    } else {
      // 切换到不同主题：走标准过渡动画路径
      await setThemeById(data.id);
    }
  }

  /// v3.0 P0 新增：直接更新当前主题的某个颜色字段（编辑器实时预览用，无过渡动画）
  ///
  /// 注意：此方法仅用于编辑器内部"应用"前的局部修改，
  /// 不触发持久化。持久化由 applyCustomTheme 完成。
  void updateCurrentColor(String tokenField, Color newColor) {
    final current = _themes[_currentThemeId];
    if (current == null) return;
    _themes[_currentThemeId] = current.withColor(tokenField, newColor);
    notifyListeners();
  }

  void _onTransitionFrame(Duration timestamp) {
    if (!_isTransitioning) return;

    _transitionStartTimestamp ??= timestamp;
    final elapsed = timestamp - _transitionStartTimestamp!;
    final t = (elapsed.inMicroseconds / _transitionDuration.inMicroseconds)
        .clamp(0.0, 1.0);

    final easedT = Curves.easeOutCubic.transform(t);
    _currentInterpolated =
        CTThemeData.lerp(_transitionFrom!, _transitionTo!, easedT);
    notifyListeners();

    if (t < 1.0) {
      _frameCallbackId =
          SchedulerBinding.instance.scheduleFrameCallback(_onTransitionFrame);
    } else {
      _stopTransition();
    }
  }

  void _cancelFrameCallback() {
    if (_frameCallbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_frameCallbackId!);
      _frameCallbackId = null;
    }
  }

  void _stopTransition() {
    _cancelFrameCallback();
    _isTransitioning = false;
    _currentInterpolated = null;
    _transitionFrom = null;
    _transitionTo = null;
    _transitionStartTimestamp = null;
    notifyListeners();
  }

  /// 加载持久化的激活主题 id
  ///
  /// v3.0 P0 启动流程（按顺序执行）：
  /// 1. 注册 6 个内置主题（id = CTTheme 枚举 name）
  /// 2. 加载所有用户主题 JSON 文件（在 isolate 中执行）
  /// 3. 读取 SharedPreferences 中的激活主题 id
  /// 4. 兼容老版本：若值为 CTTheme 枚举 name，直接作为内置主题 id
  /// 5. 降级：若激活主题 id 不存在（用户主题被外部删除等），回退到 warmSun
  Future<void> loadSavedTheme() async {
    // 1. 注册内置主题（幂等）
    ThemeRegistry.registerBuiltinThemes();

    // 2. 加载用户主题（不阻塞主线程）
    try {
      final userThemes = await ThemeStorage.loadAllUserThemes();
      for (final data in userThemes) {
        _themes[data.id] = data;
      }
    } catch (e) {
      debugPrint('[Theme] 加载用户主题失败(忽略): $e');
    }

    // 2.5 v3.9：系统默认自动创建一个「我的主题」（仅首次——无任何用户主题
    // 且未创建过）。让「自定义设计 → 我的主题」面板开箱非空，快捷功能
    // （编辑/重命名/导出）可直接演示与使用。不激活，仅注册入库。
    final hasUserTheme =
        _themes.values.any((t) => t.source == CTThemeSource.user);
    try {
      final defaultCreated =
          await ThemeStorage.loadDefaultUserThemeCreated();
      if (!hasUserTheme && !defaultCreated) {
        final base = _themes[CTTheme.warmSun.name];
        if (base != null) {
          final userTheme = base.asUserThemeCopy(
            newId: ThemeStorage.newThemeId(),
            name: '我的主题',
            emoji: '🎨',
            description: '系统默认创建',
          );
          await ThemeStorage.saveUserTheme(userTheme);
          _themes[userTheme.id] = userTheme;
        }
        await ThemeStorage.saveDefaultUserThemeCreated(true);
      }
    } catch (e) {
      debugPrint('[Theme] 默认「我的主题」创建失败(忽略): $e');
    }

    // 3. 读取激活 id
    // 3. v3.9：读取跟随系统标记——开启时忽略持久化 id，
    //    直接按平台亮度加载浅色/深色系统主题
    _followSystemTheme = await ThemeStorage.loadFollowSystemTheme();
    if (_followSystemTheme) {
      final id = _systemThemeIdFor(_currentPlatformBrightness);
      _currentThemeId =
          _themes.containsKey(id) ? id : CTTheme.warmSun.name;
      notifyListeners();
      return;
    }

    final saved = await ThemeStorage.loadActiveThemeId();
    if (saved != null && _themes.containsKey(saved)) {
      _currentThemeId = saved;
      notifyListeners();
      return;
    }

    if (saved != null) {
      // 4. 兼容：尝试匹配 CTTheme 枚举 name
      for (final t in CTTheme.values) {
        if (t.name == saved && _themes.containsKey(t.name)) {
          _currentThemeId = t.name;
          notifyListeners();
          return;
        }
      }
      // 5. 降级
      debugPrint('[Theme] 激活主题 id "$saved" 不存在, 回退到 warmSun');
    }

    _currentThemeId = CTTheme.warmSun.name;
    notifyListeners();
  }
}
