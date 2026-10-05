/// 手柄映射的启动确认弹窗 + 每游戏配置弹窗（2026-09-27 产品流程 v2）
///
/// 用户拍板（替代旧的「首次启动询问」）：
/// - **每次启动都先弹确认**：是否使用映射 + 选预设 → 确认后才启动游戏；
/// - **主页手柄按钮**：每游戏独立开关与配置（原生手柄游戏/不想用映射的
///   用户可关闭）；本文件同时提供入口弹窗。
///
/// 🔴 手柄可操作性与旧询问框同款：弹窗挂载期间注册静态回调，由
/// `big_picture_shell.dart` 的手柄语义处理器桥接（A=确认 / B=不用）。
library;

import 'package:flutter/material.dart';

import '../../services/gamepad/gamepad_adaptation_coordinator.dart';
import '../../services/gamepad/gamepad_profile.dart';
import '../../theme/app_styles.dart';
import 'gamepad_mapping_editor_dialog.dart';

/// 可选预设项（内置 + 自定义统一视图）
class GamepadPresetOption {
  const GamepadPresetOption(this.id, this.label);
  final String id;
  final String label;
}

/// 内置预设选项（自定义预设由调用方追加）
const List<GamepadPresetOption> kBuiltinPresetOptions = [
  GamepadPresetOption(GamepadPresets.steamosVnId, 'SteamOS 通用方案（推荐）'),
  GamepadPresetOption(GamepadPresets.genericVnId, '经典方案（键盘直映）'),
];

String? presetLabelOf(String? id) {
  for (final o in kBuiltinPresetOptions) {
    if (o.id == id) return o.label;
  }
  return id; // 自定义预设 id（存储层负责给出可读名）
}

/// 手柄桥接（挂载中的弹窗注册；shell 的手柄语义处理器消费）：
/// confirm = A 键（确认/保存），dismiss = B 键（跳过/不保存）。
/// 同一时刻只有一个映射弹窗在前台，注册/注销即互斥。
class GamepadDialogBridge {
  static VoidCallback? confirm;
  static VoidCallback? dismiss;

  static void register({required VoidCallback confirm, required VoidCallback dismiss}) {
    GamepadDialogBridge.confirm = confirm;
    GamepadDialogBridge.dismiss = dismiss;
  }

  static void unregister() {
    confirm = null;
    dismiss = null;
  }
}

/// 启动前确认弹窗：使用映射（选预设）并启动 / 本次不使用映射
///
/// 返回 null = 用户取消（关闭弹窗，不启动游戏）；返回记录 = 用户决定。
class GamepadLaunchConfirmDialog extends StatefulWidget {
  const GamepadLaunchConfirmDialog({
    super.key,
    required this.gameId,
    required this.gameTitle,
    required this.initialEnabled,
    required this.initialPresetId,
    this.presetOptions = kBuiltinPresetOptions,
  });

  final String gameId;
  final String gameTitle;
  final bool initialEnabled;
  final String initialPresetId;
  final List<GamepadPresetOption> presetOptions;


  static Future<({bool useMapping, String presetId})?> show(
    BuildContext context, {
    required String gameId,
    required String gameTitle,
    required bool initialEnabled,
    required String initialPresetId,
    List<GamepadPresetOption>? presetOptions,
  }) {
    return showDialog<({bool useMapping, String presetId})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GamepadLaunchConfirmDialog(
        gameId: gameId,
        gameTitle: gameTitle,
        initialEnabled: initialEnabled,
        initialPresetId: initialPresetId,
        presetOptions: presetOptions ?? kBuiltinPresetOptions,
      ),
    );
  }

  @override
  State<GamepadLaunchConfirmDialog> createState() =>
      _GamepadLaunchConfirmDialogState();
}

class _GamepadLaunchConfirmDialogState
    extends State<GamepadLaunchConfirmDialog> {
  late bool _useMapping = widget.initialEnabled;
  late String _presetId = widget.initialPresetId;

  @override
  void initState() {
    super.initState();
    GamepadDialogBridge.register(confirm: _confirm, dismiss: _skip);
  }

  @override
  void dispose() {
    GamepadDialogBridge.unregister();
    super.dispose();
  }

  /// 确认：保存选择（下次启动记住）并启动
  void _confirm() {
    final navigator = Navigator.of(context);
    GamepadAdaptationCoordinator.instance.saveLaunchChoice(
      gameId: widget.gameId,
      gameTitle: widget.gameTitle,
      enabled: true,
      presetId: _presetId,
    );
    navigator.pop((useMapping: true, presetId: _presetId));
  }

  /// 本次不用映射（**不改动**每游戏开关 —— 下次启动仍按开关默认）
  void _skip() {
    Navigator.of(context).pop((useMapping: false, presetId: _presetId));
  }

  @override
  Widget build(BuildContext context) {
    final validIds = widget.presetOptions.map((o) => o.id).toSet();
    final dropdownValue = validIds.contains(_presetId) ? _presetId : null;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: Text('手柄映射 — ${widget.gameTitle}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本次启动是否使用手柄映射（手柄 → 键鼠模拟）？',
                style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            if (_useMapping)
              Row(
                children: [
                  const Text('映射预设', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  DropdownButton<String>(
                    value: dropdownValue,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final o in widget.presetOptions)
                        DropdownMenuItem(
                            value: o.id, child: Text(o.label, style: const TextStyle(fontSize: 13))),
                    ],
                    onChanged: (v) => setState(() => _presetId = v ?? _presetId),
                  ),
                ],
              ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('使用手柄映射', style: TextStyle(fontSize: 14)),
              subtitle: const Text('开启并确认后记住此选择 —— 该游戏下次启动直接使用，不再询问',
                  style: TextStyle(fontSize: 12)),
              value: _useMapping,
              onChanged: (v) => setState(() => _useMapping = v),
            ),
            const SizedBox(height: 4),
            Text('可用手柄直接选择：A = 确认启动 · B = 本次不使用',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _skip, child: const Text('本次不使用映射')),
        FilledButton(onPressed: _confirm, child: const Text('使用映射并启动')),
      ],
    );
  }
}

