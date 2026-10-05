import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

class FileDropZone extends StatelessWidget {
  final JoinController controller;

  /// ★ 2026-10-04 拖拽修复：仅在单文件模式启用系统拖放监听。
  /// desktop_drop 的 DropTarget【不走 Flutter hitTest】——SwipeSwitcher
  /// 用 Stack 叠放单/批两页时，隐藏页的 DropTarget 仍会收到系统拖放
  /// （插件文档原话："drop target will still receive drag events even
  /// it is invisible"），与可见页的 DropTarget 完全重叠 → 双响应/抢事件。
  /// 用 enable 互斥：任一时刻只有当前模式的 DropTarget 在监听。
  final bool dropEnabled;

  /// ★ 2026-10-05 需求修正：叠放在置入板块【内部右下角】的操作按钮组
  /// （使用说明 / 打开解压计划窗口）。空态与已选态都常驻显示。
  final Widget? bottomRightActions;

  const FileDropZone({
    super.key,
    required this.controller,
    this.dropEnabled = true,
    this.bottomRightActions,
  });

  @override
  Widget build(BuildContext context) {
    final hasFile = controller.selectedFilePath != null;
    final fileType = hasFile
        ? controller.detectFileType(controller.selectedFilePath!)
        : null;

    // ★ 2026-10-04 智能解压 Phase 1（G6）：叠加系统级拖拽。
    // 原 Flutter DragTarget 只接收应用内 Draggable 数据，从资源管理器
    // 拖文件进来无任何反应；desktop_drop 的 DropTarget（批量模式
    // batch_import_section.dart:435 同款）接收系统级拖放。包在整体
    // 外层使空态与已选态均可接收，拖入即替换当前选择。
    return DropTarget(
      enable: dropEnabled,
      onDragDone: (details) {
        controller.setDragging(false);
        if (details.files.isEmpty) return;
        // 单文件导入语义：多选拖入只取第一个
        controller.handleFileSelected(details.files.first.path);
      },
      onDragEntered: (_) => controller.setDragging(true),
      onDragExited: (_) => controller.setDragging(false),
      child: Container(
      width: double.infinity,
      decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(
              color: AppColors.border, width: 1.6, style: BorderStyle.solid)),
      child: Stack(
        children: [
          hasFile
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
                                            ? AppColors.infoBlue
                                                .withOpacity(0.08)
                                            : AppColors.placeholderBg,
                                        border: Border.all(
                                            color: controller.isDragging
                                                ? AppColors.infoBlue
                                                : AppColors.border,
                                            width: controller.isDragging
                                                ? 2
                                                : 1.6),
                                        borderRadius:
                                            BorderRadius.circular(8)),
                                    alignment: Alignment.center,
                                    child: Icon(Icons.folder_outlined,
                                        size: 40,
                                        color: controller.isDragging
                                            ? AppColors.infoBlue
                                            : AppColors.border)),
                                const SizedBox(height: 16),
                                Text('置入本地游戏文件',
                                    style: TextStyle(
                                        fontSize: 18,
                                        letterSpacing: 1.2,
                                        color: controller.isDragging
                                            ? AppColors.infoBlue
                                            : AppColors.border)),
                                const SizedBox(height: 8),
                                Text('支持拖拽游戏文件夹或压缩包（.zip/.rar/.7z/.iso等）',
                                    style: TextStyle(
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
          // ★ 2026-10-05：置入板块内部右下角常驻按钮组（需求 #2 修正：
          //   放板块内而非页面底部操作行；有文件后仍保持显示）
          if (bottomRightActions != null)
            Positioned(
              right: 10,
              bottom: 10,
              child: bottomRightActions!,
            ),
        ],
      ),
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
                  color: AppColors.placeholderBg,
                  border: Border.all(color: AppColors.border, width: 1.6),
                  borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: Icon(controller.getFileIcon(fileType),
                  size: 40, color: AppColors.secondaryText)),
          const SizedBox(height: 16),
          Text(controller.selectedFileName ?? '',
              style: TextStyle(
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
                  color: AppColors.placeholderBg,
                  border: Border.all(color: AppColors.border, width: 1),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(controller.getFileLabel(fileType),
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.secondaryText))),
          const SizedBox(height: 8),
          Flexible(
              child: Text(controller.selectedFilePath ?? '',
                  style: TextStyle(
                      fontSize: 12,
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
