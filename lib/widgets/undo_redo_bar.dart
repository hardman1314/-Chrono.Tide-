import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_manager.dart';
import '../theme/theme_element_registry.dart';
import 'interactive_wrapper.dart';

/// v3.0 P3：撤销/重做控制器（D3 决策：50 步栈）
class UndoRedoController extends ChangeNotifier {
  static const int _maxStackDepth = 50;

  final List<CTThemeData> _undoStack = [];
  final List<CTThemeData> _redoStack = [];

  bool get canUndo => _undoStack.length > 1;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 初始化：压入初始状态
  void initialize(CTThemeData initial) {
    _undoStack.clear();
    _redoStack.clear();
    _undoStack.add(initial);
    notifyListeners();
  }

  /// 压入新状态（在完整动作结束时调用）
  ///
  /// v3.0.1 修复：原 `_undoStack.last == state` 比较是引用比较
  /// （CTThemeData 未重写 ==），永远返回 false，导致去重逻辑失效。
  /// 本版本改用 JSON 序列化字符串做内容相等判断。性能可接受
  /// （undo 栈深度仅 50，仅在拖动结束的离散时刻调用）。
  void push(CTThemeData state) {
    if (_undoStack.isNotEmpty) {
      final last = _undoStack.last;
      // 同一引用或内容相同则跳过
      if (identical(last, state)) return;
      try {
        final lastJson = const JsonEncoder().convert(last.toJson());
        final stateJson = const JsonEncoder().convert(state.toJson());
        if (lastJson == stateJson) return;
      } catch (_) {
        // 序列化失败时降级为引用比较，仍允许 push（避免功能丢失）
      }
    }
    _undoStack.add(state);
    if (_undoStack.length > _maxStackDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    notifyListeners();
  }

  /// 撤销，返回上一状态（若无可撤销则返回当前）
  CTThemeData? undo() {
    if (!canUndo) return null;
    final current = _undoStack.removeLast();
    _redoStack.add(current);
    notifyListeners();
    return _undoStack.last;
  }

  /// 重做，返回下一状态
  CTThemeData? redo() {
    if (!canRedo) return null;
    final state = _redoStack.removeLast();
    _undoStack.add(state);
    notifyListeners();
    return state;
  }

  CTThemeData get current => _undoStack.last;
}

/// v3.0 P3：撤销/重做按钮栏
class UndoRedoBar extends StatelessWidget {
  final UndoRedoController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  const UndoRedoBar({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          children: [
            _buildButton(
              icon: Icons.undo_rounded,
              label: '撤销',
              enabled: controller.canUndo,
              onTap: onUndo,
            ),
            const SizedBox(width: 8),
            _buildButton(
              icon: Icons.redo_rounded,
              label: '重做',
              enabled: controller.canRedo,
              onTap: onRedo,
            ),
          ],
        );
      },
    );
  }

  Widget _buildButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = enabled ? AppColors.primaryText : AppColors.placeholderText;
    return InteractiveWrapper(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.buttonBackground
              : AppColors.placeholderBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.borderLight, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v3.0 P3：键盘快捷键控制器（Ctrl+Z / Ctrl+Y / Esc）
class UndoRedoKeyboardHandler extends StatelessWidget {
  final UndoRedoController controller;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback? onEscape;
  final Widget child;

  const UndoRedoKeyboardHandler({
    super.key,
    required this.controller,
    required this.onUndo,
    required this.onRedo,
    this.onEscape,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          final isCtrl = HardwareKeyboard.instance.isControlPressed;
          if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              onRedo();
            } else {
              onUndo();
            }
          } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyY) {
            onRedo();
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            onEscape?.call();
          }
        }
      },
      child: child,
    );
  }
}

/// v3.0 P3：影响范围提示组件（A2 决策）
///
/// v3.0.1 修复3：扩展为显示「直接作用位置」+「连锁影响」两部分。
/// - 直接作用位置：来自 [descriptor.impactLocations]
/// - 连锁影响：来自 [ThemeElementRegistry.getChainedImpacts]，
///   列出与该元素共享颜色令牌的其他元素，并展开各元素的受影响 UI 位置。
///
/// v3.0.2 优化：连锁影响展开显示具体 UI 位置（最多 3 处 + 折叠计数），
/// 让用户明确知道修改此元素会连带影响哪些区域。整体内容限高可滚动，
/// 避免连锁项过多时挤压颜色通道面板。
class ImpactHint extends StatelessWidget {
  final ThemeElementDescriptor descriptor;

  const ImpactHint({super.key, required this.descriptor});

  @override
  Widget build(BuildContext context) {
    if (descriptor.impactLocations.isEmpty) {
      return const SizedBox.shrink();
    }

    // v3.0.1 修复3：计算连锁影响（与该元素共享令牌的其他元素）
    final chained = ThemeElementRegistry.getChainedImpacts(descriptor.id);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.infoBg.withOpacity(0.4),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.infoBlue.withOpacity(0.4), width: 0.8),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 12, color: AppColors.infoBlue),
                const SizedBox(width: 4),
                Text(
                  '此修改将会影响',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.infoBlue,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 直接作用位置
            ...descriptor.impactLocations.map((loc) => Padding(
                  padding: const EdgeInsets.only(left: 16, top: 1),
                  child: Text(
                    '· $loc',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.secondaryText,
                    ),
                  ),
                )),
            // v3.0.2 优化：连锁影响展开显示具体 UI 位置
            if (chained.isNotEmpty) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2),
                child: Row(
                  children: [
                    Icon(Icons.link,
                        size: 10, color: AppColors.selectedAccent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '连锁影响（共享令牌，${chained.length} 个元素联动）',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.selectedAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...chained.map((c) {
                final locs = c.impactLocations;
                final shown = locs.take(3).toList();
                final remaining = locs.length - shown.length;
                return Padding(
                  padding: const EdgeInsets.only(left: 28, top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '· ${c.displayName}（共享: ${c.sharedTokens.join(", ")}）',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondaryText,
                        ),
                      ),
                      ...shown.map((loc) => Padding(
                            padding: const EdgeInsets.only(left: 12, top: 1),
                            child: Text(
                              '↳ $loc',
                              style: TextStyle(
                                fontSize: 9,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          )),
                      if (remaining > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 1),
                          child: Text(
                            '↳ +$remaining 处其他位置',
                            style: TextStyle(
                              fontSize: 9,
                              fontStyle: FontStyle.italic,
                              color: AppColors.placeholderText,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
