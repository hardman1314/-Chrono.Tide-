/// 手柄映射编辑对话框 + 首次启动询问框（Phase 3）
///
/// - [GamepadMappingEditorDialog]：以**手柄键为行**（18 个源固定），每行配置
///   键鼠动作；键盘动作用「录制键盘键」捕获（GetAsyncKeyState 轮询）；
///   手柄侧不需要录制 —— 行本身就是手柄键。
/// - [GamepadFirstLaunchPromptDialog]：BPM 首次启动某游戏时的询问框，
///   三选：开启（建议预设）/ 自定义映射（打开编辑器）/ 不开启；可「稍后再说」。
///
/// 保存一律交回调方持久化（编辑器不直接写 GamepadProfileStore，
/// 便于协调器在「首次询问」路径里用 pid 当场启动会话）。
library;

import 'package:flutter/material.dart';

import '../../services/gamepad/gamepad_key_recorder.dart';
import '../../services/gamepad/gamepad_profile.dart';
import '../../theme/app_styles.dart';

/// 手柄源中文名（编辑器行标签用）
const Map<GamepadSource, String> kGamepadSourceLabels = {
  GamepadSource.a: 'A 键（下键）',
  GamepadSource.b: 'B 键（右键）',
  GamepadSource.x: 'X 键（左键）',
  GamepadSource.y: 'Y 键（上键）',
  GamepadSource.lb: 'LB 肩键（左）',
  GamepadSource.rb: 'RB 肩键（右）',
  GamepadSource.lt: 'LT 扳机（左）',
  GamepadSource.rt: 'RT 扳机（右）',
  GamepadSource.ls: '左摇杆按下（LS）',
  GamepadSource.rs: '右摇杆按下（RS）',
  GamepadSource.start: 'Start / Menu',
  GamepadSource.back: 'Back / View',
  GamepadSource.dpadUp: '十字键 上',
  GamepadSource.dpadDown: '十字键 下',
  GamepadSource.dpadLeft: '十字键 左',
  GamepadSource.dpadRight: '十字键 右',
  GamepadSource.stickLeft: '左摇杆（连续）',
  GamepadSource.stickRight: '右摇杆（连续）',
};

/// 常用 VK → 显示名（编辑器与描述用）
String vkName(int vk) => switch (vk) {
      13 => 'Enter',
      27 => 'Esc',
      32 => 'Space',
      17 => 'Ctrl',
      16 => 'Shift',
      18 => 'Alt',
      8 => 'Backspace',
      9 => 'Tab',
      0x30 => '0',
      0x31 => '1',
      0x32 => '2',
      0x33 => '3',
      0x34 => '4',
      0x35 => '5',
      0x36 => '6',
      0x37 => '7',
      0x38 => '8',
      0x39 => '9',
      >= 0x41 && <= 0x5A => String.fromCharCode(vk),
      >= 0x70 && <= 0x7B => 'F${vk - 0x6F}',
      37 => '←',
      38 => '↑',
      39 => '→',
      40 => '↓',
      _ => 'VK 0x${vk.toRadixString(16).toUpperCase()}',
    };

/// 动作的一句话描述（行内展示用）
String describeAction(GamepadAction? a) {
  if (a == null) return '未映射';
  switch (a.type) {
    case GamepadActionType.key:
      return '键盘 ${vkName(a.vk!)}';
    case GamepadActionType.mouseButton:
      return '鼠标${a.mouseButtonName == 'right' ? '右键' : '左键'}';
    case GamepadActionType.mouseMove:
      return a.direction == null
          ? '光标移动（摇杆，灵敏度 ${a.sensitivity}）'
          : '光标步进-${_dirName(a.direction!)}（${a.stepPixels}px）';
    case GamepadActionType.mouseWheel:
      return '滚轮滚动（右摇杆）';
  }
}

String _dirName(String d) => switch (d) {
      'up' => '上',
      'down' => '下',
      'left' => '左',
      _ => '右',
    };

/// 手柄映射编辑对话框
class GamepadMappingEditorDialog extends StatefulWidget {
  const GamepadMappingEditorDialog({
    super.key,
    required this.initial,
    required this.title,
    this.showEnabledSwitch = true,
  });

  final GamepadProfile initial;
  final String title;
  final bool showEnabledSwitch;

