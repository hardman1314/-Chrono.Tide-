import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../big_picture/big_picture_manager.dart';
import '../big_picture/big_picture_theme.dart';
import '../services/system_notice_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';

/// 系统提示气泡的锚点方位。
enum NoticeAnchor {
  /// 桌面模式：气泡挂在右下角用户按钮（`FloatingUserButton`）**上方**，向上生长。
  bottomRight,

  /// BPM 大屏模式：气泡挂在顶栏用户按钮**下方**，向下生长。
  topRight,
}

/// 全局系统提示渲染层。
///
/// 挂在 `MaterialApp.builder` 的 Stack 顶层（高于 Navigator），因此
/// **弹窗、BPM 大屏模式、登录页全都盖不住它**，无需在各外壳重复挂载。
///
/// 渲染内容见 [SystemNoticeService]；本层只负责「摆在哪、长什么样、怎么进出场」。
class SystemNoticeLayer extends StatelessWidget {
  const SystemNoticeLayer({super.key});

  /// 气泡堆叠最大宽度（气泡本体 320 + 尾巴留白）。
  static const double _stackWidth = 336;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        SystemNoticeService.instance,
        BigPictureManager.instance,
      ]),
      builder: (context, _) {
        final isBpm = BigPictureManager.instance.isActive;
        final anchor =
            isBpm ? NoticeAnchor.topRight : NoticeAnchor.bottomRight;

        // 锚点切换时重建（key 变化），保证 AnimatedList 的内部计数与新顺序一致。
        // 外层 Align+Padding 负责把堆叠贴到用户按钮旁：桌面 = 右下角头像上方，
        // BPM = 顶栏用户按钮下方（top 留出顶栏高度）。
        return Align(
          alignment:
              isBpm ? Alignment.topRight : Alignment.bottomRight,
          child: Padding(
            padding: isBpm
                ? const EdgeInsets.only(
                    top: BigPictureTheme.topBarHeight + 8, right: 26)
                : const EdgeInsets.only(bottom: 112, right: 40),
            child: _NoticeStack(
              key: ValueKey<NoticeAnchor>(anchor),
              anchor: anchor,
            ),
          ),
        );
      },
    );
  }
}

/// 气泡堆叠容器：镜像 [SystemNoticeService] 的列表，负责增删动画。
class _NoticeStack extends StatefulWidget {
  const _NoticeStack({super.key, required this.anchor});

  final NoticeAnchor anchor;

  @override
  State<_NoticeStack> createState() => _NoticeStackState();
}

class _NoticeStackState extends State<_NoticeStack> {
  static const Duration _enter = Duration(milliseconds: 230);
  static const Duration _exit = Duration(milliseconds: 190);

  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  /// 当前渲染顺序（与视觉从上到下一致）。
  late List<SystemNotice> _items;

  @override
  void initState() {
    super.initState();
    _items = _desired();
    SystemNoticeService.instance.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    SystemNoticeService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  /// 期望的渲染顺序：服务返回最旧在前；BPM 需反转使最新贴住顶栏按钮。
  List<SystemNotice> _desired() {
    final base = SystemNoticeService.instance.notices;
    return widget.anchor == NoticeAnchor.topRight
        ? base.reversed.toList(growable: true)
        : List<SystemNotice>.of(base);
  }

  void _onServiceChanged() {
    if (!mounted) return;
    // push 可能发生在 build 期间（错误路径），延迟到帧末再同步，避免
    // 「setState during build」。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync();
      });
    } else {
      _sync();
    }
  }

  void _sync() {
    final desired = _desired();

    // 1) 移除已从服务消失的条目（倒序遍历，避免索引漂移）。
    for (var i = _items.length - 1; i >= 0; i--) {
      final id = _items[i].id;
      if (!desired.any((n) => n.id == id)) {
        final removed = _items.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, animation) => _buildBubble(
            removed,
            animation,
            showTail: false,
            removing: true,
          ),
          duration: _exit,
        );
      }
    }

    // 2) 插入新出现的条目（顺序遍历，索引即最终位置）。
    for (var i = 0; i < desired.length; i++) {
      final notice = desired[i];
      if (!_items.any((n) => n.id == notice.id)) {
        _items.insert(i, notice);
        _listKey.currentState?.insertItem(i, duration: _enter);
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();

    final isBottom = widget.anchor == NoticeAnchor.bottomRight;
    // 尾巴贴在最靠近用户按钮的那一条：桌面 = 最后一条（最下），BPM = 第一条（最上）。
    final tailIndex = isBottom ? _items.length - 1 : 0;

    return SizedBox(
      width: SystemNoticeLayer._stackWidth,
      child: AnimatedList(
        key: _listKey,
        shrinkWrap: true,
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        initialItemCount: _items.length,
        itemBuilder: (context, index, animation) {
          if (index >= _items.length) return const SizedBox.shrink();
          return _buildBubble(
            _items[index],
            animation,
            showTail: index == tailIndex,
          );
        },
      ),
    );
  }

  Widget _buildBubble(
    SystemNotice notice,
    Animation<double> animation, {
    required bool showTail,
    bool removing = false,
  }) {
    // 注意：右对齐必须在 _NoticeBubble 内部（SizeTransition 之内）做。
    // SizeTransition 撑满堆叠宽度，外层 Align 对它无效（见 build 内注释）。
    return _NoticeBubble(
      notice: notice,
      anchor: widget.anchor,
      showTail: showTail,
      animation: animation,
      onDismiss: removing
          ? null
          : () => SystemNoticeService.instance.dismiss(notice.id),
    );
  }
}

