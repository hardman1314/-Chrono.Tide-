import 'dart:ui' show Brightness;

import 'package:flutter/widgets.dart';

import 'bpm_theme_controller.dart';

/// 大屏模式 (BPM) 视觉常量集合
///
/// 集中定义 BPM 内所有尺寸、缩放、字号、动画时长等常量,
/// 避免硬编码散落各处。所有数值基于"10 英尺 UI"理念设计,
/// 适配串流场景下大屏远距离观看。
///
/// 颜色仍走 [AppColors] 静态门面,BPM 不引入独立主题色板。
class BigPictureTheme {
  BigPictureTheme._();

  // ============ 整体缩放 ============
  /// 相对桌面布局的整体缩放因子
  static const double scale = 1.6;

  // ============ 导航栏 ============
  /// 左侧导航栏宽度
  static const double navBarWidth = 96.0;

  /// 导航项按钮尺寸 (正方形)
  static const double navItemSize = 64.0;

  /// 导航图标尺寸
  static const double navIconSize = 32.0;

  /// 导航项间距
  static const double navItemSpacing = 12.0;

  /// 当前页左侧高亮条宽度
  static const double navActiveIndicatorWidth = 4.0;

  // ============ 游戏卡片 ============
  /// 卡片宽度 (16:9 比例)
  static const double cardWidth = 320.0;

  /// 卡片高度
  static const double cardHeight = 180.0;

  /// 卡片间距
  static const double cardSpacing = 24.0;

  /// 焦点态缩放
  static const double cardFocusScale = 1.05;

  /// 悬停态缩放
  static const double cardHoverScale = 1.02;

  /// 焦点辉光边框宽度
  static const double cardFocusGlowWidth = 4.0;

  /// 卡片圆角
  static const double cardRadius = 12.0;

  // ============ 字号 ============
  /// 大标题字号 (首页主标题)
  static const double displayFontSize = 36.0;

  /// 标题字号 (区块标题/详情页游戏名)
  static const double titleFontSize = 28.0;

  /// 副标题字号 (开发者/分类)
  static const double subtitleFontSize = 22.0;

  /// 正文字号 (描述/元数据)
  static const double bodyFontSize = 18.0;

  /// 标签字号 (徽章/状态)
  static const double labelFontSize = 14.0;

  // ============ 间距 ============
  /// 页面外边距
  static const double pagePadding = 48.0;

  /// 区块间距
  static const double sectionSpacing = 32.0;

  /// 组件内间距
  static const double widgetPadding = 16.0;

  // ============ 启动按钮 ============
  /// 主启动按钮宽度
  static const double launchButtonWidth = 280.0;

  /// 主启动按钮高度
  static const double launchButtonHeight = 72.0;

  /// 次要按钮高度
  static const double secondaryButtonHeight = 56.0;

  // ============ 详情页 ============
  /// 详情页大封面宽度 (16:9)
  static const double detailCoverWidth = 480.0;

  /// 详情页大封面高度
  static const double detailCoverHeight = 270.0;

  // ============ 动画 ============
  /// 焦点切换动画时长
  static const Duration focusAnimDuration = Duration(milliseconds: 200);

  /// BPM 进入/退出过渡时长 (与 AppThemeManager 一致)
  static const Duration modeTransitionDuration = Duration(milliseconds: 250);

  /// 页面切换动画时长
  static const Duration pageTransitionDuration = Duration(milliseconds: 200);

  // ============ 通用圆角 ============
  /// 按钮圆角
  static const double buttonRadius = 12.0;

  /// 容器圆角 (详情面板/动作表)
  static const double containerRadius = 16.0;

  /// 焦点辉光 BorderRadius 默认值
  static BorderRadius get defaultFocusRadius =>
      BorderRadius.circular(cardRadius);

  // ============ Ubiquity 风格主页 (v1.3) ============
  /// 底部轮播竖版封面卡片宽度 (2:3 比例,接近 GAL 标准封面)
  static const double posterCardWidth = 140.0;

  /// 底部轮播竖版封面卡片高度
  static const double posterCardHeight = 200.0;

  /// 底部轮播卡片间距
  static const double posterCardSpacing = 16.0;

  /// 底部轮播容器高度 (含上下边距)
  static const double posterCarouselHeight = 240.0;

  /// 选中卡片缩放倍数
  static const double posterFocusScale = 1.08;

  /// 信息层最大宽度 (避免超宽屏文字过长)
  static const double heroInfoMaxWidth = 720.0;

  /// 半透明启动按钮背景透明度
  static const double glassButtonOpacity = 0.18;

