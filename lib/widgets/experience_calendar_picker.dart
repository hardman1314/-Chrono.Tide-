// ===========================================================================
// 阅历历史日历（悬浮式）
//
// 设计目的：
//   替代原"自定义时段"双日历选择器，改为类似实体日历的翻页式交互：
//   - 顶部 ◀ ▶ 切换年份 / ◁ ▷ 切换月份
//   - 中部 7×6 月历网格，每个日期格根据当日活跃度染色
//   - 选中某日后底部展示该日游戏列表（活跃详情）
//   - "查看此日"按钮 → 定位到主面板，折线图切换为该日所在周视图
//
// 视觉规范：
//   沿用 AppColors token，圆角 8、阴影 (2,4) blur 12、棕色主色 #8B7355
//   活跃度色阶：titleBrown @ 0.2 / 0.4 / 0.6 / 0.85
// ===========================================================================

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/experience_history_service.dart';

/// 阅历历史日历入口
class ExperienceCalendarPicker {
  ExperienceCalendarPicker._();

  /// 显示日历悬浮窗
  ///
  /// [anchor] 触发按钮的屏幕坐标
  /// [onDatePicked] 用户点击"查看此日"时回调，返回选中的日期
  /// [initialDate] 初始定位日期（默认今日）
  static void show({
    required BuildContext context,
    required Rect anchor,
    required ValueChanged<DateTime> onDatePicked,
    DateTime? initialDate,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ExperienceCalendarOverlay(
        anchor: anchor,
        initialDate: initialDate ?? DateTime.now(),
        onDatePicked: (date) {
          onDatePicked(date);
          entry.remove();
        },
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

/// 悬浮层实现
class _ExperienceCalendarOverlay extends StatefulWidget {
  final Rect anchor;
  final DateTime initialDate;
  final ValueChanged<DateTime> onDatePicked;
  final VoidCallback onDismiss;

  const _ExperienceCalendarOverlay({
    required this.anchor,
    required this.initialDate,
    required this.onDatePicked,
    required this.onDismiss,
  });

  @override
  State<_ExperienceCalendarOverlay> createState() =>
      _ExperienceCalendarOverlayState();
}

class _ExperienceCalendarOverlayState
    extends State<_ExperienceCalendarOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _opacityAnim;

  /// 当前显示的年月
  late int _viewYear;
  late int _viewMonth;

  /// 当前选中的日期（用于高亮 + 详情展示）
  late DateTime _selectedDate;

  /// 该月的活跃摘要
  MonthSummary? _monthSummary;

  /// 选中日的活跃详情
  DayActivity? _dayDetail;

  bool _loadingMonth = false;
  bool _loadingDay = false;

  /// 拖拽偏移
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _viewYear = widget.initialDate.year;
    _viewMonth = widget.initialDate.month;
    _selectedDate = widget.initialDate;

    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scaleAnim = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOutCubic,
    );
    _opacityAnim = CurvedAnimation(
      parent: _animCtrl,
      curve: Curves.easeOut,
    );
    _animCtrl.forward();

    _loadMonth();
    _loadDayDetail(_selectedDate);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _close() {
    _animCtrl.reverse().then((_) => widget.onDismiss());
  }

  Future<void> _loadMonth() async {
    setState(() => _loadingMonth = true);
    final summary = await ExperienceHistoryService.instance
        .getMonthSummary(_viewYear, _viewMonth);
    if (mounted) {
      setState(() {
        _monthSummary = summary;
        _loadingMonth = false;
      });
    }
  }

  Future<void> _loadDayDetail(DateTime date) async {
    setState(() => _loadingDay = true);
    final detail =
        await ExperienceHistoryService.instance.getDayDetail(date);
    if (mounted) {
      setState(() {
        _dayDetail = detail;
        _loadingDay = false;
      });
    }
  }

  void _prevMonth() {
    setState(() {
      if (_viewMonth == 1) {
        _viewYear--;
        _viewMonth = 12;
      } else {
        _viewMonth--;
      }
      _monthSummary = null;
    });
    _loadMonth();
  }

  void _nextMonth() {
    setState(() {
      if (_viewMonth == 12) {
        _viewYear++;
        _viewMonth = 1;
      } else {
        _viewMonth++;
      }
      _monthSummary = null;
    });
    _loadMonth();
  }

  void _prevYear() {
    setState(() {
      _viewYear--;
      _monthSummary = null;
    });
    _loadMonth();
  }

  void _nextYear() {
    setState(() {
      _viewYear++;
      _monthSummary = null;
    });
    _loadMonth();
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _viewYear = now.year;
      _viewMonth = now.month;
      _selectedDate = now;
      _monthSummary = null;
      _dayDetail = null;
    });
    _loadMonth();
    _loadDayDetail(now);
  }