/// 每游戏手柄配置弹窗（主页手柄按钮入口）：
/// 独立开关 + 预设选择 + 自定义映射编辑
class GamepadGameConfigDialog extends StatefulWidget {
  const GamepadGameConfigDialog({
    super.key,
    required this.gameId,
    required this.gameTitle,
    required this.initialEnabled,
    required this.initialPresetId,
    this.presetOptions = kBuiltinPresetOptions,
  });

  final String gameId;
  final String gameTitle;
  final bool initialEnabled;
  final String initialPresetId;
  final List<GamepadPresetOption> presetOptions;


  static Future<bool?> show(
    BuildContext context, {
    required String gameId,
    required String gameTitle,
    required bool initialEnabled,
    required String initialPresetId,
    List<GamepadPresetOption>? presetOptions,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GamepadGameConfigDialog(
        gameId: gameId,
        gameTitle: gameTitle,
        initialEnabled: initialEnabled,
        initialPresetId: initialPresetId,
        presetOptions: presetOptions ?? kBuiltinPresetOptions,
      ),
    );
  }

  /// 便捷入口：按**游戏标题**解析每游戏映射偏好后直接弹配置框。
  ///
  /// v3.14：主页右侧按钮区移除后，二级详情的「手柄」按钮复用这条链路
  /// （原逻辑在 `big_picture_home.dart::_openGamepadConfig`，已收敛到这里）。
  static Future<void> showForTitle(
    BuildContext context,
    String gameTitle,
  ) async {
    final pref =
        await GamepadAdaptationCoordinator.instance.resolveLaunchPref(gameTitle);
    if (pref == null || !context.mounted) return;
    final options =
        await GamepadAdaptationCoordinator.instance.loadPresetOptions();
    if (!context.mounted) return;
    await GamepadGameConfigDialog.show(
      context,
      gameId: pref.gameId,
      gameTitle: pref.gameTitle,
      initialEnabled: pref.enabled,
      initialPresetId: pref.presetId,
      presetOptions: [
        for (final (id, label) in options) GamepadPresetOption(id, label),
      ],
    );
  }

  @override
  State<GamepadGameConfigDialog> createState() =>
      _GamepadGameConfigDialogState();
}

class _GamepadGameConfigDialogState extends State<GamepadGameConfigDialog> {
  late bool _enabled = widget.initialEnabled;
  late String _presetId = widget.initialPresetId;

  @override
  void initState() {
    super.initState();
    GamepadDialogBridge.register(confirm: _save, dismiss: _close);
  }

  @override
  void dispose() {
    GamepadDialogBridge.unregister();
    super.dispose();
  }

  Future<void> _editMappings() async {
    final mappings = GamepadPresets.byId(_presetId) ?? GamepadPresets.steamosVn;
    // 编辑器叠在本弹窗之上（不先 pop，context 保持有效）
    final custom = await GamepadMappingEditorDialog.show(
      context,
      initial: GamepadProfile(preset: _presetId, mappings: mappings),
      title: '自定义手柄映射 — ${widget.gameTitle}',
    );
    if (custom == null || !mounted) return;
    await GamepadAdaptationCoordinator.instance.saveLaunchChoice(
      gameId: widget.gameId,
      gameTitle: widget.gameTitle,
      enabled: _enabled,
      presetId: _presetId,
      mappings: custom.mappings,
    );
  }

  void _save() {
    final navigator = Navigator.of(context);
    GamepadAdaptationCoordinator.instance.saveLaunchChoice(
      gameId: widget.gameId,
      gameTitle: widget.gameTitle,
      enabled: _enabled,
      presetId: _presetId,
    );
    navigator.pop(true);
  }

  void _close() => Navigator.of(context).pop(false);

  @override
  Widget build(BuildContext context) {
    final validIds = widget.presetOptions.map((o) => o.id).toSet();
    final dropdownValue = validIds.contains(_presetId) ? _presetId : null;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: Text('手柄配置 — ${widget.gameTitle}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('为此游戏启用手柄映射', style: TextStyle(fontSize: 14)),
              subtitle: const Text('关闭后启动该游戏不做任何映射（原生手柄游戏用）',
                  style: TextStyle(fontSize: 12)),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            if (_enabled)
              Row(
                children: [
                  const Text('映射预设', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  DropdownButton<String>(
                    value: dropdownValue,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final o in widget.presetOptions)
                        DropdownMenuItem(
                            value: o.id, child: Text(o.label, style: const TextStyle(fontSize: 13))),
                    ],
                    onChanged: (v) => setState(() => _presetId = v ?? _presetId),
                  ),
                ],
              ),
            if (_enabled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('自定义映射…'),
                  onPressed: _editMappings,
                ),
              ),
            Text('可用手柄直接选择：A = 保存 · B = 不保存',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: const Text('不保存')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
