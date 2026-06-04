import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

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
      offset: const Offset(-74, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCancelButton(context, isBatchMode),
          const SizedBox(width: 16),
          _buildSubmitButton(context, isBatchMode),
        ],
      ),
    );
  }

  Widget _buildCancelButton(BuildContext context, bool isBatchMode) {
    return InteractiveWrapper(
      onTap: () {
        if (isBatchMode) {
          onBatchCancel?.call();
        } else {
          controller?.cancelAndReset();
        }
      },
      child: Container(
          padding: const EdgeInsets.fromLTRB(33, 15, 32, 17),
          decoration: BoxDecoration(
              color: const Color(0xFFFDFBF7),
              border: Border.all(color: const Color(0xFF8B7355), width: 2),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF8B7355).withOpacity(0.2),
                    offset: const Offset(2, 3),
                    blurRadius: 0)
              ]),
          alignment: Alignment.center,
          child: Text('取消',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: const Color(0xFF8B7355)))),
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
            padding: const EdgeInsets.fromLTRB(41, 13, 40, 15),
            decoration: BoxDecoration(
                color:
                    canSubmit ? const Color(0xFF8B7355) : AppColors.background,
                border: Border.all(color: const Color(0xFF8B7355), width: 2),
                boxShadow: canSubmit
                    ? [
                        BoxShadow(
                            color: const Color(0xFF8B7355).withOpacity(0.4),
                            offset: const Offset(4, 5),
                            blurRadius: 0)
                      ]
                    : [
                        BoxShadow(
                            color: const Color(0xFF8B7355).withOpacity(0.2),
                            offset: const Offset(4, 5),
                            blurRadius: 0)
                      ]),
            alignment: Alignment.center,
            child: Text(isBatchMode ? '批量入库' : '确认入库',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                    color: canSubmit
                        ? const Color(0xFFFDFBF7)
                        : const Color(0xFF8B7355)))));
  }
}
