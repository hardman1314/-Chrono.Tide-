import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'animated_overlay.dart';
import 'interactive_wrapper.dart';

/// v3.0 P6 优化：主题命名弹窗
///
/// 使用 `Overlay.of(context, rootOverlay: true).insert` 注入，
/// 与 ThemeEditorDialog / SettingsModal 完全相同的层级方式，
/// 确保**永远在最上层**，不会被困在设置窗口/编辑器窗口之下。
///
/// 用法：
/// ```dart
/// final name = await NameDialog.show(context, initialValue: '我的主题');
/// if (name != null) { /* 用户确认 */ }
/// ```
class NameDialog {
  NameDialog._();

  /// 显示命名弹窗，返回用户输入的名称（null 表示取消）
  static Future<String?> show(
    BuildContext context, {
    String title = '命名主题',
    String initialValue = '我的主题',
    String confirmLabel = '确定',
    String hint = '请输入主题名称',
  }) {
    final completer = Completer<String?>();
    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<AnimatedOverlayState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => AnimatedOverlay(
        key: key,
        onDismissed: () {
          if (entry.mounted) entry.remove();
          if (!completer.isCompleted) completer.complete(null);
        },
        barrierColor: Colors.black54,
        dismissOnBarrierTap: false,
        enableScale: true,
        alignment: Alignment.center,
        child: _NameDialogContent(
          title: title,
          initialValue: initialValue,
          confirmLabel: confirmLabel,
          hint: hint,
          onConfirm: (name) {
            if (!completer.isCompleted) completer.complete(name);
            key.currentState?.dismiss();
          },
          onCancel: () {
            if (!completer.isCompleted) completer.complete(null);
            key.currentState?.dismiss();
          },
        ),
      ),
    );
    overlay.insert(entry);
    return completer.future;
  }
}

class _NameDialogContent extends StatefulWidget {
  final String title;
  final String initialValue;
  final String confirmLabel;
  final String hint;
  final ValueChanged<String> onConfirm;
  final VoidCallback onCancel;

  const _NameDialogContent({
    required this.title,
    required this.initialValue,
    required this.confirmLabel,
    required this.hint,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_NameDialogContent> createState() => _NameDialogContentState();
}

class _NameDialogContentState extends State<_NameDialogContent> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialValue.length,
    );
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    widget.onConfirm(name);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  Icon(Icons.edit_rounded, size: 18,
                      color: AppColors.primaryText),
                  const SizedBox(width: 8),
                  Text(widget.title,
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryText)),
                ],
              ),
              const SizedBox(height: 16),
              // 输入框
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: AppColors.placeholderText),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:
                        BorderSide(color: AppColors.border, width: 1.0),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                        color: AppColors.selectedAccent, width: 1.4),
                  ),
                ),
                onSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 16),
              // 按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  InteractiveWrapper(
                    onTap: widget.onCancel,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.buttonBackground,
                        border: Border.all(
                            color: AppColors.borderLight, width: 0.8),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text('取消',
                          style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.secondaryText)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InteractiveWrapper(
                    onTap: _confirm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.selectedAccent,
                        border: Border.all(
                            color: AppColors.border, width: 0.8),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(widget.confirmLabel,
                          style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primaryText)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
