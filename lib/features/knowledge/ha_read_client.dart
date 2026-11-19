import 'dart:convert';
import 'dart:io';

import '../../data/network/web_search/search_models.dart';

/// A closed GET-only API surface. No model-selected URL, method or service call.
class HaReadClient {
  static void checkTokenOrigin(
    String? previousBase,
    Uri nextBase,
    String enteredToken,
  ) {
    if (enteredToken.isEmpty &&
        (previousBase == null ||
            Uri.parse(previousBase).origin != nextBase.origin)) {
      throw const FormatException(
        'برای نشانی جدید، توکن همان Home Assistant را دوباره وارد کنید؛ توکن قبلی به میزبان دیگری فرستاده نمی‌شود.',
      );
    }
  }

  final Uri base;
  final String _token;
  final Set<String> entities;
  final HttpClient Function() createClient;
  final DateTime Function() clock;
  HaReadClient({
    required this.base,
    required String token,
    required this.entities,
    HttpClient Function()? createClient,
    DateTime Function()? clock,
  }) : _token = token,
       createClient = createClient ?? HttpClient.new,
       clock = clock ?? DateTime.now {
    final ip = InternetAddress.tryParse(base.host);
    final b = ip?.rawAddress;
    final lan =
        b != null &&
        b.length == 4 &&
        (b[0] == 10 ||
            b[0] == 127 ||
            (b[0] == 192 && b[1] == 168) ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31));
    if (!lan ||
        !{'http', 'https'}.contains(base.scheme) ||
        base.userInfo.isNotEmpty ||
        !{'', '/'}.contains(base.path) ||
        base.hasQuery ||
        base.hasFragment ||
        token.trim().isEmpty ||
        token.contains('\n') ||
        token.contains('\r')) {
      throw const FormatException(
        'نشانی باید IP محلی Home Assistant و بدون مسیر اضافی باشد.',
      );
    }
    if (entities.isEmpty ||
        entities.length > 8 ||
        entities.any(
          (e) => !RegExp(r'^(sensor|binary_sensor)\.[a-z0-9_]+$').hasMatch(e),
        )) {
      throw const FormatException('یک تا هشت حسگر مجاز لازم است.');
    }
  }
  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final client = createClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'DIRECT';
    Future<dynamic> request() async {
      final req = await client.getUrl(
        base.replace(path: path, queryParameters: query),
      );
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final response = await req.close();
      if (response.statusCode != 200)
        throw const HttpException(
          'داده HA در دسترس نیست؛ دسترسی یا اتصال را بررسی کنید.',
        );
      final bytes = <int>[];
      await for (final part in response) {
        if (bytes.length + part.length > 2 * 1024 * 1024)
          throw const FormatException(
            'پاسخ تاریخچه بیش از سقف مجاز است؛ بازه کوتاه‌تر لازم است.',
          );
        bytes.addAll(part);
      }
      return jsonDecode(utf8.decode(bytes));
    }

    try {
      return await request().timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }

  void _allowed(String id) {
    if (!entities.contains(id))
      throw const FormatException('حسگر خارج از فهرست مجاز است.');
  }

  /// Time with explicit UTC offset, using the Android device's local zone.
  /// Never label a UTC timestamp as local time without conversion.
  static String localIso(DateTime timestamp) {
    final local = timestamp.toLocal();
    final minutes = local.timeZoneOffset.inMinutes;
    final sign = minutes < 0 ? '-' : '+';
    final hours = (minutes.abs() ~/ 60).toString().padLeft(2, '0');
    final rest = (minutes.abs() % 60).toString().padLeft(2, '0');
    return '${local.toIso8601String()}$sign$hours:$rest';
  }

  /// Accept only timestamps with an explicit zone; never assume local time.
  static DateTime? parseHaTimestamp(Object? value) {
    if (value is! String ||
        !RegExp(
          r'(?:Z|[+-]\d{2}:\d{2})$',
          caseSensitive: false,
        ).hasMatch(value)) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  Future<Map<String, dynamic>> state(String id) async {
    _allowed(id);
    final data = await _get('/api/states/$id');
    if (data is! Map<String, dynamic> ||
        data['entity_id'] != id ||
        data['state'] is! String) {
      throw const FormatException('پاسخ حسگر معتبر نیست.');
    }
    final updated = parseHaTimestamp(data['last_updated']);
    if (updated == null)
      throw const FormatException('زمان به‌روزرسانی حسگر معتبر نیست.');
    // last_changed: state value changed; last_updated: state or attributes
    // changed; last_reported: actual event (may be unavailable in REST).
    // Received-at is measured by PALA after the GET, not guessed from HA.
    final changed = parseHaTimestamp(data['last_changed']);
    final reported = parseHaTimestamp(data['last_reported']);
    final received = clock().toUtc();
    final ageSeconds = reported == null
        ? null
        : received.difference(reported.toUtc()).inSeconds;
    return {
      'entity_id': id,
      'state': data['state'],
      'last_changed': changed?.toUtc().toIso8601String(),
      'last_changed_local': changed == null ? null : localIso(changed),
      'last_updated': updated.toUtc().toIso8601String(),
      'last_updated_local': localIso(updated),
      'update_age_seconds': received.difference(updated.toUtc()).inSeconds,
      'received_at': received.toIso8601String(),
      'received_at_local': localIso(received),
      'last_reported': reported?.toUtc().toIso8601String(),
      'last_reported_local': reported == null ? null : localIso(reported),
      'report_age_seconds': ageSeconds,
      'freshness': reported == null
          ? 'unverified'
          : ageSeconds! < 0
          ? 'clock_mismatch'
          : ageSeconds > 1800
          ? 'check_age'
          : 'reported',
      'unit': (data['attributes'] is Map
          ? data['attributes']['unit_of_measurement']
          : null),
    };
  }

  Future<Map<String, dynamic>> history(
    String id,
    DateTime start,
    DateTime end,
  ) async {
    _allowed(id);
    if (!start.isBefore(end) ||
        end.difference(start) > const Duration(hours: 6))
      throw const FormatException('بازه تاریخچه باید حداکثر شش ساعت باشد.');
    final data = await _get(
      '/api/history/period/${start.toUtc().toIso8601String()}',
      {
        'filter_entity_id': id,
        'end_time': end.toUtc().toIso8601String(),
        'no_attributes': '',
        'significant_changes_only': '0',
      },
    );
    if (data is! List ||
        data.length > 1 ||
        (data.isNotEmpty && data.first is! List))
      throw const FormatException('ساختار تاریخچه معتبر نیست.');
    final rows = data.isEmpty ? <dynamic>[] : data.first as List;
    if (rows.length > 10000)
      throw const FormatException('تاریخچه بیش از سقف مجاز است.');
    return summarize(rows, id, start, end);
  }

  static Map<String, dynamic> summarize(
    List<dynamic> rows,
    String id,
    DateTime start,
    DateTime end,
  ) {
    final samples = <(DateTime, double)>[];
    var missing = 0;
    for (final row in rows) {
      if (row is! Map || row['entity_id'] != id)
        throw const FormatException('شناسه تاریخچه با حسگر مجاز یکسان نیست.');
      final at = parseHaTimestamp(row['last_updated'] ?? row['last_changed']);
      final value = double.tryParse(row['state']?.toString() ?? '');
      if (at == null) throw const FormatException('زمان تاریخچه معتبر نیست.');
      if (at.isBefore(start) || at.isAfter(end)) continue;
      if (value == null || !value.isFinite) {
        missing++;
        continue;
      }
      samples.add((at, value));
    }
    samples.sort((a, b) => a.$1.compareTo(b.$1));
    var gapSeconds = 0;
    var cursor = start;
    for (final s in samples) {
      final delta = s.$1.difference(cursor).inSeconds;
      if (delta > 300) gapSeconds += delta;
      cursor = s.$1;
    }
    if (end.difference(cursor).inSeconds > 300)
      gapSeconds += end.difference(cursor).inSeconds;
    final values = samples.map((e) => e.$2).toList();
    return {
      'entity_id': id,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'samples': values.length,
      'unavailable_samples': missing,
      'gaps_over_5min_seconds': gapSeconds,
      'min': values.isEmpty ? null : values.reduce((a, b) => a < b ? a : b),
      'max': values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b),
      'sample_mean': values.isEmpty
          ? null
          : values.reduce((a, b) => a + b) / values.length,
      'limitation': 'میانگین نمونه‌هاست، نه میانگین زمانی؛ Recorder ثبت با فاصله ثابت پنج دقیقه را تضمین نمی‌کند. شکاف ثبت به‌تنهایی اثبات قطعی قطع حسگر نیست.',
    };
  }

  static SearchResult evidence(
    String label,
    Map<String, dynamic> data,
  ) => SearchResult(
    title: 'Home Assistant · $label',
    url: 'pala-ha://sensor',
    snippet: '',
    source: 'Home Assistant · خواندن هنگام پرسش',
    rank: 0,
    pageText:
        'منشأ: داده واقعی Home Assistant (نه دانشنامه و نه دانش داخلی مدل).\n'
        'زمان دریافت UTC: ${data['received_at'] ?? DateTime.now().toUtc().toIso8601String()}\n'
        'زمان محلی دستگاه در last_changed_local، last_updated_local، '
        'last_reported_local و received_at_local درج شده است. '
        'last_updated فقط زمان تغییر وضعیت/ویژگی است، نه لزوماً زمان آخرین گزارش. '
        'اگر last_reported موجود نیست، تازگی داده تأیید نشده است. '
        'اگر report_age_seconds بیش از ۱۸۰۰ است، سن داده را اعلام کن؛ آن را لحظه‌ای ننام.\n'
        'سن منفی یعنی ساعت گزارش و دستگاه سازگار نیست؛ تازگی را تأییدشده معرفی نکن.\n'
        '${jsonEncode(data)}\n'
        'HA Doctor فقط تشخیص و پیشنهاد است؛ اجرای تعمیر مجاز نیست. '
        'وضعیت unknown/unavailable مقدار واقعی عددی نیست.',
    fetchedAt: DateTime.now().toUtc(),
  );
}
