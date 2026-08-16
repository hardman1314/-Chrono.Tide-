import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// BPM 全局键盘快捷键封装
///
/// 通过 [Shortcuts] + [Actions] 实现 BPM 模式下的全局快捷键:
///
/// | 键 | Intent | 行为 |
/// |---|---|---|
/// | F11 | [_ToggleBpmIntent] | 切换 BPM 模式 (进入/退出) |
/// | Escape | [_EscapeIntent] | 详情页→返回; 否则退出 BPM |
/// | Ctrl+F | [_FocusSearchIntent] | 聚焦当前页搜索框 (仅 Library 页生效) |
///
/// 方向键导航由 [FocusTraversalGroup] + [FocusGridPolicy] 自动处理,
/// 不在本组件职责内。Tab / Shift+Tab 由 Flutter 默认 group 切换行为处理。
///
/// 使用方式 (在 [BigPictureShell] 顶层包裹):
/// ```dart
/// BpmShortcuts(
///   onToggleBpm: () => BigPictureManager.instance.toggle(),
///   onEscape: _onEscape,
///   onFocusSearch: _onFocusSearch,
///   child: ...,
/// )
/// ```
class BpmShortcuts extends StatelessWidget {
  /// 子组件
  final Widget child;

  /// F11: 切换 BPM 模式
  final VoidCallback? onToggleBpm;

  /// ESC: 详情页返回 / 退出 BPM
  final VoidCallback? onEscape;

  /// Ctrl+F: 聚焦搜索框
  final VoidCallback? onFocusSearch;

  const BpmShortcuts({
    super.key,
    required this.child,
    this.onToggleBpm,
    this.onEscape,
    this.onFocusSearch,
  });

  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.f11): _ToggleBpmIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
    SingleActivator(LogicalKeyboardKey.keyF, control: true):
        _FocusSearchIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ToggleBpmIntent: CallbackAction<_ToggleBpmIntent>(
            onInvoke: (_) => onToggleBpm?.call(),
          ),
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) => onEscape?.call(),
          ),
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) => onFocusSearch?.call(),
          ),
        },
        child: child,
      ),
    );
  }
}

/// F11: 切换 BPM 模式
class _ToggleBpmIntent extends Intent {
  const _ToggleBpmIntent();
}

/// ESC: 详情页返回 / 退出 BPM
class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

/// Ctrl+F: 聚焦搜索框
class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}
