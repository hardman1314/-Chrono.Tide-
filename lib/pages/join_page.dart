import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../theme/app_colors.dart';
import 'join/join_gamepad_actions.dart';
import 'join/widgets/archive_plan_dialog.dart'
    show showArchivePlanDialog;
import '../widgets/screenshot_carousel.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/interactive_wrapper.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/custom_title_bar.dart' show kTitleBarHeight;
import 'join/join_controller.dart';
import 'join/batch_import_controller.dart';
import '../models/watch_folder.dart';
import '../services/watch_folder_service.dart';
import 'join/widgets/form_inputs.dart';
import 'join/widgets/field_lock_button.dart';
import 'join/widgets/metadata_section.dart';
import 'join/widgets/file_drop_zone.dart';
import 'join/widgets/action_buttons.dart';
import 'join/widgets/join_help_dialog.dart'
    show showJoinHelpDialog;
import 'join/widgets/swipe_switcher.dart';
import 'join/widgets/batch_import_section.dart';
import 'join/widgets/smart_import_section.dart';

class JoinPage extends StatefulWidget {
  final VoidCallback? onGameAdded;
  final BatchImportController? batchController; // 新增：全局持久化控制器

  /// 是否提供「智能导入」模式 (BPM 大屏模式传 false 以隐藏该入口,桌面默认 true 不变)
  final bool enableSmartImport;

  /// 初始导入模式 (BPM 从模式选择弹窗进入时指定;默认单文件,桌面行为不变)
  final ImportMode initialMode;

  /// BPM 手柄操作条注入点（v3.10.3，桌面传 null）
  ///
  /// 🔴 为什么需要：本页复用的全部桌面控件都建立在
  /// `lib/widgets/interactive_wrapper.dart` 的 `InteractiveWrapper` /
  /// `HoverButton` 之上，而那个基座里**没有任何 `Focus`** —— 它只处理鼠标
  /// hover / tap，完全不在 Flutter 焦点树里。于是手柄的落焦
  /// （`findFirstFocus`）与方向遍历（`inDirection`）根本"看不见"
  /// 「文件拖放区」「确认入库」「取消」，BPM 里用手柄打开导入窗口后除了
  /// TextField 之外无处可落焦。
  ///
  /// 解法不是在 BPM 侧重写一套导入 UI（会出现两套逻辑），而是让本页把
  /// **它自己的**动作以 [JoinGamepadActions] 交出去，由 BPM 渲染一条可聚焦
  /// 的操作条 —— 手柄按钮与桌面按钮调用**同一个方法**。
  ///
  /// 为 null（桌面默认）→ 不渲染任何东西，布局与行为逐位不变。
  final Widget Function(JoinGamepadActions actions)? gamepadActionBar;

  const JoinPage({
    super.key,
    this.onGameAdded,
    this.batchController,
    this.enableSmartImport = true,
    this.initialMode = ImportMode.single,
    this.gamepadActionBar,
  });

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  late JoinController _singleController;
  late BatchImportController _batchController;
  ImportMode _currentMode = ImportMode.single;

