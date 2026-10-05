/// 月历网格纯函数（探索大厅 · 板块①发售月历）
///
/// 算法参考 KUNGAL galgame-calendar 的自绘月历（kun-galgame-forum-master）：
/// - 周日为一周起点
/// - 当月 1 号之前的空位用上月末尾日期补位，尾部用下月开头补位
/// - 行数自适应（4-6 行），网格紧凑不空占高度
///
/// 纯 Dart 模块（无 Flutter 依赖），便于单元测试。
class CalendarCell {
  /// 该格代表的日期（补位格属于相邻月份）
  final DateTime date;

  /// 是否属于当前展示月份
  final bool inCurrentMonth;

  const CalendarCell({required this.date, required this.inCurrentMonth});
}

class CalendarGrid {
  CalendarGrid._();

  /// 周标签（从周日开始，与 [buildCells] 的列顺序一致）
  static const List<String> weekdayLabels = [
    '日', '一', '二', '三', '四', '五', '六',
  ];

  /// 构建某月网格单元（含前后月补位），返回数量恒为 7 的整数倍
  ///
  /// [monthAnchor] 传入该月任意一天即可。
  static List<CalendarCell> buildCells(DateTime monthAnchor) {
    final year = monthAnchor.year;
    final month = monthAnchor.month;
    final first = DateTime(year, month, 1);
    // Dart weekday: Mon=1...Sun=7；周日开头 → 周一补 1 格，周日补 0 格
    final leading = first.weekday % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final rows = ((leading + daysInMonth) / 7).ceil();
    final cells = <CalendarCell>[];
    for (var i = 0; i < rows * 7; i++) {
      final date = first.add(Duration(days: i - leading));
      cells.add(CalendarCell(
        date: date,
        inCurrentMonth: date.year == year && date.month == month,
      ));
    }
    return cells;
  }

  /// 是否同一天（忽略时分秒）
  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// ISO 日期前缀（'YYYY-MM-DD...'）→ 本地零时日期；解析失败返回 null
  ///
  /// 元数据里的 releaseDate 形如 '2026-09-11'（可能带时间尾巴）。
  /// 注意 DateTime.tryParse 会把 '9999-99-99' 这类非法值「进位」成合法日期
  /// （实测得到 10007-06-07），因此必须先正则前缀、再回读校验。
  static DateTime? parseIsoDate(String? iso) {
    if (iso == null) return null;
    final m = _isoDatePrefix.firstMatch(iso);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    final parsed = DateTime(y, mo, d);
    if (parsed.year != y || parsed.month != mo || parsed.day != d) return null;
    return parsed;
  }

  static final RegExp _isoDatePrefix = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

  /// 月份标题：'2026年9月'
  static String monthLabel(DateTime anchor) =>
      '${anchor.year}年${anchor.month}月';

  /// 日期标题：'9月11日'
  static String dayLabel(DateTime d) => '${d.month}月${d.day}日';
}
