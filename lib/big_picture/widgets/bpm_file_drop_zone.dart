import 'package:flutter/material.dart';
import '../../pages/join/join_controller.dart';
import '../../theme/app_colors.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';

/// BPM 风格文件拖拽区 (v1.2 新增)
///
/// 包装桌面 [FileDropZone] 的拖拽逻辑,替换交互层为 [BpmInteractiveWrapper],
/// 提供键盘焦点支持与 BPM 视觉规范 (大字号、统一颜色)。
///
/// 复用 [JoinController] API:
/// - [JoinController.handleFileSelected] / [JoinController.pickFile] / [JoinController.clearFileSelection]
/// - [JoinController.detectFileType] / [JoinController.getFileIcon] / [JoinController.getFileLabel]
/// - [JoinController.setDragging] / [JoinController.isDragging]
/// - [JoinController.selectedFilePath] / [JoinController.selectedFileName]
class BpmFileDropZone extends StatelessWidget {
  final JoinController controller;

  const BpmFileDropZone({super.key, required this.controller});

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
        borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        border: Border.all(
          color: controller.isDragging
              ? AppColors.selectedAccent
              : AppColors.border,
          width: controller.isDragging ? 2 : 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasFile
          ? _FileInfoDisplay(fileType: fileType!, controller: controller)
          : DragTarget<String>(
              onWillAcceptWithDetails: (details) => true,
              onAcceptWithDetails: (details) {
                controller.handleFileSelected(details.data);
                controller.setDragging(false);
              },
              onLeave: (_) => controller.setDragging(false),
              builder: (context, candidateData, rejectedData) {
                return BpmInteractiveWrapper(
                  onTap: () => controller.pickFile(),
                  autofocus: true,
                  semanticsLabel: '选择游戏文件',
                  borderRadius:
                      BorderRadius.circular(BigPictureTheme.containerRadius),
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
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                shape: BoxShape.rectangle,
                                color: controller.isDragging
                                    ? AppColors.selectedAccent.withOpacity(0.1)
                                    : AppColors.placeholderBg,
                                border: Border.all(
                                  color: controller.isDragging
                                      ? AppColors.selectedAccent
                                      : AppColors.border,
                                  width: controller.isDragging ? 2 : 1.5,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.folder_outlined,
                                size: 48,
                                color: controller.isDragging
                                    ? AppColors.selectedAccent
                                    : AppColors.secondaryText,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              '置入本地游戏文件',
                              style: TextStyle(
                                fontFamily: 'ZhiMangXing',
                                fontSize: BigPictureTheme.subtitleFontSize,
                                letterSpacing: 1.5,
                                color: controller.isDragging
                                    ? AppColors.selectedAccent
                                    : AppColors.primaryText,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '支持拖拽游戏文件夹或压缩包 (.zip/.rar/.7z/.iso 等)',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: BigPictureTheme.labelFontSize,
                                color: AppColors.secondaryText.withOpacity(0.7),
                              ),
                              textAlign: TextAlign.center,
                            ),
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

/// 已选文件信息展示 (BPM 风格)
class _FileInfoDisplay extends StatelessWidget {
  final String fileType;
  final JoinController controller;

  const _FileInfoDisplay({
    required this.fileType,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(BigPictureTheme.widgetPadding),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              border: Border.all(color: AppColors.border, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(
              controller.getFileIcon(fileType),
              size: 48,
              color: AppColors.selectedAccent,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            controller.selectedFileName ?? '',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: BigPictureTheme.bodyFontSize,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              border: Border.all(color: AppColors.border, width: 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              controller.getFileLabel(fileType),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.labelFontSize,
                color: AppColors.secondaryText,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: Text(
              controller.selectedFilePath ?? '',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: BigPictureTheme.labelFontSize,
                color: AppColors.placeholderText,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 16),
          BpmInteractiveWrapper(
            onTap: () => controller.clearFileSelection(),
            semanticsLabel: '清除选择',
            borderRadius: BorderRadius.circular(BigPictureTheme.buttonRadius),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppColors.dangerRed.withOpacity(0.5),
                  width: 1.5,
                ),
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.buttonRadius),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close_rounded,
                      size: 18, color: AppColors.dangerRed),
                  const SizedBox(width: 6),
                  Text(
                    '清除选择',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: BigPictureTheme.labelFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppColors.dangerRed,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
