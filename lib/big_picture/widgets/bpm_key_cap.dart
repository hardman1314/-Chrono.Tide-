import 'package:flutter/material.dart';

import '../../services/local_game_registry.dart';
import '../../theme/app_styles.dart';

/// BPM 输入模式（v3.20 引导基建）。
///
/// 复用 shell 的热判定结论（默认键鼠；手柄已连接 + 真实输入 → 手柄），
/// 经 [BpmInputModeScope] 下发，引导类 UI 据此切换键帽图标。
enum BpmInputMode { keyboardMouse, gamepad }

/// 输入模式下发（shell 持有并随模式切换重建）。
class BpmInputModeScope extends InheritedWidget {
  final BpmInputMode mode;

  const BpmInputModeScope({
    super.key,
    required this.mode,
    required super.child,
  });

  static BpmInputMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BpmInputModeScope>()?.mode ??
      BpmInputMode.keyboardMouse;

  @override
  bool updateShouldNotify(BpmInputModeScope oldWidget) =>
      oldWidget.mode != mode;
}

/// BPM 按键图标（引导用，全界面统一视觉语言）。
///
/// - 手柄：ABXY 圆键帽（降饱和描边风）+ 摇杆 + 扳机（斜置）；
/// - 键鼠：鼠标左/右/中键轮廓（左键 ×2 = 双击）+ 圆角/方形键盘键帽。
enum BpmKeyCapType {
  mouseLeft,
  mouseLeftDouble,
  mouseRight,
  mouseMiddle,
  keycap,
  gamepadA,
  gamepadB,
  gamepadX,
  gamepadY,
  stick,
  gamepadLB,
  gamepadRB,
  triggerLT,
  triggerRT,
}

/// 操作引导总开关下发（v3.21）。
///
/// shell 用 [AnimatedBuilder] 监听 `BpmGuidePreference` 重建包裹 BPM 子树；
/// 引导类组件经 [BpmGuideScope.enabledOf] 短路退出 —— 关闭时完全不渲染，
/// 不留任何空占位。
class BpmGuideScope extends InheritedWidget {
  final bool enabled;

  const BpmGuideScope({super.key, required this.enabled, required super.child});

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BpmGuideScope>()?.enabled ??
      true;