  static Future<GamepadProfile?> show(
    BuildContext context, {
    required GamepadProfile initial,
    required String title,
    bool showEnabledSwitch = true,
  }) {
    return showDialog<GamepadProfile>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GamepadMappingEditorDialog(
        initial: initial,
        title: title,
        showEnabledSwitch: showEnabledSwitch,
      ),
    );
  }

  @override
  State<GamepadMappingEditorDialog> createState() =>
      _GamepadMappingEditorDialogState();
}

class _GamepadMappingEditorDialogState
    extends State<GamepadMappingEditorDialog> {
  late bool _enabled = widget.initial.enabled;
  late final String? _presetId = widget.initial.preset;
  late final Map<GamepadSource, GamepadMapping> _mappings = {
    for (final m in widget.initial.mappings) m.source: m,
  };
  GamepadButtonRecorder? _padRecorder;
  GamepadKeyboardRecorder? _kbRecorder;
  GamepadSource? _kbRecordingSource;

  @override
  void dispose() {
    _padRecorder?.stop();
    _kbRecorder?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 🔴 720 宽：旧版 560 一行塞不下「源名 + 描述 + 录制 + 动作下拉 + 模式
    // 下拉」，动作描述被挤到只剩 ~30px（真机观感「设置非常混乱」）。
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showEnabledSwitch)
              SwitchListTile(
                dense: true,
                title: const Text('启用手柄映射'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            const SizedBox(height: 4),
            Flexible(
              child: SizedBox(
                width: 720,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final source in GamepadSource.values)
                      _buildRow(source),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.initial.copyWith(
              enabled: _enabled,
              preset: _presetId,
              mappings: _mappings.values.toList(),
              prompted: true,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildRow(GamepadSource source) {
    final action = _mappings[source]?.action;
    final mode = _mappings[source]?.mode ?? GamepadMappingMode.tap;
    final isStickMove = source == GamepadSource.stickLeft;
    final isWheel = source == GamepadSource.stickRight;
    final isDpad = source.index >= GamepadSource.dpadUp.index &&
        source.index <= GamepadSource.dpadRight.index;
    final dir = switch (source) {
      GamepadSource.dpadUp => 'up',
      GamepadSource.dpadDown => 'down',
      GamepadSource.dpadLeft => 'left',
      GamepadSource.dpadRight => 'right',
      _ => null,
    };

    // 布局：源名(固定) | 当前动作描述(弹性) | 录制键 | 动作下拉(固定) | 模式下拉(固定)
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 140,
              child: Text(kGamepadSourceLabels[source]!,
                  style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(describeAction(action),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: action == null
                        ? Colors.grey
                        : Theme.of(context).colorScheme.primary)),
          ),
          // 录制键盘键（键盘动作行）
          IconButton(
            tooltip: '录制键盘键',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard,
                size: 20,
                color: _kbRecordingSource == source ? Colors.red : null),
            onPressed: () {
              _kbRecorder?.stop();
              setState(() => _kbRecordingSource = source);
              final rec = GamepadKeyboardRecorder.start(onCaptured: (vk) {
                if (!mounted) return;
                setState(() {
                  _mappings[source] = GamepadMapping(
                    source: source,
                    action: GamepadAction.key(vk),
                    mode: mode,
                  );
                  _kbRecordingSource = null;
                });
              });
              if (rec == null) {
                setState(() => _kbRecordingSource = null);
              } else {
                _kbRecorder = rec;
              }
            },
          ),
          // 动作下拉
          SizedBox(
            width: 180,
            child: Builder(builder: (context) {
              final items = _actionItemsOf(
                isStickMove: isStickMove,
                isWheel: isWheel,
                isDpad: isDpad,
                dir: dir,
              );
              final selected = _actionOptionOf(source, action);
              // 🔴 防崩：DropdownButton 断言 value 必须在 items 里。数据异常
              // （如普通按钮被配了滚轮动作）时回退显示「未映射」，描述列仍
              // 显示真实动作，用户重选一次即可纠正，而不是整框崩掉。
              final valid = items.any((i) => i.value == selected);
              return DropdownButton<String>(
                isDense: true,
                value: valid ? selected : 'none',
                underline: const SizedBox.shrink(),
                items: items,
                onChanged: (v) => setState(() => _applyOption(source, v)),
              );
            }),
          ),
          // 模式下拉（仅键盘/鼠标键动作）
          if (action != null &&
              (action.type == GamepadActionType.key ||
                  action.type == GamepadActionType.mouseButton))
            SizedBox(
              width: 76,
              child: DropdownButton<GamepadMappingMode>(
                isDense: true,
                value: mode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: GamepadMappingMode.tap, child: Text('单击', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: GamepadMappingMode.hold, child: Text('按住', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: GamepadMappingMode.repeat, child: Text('连发', style: TextStyle(fontSize: 12))),
                ],
                onChanged: (m) => setState(() {
                  final cur = _mappings[source]!;
                  _mappings[source] = GamepadMapping(
                      source: source, action: cur.action, mode: m!);
                }),
              ),
            ),
        ],
      ),
    );
  }

  /// 动作下拉选项（按行类型裁剪）
  List<DropdownMenuItem<String>> _actionItemsOf({
    required bool isStickMove,
    required bool isWheel,
    required bool isDpad,
    required String? dir,
  }) {
    return [
      const DropdownMenuItem(value: 'none', child: Text('未映射', style: TextStyle(fontSize: 12))),
      const DropdownMenuItem(value: 'mouse_left', child: Text('鼠标左键', style: TextStyle(fontSize: 12))),
      const DropdownMenuItem(value: 'mouse_right', child: Text('鼠标右键', style: TextStyle(fontSize: 12))),
      const DropdownMenuItem(value: 'key', child: Text('键盘（录制）', style: TextStyle(fontSize: 12))),
      if (isStickMove)
        const DropdownMenuItem(value: 'stick_move', child: Text('光标移动（摇杆）', style: TextStyle(fontSize: 12))),
      if (isWheel)
        const DropdownMenuItem(value: 'wheel', child: Text('滚轮滚动', style: TextStyle(fontSize: 12))),      if (isDpad)
        DropdownMenuItem(value: 'step', child: Text('光标步进（${_dirName(dir!)}）', style: const TextStyle(fontSize: 12))),
    ];
  }

  String _actionOptionOf(GamepadSource source, GamepadAction? action) {
    if (action == null) return 'none';
    switch (action.type) {
      case GamepadActionType.mouseButton:
        return action.mouseButtonName == 'right' ? 'mouse_right' : 'mouse_left';
      case GamepadActionType.key:
        return 'key';
      case GamepadActionType.mouseMove:
        return action.direction == null ? 'stick_move' : 'step';
      case GamepadActionType.mouseWheel:
        return 'wheel';
    }
  }

  void _applyOption(GamepadSource source, String? option) {
    final keepMode = _mappings[source]?.mode ?? GamepadMappingMode.tap;
    switch (option) {
      case 'none':
        _mappings.remove(source);
      case 'mouse_left':
        _mappings[source] = GamepadMapping(
            source: source,
            action: GamepadAction.mouseButton('left'),
            mode: keepMode);
      case 'mouse_right':
        _mappings[source] = GamepadMapping(
            source: source,
            action: GamepadAction.mouseButton('right'),
            mode: keepMode);
      case 'key':
        _mappings[source] = GamepadMapping(
            source: source,
            action: _mappings[source]?.action.type == GamepadActionType.key
                ? _mappings[source]!.action
                : GamepadAction.key(13),
            mode: keepMode);
        // 选中「键盘」即进入录制
        _kbRecorder?.stop();
        setState(() => _kbRecordingSource = source);
        final rec = GamepadKeyboardRecorder.start(onCaptured: (vk) {
          if (!mounted) return;
          setState(() {
            _mappings[source] = GamepadMapping(
                source: source,
                action: GamepadAction.key(vk),
                mode: keepMode);
            _kbRecordingSource = null;
          });
        });
        if (rec == null) {
          setState(() => _kbRecordingSource = null);
        } else {
          _kbRecorder = rec;
        }
      case 'stick_move':
        _mappings[source] = const GamepadMapping(
            source: GamepadSource.stickLeft,
            action: GamepadAction.mouseMove(sensitivity: 1.0, deadzone: 0.15),
            mode: GamepadMappingMode.tap);
      case 'wheel':
        _mappings[source] = const GamepadMapping(
            source: GamepadSource.stickRight,
            action: GamepadAction.mouseWheel(),
            mode: GamepadMappingMode.tap);
      case 'step':
        final dir = switch (source) {
          GamepadSource.dpadUp => 'up',
          GamepadSource.dpadDown => 'down',
          GamepadSource.dpadLeft => 'left',
          _ => 'right',
        };
        _mappings[source] = GamepadMapping(
            source: source,
            action: GamepadAction.mouseMove(direction: dir, stepPixels: 24),
            mode: GamepadMappingMode.tap);
      default:
        _mappings.remove(source);
    }
  }
}
