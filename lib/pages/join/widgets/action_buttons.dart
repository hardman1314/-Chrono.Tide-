import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/confirm_dialog.dart';

class ActionButtons extends StatelessWidget {
  final JoinController? controller;
  final VoidCallback? onBatchSubmit;
  final VoidCallback? onBatchCancel;

  /// ★ IMP-09（2026-09-12 导入审查）：批量提交是否可用。
  /// 处理队列（元数据抓取）运行期间置 false —— 此时提交会 `clearAll()` 并掐断
  /// 仍在跑的批次循环，导致未处理完的游戏既不入库也无任何提示。
  final bool submitEnabled;

  /// 取消按钮的实现（可选）。v3.10.3 新增：由 JoinPage 注入 `_handleCancel`，
  /// 使桌面「取消」与 BPM 手柄操作条共用同一条路径（含二次确认文案）。
  /// 为 null 时退回本组件内置实现，既有调用点行为不变。
  final Future<void> Function()? onCancel;

  const ActionButtons({
    super.key,
    this.controller,
    this.onBatchSubmit,
    this.onBatchCancel,
    this.submitEnabled = true,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final isBatchMode = controller == null && onBatchSubmit != null;

    return Transform.translate(
      offset: const Offset(-40, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCancelButton(context, isBatchMode),
          const SizedBox(width: 10),
          _buildSubmitButton(context, isBatchMode),
        ],
      ),
    );
  }

  Widget _buildCancelButton(BuildContext context, bool isBatchMode) {
    return HoverButton(
      variant: CtButtonVariant.secondary,
      size: CtButtonSize.md,
      onTap: () async {
        // v3.10.3: 优先走注入实现（JoinPage._handleCancel），保证与 BPM
        // 手柄操作条的取消语义完全一致
        if (onCancel != null) {
          await onCancel!();
          return;
        }
        // UX-06: 取消操作前确认
        final confirmed = await showConfirmDialog(
          context: context,
          title: '确认取消',
          message: isBatchMode
              ? '确定要清空批量列表吗？所有已添加的游戏将被移除。'
              : '确定要取消当前操作吗？已填写的表单内容将被清空。',
          confirmText: '取消操作',
          isDanger: true,
        );
        if (!context.mounted || !confirmed) return;
        if (isBatchMode) {
          onBatchCancel?.call();
        } else {
          controller?.cancelAndReset();
        }
      },
      child: const Text('取消',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }

  Widget _buildSubmitButton(BuildContext context, bool isBatchMode) {
    bool canSubmit = false;

    if (isBatchMode) {
      // ★ IMP-09: 处理队列运行中不可提交（避免掐断批次循环、丢弃未处理游戏）
      canSubmit = submitEnabled;
    } else if (controller != null) {
      canSubmit = controller!.canSubmit;
    }

    // v3.9 按钮体系：primary 语义变体——强调色底+继承 ink（修复 border 灰底
    // 在浅/深主题下文字不可见）；不可提交时禁用灰化（视觉差明确）
    return HoverButton(
      variant: CtButtonVariant.primary,
      size: CtButtonSize.lg,
      onTap: isBatchMode
          ? (submitEnabled ? onBatchSubmit : null)
          : (canSubmit ? () => controller?.submitAddGame() : null),
      child: Text(
          isBatchMode
              ? '批量入库'
              // ★ 2026-10-04 真机反馈：压缩包（含伪装包）主按钮语义变为
              //   「执行解压」——点击弹解压计划窗，而非直接入库。
              : ((controller?.isArchiveType ?? false) ? '执行解压' : '确认入库'),
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4)),
    );
  }
}
