import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/portable_image_cache_manager.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/global_install_center.dart';
import '../widgets/download_button.dart';
import '../widgets/download_progress_bar.dart';
import '../widgets/interactive_wrapper.dart';
import '../widgets/custom_title_bar.dart' show kTitleBarHeight;
import '../widgets/nsfw/nsfw_image.dart';

class InstallCenterPage extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback? onRetry;

  const InstallCenterPage({super.key, required this.onClose, this.onRetry});

  @override
  State<InstallCenterPage> createState() => _InstallCenterPageState();
}

class _InstallCenterPageState extends State<InstallCenterPage> {
  InstallPhase _phase = InstallPhase.idle;
  InstallProgress _progress = const InstallProgress();
  String? _errorMessage;

  // ★ 2026-10-05 需求 #6：系统操作日志面板（标题与进度条之间，可收起；
  // 仅内存展示不落盘）。面板语义 = 当前任务的操作日志（新任务开始时
  // 服务层已清空缓冲）。
  List<String> _opLogLines = const [];
  bool _opLogCollapsed = false;
  final ScrollController _opLogScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _syncFromGlobal();
    _opLogLines = GlobalInstallCenter.instance.opLog;
    GlobalInstallCenter.instance
        .addListener(phase: _onPhaseChanged, progress: _onProgressChanged);
    GlobalInstallCenter.instance.addQueueListener(_onQueueChanged);
    GlobalInstallCenter.instance.addOpLogListener(_onOpLogChanged);
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance.removeListener(
      phase: _onPhaseChanged,
      progress: _onProgressChanged,
    );
    GlobalInstallCenter.instance.removeQueueListener(_onQueueChanged);
    GlobalInstallCenter.instance.removeOpLogListener(_onOpLogChanged);
    _opLogScrollCtrl.dispose();
    super.dispose();
  }

  /// 操作日志变更：刷新列表并滚到底部（最新动作可见）
  void _onOpLogChanged() {
    if (!mounted) return;
    setState(() {
      _opLogLines = GlobalInstallCenter.instance.opLog;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _opLogCollapsed ||
          !_opLogScrollCtrl.hasClients) {
        return;
      }
      _opLogScrollCtrl.jumpTo(_opLogScrollCtrl.position.maxScrollExtent);
    });
  }

  /// 队列变更（入队/出队/移除/清空）时刷新队列列表
  void _onQueueChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _syncFromGlobal() {
    final center = GlobalInstallCenter.instance;
    setState(() {
      _phase = center.phase;
      _progress = center.progress;
      _errorMessage = center.errorMessage;
    });
  }

  void _onPhaseChanged(InstallPhase newPhase) {
    if (!mounted) return;
    setState(() {
      _phase = newPhase;
      _errorMessage = GlobalInstallCenter.instance.errorMessage;
    });
  }

  void _onProgressChanged(InstallProgress newProgress) {
    if (!mounted) return;
    setState(() {
      _progress = newProgress;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 遮罩从标题栏下方开始，确保标题栏在安装中心打开时仍可交互
        Positioned(
          top: kTitleBarHeight,
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(color: Colors.black54),
        ),
        // 内容区同样从标题栏下方开始
        Positioned(
          top: kTitleBarHeight,
          left: 0,
          right: 0,
          bottom: 0,
          child: Center(
            child: Padding(
              // UX-07: 留出边距并约束最大尺寸，窄窗口下自适应收缩避免溢出
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 900,
                  maxHeight: 580,
                ),
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border, width: 1.6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        offset: const Offset(4, 8),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.hardEdge,
                  // 🔴 本页由 `main_container._openInstallCenter` 挂在**裸
                  // `OverlayEntry`** 上，没有 `Material` 祖先 ⇒ 不包这一层的话，
                  // 页内未显式设置 style 的 `Text` 会继承 `MaterialApp` 的兜底
                  // `_errorTextStyle`（纯黄双下划线）。详见
                  // `widgets/game_detail/dark_surface.dart` 顶部同一说明。
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      children: [
                        _buildHeader(),
                        Expanded(child: _buildContent()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          bottom: BorderSide(color: AppColors.borderLight, width: 0.8),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                Icons.download_rounded,
                size: 22,
                color: AppColors.border,
              ),
              const SizedBox(width: 10),
              Text(
                '全局安装中心',
                style: AppStyles.titleLarge.copyWith(
                  fontSize: 18,
                  letterSpacing: 1.5,
                ),
              ),
              if (_phase != InstallPhase.idle &&
                  _phase != InstallPhase.completed &&
                  _phase != InstallPhase.failed) ...[
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _phase == InstallPhase.downloading
                        ? AppColors.infoBlue.withOpacity(0.12)
                        : const Color(0xFFD4A017).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _phase == InstallPhase.downloading
                        ? '下载中'
                        : _phase == InstallPhase.awaitingConfirmation
                            ? '待确认'
                            : '解压中',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _phase == InstallPhase.downloading
                          ? AppColors.infoBlue
                          : const Color(0xFFD4A017),
                    ),
                  ),
                ),
              ],
            ],
          ),
          InteractiveWrapper(
            onTap: widget.onClose,
            hoverScale: 1.1,
            child: Container(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final task = GlobalInstallCenter.instance.currentTask;
    final center = GlobalInstallCenter.instance;

    // 队列非空时即使无活跃任务（推进间隙）也展示队列区
    if ((task == null || _phase == InstallPhase.idle) && center.queueLength == 0) {
      return _buildIdleView();
    }

    if (task == null || _phase == InstallPhase.idle) {
      // 推进间隙：仅显示队列
      return Padding(
        padding: const EdgeInsets.all(32),
        child: _buildQueueSection(),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLeftSection(task),
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildRightSection()),
                if (center.queueLength > 0) ...[
                  const SizedBox(height: 12),
                  _buildQueueSection(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 安装队列区：展示排队任务列表，支持单项移除与一键清空
  Widget _buildQueueSection() {
    final center = GlobalInstallCenter.instance;
    final queued = center.queuedTasks;

    return Container(
      constraints: const BoxConstraints(maxHeight: 168),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.playlist_play_rounded,
                    size: 16,
                    color: AppColors.secondaryText,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '安装队列 (${queued.length})',
                    style: AppStyles.bodyRegular.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '任务将依次自动安装',
                    style: AppStyles.bodyRegular.copyWith(
                      fontSize: 11,
                      color: AppColors.secondaryText.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
              InteractiveWrapper(
                onTap: () => center.clearQueue(),
                hoverScale: 1.05,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.delete_sweep_outlined,
                        size: 14,
                        color: AppColors.secondaryText.withOpacity(0.7),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '清空',
                        style: AppStyles.bodyRegular.copyWith(
                          fontSize: 12,
                          color: AppColors.secondaryText.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: queued.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final task = queued[index];
                return _buildQueueItem(task, index + 1);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 单个排队任务项：序号 + 小封面 + 标题 + 移除按钮
  Widget _buildQueueItem(InstallTask task, int position) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderLight, width: 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '$position',
              textAlign: TextAlign.center,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 小封面
          Container(
            width: 28,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.placeholderCover,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: AppColors.borderLight, width: 1),
            ),
            clipBehavior: Clip.hardEdge,
            child: (task.coverUrl != null && task.coverUrl!.startsWith('http'))
                ? NsfwImage.network(
                    task.coverUrl!,
                    contentKind: NsfwContentKind.cover,
                    fit: BoxFit.cover,
                    showBadge: false,
                    // 安装中心封面只走服务器 URL，全量扫描覆盖不到，
                    // 必须开按需检测（child 走便携缓存，检测靠它查落盘文件）。
                    detectOnDemand: true,
                    child: CachedNetworkImage(
                      cacheManager: PortableImageCacheManager(),
                      imageUrl: task.coverUrl!,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 13,
                color: AppColors.primaryText,
              ),
            ),
          ),
          const SizedBox(width: 8),
          InteractiveWrapper(
            onTap: () =>
                GlobalInstallCenter.instance.removeQueuedTask(task.gameId),
            hoverScale: 1.1,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 64,
            color: AppColors.secondaryText.withOpacity(0.2),
          ),
          const SizedBox(height: 16),
          Text(
            '当前无安装任务',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 16,
              color: AppColors.secondaryText.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '前往探索页点击游戏详情中的"安装"按钮开始',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 13,
              color: AppColors.secondaryText.withOpacity(0.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftSection(InstallTask task) {
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: -2 * 3.14159 / 180,
            child: Container(
              width: 216,
              height: 323,
              decoration: BoxDecoration(
                color: AppColors.placeholderCover,
                border: Border.all(color: AppColors.border, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.border,
                    offset: const Offset(4, 5),
                    blurRadius: 0,
                  ),
                ],
              ),
              clipBehavior: Clip.hardEdge,
              child: Stack(
                fit: StackFit.expand,
                children: [_buildCoverImage(task.coverUrl)],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            task.title,
            textAlign: TextAlign.center,
            style: AppStyles.titleLarge.copyWith(fontSize: 24),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.tags != null && task.tags!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: task.tags!
                  .take(3)
                  .map((tag) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.buttonBackground,
                          border: Border.all(color: AppColors.border, width: 1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          tag,
                          style: AppStyles.bodyRegular.copyWith(fontSize: 11),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverImage(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty || !coverUrl.startsWith('http')) {
      return Container(
        color: AppColors.placeholderCover,
        child: Center(
          child: Icon(
            Icons.image_outlined,
            size: 48,
            color: AppColors.secondaryText.withOpacity(0.25),
          ),
        ),
      );
    }

    return NsfwImage.network(
      coverUrl,
      contentKind: NsfwContentKind.cover,
      fit: BoxFit.cover,
      // 详情大图同样只走服务器 URL，须开按需检测（child 走便携缓存）。
      detectOnDemand: true,
      child: CachedNetworkImage(
        cacheManager: PortableImageCacheManager(),
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => Container(
          color: AppColors.placeholderCover,
          child: Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: 40,
              color: AppColors.secondaryText.withOpacity(0.2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightSection() {
    switch (_phase) {
      case InstallPhase.idle:
        return const SizedBox.shrink();

      case InstallPhase.downloading:
        return _buildDownloadingUI();

      case InstallPhase.extracting:
        return _buildExtractingUI();

      // ★ 解压流水线（§C5）：本地解压完成后等待用户在确认入库弹窗决策；
      // 弹窗关闭（放弃入库）后任务转 completed，此 UI 只在挂起间隙可见。
      case InstallPhase.awaitingConfirmation:
        return _buildAwaitingConfirmationUI();

      case InstallPhase.completed:
        return _buildCompletedUI();

      case InstallPhase.failed:
        return _buildFailedUI();

      case InstallPhase.cancelled:
        return _buildCancelledUI();
    }
  }

  Widget _buildDownloadingUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.77,
            child: Text(
              '正 在 下 载',
              style: TextStyle(
                fontSize: 30,
                letterSpacing: 2.0,
                color: AppColors.border,
              ),
            ),
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: 465,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Opacity(
                      opacity: 0.8,
                      child: Text(
                        '下载速度: ${_progress.downloadSpeed}',
                        style: TextStyle(
                          fontSize: 16,
                          height: 24 / 16,
                          color: AppColors.titleBrown,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${_progress.downloadPercent.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 24,
                        height: 32 / 24,
                        letterSpacing: 1.2,
                        color: AppColors.titleBrown,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DownloadProgressBar(
                  progress: _progress.downloadPercent / 100,
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          DownloadButton(
            onTap: () => GlobalInstallCenter.instance.cancelCurrentTask(),
            isDownloading: true,
          ),
        ],
      ),
    );
  }

  Widget _buildExtractingUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.77,
            child: Text(
              '正 在 解 压',
              style: TextStyle(
                fontSize: 30,
                letterSpacing: 2.0,
                color: AppColors.border,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildOpLogPanel(),
          const SizedBox(height: 16),
          SizedBox(
            width: 465,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        _progress.statusMessage.isNotEmpty
                            ? _progress.statusMessage
                            : '正在解压...',
                        style: TextStyle(
                          fontSize: 16,
                          height: 24 / 16,
                          color: AppColors.titleBrown,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${_progress.extractPercent.toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 24,
                        height: 32 / 24,
                        letterSpacing: 1.2,
                        color: AppColors.titleBrown,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DownloadProgressBar(progress: 1.0),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  minHeight: 6,
                  value: _progress.extractPercent / 100,
                  backgroundColor: AppColors.buttonBackground,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFFD4A017)),
                ),
              ],
            ),
          ),
          // ★ 解压流水线（§C5）：解压中此前无取消入口（旧取消链路只挂在
          // 添加页进度窗）——补齐，与下载中的取消按钮同一样板。
          const SizedBox(height: 40),
          DownloadButton(
            onTap: () => GlobalInstallCenter.instance.cancelCurrentTask(),
            isExtracting: true,
          ),
        ],
      ),
    );
  }

  /// ★ 2026-10-05 需求 #6：系统操作日志面板——实时显示系统当前执行的
  /// 操作（改后缀、调用解压工具、系统判定等）。轻量化设计：仅内存展示
  /// （服务层环形缓冲 200 行，不落盘），可点击收起。
  Widget _buildOpLogPanel() {
    return SizedBox(
      width: 465,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background.withOpacity(0.65),
          border: Border.all(color: AppColors.border.withOpacity(0.6), width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---- 面板头（点击收起/展开）----
            InteractiveWrapper(
              onTap: () =>
                  setState(() => _opLogCollapsed = !_opLogCollapsed),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      _opLogCollapsed
                          ? Icons.chevron_right_rounded
                          : Icons.expand_more_rounded,
                      size: 14,
                      color: AppColors.secondaryText,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '系统操作日志',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryText,
                      ),
                    ),
                    const Spacer(),
                    if (!_opLogCollapsed)
                      Text(
                        '${_opLogLines.length} 条',
                        style: TextStyle(
                            fontSize: 10, color: AppColors.placeholderText),
                      ),
                  ],
                ),
              ),
            ),
            // ---- 日志区（展开时）----
            if (!_opLogCollapsed)
              Container(
                height: 110,
                margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.sidebarBackground.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _opLogLines.isEmpty
                    ? Center(
                        child: Text('等待系统动作…',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: AppColors.placeholderText)),
                      )
                    : ListView.builder(
                        controller: _opLogScrollCtrl,
                        itemCount: _opLogLines.length,
                        itemExtent: 15,
                        padding: EdgeInsets.zero,
                        itemBuilder: (context, i) => Text(
                          _opLogLines[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 15 / 10,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  /// ★ 解压流水线（§C5）：本地解压完成、等待用户在「确认入库」弹窗决策
  /// 期间的占位 UI。正常情况下确认弹窗悬浮其上；弹窗被关闭（放弃入库）
  /// 后任务随即转 completed，此视图只在极短的间隙可见。
  Widget _buildAwaitingConfirmationUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.77,
            child: Text(
              '等 待 确 认',
              style: TextStyle(
                fontSize: 30,
                letterSpacing: 2.0,
                color: AppColors.border,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '解压已完成，请在弹窗中确认解压结果\n确认后将回到添加页填写数据并入库；关闭弹窗视为放弃（解压产物保留在原位置）',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 22 / 14,
              color: AppColors.secondaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.check_rounded,
              size: 42,
              color: AppColors.successGreen,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '安 装 完 成',
            style: TextStyle(
              fontSize: 32,
              letterSpacing: 2.5,
              color: AppColors.successGreen,
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: 0.65,
            child: Text(
              '游戏已成功入库，可在库中查看并启动',
              style: TextStyle(
                fontSize: 15,
                height: 24 / 15,
                color: AppColors.secondaryText,
              ),
            ),
          ),
          const SizedBox(height: 36),
          DownloadButton(
            onTap: widget.onClose,
            variant: ButtonVariant.openLibrary,
          ),
        ],
      ),
    );
  }

  Widget _buildFailedUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F0),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.error_rounded,
              size: 42,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '安 装 失 败',
            style: TextStyle(
              fontSize: 32,
              letterSpacing: 2.5,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxWidth: 450),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.dangerRed.withOpacity(0.35),
                width: 1.5,
              ),
            ),
            child: Text(
              _errorMessage ?? '操作过程中发生异常，请稍后重试',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 22 / 14,
                color: const Color(0xFFD4A0A8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 28),
          DownloadButton(
            onTap: widget.onRetry ?? widget.onClose,
            variant: ButtonVariant.retry,
          ),
          const SizedBox(width: 16),
          InteractiveWrapper(
            onTap: widget.onClose,
            hoverScale: 1.0,
            hoverOffset: const Offset(0, -1),
            child: Text(
              '关闭',
              style: TextStyle(
                fontSize: 15,
                color: AppColors.secondaryText,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.secondaryText.withOpacity(0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCancelledUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已 取 消',
            style: TextStyle(
              fontSize: 30,
              letterSpacing: 2.0,
              color: AppColors.border,
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: 0.6,
            child: Text(
              '已清理临时缓存文件，任务已终止',
              style: TextStyle(
                fontSize: 14,
                height: 22 / 14,
                color: AppColors.secondaryText,
              ),
            ),
          ),
          const SizedBox(height: 32),
          DownloadButton(onTap: widget.onClose),
        ],
      ),
    );
  }
}
