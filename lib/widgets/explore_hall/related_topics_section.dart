import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/game_model.dart';
import '../../services/discover_metadata_service.dart';
import '../../services/daily_recommendation_service.dart';
import '../../services/explore_calendar_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../interactive_wrapper.dart';
import 'hall_cover_image.dart';
import 'hall_section_shell.dart';
import 'hall_visuals.dart';
import 'today_recommendation.dart';

/// 板块②：相关话题（每日推荐 · 维度轮换制）
///
/// 数据：[DailyRecommendationService] 当日快照——
/// 每日从「全库星级 / 评分人数 / 标签 / 会社」四类维度确定性随机选一种，
/// 生成后持久化，**当日恒定绝不重算**；副标题展示今日主题（机制透明）。
///
/// UI：右侧列表是**焦点轮播**（不是滚动列表）——
/// 定时把选中焦点项下移一条（到底自动回到第一条），左侧大卡跟随联动；
/// 鼠标悬停 / 点击条目 / 键盘上下方向键 均暂停自动焦点，
/// 鼠标离开并闲置一段时间后自动恢复焦点循环（桌面直觉：用户在看时不乱动）。
class RelatedTopicsSection extends StatefulWidget {
  final ExploreCalendarService service;
  final ValueChanged<GameModel> onGameTap;

  /// 测试注入：每日推荐服务（默认全局单例）
  final DailyRecommendationService? daily;

  const RelatedTopicsSection({
    super.key,
    required this.service,
    required this.onGameTap,
    this.daily,
  });

  @override
  State<RelatedTopicsSection> createState() => _RelatedTopicsSectionState();
}

class _RelatedTopicsSectionState extends State<RelatedTopicsSection> {
  /// 自动焦点推进间隔
  static const Duration _focusInterval = Duration(seconds: 4);

  /// 鼠标离开列表区域后，重新开启自动焦点循环的闲置延时
  static const Duration _idleResumeDelay = Duration(seconds: 3);

  /// 点击 / 键盘主动操作后的停留时长（比悬停恢复更久，尊重用户主动选择）
  static const Duration _interactionHold = Duration(seconds: 8);

  /// 行高 48（封面 40 + 上下 padding）+ 分隔 4
  static const double _rowStep = 52;

  /// 当前焦点条目索引
  int _selectedIndex = 0;

  /// 自动焦点推进定时器（暂停时置 null）
  Timer? _focusTimer;

  /// 暂停后的恢复倒计时定时器
  Timer? _resumeTimer;

  final ScrollController _listController = ScrollController();
  final FocusNode _listFocusNode = FocusNode(debugLabel: 'topicsList');

  /// 鼠标是否悬停在列表区域（悬停期间暂停焦点推进）
  bool _hoveringList = false;

  /// 当前鼠标悬停的行（仅用于行高亮反馈）
  int _hoverIndex = -1;

  DailyRecommendationService get _daily =>
      widget.daily ?? DailyRecommendationService.instance;

  @override
  void initState() {
    super.initState();
    _daily.load();
    _daily.attach(widget.service);
    _startLoop();
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _resumeTimer?.cancel();
    _listController.dispose();
    _listFocusNode.dispose();
    _daily.detach();
    super.dispose();
  }