  void _selectDay(int day) {
    final date = DateTime(_viewYear, _viewMonth, day);
    setState(() {
      _selectedDate = date;
      _dayDetail = null;
    });
    _loadDayDetail(date);
  }

  Offset _computePosition(Size panelSize) {
    final screenSize = MediaQuery.of(context).size;
    final above = widget.anchor.top - panelSize.height - 8;
    final below = widget.anchor.bottom + 8;

    double y;
    if (above > 16) {
      y = above;
    } else if (below + panelSize.height < screenSize.height - 16) {
      y = below;
    } else {
      y = 16;
    }

    double x = widget.anchor.right - panelSize.width;
    if (x < 16) x = 16;
    if (x + panelSize.width > screenSize.width - 16) {
      x = screenSize.width - panelSize.width - 16;
    }
    return Offset(x, y) + _dragOffset;
  }

  @override
  Widget build(BuildContext context) {
    const panelSize = Size(340, 460);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: FadeTransition(
              opacity: _opacityAnim,
              child: Container(color: Colors.black.withOpacity(0.05)),
            ),
          ),
        ),
        Positioned(
          left: _computePosition(panelSize).dx,
          top: _computePosition(panelSize).dy,
          child: FadeTransition(
            opacity: _opacityAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: Alignment.bottomRight,
              child: Material(
                color: Colors.transparent,
                child: _buildPanel(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPanel() {
    final isDark = AppColors.isDark;
    return Container(
      width: 340,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.buttonBackground.withOpacity(0.96)
            : AppColors.background.withOpacity(0.96),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border.withOpacity(0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          const Divider(height: 12, thickness: 0.5),
          _buildNav(),
          const SizedBox(height: 6),
          _buildWeekHeader(),
          const SizedBox(height: 2),
          _buildCalendarGrid(),
          const SizedBox(height: 8),
          _buildDayDetail(),
          const SizedBox(height: 8),
          _buildActions(),
        ],
      ),
    );
  }

  /// 标题栏（可拖拽）
  Widget _buildHeader() {
    return GestureDetector(
      onPanUpdate: (d) {
        setState(() => _dragOffset += d.delta);
      },
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Icon(Icons.calendar_month_outlined,
              size: 12, color: AppColors.titleBrown.withOpacity(0.8)),
          const SizedBox(width: 6),
          Text(
            '阅历 · 历史日历',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.titleBrown.withOpacity(0.9),
            ),
          ),
          const Spacer(),
          Icon(Icons.drag_indicator,
              size: 14, color: AppColors.secondaryText.withOpacity(0.5)),
          const SizedBox(width: 2),
          InkWell(
            onTap: _close,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close,
                  size: 12, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  /// 年/月翻页导航
  Widget _buildNav() {
    return Row(
      children: [
        // 年份切换
        _NavButton(
          icon: Icons.keyboard_double_arrow_left,
          tooltip: '上一年',
          onTap: _prevYear,
        ),
        Text(
          '$_viewYear年',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.titleBrown,
          ),
        ),
        _NavButton(
          icon: Icons.keyboard_double_arrow_right,
          tooltip: '下一年',
          onTap: _nextYear,
        ),
        const SizedBox(width: 12),
        // 月份切换
        _NavButton(
          icon: Icons.chevron_left,
          tooltip: '上月',
          onTap: _prevMonth,
        ),
        Text(
          '$_viewMonth月',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.titleBrown,
          ),
        ),
        _NavButton(
          icon: Icons.chevron_right,
          tooltip: '下月',
          onTap: _nextMonth,
        ),
        const Spacer(),
        // 今日按钮
        InkWell(
          onTap: _goToday,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.titleBrown.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '今日',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.titleBrown,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 星期表头（一二三四五六日）
  Widget _buildWeekHeader() {
    final labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: labels
          .map((l) => Expanded(
                child: Center(
                  child: Text(
                    l,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText.withOpacity(0.7),
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  /// 日历主体网格（6 行 × 7 列）
  Widget _buildCalendarGrid() {
    final firstOfMonth = DateTime(_viewYear, _viewMonth, 1);
    // 周一为 1，周日为 7 → 转换为 0~6 索引
    final firstWeekday = firstOfMonth.weekday - 1;
    final daysInMonth = DateTime(_viewYear, _viewMonth + 1, 0).day;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final cells = <Widget>[];

    // 前置空白
    for (int i = 0; i < firstWeekday; i++) {
      cells.add(const SizedBox.shrink());
    }

    // 日期格
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_viewYear, _viewMonth, day);
      final seconds = _monthSummary?.daySeconds[day] ?? 0;
      final gameCount = _monthSummary?.dayGameCounts[day] ?? 0;
      final isFuture = date.isAfter(today);
      final isToday = date == today;
      final isSelected = date.year == _selectedDate.year &&
          date.month == _selectedDate.month &&
          date.day == _selectedDate.day;

      cells.add(
        _CalendarCell(
          day: day,
          seconds: seconds,
          gameCount: gameCount,
          isFuture: isFuture,
          isToday: isToday,
          isSelected: isSelected,
          onTap: isFuture ? null : () => _selectDay(day),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.background.withOpacity(0.4),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border.withOpacity(0.3)),
      ),
      child: _loadingMonth
          ? SizedBox(
              height: 132,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.border.withOpacity(0.5),
                  ),
                ),
              ),
            )
          : GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
              childAspectRatio: 1.0,
              children: cells,
            ),
    );
  }

  /// 选中日的详情
  Widget _buildDayDetail() {
    final date = _selectedDate;
    final weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekday = weekdayLabels[date.weekday - 1];

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.titleBrown.withOpacity(0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border.withOpacity(0.3)),
      ),
      child: _loadingDay
          ? SizedBox(
              height: 80,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.border.withOpacity(0.5),
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.event_outlined,
                        size: 11, color: AppColors.titleBrown),
                    const SizedBox(width: 4),
                    Text(
                      '${date.month}月${date.day}日 $weekday',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleBrown,
                      ),
                    ),
                    const Spacer(),
                    if (_dayDetail != null && !_dayDetail!.isEmpty)
                      Text(
                        '${_dayDetail!.games.length}款 · ${_formatDuration(_dayDetail!.totalSeconds)} · ${_dayDetail!.totalSessionCount}次',
                        style: TextStyle(
                          fontSize: 9,
                          color: AppColors.secondaryText,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_dayDetail == null || _dayDetail!.isEmpty)
                  SizedBox(
                    height: 60,
                    child: Center(
                      child: Text(
                        '当日无游玩记录',
                        style: TextStyle(
                          fontSize: 9,
                          color: AppColors.secondaryText.withOpacity(0.6),
                        ),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 80),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _dayDetail!.games.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (ctx, idx) {
                        final g = _dayDetail!.games[idx];
                        final maxSeconds = _dayDetail!.games.first.seconds;
                        final ratio = maxSeconds > 0
                            ? (g.seconds / maxSeconds).clamp(0.0, 1.0)
                            : 0.0;
                        return _GameActivityRow(
                          title: g.gameTitle,
                          seconds: g.seconds,
                          ratio: ratio,
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  /// 底部操作：查看此日 / 关闭
  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _ActionButton(
          label: '关闭',
          isPrimary: false,
          onTap: _close,
        ),
        const SizedBox(width: 8),
        _ActionButton(
          label: '查看此日',
          isPrimary: true,
          onTap: () => widget.onDatePicked(_selectedDate),
        ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h${m}m';
    return '${m}m';
  }
}

// ===========================================================================
// 子组件
// ===========================================================================

/// 翻页导航按钮
class _NavButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon,
              size: 12, color: AppColors.titleBrown.withOpacity(0.8)),
        ),
      ),
    );
  }
}

/// 日历单元格
class _CalendarCell extends StatelessWidget {
  final int day;
  final int seconds;
  final int gameCount;
  final bool isFuture;
  final bool isToday;
  final bool isSelected;
  final VoidCallback? onTap;

  const _CalendarCell({
    required this.day,
    required this.seconds,
    required this.gameCount,
    required this.isFuture,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  /// 根据活跃度返回背景色
  Color _bgColor() {
    if (isFuture || seconds <= 0) {
      return Colors.transparent;
    }
    // 用一个合理的色阶：参考 GitHub 热力图
    // 由于没有 maxSeconds 上下文，按绝对时长分档
    // 30 分钟 / 1 小时 / 2 小时 / 3 小时+
    if (seconds < 1800) return AppColors.titleBrown.withOpacity(0.2);
    if (seconds < 3600) return AppColors.titleBrown.withOpacity(0.4);
    if (seconds < 7200) return AppColors.titleBrown.withOpacity(0.6);
    return AppColors.titleBrown.withOpacity(0.85);
  }

  @override
  Widget build(BuildContext context) {
    final hasActivity = seconds > 0;
    return GestureDetector(
      onTap: isFuture ? null : onTap,
      child: MouseRegion(
        cursor: isFuture ? MouseCursor.defer : SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            color: _bgColor(),
            borderRadius: BorderRadius.circular(3),
            border: isSelected
                ? Border.all(
                    color: AppColors.selectedAccent,
                    width: 1.5,
                  )
                : isToday
                    ? Border.all(
                        color: AppColors.titleBrown,
                        width: 0.8,
                      )
                    : null,
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$day',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: isSelected || isToday
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: isFuture
                      ? AppColors.secondaryText.withOpacity(0.3)
                      : hasActivity
                          ? Colors.white
                          : AppColors.secondaryText,
                ),
              ),
              if (hasActivity && gameCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '$gameCount',
                    style: TextStyle(
                      fontSize: 7,
                      color: Colors.white.withOpacity(0.85),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 游戏活跃行
class _GameActivityRow extends StatelessWidget {
  final String title;
  final int seconds;
  final double ratio;

  const _GameActivityRow({
    required this.title,
    required this.seconds,
    required this.ratio,
  });

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h${m}m';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 4,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: AppColors.titleBrown.withOpacity(0.7),
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9,
              color: AppColors.primaryText,
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: AppColors.border.withOpacity(0.15),
            valueColor: AlwaysStoppedAnimation<Color>(
              AppColors.titleBrown.withOpacity(0.7),
            ),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 32,
          child: Text(
            _formatDuration(seconds),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 8,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      ],
    );
  }
}

/// 操作按钮
class _ActionButton extends StatefulWidget {
  final String label;
  final bool isPrimary;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.isPrimary,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: widget.isPrimary
                ? (_hovered
                    ? AppColors.titleBrown.withOpacity(0.9)
                    : AppColors.titleBrown.withOpacity(0.8))
                : (_hovered ? AppColors.cardHoverBg : Colors.transparent),
            border: Border.all(
              color: widget.isPrimary
                  ? AppColors.titleBrown
                  : AppColors.border.withOpacity(0.5),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: widget.isPrimary
                  ? Colors.white
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