  @override
  bool updateShouldNotify(BpmGuideScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// 引导提示文字（键帽旁的说明字，全界面统一）。
/// v3.21 自 `big_picture_home.dart` 迁入 —— 多个引导组件共用。
const kGuideHintStyle = TextStyle(
  fontFamily: AppStyles.uiFontFamily,
  fontSize: 11,
  height: 1.2,
  color: Color(0xFFE9E2EF),
);

/// 引导提示分隔符（斜杠）。
const kGuideHintDividerStyle = TextStyle(
  fontFamily: AppStyles.uiFontFamily,
  fontSize: 11,
  height: 1.2,
  color: Color(0xFF8D80A0),
);

class BpmKeyCap extends StatelessWidget {
  final BpmKeyCapType type;
  /// [BpmKeyCapType.keycap] 的键面字符（Enter / Esc / 单字符等）。
  final String? label;
  /// 方形（字符键帽）或圆角（Enter/Esc 等），仅 keycap 生效。
  final bool square;
  final double size;

  const BpmKeyCap(
    this.type, {
    super.key,
    this.label,
    this.square = false,
    this.size = 19,
  });

  // 降饱和手柄配色（描边风，避免与 Cinema 樱粉主题打架）
  static const _aColor = Color(0xFF7FAE45);
  static const _bColor = Color(0xFFD66A68);
  static const _xColor = Color(0xFF6F95D6);
  static const _yColor = Color(0xFFC79A3E);
  static const _outline = Color(0xFFB8AED0);

  Color get _stroke {
    switch (type) {
      case BpmKeyCapType.gamepadA:
        return _aColor;
      case BpmKeyCapType.gamepadB:
        return _bColor;
      case BpmKeyCapType.gamepadX:
        return _xColor;
      case BpmKeyCapType.gamepadY:
        return _yColor;
      default:
        return _outline;
    }
  }

  String? get _face {
    switch (type) {
      case BpmKeyCapType.gamepadA:
        return 'A';
      case BpmKeyCapType.gamepadB:
        return 'B';
      case BpmKeyCapType.gamepadX:
        return 'X';
      case BpmKeyCapType.gamepadY:
        return 'Y';
      case BpmKeyCapType.triggerLT:
        return 'LT';
      case BpmKeyCapType.triggerRT:
        return 'RT';
      case BpmKeyCapType.gamepadLB:
        return 'LB';
      case BpmKeyCapType.gamepadRB:
        return 'RB';
      default:
        return label;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = size;
    switch (type) {
      case BpmKeyCapType.mouseLeft:
      case BpmKeyCapType.mouseLeftDouble:
      case BpmKeyCapType.mouseRight:
      case BpmKeyCapType.mouseMiddle:
        return _mouse(s);
      case BpmKeyCapType.stick:
        return Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _outline, width: 1.2),
          ),
          alignment: Alignment.center,
          child: Container(
            width: s * 0.42,
            height: s * 0.42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _outline, width: 1),
            ),
          ),
        );
      case BpmKeyCapType.triggerLT:
      case BpmKeyCapType.triggerRT:
        // 斜置扳机：圆角横键 + 顶部弧背（Transform 轻量表达）
        final tilt = type == BpmKeyCapType.triggerRT ? -0.42 : 0.42;
        return Transform.rotate(
          angle: tilt,
          child: Container(
            width: s * 1.7,
            height: s * 0.78,
            decoration: BoxDecoration(
              border: Border.all(color: _outline, width: 1.2),
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(7),
                bottom: Radius.circular(3),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _face ?? '',
              style: TextStyle(
                fontSize: s * 0.46,
                height: 1.35,
                fontWeight: FontWeight.w500,
                color: type == BpmKeyCapType.triggerRT
                    ? const Color(0xFFF27D98)
                    : _outline,
              ),
            ),
          ),
        );
      case BpmKeyCapType.gamepadLB:
      case BpmKeyCapType.gamepadRB:
        // 肩键：扁长圆角横键（与扳机同族但不斜置）
        return Container(
          width: s * 1.55,
          height: s * 0.74,
          decoration: BoxDecoration(
            border: Border.all(color: _outline, width: 1.2),
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(7),
              bottom: Radius.circular(3),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            _face ?? '',
            style: TextStyle(
              fontSize: s * 0.44,
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: _outline,
            ),
          ),
        );
      case BpmKeyCapType.keycap:
        return Container(
          padding: EdgeInsets.symmetric(
              horizontal: s * 0.34, vertical: s * 0.12),
          constraints: BoxConstraints(minWidth: s, minHeight: s * 0.92),
          decoration: BoxDecoration(
            border: Border.all(color: _outline, width: 1.1),
            borderRadius:
                BorderRadius.circular(square ? 3 : s * 0.28),
          ),
          alignment: Alignment.center,
          child: Text(
            label ?? '',
            style: TextStyle(
              fontSize: s * 0.62,
              fontWeight: FontWeight.w500,
              color: _outline,
              height: 1.2,
            ),
          ),
        );
      default: // ABXY
        return Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _stroke, width: 1.2),
            color: _stroke.withOpacity(0.14),
          ),
          alignment: Alignment.center,
          child: Text(
            _face ?? '',
            style: TextStyle(
              fontSize: s * 0.55,
              fontWeight: FontWeight.w500,
              color: _stroke.withOpacity(0.95),
              height: 1.1,
            ),
          ),
        );
    }
  }

  /// 鼠标轮廓：竖椭圆 + 中线；按 type 高亮对应键区。
  Widget _mouse(double s) {
    final w = s * 0.72;
    final h = s * 1.08;
    final hl = const Color(0xFFF27D98);
    final leftActive = type == BpmKeyCapType.mouseLeft ||
        type == BpmKeyCapType.mouseLeftDouble;
    final rightActive = type == BpmKeyCapType.mouseRight;
    final midActive = type == BpmKeyCapType.mouseMiddle;
    return SizedBox(
      width: type == BpmKeyCapType.mouseLeftDouble ? w + 13 : w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              border: Border.all(color: _outline, width: 1.2),
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(8),
                bottom: Radius.circular(4),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(7),
                bottom: Radius.circular(3),
              ),
              child: Column(
                children: [
                  Expanded(
                    flex: 42,
                    child: Row(
                      children: [
                        Expanded(
                          child: ColoredBox(
                            color: leftActive
                                ? hl.withOpacity(0.55)
                                : Colors.transparent,
                          ),
                        ),
                        if (type == BpmKeyCapType.mouseMiddle)
                          ColoredBox(
                            color: hl.withOpacity(0.55),
                            child: SizedBox(width: w * 0.26, height: 40),
                          )
                        else
                          const SizedBox.shrink(),
                        Expanded(
                          child: ColoredBox(
                            color: rightActive
                                ? hl.withOpacity(0.55)
                                : Colors.transparent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 58,
                    child: ColoredBox(color: Colors.transparent),
                  ),
                ],
              ),
            ),
          ),
          // 中线（左/右分界）
          Positioned(
            left: w / 2 - 0.6,
            top: 0,
            child: Container(
              width: 1.2,
              height: h * 0.42,
              color: midActive ? hl : _outline,
            ),
          ),
          // 横分界
          Positioned(
            left: 0,
            top: h * 0.42 - 0.6,
            child: Container(
              width: w,
              height: 1,
              color: _outline.withOpacity(0.6),
            ),
          ),
          if (type == BpmKeyCapType.mouseLeftDouble)
            Positioned(
              right: -1,
              top: -2,
              child: Text('×2',
                  style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w500,
                      color: hl)),
            ),
        ],
      ),
    );
  }
}

/// 游玩状态角标（封面右上角，主页 shelf 与库页海报共用）。
class BpmStatusBadge extends StatelessWidget {
  final PlayStatus status;
  final double size;

  const BpmStatusBadge(this.status, {super.key, this.size = 22});

  static const _map = <PlayStatus, (Color, IconData, String)>{
    PlayStatus.notStarted: (Color(0xFF888780), Icons.radio_button_unchecked,
        '未开始'),
    PlayStatus.inProgress: (Color(0xFF6F95D6), Icons.play_arrow_rounded,
        '进行中'),
    PlayStatus.dropped: (Color(0xFFBA7517), Icons.pause_circle_outline,
        '搁置'),
    PlayStatus.completed: (Color(0xFF639922), Icons.check_rounded, '已通关'),
  };

  @override
  Widget build(BuildContext context) {
    final (color, icon, tip) = _map[status]!;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xE617111D),
          border: Border.all(color: color, width: 1.2),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: size * 0.58, color: color),
      ),
    );
  }
}