  /// 渐变遮罩起始透明度 (顶部,最透明)
  static const double scrimTopOpacity = 0.0;

  /// 渐变遮罩结束透明度 (底部,最深)
  static const double scrimBottomOpacity = 0.85;

  // ============ Cinema 舞台布局 (v3 重构,借鉴 gal-launcher Cinema 主题) ============

  /// 顶部头部栏高度 (v3.5:BPM 专属头部栏,替代系统标题栏)
  static const double topBarHeight = 64.0;

  /// 侧边栏中心向外光晕外扩宽度 (v3.5 模糊侧边栏)
  // —— v3.6-re 侧边栏环境阴影/羽化参数 ——
  /// ⚠️ 必须足够大: 阴影团所有径向渐变要在**到达画布右缘之前**衰减到 0,
  /// 否则 CustomPaint 的矩形边界会切出硬边 (v3.6 实测教训)。
  static const double railShadowSpreadRight = 240.0;

  /// 阴影画布向上余量 (与头部栏之间不留硬边界)
  static const double railShadowSpreadTop = 30.0;

  /// 羽化带: 由外到内的外扩量 (与 [railFeatherSigmas] 一一对应)。
  /// 单段 BackdropFilter 的裁剪边必然是「模糊↔清晰」的 1px 硬过渡;
  /// 两段递减 (外圈 σ3.5 → 本体 σ7) 段差小, 外缘过渡肉眼难辨,
  /// 且无三段式的高频莫尔风险。
  static const List<double> railFeatherExtents = <double>[32.0, 0.0];

  /// 羽化带模糊强度 (由外到内, 与 [railFeatherExtents] 对齐)。
  /// 🔴 σ 刻意调轻 (v3.5 曾用 24): 用户要求「能看到后方背景原画」,
  /// σ7 只磨掉细碎纹理、保留画面轮廓。
  static const List<double> railFeatherSigmas = <double>[3.5, 7.0];

  /// 左侧 rail 导航栏宽度 (v3.5: 88 → 104; v3.8: 104 → 128,触屏可点性)
  static const double railWidth = 128.0;

  /// rail 应用 Logo 尺寸
  ///
  /// 原为「CT」字样字号 (v3.5: 26 → 34; v3.8: → 38)；10-04 换成软件图标后
  /// 语义变为**图标边长**。38 时与导航图标 (railIconSize=34, 选中放大
  /// 1.12≈38) 视觉等大,看不出是 Logo → 64 (1.9 倍) → **72** 定稿:
  /// 与按钮框 railItemSize 同高,是导航图标的 2.1 倍,清晰可辨且仍在
  /// rail 宽 128 内居中。
  static const double railLogoSize = 72.0;

  /// rail logo 距顶距离
  static const double railLogoTop = 20.0;

  /// rail 导航按钮尺寸 (v3.5: 56; v3.8: → 72,触屏/手柄可点性)
  static const double railItemSize = 72.0;

  /// rail 图标尺寸 (v3.8: 26 → 34)
  static const double railIconSize = 34.0;

  /// rail 文字标签字号
  static const double railLabelSize = 10.0;

  /// rail 按钮间距 (v3.8: 10 → 22,拉开呼吸感)
  static const double railItemSpacing = 38.0;

  /// 底部 shelf 单张竖版封面宽度 (v3.5: 196 → 224 放大)
  static const double shelfCardWidth = 224.0;

  /// 底部 shelf 单张竖版封面高度 (约 5:7, v3.5: 276 → 316 放大)
  static const double shelfCardHeight = 316.0;

  /// 底部 shelf 区域总高度 (含标题行/统计行/上下内边距, v3.5: 368 → 420)
  static const double shelfAreaHeight = 420.0;

  /// shelf 选中卡片上浮距离
  static const double shelfFocusLift = 10.0;

  /// shelf 选中卡片缩放
  static const double shelfFocusScale = 1.06;

  /// shelf 卡片间距
  static const double shelfCardSpacing = 16.0;

  /// shelf 内容（标题行 + 卡片）静止时距舞台左右边缘的净内缩。
  ///
  /// v3.23：原先写死在货架 `Container` 的 `EdgeInsets.fromLTRB(32, ...)` 里，
  /// 现提为常量，与 [shelfViewportBleed] 配套使用。
  static const double shelfPageInset = 32.0;

