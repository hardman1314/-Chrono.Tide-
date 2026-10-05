import 'package:flutter/material.dart';

import '../custom_title_bar.dart' show kTitleBarHeight;

/// 探索详情页 4 个弹窗共享的**固定深色**调色板与基础组件。
///
/// 设计稿（Figma）把这 4 个窗口画成独立于主题的"暗色工作台"：
/// 无论应用当前是暖阳 / 浅色 / 深色 / 墨绿金 / 樱花 / 蓝天，它们恒为深色。
/// 用户已确认采用「固定深色，不随主题」方案，故此处直接常量固化，
/// **不接入 CTThemeData / AppColors**（接入反而会破坏 1:1 复刻）。
///
/// 色值全部取自设计 JSON（`素材/新建文件夹 (2)/*.json`），
/// 并在用户提供的截图中逐点取样核对过。
class DarkPalette {
  const DarkPalette._();

  // ===== 窗口骨架 =====
  /// 窗口底色
  static const Color bg = Color(0xFF18181B);

  /// 窗口描边
  static const Color border = Color(0xFF242426);

  /// 内层卡片描边
  static const Color cardBorder = Color(0xFF414146);

  /// 表单控件描边
  static const Color fieldBorder = Color(0xFF28282F);

  /// 编辑器描边（比普通输入框更亮一档）
  static const Color editorBorder = Color(0xFF3B3B43);

  // ===== 文字层级 =====
  /// 一级标题
  static const Color textPrimary = Color(0xFFE4E4E8);

  /// 二级标题 / 强调正文
  static const Color textSecondary = Color(0xFFD5D5DA);

  /// 正文
  static const Color textBody = Color(0xFFB9B9C6);

  /// 标签（表单 label）
  static const Color textLabel = Color(0xFFBCBCC7);

  /// 弱化说明 / 元信息
  static const Color textMuted = Color(0xFF8B8B97);

  /// 次级元信息（网盘名、下载数）
  static const Color textDim = Color(0xFF92929E);

  /// 占位符
  static const Color placeholder = Color(0xFF71717C);

  // ===== 强调色 =====
  /// 主行动蓝（发布 / 下载）
  static const Color primaryBlue = Color(0xFF0878F9);

  /// 官方下载按钮蓝
  static const Color actionBlue = Color(0xFF0078F5);

  /// 网盘跳转蓝
  static const Color linkBlue = Color(0xFF1463C2);

  /// 成功绿
  static const Color green = Color(0xFF0BD565);

  /// 警示黄
  static const Color yellow = Color(0xFFFFB600);

  /// 紫
  static const Color violet = Color(0xFFC088F6);

  /// 粉
  static const Color pink = Color(0xFFFF53D1);

  /// 浅蓝（徽章字色）
  static const Color lightBlue = Color(0xFF5CAFFF);

  /// 复制码按钮绿
  static const Color copyGreen = Color(0xFF22C565);

  /// 复制码按钮文字
  static const Color copyGreenText = Color(0xFF05190C);

  /// 必填星号
  static const Color requiredStar = Color(0xFFEC2576);

  /// 编辑器工具条激活色
  static const Color toolbarActive = Color(0xFF008BFF);

  /// 编辑器工具条默认色
  static const Color toolbarIdle = Color(0xFFD9D9DE);

  // ===== 徽章底色（与上面强调色成对使用）=====
  static const Color badgeBlueBg = Color(0xFF152C46);
  static const Color badgeVioletBg = Color(0xFF30233F);
  static const Color badgeGreenBg = Color(0xFF153D2B);
  static const Color badgeYellowBg = Color(0xFF443414);
  static const Color badgePinkBg = Color(0xFF453041);
  static const Color badgeNeutralBg = Color(0xFF252529);
  static const Color badgeMutedBg = Color(0xFF202E29);

  // ===== 结构块 =====
  /// 分享卡片（有效）
  static const Color shareCardBg = Color(0xFF091C12);
  static const Color shareCardBorder = Color(0xFF006920);

  /// 分享卡片内的说明块
  static const Color shareNoteBg = Color(0xFF14211C);

  /// 分享详情顶部栏
  static const Color detailHeaderBg = Color(0xFF1A2C23);

  /// 发布者备注卡
  static const Color noteCardBg = Color(0xFF143139);

  /// 下载链接卡
  static const Color linkCardBg = Color(0xFF19283C);

  /// 汐乃的小请求卡
  static const Color requestCardBg = Color(0xFF252528);

