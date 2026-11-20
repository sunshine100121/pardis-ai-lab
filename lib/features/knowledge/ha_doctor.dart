import 'ha_doctor_readouts.dart';

/// M14: deterministic, local HA diagnostics. Raw logs must never enter a report.
class HaDoctorSnapshot {
  final DateTime checkedAtUtc;
  final bool configRead, logRead;
  final String? coreVersion, transientLog;
  final int? componentCount;
  final List<HaDoctorSensor> sensors;
  final HaDoctorIntegrationReadout? integrations;
  final HaDoctorSystemReadout? system;
  const HaDoctorSnapshot({
    required this.checkedAtUtc,
    required this.configRead,
    required this.logRead,
    required this.coreVersion,
    required this.transientLog,
    required this.componentCount,
    required this.sensors,
    this.integrations,
    this.system,
  });
}

class HaDoctorSensor {
  final String id, state;
  const HaDoctorSensor(this.id, this.state);
}

abstract final class HaDoctorIntent {
  static final _doctor = RegExp(
    r'ha[ -]?doctor|پزشک خانه هوشمند|دکتر هوم اسیستنت|چکاپ سلامت سیستم|چکاپ خانه هوشمند',
    caseSensitive: false,
  );
  static final _target = RegExp(
    r'home[ -]?assistant|هوم[ -]?اسیستنت|خانه هوشمند',
    caseSensitive: false,
  );
  static final _problem = RegExp(
    r'عیب|خراب|مشکل|خطا|ارور|کند|کندی|سلامت|چکاپ|وضعیت سیستم|نسخه نصب|نسخه فعلی|لاگ|health|error|log|diagnos',
    caseSensitive: false,
  );
  static final _subsystem = RegExp(
    r'(?:recorder|ریکوردر|mqtt|zigbee2mqtt|پایگاه داده).{0,40}(?:خطا|خرابی|مشکل|قطع|error|failed)',
    caseSensitive: false,
  );
  static bool matches(String q) => _doctor.hasMatch(q) ||
      (_target.hasMatch(q) && _problem.hasMatch(q)) || _subsystem.hasMatch(q);
}

abstract final class HaDoctorDiagnosis {
  static final _db = RegExp(
    r'database disk image is malformed|btreeinitpage|sqlite3\.databaseerror|database corruption',
    caseSensitive: false,
  );
  static final _io = RegExp(r'disk i/o error', caseSensitive: false);
  static final _mqtt = RegExp(
    r'(mqtt|mosquitto).{0,100}(error|failed|timeout|disconnect)|'
    r'(error|failed|timeout|disconnect).{0,100}(mqtt|mosquitto)',
    caseSensitive: false,
  );
  static final _zigbee = RegExp(
    r'(zigbee|coordinator).{0,100}(error|failed|timeout|disconnect)|'
    r'(error|failed|timeout|disconnect).{0,100}(zigbee|coordinator)',
    caseSensitive: false,
  );

