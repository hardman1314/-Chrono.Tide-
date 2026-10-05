import 'package:flutter/material.dart';

import '../../models/kungal_calendar_game.dart';
import '../../services/kungal_calendar_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import 'calendar_grid.dart';
import 'hall_cover_image.dart';
import 'hall_section_shell.dart';
import 'hall_visuals.dart';

/// 板块①：Galgame 发售月历（数据源：KUNGAL 社区公开接口，实时同步）
///
/// 左：月历网格（周日开头，KUNGAL 算法，见 calendar_grid.dart），
///   只挂 day 精度条目；月精度/无日期条目进「本月待定」桶。
/// 右：选中日期的发售作品列表；「待定」按钮循环切换四桶视图——
///   本月待定 → 未发售（已定档）→ 年内待定 → 日期未定（镜像 KUNGAL
///   galgame-calendar 的 月历/未发售/年内待定/日期未定 四视图）。
/// 点击条目由大厅页接管：匹配本地探索库进详情页，否则开 KUNGAL 页面。
class CalendarSection extends StatefulWidget {
  final KungalCalendarService kungal;
  final ValueChanged<KungalCalendarGame> onItemTap;

  /// 判定单条作品是否有可打开的目标（本地探索库命中 或 KUNGAL 详情页）。
  ///
  /// 「本地库是否命中同款」的判定只在大厅页可见（需读探索库游戏表），
  /// 故由大厅页注入；未注入时退化为「有 KUNGAL 详情页即可打开」。
  /// 列表行据此渲染「可点 / 不可点」的视觉差异——整片卡片长得一样、
  /// 点了却毫无反应，是用户把问题误判成「被遮罩层挡住」的根源。
  final bool Function(KungalCalendarGame game)? canOpen;

  const CalendarSection({
    super.key,
    required this.kungal,
    required this.onItemTap,
    this.canOpen,
  });

  @override
  State<CalendarSection> createState() => _CalendarSectionState();
}

enum _BucketView { date, monthBucket, upcoming, pending, tba }

