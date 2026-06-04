import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import '../batch_import_controller.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

class BatchImportSection extends StatefulWidget {
  final BatchImportController batchController;
  final JoinController singleController;

  const BatchImportSection({
    super.key,
    required this.batchController,
    required this.singleController,
  });

  @override
  State<BatchImportSection> createState() => _BatchImportSectionState();
}

class _BatchImportSectionState extends State<BatchImportSection> {
  bool _isCenterIconHovered = false;
  bool _isDragging = false; // 新增：拖拽状态跟踪

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.6),
      ),
      child: widget.batchController.hasGames
          ? _buildGamesList(context)
          : _buildEmptyState(context),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return DropTarget(
      onDragDone: (details) {
        final paths = details.files.map((f) => f.path).toList();
        widget.batchController.handleDraggedFiles(paths);
      },
      child: InteractiveWrapper(
        onTap: () => widget.batchController.pickFolders(),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 116),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 中心方框（带圆角和悬停效果）
              _buildCenterIcon(),
              const SizedBox(height: 20),
              Text('批量置入游戏文件',
                  style: TextStyle(
                      fontFamily: 'Zhi Mang Xing',
                      fontSize: 24,
                      letterSpacing: 2.0,
                      color: const Color(0xFF8B7355))),
              const SizedBox(height: 8),
              Text('支持选择或拖入多个游戏文件夹',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFA08264))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterIcon() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isCenterIconHovered = true),
      onExit: (_) => setState(() => _isCenterIconHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: _isCenterIconHovered
              ? const Color(0xFFFFF3CD) // 悬停时：浅黄色
              : const Color(0xFFF5F1E8), // 默认时：米色
          borderRadius: BorderRadius.circular(12), // 圆角处理
          border: Border.all(
            color: _isCenterIconHovered
                ? const Color(0xFFFFD700) // 悬停边框：金黄色
                : AppColors.border, // 默认边框：棕色
            width: _isCenterIconHovered ? 2.5 : 1.6,
          ),
          boxShadow: _isCenterIconHovered
              ? [
                  BoxShadow(
                    color: const Color(0xFFFFD700).withOpacity(0.4), // 黄色阴影
                    offset: const Offset(0, 4),
                    blurRadius: 8,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.create_new_folder,
          size: 40,
          color: _isCenterIconHovered
              ? const Color(0xFFFFA500) // 悬停图标：橙色-金色
              : AppColors.border, // 默认图标：棕色
        ),
      ),
    );
  }

  Widget _buildGamesList(BuildContext context) {
    // 将整个列表包裹在 DropTarget 中，支持持续拖入新增
    return DropTarget(
      onDragEntered: (details) {
        // 拖拽进入时改变视觉反馈
        setState(() {
          _isDragging = true;
        });
        debugPrint('[BATCH] 拖拽进入区域');
      },
      onDragExited: (details) {
        // 拖拽离开时恢复
        setState(() {
          _isDragging = false;
        });
        debugPrint('[BATCH] 拖拽离开区域');
      },
      onDragDone: (details) {
        // 拖拽完成后重置状态并处理文件
        setState(() {
          _isDragging = false;
        });

        final paths = details.files.map((f) => f.path).toList();
        debugPrint('[BATCH] 拖拽完成，收到 ${paths.length} 个文件/文件夹');

        if (paths.isNotEmpty) {
          widget.batchController.handleDraggedFiles(paths);
        }
      },
      onDragUpdated: (details) {
        // 可选：跟踪拖拽位置（用于调试）
        debugPrint('[BATCH] 拖拽位置更新: ${details.localPosition}');
      },
      child: Container(
        // 根据拖拽状态改变背景色提供视觉反馈
        decoration: BoxDecoration(
          color: _isDragging
              ? const Color(0xFFE8F4E8) // 拖拽时：浅绿色背景
              : Colors.transparent,
          border: _isDragging
              ? Border.all(color: const Color(0xFF4CAF50), width: 3) // 拖拽时：绿色边框
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount:
                      widget.batchController.games.length + 1, // +1 为新增按钮
                  itemBuilder: (context, index) {
                    // 第一个位置是新增按钮
                    if (index == 0) {
                      return _buildAddNewButton(context);
                    }

                    final game = widget.batchController.games[index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: BatchGameCard(
                        game: game,
                        isSelected:
                            widget.batchController.selectedGame?.id == game.id,
                        onTap: () => widget.batchController.selectGame(game),
                        onDelete: () =>
                            widget.batchController.removeGame(game.id),
                        onConfirm: () =>
                            widget.batchController.confirmCurrentSelection(),
                      ),
                    );
                  },
                ),
              ),
              if (widget.batchController.isProcessingQueue)
                _buildProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddNewButton(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InteractiveWrapper(
        onTap: () => widget.batchController.pickFolders(),
        child: Container(
          constraints: const BoxConstraints(minWidth: 136, minHeight: 31),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFF4A72A5), width: 1.8),
            borderRadius: BorderRadius.circular(4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x304A72A5),
                offset: Offset(1.5, 2),
                blurRadius: 3,
                spreadRadius: 0,
              )
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.create_new_folder,
                  size: 17, color: const Color(0xFF4A72A5)),
              const SizedBox(width: 10),
              Text('新增',
                  style: TextStyle(
                      fontFamily: 'Zhi Mang Xing',
                      fontSize: 18,
                      letterSpacing: 1.8,
                      color: const Color(0xFF4A72A5))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      children: [
        LinearProgressIndicator(
          value: widget.batchController.overallProgress > 0
              ? widget.batchController.overallProgress
              : null,
          backgroundColor: AppColors.buttonBackground,
          valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF4A72A5)),
        ),
        const SizedBox(height: 8),
        Text(widget.batchController.batchStatusMessage,
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: AppColors.secondaryText)),
      ],
    );
  }
}

