import 'package:fitcheck/services/widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('halfPeriodIndexOf (02:00/14:00 boundaries, local)', () {
    int day(int y, int m, int d) => y * 10000 + m * 100 + d;

    test('01:59 belongs to previous day second period', () {
      final half = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 10, 1, 59));
      expect(half, day(2026, 5, 9) * 2 + 1);
    });

    test('02:00 opens the first period of the day', () {
      final half = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 10, 2));
      expect(half, day(2026, 5, 10) * 2);
    });

    test('13:59 still first period', () {
      final half = WidgetService.halfPeriodIndexOf(
        DateTime(2026, 5, 10, 13, 59),
      );
      expect(half, day(2026, 5, 10) * 2);
    });

    test('14:00 flips to the second period', () {
      final half = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 10, 14));
      expect(half, day(2026, 5, 10) * 2 + 1);
    });

    test('periods are monotonic across the boundary', () {
      final a = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 10, 13, 59));
      final b = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 10, 14));
      final c = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 11, 1, 59));
      final d = WidgetService.halfPeriodIndexOf(DateTime(2026, 5, 11, 2));
      expect(b, a + 1);
      expect(c, b);
      expect(d, c + 1);
    });
  });
}
