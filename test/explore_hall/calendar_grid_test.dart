import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/widgets/explore_hall/calendar_grid.dart';

void main() {
  group('CalendarGrid.buildCells', () {
    test('2026年9月：周二开头，5 行 35 格，首格 8/30（周日）', () {
      // 2026-09-01 是周二（weekday=2）→ 前面补 2 格；9 月 30 天
      // ceil((2+30)/7)=5 行 → 35 格；首格 = 9/1 - 2d = 8/30（周日）
      final cells = CalendarGrid.buildCells(DateTime(2026, 9, 15));
      expect(cells.length, 35);
      expect(cells.length % 7, 0);
      expect(cells.first.date, DateTime(2026, 8, 30));
      expect(cells.last.date, DateTime(2026, 10, 3));
      expect(cells.where((c) => c.inCurrentMonth).length, 30);
      // 每行首列必须是周日
      for (var r = 0; r < 5; r++) {
        expect(cells[r * 7].date.weekday, DateTime.sunday);
      }
    });

    test('2026年2月：28 天恰好 4 行整', () {
      // 2026-02-01 是周日 → 无前置补位；28 天 = 4 行整
      final cells = CalendarGrid.buildCells(DateTime(2026, 2, 10));
      expect(cells.length, 28);
      expect(cells.first.date, DateTime(2026, 2, 1));
      expect(cells.last.date, DateTime(2026, 2, 28));
      expect(cells.every((c) => c.inCurrentMonth), isTrue);
    });

    test('闰月与跨年补位：2027年1月', () {
      // 2027-01-01 是周五 → 前补 5 格（12/27-12/31）
      final cells = CalendarGrid.buildCells(DateTime(2027, 1, 1));
      expect(cells.first.date, DateTime(2026, 12, 27));
      expect(cells.where((c) => c.inCurrentMonth).length, 31);
      // 尾部补位进入 2 月
      expect(cells.last.date.month, 2);
    });
  });

  group('CalendarGrid.parseIsoDate', () {
    test('标准 ISO 与带时间尾巴均可解析', () {
      expect(CalendarGrid.parseIsoDate('2026-09-11'), DateTime(2026, 9, 11));
      expect(
        CalendarGrid.parseIsoDate('2026-09-11T00:00:00Z'),
        DateTime(2026, 9, 11),
      );
    });

    test('空值与垃圾串返回 null', () {
      expect(CalendarGrid.parseIsoDate(null), isNull);
      expect(CalendarGrid.parseIsoDate(''), isNull);
      expect(CalendarGrid.parseIsoDate('garbage'), isNull);
      expect(CalendarGrid.parseIsoDate('9999-99-99'), isNull);
    });
  });

  test('isSameDay / monthLabel / dayLabel', () {
    expect(
      CalendarGrid.isSameDay(DateTime(2026, 9, 11, 8, 30), DateTime(2026, 9, 11)),
      isTrue,
    );
    expect(
      CalendarGrid.isSameDay(DateTime(2026, 9, 11), DateTime(2026, 9, 12)),
      isFalse,
    );
    expect(CalendarGrid.monthLabel(DateTime(2026, 9, 1)), '2026年9月');
    expect(CalendarGrid.dayLabel(DateTime(2026, 9, 11)), '9月11日');
    expect(CalendarGrid.weekdayLabels.length, 7);
    expect(CalendarGrid.weekdayLabels.first, '日');
  });
}
