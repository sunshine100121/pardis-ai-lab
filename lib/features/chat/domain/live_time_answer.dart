/// Offline, deterministic answers for device time and sensor timestamps.
/// No encyclopedia, network search or language-model generation is needed.
/// Device time and its UTC offset come from the Android operating system.
enum LiveTimeKind { clock, date, dateTime, zone, sensorUpdate }

class LiveTimeAnswer {
  const LiveTimeAnswer._();

  static String normalize(String input) => input
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(RegExp(r'[\u200c\u200f]'), ' ')
      .replaceAll(RegExp(r'[؟?!.,،؛:]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Conservative matching: other countries' times, historical dates,
  /// sensor values and timing advice remain on their existing routes.
  static LiveTimeKind? intent(String question) {
    final q = normalize(question).replaceFirst(
      RegExp(r'^(?:لطفا|لطفاً|خواهش می کنم|میشه|میشه بگی)\s+'),
      '',
    );
    final sensor = RegExp(
      r'(حسگر|سنسور|sensor|home assistant|هوم اسیستنت)',
      caseSensitive: false,
    ).hasMatch(q);
    if (sensor &&
        RegExp(r'(آخرین|last|recent|latest)').hasMatch(q) &&
        RegExp(
          r'(بروز|به روز|به روزرسان|اپدیت|آپدیت|گزارش|ثبت|تغییر|'
          r'updated|update|reported|report|changed|change)',
          caseSensitive: false,
        ).hasMatch(q)) {
      return LiveTimeKind.sensorUpdate;
    }
    if (sensor) return null;
    if (RegExp(
      r'^(?:منطقه زمانی|تایم زون|timezone|time zone)'
      r'(?: (?:من|دستگاه|گوشی|تبلت|الان|چیست|چیه|چنده|فعلی|current))*$',
    ).hasMatch(q)) {
      return LiveTimeKind.zone;
    }
    if (RegExp(
      r'^(?:الان|هم اکنون|اکنون|امروز) (?:ساعت و تاریخ|تاریخ و ساعت)'
      r'(?: (?:چنده|چیه|چند است|چیست))?$',
    ).hasMatch(q)) {
      return LiveTimeKind.dateTime;
    }
    if (RegExp(
      r'^(?:(?:الان|اکنون|هم اکنون) )?'
      r'(?:ساعت(?: الان)? (?:چنده|چند است|چند شده|چیه|چیست)|'
      r'چه ساعتی(?:ه| هست| است)?|'
      r'ساعت چند(?:ه| است)?|'
      r'what time is it(?: now)?|'
      r'what is the (?:current )?time|current time|time now)$',
    ).hasMatch(q)) {
      return LiveTimeKind.clock;
    }
    if (RegExp(
      r'^(?:(?:امروز|الان) (?:چندمه|چه روزیه|چه روزی است|'
      r'چه تاریخیه|چه تاریخی است|چه روز هفته ایه)|'
      r'تاریخ امروز(?: چیه| چیست| چندمه)?|'
      r'امروز چه روزی از هفته است|'
      r'what is today.s date|'
      r'what date is it today|today.s date|current date)$',
    ).hasMatch(q)) {
      return LiveTimeKind.date;
    }
    return null;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String zoneOffset(Duration offset) {
    final minutes = offset.inMinutes;
    final sign = minutes < 0 ? '-' : '+';
    final absolute = minutes.abs();
    return 'UTC$sign${_two(absolute ~/ 60)}:${_two(absolute % 60)}';
  }

  static const weekdays = [
    'دوشنبه',
    'سه‌شنبه',
    'چهارشنبه',
    'پنجشنبه',
    'جمعه',
    'شنبه',
    'یکشنبه',
  ];

  static String device(LiveTimeKind kind, {DateTime Function()? clock}) {
    final local = (clock ?? DateTime.now)().toLocal();
    final date = '${local.year}/${_two(local.month)}/${_two(local.day)}';
    final time =
        '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
    final zone =
        'منطقه زمانی دستگاه: ${local.timeZoneName} '
        '(${zoneOffset(local.timeZoneOffset)})';
    return switch (kind) {
      LiveTimeKind.clock => 'ساعت دستگاه: $time\n$zone',
      LiveTimeKind.date =>
        'تاریخ دستگاه (میلادی): $date، '
            '${weekdays[local.weekday - 1]}\n$zone',
      LiveTimeKind.dateTime =>
        'ساعت دستگاه: $time\n'
            'تاریخ دستگاه (میلادی): $date، '
            '${weekdays[local.weekday - 1]}\n$zone',
      LiveTimeKind.zone => zone,
      LiveTimeKind.sensorUpdate => throw ArgumentError(
        'Sensor time needs a verified Home Assistant response',
      ),
    };
  }

  static String sensor(String label, Map<String, dynamic> state) {
    String display(Object? value) => value is String && value.isNotEmpty
        ? value
        : 'در Home Assistant ثبت نشده';
    final age = state['report_age_seconds'];
    final freshness = state['freshness'];
    final ageText = age is int && age >= 0
        ? age < 60
              ? '$age ثانیه'
              : age < 3600
              ? '${age ~/ 60} دقیقه'
              : '${age ~/ 3600} ساعت و ${(age % 3600) ~/ 60} دقیقه'
        : 'نامشخص';
    final freshnessText = switch (freshness) {
      'reported' => 'آخرین گزارش $ageText پیش ثبت شده است.',
      'check_age' =>
        'آخرین گزارش $ageText پیش ثبت شده؛ '
            'تازه‌بودن لحظه‌ای حسگر تأیید نیست.',
      'clock_mismatch' =>
        'زمان گزارش حسگر از زمان دریافت جلوتر است؛ '
            'اختلاف ساعت را بررسی کنید.',
      _ =>
        'زمان آخرین گزارش در دسترس نیست؛ '
            'دریافت پاسخ جدید به معنی تازگی اندازه‌گیری نیست.',
    };
    return 'منبع: Home Assistant · حسگر «$label»\n'
        'آخرین تغییر مقدار حسگر: ${display(state['last_changed_local'])}\n'
        'آخرین به‌روزرسانی وضعیت/ویژگی‌ها: '
        '${display(state['last_updated_local'])}\n'
        'آخرین گزارش ثبت‌شده حسگر: '
        '${display(state['last_reported_local'])}\n'
        'زمان دریافت اطلاعات توسط پالا: ${display(state['received_at_local'])}\n'
        'تازگی اطلاعات: $freshnessText\n'
        'همه زمان‌ها به منطقه زمانی دستگاه تبدیل شده‌اند؛ '
        'هر زمان با اختلاف UTC خودش نمایش داده شده است.';
  }
}