class _CalendarSectionState extends State<CalendarSection> {
  late DateTime _monthAnchor =
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  late DateTime _selectedDate = _today;
  _BucketView _view = _BucketView.date;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _monthAnchor =
          DateTime(_monthAnchor.year, _monthAnchor.month + delta, 1);
      _selectedDate = _monthAnchor;
      _view = _BucketView.date;
    });
    // 翻月按需拉取（24h 缓存内直接命中）
    widget.kungal
        .ensureMonth(KungalCalendarService.monthKey(_monthAnchor));
  }

  void _selectDate(DateTime date) {
    setState(() {
      _selectedDate = date;
      _view = _BucketView.date;
    });
  }

  /// 「待定」按钮：循环切换四桶视图，切桶时按需拉取对应数据
  void _cycleBucketView() {
    setState(() {
      _view = _BucketView
          .values[(_view.index + 1) % _BucketView.values.length];
    });
    final k = widget.kungal;
    switch (_view) {
      case _BucketView.upcoming:
        k.ensureUpcoming();
      case _BucketView.pending:
        k.ensurePending('${DateTime.now().year}');
      case _BucketView.tba:
        k.ensureTba();
      default:
        break;
    }
  }

  void _retryCurrentView() {
    final k = widget.kungal;
    switch (_view) {
      case _BucketView.date:
      case _BucketView.monthBucket:
        k.ensureMonth(
            KungalCalendarService.monthKey(_view == _BucketView.date
                ? _selectedDate
                : _monthAnchor),
            force: true);
      case _BucketView.upcoming:
        k.ensureUpcoming(force: true);
      case _BucketView.pending:
        k.ensurePending('${DateTime.now().year}', force: true);
      case _BucketView.tba:
        k.ensureTba(force: true);
    }
  }

  // ---- 状态派生 ----

  String get _monthKey => KungalCalendarService.monthKey(_monthAnchor);
  KungalMonthData? get _monthData => widget.kungal.monthData(_monthKey);

  String get _activeKey {
    switch (_view) {
      case _BucketView.date:
      case _BucketView.monthBucket:
        return 'month_${KungalCalendarService.monthKey(
            _view == _BucketView.date ? _selectedDate : _monthAnchor)}';
      case _BucketView.upcoming:
        return 'upcoming';
      case _BucketView.pending:
        return KungalCalendarService.pendingKey('${DateTime.now().year}');
      case _BucketView.tba:
        return 'tba';
    }
  }

  bool get _activeLoading => widget.kungal.isLoading(_activeKey);
  bool get _activeFailed => widget.kungal.isFailed(_activeKey);

  List<KungalCalendarGame> _panelItems() {
    final k = widget.kungal;
    switch (_view) {
      case _BucketView.date:
        final items = k.monthData(KungalCalendarService.monthKey(_selectedDate))
            ?.items;
        if (items == null) return const [];
        return items
            .where((g) =>
                g.exactDate != null &&
                CalendarGrid.isSameDay(g.exactDate!, _selectedDate))
            .toList();
      case _BucketView.monthBucket:
        return _monthData?.bucket ?? const [];
      case _BucketView.upcoming:
        return k.upcomingGames;
      case _BucketView.pending:
        return k.pendingGames;
      case _BucketView.tba:
        return k.tbaGames;
    }
  }

  String get _panelTitle {
    switch (_view) {
      case _BucketView.date:
        return CalendarGrid.dayLabel(_selectedDate);
      case _BucketView.monthBucket:
        return '本月待定';
      case _BucketView.upcoming:
        return '未发售 · 已定档';
      case _BucketView.pending:
        return '${DateTime.now().year} 年内待定';
      case _BucketView.tba:
        return '发售日期未定';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.kungal,
      builder: (context, _) {
        final md = _monthData;
        final subtitle = _activeLoading
            ? '同步 KUNGAL 月历…'
            : _activeFailed
                ? '同步失败 · 点击重试'
                : md == null
                    ? '数据来源 KUNGAL'
                    : '本月 ${md.items.length} 部 · 数据来源 KUNGAL';

        return HallSectionShell(
          title: '发售月历',
          subtitle: subtitle,
          icon: Icons.calendar_month_rounded,
          iconAccent: AppColors.brandBlue,
          engCaption: 'RELEASE · KUNGAL',
          trailing: _MonthNav(
            anchor: _monthAnchor,
            onPrev: md?.hasPrev == false
                ? null
                : () => _shiftMonth(-1),
            onNext: md?.hasNext == false
                ? null
                : () => _shiftMonth(1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 58, child: _buildGrid()),
              const SizedBox(width: 8),
              Expanded(flex: 42, child: _buildDayPanel()),
            ],
          ),
        );
      },
    );
  }

  // ---------- 左：月历网格 ----------

  Widget _buildGrid() {
    final cells = CalendarGrid.buildCells(_monthAnchor);
    final rows = cells.length ~/ 7;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final label in CalendarGrid.weekdayLabels)
              Expanded(
                child: Text(
                  label,
                  style: AppStyles.microCaption.copyWith(fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var r = 0; r < rows; r++)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < 7; c++)
                        Expanded(child: _buildCell(cells[r * 7 + c])),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCell(CalendarCell cell) {
    final count = _monthData?.byDate[cell.date]?.length ?? 0;
    final selected = _view == _BucketView.date &&
        CalendarGrid.isSameDay(cell.date, _selectedDate);
    final isToday = CalendarGrid.isSameDay(cell.date, _today);
    final dimmed = !cell.inCurrentMonth;

    return GestureDetector(
      onTap: () => _selectDate(cell.date),
      behavior: HitTestBehavior.opaque,
      child: Center(
        // 日框：圆角正方形（AspectRatio 1，随格子尺寸自适应）——
        // 数字 + 新作数量圆点都装在框内；按设计图，默认无框线
        // （纯数字 + 圆点），仅选中（主色描边+主色数字）与今日（金描边）
        // 显示框线
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? AppColors.brandBlue
                    : (isToday ? AppColors.starGold : Colors.transparent),
                width: selected ? 1.6 : (isToday ? 1.3 : 0),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${cell.date.day}',
                  style: TextStyle(
                    fontFamily: AppStyles.enDecorativeFont,
                    fontSize: 11,
                    height: 1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: dimmed
                        ? AppColors.secondaryText.withOpacity(0.35)
                        : (selected ? AppColors.brandBlue : AppColors.primaryText),
                  ),
                ),
                // 新作数量下标：1-3 颗圆点，装在日框内（无事件占位对齐）
                const SizedBox(height: 3),
                SizedBox(
                  height: 4,
                  child: count > 0
                      ? HallReleaseDots(
                          count: count,
                          color: AppColors.brandBlue,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 右：日期作品 / 四桶视图 ----------

  Widget _buildDayPanel() {
    return Container(
      padding: const EdgeInsets.all(7),
      decoration: HallDecor.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$_panelTitle · ${_panelItems().length} 部',
                  style: AppStyles.titleSmall.copyWith(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _cycleBucketView,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _view == _BucketView.date
                        ? Colors.transparent
                        : AppColors.brandBlue.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: _view == _BucketView.date
                          ? AppColors.border
                          : AppColors.brandBlue,
                    ),
                  ),
                  child: Text(
                    _view == _BucketView.date ? '待定' : '下一桶 ›',
                    style: AppStyles.microCaption.copyWith(
                      color: _view == _BucketView.date
                          ? AppColors.secondaryText
                          : AppColors.brandBlue,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildPanelBody()),
        ],
      ),
    );
  }

  Widget _buildPanelBody() {
    if (_activeLoading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_activeFailed && _panelItems().isEmpty) {
      return GestureDetector(
        onTap: _retryCurrentView,
        behavior: HitTestBehavior.opaque,
        child: const HallEmptyHint(
          text: '加载失败 · 点击重试',
          icon: Icons.wifi_off_rounded,
        ),
      );
    }

    final list = _panelItems();
    if (list.isEmpty) {
      return HallEmptyHint(
        text: switch (_view) {
          _BucketView.date => '该日期暂无发售作品',
          _BucketView.monthBucket => '本月没有待定作品',
          _BucketView.upcoming => '暂无已定档的未发售作品',
          _BucketView.pending => '该年暂无仅知年份的待定作品',
          _BucketView.tba => '暂无日期未定作品',
        },
        icon: Icons.event_busy_rounded,
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final game = list[i];
        return _KungalRow(
          game: game,
          // 未注入判定器时退化为「有 KUNGAL 详情页」
          openable: widget.canOpen?.call(game) ?? game.detailUrl.isNotEmpty,
          onTap: () => widget.onItemTap(game),
        );
      },
    );
  }
}

/// 月份切换导航（‹ 2026年9月 ›），边界月禁用对应方向
class _MonthNav extends StatelessWidget {
  final DateTime anchor;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _MonthNav({
    required this.anchor,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.045)
            : Colors.white.withOpacity(0.55),
        border: Border.all(
          color: AppColors.isDark
              ? Colors.white.withOpacity(0.09)
              : AppColors.titleBrown.withOpacity(0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _NavIconButton(icon: Icons.chevron_left_rounded, onTap: onPrev),
          SizedBox(
            width: 64,
            child: Text(
              CalendarGrid.monthLabel(anchor),
              style: AppStyles.labelMedium.copyWith(fontSize: 12),
              textAlign: TextAlign.center,
              maxLines: 1,
            ),
          ),
          _NavIconButton(icon: Icons.chevron_right_rounded, onTap: onNext),
        ],
      ),
    );
  }
}

class _NavIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _NavIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(icon,
            size: 16,
            color: enabled
                ? AppColors.secondaryText
                : AppColors.placeholderText),
      ),
    );
  }
}

