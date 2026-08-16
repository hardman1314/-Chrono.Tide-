import 'package:flutter/material.dart';

/// UX-01: 设计令牌系统——间距基线网格
///
/// 基于 4px 基线网格的间距令牌，替代代码中充斥的魔法数字。
/// 使用方式：`SizedBox(height: AppSpacing.md)` 替代 `SizedBox(height: 12)`
class AppSpacing {
  AppSpacing._();

  /// 极小间距：4px — 图标与文字内部紧贴、细线分隔
  static const double xs = 4;

  /// 小间距：8px — 按钮内边距、紧凑列表行距
  static const double sm = 8;

  /// 中间距：12px — 卡片内边距、表单项间距
  static const double md = 12;

  /// 大间距：16px — 区块间距、列表项间距
  static const double lg = 16;

  /// 超大间距：24px — 卡片间距、分区之间
  static const double xl = 24;

  /// 双倍超大间距：32px — 大区块之间、页面级分区
  static const double xxl = 32;

  /// 三倍超大间距：48px — 页面顶部/底部留白
  static const double xxxl = 48;
}

/// UX-01: 常用 EdgeInsets 预设，减少重复的 EdgeInsets.fromLTRB 调用
class AppPaddings {
  AppPaddings._();

  /// 水平对称内边距（8px）
  static const EdgeInsets horizontalSm =
      EdgeInsets.symmetric(horizontal: AppSpacing.sm);

  /// 水平对称内边距（16px）
  static const EdgeInsets horizontalLg =
      EdgeInsets.symmetric(horizontal: AppSpacing.lg);

  /// 垂直对称内边距（8px）
  static const EdgeInsets verticalSm =
      EdgeInsets.symmetric(vertical: AppSpacing.sm);

  /// 垂直对称内边距（16px）
  static const EdgeInsets verticalLg =
      EdgeInsets.symmetric(vertical: AppSpacing.lg);

  /// 全方位内边距（8px）
  static const EdgeInsets allSm = EdgeInsets.all(AppSpacing.sm);

  /// 全方位内边距（12px）
  static const EdgeInsets allMd = EdgeInsets.all(AppSpacing.md);

  /// 全方位内边距（16px）
  static const EdgeInsets allLg = EdgeInsets.all(AppSpacing.lg);

  /// 卡片标准内边距
  static const EdgeInsets card = EdgeInsets.all(AppSpacing.md);

  /// 页面标准内边距
  static const EdgeInsets page = EdgeInsets.all(AppSpacing.lg);
}