class BatchGameCard extends StatefulWidget {
  final BatchGameItem game;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onConfirm;

  const BatchGameCard({
    super.key,
    required this.game,
    this.isSelected = false,
    this.onTap,
    this.onDelete,
    this.onConfirm,
  });

  @override
  State<BatchGameCard> createState() => _BatchGameCardState();
}

class _BatchGameCardState extends State<BatchGameCard> {
  bool _showSavedFeedback = false;
  bool _actionButtonClicked = false; // 新增：标记是否点击了操作按钮

  @override
  Widget build(BuildContext context) {
    return InteractiveWrapper(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          if (_actionButtonClicked) {
            _actionButtonClicked = false;
            return;
          }
          widget.onTap?.call();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: const Color(0xFFFDFBF7),
            border: Border.all(
              color: widget.isSelected
                  ? const Color(0xFF555D8B) // 选中态：蓝色边框
                  : const Color(0xFF8B7355), // 普通态：棕色边框
              width: widget.isSelected ? 4 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B7355).withOpacity(0.15),
                offset: const Offset(2, 3),
                blurRadius: 0,
              )
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          height: 82, // 增加高度以容纳路径框
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCoverImage(),
                  const SizedBox(width: 19),
                  Expanded(child: _buildGameInfo()),
                  const SizedBox(width: 13),
                  _buildActionButtons(),
                ],
              ),
              // 路径框单独一行，放在底部
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 75), // 对齐到信息区域
                child: _buildPathDisplay(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage() {
    return Container(
      width: 44,
      height: 58,
      decoration: BoxDecoration(
        color: const Color(0xFFE9E0D1),
        border: Border.all(color: const Color(0xFF8B7355), width: 2),
      ),
      clipBehavior: Clip.hardEdge,
      alignment: Alignment.center,
      child: _getCoverContent(),
    );
  }

  Widget _getCoverContent() {
    if (widget.game.coverFilePath != null &&
        File(widget.game.coverFilePath!).existsSync()) {
      return FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.center,
        clipBehavior: Clip.hardEdge,
        child: Image.file(
          File(widget.game.coverFilePath!),
          fit: BoxFit.fill,
        ),
      );
    }

    if (widget.game.metadata != null &&
        widget.game.metadata!['cover_url'] != null) {
      final coverUrl = widget.game.metadata!['cover_url'].toString();
      if (coverUrl.startsWith('http')) {
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.center,
          clipBehavior: Clip.hardEdge,
          child: CachedNetworkImage(
            imageUrl: coverUrl,
            fit: BoxFit.fill,
            placeholder: (context, url) => Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  const Color(0xFF8B7355),
                ),
              ),
            ),
            errorWidget: (context, url, error) => Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 16, color: const Color(0xFF8B7355)),
            ),
          ),
        );
      }
    }

    return Icon(Icons.image_outlined, size: 16, color: const Color(0xFF8B7355));
  }

  Widget _buildGameInfo() {
    // 只有在已抓取到元数据时才显示平台标签
    final hasMetadata =
        widget.game.metadata != null && widget.game.metadata!.isNotEmpty;

    final platform = hasMetadata
        ? (widget.game.metadata!['platform'] ?? 'vndb')
        : null; // 未抓取数据时不设置默认值
    final platformId =
        hasMetadata ? (widget.game.metadata!['platform_id'] ?? '') : '';
    final releaseDate =
        hasMetadata ? (widget.game.metadata!['release_date'] ?? '') : '';

    final isVndb = platform == 'vndb';
    final platformColor =
        isVndb ? const Color(0xFF4A72A5) : const Color(0xFFF27494);
    final platformLabel = isVndb ? 'VNDB' : 'Bangumi';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 只在有元数据时显示平台标签和ID
        if (hasMetadata && platform != null)
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: platformColor,
                    borderRadius: BorderRadius.circular(4)),
                child: Text(platformLabel!,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
              const SizedBox(width: 6),
              Text(platformId,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFA08264))),
            ],
          ),
        if (!hasMetadata)
          Container(
            height: 17, // 占位，保持布局一致
          ),
        const SizedBox(height: 3),
        Text(widget.game.gameName,
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF5C4A3D)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 3),
        Text(releaseDate.isNotEmpty ? '$releaseDate发行' : '',
            style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                color: const Color(0xFFA08264))),
      ],
    );
  }

  Widget _buildPathDisplay() {
    final path = widget.game.folderPath;
    final displayPath =
        _truncatePath(path, maxStartLength: 20, maxEndLength: 15);

    return InteractiveWrapper(
      child: Listener(
        onPointerUp: (event) {
          debugPrint('[BATCH] 路径框被点击: $path');
          _showPathEditDialog();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280, minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF8B7355), width: 1.5),
            borderRadius: BorderRadius.circular(2),
            color: const Color(0xFFFDFBF7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 14, color: const Color(0xFF8B7355)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  displayPath,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: const Color(0xFF000000),
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit, size: 14, color: const Color(0xFF4A72A5)),
            ],
          ),
        ),
      ),
    );
  }

  String _truncatePath(String path,
      {required int maxStartLength, required int maxEndLength}) {
    if (path.length <= maxStartLength + maxEndLength + 3) {
      return path; // 路径不够长，不需要截断
    }

    final start = path.substring(0, maxStartLength);
    final end = path.substring(path.length - maxEndLength);
    return '$start...$end';
  }

  void _showPathEditDialog() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        String newPath = widget.game.folderPath;

        return AlertDialog(
          title: Text('修改游戏路径'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前路径:',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 4),
              SelectableText(
                widget.game.folderPath,
                style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              Text('或选择新路径:',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: () async {
                  final result = await FilePicker.platform.getDirectoryPath(
                    dialogTitle: '选择游戏目录',
                    initialDirectory: widget.game.folderPath,
                  );

                  if (result != null && mounted) {
                    Navigator.of(dialogContext).pop(result);
                  }
                },
                icon: Icon(Icons.folder_open, size: 18),
                label: Text('浏览文件夹'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A72A5),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('取消'),
            ),
          ],
        );
      },
    ).then((selectedPath) {
      if (selectedPath != null && selectedPath is String) {
        debugPrint('[BATCH] 用户选择了新路径: $selectedPath');
        // 这里可以添加更新逻辑
      }
    });
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isSelected) _buildConfirmButton(),
        const SizedBox(width: 8),
        _buildDeleteButton(),
      ],
    );
  }

  Widget _buildConfirmButton() {
    return InteractiveWrapper(
      hoverScale: 1.1,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          _actionButtonClicked = true;
          widget.onConfirm?.call();
          setState(() => _showSavedFeedback = true);
          Future.delayed(const Duration(milliseconds: 1200), () {
            if (mounted) {
              setState(() => _showSavedFeedback = false);
            }
          });
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                color: const Color(0xFFFDFBF7),
                border: Border.all(color: const Color(0xFF0000001a), width: 2),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0xFF8B7355),
                      offset: Offset(2, 3),
                      blurRadius: 0)
                ],
              ),
              alignment: Alignment.center,
              child: Icon(
                  _showSavedFeedback ? Icons.check_circle : Icons.check_rounded,
                  size: 18,
                  color: _showSavedFeedback
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFF4CAF50)),
            ),
            if (_showSavedFeedback)
              Positioned(
                top: -32,
                left: -20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('已保存',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteButton() {
    return InteractiveWrapper(
      hoverScale: 1.1,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          _actionButtonClicked = true;
          widget.onDelete?.call();
        },
        child: Container(
          width: 29,
          height: 29,
          decoration: BoxDecoration(
            color: const Color(0xFFFDFBF7),
            border: Border.all(color: const Color(0xFF0000001a), width: 2),
            boxShadow: const [
              BoxShadow(
                  color: Color(0xFF8B7355), offset: Offset(2, 3), blurRadius: 0)
            ],
          ),
          alignment: Alignment.center,
          child: Icon(Icons.close_rounded,
              size: 18, color: const Color(0xFF8B7355)),
        ),
      ),
    );
  }
}
