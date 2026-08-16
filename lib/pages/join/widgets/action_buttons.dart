import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/confirm_dialog.dart';

class ActionButtons extends StatelessWidget {
  final JoinController? controller;
  final VoidCallback? onBatchSubmit;
  final VoidCallback? onBatchCancel;

  const ActionButtons({
    super.key,
    this.controller,
    this.onBatchSubmit,
    this.onBatchCancel,
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
    return InteractiveWrapper(
      onTap: () async {
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
      child: Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 2),
              boxShadow: [
                BoxShadow(
                    color: AppColors.border.withOpacity(0.2),
                    offset: const Offset(2, 3),
                    blurRadius: 0)
              ]),
          alignment: Alignment.center,
          child: Text('取消',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.border))),
    );
  }

  Widget _buildSubmitButton(BuildContext context, bool isBatchMode) {
    bool canSubmit = false;

    if (isBatchMode) {
      canSubmit = true; // 批量模式下总是可以提交
    } else if (controller != null) {
      canSubmit = controller!.canSubmit;
    }

    return InteractiveWrapper(
        onTap:
            (isBatchMode ? onBatchSubmit : () => controller?.submitAddGame()),
        child: Container(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 10),
            decoration: BoxDecoration(
                color: canSubmit ? AppColors.border : AppColors.background,
                border: Border.all(color: AppColors.border, width: 2),
                boxShadow: canSubmit
                    ? [
                        BoxShadow(
                            color: AppColors.border.withOpacity(0.4),
                            offset: const Offset(3, 4),
                            blurRadius: 0)
                      ]
                    : [
                        BoxShadow(
                            color: AppColors.border.withOpacity(0.2),
                            offset: const Offset(3, 4),
                            blurRadius: 0)
                      ]),
            alignment: Alignment.center,
            child: Text(isBatchMode ? '批量入库' : '确认入库',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color:
                        canSubmit ? AppColors.background : AppColors.border))));
  }
}
