import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/stats_aggregator.dart';
import 'experience_calendar_picker.dart';

/// 首页右下角游玩统计面板（v2.2 "阅历"系统 · 历史日历版）
///
/// 在保留原 280×168 折线图视觉风格基础上，轻量化为 320×196，
/// 4 段时段切换 + 历史日历入口，支持任意历史日期回溯定位。
///
/// 数据源策略：
///   - 短时段（≤90 天）：直接读 game.json daily_play_log
///   - 长时段 / 历史日历查询：从 sessions + sessions_archive.json 全量重聚合
///   - 历史日历数据由 ExperienceHistoryService 提供（独立适配层 + 缓存）
class PlayStatsPanel extends StatefulWidget {
  final LibraryGame? currentGame;

  const PlayStatsPanel({super.key, this.currentGame});

  @override
  State<PlayStatsPanel> createState() => _PlayStatsPanelState();
}

class _PlayStatsPanelState extends State<PlayStatsPanel> {
  // ==================== 状态字段 ====================

  /// 默认展开
  bool _expanded = true;
  bool _loading = false;

  /// 当前选中时段（默认近 7 日，保持原行为）
  StatsPeriod _period = StatsPeriod.last7;

  /// 自定义时段的起止（仅在 _period == custom 时生效）
  DateTime? _customFrom;
  DateTime? _customTo;

  /// 历史日历选定的日期（仅在 _period == pickedDay 时生效）
  ///
  /// 当用户从历史日历中选定某日时，折线图切换到该日所在周的 7 天视图，
  /// 并以该日为中心高亮。
  DateTime? _pickedDate;

  /// 当前聚合结果（驱动折线图）
  List<AggregatedPoint> _points = const [];

  /// 实时流是否启用（仅 last7 + 当日有效）
  bool _realtimeEnabled = true;

  /// 防抖定时器：registry 频繁通知时避免过度刷新
  Timer? _refreshDebounce;

  /// 自定义按钮的 GlobalKey（用于计算悬浮窗弹出锚点）
  final GlobalKey _calendarBtnKey = GlobalKey();

  // ==================== 生命周期 ====================

