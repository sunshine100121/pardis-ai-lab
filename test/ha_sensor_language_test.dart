import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/ha_sensor_language.dart';

void main() {
  const labels = <String, dynamic>{
    'sensor.garden_temperature': 'دمای محوطه باغ',
    'sensor.indoor_temperature': 'دمای داخل خانه',
    'sensor.garden_humidity': 'رطوبت باغ',
    'sensor.rosemary_soil_moisture': 'رطوبت خاک رزماری',
    'sensor.rose_soil_moisture': 'رطوبت خاک گل رز',
    'sensor.kitchen_temperature': 'دمای آشپزخانه',
  };

  test('colloquial Persian garden temperature resolves without entity ID', () {
    for (final q in [
      'دمای باغ چقدره؟',
      'الان دمای محوطه باغ چنده؟',
      'هوا تو باغ چند درجه است؟',
      'دمای باغ الان چند است',
    ]) {
      expect(
        HaSensorLanguage.isLiveQuestion(q),
        isTrue,
        reason: q,
      );
      expect(
        HaSensorLanguage.resolve(q, labels).selected?.key,
        'sensor.garden_temperature',
        reason: q,
      );
    }
  });

  test('soil moisture rosemary is not air humidity or rose moisture', () {
    for (final q in [
      'رطوبت خاک رزماری چطوره؟',
      'نم خاک رزمری چقدره؟',
      'رزمری خاکش چقدر نم داره؟',
    ]) {
      expect(HaSensorLanguage.isLiveQuestion(q), isTrue, reason: q);
      expect(
        HaSensorLanguage.resolve(q, labels).selected?.key,
        'sensor.rosemary_soil_moisture',
        reason: q,
      );
    }
    expect(
      HaSensorLanguage.resolve('رطوبت باغ چقدره؟', labels).selected?.key,
      'sensor.garden_humidity',
    );
  });

  test('room aliases do not confuse indoor, kitchen and garden', () {
    expect(
      HaSensorLanguage.resolve('دما آشپزخونه چنده؟', labels).selected?.key,
      'sensor.kitchen_temperature',
    );
    expect(
      HaSensorLanguage.resolve('دمای داخل خانه چطوره؟', labels).selected?.key,
      'sensor.indoor_temperature',
    );
    expect(
      HaSensorLanguage.resolve('دمای باغ چقدره؟', labels).selected?.key,
      'sensor.garden_temperature',
    );
  });

  test('multiple equally plausible sensors remain ambiguous', () {
    final possible = HaSensorLanguage.resolve('دمای باغ چقدره؟', {
      'sensor.east_temperature': 'دمای محوطه شرقی باغ',
      'sensor.west_temperature': 'دمای محوطه غربی باغ',
    });
    expect(possible.selected, isNull);
    expect(possible.ambiguous, isTrue);
    expect(possible.candidates, hasLength(2));
  });

  test('no matching allowed sensor is not replaced with similar indoor data', () {
    final possible = HaSensorLanguage.resolve('دمای باغ چقدره؟', {
      'sensor.indoor_temperature': 'دمای داخل ساختمان',
      'sensor.basil_humidity': 'رطوبت خاک ریحان',
    });
    expect(possible.candidates, isEmpty);
  });

  test('historical, explanatory and desired temperature remain Qwen questions', () {
    for (final q in [
      'آیا دمای مناسب رزماری چنده؟',
      'چرا دمای باغ بالا می رود؟',
      'دمای باغ دیروز چقدر بود؟',
      'چطور تنظیم دمای خانه را تغییر بدهم؟',
      'آفت‌های درخت گلابی چیست؟',
    ]) {
      expect(HaSensorLanguage.isLiveQuestion(q), isFalse, reason: q);
    }
  });

  test('large allow-list scales without reading or inventing extra IDs', () {
    final many = <String, dynamic>{
      for (var n = 0; n < 180; n++)
        'sensor.fixture_$n': 'حسگر آزمایشی شماره $n',
      'sensor.real_garden_temperature': 'دمای باغ',
    };
    final match = HaSensorLanguage.resolve('دمای باغ چقدره؟', many);
    expect(many.length, greaterThan(8));
    expect(match.selected?.key, 'sensor.real_garden_temperature');
    expect(match.candidates, hasLength(1));
  });

  test('old, unavailable, and unreported samples cannot look live', () {
    final base = <String, dynamic>{
      'received_at_local': '2026-11-19T15:30:00+03:30',
      'last_updated_local': '2026-11-19T12:00:00+03:30',
      'last_reported_local': null,
      'freshness': 'unverified',
      'unit': '°C',
    };
    final unavailable = HaSensorLanguage.currentValue('دمای باغ', {
      ...base,
      'state': 'unavailable',
    });
    expect(unavailable, contains('در دسترس نیست'));
    expect(unavailable, contains('تازه‌بودن اندازه‌گیری تأیید نشده'));
    expect(unavailable, isNot(contains('0 °C')));
    final stale = HaSensorLanguage.currentValue('دمای باغ', {
      ...base,
      'state': '18.4',
      'report_age_seconds': 3900,
      'freshness': 'check_age',
    });
    expect(stale, contains('18.4 °C'));
    expect(stale, contains('ممکن است مقدار قدیمی باشد'));
    final badClock = HaSensorLanguage.currentValue('دمای باغ', {
      ...base,
      'state': '18.4',
      'freshness': 'clock_mismatch',
    });
    expect(badClock, contains('ساعت دستگاه'));
  });
}
