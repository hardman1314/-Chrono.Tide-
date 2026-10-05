/// 设置 → 大屏模式 → 「手柄映射」分组（2026-09-27 v2）
///
/// - 全局默认预设切换（内置 + 自定义预设）—— 无专属配置的游戏用它；
/// - 每游戏配置列表：独立开关（enabled）+ 编辑（映射编辑器）+ 删除；
/// - 🔴 自定义预设管理（用户拍板「类似游戏手柄预设系统」）：
///   新建（编辑器 + 命名）/ 重命名 / 删除，保存于 gamepad_profiles.json
///   的 `custom_presets`；BPM 启动确认弹窗与主页手柄按钮同源可选。
///
/// 数据全部走 `GamepadProfileStore`（独立 JSON，不触碰 game.json）。
library;

import 'package:flutter/material.dart';

import '../../services/gamepad/gamepad_profile.dart';
import '../../services/gamepad/gamepad_profile_store.dart';
import '../../theme/app_styles.dart';
import '../settings/settings_section.dart';
import 'gamepad_mapping_editor_dialog.dart';

class GamepadSettingsSection extends StatefulWidget {
  const GamepadSettingsSection({super.key});

  @override
  State<GamepadSettingsSection> createState() =>
      _GamepadSettingsSectionState();
}

