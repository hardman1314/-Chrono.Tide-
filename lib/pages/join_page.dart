import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_colors.dart';
import 'join/join_controller.dart';
import 'join/batch_import_controller.dart';
import 'join/widgets/form_inputs.dart';
import 'join/widgets/metadata_section.dart';
import 'join/widgets/file_drop_zone.dart';
import 'join/widgets/action_buttons.dart';
import 'join/widgets/progress_dialog.dart';
import 'join/widgets/swipe_switcher.dart';
import 'join/widgets/batch_import_section.dart';

class JoinPage extends StatefulWidget {
  final VoidCallback? onGameAdded;
  final BatchImportController? batchController; // 新增：全局持久化控制器

  const JoinPage({super.key, this.onGameAdded, this.batchController});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  late JoinController _singleController;
  late BatchImportController _batchController;
  ImportMode _currentMode = ImportMode.single;
  OverlayEntry? _progressOverlay;

  @override
  void initState() {
    super.initState();

    _singleController = JoinController(
      onGameAdded: widget.onGameAdded,
      onError: _showErrorSnackBar,
      onSuccess: _showSuccessSnackBar,
      onWarning: _showWarningSnackBar,
      onInfo: _showInfoSnackBar,
    );

    // 优先使用全局持久化的控制器（如果提供），否则创建本地控制器
    _batchController = widget.batchController ??
        BatchImportController(
          onGameAdded: () {
            _singleController.onGameAdded?.call();
            setState(() {});
          },
          onError: _showErrorSnackBar,
          onSuccess: _showBatchSuccessNotification,
          onInfo: _showInfoSnackBar,
          onConfirmEdit: _saveSingleToBatchGame,
        );

    // ★ 关键修复：无论使用全局还是本地控制器，都必须绑定保存回调！
    // 全局控制器在 main_container.dart 创建时没有设置 onConfirmEdit，
    // 导致 ✓ 按钮点击后什么都不会发生。
    _batchController.onConfirmEdit = _saveSingleToBatchGame;

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _singleController.initListeners();

      _batchController.addListener(() {
        // 只在切换选中游戏时同步到左侧表单
        // 确认保存操作（_lastSelectedGameId 为 null）不触发同步，避免覆盖用户编辑
        if (_batchController.selectedGame != null &&
            _batchController.lastSelectedGameId != null) {
          _syncBatchGameToSingleForm(_batchController.selectedGame!);
        }
        // 确保UI更新（即使是从其他页面切回来）
        setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _dismissProgress();
    _singleController.dispose();
    // 只有本地创建的控制器才需要销毁，全局控制器由MainContainer管理
    if (widget.batchController == null) {
      _batchController.dispose();
    }
    super.dispose();
  }

  void _syncBatchGameToSingleForm(dynamic batchGame) {
    _singleController.nameController.text = batchGame.gameName;
    _singleController.tagsController.text = batchGame.tags.join(', ');
    _singleController.descController.text = batchGame.description;
    if (batchGame.developer != null &&
        batchGame.developer.toString().isNotEmpty) {
      _singleController.developerController.text =
          batchGame.developer.toString();
    }

    // 设置封面（优先使用本地文件，其次从网络URL下载）
    if (batchGame.coverFilePath != null &&
        batchGame.coverFilePath!.isNotEmpty &&
        File(batchGame.coverFilePath!).existsSync()) {
      _singleController.setCoverFilePath(batchGame.coverFilePath);
    } else if (batchGame.metadata?['cover_url'] != null &&
        batchGame.metadata!['cover_url'].toString().isNotEmpty) {
      // 有网络封面URL但本地没有缓存文件 → 自动下载
      final coverUrl = batchGame.metadata!['cover_url'].toString();
      debugPrint('[BATCH] 从网络下载封面到本地: $coverUrl');
      _singleController.downloadAndSetCover(coverUrl);
    } else {
      // 无任何封面数据，清空封面
      _singleController.removeCover();
    }
  }

  void _saveSingleToBatchGame() {
    if (_batchController.selectedGame == null) return;

    // 构建完整的 metadata（保留原有数据 + 新抓取的数据）
    final existingMetadata = _batchController.selectedGame?.metadata ?? {};
    final newMetadata = <String, dynamic>{...existingMetadata};

    // 如果用户通过一键抓取选择了新数据，更新 metadata
    if (_singleController.selectedResult != null) {
      final scrapeResult = _singleController.selectedResult!;
      // 更新/覆盖抓取到的字段
      if (scrapeResult['game_name'] != null) {
        newMetadata['game_name'] = scrapeResult['game_name'];
      }
      if (scrapeResult['platform'] != null) {
        newMetadata['platform'] = scrapeResult['platform'];
      }
      if (scrapeResult['platform_id'] != null) {
        newMetadata['platform_id'] = scrapeResult['platform_id'];
      }
      if (scrapeResult['cover_url'] != null &&
          scrapeResult['cover_url'].toString().isNotEmpty) {
        newMetadata['cover_url'] = scrapeResult['cover_url'];
      }
      if (scrapeResult['tags'] != null) {
        newMetadata['tags'] = scrapeResult['tags'];
      }
      if (scrapeResult['release_date'] != null) {
        newMetadata['release_date'] = scrapeResult['release_date'];
      }
    }

    _batchController.updateSelectedGame(
      gameName: _singleController.nameController.text.trim(),
      tags: _singleController.tagsController.text
          .split(RegExp(r'[,\s，、]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      description: _singleController.descController.text.trim(),
      coverFilePath: _singleController.coverFilePath,
      developer: _singleController.developerController.text.trim(),
      metadata: newMetadata,
    );
  }

  void _onModeChanged(ImportMode mode) {
    if (_currentMode == ImportMode.batch && mode == ImportMode.single) {
      _saveSingleToBatchGame();
    }

    setState(() {
      _currentMode = mode;
    });
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
        ],
      ),
      duration: const Duration(seconds: 3),
      backgroundColor: AppColors.dangerRed,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
      elevation: 6,
    ));
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
        ],
      ),
      duration: const Duration(seconds: 2, milliseconds: 500),
      backgroundColor: const Color(0xFF4CAF50),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
      elevation: 6,
    ));
  }

  void _showWarningSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.warning_amber_outlined,
              color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
        ],
      ),
      duration: const Duration(seconds: 3),
      backgroundColor: const Color(0xFFD4A017),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
      elevation: 6,
    ));
  }

  void _showInfoSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
        ],
      ),
      duration: const Duration(seconds: 2, milliseconds: 500),
      backgroundColor: const Color(0xFF4A72A5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
      elevation: 6,
    ));
  }

  // 新增：批量入库专用的醒目成功提示
  void _showBatchSuccessNotification(String message) {
    if (!mounted) return;

    // 使用延迟初始化解决循环引用
    OverlayEntry? overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => _BatchSuccessOverlay(
        message: message,
        onDismiss: () {
          overlayEntry?.remove();
        },
      ),
    );

    Overlay.of(context).insert(overlayEntry);

    // 3秒后自动消失
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && overlayEntry?.mounted == true) {
        overlayEntry!.remove();
      }
    });
  }

  void _showProgress() {
    _progressOverlay?.remove();
    _singleController.resetProgress();
    _progressOverlay = OverlayEntry(
        builder: (_) => JoinProgressDialog(controller: _singleController));
    Overlay.of(context).insert(_progressOverlay!);
  }

  void _dismissProgress() {
    _progressOverlay?.remove();
    _progressOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_singleController, _batchController]),
      builder: (context, child) {
        if (_singleController.isSubmitting && _progressOverlay == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _showProgress());
        }

        if (_singleController.isProgressSuccess ||
            _singleController.isProgressFailed) {
          if (_progressOverlay != null) {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (_singleController.isProgressSuccess) {
                _singleController.handleExtractSuccess();
              }
              _dismissProgress();
            });
          }
        }

        return Container(
          width: double.infinity,
          height: double.infinity,
          color: AppColors.pageBackground,
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLeftColumn(),
              const SizedBox(width: 20),
              Expanded(flex: 6, child: _buildRightColumn()),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLeftColumn() {
    return Expanded(
      flex: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverSection(controller: _singleController),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    NameInput(controller: _singleController),
                    const SizedBox(height: 10),
                    TagsInput(controller: _singleController),
                    const SizedBox(height: 10),
                    DeveloperInput(controller: _singleController),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: DescInput(controller: _singleController)),
        ],
      ),
    );
  }

  Widget _buildRightColumn() {
    return Column(
      children: [
        MetadataSection(controller: _singleController),
        const SizedBox(height: 16),
        Expanded(
          child: SwipeSwitcher(
            initialMode: _currentMode,
            onModeChanged: _onModeChanged,
            hasContent: _batchController.hasGames ||
                (_singleController.selectedFilePath != null),
            singleModeChild: FileDropZone(controller: _singleController),
            batchModeChild: BatchImportSection(
              batchController: _batchController,
              singleController: _singleController,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ActionButtons(
          controller:
              _currentMode == ImportMode.single ? _singleController : null,
          onBatchSubmit: _currentMode == ImportMode.batch
              ? () => _submitBatchImport()
              : null,
          onBatchCancel: _currentMode == ImportMode.batch
              ? () {
                  _batchController.clearAll();
                  _singleController.resetForm();
                }
              : null,
        ),
      ],
    );
  }

  Future<void> _submitBatchImport() async {
    if (!_batchController.hasGames) {
      _showWarningSnackBar('请先置入游戏文件夹');
      return;
    }

    await _batchController.submitBatchImport();
  }
}

// 批量入库成功提示的Overlay组件
class _BatchSuccessOverlay extends StatefulWidget {
  final String message;
  final VoidCallback onDismiss;

  const _BatchSuccessOverlay({
    required this.message,
    required this.onDismiss,
  });

  @override
  State<_BatchSuccessOverlay> createState() => _BatchSuccessOverlayState();
}

class _BatchSuccessOverlayState extends State<_BatchSuccessOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();

    // 2.5秒后开始消失动画
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54, // 半透明黑色背景
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Opacity(
              opacity: _opacityAnimation.value,
              child: Transform.scale(
                scale: _scaleAnimation.value,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50), // 绿色背景
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF4CAF50).withOpacity(0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_outline,
                        color: Colors.white,
                        size: 48,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
