import 'package:flutter/material.dart';

import '../../services/nsfw/nsfw_settings.dart';
import '../../theme/app_colors.dart';

/// NSFW 三档滑动开关：关闭 / 纯净 / 工作（v2.1.15）。
///
/// **复用既有 [NsfwDisplayMode] 枚举，不新增重复定义。** 三档与持久化的映射：
///
/// | 档位 | `NsfwSettings.enabled` | `NsfwSettings.mode` |
/// | --- | --- | --- |
/// | 关闭 | `false` | **保持不变**（下次开启沿用） |
/// | 纯净 | `true` | [NsfwDisplayMode.clean] |
/// | 工作 | `true` | [NsfwDisplayMode.work] |
///
/// 「关闭」档只写 `enabled=false`、**不重置 mode**，所以从「工作」关掉再打开
/// 仍回到「工作」——即「沿用切换前的状态」。
///
/// 数据源与设置页是同一个 [NsfwSettings.instance]（ChangeNotifier），
/// 任一侧改动即时同步到另一侧，不存在两份状态；本控件用 [AnimatedBuilder]
/// 监听，设置页改了这里也会跟着变。
class NsfwModeSwitch extends StatefulWidget {
  const NsfwModeSwitch({
    super.key,
    this.enabled = true,
    this.height = 24,
    this.segmentWidth = 42,
  });

  /// 外部闸门：`false` 时控件置灰且不可交互（语义禁用）。
  ///
  /// ⚠️ 用户窗口里**必须**恒为 `true` —— 因为「关闭」档本身要能被点回升，
  /// 若把闸门接到 `NsfwSettings.enabled`，切到「关闭」就会把自己锁死
  /// （禁用后无法再拖回「纯净」）。这里保留参数只为将来接入真正的独立闸门。
  final bool enabled;

  /// 控件高度。保持 24 与原二态开关一致，避免撑高右上角头部。
  final double height;

  /// 单档宽度。沿用原二态开关的 42px，使每档尺寸与历史一致。
  final double segmentWidth;

  @override
  State<NsfwModeSwitch> createState() => _NsfwModeSwitchState();
}

class _NsfwModeSwitchState extends State<NsfwModeSwitch> {
  static const List<String> _labels = <String>['关闭', '纯净', '工作'];
  static const List<IconData> _icons = <IconData>[
    Icons.power_settings_new_rounded,
    Icons.visibility_off_rounded,
    Icons.work_rounded,
  ];
  static const List<String> _tips = <String>[
    'NSFW 内容保护：已关闭（点击开启）',
    'NSFW 纯净模式：本地 AI 判定敏感内容后模糊或隐藏',
    'NSFW 工作模式：所有图片替换为占位图，不加载模型',
  ];

  static const Duration _slide = Duration(milliseconds: 220);
  static const double _pad = 2.0;

  bool _hovered = false;
  bool _dragging = false;
  bool _dragMoved = false;
  double? _dragLeft;

  double get _trackW => widget.segmentWidth * 3;
  double get _maxLeft => _trackW - widget.segmentWidth;

  /// 持久化状态 → 档位下标。
  static int _indexFor(bool enabled, NsfwDisplayMode mode) {
    if (!enabled) return 0;
    return mode == NsfwDisplayMode.work ? 2 : 1;
  }

  /// 档位下标 → 写回持久化。
  Future<void> _commit(int index) async {
    final NsfwSettings s = NsfwSettings.instance;
    if (index == 0) {
      await s.setEnabled(false);
      return;
    }
    if (!s.enabled) await s.setEnabled(true);
    await s.setMode(index == 2 ? NsfwDisplayMode.work : NsfwDisplayMode.clean);
  }

  int _indexAt(double dx) =>
      ((dx - _pad) / widget.segmentWidth).floor().clamp(0, 2);

  void _setDrag(double dx) {
    setState(() {
      _dragLeft =
          (dx - _pad - widget.segmentWidth / 2).clamp(0.0, _maxLeft);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: NsfwSettings.instance,
      builder: (BuildContext context, Widget? _) {
        final NsfwSettings s = NsfwSettings.instance;
        final int index = _indexFor(s.enabled, s.mode);
        final bool interactive = widget.enabled;
        final double left =
            (_dragLeft ?? index * widget.segmentWidth).clamp(0.0, _maxLeft);

        return Semantics(
          container: true,
          enabled: interactive,
          label: 'NSFW 内容保护模式，当前：${_labels[index]}',
          child: Tooltip(
            message: _tips[index],
            waitDuration: const Duration(milliseconds: 400),
            child: MouseRegion(
              cursor: interactive
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: interactive && !_dragMoved
                    ? (TapUpDetails d) => _commit(_indexAt(d.localPosition.dx))
                    : null,
                onHorizontalDragStart: interactive
                    ? (DragStartDetails d) {
                        _dragMoved = true;
                        setState(() => _dragging = true);
                        _setDrag(d.localPosition.dx);
                      }
                    : null,
                onHorizontalDragUpdate: interactive
                    ? (DragUpdateDetails d) => _setDrag(d.localPosition.dx)
                    : null,
                onHorizontalDragEnd: interactive
                    ? (DragEndDetails d) {
                        final double cur =
                            (_dragLeft ?? 0.0).clamp(0.0, _maxLeft);
                        final int target =
                            (cur / widget.segmentWidth).round().clamp(0, 2);
                        // 先让滑块从当前位置平滑滑到目标档（而非回弹到旧档），
                        // commit 完成后 _dragLeft 置空，此时 index 已等于
                        // target，left 不变，不会产生二次跳动。
                        setState(() {
                          _dragging = false;
                          _dragLeft = target * widget.segmentWidth;
                        });
                        _commit(target).whenComplete(() {
                          if (mounted) setState(() => _dragLeft = null);
                          _dragMoved = false;
                        });
                      }
                    : null,
                child: _track(index, left, interactive),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _track(int index, double left, bool interactive) {
    final bool hot = _hovered && interactive;
    return AnimatedOpacity(
      opacity: interactive ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 150),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: _trackW + _pad * 2,
        height: widget.height,
        padding: const EdgeInsets.all(_pad),
        decoration: BoxDecoration(
          color: AppColors.sidebarBackground,
          borderRadius: BorderRadius.circular(widget.height / 2),
          border: Border.all(
            color: hot ? AppColors.border : AppColors.borderLight,
            width: hot ? 1.4 : 1.0,
          ),
        ),
        child: Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: _dragging ? Duration.zero : _slide,
              curve: Curves.easeOutCubic,
              left: left,
              top: 0,
              width: widget.segmentWidth,
              height: widget.height - _pad * 2,
              child: _thumb(index),
            ),
            // Positioned.fill 给 Row 紧约束，否则 Expanded 在无界宽度下报错。
            Positioned.fill(
              child: Row(
                children: List<Widget>.generate(3, (int i) {
                  final bool sel = i == index;
                  return Expanded(
                    child: Semantics(
                      button: true,
                      selected: sel,
                      enabled: interactive,
                      label: _labels[i],
                      child: IgnorePointer(
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                _icons[i],
                                size: 11,
                                color: sel
                                    ? Colors.white
                                    : AppColors.secondaryText,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _labels[i],
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  height: 1.0,
                                  color: sel
                                      ? Colors.white
                                      : AppColors.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(int index) {
    final Color fill = index == 0
        ? AppColors.secondaryText.withOpacity(0.55)
        : const Color(0xFF4CAF50); // 与设置页开关同色
    return Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular((widget.height - _pad * 2) / 2),
      ),
    );
  }
}