  /// 补票提示卡
  static const Color tipCardBg = Color(0xFF351421);
  static const Color tipCardBorder = Color(0xFFFF0060);

  /// 关闭按钮
  static const Color closeButtonBg = Color(0xFF74737E);

  /// Markdown 支持胶囊
  static const Color mdPillBg = Color(0xFF123D25);
  static const Color mdPillText = Color(0xFF20C66A);

  /// 关闭图标
  static const Color closeIcon = Color(0xFFC9C9D0);

  // ===== 尺寸（对齐设计 JSON，单位 dp）=====
  /// Chrono Tide 下载栏
  static const double downloadBarWidth = 515;

  /// 资源分享栏
  static const double shareListWidth = 600;

  /// 分享详情窗
  static const double shareDetailWidth = 725;
  static const double shareDetailHeight = 915;

  /// 发布资源窗
  static const double uploadWidth = 679;
  static const double uploadHeight = 1083;

  /// 窗口圆角（统一档：T2 大型模态面板 = 16，与 AppRadius.xl 一致）
  static const double radiusShell = 16;
  static const double radiusCard = 14;
  static const double radiusField = 12;

  /// 窗口阴影
  static const List<BoxShadow> shellShadow = [
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 16.62,
      offset: Offset(0, 3.32),
    ),
  ];
}

// ============================================================
// 基础原子组件
// ============================================================

/// 深色窗口外壳：底色 + 描边 + 圆角 + 阴影
class DarkShell extends StatelessWidget {
  const DarkShell({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.radius = DarkPalette.radiusShell,
  });

  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: DarkPalette.bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: DarkPalette.border, width: 0.6),
        boxShadow: DarkPalette.shellShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 徽章：胶囊底 + 可选前置图标 + 文字
class DarkBadge extends StatelessWidget {
  const DarkBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    this.borderRadius = 999,
  });

  /// 无图标徽章（如「民间汉化」灰底）
  const DarkBadge.plain({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    this.borderRadius = 999,
  }) : icon = null;

  final String label;
  final Color background;
  final Color foreground;
  final Widget? icon;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: foreground, size: fontSize + 1),
              child: icon!,
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              color: foreground,
              fontWeight: FontWeight.w500,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 内层卡片（描边容器）
class DarkCard extends StatelessWidget {
  const DarkCard({
    super.key,
    required this.child,
    this.background,
    this.borderColor = DarkPalette.cardBorder,
    this.padding = const EdgeInsets.all(14),
    this.radius = DarkPalette.radiusCard,
    this.borderWidth = 0.6,
  });

  final Widget child;
  final Color? background;
  final Color borderColor;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: child,
    );
  }
}

