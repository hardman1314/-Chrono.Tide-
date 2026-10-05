import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/portable_image_cache_manager.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import '../batch_import_controller.dart';
import '../join_controller.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_styles.dart';
import '../../../widgets/interactive_wrapper.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/nsfw/nsfw_image.dart';
import '../../../services/scan_logger.dart';
import 'platform_badge.dart';

class BatchImportSection extends StatefulWidget {
  final BatchImportController batchController;
  final JoinController singleController;

  /// ★ 2026-10-04 拖拽修复：仅在批量模式启用系统拖放监听。
  /// desktop_drop 的 DropTarget 不走 Flutter hitTest，SwipeSwitcher 的
  /// Stack 里隐藏页的 DropTarget 仍会收到系统拖放（与可见页完全重叠），
  /// 用 enable 互斥（任一时刻只有当前模式在监听）。
  final bool dropEnabled;

  const BatchImportSection({
    super.key,
    required this.batchController,
    required this.singleController,
    this.dropEnabled = true,
  });

  @override
  State<BatchImportSection> createState() => _BatchImportSectionState();
}

class _BatchImportSectionState extends State<BatchImportSection> {
  bool _isCenterIconHovered = false;
  bool _isDragging = false; // 新增：拖拽状态跟踪

  // ===== 扫描摘要可折叠状态 =====
  bool _isScanSummaryExpanded = true;
  Timer? _scanSummaryTimer;
  ScanSummary? _lastSeenSummary;

  // ===== 进度 ETA 追踪 =====
  DateTime? _progressStartTime;
  int _lastCompletedCount = 0;
  double _avgTimePerItem = 0; // 秒/项，EMA 平滑

  // ===== 新增按钮悬停 =====
  bool _isAddBtnHovered = false;

