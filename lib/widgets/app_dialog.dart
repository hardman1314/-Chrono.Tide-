import 'package:flutter/material.dart';
import 'custom_title_bar.dart' show kTitleBarHeight;

/// 标题栏安全的对话框显示函数
///
/// 替代 `showDialog`，将半透明遮罩定位在标题栏下方（top: kTitleBarHeight），
/// 而非覆盖整个窗口。确保标题栏在对话框打开时仍可交互（拖动/最小化/最大化/关闭）。
///
/// 适用于长时间存活的对话框（如游戏详情、启动管理器），
/// 短暂确认对话框（删除确认等）仍可使用标准 `showDialog`。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = const Color(0x66000000),
  Duration transitionDuration = const Duration(milliseconds: 250),
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent, // 禁用默认 barrier，使用自定义遮罩
    transitionDuration: transitionDuration,
    pageBuilder: (context, animation, secondaryAnimation) {
      return builder(context);
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return Stack(
        children: [
          // 自定义遮罩从标题栏下方开始
          Positioned(
            top: kTitleBarHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: animation,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: barrierDismissible
                    ? () => Navigator.of(context).pop<T>()
                    : null,
                child: Container(color: barrierColor),
              ),
            ),
          ),
          // 对话框内容
          child,
        ],
      );
    },
  );
}
