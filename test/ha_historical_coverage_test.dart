import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/ha_historical_coverage.dart';
import 'package:ondevice_llm/features/knowledge/hourly_pattern.dart';

void main() {
  test('six-month PM2.5: sparse real hours, gaps, extrema and coverage', () {
    final from = DateTime.utc(2026, 1, 1);
    final to = DateTime.utc(2026, 7, 1);
    final second = from.add(const Duration(hours: 25));
    final last = to.subtract(const Duration(hours: 1));
    final result = HaHistoricalCoverage.summarize(
      fromUtc: from,
      toUtc: to,
      samples: [
        HourlyValue(
          from.add(const Duration(hours: 24)),
          12,
          minimum: 10,
          maximum: 14,
        ),
        HourlyValue(second, 18, minimum: 16, maximum: 20),
        HourlyValue(last, 30, minimum: 25, maximum: 45),
      ],
    );
    expect(result['expected_hours'], 4344);
    expect(result['valid_hours'], 3);
    expect(result['missing_hours'], 4341);
    expect(result['coverage'], closeTo(3 / 4344, 0.0000001));
    expect(result['coverage_percent'], closeTo(0.07, 0.001));
    expect(result['mean'], 20);
    expect(result['min'], 10);
    expect(result['max'], 45);
    expect(result['available_from_utc'], '2026-01-02T00:00:00.000Z');
    expect(result['available_until_utc'], '2026-07-01T00:00:00.000Z');
    expect(result['missing_intervals_total'], 2);
    expect((result['missing_intervals'] as List).first['hours'], 24);
    expect(result['period_representative'], false);
  });

  test(
    'empty six-month statistic has no fabricated number or observed period',
    () {
      final result = HaHistoricalCoverage.summarize(
        fromUtc: DateTime.utc(2026, 1, 1),
        toUtc: DateTime.utc(2026, 7, 1),
        samples: const <HourlyValue>[],
      );
      expect(result['coverage_percent'], 0);
      expect(result['valid_hours'], 0);
      expect(result['reported_statistic_hours'], 0);
      expect(result['mean'], isNull);
      expect(result['min'], isNull);
      expect(result['max'], isNull);
      expect(result['available_from_utc'], isNull);
      expect((result['missing_intervals'] as List).single['hours'], 4344);
    },
  );

  test('mean-only stats cannot masquerade as observed min or max', () {
    final from = DateTime.utc(2026, 1, 1);
    final result = HaHistoricalCoverage.summarize(
      fromUtc: from,
      toUtc: from.add(const Duration(hours: 2)),
      samples: [HourlyValue(from, 9)],
    );
    expect(result['mean'], 9);
    expect(result['min'], isNull);
    expect(result['max'], isNull);
    expect(result['coverage_percent'], 50);
    expect(result['missing_intervals_total'], 1);
  });

  test('null hourly mean is missing even if min and max were recorded', () {
    final from = DateTime.utc(2026, 1, 1);
    final result = HaHistoricalCoverage.summarize(
      fromUtc: from,
      toUtc: from.add(const Duration(hours: 2)),
      samples: [
        HourlyValue(from, null, minimum: 1, maximum: 5),
        HourlyValue(from.add(const Duration(hours: 1)), 7),
      ],
    );
    expect(result['valid_hours'], 1);
    expect(result['reported_statistic_hours'], 2);
    expect(result['coverage_percent'], 50);
    expect(result['mean'], 7);
    expect(result['min'], 1);
    expect(result['max'], 5);
    expect(result['missing_hours'], 1);
  });

  test('invalid and duplicate hourly statistics fail closed', () {
    final from = DateTime.utc(2026, 1, 1);
    final to = from.add(const Duration(hours: 2));
    for (final records in [
      [HourlyValue(from, 4), HourlyValue(from, 5)],
      [HourlyValue(from.add(const Duration(minutes: 1)), 3)],
      [HourlyValue(from, double.nan)],
      [HourlyValue(from, 3, minimum: 7, maximum: 2)],
    ]) {
      expect(
        () => HaHistoricalCoverage.summarize(
          fromUtc: from,
          toUtc: to,
          samples: records,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'long scattered missing intervals are listed with explicit truncation',
    () {
      final from = DateTime.utc(2026, 1, 1);
      final result = HaHistoricalCoverage.summarize(
        fromUtc: from,
        toUtc: from.add(const Duration(hours: 200)),
        samples: [
          for (var hour = 1; hour < 200; hour += 2)
            HourlyValue(from.add(Duration(hours: hour)), 5),
        ],
      );
      expect(result['missing_intervals_total'], 100);
      expect((result['missing_intervals'] as List).length, 48);
      expect(result['missing_intervals_omitted'], 52);
      expect(result['missing_hours'], 100);
    },
  );
}