  static String report(
    HaDoctorSnapshot s, {
    Map<String, String> labels = const {},
    List<String> documentTitles = const [],
  }) {
    final logs = (s.transientLog ?? '').split('\n');
    final window = logs.length > 250 ? logs.skip(logs.length - 250) : logs;
    int count(RegExp pattern) => window.where(pattern.hasMatch).length;
    final db = s.logRead ? count(_db) : 0;
    final io = s.logRead ? count(_io) : 0;
    final mqtt = s.logRead ? count(_mqtt) : 0;
    final zigbee = s.logRead ? count(_zigbee) : 0;
    final unavailable = s.sensors.where((e) =>
        const {'unavailable', 'unknown', 'read_error'}
            .contains(e.state.toLowerCase())).toList();
    final recorder = db + io > 0;
    final integrationProblems = s.integrations?.problems ?? 0;
    final integrationRetries = s.integrations?.retrying ?? 0;
    final other = mqtt + zigbee > 0 || unavailable.isNotEmpty ||
        integrationProblems > 0 || integrationRetries > 0;
    final headline = recorder
        ? 'در لاگ خوانده‌شده نشانه خطای Recorder یا ذخیره‌سازی دیده شد.'
        : integrationProblems > 0
            ? 'در وضعیت Config Entry یک یا چند Integration خطای راه‌اندازی دارند.'
            : other ? 'چند نشانه نیازمند بررسی در نمونه محدود دیده شد.'
        : !s.configRead && !s.logRead
            ? 'داده تشخیصی کافی دریافت نشد؛ سلامت سیستم نامعلوم است.'
            : 'در نمونه محدود خطای مشخصی پیدا نشد؛ سلامت کامل تأیید نیست.';
    final confidence = recorder
        ? 'بالا برای مشاهده پیام خطا؛ نامعلوم برای علت ریشه‌ای و وضعیت فعلی'
        : other ? 'متوسط برای نشانه‌ها؛ پایین برای علت احتمالی'
        : 'پایین؛ پوشش بررسی محدود است';
    final out = StringBuffer('HA Doctor — بررسی اولیه فقط‌خواندنی\n');
    out.writeln('نتیجه: $headline');
    out.writeln('درجه اطمینان: $confidence');
    out.writeln('زمان نمونه‌برداری UTC: ' + s.checkedAtUtc.toIso8601String());
    out.writeln('\nشواهد واقعی Home Assistant (نه دانشنامه):');
    out.writeln(s.configRead
        ? '• نسخه Core: ' + (s.coreVersion ?? 'نامشخص') + '.'
        : '• نسخه Core: دریافت نشد.');
    if (s.system == null) {
      out.writeln('• نسخه OS و Supervisor: داده معتبر دریافت نشد؛ نامعلوم.');
    } else {
      final system = s.system!;
      out.writeln('• نسخه OS و Supervisor از حسگرهای رسمی: ' +
          (system.osVersion ?? 'OS نامعلوم') + ' / ' +
          (system.supervisorVersion ?? 'Supervisor نامعلوم') + '.');
      String metric(String title, double? value, String unit) =>
          '• $title: ' + (value == null ? 'نامعلوم یا حسگر غیرفعال'
            : value.toStringAsFixed(1) + ' ' + unit) +
            ' (تازگی مستقل نمونه تأیید نشده).';
      out.writeln(metric('CPU', system.processorPercent, '%'));
      out.writeln(metric('RAM', system.memoryPercent, '%'));
      out.writeln(metric('فضای آزاد دیسک', system.diskFreeGb, 'GB/GiB'));
      out.writeln('• وضعیت مدیر بکاپ: ' +
          (system.backupManagerState ?? 'نامعلوم یا حسگر غیرفعال') + '.');
      out.writeln('• آخرین بکاپ خودکار موفق (UTC): ' +
          (system.lastAutomaticBackupUtc?.toIso8601String() ??
              'نامعلوم یا حسگر غیرفعال') + '.');
      out.writeln('• آخرین تلاش بکاپ خودکار (UTC): ' +
          (system.lastAttemptedBackupUtc?.toIso8601String() ??
              'نامعلوم یا حسگر غیرفعال') + '.');
      out.writeln('• حسگرهای بکاپ، بکاپ‌های دستی، صحت فایل یا موفقیت Restore را تأیید نمی‌کنند.');
      out.writeln('• نسخه Supervisor به‌تنهایی به معنی سالم‌بودن سرویس نیست.');
    }
    out.writeln(s.componentCount == null
        ? '• فهرست اجزا: نامشخص.'
        : '• تعداد اجزای پیکربندی: ' + s.componentCount.toString() +
          '؛ این عدد سلامت Integrationها را نشان نمی‌دهد.');
    out.writeln(s.logRead
        ? '• لاگ خوانده شد؛ زمان وقوع پیام‌ها الزاماً زمان فعلی نیست.'
        : '• لاگ در دسترس نبود؛ این به معنی سالم‌بودن نیست.');
    if (recorder) {
      out.writeln('• الگوهای خرابی پایگاه داده: $db؛ خطای دیسک I/O: $io.');
      out.writeln('• این خطاها به‌تنهایی خرابی فیزیکی SSD یا ادامه خطا در لحظه حاضر را اثبات نمی‌کنند.');
    }
    if (s.integrations == null) {
      out.writeln('• وضعیت Integrationها: فهرست قابل‌خواندن نبود؛ نامعلوم.');
    } else {
      final items = s.integrations!;
      out.writeln('• Integrationها: ' +
          items.configured.toString() + ' پیکربندی فعال، ' +
          items.loaded.toString() + ' بارگذاری‌شده، ' +
          items.problems.toString() + ' خطای راه‌اندازی/مهاجرت، ' +
          items.retrying.toString() + ' در انتظار تلاش مجدد، ' +
          items.disabled.toString() + ' عمداً غیرفعال/نادیده‌گرفته‌شده.');
      out.writeln('• این شمارش وضعیت پیکربندی است، نه گواه سلامت همه دستگاه‌ها.');
    }
    if (mqtt > 0) out.writeln('• خطاهای مرتبط با MQTT: $mqtt.');
    if (zigbee > 0) out.writeln('• خطاهای مرتبط با Zigbee: $zigbee.');
    out.writeln('• فقط ' + s.sensors.length.toString() +
        ' حسگر مجاز نمونه‌برداری شد؛ نه همه تجهیزات.');
    for (final item in unavailable.take(3)) {
      final label = labels[item.id] ?? 'حسگر مجاز';
      final state = item.state == 'read_error' ? 'نتیجه خواندن نامعلوم' : item.state;
      out.writeln('• $label: $state؛ وضعیت فیزیکی دستگاه تأیید نشده است.');
    }
    out.writeln('\nبررسی‌های کم‌خطر پیشنهادی:');
    if (recorder) {
      out.writeln('۱. تاریخ و تکرار خطاهای Recorder را در بخش Logs بررسی کنید.');
      out.writeln('۲. فقط فضای آزاد دیسک و موجودبودن بکاپ معتبر را بررسی کنید؛ چیزی حذف نشود.');
      out.writeln('۳. پیش از هر تعمیر، وضعیت بکاپ و امکان بازگشت را بسنجید.');
    } else if (mqtt + zigbee > 0 || integrationProblems > 0 || integrationRetries > 0) {
      out.writeln('۱. وضعیت ارتباط سرویس و حسگرهای فعال مرتبط را در رابط HA بررسی کنید.');
      out.writeln('۲. زمان خطا و قطعی شبکه را مقایسه کنید؛ Restart خودکار نکنید.');
    } else {
      out.writeln('۱. وضعیت و تازگی داده حسگرهای حیاتی را در داشبورد بررسی کنید.');
      out.writeln('۲. برای تشخیص دقیق‌تر نشانه و زمان وقوع مشکل را مشخص کنید.');
    }
    out.writeln('\nمستندات محلی — جدا از داده زنده:');
    if (documentTitles.isEmpty) {
      out.writeln('• سند مرتبط در منابع مجاز این نوبت تأیید نشد.');
    } else {
      for (final title in documentTitles.take(2)) {
        out.writeln('• $title (راهنمای محلی، نه شاهد خرابی فعلی).');
      }
    }
    out.writeln('\nدانش داخلی Qwen برای این تشخیص استفاده نشد. '
        'هیچ Restart، Restore، تغییر تنظیمات یا کنترلی انجام نشد.');
    return out.toString().trimRight();
  }
}