  @override
  void initState() {
    super.initState();
    _currentMode = widget.initialMode;

    _singleController = JoinController(
      onGameAdded: widget.onGameAdded,
      onError: _showErrorSnackBar,
      onSuccess: _showSuccessSnackBar,
      onWarning: _showWarningSnackBar,
      onInfo: _showInfoSnackBar,
    );

    // ★ 2026-10-04 智能解压：注入解压计划弹窗钩子（controller 不持
    //   BuildContext，弹窗统一由页面层提供）。
    //   （解压流水线 C4：执行期决策弹窗与完成确认窗已迁至安装中心 +
    //   main_container 注入，此处仅保留计划窗。）
    _singleController.archivePlanProvider = (archivePath) async {
      if (!mounted) return null;
      return showArchivePlanDialog(context, archivePath: archivePath);
    };

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
      _batchController.addListener(_onBatchControllerChanged);
    });

    // ★ 2026-10-05 流程语义修正（解压完成≠入库）：订阅安装中心交接通道。
    //   JoinPage 由 Offstage 保活（State 常驻、initState 只跑一次），
    //   因此交接用 JoinController 的静态 ValueNotifier 通道：
    //   main_container 收到 onUnpackReadyForManualImport 后写入值并切页，
    //   本监听消费后立即置 null（一次性信箱）。
    JoinController.pendingExtractedDir.addListener(_consumePendingExtractedDir);
  }

  /// 消费安装中心交接的解压产物目录（一次性信箱，见 initState 注释）
  void _consumePendingExtractedDir() {
    final dir = JoinController.pendingExtractedDir.value;
    if (dir == null || dir.isEmpty) return;
    JoinController.pendingExtractedDir.value = null;
    if (!mounted) return;
    if (_currentMode != ImportMode.single) {
      setState(() => _currentMode = ImportMode.single);
    }
    _singleController.receiveExtractedDirectory(dir);
  }

  /// 批量控制器变化回调（★ IMP-15）
  ///
  /// 必须持有具名引用：`_batchController` 是由 MainContainer 持有的**全局**
  /// 控制器，寿命长于本页面；若用匿名闭包注册且 dispose 时不注销，
  /// 页面卸载后仍会收到通知 —— 导致 `setState() after dispose`、
  /// 在已废弃的表单上触发网络封面下载，并让整个 State 无法回收。
  void _onBatchControllerChanged() {
    if (!mounted) return;
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
  }

  @override
  void dispose() {
    // ★ IMP-15: 注销全局批量控制器的监听（否则页面卸载后仍被回调）
    _batchController.removeListener(_onBatchControllerChanged);
    // ★ 2026-10-05 流程语义修正：注销解压交接信箱监听
    JoinController.pendingExtractedDir
        .removeListener(_consumePendingExtractedDir);
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

    // 副标题同步：从 BatchGameItem 恢复副标题（日文原版标题）
    _singleController.subtitleController.text = batchGame.subtitle ?? '';

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

  // ==================== 智能导入：表单联动 ====================

  /// 智能导入：候选数据同步到左侧表单（对齐批量导入联动体验）
  ///
  /// 点击发现队列中就绪/失败的候选卡片时调用。
  void _syncCandidateToSingleForm(ImportCandidate candidate) {
    _singleController.bumpGeneration(); // 强制重建左侧UI，防止切换时Element累积
    _singleController.nameController.text = candidate.title;
    _singleController.tagsController.text = candidate.tags.join(', ');
    _singleController.descController.text = candidate.description;
    _singleController.developerController.text = candidate.developer;
    _singleController.subtitleController.text = candidate.subtitle;

    // 双标题同步：文件夹原标题 ↔ 元数据标题，支持 NameInput 切换
    _singleController.setTitles(
      original:
          candidate.title.isNotEmpty ? candidate.title : candidate.originalTitle,
      metadata: candidate.metadataTitle,
      useMetadata: false,
    );

    // 清理之前的元数据抓取结果，避免残留上一个候选的数据
    _singleController.clearScrapeResults();

    // 恢复截图（必须放在 clearScrapeResults 之后）
    _singleController.restoreScreenshotUrls(candidate.screenshotUrls);

    // 设置封面（本地临时文件优先，其次从网络URL下载）
    if (candidate.coverFilePath != null &&
        candidate.coverFilePath!.isNotEmpty &&
        File(candidate.coverFilePath!).existsSync()) {
      _singleController.setCoverFilePath(candidate.coverFilePath);
    } else if (candidate.coverUrl != null) {
      _singleController.downloadAndSetCover(candidate.coverUrl!);
    } else {
      _singleController.removeCover();
    }
  }

  /// 智能导入：左侧表单编辑保存回候选（切换选中 / 入库前调用）
  void _saveSingleToCandidate(ImportCandidate candidate) {
    final name = _singleController.nameController.text.trim();
    if (name.isNotEmpty) {
      candidate.title = name;
    }
    candidate.tags = _singleController.tagsController.text
        .split(RegExp(r'[,\s，、]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    candidate.description = _singleController.descController.text.trim();
    candidate.developer = _singleController.developerController.text.trim();
    candidate.subtitle = _singleController.subtitle;

    // 双标题回写（表单中切换过标题或重新抓取时生效）
    final metadataTitle = _singleController.metadataTitle;
    if (metadataTitle != null && metadataTitle.isNotEmpty) {
      candidate.metadataTitle = metadataTitle;
    }

    // 封面回写：表单本地封面优先
    final cover = _singleController.coverFilePath;
    if (cover != null && cover.isNotEmpty) {
      candidate.coverFilePath = cover;
    }

    // 截图回写：ImportCandidate.screenshotUrls 派生自 metadata
    final shots = _singleController.screenshotUrls;
    if (shots.isNotEmpty) {
      candidate.metadata ??= <String, dynamic>{};
      candidate.metadata!['screenshot_urls'] = shots;
    }

    // 用户通过表单重新抓取选择了新元数据 → 合并到候选 metadata
    final scrapeResult = _singleController.selectedResult;
    if (scrapeResult != null) {
      candidate.metadata ??= <String, dynamic>{};
      final m = candidate.metadata!;
      for (final key in const [
        'game_name',
        'platform',
        'platform_id',
        'cover_url',
        'release_date',
      ]) {
        if (scrapeResult[key] != null) {
          m[key] = scrapeResult[key];
        }
      }
      if (scrapeResult['tags'] != null) {
        m['tags'] = scrapeResult['tags'];
      }
      final scrapedName = scrapeResult['game_name']?.toString();
      if (scrapedName != null && scrapedName.isNotEmpty) {
        candidate.metadataTitle = scrapedName;
      }
    }

    // ★ 候选队列已内存化（2026-10-03）：用户编辑只改内存对象，
    //   本会话内实时可见；不再落盘（原 persistCandidates 调用已删）。
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
      // 副标题回写：同步单文件模式下编辑的副标题
      subtitle: _singleController.subtitle,
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

    // 从智能导入模式切出时，保存候选编辑并重置表单
    if (_currentMode == ImportMode.smart && mode != ImportMode.smart) {
      final selected = WatchFolderService.instance.selectedCandidate;
      if (selected != null) {
        _saveSingleToCandidate(selected);
        WatchFolderService.instance.selectCandidate(null);
      }
      _singleController.resetForm();
    }

    // 切入智能导入模式时，若有选中的候选则恢复其表单数据
    if (mode == ImportMode.smart) {
      final selected = WatchFolderService.instance.selectedCandidate;
      if (selected != null) {
        _syncCandidateToSingleForm(selected);
      }
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_singleController, _batchController]),
      builder: (context, child) {
        final body = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLeftColumn(),
            const SizedBox(width: 20),
            Expanded(flex: 7, child: _buildRightColumn()),
          ],
        );

        return Container(
          width: double.infinity,
          height: double.infinity,
          color: AppColors.pageBackground,
          padding: const EdgeInsets.all(24),
          // v3.10.3: BPM 手柄操作条。gamepadActionBar 为 null 时
          // **这一层 Column 整体不存在** —— 桌面布局与改动前逐位一致。
          child: widget.gamepadActionBar == null
              ? body
              : Column(
                  children: <Widget>[
                    widget.gamepadActionBar!(
                      JoinGamepadActions(
                        mode: _currentMode,
                        single: _singleController,
                        batch: _batchController,
                        submitBatch: _submitBatchImport,
                        cancel: _handleCancel,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(child: body),
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
              // 设计稿：封面框右缘 246 → 字段列左缘 257，视觉间隙 11
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  children: [
                    NameInput(controller: _singleController),
                    // 设计稿字段行距 5.7（名称→副标题→标签→开发商，合计 206）
                    const SizedBox(height: 5),
                    TagsInput(controller: _singleController),
                    const SizedBox(height: 5),
                    DeveloperInput(controller: _singleController),
                  ],
                ),
              ),
            ],
          ),
          // 走查调整：截图区上移，与封面·字段列的间距收紧（8 → 5）
          const SizedBox(height: 5),
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
          const SizedBox(height: 6),
          // 简介占满左栏剩余高度：上面每省 1px 都转化为简介可用区
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
            singleModeChild: FileDropZone(
              controller: _singleController,
              // ★ 拖拽互斥：desktop_drop 不走 hitTest，Stack 里隐藏页的
              //   DropTarget 仍会收系统拖放 → 任一时刻只启用当前模式。
              dropEnabled: _currentMode == ImportMode.single,
              // ★ 2026-10-05 需求修正：两个按钮放置入板块【内部右下角】
              //  （而非页面底部操作行），有文件后仍常驻显示。
              bottomRightActions: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildLightweightButton(
                    icon: Icons.help_outline_rounded,
                    label: '使用说明',
                    onTap: () => showJoinHelpDialog(context),
                  ),
                  const SizedBox(width: 8),
                  _buildLightweightButton(
                    icon: Icons.tune_rounded,
                    label: '打开解压计划窗口',
                    onTap: _openArchivePlanSettings,
                  ),
                ],
              ),
            ),
            batchModeChild: BatchImportSection(
              batchController: _batchController,
              singleController: _singleController,
              dropEnabled: _currentMode == ImportMode.batch,
            ),
            smartModeChild: widget.enableSmartImport
                ? SmartImportSection(
                    onGameAdded: widget.onGameAdded,
                    // 表单联动：点击候选 → 同步左侧表单；编辑 → 入库/切换时自动保存
                    onCandidateSelected: _syncCandidateToSingleForm,
                    onSaveFormEdits: _saveSingleToCandidate,
                    onFormReset: () => _singleController.resetForm(),
                  )
                // null = 不提供智能导入 (SwipeSwitcher 会隐藏对应按钮)
                : null,
          ),
        ),
        const SizedBox(height: 16),
        // 智能导入模式不需要底部操作按钮（操作在面板内完成）
        // ★ 2026-10-05 修正：「使用说明/打开解压计划窗口」已移入置入板块
        //   内部右下角（FileDropZone.bottomRightActions），此处恢复原布局。
        if (_currentMode != ImportMode.smart)
          ActionButtons(
            controller:
                _currentMode == ImportMode.single ? _singleController : null,
            // ★ IMP-09: 处理队列运行中禁用批量提交（否则 clearAll 掐断批次循环）
            submitEnabled: !_batchController.isProcessingQueue,
            onBatchSubmit: _currentMode == ImportMode.batch
                ? () => _submitBatchImport()
                : null,
            onBatchCancel: _currentMode == ImportMode.batch
                ? () {
                    _batchController.clearAll();
                    _singleController.resetForm();
                  }
                : null,
            // 与 BPM 手柄操作条共用同一条取消路径（含二次确认）
            onCancel: _handleCancel,
          ),
      ],
    );
  }

  /// ★ 2026-10-05 需求 #2：打开解压计划窗口（纯设置模式，无需先选压缩包）。
  /// 两板块配置在操作时即时写入 UnpackStore，「保存」即生效。
  Future<void> _openArchivePlanSettings() async {
    await showArchivePlanDialog(context, archivePath: null);
  }

  /// 轻量化小按钮（需求 #2：尺寸不宜过大）
  Widget _buildLightweightButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: AppColors.infoBlue),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11, color: AppColors.secondaryText)),
          ],
        ),
      ),
    );
  }

  Future<void> _submitBatchImport() async {
    if (!_batchController.hasGames) {
      _showWarningSnackBar('请先置入游戏文件夹');
      return;
    }

    // ★ IMP-09（2026-09-12 导入审查）：元数据抓取队列仍在跑时禁止入库。
    // 提交末尾的 clearAll() 会置 _isDisposed = true，直接掐断仍在执行的批次循环，
    // 未处理完的游戏既不入库也不会有任何提示。
    if (_batchController.isProcessingQueue) {
      _showWarningSnackBar('正在抓取元数据，请等待处理完成后再入库');
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

  /// 取消（带二次确认）。
  ///
  /// 🔴 单一实现：桌面「取消」按钮（[ActionButtons.onCancel]）与 BPM 手柄
  /// 操作条都走这里，避免两套确认文案 / 两套清理口径分叉。
  Future<void> _handleCancel() async {
    final isBatchMode = _currentMode == ImportMode.batch;
    final confirmed = await showConfirmDialog(
      context: context,
      title: '确认取消',
      message: isBatchMode
          ? '确定要清空批量列表吗？所有已添加的游戏将被移除。'
          : '确定要取消当前操作吗？已填写的表单内容将被清空。',
      confirmText: '取消操作',
      isDanger: true,
    );
    if (!mounted || !confirmed) return;
    if (isBatchMode) {
      _batchController.clearAll();
      _singleController.resetForm();
    } else {
      _singleController.cancelAndReset();
    }
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
