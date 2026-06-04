import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

class FileDropZone extends StatelessWidget {
  final JoinController controller;

  const FileDropZone({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final hasFile = controller.selectedFilePath != null;
    final fileType = hasFile
        ? controller.detectFileType(controller.selectedFilePath!)
        : null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(
              color: AppColors.border, width: 1.6, style: BorderStyle.solid)),
      child: hasFile
          ? FileInfoDisplay(fileType: fileType!, controller: controller)
          : DragTarget<String>(
              onWillAcceptWithDetails: (details) => true,
              onAcceptWithDetails: (details) {
                controller.handleFileSelected(details.data);
                controller.setDragging(false);
              },
              onLeave: (_) => controller.setDragging(false),
              builder: (context, candidateData, rejectedData) {
                return InteractiveWrapper(
                  onTap: () => controller.pickFile(),
                  child: MouseRegion(
                    onEnter: (_) => controller.setDragging(true),
                    onExit: (_) => controller.setDragging(false),
                    child: Container(
                      width: double.infinity,
                      height: double.infinity,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                    shape: BoxShape.rectangle,
                                    color: controller.isDragging
                                        ? const Color(0xFF4A72A5)
                                            .withOpacity(0.08)
                                        : const Color(0xFFF5F1E8),
                                    border: Border.all(
                                        color: controller.isDragging
                                            ? const Color(0xFF4A72A5)
                                            : AppColors.border,
                                        width: controller.isDragging ? 2 : 1.6),
                                    borderRadius: BorderRadius.circular(8)),
                                alignment: Alignment.center,
                                child: Icon(Icons.folder_outlined,
                                    size: 40,
                                    color: controller.isDragging
                                        ? const Color(0xFF4A72A5)
                                        : AppColors.border)),
                            const SizedBox(height: 16),
                            Text('置入本地游戏文件',
                                style: TextStyle(
                                    fontFamily: 'Zhi Mang Xing',
                                    fontSize: 18,
                                    letterSpacing: 1.2,
                                    color: controller.isDragging
                                        ? const Color(0xFF4A72A5)
                                        : AppColors.border)),
                            const SizedBox(height: 8),
                            Text('支持拖拽游戏文件夹或压缩包（.zip/.rar/.7z/.iso等）',
                                style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 12,
                                    color: AppColors.secondaryText
                                        .withOpacity(0.6)))
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class FileInfoDisplay extends StatelessWidget {
  final String fileType;
  final JoinController controller;

  const FileInfoDisplay({
    super.key,
    required this.fileType,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F1E8),
                  border: Border.all(color: AppColors.border, width: 1.6),
                  borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: Icon(controller.getFileIcon(fileType),
                  size: 40, color: AppColors.secondaryText)),
          const SizedBox(height: 16),
          Text(controller.selectedFileName ?? '',
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F1E8),
                  border: Border.all(color: AppColors.border, width: 1),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(controller.getFileLabel(fileType),
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      color: AppColors.secondaryText))),
          const SizedBox(height: 8),
          Flexible(
              child: Text(controller.selectedFilePath ?? '',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      color: AppColors.placeholderText),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis)),
          const Spacer(),
          InteractiveWrapper(
              onTap: () => controller.clearFileSelection(),
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  decoration: BoxDecoration(
                      border: Border.all(
                          color: AppColors.dangerRed.withOpacity(0.5),
                          width: 1),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.close_rounded,
                          size: 13,
                          color: AppColors.dangerRed.withOpacity(0.7)),
                      const SizedBox(width: 4),
                      Text('清除选择',
                          style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.dangerRed.withOpacity(0.7)))
                    ],
                  )))
        ],
      ),
    );
  }
}