/// 实心主按钮
class DarkPrimaryButton extends StatelessWidget {
  const DarkPrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.background = DarkPalette.primaryBlue,
    this.foreground = Colors.white,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
    this.radius = 11,
    this.fontSize = 13,
    this.fontWeight = FontWeight.w600,
    this.enabled = true,
    this.busy = false,
  });

  final String label;

  /// 可选前置图标（如分享卡的「获取资源」云图标）；为空则只有文字
  final Widget? icon;

  final VoidCallback? onTap;
  final Color background;
  final Color foreground;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double fontSize;
  final FontWeight fontWeight;
  final bool enabled;

  /// 提交中：显示加载圈并禁用点击
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final active = enabled && !busy;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.55,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: busy
                ? SizedBox(
                    width: fontSize + 1,
                    height: fontSize + 1,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      valueColor: AlwaysStoppedAnimation(foreground),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        IconTheme.merge(
                          data: IconThemeData(size: fontSize + 1.5, color: foreground),
                          child: icon!,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: fontSize,
                          color: foreground,
                          fontWeight: fontWeight,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 幽灵按钮（无底色，仅文字，可带图标）
class DarkGhostButton extends StatelessWidget {
  const DarkGhostButton({
    super.key,
    required this.label,
    required this.onTap,
    this.foreground = DarkPalette.textSecondary,
    this.icon,
    this.fontSize = 13,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
  });

  final String label;
  final VoidCallback? onTap;
  final Color foreground;
  final Widget? icon;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                IconTheme.merge(
                  data: IconThemeData(color: foreground, size: fontSize + 2),
                  child: icon!,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(fontSize: fontSize, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 图标按钮（方形，圆角）
class DarkIconButton extends StatelessWidget {
  const DarkIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.background,
    this.foreground = Colors.white,
    this.size = 24,
    this.radius = 7.58,
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback? onTap;
  final Color? background;
  final Color foreground;
  final double size;
  final double radius;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget body = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: size * 0.52),
            child: Center(child: icon),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      body = Tooltip(message: tooltip!, child: body);
    }
    return body;
  }
}

/// 关闭按钮（右上角 ×）
class DarkCloseButton extends StatelessWidget {
  const DarkCloseButton({super.key, required this.onTap, this.size = 28});

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DarkIconButton(
      icon: const Icon(Icons.close_rounded),
      onTap: onTap,
      size: size,
      radius: size / 2,
      foreground: DarkPalette.closeIcon,
    );
  }
}

/// 表单字段：label（可带必填星号）+ 控件 + 辅助说明
class DarkField extends StatelessWidget {
  const DarkField({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
    this.helper,
    this.trailing,
    this.labelSpacing = 6,
    this.helperSpacing = 6,
  });

  final String label;
  final Widget child;
  final bool required;

  /// 字段下方的辅助说明（设计稿的 Paragraph）
  final String? helper;

  /// label 行右侧的附加控件（如「清除」按钮）
  final Widget? trailing;

  final double labelSpacing;
  final double helperSpacing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: DarkPalette.textLabel,
              ),
            ),
            if (required)
              const Text(
                ' *',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: DarkPalette.requiredStar,
                ),
              ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
        SizedBox(height: labelSpacing),
        child,
        if (helper != null) ...[
          SizedBox(height: helperSpacing),
          Text(
            helper!,
            style: const TextStyle(
              fontSize: 11.5,
              color: DarkPalette.textMuted,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

/// 深色输入框的基础装饰
InputDecoration darkInputDecoration({
  String? hint,
  EdgeInsetsGeometry padding =
      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  bool multiline = false,
}) {
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 12.5, color: DarkPalette.placeholder),
    contentPadding: padding,
    filled: false,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(DarkPalette.radiusField),
      borderSide: const BorderSide(color: DarkPalette.fieldBorder, width: 0.8),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(DarkPalette.radiusField),
      borderSide: const BorderSide(color: DarkPalette.fieldBorder, width: 0.8),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(DarkPalette.radiusField),
      borderSide: const BorderSide(color: DarkPalette.primaryBlue, width: 1.1),
    ),
  );
}

/// 深色单行输入框
class DarkTextInput extends StatelessWidget {
  const DarkTextInput({
    super.key,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.textAlignVertical,
  });

  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final TextAlignVertical? textAlignVertical;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textAlignVertical: textAlignVertical,
      style: const TextStyle(fontSize: 12.5, color: DarkPalette.textPrimary),
      cursorColor: DarkPalette.primaryBlue,
      decoration: darkInputDecoration(hint: hint),
    );
  }
}

// ============================================================
// 弹窗显示：居中 / 锚定
// ============================================================

/// 点击深色遮罩关闭（带路由守卫，逻辑与 [showAppDialog] 一致）
void _dismissDark<T>(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent || !route.isActive) return;
  Navigator.of(context).pop<T>();
}