  @override
  void initState() {
    super.initState();
    widget.batchController.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _scanSummaryTimer?.cancel();
    widget.batchController.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// 监听 controller 变化：检测新扫描摘要到达 → 展开并启动自动收起计时
  void _onControllerChanged() {
    if (!mounted) return;
    final current = widget.batchController.lastScanSummary;
    if (current != null && !identical(current, _lastSeenSummary)) {
      // 新扫描摘要到达
      _lastSeenSummary = current;
      _isScanSummaryExpanded = true;
      _startScanSummaryTimer();
    } else if (current == null && _lastSeenSummary != null) {
      // 摘要被清空（新扫描开始）
      _lastSeenSummary = null;
      _isScanSummaryExpanded = true;
      _scanSummaryTimer?.cancel();
    }
    _updateProgressTracking();
  }

  void _startScanSummaryTimer() {
    _scanSummaryTimer?.cancel();
    _scanSummaryTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) {
        setState(() => _isScanSummaryExpanded = false);
      }
    });
  }

  void _toggleScanSummary() {
    setState(() {
      _isScanSummaryExpanded = !_isScanSummaryExpanded;
      if (_isScanSummaryExpanded) {
        _startScanSummaryTimer();
      } else {
        _scanSummaryTimer?.cancel();
      }
    });
  }

  /// 追踪进度起始时间和平均每项耗时（EMA 平滑），供 ETA 计算
  void _updateProgressTracking() {
    final isProcessing =
        widget.batchController.isProcessingQueue ||
            widget.batchController.isImporting;

    if (isProcessing && _progressStartTime == null) {
      _progressStartTime = DateTime.now();
      _lastCompletedCount = 0;
      _avgTimePerItem = 0;
    } else if (!isProcessing && _progressStartTime != null) {
      _progressStartTime = null;
      _lastCompletedCount = 0;
      _avgTimePerItem = 0;
    }

    if (_progressStartTime != null) {
      final completed = widget.batchController.isImporting
          ? widget.batchController.importProgressCurrent
          : widget.batchController.finishedCount;
      if (completed > _lastCompletedCount) {
        final elapsed =
            DateTime.now().difference(_progressStartTime!).inSeconds;
        if (completed > 0 && elapsed > 0) {
          final instantRate = elapsed / completed;
          _avgTimePerItem = _avgTimePerItem == 0
              ? instantRate
              : _avgTimePerItem * 0.7 + instantRate * 0.3;
        }
        _lastCompletedCount = completed;
      }
    }
  }

  /// 计算 ETA 文案
  String _getEtaText() {
    if (_progressStartTime == null || _avgTimePerItem == 0) return '';

    final ctrl = widget.batchController;
    final completed = ctrl.isImporting
        ? ctrl.importProgressCurrent
        : ctrl.finishedCount;
    final total = ctrl.isImporting
        ? ctrl.importProgressTotal
        : ctrl.totalCount;

    if (total <= 0) return '';
    final remaining = total - completed;
    if (remaining <= 0) return '即将完成';

    final etaSeconds = (_avgTimePerItem * remaining).round();
    if (etaSeconds < 30) return '即将完成';
    if (etaSeconds < 60) return '预计剩余 ${etaSeconds}秒';
    return '预计剩余 ${(etaSeconds / 60).ceil()}分钟';
  }

  /// 获取当前进度阶段的图标和标签
  ({IconData icon, String label, int current, int total}) _getPhaseInfo() {
    final ctrl = widget.batchController;
    if (ctrl.isImporting && ctrl.importProgressTotal > 0) {
      return (
        icon: Icons.save_outlined,
        label: '正在入库',
        current: ctrl.importProgressCurrent,
        total: ctrl.importProgressTotal,
      );
    }
    return (
      icon: Icons.cloud_download_outlined,
      label: '正在抓取元数据',
      current: ctrl.finishedCount,
      total: ctrl.totalCount,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.background,
        // 设计稿「Section - 待入库游戏列表」666×329，边框 0.93
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Column(
        children: [
          // 扫描摘要条：扫描完成后展示，7 秒后自动收起为迷你胶囊
          if (widget.batchController.lastScanSummary != null)
            _buildScanSummaryBanner(widget.batchController.lastScanSummary!),
          // 预览确认条：扫描后暂停，等待用户点击"开始处理"
          if (widget.batchController.isAwaitingConfirmation)
            _buildPreviewConfirmationBar()
          // 重新处理条（2026-10-03）：存在数据不全的游戏时，
          // 提供批量重新抓取元数据的入口（与预览条互斥）
          else if (widget.batchController.incompleteCount > 0)
            _buildReprocessBar(),
          Expanded(
            child: widget.batchController.hasGames
                ? _buildGamesList(context)
                : _buildEmptyState(context),
          ),
        ],
      ),
    );
  }

  /// 扫描摘要条（可折叠信息胶囊）
  ///
  /// 展开态：左侧 3px 彩色竖条 + 极淡背景 + 图标 + 完整文案，高度 ~32px
  /// 收起态：迷你胶囊，仅彩色圆点 + 浓缩文案，高度 ~24px
  /// - 有识别到游戏：绿色（successGreen）
  /// - 未识别到游戏：蓝色（infoBlue）
  /// 扫描完成后 7 秒自动收起，点击收起态可重新展开
  Widget _buildScanSummaryBanner(ScanSummary summary) {
    final hasAccepted = summary.accepted > 0;
    final accentColor =
        hasAccepted ? AppColors.successGreen : AppColors.infoBlue;
    // 收起态浓缩文案
    final collapsedText =
        hasAccepted ? '✓ ${summary.accepted} 个新游戏' : '未发现游戏';

    return GestureDetector(
      onTap: _toggleScanSummary,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 200),
          child: _isScanSummaryExpanded
              ? _buildExpandedSummary(summary, accentColor)
              : _buildCollapsedSummary(collapsedText, accentColor),
        ),
      ),
    );
  }

  /// 展开态：轻量化设计，左侧彩色竖条 + 极淡背景
  Widget _buildExpandedSummary(ScanSummary summary, Color accentColor) {
    final hasAccepted = summary.accepted > 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(4),
        // 左侧 3px 彩色竖条替代完整边框
        border: Border(
          left: BorderSide(color: accentColor, width: 3),
          top: BorderSide(color: accentColor.withOpacity(0.15), width: 0.5),
          bottom: BorderSide(color: accentColor.withOpacity(0.15), width: 0.5),
          right:
              BorderSide(color: accentColor.withOpacity(0.15), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasAccepted ? Icons.check_circle_outline : Icons.info_outline,
            size: 14,
            color: accentColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              summary.humanReadable,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.secondaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 收起指示
          Icon(Icons.keyboard_arrow_up, size: 14, color: AppColors.secondaryText),
        ],
      ),
    );
  }

  /// 收起态：迷你胶囊，彩色圆点 + 浓缩文案
  Widget _buildCollapsedSummary(String text, Color accentColor) {
    // 设计稿摘要胶囊 118×23：全圆角、左右内边距 9、上下 4，水平居中
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 7, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(11.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.secondaryText,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down,
              size: 12, color: AppColors.secondaryText),
        ],
      ),
    );
  }

  /// 预览确认条
  ///
  /// 扫描完成后展示，告知用户待处理游戏数量，并提供"开始处理"按钮。
  /// 用户确认后才触发元数据抓取（[BatchImportController.confirmAndProcess]）。
  /// 预览期间用户可点击卡片编辑、删除、修改路径。
  Widget _buildPreviewConfirmationBar() {
    final count = widget.batchController.pendingConfirmationCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.infoBlue.withOpacity(0.1),
        border: Border.all(color: AppColors.infoBlue, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.preview, size: 16, color: AppColors.infoBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已识别 $count 个游戏，请确认列表后开始处理',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.primaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          InteractiveWrapper(
            onTap: () => widget.batchController.confirmAndProcess(),
            hoverScale: 1.04,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.infoBlue,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Text('开始处理',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 重新处理条（2026-10-03）
  ///
  /// 存在数据不全的游戏（已完成但封面/简介缺失）时展示，
  /// 提供批量重新抓取元数据的入口（[BatchImportController.reprocessIncompleteGames]）。
  /// 与预览确认条互斥：预览态显示「开始处理」，处理后显示本条。
  Widget _buildReprocessBar() {
    final count = widget.batchController.incompleteCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.starGold.withOpacity(0.1),
        border: Border.all(color: AppColors.starGold, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: AppColors.starGold),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count 款游戏数据不全（缺封面/简介），已保留在列表',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.primaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          InteractiveWrapper(
            onTap: () =>
                widget.batchController.reprocessIncompleteGames(),
            hoverScale: 1.04,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.starGold,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Text('重新处理',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return DropTarget(
      enable: widget.dropEnabled,
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
                      fontSize: 24,
                      letterSpacing: 2.0,
                      color: AppColors.border)),
              const SizedBox(height: 8),
              Text('支持选择或拖入多个游戏文件夹',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText)),
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
              : AppColors.placeholderBg, // 默认时：米色
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
      enable: widget.dropEnabled,
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
              ? Border.all(color: AppColors.successGreen, width: 3) // 拖拽时：绿色边框
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 固定头部栏：新增按钮 + 游戏计数（不随列表滚动）
              _buildStickyAddHeader(),
              const SizedBox(height: 8),
              Expanded(
                // BatchGameCard 的 InteractiveWrapper 已关闭 hoverScale（1.0）
                // 和 hoverOffset（zero），从源头消除 transform 溢出，无需 Clip.none
                child: ListView.builder(
                  itemCount: widget.batchController.games.length,
                  itemBuilder: (context, index) {
                    final game = widget.batchController.games[index];
                    return Padding(
                      // 设计稿卡片间距 13（卡1 底 189 → 卡2 顶 202）
                      padding: const EdgeInsets.only(bottom: 13),
                      child: BatchGameCard(
                        game: game,
                        isSelected:
                            widget.batchController.selectedGame?.id == game.id,
                        onTap: () => widget.batchController.selectGame(game),
                        onDelete: () =>
                            widget.batchController.removeGame(game.id),
                        onConfirm: () =>
                            widget.batchController.confirmCurrentSelection(),
                        onRestore: () =>
                            widget.batchController.restoreSelectedGame(),
                        onToggleTitle: () => widget.batchController
                            .toggleTitlePreference(game.id),
                        onRetry: () =>
                            widget.batchController.retryGame(game.id),
                        onPathUpdate: (newPath) => widget.batchController
                            .updateGamePath(game.id, newPath),
                      ),
                    );
                  },
                ),
              ),
              // 进度条：元数据抓取 + 入库两阶段统一显示
              if (widget.batchController.isProcessingQueue ||
                  widget.batchController.isImporting)
                _buildProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  /// 固定头部栏：新增按钮 + 游戏计数
  ///
  /// 从原 ListView 第 0 项移出，改为列表区域上方的固定栏，
  /// 始终可见不随列表滚动。风格与游戏卡片协调（棕色边框，非蓝色）。
  Widget _buildStickyAddHeader() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isAddBtnHovered = true),
      onExit: (_) => setState(() => _isAddBtnHovered = false),
      child: GestureDetector(
        onTap: () => widget.batchController.pickFolders(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          // 设计稿「新增文件夹」栏 611.6×37.1：上下内边距 8、左右 14
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _isAddBtnHovered ? AppColors.cardHoverBg : AppColors.background,
            borderRadius: BorderRadius.circular(4),
            // 设计稿为四边完整 1px 浅边框 + 右下硬阴影（原实现仅底边框）
            border: Border.all(color: AppColors.borderLight, width: 1),
            boxShadow: [
              BoxShadow(
                color: AppColors.borderLight,
                offset: const Offset(2, 3),
                blurRadius: 0,
              )
            ],
          ),
          child: Row(
            children: [
              Icon(
                Icons.add,
                size: 16,
                color: _isAddBtnHovered
                    ? AppColors.infoBlue
                    : AppColors.secondaryText,
              ),
              const SizedBox(width: 6),
              Text(
                '新增文件夹',
                style: TextStyle(
                  fontSize: 15,
                  letterSpacing: 1.2,
                  color: _isAddBtnHovered
                      ? AppColors.infoBlue
                      : AppColors.secondaryText,
                ),
              ),
              const Spacer(),
              // 右侧游戏计数
              Text(
                '共 ${widget.batchController.games.length} 个',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.secondaryText,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 统一智能进度条
  ///
  /// 两阶段自适应：元数据抓取 / 入库
  /// 布局：图标+状态文字（左）+ ETA（右），下方 2px 细线进度条
  Widget _buildProgressIndicator() {
    final ctrl = widget.batchController;
    final phase = _getPhaseInfo();
    final eta = _getEtaText();
    final progress = ctrl.overallProgress;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文字行：图标 + 阶段标签 + 进度计数 + 当前游戏名（左） | ETA（右）
          Row(
            children: [
              Icon(phase.icon, size: 13, color: AppColors.infoBlue),
              const SizedBox(width: 5),
              Text(
                phase.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${phase.current}/${phase.total}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
              ),
              // 当前处理的游戏名（省略号截断）
              if (ctrl.batchStatusMessage.isNotEmpty &&
                  ctrl.batchStatusMessage != '准备就绪') ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '· ${ctrl.batchStatusMessage}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.secondaryText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              // ETA（右对齐）
              if (eta.isNotEmpty)
                Text(
                  eta,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w400,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 2px 细线进度条
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                backgroundColor: AppColors.buttonBackground,
                minHeight: 2,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.infoBlue),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BatchGameCard extends StatefulWidget {
  final BatchGameItem game;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onConfirm;
  final VoidCallback? onRestore;
  final VoidCallback? onToggleTitle; // 双标题切换
  final VoidCallback? onRetry; // 失败重试
  final ValueChanged<String>? onPathUpdate;

  const BatchGameCard({
    super.key,
    required this.game,
    this.isSelected = false,
    this.onTap,
    this.onDelete,
    this.onConfirm,
    this.onRestore,
    this.onToggleTitle,
    this.onRetry,
    this.onPathUpdate,
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
      hoverScale: 1.0,
      hoverOffset: Offset.zero,
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
            color: AppColors.background,
            border: Border.all(
              color: widget.isSelected
                  ? AppColors.infoBlue // 选中态：蓝色边框
                  : AppColors.border, // 普通态：棕色边框
              width: widget.isSelected ? 4 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.borderLight,
                offset: const Offset(2, 3),
                blurRadius: 0,
              )
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          // ★ 目录框不再独占第二行（原「信息行 + 路径框行」两行结构，路径框只占左半，
          // 右半大片留白，卡片被动撑到 ~102）。现改为「信息 : 目录框 = 2 : 1」同排，
          // 卡片高度收敛到 ~70~78，单屏可见卡片数明显增加（设计稿路径框也位于
          // 信息区右带、与信息同排而非独占一行）。
          constraints: const BoxConstraints(minHeight: 70),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildCoverImage(),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 2, child: _buildGameInfo()),
                    const SizedBox(width: 8),
                    // 目录框上移：与信息区同排停放，不再是独立一行
                    Expanded(flex: 1, child: _buildPathDisplay()),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildActionButtons(),
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
        color: AppColors.placeholderCover,
        border: Border.all(color: AppColors.border, width: 2),
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
        child: NsfwImage.file(
          widget.game.coverFilePath!,
          contentKind: NsfwContentKind.cover,
          fit: BoxFit.fill,
          child: Image.file(
            File(widget.game.coverFilePath!),
            fit: BoxFit.fill,
            // ★ 性能优化：卡片封面 44×58，限宽解码（132 = 44 × 3x DPR）
            cacheWidth: 132,
          ),
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
          // 刮削候选：URL 渲染，缓存落盘后按需补检（§7.1 风险🟠4）
          child: NsfwImage.network(
            coverUrl,
            contentKind: NsfwContentKind.cover,
            fit: BoxFit.fill,
            detectOnDemand: true,
            child: CachedNetworkImage(
            cacheManager: PortableImageCacheManager(),
            imageUrl: coverUrl,
            fit: BoxFit.fill,
            placeholder: (context, url) => Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppColors.border,
                ),
              ),
            ),
            errorWidget: (context, url, error) => Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 16, color: AppColors.border),
            ),
          ),
          ),
        );
      }
    }

    return Icon(Icons.image_outlined, size: 16, color: AppColors.border);
  }

  Widget _buildGameInfo() {
    // 只有在已抓取到元数据时才显示平台标签
    final hasMetadata =
        widget.game.metadata != null && widget.game.metadata!.isNotEmpty;

    // 平台徽章：复用共享 resolvePlatformBadge，修复原小写比较 bug
    // （原 `platform == 'vndb'` 用小写比较，但 displayName 返回 'VNDB' 大写，
    // 导致 isVndb 永远 false → 固定显示 'Bangumi'）
    final platform =
        hasMetadata ? (widget.game.metadata!['platform'] ?? 'Bangumi') : null;
    final badge = platform != null ? resolvePlatformBadge(platform) : null;
    final platformId =
        hasMetadata ? (widget.game.metadata!['platform_id'] ?? '') : '';
    final releaseDate =
        hasMetadata ? (widget.game.metadata!['release_date'] ?? '') : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 失败状态优先显示红色错误条（替代平台徽章位置）
        // 用户需求：对识别异常或元数据抓取失败的游戏提供明确提示
        if (widget.game.taskStatus == GameTaskStatus.failed &&
            widget.game.errorMessage != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.dangerRed.withOpacity(0.1),
              border: Border.all(color: AppColors.dangerRed, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 12, color: AppColors.dangerRed),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '处理失败: ${widget.game.errorMessage}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.dangerRed,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        // 数据不全提示条（2026-10-03）：封面/简介任一缺失，
        // 确认导入时会被拦截保留在列表，需补全或重试
        else if (widget.game.taskStatus == GameTaskStatus.completed &&
            widget.game.missingCoreFields.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.starGold.withOpacity(0.12),
              border: Border.all(color: AppColors.starGold, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 12, color: AppColors.starGold),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '数据不全: 缺${widget.game.missingCoreFields.join('、')}，'
                    '补全后确认导入或点重试',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.starGold,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        else if (hasMetadata && badge != null)
          Row(
            children: [
              PlatformBadgeWidget(badge: badge),
              const SizedBox(width: 6),
              Text(platformId,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText)),
            ],
          )
        else if (!hasMetadata)
          Container(
            height: 17, // 占位，保持布局一致
          ),
        const SizedBox(height: 3),
        // 双标题：主显示当前标题 + 切换按钮（若有元数据标题且不同）
        Row(
          children: [
            Expanded(
              child: Text(widget.game.gameName,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.titleBrown),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            // 排重警告徽章：紧凑放置在标题旁
            if (widget.game.duplicateWarning != null ||
                widget.game.isHardDuplicate)
              _buildDuplicateBadge(),
            if (widget.game.canToggleTitle) _buildTitleToggleButton(),
          ],
        ),
        // 双标题：下方小字显示另一个标题
        if (widget.game.canToggleTitle)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              widget.game.usingMetadataTitle
                  ? '原标题: ${widget.game.originalTitle}'
                  : '元数据: ${widget.game.metadataTitle}',
              style: TextStyle(
                fontSize: 10,
                color: AppColors.secondaryText,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 3),
        Text(releaseDate.isNotEmpty ? '$releaseDate发行' : '',
            style: TextStyle(
                fontSize: 12,
                color: AppColors.secondaryText)),
      ],
    );
  }

  /// 双标题切换按钮（小图标，点击在原标题/元数据标题间切换）
  Widget _buildTitleToggleButton() {
    return InteractiveWrapper(
      hoverScale: 1.1,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          _actionButtonClicked = true;
          widget.onToggleTitle?.call();
        },
        child: Tooltip(
          message:
              '切换标题（当前: ${widget.game.usingMetadataTitle ? "元数据标题" : "原标题"}）',
          child: Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.infoBlue, width: 1),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.swap_horiz,
              size: 12,
              color: AppColors.infoBlue,
            ),
          ),
        ),
      ),
    );
  }

  /// 排重警告徽章
  ///
  /// 当 [BatchGameItem.duplicateWarning] 非空或 [BatchGameItem.isHardDuplicate]
  /// 为 true 时展示于标题旁，提示该游戏可能与库中已有项重复。
  /// - 软警告（duplicateWarning 非空且非硬重复）：橙色徽章 + warning_amber 图标
  /// - 硬重复（isHardDuplicate）：红色徽章 + block 图标 + "元数据重复"
  Widget _buildDuplicateBadge() {
    final game = widget.game;
    final isHard = game.isHardDuplicate;
    final color = isHard ? AppColors.dangerRed : Colors.orange;
    final icon = isHard ? Icons.block : Icons.warning_amber;
    final text = isHard ? '元数据重复' : (game.duplicateWarning ?? '');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathDisplay() {
    final path = widget.game.folderPath;
    final displayPath =
        _truncatePath(path, maxStartLength: 20, maxEndLength: 15);

    return InteractiveWrapper(
      onTap: () {
        debugPrint('[BATCH] 路径框被点击: $path');
        _actionButtonClicked = true;
        _showPathEditDialog();
      },
      hoverScale: 1.02,
      child: Container(
        // 目录框现与信息区同排（宽度由外层 flex 2:1 决定），内部用 Expanded 文本把
        // ✎ 顶到右缘，与设计稿「文件夹图标 — 路径 — 编辑铅笔」三段式一致（框 144×25）。
        // width: infinity 是必需的：InteractiveWrapper 内层 AnimatedContainer(alignment)
        // 只给子级松约束，不显式撑满的话短路径会把框缩成一小块。
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 25),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.infoBlue, width: 1),
          borderRadius: BorderRadius.circular(3),
          color: AppColors.background,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 13, color: AppColors.infoBlue),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                displayPath,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.edit, size: 12, color: AppColors.infoBlue),
          ],
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
    final textController = TextEditingController(text: widget.game.folderPath);
    String? validationError;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              title: Text('修改游戏路径'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前路径:',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.secondaryText)),
                    const SizedBox(height: 4),
                    SelectableText(
                      widget.game.folderPath,
                      style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 16),
                    Text('输入新路径:',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.secondaryText)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: textController,
                      decoration: InputDecoration(
                        hintText: '输入或粘贴游戏目录路径',
                        hintStyle: TextStyle(
                            fontSize: 12, color: AppColors.secondaryText),
                        border: OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        errorText: validationError,
                      ),
                      style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      onChanged: (_) {
                        if (validationError != null) {
                          setState(() => validationError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 14, color: AppColors.secondaryText),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '可手动输入路径或点击右侧按钮浏览选择',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.secondaryText),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () async {
                            final result =
                                await FilePicker.platform.getDirectoryPath(
                              dialogTitle: '选择游戏目录',
                              initialDirectory: widget.game.folderPath,
                            );

                            if (result != null && mounted) {
                              setState(() {
                                textController.text = result;
                                validationError = null;
                              });
                            }
                          },
                          icon: Icon(Icons.folder_open, size: 18),
                          label: Text('浏览'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.infoBlue,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final path = textController.text.trim();
                    if (path.isEmpty) {
                      setState(() => validationError = '路径不能为空');
                      return;
                    }
                    // 验证目录是否存在
                    if (!Directory(path).existsSync()) {
                      setState(() => validationError = '目录不存在，请检查路径');
                      return;
                    }
                    Navigator.of(dialogContext).pop(path);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.infoBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: Text('确认'),
                ),
              ],
            );
          },
        );
      },
    ).then((selectedPath) {
      textController.dispose();
      if (selectedPath != null && selectedPath is String) {
        debugPrint('[BATCH] 用户选择了新路径: $selectedPath');
        widget.onPathUpdate?.call(selectedPath);
      }
    });
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isSelected) _buildRestoreButton(),
        if (widget.isSelected) const SizedBox(width: 8),
        if (widget.isSelected) _buildConfirmButton(),
        // 失败状态显示重试按钮（错误处理机制）
        if (widget.game.taskStatus == GameTaskStatus.failed) ...[
          const SizedBox(width: 8),
          _buildRetryButton(),
        ],
        const SizedBox(width: 8),
        _buildDeleteButton(),
      ],
    );
  }

  /// 重试按钮（失败状态显示，点击重新处理该游戏）
  Widget _buildRetryButton() {
    return InteractiveWrapper(
      hoverScale: 1.1,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          _actionButtonClicked = true;
          widget.onRetry?.call();
        },
        child: Tooltip(
          message: widget.game.errorMessage != null
              ? '重试 (错误: ${widget.game.errorMessage})'
              : '重试',
          child: Container(
            width: 29,
            height: 29,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.infoBlue, width: 2),
              boxShadow: [
                BoxShadow(
                    color: AppColors.shadowColor,
                    offset: const Offset(2, 3),
                    blurRadius: 0)
              ],
            ),
            alignment: Alignment.center,
            child: Icon(Icons.refresh, size: 16, color: AppColors.infoBlue),
          ),
        ),
      ),
    );
  }

  Widget _buildRestoreButton() {
    // 只有存在原始快照且数据已被修改时才显示恢复按钮
    final game = widget.game;
    final hasChanges = game.hasOriginalSnapshot &&
        (game.gameName != game.originalGameName ||
            game.developer != game.originalDeveloper ||
            game.description != game.originalDescription);

    if (!hasChanges) return const SizedBox.shrink();

    return InteractiveWrapper(
      hoverScale: 1.1,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (event) {
          _actionButtonClicked = true;
          widget.onRestore?.call();
        },
        child: Container(
          width: 29,
          height: 29,
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: const Color(0x1A000000), width: 2),
            boxShadow: [
              BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ],
          ),
          alignment: Alignment.center,
          child: Tooltip(
            message: '恢复原始数据',
            child: Icon(Icons.restore, size: 16, color: AppColors.infoBlue),
          ),
        ),
      ),
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
                color: AppColors.background,
                border: Border.all(color: const Color(0x1A000000), width: 2),
                boxShadow: [
                  BoxShadow(
                      color: AppColors.shadowColor,
                      offset: const Offset(2, 3),
                      blurRadius: 0)
                ],
              ),
              alignment: Alignment.center,
              child: Icon(
                  _showSavedFeedback ? Icons.check_circle : Icons.check_rounded,
                  size: 18,
                  color: _showSavedFeedback
                      ? AppColors.successGreen
                      : AppColors.successGreen),
            ),
            if (_showSavedFeedback)
              Positioned(
                top: -32,
                left: -20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.successGreen,
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
                              fontSize: 12,
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
        onPointerUp: (event) async {
          _actionButtonClicked = true;
          // UX-06: 从批量列表中移除游戏前确认
          final confirmed = await showConfirmDialog(
            context: context,
            title: '移除游戏',
            message: '确定要从批量列表中移除「${widget.game.gameName ?? '未命名游戏'}」吗？',
            hint: '已填写的信息将丢失，需要重新添加。',
            confirmText: '移除',
            isDanger: true,
          );
          if (!mounted || !confirmed) return;
          widget.onDelete?.call();
        },
        child: Container(
          width: 29,
          height: 29,
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: const Color(0x1A000000), width: 2),
            boxShadow: [
              BoxShadow(
                  color: AppColors.shadowColor,
                  offset: const Offset(2, 3),
                  blurRadius: 0)
            ],
          ),
          alignment: Alignment.center,
          child: Icon(Icons.close_rounded, size: 18, color: AppColors.border),
        ),
      ),
    );
  }
}
