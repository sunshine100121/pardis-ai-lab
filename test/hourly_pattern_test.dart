import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/hourly_pattern.dart';

void main() {
  test(
    'hour-of-day summary is data-derived with explicit missing coverage',
    () {
      final from = DateTime.utc(2026, 1, 1), to = DateTime.utc(2026, 1, 3);
      final data = [
        HourlyValue(DateTime.utc(2026, 1, 1, 0), 12),
        HourlyValue(DateTime.utc(2026, 1, 2, 0), 24),
        HourlyValue(DateTime.utc(2026, 1, 1, 1), null),
      ];
      final profile = HourlyPattern.summarize(
        fromUtc: from,
        toUtc: to,
        samples: data,
      );
      expect(profile.length, 24);
      final first = profile[DateTime.utc(2026, 1, 1, 0).toLocal().hour];
      expect(first.expectedHours, 2);
      expect(first.validHours, 2);
      expect(first.mean, 18);
      expect(first.coverage, 1);
      final missing = profile[DateTime.utc(2026, 1, 1, 1).toLocal().hour];
      expect(missing.expectedHours, 2);
      expect(missing.validHours, 0);
      expect(missing.mean, isNull); // Never invent zero pollution.
      expect(missing.coverage, 0);
    },
  );
  test('duplicate statistics buckets fail instead of double-counting', () {
    final at = DateTime.utc(2026, 1, 1);
    expect(
      () => HourlyPattern.summarize(
        fromUtc: at,
        toUtc: at.add(const Duration(hours: 1)),
        samples: [HourlyValue(at, 2), HourlyValue(at, 100)],
      ),
      throwsFormatException,
    );
  });
  test(
    'half-hour UTC offset preserves real interval labels and expected coverage',
    () {
      final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 1, 3);
      final profile = HourlyPattern.summarize(
        fromUtc: start,
        toUtc: end,
        samples: [
          HourlyValue(start, 10),
          HourlyValue(start.add(const Duration(days: 1)), 20),
        ],
        utcOffsetAt: (_) => const Duration(hours: 3, minutes: 30),
      );
      expect(profile[3].mean, 15);
      expect(profile[3].localInterval, '03:30–04:30');
      expect(profile[3].utcOffsetMinutes, {210});
      expect(profile[3].expectedHours, 2);
      expect(profile[3].coverage, 1);
      expect(profile[23].localInterval, '23:30–00:30');
    },
  );
  test('mixed local start minutes cannot be labelled as one exact hour', () {
    final start = DateTime.utc(2026, 1, 1),
        middle = DateTime.utc(2026, 1, 2),
        end = DateTime.utc(2026, 1, 3);
    final profile = HourlyPattern.summarize(
      fromUtc: start,
      toUtc: end,
      samples: [],
      utcOffsetAt: (at) => at.isBefore(middle)
          ? const Duration(hours: 3, minutes: 30)
          : const Duration(hours: 4),
    );
    expect(profile[4].startMinutes, {0, 30});
    expect(profile[4].localInterval, isNull);
  });
  test(
    'sub-millisecond bucket alignment and excessive samples are rejected',
    () {
      final start = DateTime.utc(2026, 1, 1), end = DateTime.utc(2026, 1, 2);
      expect(
        () => HourlyPattern.summarize(
          fromUtc: start.add(const Duration(microseconds: 1)),
          toUtc: end,
          samples: [],
        ),
        throwsFormatException,
      );
      expect(
        () => HourlyPattern.summarize(
          fromUtc: start,
          toUtc: end,
          samples: [HourlyValue(start.add(const Duration(microseconds: 1)), 2)],
        ),
        throwsFormatException,
      );
      expect(
        () => HourlyPattern.summarize(
          fromUtc: start,
          toUtc: end,
          samples: List.generate(
            10001,
            (i) => HourlyValue(start.subtract(Duration(hours: i + 1)), null),
          ),
        ),
        throwsFormatException,
      );
    },
  );
}