  /// shelf 滚动视口的裁剪边界相对舞台左右边缘的**外扩量**。
  ///
  /// 🔴 为什么需要它：横向 `ListView` 按视口硬裁剪（`Clip.hardEdge`），而卡片
  /// 静止时的左右边缘原本正好等于视口边缘 —— 选中时 `AnimatedScale` 放大
  /// [shelfFocusScale] 属于「只画不改布局」，左右各多画
  /// `shelfCardWidth * (shelfFocusScale - 1) / 2 = 6.72px`，这段连同该侧的
  /// 2px 描边与圆角一起被硬切掉（真机现象：最左/最右卡片封面显示不完整）。
  ///
  /// 修法：视口裁剪边界外扩本值，内容靠 ListView 自己的水平 padding 继续
  /// 保持 [shelfPageInset] 的静止内缩 —— 静止几何一行不变，只多出余量。
  ///
  /// ⚠️ 必须 > `shelfCardWidth * (shelfFocusScale - 1) / 2`（= 6.72），
  /// 且 ≤ [shelfPageInset]（否则会把卡片静止位置往里推、标题行与卡片错位）。
  static const double shelfViewportBleed = 12.0;

  /// 舞台侧留白与内容留白的差值：货架内容层（标题行 / ListView）自己该加的
  /// 水平 padding = [shelfPageInset] − [shelfViewportBleed]。
  static const double shelfContentHorizontalPadding =
      shelfPageInset - shelfViewportBleed;

  /// 右侧滑出详情面板宽度 (v3.8: 440 → 520,向左加大面积)
  static const double detailPanelWidth = 520.0;

  /// hero 舞台 meta 行字号 (雾蓝小字,字距拉宽)
  static const double heroMetaSize = 15.0;

  /// hero 舞台主标题字号 (得意黑)
  static const double heroTitleSize = 64.0;

  /// hero 舞台副标题字号
  static const double heroSubtitleSize = 18.0;

  /// hero 舞台启动胶囊按钮高度 (v3.8: 60 → 76,触屏可点性)
  static const double heroButtonHeight = 76.0;

  /// hero 信息区最大宽度
  static const double heroInfoMaxWidthCinema = 880.0;

  /// 页面顶部工具行高度 (搜索 pill 行)
  static const double stageTopHeight = 76.0;

  // ============ v3.10 分层板块焦点系统 (2026-09-20) ============

  /// 板块高亮框相对板块内容的外扩像素
  ///
  /// 用负 `Positioned` 偏移实现（`Padding` 不允许负值），因此**不影响布局**。
  static const double zoneFocusExpand = 6.0;

  /// 板块高亮框圆角
  static const double zoneFocusRadius = 18.0;

  /// 板块高亮框线宽 (组件焦点环是 4px, 板块 2px + 外辉光, 视觉语言区分)
  static const double zoneFocusBorderWidth = 2.0;

  /// 板块高亮渐入渐出时长
  static const Duration zoneFocusAnimDuration = Duration(milliseconds: 180);
}

/// BPM 主题色门面 (v3.5：由静态常量改为调色板转发)
///
/// 深色/浅色两套调色板定义在 `bpm_theme_controller.dart` 的 [BpmPalette]，
/// 本类保留原令牌名以兼容 v3 起约 300 处引用（调用点零改动）。
///
/// ⚠️ 令牌已是 getter，**不可再用于 `const` 表达式**。
/// ⚠️ 取色会读取 [BpmThemeController.instance]，因此 BPM 内需要随主题切换
/// 刷新的组件必须监听该控制器（`big_picture_shell.dart` 已统一监听）。
class BpmColors {
  BpmColors._();

  static BpmPalette get _p => BpmThemeController.instance.palette;

  /// 页面深底 (Cinema #0c0f16)
  static Color get deepBase => _p.deepBase;

  /// 玻璃面板基色 (rgba(16,22,32,x) 的实色部分,配合 opacity 使用)
  static Color get deepPanel => _p.deepPanel;

  /// 玻璃面板 (rgba(16,22,32,.42) → 毛玻璃卡片/胶囊底)
  static Color get panelGlass => _p.panelGlass;

  /// 强遮罩 (底部渐变收尾)
  static Color get scrimStrong => _p.scrimStrong;

  /// 中遮罩 (左侧渐变起点)
  static Color get scrimMid => _p.scrimMid;

  /// 主文字 (Cinema #fff7f8)
  static Color get textPrimary => _p.textPrimary;

  /// 次级文字 (主文字 75%)
  static Color get textSecondary => _p.textSecondary;

  /// 弱文字 (主文字 50%)
  static Color get textMuted => _p.textMuted;

  /// 雾蓝 (Cinema #9ed0ea) —— meta 行/次强调
  static Color get mistBlue => _p.mistBlue;

  /// 雾蓝柔色 (Cinema #b8d4e3) —— 焦点边框/渐变
  static Color get mistBlueSoft => _p.mistBlueSoft;

