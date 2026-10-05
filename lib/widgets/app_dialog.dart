import 'package:flutter/material.dart';
import 'custom_title_bar.dart' show kTitleBarHeight;

/// 点击遮罩关闭对话框（带路由守卫）
///
/// ★ 修复（2026-08-30）：详情窗口启动游戏时"点击周边空白导致软件卡死"
/// 旧实现是 `Navigator.of(context).pop()`，没有任何路由状态校验：
/// - 详情窗口关闭动画（250ms）期间路由已 pop 但 State 仍 mounted，
///   此时再点一次空白会把 Navigator 的**下一条路由**一起弹掉；
/// - 若启动流程（超分 Magpie 链路）在 await 中，其回调里还有一次 pop，
///   两者叠加导致路由栈错乱、页面反复重建，主窗口表现为卡死。
///
/// 守卫逻辑：仅当本对话框路由仍是"当前且活动"的路由时才允许 pop。
void _dismiss<T>(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent || !route.isActive) return;
  Navigator.of(context).pop<T>();
}

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
                onTap: barrierDismissible ? () => _dismiss<T>(context) : null,
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