class _GamepadSettingsSectionState extends State<GamepadSettingsSection> {
  GamepadProfileFile? _file;
  String? _defaultPreset;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final file = await GamepadProfileStore.load();
    if (!mounted) return;
    setState(() {
      _file = file;
      _defaultPreset =
          file.defaults.preset ?? GamepadPresets.steamosVnId;
    });
  }

  List<DropdownMenuItem<String>> _presetItems(GamepadProfileFile file) {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
          value: GamepadPresets.steamosVnId,
          child: Text('SteamOS 通用方案（推荐）', style: TextStyle(fontSize: 13))),
      const DropdownMenuItem(
          value: GamepadPresets.genericVnId,
          child: Text('经典方案（键盘直映）', style: TextStyle(fontSize: 13))),
    ];
    for (final p in file.customPresets.values) {
      items.add(DropdownMenuItem(
          value: p.id,
          child: Text('自定义 · ${p.name}', style: const TextStyle(fontSize: 13))));
    }
    return items;
  }

  Future<void> _saveDefaultPreset(String presetId) async {
    final file = _file ?? await GamepadProfileStore.load();
    final updated =
        file.copyWith(defaults: file.defaults.copyWith(preset: presetId));
    await GamepadProfileStore.save(updated);
    await _reload();
  }

  Future<void> _saveProfile(String gameId, GamepadProfile profile) async {
    final file = _file ?? await GamepadProfileStore.load();
    file.profiles[gameId] = profile;
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<void> _deleteProfile(String gameId) async {
    final file = _file ?? await GamepadProfileStore.load();
    file.profiles.remove(gameId);
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<void> _edit(String gameId, GamepadProfile profile, String title) async {
    final result = await GamepadMappingEditorDialog.show(
      context,
      initial: profile,
      title: title,
    );
    if (result == null) return;
    await _saveProfile(gameId, result);
  }

  // ── 自定义预设管理 ──

  Future<void> _createCustomPreset() async {
    final result = await GamepadMappingEditorDialog.show(
      context,
      initial: const GamepadProfile(
          preset: GamepadPresets.steamosVnId,
          mappings: GamepadPresets.steamosVn),
      title: '新建预设 — 调配各手柄键的映射',
    );
    if (result == null || !mounted) return;
    final name = await _askName('保存为预设');
    if (name == null || name.trim().isEmpty) return;
    final file = _file ?? await GamepadProfileStore.load();
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    file.customPresets[id] = GamepadCustomPreset(
      id: id,
      name: name.trim(),
      mappings: result.mappings,
    );
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<void> _editCustomPreset(GamepadCustomPreset preset) async {
    final result = await GamepadMappingEditorDialog.show(
      context,
      initial: GamepadProfile(preset: preset.id, mappings: preset.mappings),
      title: '编辑预设 — ${preset.name}',
    );
    if (result == null) return;
    final file = _file ?? await GamepadProfileStore.load();
    file.customPresets[preset.id] = GamepadCustomPreset(
        id: preset.id, name: preset.name, mappings: result.mappings);
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<void> _renameCustomPreset(GamepadCustomPreset preset) async {
    final name = await _askName('重命名预设', initial: preset.name);
    if (name == null || name.trim().isEmpty) return;
    final file = _file ?? await GamepadProfileStore.load();
    file.customPresets[preset.id] = GamepadCustomPreset(
        id: preset.id, name: name.trim(), mappings: preset.mappings);
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<void> _deleteCustomPreset(GamepadCustomPreset preset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('删除预设'),
        content: Text('确定删除预设「${preset.name}」吗？\n'
            '使用该预设的游戏将回落到默认预设。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final file = _file ?? await GamepadProfileStore.load();
    file.customPresets.remove(preset.id);
    await GamepadProfileStore.save(file);
    await _reload();
  }

  Future<String?> _askName(String title, {String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: '预设名称', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final entries = file?.profiles.entries.toList() ??
        const <MapEntry<String, GamepadProfile>>[];
    final presetItems =
        file == null ? const <DropdownMenuItem<String>>[] : _presetItems(file);
    final validIds = file?.customPresets.keys
            .toSet()
            .union(const {
              GamepadPresets.steamosVnId,
              GamepadPresets.genericVnId,
            }) ??
        const <String>{};
    return SettingsSection(
      title: '手柄映射',
      description: '为原生无手柄支持的游戏提供「手柄 → 键鼠」映射（摇杆移动光标、'
          'A/RT 点击、LT 按住快进……）。BPM 主页的「手柄」按钮可按游戏快速开关；'
          '启动游戏时也会弹出映射确认。',
      children: [
        // ── 全局默认预设 ──
        Row(
          children: [
            const Text('默认预设', style: TextStyle(fontSize: 14)),
            const Spacer(),
            DropdownButton<String>(
              // 🔴 防崩：value 必须在 items 里（异常数据回退默认项）
              value: validIds.contains(_defaultPreset)
                  ? _defaultPreset
                  : GamepadPresets.steamosVnId,
              items: presetItems,
              onChanged: (v) {
                if (v != null) _saveDefaultPreset(v);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── 自定义预设管理 ──
        Row(
          children: [
            Text('自定义预设',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建预设'),
              onPressed: _createCustomPreset,
            ),
          ],
        ),
        if (file != null && file.customPresets.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('尚无自定义预设。新建后可在启动确认弹窗与主页「手柄」按钮中选择。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          )
        else if (file != null)
          for (final p in file.customPresets.values)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sports_esports_outlined, size: 20),
              title: Text('自定义 · ${p.name}',
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text('${p.mappings.length} 条映射',
                  style: const TextStyle(fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑映射',
                    icon: const Icon(Icons.tune, size: 20),
                    onPressed: () => _editCustomPreset(p),
                  ),
                  IconButton(
                    tooltip: '重命名',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _renameCustomPreset(p),
                  ),
                  IconButton(
                    tooltip: '删除预设',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteCustomPreset(p),
                  ),
                ],
              ),
            ),
        const Divider(height: 24),
        // ── 每游戏配置列表 ──
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
                '尚无单独配置的游戏。可在 BPM 主页选中游戏后点「手柄」按钮快速配置。',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
          )
        else
          for (final e in entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.value.gameTitle ?? e.key,
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                '${e.value.enabled ? "已启用" : "已禁用"} · '
                '${_presetLabelOf(e.value.preset)} · '
                '${e.value.mappings.length} 条映射',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: e.value.enabled,
                    onChanged: (v) =>
                        _saveProfile(e.key, e.value.copyWith(enabled: v)),
                  ),
                  IconButton(
                    tooltip: '编辑映射',
                    icon: const Icon(Icons.tune, size: 20),
                    onPressed: () => _edit(e.key, e.value,
                        '手柄映射 — ${e.value.gameTitle ?? e.key}'),
                  ),
                  IconButton(
                    tooltip: '删除配置（恢复默认预设）',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteProfile(e.key),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  String _presetLabelOf(String? preset) {
    final file = _file;
    if (file != null && preset != null) {
      final custom = file.customPresets[preset];
      if (custom != null) return '自定义 · ${custom.name}';
    }
    return presetLabel(preset);
  }
}

/// 内置预设显示名
String presetLabel(String? id) => switch (id) {
      GamepadPresets.steamosVnId => 'SteamOS 通用方案',
      GamepadPresets.genericVnId => '经典方案（键盘直映）',
      _ => id ?? '自定义',
    };
