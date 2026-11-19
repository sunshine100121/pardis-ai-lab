import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/live_time_answer.dart';

void main() {
  test('live device-clock routing in Persian and English', () {
    expect(LiveTimeAnswer.intent('الان ساعت چنده؟'), LiveTimeKind.clock);
    expect(LiveTimeAnswer.intent('ساعت الان چنده؟'), LiveTimeKind.clock);
    expect(LiveTimeAnswer.intent('الان چه ساعتیه؟'), LiveTimeKind.clock);
    expect(LiveTimeAnswer.intent('امروز چه تاریخیه؟'), LiveTimeKind.date);
    expect(LiveTimeAnswer.intent('امروز چندمه؟'), LiveTimeKind.date);
    expect(LiveTimeAnswer.intent('الان ساعت و تاریخ چنده؟'), LiveTimeKind.dateTime);
    expect(LiveTimeAnswer.intent('منطقه زمانی دستگاه چیه؟'), LiveTimeKind.zone);
    expect(LiveTimeAnswer.intent('what time is it now?'), LiveTimeKind.clock);
  });

  test('historical, foreign and sensor-value requests are not intercepted', () {
    for (final question in [
      'ساعت اوج آلودگی باغ کی است؟',
      'دمای حسگر باغ الان چنده؟',
      'در سال ۲۰۲۰ امروز چه اتفاقی افتاد؟',
      'ساعت توکیو چنده؟',
      'چه ساعتی به درختان آب بدهم؟',
    ]) {
      expect(LiveTimeAnswer.intent(question), isNull, reason: question);
    }
  });

  test('sensor timestamp is separate from device clock and encyclopedia', () {
    expect(
      LiveTimeAnswer.intent('آخرین به‌روزرسانی حسگر چه زمانی بوده؟'),
      LiveTimeKind.sensorUpdate,
    );
    expect(
      LiveTimeAnswer.intent('آخرین گزارش سنسور PM2.5 باغ کی بوده؟'),
      LiveTimeKind.sensorUpdate,
    );
  });

  test('device clock uses real local zone, not hard-coded Tehran', () {
    final instant = DateTime.utc(2026, 11, 19, 12, 34, 56);
    final local = instant.toLocal();
    final answer = LiveTimeAnswer.device(
      LiveTimeKind.clock,
      clock: () => instant,
    );
    expect(
      answer,
      contains(
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}',
      ),
    );
    expect(
      answer,
      contains(LiveTimeAnswer.zoneOffset(local.timeZoneOffset)),
    );
    expect(answer, contains('ساعت دستگاه'));
    expect(answer, isNot(contains('دانشنامه')));
    expect(
      LiveTimeAnswer.device(LiveTimeKind.date, clock: () => instant),
      contains('2026/11/19'),
    );
  });

  test('zone offset handles Iranian and negative half-hour offsets', () {
    expect(LiveTimeAnswer.zoneOffset(const Duration(minutes: 210)), 'UTC+03:30');
    expect(LiveTimeAnswer.zoneOffset(const Duration(minutes: -330)), 'UTC-05:30');
    expect(LiveTimeAnswer.zoneOffset(Duration.zero), 'UTC+00:00');
  });

  test('sensor changed, updated, reported and received times stay distinct', () {
    final state = <String, dynamic>{
      'last_changed_local': '2026-11-19T14:00:00.000+03:30',
      'last_updated_local': '2026-11-19T14:30:00.000+03:30',
      'last_reported_local': '2026-11-19T15:25:00.000+03:30',
      'received_at_local': '2026-11-19T15:30:00.000+03:30',
      'report_age_seconds': 300,
      'freshness': 'reported',
    };
    final result = LiveTimeAnswer.sensor('PM2.5 باغ', state);
    expect(result, contains('آخرین تغییر مقدار حسگر: 2026-11-19T14:00'));
    expect(result, contains('آخرین به‌روزرسانی وضعیت/ویژگی‌ها:'));
    expect(result, contains('آخرین گزارش ثبت‌شده حسگر:'));
    expect(result, contains('زمان دریافت اطلاعات توسط پالا:'));
    expect(result, contains('5 دقیقه'));
    expect(result, contains('منبع: Home Assistant'));
  });

  test('missing report or future event does not certify freshness', () {
    final state = <String, dynamic>{
      'last_updated_local': '2026-11-19T12:00:00.000+00:00',
      'received_at_local': '2026-11-19T12:05:00.000+00:00',
      'last_reported_local': null,
      'freshness': 'unverified',
    };
    final result = LiveTimeAnswer.sensor('حسگر باغ', state);
    expect(result, contains('تازگی اندازه‌گیری نیست'));
    expect(result, contains('ثبت نشده'));
    final future = LiveTimeAnswer.sensor('باغ', {
      ...state,
      'last_reported_local': '2026-11-19T12:10:00.000+00:00',
      'report_age_seconds': -300,
      'freshness': 'clock_mismatch',
    });
    expect(future, contains('اختلاف ساعت'));
  });
}
