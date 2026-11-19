import 'hourly_pattern.dart';

/// Deterministic, read-only period summary of real HA hourly statistics.
/// Missing buckets are never interpolated or silently filled with zero.
class HaHistoricalCoverage {
  static const int maxListedGaps = 48;

  static Map<String, dynamic> summarize({
    required DateTime fromUtc,
    required DateTime toUtc,
    required Iterable<HourlyValue> samples,
  }) {
    final start = fromUtc.toUtc();
    final end = toUtc.toUtc();
    final span = end.difference(start);
    if (!start.isBefore(end) ||
        span > const Duration(days: 190) ||
        span.inSeconds % Duration.secondsPerHour != 0 ||
        start.minute != 0 ||
        end.minute != 0 ||
        start.second != 0 ||
        end.second != 0 ||
        start.millisecond != 0 ||
        end.millisecond != 0 ||
        start.microsecond != 0 ||
        end.microsecond != 0) {
      throw const FormatException('بازه ساعتی تاریخی معتبر نیست.');
    }

    final expected = span.inHours;
    final seen = <int>{};
    final recordedMeans = <int>{};
    final recordedAny = <int>{};
    var sumMeans = 0.0;
    var minHours = 0;
    var maxHours = 0;
    double? lowest;
    double? highest;
    DateTime? first;
    DateTime? last;
    var rows = 0;

    for (final item in samples) {
      if (++rows > 10000) {
        throw const FormatException('آمار تاریخی بیش از سقف مجاز است.');
      }
      final at = item.at.toUtc();
      if (at.isBefore(start) || !at.isBefore(end)) continue;
      if (at.minute != 0 ||
          at.second != 0 ||
          at.millisecond != 0 ||
          at.microsecond != 0 ||
          !seen.add(at.millisecondsSinceEpoch)) {
        throw const FormatException('زمان یا تکرار آمار تاریخی نامعتبر است.');
      }
      final mean = item.mean;
      final minimum = item.minimum;
      final maximum = item.maximum;
      if ((mean != null && !mean.isFinite) ||
          (minimum != null && !minimum.isFinite) ||
          (maximum != null && !maximum.isFinite) ||
          (minimum != null && maximum != null && minimum > maximum)) {
        throw const FormatException('مقادیر آمار تاریخی معتبر نیست.');
      }
      if (mean == null && minimum == null && maximum == null) continue;
      recordedAny.add(at.millisecondsSinceEpoch);
      if (first == null || at.isBefore(first)) first = at;
      if (last == null || at.isAfter(last)) last = at;
      if (mean != null) {
        recordedMeans.add(at.millisecondsSinceEpoch);
        sumMeans += mean;
        if (!sumMeans.isFinite) {
          throw const FormatException('تجمیع میانگین‌های تاریخی نامعتبر است.');
        }
      }
      if (minimum != null) {
        minHours++;
        if (lowest == null || minimum < lowest) lowest = minimum;
      }
      if (maximum != null) {
        maxHours++;
        if (highest == null || maximum > highest) highest = maximum;
      }
    }

    final valid = recordedMeans.length;
    final coverage = valid / expected;
    final gaps = <Map<String, dynamic>>[];
    var missingIntervals = 0;
    DateTime? gapStart;

    void closeGap(DateTime at) {
      final begin = gapStart;
      if (begin == null) return;
      missingIntervals++;
      if (gaps.length < maxListedGaps) {
        gaps.add({
          'from_utc': begin.toIso8601String(),
          'to_utc': at.toIso8601String(),
          'hours': at.difference(begin).inHours,
        });
      }
      gapStart = null;
    }

    for (
      var at = start;
      at.isBefore(end);
      at = at.add(const Duration(hours: 1))
    ) {
      if (recordedMeans.contains(at.millisecondsSinceEpoch)) {
        closeGap(at);
      } else {
        gapStart ??= at;
      }
    }
    closeGap(end);

    return {
      'from_utc': start.toIso8601String(),
      'to_utc': end.toIso8601String(),
      'expected_hours': expected,
      'valid_hours': valid,
      'reported_statistic_hours': recordedAny.length,
      'coverage': coverage,
      'coverage_percent': double.parse((coverage * 100).toStringAsFixed(2)),
      'coverage_basis':
          'ساعت‌های دارای میانگین واقعی در آمار ساعتی HA / ساعت‌های درخواستی؛ '
          'این نسبت اثبات‌کننده کارکرد پیوسته حسگر درون هر ساعت نیست.',
      'missing_hours': expected - valid,
      'missing_intervals': gaps,
      'missing_intervals_total': missingIntervals,
      'missing_intervals_omitted': missingIntervals - gaps.length,
      'available_from_utc': first?.toIso8601String(),
      'available_until_utc': last == null
          ? null
          : last.add(const Duration(hours: 1)).toIso8601String(),
      'mean': valid == 0 ? null : sumMeans / valid,
      'mean_hours': valid,
      'mean_basis':
          'میانگین ساده میانگین‌های ساعتی موجود؛ '
          'میانگین تمام شش ماه یا میانگین زمان‌وزن‌دار خام نیست.',
      'min': lowest,
      'max': highest,
      'min_hours': minHours,
      'max_hours': maxHours,
      'extrema_basis':
          'فقط min و max واقعی بازه‌های ساعتی HA؛ '
          'از میانگین‌ها حداقل و حداکثر ساخته نمی‌شود.',
      'period_representative': valid == expected,
      'limitation_period': valid == expected
          ? 'پوشش همه باکت‌های ساعتی تأیید شد؛ '
                'گزارش ساعتی به معنی پوشش همه لحظات هر ساعت نیست.'
          : 'بازه درخواستی پوشش ناقص دارد؛ '
                'میانگین و دامنه فقط درباره داده‌های موجودند و '
                'برای ساعت‌های فاقد داده هیچ مقداری فرض نشده است.',
    };
  }
}
