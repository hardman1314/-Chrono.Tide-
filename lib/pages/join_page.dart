import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_colors.dart';
import '../widgets/screenshot_carousel.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/custom_title_bar.dart' show kTitleBarHeight;
import 'join/join_controller.dart';
import 'join/batch_import_controller.dart';
import 'join/widgets/form_inputs.dart';
import 'join/widgets/field_lock_button.dart';
import 'join/widgets/metadata_section.dart';
import 'join/widgets/file_drop_zone.dart';
import 'join/widgets/action_buttons.dart';
import 'join/widgets/progress_dialog.dart';
import 'join/widgets/swipe_switcher.dart';
import 'join/widgets/batch_import_section.dart';
import 'join/widgets/smart_import_section.dart';

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
          onConfirmEdit: _onBatchConfirmEdit,
        );

    // ★ 关键修复：无论使用全局还是本地控制器，都必须绑定回调！
    _batchController.onConfirmEdit = _onBatchConfirmEdit;
    _batchController.onAutoSave = _saveSingleToBatchGame;

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _singleController.initListeners();

      _batchController.addListener(() {
        // 只在用户主动切换选中游戏时同步到左侧表单
        // _lastSelectedGameId != null 表示是切换操作
        // _lastSelectedGameId == null 表示是确认保存后的通知，不覆盖表单
        if (_batchController.selectedGame != null &&
            _batchController.lastSelectedGameId != null) {
          _syncBatchGameToSingleForm(_batchController.selectedGame!);
        } else if (_batchController.selectedGame == null &&
            _batchController.lastSelectedGameId == null) {
          // 确认保存后：selectedGame 被设为 null，清空左侧表单
          _singleController.resetForm();
        }
        // 确保UI更新
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
    _singleController.bumpGeneration(); // 强制重建左侧UI，防止批量切换时Element累积
    _singleController.nameController.text = batchGame.gameName ?? '';
    _singleController.tagsController.text =
        (batchGame.tags as List?)?.join(', ') ?? '';
    _singleController.descController.text = batchGame.description ?? '';
    // 修复：无论 developer 是否为空都直接赋值，避免残留上一个游戏的会社名
    _singleController.developerController.text =
        batchGame.developer?.toString() ?? '';

    // 双标题同步：从 BatchGameItem 恢复 originalTitle/metadataTitle/usingMetadataTitle
    // 让 NameInput 右下角能显示"另一个标题"并支持切换
    _singleController.setTitles(
      original: batchGame.originalTitle ?? batchGame.gameName ?? '',
      metadata: batchGame.metadataTitle,
      useMetadata: batchGame.usingMetadataTitle ?? false,
    );

    // 清理之前的元数据抓取结果，避免残留上一个游戏的抓取数据
    _singleController.clearScrapeResults();

    // 恢复截图URL数据（从 BatchGameItem 的 screenshotUrls 字段恢复）
    // 注意：必须在 clearScrapeResults 之后调用，否则会被清空
    _singleController
        .restoreScreenshotUrls(batchGame.screenshotUrls?.cast<String>() ?? []);

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

  /// 确认保存编辑（✓按钮）— 保存数据到卡片 + 重置表单
  void _onBatchConfirmEdit() {
    _saveSingleToBatchGame();
    // confirmCurrentSelection 已经在 controller 中处理了取消选中和清空标志
    // listener 会检测到 selectedGame == null && lastSelectedGameId == null
    // 并自动调用 _singleController.resetForm()
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
      screenshotUrls: _singleController.screenshotUrls,
      // 双标题回写：同步单文件模式下的元数据标题与切换状态
      // metadataTitle 为 null 时 copyWith 保留原值（未抓取新元数据时不覆盖）
      metadataTitle: _singleController.metadataTitle,
      usingMetadataTitle: _singleController.usingMetadataTitle,
    );
  }

  void _onModeChanged(ImportMode mode) {
    if (_currentMode == ImportMode.batch && mode != ImportMode.batch) {
      // 从批量模式切出时，自动保存当前编辑
      _saveSingleToBatchGame();
      // 取消选中并重置表单
      if (_batchController.selectedGame != null) {
        _batchController.selectGame(null);
      }
      _singleController.resetForm();
    }

    setState(() {
      _currentMode = mode;
    });
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    AppSnackBar.error(context, message);
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    AppSnackBar.success(context, message);
  }

  void _showWarningSnackBar(String message) {
    if (!mounted) return;
    AppSnackBar.warning(context, message);
  }

  void _showInfoSnackBar(String message) {
    if (!mounted) return;
    AppSnackBar.info(context, message);
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
              Expanded(flex: 7, child: _buildRightColumn()),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLeftColumn() {
    // 使用 selectionGeneration 作为 key，确保每次点击元数据卡片时
    // Flutter 强制销毁旧组件树并重建新组件树，彻底防止快速点击导致的信息区重复累积
    return Expanded(
      flex: 5,
      child: Column(
        key: ValueKey('left_col_gen_${_singleController.selectionGeneration}'),
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
                    const SizedBox(height: 6),
                    TagsInput(controller: _singleController),
                    const SizedBox(height: 6),
                    DeveloperInput(controller: _singleController),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 截图轮播 + 锁按钮
          Stack(
            clipBehavior: Clip.none,
            children: [
              ScreenshotCarousel(
                key: ValueKey(
                    'join_screenshots_${_singleController.screenshotUrls.length}'),
                paths: _singleController.screenshotUrls,
                isNetwork: true,
                showIndicator: false,
              ),
              Positioned(
                top: 4,
                left: 4,
                child: FieldLockButton(
                  isLocked: _singleController.screenshotLocked,
                  onToggle: () => _singleController.toggleScreenshotLock(),
                  size: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
            smartModeChild: SmartImportSection(
              onGameAdded: widget.onGameAdded,
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 智能导入模式不需要底部操作按钮（操作在面板内完成）
        if (_currentMode != ImportMode.smart)
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

    // 入库前自动保存当前编辑
    if (_batchController.selectedGame != null) {
      _saveSingleToBatchGame();
    }

    await _batchController.submitBatchImport();

    // 入库完成后重置左侧表单
    _singleController.resetForm();
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
    return Stack(
      children: [
        // 遮罩从标题栏下方开始，确保标题栏在成功浮层显示时仍可交互
        Positioned(
          top: kTitleBarHeight,
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(color: Colors.black54),
        ),
        Positioned(
          top: kTitleBarHeight,
          left: 0,
          right: 0,
          bottom: 0,
          child: Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Opacity(
                  opacity: _opacityAnimation.value,
                  child: Transform.scale(
                    scale: _scaleAnimation.value,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 20),
                      decoration: BoxDecoration(
                        color: AppColors.successGreen, // 绿色背景
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.successGreen.withOpacity(0.4),
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
                              fontWeight: FontWeight.w500,
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
        ),
      ],
    );
  }
}
