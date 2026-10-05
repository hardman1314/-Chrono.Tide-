import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../models/watch_folder.dart';
import '../services/watch_folder_service.dart';

/// 侧边栏"添加"按钮的智能导入通知组件。
///
/// 交互模型（v2 — 红点点击式）：
/// - 持久红点：按钮右上角显示待处理数量，**点击红点**弹出 / 收起气泡
/// - 主动弹出：发现新候选时自动弹出气泡约 4 秒（聊天通知式），
///   用户已停留在添加页时不打扰；主动弹出期间用户点击红点则转为手动模式
/// - 点击外部收起：气泡打开时，点击气泡以外的任意位置自动收起
/// - 气泡可交互：提供"全部入库"按钮，无需进入添加页即可完成入库
///
/// 气泡渲染：通过全局 Overlay + CompositedTransformFollower 定位。
/// 侧边栏与主内容区是同级兄弟节点，普通溢出绘制会被主内容区遮盖，
/// 因此气泡必须挂在顶层 Overlay 上，用 LayerLink 跟随红点位置。
class SmartImportNotification extends StatefulWidget {
  final Widget child;

  /// 当前是否停留在添加页（是则抑制主动弹出通知）
  final bool isActive;

  /// 入库成功后回调（侧边栏气泡一键入库后刷新库页）
  final VoidCallback? onGameAdded;

  /// 红点顶部相对 Stack 顶部的偏移。
  /// 展开态卡片无顶部 margin，默认 -5；
  /// 收起态按钮自带 12px 顶部 margin，需传 7（12 - 5）抵消。
  final double badgeTop;

  /// 气泡相对按钮右缘中心的偏移（水平间距 + 垂直校正）。
  final Offset bubbleOffset;

  const SmartImportNotification({
    super.key,
    required this.child,
    this.isActive = false,
    this.onGameAdded,
    this.badgeTop = -5,
    this.bubbleOffset = const Offset(8, 0),
  });

  @override
  State<SmartImportNotification> createState() =>
      _SmartImportNotificationState();
}

class _SmartImportNotificationState extends State<SmartImportNotification> {
  /// 气泡淡入淡出动画时长（也是 Overlay 延迟移除的等待时间）
  static const Duration _fadeDuration = Duration(milliseconds: 250);

  /// 主动弹出气泡的自动隐藏时长
  static const Duration _autoHideDuration = Duration(seconds: 4);

  /// LayerLink：连接红点（Target）与 Overlay 气泡（Follower）
  final LayerLink _layerLink = LayerLink();

  /// 顶层 Overlay 中的气泡条目（null = 未挂载）
  OverlayEntry? _bubbleEntry;

  Timer? _autoHideTimer;
  bool _showBubble = false;
  bool _autoShowing = false; // 主动弹出（4 秒后自动收起）
  bool _userOpened = false; // 用户点击红点打开（需手动关闭或点击外部）
  int _lastAttentionCount = 0;