  /// 樱粉 (Cinema #e89aa8) —— 主强调/焦点辉光/shelf 圆点
  static Color get cherryRose => _p.cherryRose;

  /// 樱粉弱化边框 (透明度 .22)
  static Color get cherryRoseBorder => _p.cherryRoseBorder;

  /// 雾蓝弱化边框 (透明度 .22)
  static Color get mistBlueBorder => _p.mistBlueBorder;

  /// 主启动按钮渐变 (Cinema .play: #fff2f6 → #e89aa8 → #b8d4e3)
  static LinearGradient get playButtonGradient => _p.playButtonGradient;

  /// 主启动按钮文字色 (Cinema #21141a)
  static Color get playButtonForeground => _p.playButtonForeground;

  // ===== v3.3 Mica 详情浮窗令牌 =====
  /// Mica 浮窗底色 (半透明深蓝,叠加在 backdrop blur 之上)
  static Color get micaSurface => _p.micaSurface;

  /// Mica 顶部光泽渐变起点 (模拟云母的顶部高光)
  static Color get micaSheen => _p.micaSheen;

  /// Mica 玻璃边框
  static Color get micaBorder => _p.micaBorder;

  /// Mica 分区卡片底色 (面板内部次级表面)
  static Color get micaSection => _p.micaSection;

  // ===== v3.5 新增令牌 =====
  /// 焦点环/选中描边色（替代桌面主题的 AppColors.selectedAccent）
  static Color get selectedAccent => _p.selectedAccent;

  /// 危险/警示强调色（原散落硬编码 0xFFFF7B8A / 0xFFFF8A9B）
  static Color get dangerAccent => _p.dangerAccent;

  /// 危险色弱化
  static Color get dangerAccentSoft => _p.dangerAccentSoft;

  /// 上下文菜单表面色
  static Color get menuSurface => _p.menuSurface;

  /// 页面底渐变（深色主题"渐变发微光"基底层）
  static List<Color> get baseGradientColors => _p.baseGradientColors;

  /// 页面底微光色（径向叠加）
  static Color get glowColor => _p.glowColor;

  /// backdrop 纵向遮罩（4 段）
  static List<Color> get backdropScrimV => _p.backdropScrimV;

  /// backdrop 横向遮罩（4 段）
  static List<Color> get backdropScrimH => _p.backdropScrimH;

  /// backdrop 纵向遮罩 —— **OP 视频播放态**（更轻，保证视频「尽可能清晰」）
  static List<Color> get backdropScrimVPlaying => _p.backdropScrimVPlaying;

  /// backdrop 横向遮罩 —— **OP 视频播放态**
  static List<Color> get backdropScrimHPlaying => _p.backdropScrimHPlaying;

  /// 底部栏渐变（首段全透明 → 栏边界消失）
  static List<Color> get shelfScrim => _p.shelfScrim;

  /// 侧边栏玻璃底色
  static Color get railGlass => _p.railGlass;

  /// 侧边栏中心向外渐浅阴影色
  /// 侧边栏环境阴影色 (v3.6-re 柔和阴影团)
  static Color get railShadow => _p.railShadow;

  /// 侧边栏选中图标辉光色 (柔和蓝)
  static Color get navGlowBlue => _p.navGlowBlue;

  /// 侧边栏描边
  static Color get railBorder => _p.railBorder;

  /// 头部栏玻璃底色
  static Color get topBarGlass => _p.topBarGlass;

  /// 头部栏描边
  static Color get topBarBorder => _p.topBarBorder;

  /// 头部栏文字/图标色
  static Color get topBarInk => _p.topBarInk;

  /// 在线状态色
  static Color get statusOnline => _p.statusOnline;

  /// 离线状态色
  static Color get statusOffline => _p.statusOffline;

  /// 封面占位渐变
  static List<Color> get placeholderGradient => _p.placeholderGradient;

  /// 未选中卡片压暗层色
  static Color get cardMask => _p.cardMask;

  /// hero 大标题阴影
  /// 当前调色板是否深色 (辉光强度/按钮底色等分支判断用)
  static bool get isDark => _p.brightness == Brightness.dark;

  static Color get heroTextShadow => _p.heroTextShadow;

  /// hero 大标题辉光
  static Color get heroTextGlow => _p.heroTextGlow;

  /// 次级文字阴影
  static Color get subTextShadow => _p.subTextShadow;

  /// 封面底部渐变
  static Color get coverGradientBottom => _p.coverGradientBottom;

  /// 封面标题文字色
  static Color get coverLabelText => _p.coverLabelText;

  /// 卡片投影色
  static Color get cardShadow => _p.cardShadow;
}