  @override
  void initState() {
    super.initState();
    _loadData();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  /// registry 变化时防抖刷新（500ms 内多次通知合并为一次）
  void _onRegistryChanged() {
    if (!mounted) return;
    // 仅在实时模式下响应（M5 双通道隔离）
    if (!_realtimeEnabled) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _loadData();
    });
  }

  @override
  void didUpdateWidget(PlayStatsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换游戏时重新加载
    if (widget.currentGame?.title != oldWidget.currentGame?.title) {
      _loadData();
    }
  }

  // ==================== 数据加载 ====================

  /// 加载当前时段的数据
  ///
  /// 根据 _period 决定走 [daily_play_log] 还是 [sessions] 重聚合：
  ///   - last7 / last30 / custom(≤90 天) → daily_play_log 路径（快速）
  ///   - last90 / all / custom(>90 天) → sessions 重聚合（慢路径）
  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      // 切换到非 last7 时段时关闭实时流（M5 双通道隔离）
      _realtimeEnabled = (_period == StatsPeriod.last7);
    });

    try {
      final now = DateTime.now();

      // 计算区间
      DateTime from;
      DateTime to;
      if (_pickedDate != null) {
        // 历史日历定位模式：显示选中日所在 7 天（前 6 天 + 当天）
        final picked =
            DateTime(_pickedDate!.year, _pickedDate!.month, _pickedDate!.day);
        from = picked.subtract(const Duration(days: 6));
        to = picked;
      } else {
        final range = StatsAggregator.periodRange(
          _period,
          now: now,
          customFrom: _customFrom,
          customTo: _customTo,
          firstPlayDate: await _findFirstPlayDate(),
        );
        from = range.from;
        to = range.to;
      }
      final span = to.difference(from);
      // 定位模式强制日粒度（7 天）
      final granularity = _pickedDate != null
          ? StatsGranularity.day
          : StatsAggregator.granularityFor(span);

      // 决定数据源：> 90 天走 sessions 重聚合
      final useSessionsPath = span.inDays > 90 || _period == StatsPeriod.all;

      List<DailyEntry> dailyEntries;
      if (useSessionsPath) {
        dailyEntries = await _loadFromSessions();
      } else {
        dailyEntries = await _loadFromDailyPlayLog();
      }

      // 按区间过滤后再聚合
      final filtered = dailyEntries.where((e) {
        return !e.date.isBefore(from) && !e.date.isAfter(to);
      }).toList();

      final points = StatsAggregator.aggregate(
        dailyEntries: filtered,
        from: from,
        to: to,
        granularity: granularity,
      );

      if (mounted) {
        setState(() {
          _points = points;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[STATS] 加载游玩统计失败: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 从 daily_play_log 读取（短跨度路径，复用原 _loadGameDailyLog 逻辑）
  Future<List<DailyEntry>> _loadFromDailyPlayLog() async {
    final allEntries = <DailyEntry>[];

    if (widget.currentGame != null) {
      allEntries.addAll(await _readGameDailyLog(widget.currentGame!));
    } else {
      for (final game in LocalGameRegistry.instance.allGames) {
        allEntries.addAll(await _readGameDailyLog(game));
      }
    }

    // 合并同日
    return _mergeByDate(allEntries);
  }

  /// 从 sessions + sessions_archive.json 读取并重聚合（长跨度路径）
  Future<List<DailyEntry>> _loadFromSessions() async {
    final allSessions = <SessionRecord>[];

    if (widget.currentGame != null) {
      allSessions.addAll(await _readGameSessions(widget.currentGame!));
    } else {
      for (final game in LocalGameRegistry.instance.allGames) {
        allSessions.addAll(await _readGameSessions(game));
      }
    }

    return StatsAggregator.aggregateSessionsToDaily(allSessions);
  }

  /// 读取单个游戏的 daily_play_log
  /// 兼容两种格式：
  ///   旧格式: { "2026-06-23": 3600 }
  ///   新格式: { "2026-06-23": { "seconds": 3600, "count": 1 } }
  Future<List<DailyEntry>> _readGameDailyLog(LibraryGame game) async {
    try {
      final metaDataDir = game.metaDataDir;
      final jsonFile = File('$metaDataDir/game.json');
      if (!jsonFile.existsSync()) return const [];

      final raw =
          jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
      final log = raw['daily_play_log'];
      if (log is! Map) return const [];
      return StatsAggregator.parseDailyPlayLog(Map<String, dynamic>.from(log));
    } catch (e) {
      debugPrint('[STATS] 读取 ${game.title} daily_play_log 失败: $e');
      return const [];
    }
  }

  /// 读取单个游戏的全部会话（active + archived）
  Future<List<SessionRecord>> _readGameSessions(LibraryGame game) async {
    try {
      final metaDataDir = game.metaDataDir;
      final active = await GameDataFormat.readSessions(metaDataDir);
      final archived = await GameDataFormat.readArchivedSessions(metaDataDir);
      final all = [...archived, ...active];
      return all.map(SessionRecord.fromJson).toList();
    } catch (e) {
      debugPrint('[STATS] 读取 ${game.title} sessions 失败: $e');
      return const [];
    }
  }

  /// 找到所有游戏中的最早游玩日期（用于 all 模式）
  Future<DateTime?> _findFirstPlayDate() async {
    DateTime? earliest;
    for (final game in LocalGameRegistry.instance.allGames) {
      try {
        final firstStr = game.firstOpenedAt;
        if (firstStr.isNotEmpty) {
          final dt = DateTime.tryParse(firstStr);
          if (dt != null && (earliest == null || dt.isBefore(earliest))) {
            earliest = dt;
          }
        }
      } catch (_) {}
    }
    return earliest;
  }

  /// 合并同日 entry
  List<DailyEntry> _mergeByDate(List<DailyEntry> entries) {
    final Map<String, DailyEntry> merged = {};
    for (final e in entries) {
      final key = '${e.date.year}-${e.date.month}-${e.date.day}';
      final existing = merged[key];
      if (existing == null) {
        merged[key] = e;
      } else {
        merged[key] = DailyEntry(
          date: e.date,
          seconds: existing.seconds + e.seconds,
          count: existing.count + e.count,
        );
      }
    }
    final list = merged.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  // ==================== 派生统计 ====================

  int get _totalSeconds => _points.fold(0, (a, p) => a + p.seconds);
  int get _totalCount => _points.fold(0, (a, p) => a + p.count);

  /// "今日"数据：仅在 last7 模式下取最后一个点；其他模式取最后一个 bucket
  int get _latestSeconds => _points.isNotEmpty ? _points.last.seconds : 0;
  int get _latestCount => _points.isNotEmpty ? _points.last.count : 0;

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0m';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  /// 根据 _period 返回标题文字（保留原"近7日"语义）
  String get _titleText {
    final isCurrent = widget.currentGame != null;
    // 历史日历定位模式优先显示
    if (_pickedDate != null) {
      final d = _pickedDate!;
      final label =
          '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
      return isCurrent ? '游玩记录 · $label' : '总游玩 · $label';
    }
    switch (_period) {
      case StatsPeriod.last7:
        return isCurrent ? '近7日游玩' : '近7日总游玩';
      case StatsPeriod.last30:
        return isCurrent ? '近30日游玩' : '近30日总游玩';
      case StatsPeriod.last90:
        return isCurrent ? '近90日游玩' : '近90日总游玩';
      case StatsPeriod.all:
        return isCurrent ? '游玩阅历' : '全部游玩阅历';
      case StatsPeriod.custom:
        return isCurrent ? '游玩记录' : '总游玩记录';
    }
  }

  /// "最新"标签：定位日模式下显示"当日"，其他显示"今日"/"最近"
  String get _latestLabel =>
      _pickedDate != null ? '当日' : (_period == StatsPeriod.last7 ? '今日' : '最近');

  // ==================== UI 构建 ====================

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.bottomRight,
      child: _expanded ? _buildExpanded() : _buildCollapsed(),
    );
  }

  /// 收起状态：仅显示标题栏（轻量化尺寸 260×28）
  Widget _buildCollapsed() {
    return _buildContainer(
      width: 260,
      height: 28,
      radius: 6, // 收起态保持原圆角
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _expanded = true),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(
                  Icons.show_chart,
                  size: 12,
                  color: AppColors.titleBrown.withOpacity(0.8),
                ),
                const SizedBox(width: 4),
                Text(
                  '阅历',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.titleBrown.withOpacity(0.9),
                  ),
                ),
                const Spacer(),
                Text(
                  '${_formatDuration(_totalSeconds)} · $_totalCount次',
                  style: TextStyle(
                    fontSize: 9,
                    color: AppColors.secondaryText,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  Icons.expand_less,
                  size: 12,
                  color: AppColors.secondaryText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 展开状态：折线图 + 时段切换 + 详情入口
  Widget _buildExpanded() {
    return _buildContainer(
      width: 320,
      height: 196,
      radius: 8, // 等比放大后圆角微调
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题栏 + 时段胶囊 + 工具图标
              _buildTitleRow(),
              const SizedBox(height: 4),
              // 折线图
              Expanded(
                child: _loading
                    ? Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: AppColors.border.withOpacity(0.5),
                          ),
                        ),
                      )
                    : _buildLineChart(),
              ),
              const SizedBox(height: 4),
              // 分隔线
              Container(
                height: 0.5,
                color: AppColors.border.withOpacity(0.2),
              ),
              const SizedBox(height: 4),
              // 底部统计：时长 + 次数 + 今日 + 详情入口
              _buildFooterRow(),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题行：图标 + 标题 + 时段胶囊 + 自定义按钮 + 收起按钮
  Widget _buildTitleRow() {
    return SizedBox(
      height: 20,
      child: Row(
        children: [
          Icon(
            Icons.show_chart,
            size: 12,
            color: AppColors.titleBrown.withOpacity(0.8),
          ),
          const SizedBox(width: 5),
          Text(
            _titleText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.titleBrown.withOpacity(0.9),
            ),
          ),
          const Spacer(),
          // 时段切换胶囊
          _buildPeriodSegments(),
          const SizedBox(width: 3),
          // 历史日历入口按钮
          _buildIconBtn(
            key: _calendarBtnKey,
            icon: Icons.history,
            tooltip: '历史日历',
            onTap: _showCustomPeriodPicker,
          ),
          const SizedBox(width: 2),
          // 收起按钮（保留原位置和样式）
          InkWell(
            onTap: () => setState(() => _expanded = false),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.expand_more,
                size: 12,
                color: AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 时段切换胶囊（4 段：7日/30日/90日/全部）
  /// 样式沿用 [_HoverChip] 的圆角 10 + 激活态 selectedAccent
  Widget _buildPeriodSegments() {
    final segments = [
      (StatsPeriod.last7, '7日'),
      (StatsPeriod.last30, '30日'),
      (StatsPeriod.last90, '90日'),
      (StatsPeriod.all, '全部'),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: AppColors.border.withOpacity(0.5),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
        color: AppColors.background.withOpacity(0.4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: segments.map((item) {
          final (period, label) = item;
          // 定位日模式下 4 段胶囊均不激活；切换时段会清除定位日
          final isActive = _pickedDate == null && _period == period;
          return _HoverSegment(
            label: label,
            isActive: isActive,
            onTap: () {
              setState(() {
                _period = period;
                // 切换预设时段时清除历史日历的定位日
                _pickedDate = null;
              });
              _loadData();
            },
          );
        }).toList(),
      ),
    );
  }

  /// 统一的小图标按钮（沿用 [home_page.dart] _buildBigPictureButton 24×24 风格）
  Widget _buildIconBtn({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final isDark = AppColors.isDark;
    return Tooltip(
      key: key,
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: isDark
                    ? AppColors.border.withOpacity(0.5)
                    : AppColors.borderLight,
              ),
              color: isDark ? AppColors.buttonBackground : AppColors.background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              icon,
              size: 10,
              color: isDark ? AppColors.primaryText : AppColors.border,
            ),
          ),
        ),
      ),
    );
  }

  /// 打开历史日历（替代原"自定义时段"双日历选择器）
  ///
  /// 用户可在日历中翻页查看任意年月，点击某日 → "查看此日" 后，
  /// 折线图切换到该日所在 7 天视图，并以该日为"今日"高亮。
  void _showCustomPeriodPicker() {
    // 通过 GlobalKey 获取触发按钮的屏幕坐标
    final renderObj = _calendarBtnKey.currentContext?.findRenderObject();
    Rect anchor;
    if (renderObj is RenderBox && renderObj.hasSize) {
      final offset = renderObj.localToGlobal(Offset.zero);
      anchor = offset & renderObj.size;
    } else {
      final size = MediaQuery.of(context).size;
      anchor = Rect.fromPoints(
        Offset(size.width - 340, size.height - 280),
        Offset(size.width - 20, size.height - 240),
      );
    }

    ExperienceCalendarPicker.show(
      context: context,
      anchor: anchor,
      initialDate: _pickedDate ?? DateTime.now(),
      onDatePicked: (date) {
        setState(() {
          _pickedDate = date;
          // 进入"定位日"模式：清空 custom 区间，避免冲突
          _customFrom = null;
          _customTo = null;
          // 时段保持原 _period 值（仅作显示参考），实际加载走 _pickedDate 分支
        });
        _loadData();
      },
    );
  }

  /// 底部统计行：总计 / 次数 / 今日 + 详情入口
  Widget _buildFooterRow() {
    return SizedBox(
      height: 16,
      child: Row(
        children: [
          Text(
            '总计 ${_formatDuration(_totalSeconds)}',
            style: TextStyle(
              fontSize: 9,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$_totalCount次',
            style: TextStyle(
              fontSize: 9,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$_latestLabel ${_formatDuration(_latestSeconds)} · $_latestCount次',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: AppColors.titleBrown,
            ),
          ),
          const Spacer(),
          // 详情入口
          _HoverDetail(
            onTap: () => _showDetailSheet(),
          ),
        ],
      ),
    );
  }

  /// 详情底部弹层（显示当前时段的明细）
  void _showDetailSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        final sortedPoints = List<AggregatedPoint>.from(_points.reversed);
        return SizedBox(
          height: 360,
          child: Column(
            children: [
              // 标题
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.show_chart,
                      size: 16,
                      color: AppColors.titleBrown,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$_titleText · 明细',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.titleBrown,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close,
                          size: 18, color: AppColors.secondaryText),
                      onPressed: () => Navigator.of(ctx).pop(),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 列表
              Expanded(
                child: sortedPoints.isEmpty
                    ? Center(
                        child: Text(
                          '暂无数据',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: sortedPoints.length,
                        itemBuilder: (ctx, idx) {
                          final p = sortedPoints[idx];
                          final maxSeconds = sortedPoints
                              .map((e) => e.seconds)
                              .fold<int>(0, (a, b) => a > b ? a : b);
                          final ratio = maxSeconds > 0
                              ? (p.seconds / maxSeconds).clamp(0.0, 1.0)
                              : 0.0;
                          return ListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            title: Text(
                              p.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primaryText,
                              ),
                            ),
                            subtitle: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 4,
                              backgroundColor:
                                  AppColors.border.withOpacity(0.15),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.titleBrown.withOpacity(0.7),
                              ),
                            ),
                            trailing: Text(
                              '${_formatDuration(p.seconds)} · ${p.count}次',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.secondaryText,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== 折线图 ====================

  Widget _buildLineChart() {
    // 空数据态
    if (_points.isEmpty || _totalSeconds == 0) {
      return Center(
        child: Text(
          '该时段暂无游玩记录',
          style: TextStyle(
            fontSize: 10,
            color: AppColors.secondaryText.withOpacity(0.6),
          ),
        ),
      );
    }

    final maxSeconds =
        _points.map((e) => e.seconds).fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = (maxSeconds / 3600).ceil().toDouble().clamp(0.5, 24.0);

    final spots = <FlSpot>[];
    for (int i = 0; i < _points.length; i++) {
      spots.add(FlSpot(i.toDouble(), _points[i].seconds / 3600.0));
    }

    // 轻量化：点数过多时关闭数据点显示，减少绘制开销
    final showDots = _points.length <= 14;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 3,
          getDrawingHorizontalLine: (value) => FlLine(
            color: AppColors.border.withOpacity(0.15),
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: maxY / 3,
              getTitlesWidget: (value, meta) {
                if (value == 0) return const Text('');
                return Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Text(
                    '${value.toInt()}h',
                    style: TextStyle(
                      fontSize: 8,
                      color: AppColors.secondaryText,
                    ),
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 14,
              // 自适应间隔：点数过多时跳过部分标签
              interval:
                  _points.length > 12 ? (_points.length / 7).ceilToDouble() : 1,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= _points.length) {
                  return const Text('');
                }
                final isLast = idx == _points.length - 1;
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _points[idx].label,
                    style: TextStyle(
                      fontSize: 8,
                      color: isLast
                          ? AppColors.titleBrown
                          : AppColors.secondaryText,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minX: 0,
        maxX: (_points.length - 1).toDouble().clamp(0, double.infinity),
        minY: 0,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.3,
            preventCurveOverShooting: true,
            barWidth: 1.8,
            isStrokeCapRound: true,
            color: const Color(0xFF8B7355),
            dotData: FlDotData(
              show: showDots,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 2,
                  color: AppColors.background,
                  strokeWidth: 1.2,
                  strokeColor: const Color(0xFF8B7355),
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF8B7355).withOpacity(0.25),
                  const Color(0xFF8B7355).withOpacity(0.02),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) =>
                AppColors.titleBrown.withOpacity(0.9),
            tooltipRoundedRadius: 4,
            tooltipPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final idx = spot.spotIndex;
                if (idx >= _points.length) return null;
                final p = _points[idx];
                return LineTooltipItem(
                  '${p.label}\n${_formatDuration(p.seconds)} · ${p.count}次',
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  /// 统一的容器样式（沿用原 _buildContainer，radius 参数化以兼容收起态）
  Widget _buildContainer({
    required double width,
    required double height,
    required double radius,
    required Widget child,
  }) {
    final isDark = AppColors.isDark;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.buttonBackground.withOpacity(0.92)
            : AppColors.background.withOpacity(0.88),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: AppColors.border.withOpacity(0.5),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: radius == 6 ? 6 : 8,
            offset: Offset(1, radius == 6 ? 2 : 3),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ===========================================================================
// 子组件：时段胶囊段
// ===========================================================================

/// 单个时段胶囊段（沿用 [_HoverChip] 风格）
class _HoverSegment extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _HoverSegment({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_HoverSegment> createState() => _HoverSegmentState();
}

class _HoverSegmentState extends State<_HoverSegment> {
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
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.selectedAccent.withOpacity(0.15)
                : _hovered
                    ? AppColors.cardHoverBg
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: widget.isActive ? FontWeight.w700 : FontWeight.w500,
              color: widget.isActive
                  ? AppColors.selectedAccent
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// 子组件：详情入口
// ===========================================================================

/// 底部"详情"链接式按钮
class _HoverDetail extends StatefulWidget {
  final VoidCallback onTap;

  const _HoverDetail({required this.onTap});

  @override
  State<_HoverDetail> createState() => _HoverDetailState();
}

class _HoverDetailState extends State<_HoverDetail> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '详情',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color:
                    _hovered ? AppColors.titleBrown : AppColors.secondaryText,
              ),
            ),
            const SizedBox(width: 1),
            Icon(
              Icons.chevron_right,
              size: 11,
              color: _hovered ? AppColors.titleBrown : AppColors.secondaryText,
            ),
          ],
        ),
      ),
    );
  }
}