/// 单条气泡：实心语义底色 + 白字 + 头像方向尾巴 + 关闭按钮。
class _NoticeBubble extends StatelessWidget {
  const _NoticeBubble({
    required this.notice,
    required this.anchor,
    required this.showTail,
    required this.animation,
    this.onDismiss,
  });

  final SystemNotice notice;
  final NoticeAnchor anchor;
  final bool showTail;
  final Animation<double> animation;
  final VoidCallback? onDismiss;

  static const double _maxWidth = 320;
  static const double _minWidth = 176;
  static const double _tailWidth = 14;
  static const double _tailHeight = 7;

  @override
  Widget build(BuildContext context) {
    final color = systemNoticeColor(notice.level);
    final tailUp = anchor == NoticeAnchor.topRight;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showTail && tailUp)
          const SizedBox(height: 6)
        else
          const SizedBox(height: 5),
        _bubbleBody(context, color),
        if (showTail && !tailUp) ...[
          _tail(color, up: false),
          const SizedBox(height: 2),
        ],
      ],
    );

    return SizeTransition(
      sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      // 桌面堆叠底部固定 → 从下往上显现；BPM 顶部固定 → 从上往下显现。
      axisAlignment: tailUp ? -1.0 : 1.0,
      child: FadeTransition(
        opacity: animation,
        // 🔴 SizeTransition 内部是 Align(alignment: Alignment(-1.0, axisAlignment))，
        // x 分量写死 -1.0 → 气泡被压到堆叠左缘（2026-10-03 真机截图实测：
        // 右缘距窗口右缘 193 逻辑px，而非 right:40）。必须在 SizeTransition
        // 之内再包一层 Align 把气泡贴回右缘，与用户按钮右缘对齐。
        child: Align(
          alignment: Alignment.centerRight,
          child: content,
        ),
      ),
    );
  }

  Widget _bubbleBody(BuildContext context, Color color) {
    final radius = Radius.circular(AppStyle.rLg);
    final border = BorderRadius.only(
      topLeft: radius,
      topRight: radius,
      bottomLeft: radius,
      bottomRight: showTail ? const Radius.circular(4) : radius,
    );

    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: _maxWidth,
          minWidth: _minWidth,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: border,
          boxShadow: AppStyle.e3,
        ),
        child: ClipRRect(
          borderRadius: border,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 8, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        _iconFor(notice.level),
                        size: 17,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notice.title ?? _defaultTitle(notice.level),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            notice.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    _closeButton(),
                  ],
                ),
              ),
              if (notice.autoDismissAfter != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey<int>(notice.id),
                    tween: Tween<double>(begin: 1.0, end: 0.0),
                    duration: notice.autoDismissAfter!,
                    builder: (context, value, _) => FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: value.clamp(0.0, 1.0),
                      child: Container(
                        height: 2,
                        color: Colors.white.withOpacity(0.38),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _closeButton() {
    final enabled = onDismiss != null;
    return Semantics(
      button: true,
      label: '关闭提示',
      child: MouseRegion(
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: const SizedBox(
            width: 22,
            height: 22,
            child: Icon(
              Icons.close_rounded,
              size: 15,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// 指向用户头像的三角尾巴。
  Widget _tail(Color color, {required bool up}) {
    // 尾巴水平位置对齐头像中心：
    // 桌面（右 40 锚点 + 56 头像）→ 距堆叠右缘 28px；
    // BPM（右 26 锚点 + 44 头像）→ 距堆叠右缘 22px。
    final rightInset =
        anchor == NoticeAnchor.bottomRight ? 21.0 : 15.0;
    return Padding(
      padding: EdgeInsets.only(right: rightInset),
      child: CustomPaint(
        size: const Size(_tailWidth, _tailHeight),
        painter: _TailPainter(color: color, up: up),
      ),
    );
  }
}

/// 语义等级 → 实心底色（沿用主题令牌，随明暗主题自适应）。
Color systemNoticeColor(NoticeLevel level) {
  switch (level) {
    case NoticeLevel.success:
      return AppColors.successGreen;
    case NoticeLevel.warning:
      return AppColors.warningAmber;
    case NoticeLevel.error:
      return AppColors.dangerRed;
    case NoticeLevel.info:
      return AppColors.infoBlue;
  }
}

IconData _iconFor(NoticeLevel level) {
  switch (level) {
    case NoticeLevel.success:
      return Icons.check_circle_outline;
    case NoticeLevel.warning:
      return Icons.warning_amber_outlined;
    case NoticeLevel.error:
      return Icons.error_outline;
    case NoticeLevel.info:
      return Icons.info_outline;
  }
}

String _defaultTitle(NoticeLevel level) {
  switch (level) {
    case NoticeLevel.success:
      return '操作成功';
    case NoticeLevel.warning:
      return '注意';
    case NoticeLevel.error:
      return '出错了';
    case NoticeLevel.info:
      return '提示';
  }
}

/// 气泡下指 / 上指三角。
class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color, required this.up});

  final Color color;

  /// true = 朝上（BPM，指向顶栏按钮）；false = 朝下（桌面，指向右下角按钮）。
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    if (up) {
      path
        ..moveTo(0, size.height)
        ..lineTo(size.width, size.height)
        ..lineTo(size.width / 2, 0);
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TailPainter oldDelegate) =>
      color != oldDelegate.color || up != oldDelegate.up;
}