/// 🔴 为什么两个 show 函数都要包一层 `Material(type: MaterialType.transparency)`
///
/// `MaterialApp` 会把框架内部的 `_errorTextStyle`（见
/// `flutter/.../src/material/app.dart:33`）作为**全局兜底 `DefaultTextStyle`**。
/// 那个样式专门用来提示开发者"这段文字没放进 `Material`"，它带：
/// `decoration: underline` + `decorationColor: Color(0xFFFFFF00)` +
/// `decorationStyle: double` —— 也就是**纯黄双下划线**。
///
/// 本浮层挂在 `Overlay` 上、**没有 `Material` 祖先** ⇒ 弹窗内所有"没有显式
/// 设置 `style`"的 `Text` 都会继承这条黄线（其 `color` 因为被各 Text 自己的
/// style 覆盖，所以文字看起来正常，只有线是多余的）。
///
/// 这正是 2026-10-01 真机走查里反复出现的「设计外的标线」的根因。
/// 包一层**透明** `Material` 后，`DefaultTextStyle` 回到主题的
/// `textTheme.bodyMedium`（无 decoration），且不绘制任何背景。
///
/// ⛔ 不要改成"手动 copyWith(decoration: none)"这类写法——
/// 透明 `Material` 是 Flutter 框架注释里给出的官方解法。
///
/// 居中深色弹窗（分享详情 / 发布资源）
///
/// 遮罩自标题栏下方开始（与项目既有 [showAppDialog] 约定一致），
/// 内容超屏时由调用方内部滚动（如发布表单 1083dp > 720dp 视口）。
Future<T?> showDarkCenteredDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, animation, secondary) => const SizedBox.shrink(),
    transitionBuilder: (ctx, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return Stack(
        children: [
          Positioned(
            top: kTitleBarHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: curved,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: barrierDismissible ? () => _dismissDark<T>(ctx) : null,
                child: Container(color: const Color(0x8C000000)),
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
                child: Material(
                  type: MaterialType.transparency,
                  child: builder(ctx),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 锚定式深色浮层（Chrono Tide 下载栏 / 资源分享栏）
///
/// 定位算法（由 [_AnchoredPanelLayout] 在拿到子组件实测尺寸后执行）：
/// 1. 宽度 = min([preferredWidth], 可用宽度 − 2×[margin])；
/// 2. 水平：优先与锚点左缘对齐，越界则贴边；
/// 3. 垂直：优先置于锚点下方 [anchorGap]；下方空间不足且上方更宽裕 → 翻到上方；
/// 4. 最终夹紧在「标题栏之下、窗口底边之上」的可用区域内。
///
/// 之所以用 [CustomSingleChildLayout] 而不是 `Positioned`：面板高度取决于内容
/// （下载栏有/无版本徽章会差一行），必须测量后才能决定是"贴锚点下方"还是"翻上去"。
Future<T?> showDarkAnchoredPanel<T>({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
  double preferredWidth = DarkPalette.downloadBarWidth,
  double anchorGap = 8,
  double margin = 12,
}) {
  final overlayBox =
      Overlay.of(context, rootOverlay: true).context.findRenderObject()
          as RenderBox?;
  final screenSize = overlayBox?.size ?? const Size(1280, 720);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, animation, secondary) => const SizedBox.shrink(),
    transitionBuilder: (ctx, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return Stack(
        children: [
          Positioned(
            top: kTitleBarHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: curved,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _dismissDark<T>(ctx),
                child: Container(color: const Color(0x40000000)),
              ),
            ),
          ),
          Positioned.fill(
            child: FadeTransition(
              opacity: curved,
              child: CustomSingleChildLayout(
                delegate: _AnchoredPanelLayout(
                  anchor: anchor,
                  anchorGap: anchorGap,
                  margin: margin,
                  preferredWidth: preferredWidth,
                  screenSize: screenSize,
                ),
                // 🔴 透明 Material：见文件顶部「为什么两个 show 函数都要包一层」。
                child: Material(
                  type: MaterialType.transparency,
                  child: builder(ctx),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 锚定浮层的定位委托：先约束子组件宽度，再按实测高度决定最终位置。
class _AnchoredPanelLayout extends SingleChildLayoutDelegate {
  _AnchoredPanelLayout({
    required this.anchor,
    required this.anchorGap,
    required this.margin,
    required this.preferredWidth,
    required this.screenSize,
  });

  final Rect anchor;
  final double anchorGap;
  final double margin;
  final double preferredWidth;
  final Size screenSize;

  /// 可用区域：标题栏之下 → 窗口底边之上
  double get _topLimit => kTitleBarHeight + margin;

  double get _bottomLimit => screenSize.height - margin;

  double get _width => preferredWidth
      .clamp(240.0, (screenSize.width - margin * 2).clamp(240.0, 4000.0));

  double get _left {
    var left = anchor.left;
    if (left + _width > screenSize.width - margin) {
      left = screenSize.width - margin - _width;
    }
    if (left < margin) left = margin;
    return left;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
        minWidth: 0,
        maxWidth: _width,
        minHeight: 0,
        maxHeight: (_bottomLimit - _topLimit).clamp(0.0, c.maxHeight),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = anchor.bottom + anchorGap;
    final roomBelow = _bottomLimit - below;
    final roomAbove = anchor.top - anchorGap - _topLimit;

    final double top;
    if (roomBelow >= childSize.height || roomBelow >= roomAbove) {
      top = below;
    } else {
      top = anchor.top - anchorGap - childSize.height;
    }

    final maxTop =
        (_bottomLimit - childSize.height).clamp(_topLimit, _bottomLimit);
    final clampedTop = top.clamp(_topLimit, maxTop);

    return Offset(_left, clampedTop);
  }

  @override
  bool shouldRelayout(_AnchoredPanelLayout old) =>
      anchor != old.anchor ||
      anchorGap != old.anchorGap ||
      margin != old.margin ||
      preferredWidth != old.preferredWidth ||
      screenSize != old.screenSize;
}