  /// 启动（或恢复）自动焦点循环
  void _startLoop() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _focusTimer?.cancel();
    _focusTimer = Timer.periodic(_focusInterval, (_) => _focusTick());
  }

  /// 暂停自动焦点循环；[delay] 非空则在延时结束后自动恢复，
  /// 为空则保持暂停（用于鼠标悬停——离开时再由 [_onHoverExit] 排恢复）。
  ///
  /// ⚠️ 一律用 Timer 而非 DateTime 时间戳：测试里 pump 推进的是假时钟，
  /// 墙上时钟与它不同步（2026-09-11 教训）。
  void _pauseLoop({Duration? delay}) {
    _focusTimer?.cancel();
    _focusTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = delay == null ? null : Timer(delay, _startLoop);
  }

  int _itemCount() => _daily.plan?.items.length ?? 0;

  /// 自动焦点循环 tick：悬停中 / 不足两条时跳过。
  /// Timer 回调内吞掉任何异常，保证轮播永不把异常冒到 UI
  /// （2026-09-11 真机反馈"轮播系统错误"防御）。
  void _focusTick() {
    try {
      final total = _itemCount();
      if (total <= 1 || _hoveringList) return;
      _moveFocus(1, total);
    } catch (e) {
      debugPrint('[RelatedTopics] ⚠️ 焦点轮播异常（已跳过本次）: $e');
    }
  }

  /// 移动焦点（自动推进 / 键盘 / 点击共用），并滚动到可见位置。
  /// [pause] 为真时暂停自动循环 [_interactionHold] 后恢复（用户主动操作）。
  void _moveFocus(int delta, int total, {bool pause = false}) {
    if (total <= 0) return;
    final next = ((_selectedIndex + delta) % total + total) % total;
    setState(() => _selectedIndex = next);
    if (pause) _pauseLoop(delay: _interactionHold);
    _ensureVisible(next);
  }

  /// 焦点项滚入可见范围（行高固定 [_rowStep]），仅在越界时滚动
  void _ensureVisible(int index) {
    if (!_listController.hasClients) return;
    try {
      final pos = _listController.position;
      if (!pos.hasContentDimensions) return;
      final viewport = pos.viewportDimension;
      final itemStart = index * _rowStep;
      final itemEnd = itemStart + _rowStep;
      final current = _listController.offset;
      var target = current;
      if (itemEnd > current + viewport) {
        target = itemEnd - viewport;
      } else if (itemStart < current) {
        target = itemStart;
      }
      if ((target - current).abs() < 0.5) return;
      _listController.animateTo(
        target.clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } catch (e) {
      debugPrint('[RelatedTopics] ⚠️ 焦点滚动异常（已跳过）: $e');
    }
  }

  void _onHoverEnter() {
    _hoveringList = true;
    _pauseLoop(); // 悬停期间无限期暂停，离开时再排恢复
  }

  /// 鼠标离开列表：闲置延时结束后自动恢复焦点循环
  void _onHoverExit() {
    _hoveringList = false;
    if (mounted) setState(() => _hoverIndex = -1);
    _pauseLoop(delay: _idleResumeDelay);
  }

  @override
  Widget build(BuildContext context) {
    // 监听快照服务（生成/加载完成）与探索库服务（整理进度 / 失败态）
    return AnimatedBuilder(
      animation: Listenable.merge([_daily, widget.service]),
      builder: (context, _) {
        final plan = _daily.plan;
        final items = plan?.items ?? const <RecommendedGame>[];
        final byId = {for (final g in widget.service.games) g.id: g};
        final safeIndex =
            items.isEmpty ? 0 : _selectedIndex.clamp(0, items.length - 1);

        return HallSectionShell(
          title: '相关话题',
          subtitle: plan == null
              ? '每日推荐 · 数据就绪后自动生成'
              : '每日推荐 · ${plan.label}',
          icon: Icons.auto_awesome_rounded,
          iconAccent: AppColors.starGold,
          engCaption: "TODAY'S PICKS",
          child: _buildBody(plan, items, safeIndex, byId),
        );
      },
    );
  }

  Widget _buildBody(
    RecommendationPlan? plan,
    List<RecommendedGame> items,
    int safeIndex,
    Map<String, GameModel> byId,
  ) {
    // 就绪等待 / 失败 / 空结果 三类状态（方案已持久化的空结果单独提示）
    if (items.isEmpty) {
      return _buildPendingOrEmpty(plan);
    }
    final scoreIsVotes = plan!.dimension == RecommendationDimension.voteCount;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            flex: 46,
            child: _buildBigCard(items[safeIndex], byId, scoreIsVotes)),
        const SizedBox(width: 8),
        Expanded(
            flex: 54,
            child: _buildCarouselList(items, safeIndex, scoreIsVotes)),
      ],
    );
  }

  Widget _buildPendingOrEmpty(RecommendationPlan? plan) {
    final svc = widget.service;
    if (plan != null) {
      // 当日快照存在但为空（如全库暂无元数据），不再重算
      return const HallEmptyHint(
        text: '每日推荐 · 今日暂无符合条件的内容，明日自动更换主题',
        icon: Icons.auto_awesome_rounded,
      );
    }
    if (svc.gamesFailed && svc.games.isEmpty) {
      return GestureDetector(
        onTap: () => svc.ensureGamesLoaded(),
        behavior: HitTestBehavior.opaque,
        child: const HallEmptyHint(
          text: '探索库加载失败 · 点击重试',
          icon: Icons.wifi_off_rounded,
        ),
      );
    }
    final progress = svc.isWarming && svc.warmTotal > 0
        ? '（元数据补抓 ${svc.warmFilled}/${svc.warmTotal}）'
        : '';
    return HallEmptyHint(
      text: '每日推荐整理中$progress：等待探索库数据完全可读后自动生成',
      icon: Icons.auto_awesome_rounded,
    );
  }

  // ---------- 左：选中作品大卡 ----------

  Widget _buildBigCard(
      RecommendedGame pick, Map<String, GameModel> byId, bool scoreIsVotes) {
    final game = byId[pick.gameId];
    final meta = DiscoverMetadataService.instance.getMetadata(pick.gameId);
    final tags = (pick.tags.isNotEmpty ? pick.tags : (game?.tags ?? const []))
        .take(2)
        .toList();
    final developer = pick.developer.isNotEmpty
        ? pick.developer
        : (meta?.developer ?? game?.developer ?? '');
    // 星级展示：元数据优先，退化用排序值；无星级显示 '—'（不显示误导性 0.0）
    final shownRating =
        meta?.rating ?? (pick.score > 0 && !scoreIsVotes ? pick.score : null);

    return InteractiveWrapper(
      onTap: game == null ? null : () => widget.onGameTap(game),
      hoverScale: 1.015,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: HallDecor.panel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 封面全幅 + 底部渐变压字（标题/工作室压在封面上，杂志感）
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    HallCoverImage(networkUrl: pick.coverUrl),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: HallGradients.coverScrim),
                      ),
                    ),
                    Positioned(
                      left: 9,
                      right: 8,
                      bottom: 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pick.title,
                            key: const Key('topicBigCardTitle'),
                            style: const TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            developer.isEmpty ? '—' : developer,
                            style: const TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 9.5,
                              height: 1.2,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 评分 + 标签行
            Row(
              children: [
                Icon(Icons.star_rounded, size: 13, color: AppColors.starGold),
                const SizedBox(width: 2),
                Text(
                  shownRating == null ? '—' : shownRating.toStringAsFixed(1),
                  style: AppStyles.microCaption.copyWith(fontSize: 11),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < tags.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.brandBlue.withOpacity(0.10),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.xs),
                            ),
                            child: Text(
                              tags[i],
                              style: AppStyles.microCaption.copyWith(
                                  fontSize: 10, color: AppColors.brandBlue),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 右：自动轮播列表 ----------

  Widget _buildCarouselList(
      List<RecommendedGame> items, int selectedIndex, bool scoreIsVotes) {
    // ⚠️ CallbackShortcuts 必须包在 Focus **外层**：它内部自带一个
    // canRequestFocus:false 的 Focus，按键沿焦点链向上冒泡，
    // 只有作为可聚焦节点的祖先才能收到（写反了方向键会完全无响应）。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveFocus(1, items.length, pause: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveFocus(-1, items.length, pause: true),
      },
      child: Focus(
        focusNode: _listFocusNode,
        child: MouseRegion(
          key: const Key('topicList'),
          onEnter: (_) => _onHoverEnter(),
          onExit: (_) => _onHoverExit(),
          child: ListView.separated(
            controller: _listController,
            padding: EdgeInsets.zero,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) =>
                _buildRow(items[i], i, i == selectedIndex, scoreIsVotes),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
      RecommendedGame pick, int i, bool selected, bool scoreIsVotes) {
    final hovered = _hoverIndex == i;
    return GestureDetector(
      onTap: () {
        // 点击 = 锁定选中项并暂停自动焦点循环（[_interactionHold] 后恢复）
        setState(() => _selectedIndex = i);
        _pauseLoop(delay: _interactionHold);
        _listFocusNode.requestFocus(); // 取得键盘焦点，随后方向键可用
      },
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hoverIndex = i),
        onExit: (_) => setState(() {
          if (_hoverIndex == i) _hoverIndex = -1;
        }),
        child: Container(
          key: Key('topicRow_$i'),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.brandBlue.withOpacity(0.09)
                : (hovered
                    ? (AppColors.isDark
                        ? Colors.white.withOpacity(0.05)
                        : Colors.black.withOpacity(0.05))
                    : (AppColors.isDark
                        ? Colors.white.withOpacity(0.03)
                        : Colors.white.withOpacity(0.35))),
            borderRadius: BorderRadius.circular(AppRadius.sm + 2),
            border: selected
                ? Border.all(color: AppColors.brandBlue.withOpacity(0.45))
                : (hovered
                    ? Border.all(
                        color: AppColors.brandBlue.withOpacity(0.22))
                    : null),
          ),
        child: Row(
          children: [
            // 排名数字（Outfit；Top1 主色强调）
            SizedBox(
              width: 14,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppStyles.enDecorativeFont,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: i == 0
                      ? AppColors.brandBlue
                      : AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ),
            const SizedBox(width: 7),
            SizedBox(
              width: 30,
              height: 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs + 1),
                child: HallCoverImage(networkUrl: pick.coverUrl),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pick.title,
                style: AppStyles.titleSmall.copyWith(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _fmtScore(pick.score, scoreIsVotes),
              style: AppStyles.microCaption.copyWith(
                fontSize: 11,
                color: AppColors.starGold,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// 排序值展示：星级维度无数据显示 '—'（不显示误导性 0.0）；
  /// 评分人数维度大数压缩（2.5w）
  static String _fmtScore(double v, bool scoreIsVotes) {
    if (scoreIsVotes) {
      if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}w';
      return v.toStringAsFixed(0);
    }
    if (v <= 0) return '—';
    return v.toStringAsFixed(1);
  }
}
