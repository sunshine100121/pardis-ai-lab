/// Local, app-owned Persian mapping for explicitly permitted HA sensor names.
/// The model NEVER chooses an entity ID; no discovery or HA service calls.
class HaSensorMatch {
  const HaSensorMatch(this.candidates);
  final List<MapEntry<String, dynamic>> candidates;
  MapEntry<String, dynamic>? get selected =>
      candidates.length == 1 ? candidates.single : null;
  bool get ambiguous => candidates.length > 1;
}

class HaSensorLanguage {
  const HaSensorLanguage._();

  static String normalize(String text) => text
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('ۀ', 'ه')
      .replaceAll(RegExp(r'[\u200c\u200f\u0640]'), ' ')
      .replaceAll(RegExp(r'[_/.\-:،؛؟?!()\[\]]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _has(String input, Iterable<String> aliases) {
    final padded = ' $input ';
    return aliases.any(
      (s) => padded.contains(' ${normalize(s)} '),
    );
  }

  static const _groups = <String, List<String>>{
    'garden': ['باغ', 'محوطه', 'بیرون', 'فضای باز', 'outdoor', 'garden'],
    'indoor': ['داخل', 'خانه', 'ساختمان', 'اتاق', 'indoor'],
    'rosemary': ['رزماری', 'رزمری', 'rosemary', 'rzmry'],
    'rose': ['گل رز', 'رز', 'rose'],
    'kitchen': ['آشپزخانه', 'آشپزخونه', 'مطبخ', 'kitchen', 'مدبق'],
    'living': ['پذیرایی', 'هال', 'نشیمن', 'living'],
    'bedroom': ['اتاق خواب', 'خواب', 'bedroom'],
    'storage': ['انباری', 'storage'],
    'pool': ['استخر', 'pool'],
    'tank': ['مخزن', 'تانکر', 'tank'],
    'greenhouse': ['گلخانه', 'greenhouse'],
  };

  static Set<String> _places(String text) => {
    for (final group in _groups.entries)
      if (_has(text, group.value)) group.key,
  };

  static String? _kind(String text) {
    final q = normalize(text);
    if (_has(q, ['رطوبت خاک', 'نم خاک', 'نم زمین', 'soil moisture',
      'soil humidity', 'soil water', 'soilmoisture']) ||
        (_has(q, ['خاک', 'خاکش', 'soil']) &&
            _has(q, ['رطوبت', 'نم', 'moisture', 'humidity', 'خیس']))) {
      return 'soil_moisture';
    }
    if (_has(q, ['دما', 'دمای', 'درجه', 'حرارت', 'گرمی', 'سردی',
      'temperature', 'temp'])) {
      return 'temperature';
    }
    if (_has(q, ['رطوبت', 'نم', 'شرجی', 'humidity', 'humid'])) {
      return 'humidity';
    }
    if (_has(q, ['آلودگی', 'الودگی', 'ذرات معلق', 'pm2 5', 'pm25', 'pm 2 5'])) {
      return 'pm25';
    }
    if (_has(q, ['دی اکسید کربن', 'co2', 'کربن دی اکسید'])) return 'co2';
    if (_has(q, ['ولتاژ', 'ولتهاژ', 'voltage'])) return 'voltage';
    if (_has(q, ['شارژ باتری', 'باتری', 'soc', 'battery'])) return 'battery';
    if (_has(q, ['سطح آب', 'ارتفاع آب', 'میزان آب', 'water level',
      'waterlevel'])) {
      return 'water_level';
    }
    if (_has(q, ['توان', 'power', 'مصرف برق', 'مصرف انرژی', 'energy'])) {
      return 'power';
    }
    if (_has(q, ['باران', 'بارندگی', 'rain', 'rainfall'])) return 'rain';
    if (_has(q, ['باد', 'سرعت باد', 'wind'])) return 'wind';
    if (_has(q, ['نور', 'روشنایی', 'illuminance', 'light level'])) {
      return 'light';
    }
    if (_has(q, ['هدایت الکتریکی', 'شوری خاک', 'conductivity'])) {
      return 'conductivity';
    }
    return null;
  }

  /// Sensor intent only: no encyclopedic explanations or historical queries.
  /// An unspecific "How hot should rosemary be?" is NOT a live observation.
  static bool isLiveQuestion(String question) {
    final q = normalize(question);
    if (q.isEmpty || _has(q, [
      'دیروز', 'پارسال', 'سال قبل', 'هفته پیش', 'ماه قبل',
      'تاریخچه', 'میانگین', 'نمودار', 'قبلا', 'قبلاً',
      'علت', 'چرا', 'چگونه کار', 'روش', 'مناسب', 'ایده آل',
      'ایده آلش', 'چقدر باید', 'چه زمانی', 'کی', 'چطور تنظیم',
      'آموزش', 'مقایسه', 'در سال', 'last year', 'yesterday',
    ])) {
      return false;
    }
    final asksReading = RegExp(
      r'(^| )(چقدره|چقدره؟|چقدر|چنده|چند|چطوره|چطورن|چیست|چیه|'
      r'چه وضعی|وضعیت|میزان|مقدار|الان|همین الان|فعلی|'
      r'گزارش|نشان میده|نشون میده|است|هست|'
      r'how much|current|right now|reading|value)( |$)',
    ).hasMatch(q);
    final asksSensor = _kind(q) != null ||
        _has(q, ['حسگر', 'سنسور', 'sensor']);
    return asksSensor && asksReading;
  }

  /// Match a *configured* Persian label/room/alias to a unique allowed ID.
  /// A more specific plant sensor cannot stand in for a generic garden one.
  /// Equal top scores remain ambiguous; never silently pick the first.
  static HaSensorMatch resolve(
    String question,
    Map<String, dynamic> allowed, {
    bool singleFallback = false,
  }) {
    final q = normalize(question);
    final wantedKind = _kind(q);
    final wantedPlaces = _places(q);
    final matches = <(int, MapEntry<String, dynamic>)>[];
    for (final e in allowed.entries) {
      if (e.value is! String || (e.value as String).trim().isEmpty) continue;
      final display = normalize(e.value as String);
      final meta = normalize('${e.value} ${e.key}');
      final kind = _kind(meta);
      final places = _places(meta);
      if (wantedKind != null && kind != wantedKind) continue;
      if (!places.containsAll(wantedPlaces)) continue;
      if ((wantedPlaces.contains('garden') && places.contains('indoor')) ||
          (wantedPlaces.contains('indoor') && places.contains('garden'))) {
        continue;
      }
      // Explicitly requested plant/place is required, and additional
      // plant-specific labels never silently substitute for a whole garden.
      final extraPlant = {'rosemary', 'rose'}.difference(wantedPlaces);
      if (wantedPlaces.isNotEmpty && places.any(extraPlant.contains)) {
        continue;
      }
      if (wantedKind == null &&
          !(display.length >= 3 &&
              (' $q ').contains(' $display ')) &&
          !q.contains(normalize(e.key))) {
        continue;
      }
      var score = 10 + wantedPlaces.length * 15;
      if (display.isNotEmpty && (' $q ').contains(' $display ')) score += 120;
      if (wantedKind != null) score += 30;
      // Prefer room-specific sensors to generic sensors, but not a
      // particular plant's sensor when the plant was not requested.
      score -= places.difference(wantedPlaces).length * 3;
      matches.add((score, e));
    }
    if (matches.isEmpty) {
      if (singleFallback && allowed.length == 1 &&
          wantedKind == null && wantedPlaces.isEmpty) {
        return HaSensorMatch(allowed.entries.toList());
      }
      return const HaSensorMatch([]);
    }
    matches.sort((a, b) => b.$1.compareTo(a.$1));
    final top = matches.first.$1;
    return HaSensorMatch([
      for (final pair in matches)
        if (pair.$1 == top) pair.$2,
    ]);
  }
  /// Display one actual allow-listed state. "Current" means fetched now,
  /// not that the sensing hardware took a new measurement just now.
  static String currentValue(String label, Map<String, dynamic> state) {
    final raw = state['state']?.toString().trim() ?? '';
    final unit = state['unit'] is String
        ? (state['unit'] as String).trim()
        : '';
    final unavailable = raw.isEmpty ||
        {'unknown', 'unavailable', 'none', 'null'}.contains(raw.toLowerCase());
    final age = state['report_age_seconds'];
    final freshness = state['freshness'];
    final seenAt = state['received_at_local'] ?? 'نامشخص';
    final changedAt = state['last_updated_local'] ?? 'نامشخص';
    final reportedAt = state['last_reported_local'] ?? 'ثبت نشده';
    final value = unavailable
        ? 'در دسترس نیست (unknown/unavailable)'
        : unit.isEmpty ? raw : '$raw $unit';
    final freshnessText = switch (freshness) {
      'clock_mismatch' => 'زمان حسگر از ساعت دستگاه جلوتر است؛ '
          'این داده قابل تأیید به‌عنوان اندازه‌گیری تازه نیست.',
      'check_age' => age is int && age >= 0
          ? 'آخرین گزارش ${age ~/ 60} دقیقه قبل ثبت شده؛ '
              'ممکن است مقدار قدیمی باشد.'
          : 'آخرین گزارش قدیمی است؛ تازگی تأیید نشده.',
      'reported' => age is int && age >= 0
          ? 'آخرین گزارش ${age ~/ 60} دقیقه قبل ثبت شده است.'
          : 'زمان دریافت گزارش معتبر است.',
      _ => 'زمان آخرین گزارش موجود نیست؛ '
          'تازه‌بودن اندازه‌گیری تأیید نشده است.',
    };
    return 'Home Assistant · $label\n'
        'مقدار ثبت‌شده: $value\n'
        'زمان دریافت پاسخ توسط پالا: $seenAt\n'
        'آخرین به‌روزرسانی وضعیت: $changedAt\n'
        'آخرین گزارش حسگر: $reportedAt\n'
        '$freshnessText\n'
        'این پاسخ از حسگر مجاز خوانده شده، نه از دانشنامه یا حدس Qwen.';
  }

}
