import 'package:flutter/material.dart';

/// UX-07: 响应式布局断点系统
///
/// 遵循 Material Design 3 窗口尺寸类别：
/// - compact: 0-960px（窄窗口，单列布局）
/// - medium: 960-1280px（中等窗口，双列布局）
/// - expanded: 1280-1920px（宽窗口，多列布局）
/// - large: 1920px+（超宽窗口）
class AppBreakpoints {
  AppBreakpoints._();

  static const double compact = 960;
  static const double medium = 1280;
  static const double expanded = 1920;

  /// 根据窗口宽度判断布局类别
  static WindowSizeClass classify(double width) {
    if (width < compact) return WindowSizeClass.compact;
    if (width < medium) return WindowSizeClass.medium;
    if (width < expanded) return WindowSizeClass.expanded;
    return WindowSizeClass.large;
  }

  /// 从 BuildContext 获取当前窗口尺寸类别
  static WindowSizeClass of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return classify(width);
  }

  /// 是否为窄窗口（需要单列布局）
  static bool isCompact(BuildContext context) =>
      of(context) == WindowSizeClass.compact;

  /// 是否为中等窗口
  static bool isMedium(BuildContext context) =>
      of(context) == WindowSizeClass.medium;

  /// 是否为宽窗口
  static bool isExpanded(BuildContext context) {
    final cls = of(context);
    return cls == WindowSizeClass.expanded || cls == WindowSizeClass.large;
  }
}

enum WindowSizeClass {
  /// 窄窗口：0-960px
  compact,

  /// 中等窗口：960-1280px
  medium,

  /// 宽窗口：1280-1920px
  expanded,

  /// 超宽窗口：1920px+
  large,
}
