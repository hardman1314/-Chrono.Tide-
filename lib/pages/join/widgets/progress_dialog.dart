import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../services/global_task_manager.dart';

class JoinProgressDialog extends StatelessWidget {
  final JoinController controller;

  const JoinProgressDialog({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final isSuccess = controller.isProgressSuccess;
    final isFailed = controller.isProgressFailed;
    final isInProgress = !isSuccess && !isFailed;

    return Material(
      color: Colors.black54,
      child: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.6),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                offset: const Offset(4, 8),
                blurRadius: 24,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isInProgress) ...[
                _buildProgressContent(),
              ] else if (isSuccess) ...[
                _buildSuccessContent(),
              ] else if (isFailed) ...[
                _buildFailedContent(),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressContent() {
    return Column(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF4A72A5)),
            value:
                controller.progressValue > 0 ? controller.progressValue : null,
          ),
        ),
        const SizedBox(height: 20),
        Text('正在入库...',
            style: TextStyle(
                fontFamily: 'Zhi Mang Xing',
                fontSize: 18,
                color: AppColors.primaryText)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 6,
            value:
                controller.progressValue > 0 ? controller.progressValue : null,
            backgroundColor: AppColors.buttonBackground,
            valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF4A72A5)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
            controller.progressMessage.isNotEmpty
                ? controller.progressMessage
                : '请稍候...',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.secondaryText),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => controller.cancelOperation(),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('取消',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessContent() {
    return Column(
      children: [
        Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(Icons.check_rounded,
                size: 32, color: const Color(0xFF4CAF50))),
        const SizedBox(height: 16),
        Text('入库成功！',
            style: TextStyle(
                fontFamily: 'Zhi Mang Xing',
                fontSize: 20,
                color: const Color(0xFF4CAF50))),
        const SizedBox(height: 8),
        Text('《${controller.nameController.text}》已添加到库中',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: AppColors.secondaryText)),
      ],
    );
  }

  Widget _buildFailedContent() {
    return Column(
      children: [
        Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                color: const Color(0xFFFFF0F0), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(Icons.error_rounded,
                size: 32, color: AppColors.dangerRed)),
        const SizedBox(height: 16),
        Text('入库失败',
            style: TextStyle(
                fontFamily: 'Zhi Mang Xing',
                fontSize: 20,
                color: AppColors.dangerRed)),
        const SizedBox(height: 8),
        Text(
            GlobalTaskManager.instance.dlCore.extractManager.errorMessage ??
                '未知错误',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.dangerRed.withOpacity(0.8)),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => controller.resetProgress(),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.dangerRed.withOpacity(0.08),
                border: Border.all(
                    color: AppColors.dangerRed.withOpacity(0.4), width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('关闭',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.dangerRed)),
            ),
          ),
        ),
      ],
    );
  }
}
