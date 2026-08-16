import 'package:flutter/widgets.dart';

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
}