/// 日期面板里的单条作品（KUNGAL 条目）
///
/// [openable] 决定这一行的视觉语义，让「能不能点」在点之前就看得出来：
/// - 可打开：尾随「›」外跳箭头、悬停指针变手型；
/// - 不可打开（KUNGAL 站内未收录，且本地探索库无同款）：尾随换灰色
///   「无详情」标记、指针保持基本型、卡片与标题降一档对比度。
class _KungalRow extends StatelessWidget {
  final KungalCalendarGame game;
  final bool openable;
  final VoidCallback onTap;

  const _KungalRow({
    required this.game,
    required this.openable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: openable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.isDark
                ? Colors.white.withOpacity(openable ? 0.03 : 0.015)
                : Colors.white.withOpacity(openable ? 0.45 : 0.28),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: AppColors.isDark
                  ? Colors.white.withOpacity(openable ? 0.05 : 0.03)
                  : AppColors.titleBrown.withOpacity(openable ? 0.10 : 0.07),
            ),
          ),
          child: Row(
            children: [
              // 放大后的竖封（3:4），可读性优先——列表本来就可滚动
              SizedBox(
                width: 56,
                height: 75,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: HallCoverImage(networkUrl: game.portraitUrl),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    game.displayName,
                    style: AppStyles.titleSmall.copyWith(
                      fontSize: 13,
                      // 不可打开的行降一档对比度（仍可读，但明显更「安静」）
                      color: openable ? null : AppColors.secondaryText,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (game.isNsfw) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.dangerRed.withOpacity(0.15),
                            borderRadius:
                                BorderRadius.circular(AppRadius.xs),
                          ),
                          child: Text(
                            'NSFW',
                            style: AppStyles.microCaption.copyWith(
                              fontSize: 9,
                              color: AppColors.dangerRed,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(
                          game.company.isNotEmpty
                              ? game.company
                              : game.nameOriginal,
                          style: AppStyles.microCaption.copyWith(fontSize: 10.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (game.rating != null && game.rating! > 0)
              Text(
                '★ ${game.rating!.toStringAsFixed(1)}',
                style: AppStyles.microCaption.copyWith(
                  fontSize: 10.5,
                  color: AppColors.starGold,
                ),
              ),
            // 尾随标记＝可点性的唯一视觉判据：箭头的给人期待，无详情的不给
            if (openable)
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: AppColors.placeholderText)
            else
              Text(
                '无详情',
                style: AppStyles.microCaption.copyWith(
                  fontSize: 9,
                  color: AppColors.placeholderText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
