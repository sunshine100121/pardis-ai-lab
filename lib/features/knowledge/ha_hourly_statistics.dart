import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ha_read_client.dart';
import 'hourly_pattern.dart';

/// Only one allow-listed sensor, hourly mean statistics and a bounded period.
/// This is a read-only Home Assistant WebSocket command, NOT a service call.
/// The URL/entity/time come from trusted app configuration, never from Qwen.
class HaHourlyStatistics {
  final Uri base;
  final String _token;
  final Set<String> entities;
  final Duration timeLimit;

  HaHourlyStatistics({
    required this.base,
    required String token,
    required Set<String> entities,
    this.timeLimit = const Duration(seconds: 45),
  }) : _token = token, entities = Set.unmodifiable(entities) {
    // The existing HA client validates private LAN IP, scheme, credentials,
    // entity domains and the same allow-list before any WebSocket handshake.
    HaReadClient(base: base, token: token, entities: entities);
    if (timeLimit <= Duration.zero || timeLimit > const Duration(seconds: 60)) {
      throw ArgumentError('Statistics deadline must be positive and bounded');
    }
  }

  static Uri wsUri(Uri base) => base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/websocket',
    query: null,
    fragment: null,
  );

  /// Extract one bounded series from the reply without inventing missing
  /// values. WebSocket uses millisecond epoch timestamps, not ISO timestamps.
  static List<HourlyValue> parseStatistics(
    Object? result, String entityId, DateTime start, DateTime end,
  ) {
    if (result is! Map || result.keys.any((k) => k != entityId)) {
      throw const FormatException('ساختار آمار حسگر معتبر نیست.');
    }
    final rows = result[entityId];
    if (rows == null) return const <HourlyValue>[]; // No long-term statistics.
    if (rows is! List || rows.length > 10000) {
      throw const FormatException('تعداد رکوردهای آماری نامعتبر است.');
    }
    final parsed = <HourlyValue>[];
    final seen = <int>{};
    for (final row in rows) {
      if (row is! Map || row['start'] is! num) {
        throw const FormatException('زمان آمار ساعتی نامعتبر است.');
      }
      final stamp = row['start'] as num;
      if (!stamp.isFinite || stamp != stamp.truncateToDouble() ||
          stamp.abs() > 8640000000000000) {
        throw const FormatException('زمان آمار ساعتی نامعتبر است.');
      }
      final at = DateTime.fromMillisecondsSinceEpoch(
        stamp.toInt(), isUtc: true,
      );
      if (at.isBefore(start) || !at.isBefore(end)) continue;
      if (at.minute != 0 || at.second != 0 || at.millisecond != 0 ||
          !seen.add(at.millisecondsSinceEpoch)) {
        throw const FormatException('بازه ساعتی نامنظم یا رکورد تکراری است.');
      }
      final raw = row['mean'];
      if (raw != null && raw is! num) {
        throw const FormatException('مقدار میانگین ساعتی نامعتبر است.');
      }
      final value = (raw as num?)?.toDouble();
      if (value != null && !value.isFinite) {
        throw const FormatException('مقدار نامتناهی در آمار یافت شد.');
      }
      parsed.add(HourlyValue(at, value));
    }
    return parsed;
  }

  Future<List<HourlyValue>> read({
    required String entityId,
    required DateTime fromUtc,
    required DateTime toUtc,
  }) async {
    if (!entities.contains(entityId)) {
      throw const FormatException('حسگر خارج از فهرست مجاز است.');
    }
    final start = fromUtc.toUtc(), end = toUtc.toUtc();
    if (!start.isBefore(end) ||
        end.difference(start) > const Duration(days: 190) ||
        start.minute != 0 || end.minute != 0 ||
        start.second != 0 || end.second != 0 ||
        start.millisecond != 0 || end.millisecond != 0 ||
        start.microsecond != 0 || end.microsecond != 0) {
      throw const FormatException('بازه آماری باید ساعتی و حداکثر ۱۹۰ روز باشد.');
    }

    // Authentication and all messages are handled inside one controlled read.
    // No token or raw server response is logged or returned to Qwen.
    final http=HttpClient()
      ..connectionTimeout=const Duration(seconds:10)
      ..findProxy=(_)=>'DIRECT';
    WebSocket? socket;
    StreamIterator<dynamic>? iterator;
    final clock = Stopwatch()..start();
    var finished = false;
    Future<T> bounded<T>(Future<T> Function() action, Duration phaseLimit) {
      final remaining = timeLimit - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Statistics deadline exceeded');
      }
      return action().timeout(remaining < phaseLimit ? remaining : phaseLimit);
    }
    Future<void> closeSocket(WebSocket value) async {
      try {
        await value.close(WebSocketStatus.normalClosure)
            .timeout(const Duration(seconds: 2));
      } catch (_) { /* Cleanup must not mask the original bounded result. */ }
    }
    try {
      final opening = WebSocket.connect(wsUri(base).toString(),
        compression: CompressionOptions.compressionOff,
        customClient: _SameOriginHandshakeClient(http, base),
        maxPayloadLength: 6 * 1024 * 1024,
      );
      // A timed-out Future does not cancel a late upgraded socket.
      unawaited(opening.then<void>((lateSocket) {
        if (finished) unawaited(closeSocket(lateSocket));
      }, onError: (Object error, StackTrace stack) {}));
      socket = await bounded(() => opening, const Duration(seconds: 10));
      iterator = StreamIterator<dynamic>(socket);
      Future<Map<String, dynamic>> next() async {
        final more = await bounded(() => iterator!.moveNext(), const Duration(seconds: 20));
        if (!more) throw const FormatException('اتصال آمار بسته شد.');
        final frame = iterator!.current;
        if (frame is! String || frame.length > 6 * 1024 * 1024) {
          throw const FormatException('اندازه یا نوع پاسخ آماری نامعتبر است.');
        }
        final data = jsonDecode(frame);
        if (data is! Map<String, dynamic>) {
          throw const FormatException('پیام آماری نامعتبر است.');
        }
        return data;
      }
      final challenge = await next();
      if (challenge['type'] != 'auth_required') {
        throw const FormatException('دست‌دهی احراز هویت معتبر نیست.');
      }
      socket.add(jsonEncode({'type': 'auth', 'access_token': _token}));
      final auth = await next();
      if (auth['type'] != 'auth_ok') {
        throw const FormatException('دسترسی خواندن آمار تأیید نشد.');
      }
      socket.add(jsonEncode({
        'id': 1,
        'type': 'recorder/statistics_during_period',
        'start_time': start.toIso8601String(),
        'end_time': end.toIso8601String(),
        'statistic_ids': [entityId],
        'period': 'hour',
        'types': ['mean'],
      }));
      final response = await next();
      if (response['id'] != 1 || response['type'] != 'result' ||
          response['success'] != true) {
        throw const FormatException('آمار بلندمدت موجود یا قابل‌دریافت نیست.');
      }
      return parseStatistics(response['result'], entityId, start, end);
    } finally {
      finished = true;
      http.close(force:true);
      if (iterator != null) {
        try { await iterator.cancel().timeout(const Duration(seconds: 2)); }
        catch (_) { /* Remaining cleanup is bounded too. */ }
      }
      if (socket != null) await closeSocket(socket);
    }
  }

  /// Safe, small, reproducible context for Qwen. Never send raw HA database.
  static Map<String, dynamic> report({
    required String entityId,
    required DateTime fromUtc,
    required DateTime toUtc,
    required List<HourlyValue> samples,
    Duration Function(DateTime utc)? utcOffsetAt,
  }) {
    final profile = HourlyPattern.summarize(
      fromUtc: fromUtc, toUtc: toUtc, samples: samples, utcOffsetAt: utcOffsetAt,
    );
    final total = profile.fold<int>(0, (a, h) => a + h.expectedHours);
    final present = profile.fold<int>(0, (a, h) => a + h.validHours);
    // Each hour-of-day needs good coverage before claiming a recurring peak.
    final adequate = profile.every((h) =>
      h.expectedHours > 0 && h.coverage >= 0.8 && h.mean != null &&
      h.mean!.isFinite && h.localInterval != null);
    final sorted = profile.where((h) => h.mean != null).toList()
      ..sort((a, b) => b.mean!.compareTo(a.mean!));
    final uniquePeak=adequate && sorted.length>=2 &&
      sorted.first.mean!>sorted[1].mean!;
    return {
      'kind': 'ha_hourly_statistics',
      'origin': 'Home Assistant recorder, hourly long-term mean',
      'entity_id': entityId,
      'from_utc': fromUtc.toUtc().toIso8601String(),
      'to_utc': toUtc.toUtc().toIso8601String(),
      'local_timezone': DateTime.now().timeZoneName,
      'expected_hours': total,
      'valid_hours': present,
      'coverage': total == 0 ? 0 : present / total,
      'coverage_adequate': adequate,
      'recurring_peak_supported': uniquePeak,
      'peak_hour_local': uniquePeak ? sorted.first.localHour : null,
      'peak_interval_local': uniquePeak ? sorted.first.localInterval : null,
      'time_basis': 'ساعت شروع به‌تنهایی کافی نیست؛ بازهٔ local_interval را بخوان. '
          'بازه‌های ساعتی HA روی مرز ساعت UTC هستند؛ در اختلاف ساعت نیم‌ساعتی، '
          'مثلاً ۰۳:۳۰ تا ۰۴:۳۰، آن‌ها را ۰۳:۰۰ تا ۰۴:۰۰ معرفی نکن.',
      'limitation': uniquePeak
          ? 'اوج ساعات بر پایه میانگین آماری ساعتی است؛ علت آلودگی را اثبات نمی‌کند.'
          : adequate ? 'بیشترین میانگین چند بازه یکسان است؛ ساعت اوج یکتا و قطعی اعلام نکن.'
          : 'پوشش داده یا هم‌ترازی محلی برای تعیین ساعت اوج معمول کافی نیست؛ هیچ ساعت قطعی اعلام نکن.',
      'hours': [
        for (final h in profile) {
          'hour_local': h.localHour,
          'local_interval': h.localInterval,
          'start_minutes': h.startMinutes.toList()..sort(),
          'utc_offset_minutes': h.utcOffsetMinutes.toList()..sort(),
          'expected': h.expectedHours,
          'valid': h.validHours,
          'mean': h.mean,
          'coverage': h.coverage,
        },
      ],
    };
  }
}

/// WebSocket.connect uses only openUrl on its supplied HttpClient. Restrict
/// that handshake and disable automatic redirects before any auth frame exists.
class _SameOriginHandshakeClient implements HttpClient {
  final HttpClient inner;
  final Uri base;
  _SameOriginHandshakeClient(this.inner, this.base);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (method != 'GET' || url.origin != base.origin ||
        url.path != '/api/websocket' || url.hasQuery || url.hasFragment) {
      throw const FormatException('مقصد اتصال آمار با تنظیمات مجاز یکسان نیست.');
    }
    final request = await inner.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected statistics HTTP operation');
}