  /// 一键入库进行中
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _lastAttentionCount = _attentionCount();
    WatchFolderService.instance.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant SmartImportNotification oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户进入添加页处理 → 撤回主动弹出
    if (widget.isActive && !oldWidget.isActive && _autoShowing) {
      _autoHideTimer?.cancel();
      _autoShowing = false;
      _closeBubble();
    }
  }

  @override
  void dispose() {
    WatchFolderService.instance.removeListener(_onServiceChanged);
    _autoHideTimer?.cancel();
    _unmountBubble();
    super.dispose();
  }

  /// 需要用户关注的候选数量
  ///
  /// - 确认模式：队列全部候选（等待确认入库）
  /// - 静默模式：仅失败候选（其余自动入库）
  int _attentionCount() {
    final service = WatchFolderService.instance;
    if (service.importMode == AutoImportMode.silent) {
      return service.candidates
          .where((c) => c.taskStatus == CandidateTaskStatus.failed)
          .length;
    }
    return service.candidates.length;
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final count = _attentionCount();
    final increased = count > _lastAttentionCount;
    _lastAttentionCount = count;

    if (increased && !widget.isActive) {
      // 发现新候选 → 主动轻量通知（4 秒自动收起）
      _autoShowing = true;
      _userOpened = false;
      _autoHideTimer?.cancel();
      _autoHideTimer = Timer(_autoHideDuration, () {
        if (!mounted) return;
        _autoShowing = false;
        // 用户已手动打开则不自动收起
        if (!_userOpened) _closeBubble();
      });
      _setBubbleVisible(true);
    } else {
      // 刷新红点 / 气泡内容
      setState(() {});
      _bubbleEntry?.markNeedsBuild();
      // 队列清空（全部入库 / 全部忽略后）→ 收起气泡
      if (_showBubble && WatchFolderService.instance.candidates.isEmpty) {
        _autoShowing = false;
        _userOpened = false;
        _closeBubble();
      }
    }
  }

  // ==================== 红点点击 ====================

  /// 点击红点：切换气泡显隐
  ///
  /// - 主动弹出期间点击 → 转为手动模式（取消自动收起，保持打开）
  /// - 已打开 → 收起
  /// - 已关闭 → 打开
  void _toggleBubble() {
    if (_importing) return; // 入库进行中不允许关闭
    if (_showBubble) {
      _userOpened = false;
      _autoShowing = false;
      _closeBubble();
    } else {
      _userOpened = true;
      _autoShowing = false;
      _autoHideTimer?.cancel();
      _setBubbleVisible(true);
    }
  }

  // ==================== 气泡显隐 ====================

  void _setBubbleVisible(bool visible) {
    if (_showBubble == visible) return;
    setState(() => _showBubble = visible);

    if (visible) {
      _mountBubble();
    }
    _bubbleEntry?.markNeedsBuild();

    if (!visible) {
      // 等淡出动画播完再移除 Overlay 条目
      Future.delayed(_fadeDuration, () {
        if (mounted && !_showBubble) _unmountBubble();
      });
    }
  }

  void _closeBubble() => _setBubbleVisible(false);

  /// 挂载气泡到全局顶层 Overlay（重复调用安全）
  void _mountBubble() {
    if (_bubbleEntry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      debugPrint('[SMART-NOTIFY] ⚠️ 无可用 Overlay，气泡未显示');
      return;
    }
    _bubbleEntry = OverlayEntry(builder: (_) => _buildOverlayBubble());
    overlay.insert(_bubbleEntry!);
  }

  /// 卸载 Overlay 气泡（幂等）
  void _unmountBubble() {
    _bubbleEntry?.remove();
    _bubbleEntry = null;
  }

  // ==================== 一键入库 ====================

  /// 气泡内"全部入库"：无需进入添加页，通知中直接完成入库
  Future<void> _confirmAllFromBubble() async {
    if (_importing) return;
    final service = WatchFolderService.instance;
    final count = service.actionableCandidates.length;
    if (count == 0) return;

    setState(() => _importing = true);
    _bubbleEntry?.markNeedsBuild();

    final successCount = await service.confirmAllCandidates();

    if (!mounted) return;
    setState(() => _importing = false);
    widget.onGameAdded?.call();
    _bubbleEntry?.markNeedsBuild();

    debugPrint('[SMART-NOTIFY] ✅ 通知气泡一键入库: $successCount/$count');

    // 入库完成后短暂展示结果，然后收起气泡
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _closeBubble();
    });
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final count = _attentionCount();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // LayerLink 锚点：气泡 Follower 据此定位到红点右侧
        CompositedTransformTarget(
          link: _layerLink,
          child: widget.child,
        ),
        // 持久红点（待处理数量，按钮右上角；队列为空时隐藏）
        if (count > 0)
          Positioned(
            right: -5,
            top: widget.badgeTop,
            child: _buildRedDot(count),
          ),
      ],
    );
  }

  /// 红点（可点击，鼠标悬停变手型）
  Widget _buildRedDot(int count) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggleBubble,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          constraints: const BoxConstraints(minWidth: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.dangerRed,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.sidebarBackground, width: 1.5),
            // 气泡打开时红点高亮
            boxShadow: _showBubble
                ? [
                    BoxShadow(
                      color: AppColors.dangerRed.withOpacity(0.4),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// 顶层 Overlay 气泡
  ///
  /// 结构：全屏透明屏障（点击外部收起）+ LayerLink 跟随红点的气泡
  Widget _buildOverlayBubble() {
    return Stack(
      children: [
        // 全屏透明屏障：点击气泡以外的任意位置收起
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeBubble,
            child: Container(color: Colors.transparent),
          ),
        ),
        // 气泡：LayerLink 跟随红点
        CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.centerRight,
          followerAnchor: Alignment.centerLeft,
          offset: widget.bubbleOffset,
          showWhenUnlinked: false,
          child: IgnorePointer(
            // 淡出过程中不拦截点击
            ignoring: !_showBubble,
            child: AnimatedOpacity(
              duration: _fadeDuration,
              curve: Curves.easeOutCubic,
              opacity: _showBubble ? 1.0 : 0.0,
              // 🔴 气泡由**裸 `OverlayEntry`** 直插 Overlay，没有 `Material`
              // 祖先 ⇒ 不包这一层的话，气泡内未显式设置 style 的 `Text` 会继承
              // `MaterialApp` 的兜底 `_errorTextStyle`（纯黄双下划线）。
              // 详见 `widgets/game_detail/dark_surface.dart` 顶部同一说明。
              child: Material(
                type: MaterialType.transparency,
                child: _buildBubble(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 通知气泡：左指三角 + 详情卡片
  Widget _buildBubble() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CustomPaint(
          size: const Size(7, 14),
          painter: _BubbleTailPainter(
            color: AppColors.buttonBackground,
            borderColor: AppColors.titleBrown.withOpacity(0.45),
          ),
        ),
        _buildBubbleCard(),
      ],
    );
  }

  /// 气泡详情卡片（含一键入库操作）
  Widget _buildBubbleCard() {
    final service = WatchFolderService.instance;
    final candidates = service.candidates;
    final attention = _attentionCount();
    final readyCount = service.actionableCandidates.length;

    int ready = 0, failed = 0, working = 0;
    for (final c in candidates) {
      switch (c.taskStatus) {
        case CandidateTaskStatus.ready:
          ready++;
          break;
        case CandidateTaskStatus.failed:
          failed++;
          break;
        case CandidateTaskStatus.processing:
        case CandidateTaskStatus.pending:
          working++;
          break;
      }
    }

    // 前 3 个候选（就绪 / 失败优先展示）
    final ordered = [...candidates]
      ..sort((a, b) =>
          _statusOrder(b.taskStatus).compareTo(_statusOrder(a.taskStatus)));
    final top = ordered.take(3).toList();

    return Container(
      width: 224,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.titleBrown.withOpacity(0.45), width: 1),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.18),
            offset: const Offset(0, 2),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 12, color: AppColors.titleBrown),
              const SizedBox(width: 5),
              Text(
                '智能导入',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleBrown,
                ),
              ),
              const Spacer(),
              Text(
                attention > 0 ? '$attention 待处理' : '队列为空',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: attention > 0
                      ? AppColors.dangerRed
                      : AppColors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          // 状态摘要
          Text(
            '就绪 $ready · 识别中 $working · 失败 $failed',
            style: TextStyle(fontSize: 10, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 5),
          // 候选标题列表
          for (final c in top)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(c.taskStatus),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (candidates.length > 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '… 以及其他 ${candidates.length - 3} 个',
                style: TextStyle(fontSize: 9, color: AppColors.secondaryText),
              ),
            ),
          const SizedBox(height: 4),
          // 操作行：一键入库（通知中直接完成，无需进添加页）
          _buildBubbleActions(readyCount, failed),
        ],
      ),
    );
  }

  /// 气泡底部操作行
  Widget _buildBubbleActions(int readyCount, int failedCount) {
    // 入库进行中：进度指示
    if (_importing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.4,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.successGreen),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '正在入库…',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.successGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    // 无可入库候选（全部在识别中 / 队列空）
    if (readyCount == 0) {
      return Row(
        children: [
          Icon(Icons.info_outline,
              size: 10, color: AppColors.secondaryText.withOpacity(0.8)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              failedCount > 0 ? '失败项请进入添加页重试' : '识别完成后可一键入库',
              style: TextStyle(
                fontSize: 9,
                color: AppColors.secondaryText,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            '$readyCount 个就绪待入库',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.secondaryText,
            ),
          ),
        ),
        const SizedBox(width: 6),
        // 一键入库按钮
        InkWell(
          onTap: _confirmAllFromBubble,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.successGreen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(3),
              border:
                  Border.all(color: AppColors.successGreen.withOpacity(0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.done_all,
                    size: 11, color: AppColors.successGreen),
                const SizedBox(width: 3),
                Text(
                  '全部入库',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.successGreen,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 状态展示优先级：就绪 > 失败 > 识别中 > 待处理
  int _statusOrder(CandidateTaskStatus status) {
    switch (status) {
      case CandidateTaskStatus.ready:
        return 3;
      case CandidateTaskStatus.failed:
        return 2;
      case CandidateTaskStatus.processing:
        return 1;
      case CandidateTaskStatus.pending:
        return 0;
    }
  }

  Color _statusColor(CandidateTaskStatus status) {
    switch (status) {
      case CandidateTaskStatus.ready:
        return AppColors.successGreen;
      case CandidateTaskStatus.failed:
        return AppColors.dangerRed;
      case CandidateTaskStatus.processing:
        return AppColors.titleBrown;
      case CandidateTaskStatus.pending:
        return AppColors.secondaryText;
    }
  }
}

/// 气泡左指三角指针绘制器。顶点朝左指向红点，底边与气泡左边框衔接。
class _BubbleTailPainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  const _BubbleTailPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 填充三角（顶点朝左）
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, h / 2)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(path, fillPaint);
    // 上下两边描边（与气泡边框衔接，左侧不描边避免与红点重叠）
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final topPath = Path()
      ..moveTo(0, h / 2)
      ..lineTo(w, 0);
    final bottomPath = Path()
      ..moveTo(0, h / 2)
      ..lineTo(w, h);
    canvas.drawPath(topPath, borderPaint);
    canvas.drawPath(bottomPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) =>
      color != oldDelegate.color || borderColor != oldDelegate.borderColor;
}
