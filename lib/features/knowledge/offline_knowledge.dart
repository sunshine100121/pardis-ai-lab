import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/network/web_search/search_models.dart';
import 'folder_library.dart';
import 'ha_read_client.dart';
import 'ha_doctor.dart';
import 'ha_sensor_language.dart';
import '../chat/domain/live_time_answer.dart';
import 'ha_hourly_statistics.dart';
import 'knowledge_read_report.dart';

class OfflineKnowledge {
  static const configKey = 'pala_ha_read_config_v1';
  static const tokenKey = 'pala_ha_read_token_v1';
  static const secure = FlutterSecureStorage();
  final FolderLibrary library;
  final Future<String?> Function() readToken;
  final DateTime Function() clock;
  OfflineKnowledge(
    this.library, {
    Future<String?> Function()? readToken,
    DateTime Function()? clock,
  }) : readToken = readToken ?? (() => secure.read(key: tokenKey)),
       clock = clock ?? DateTime.now;
  Future<List<SearchResult>> search(String question) async =>
      (await searchDetailed(question)).sources;
  Future<KnowledgeReadReport> searchProject(
    String question, {
    required Set<String> sourceIds,
  }) async {
    try {
      return await library.searchDetailed(question, sourceIds: sourceIds);
    } catch (_) {
      return const KnowledgeReadReport([], [
        {'file': 'منابع پروژه', 'stage': 'access', 'code': 'access'},
      ]);
    }
  }

  /// All ordinary observations use the same owner-approved sensor list.
  /// Neither the model nor the question may broaden that list.
  Future<String> sensorCurrentValue(String question, {bool permitted = true}) =>
      _directSensor(question, timestampOnly: false, permitted: permitted);

  Future<String> sensorLastUpdate(String question, {bool permitted = true}) =>
      _directSensor(question, timestampOnly: true, permitted: permitted);

  Future<String> _directSensor(
    String question, {
    required bool timestampOnly,
    required bool permitted,
  }) async {
    if (!permitted) {
      return 'در محدوده این پروژه، خواندن حسگر Home Assistant '
          'مجاز نشده است؛ از منبع دیگری حدس نمی‌زنم.';
    }
    try {
      final raw = (await SharedPreferences.getInstance()).getString(configKey);
      if (raw == null) {
        return 'دسترسی خواندنی Home Assistant تنظیم نشده است؛ '
            'اطلاعات حسگر را نمی‌توانم تأیید کنم.';
      }
      final parsed = jsonDecode(raw);
      if (parsed is! Map ||
          parsed['enabled'] != true ||
          parsed['base'] is! String ||
          parsed['entities'] is! Map) {
        return 'اتصال خواندنی Home Assistant فعال یا معتبر نیست؛ '
            'داده‌ای حدس نمی‌زنم.';
      }
      final allowed = Map<String, dynamic>.from(parsed['entities'] as Map);
      if (allowed.isEmpty ||
          allowed.values.any((v) => v is! String || v.trim().isEmpty)) {
        return 'فهرست حسگرهای مجاز Home Assistant معتبر نیست.';
      }
      // No eight-sensor cap: resolve locally, then GET only one approved ID.
      final match = HaSensorLanguage.resolve(
        question,
        allowed,
        singleFallback: timestampOnly,
      );
      if (match.ambiguous) {
        final names = match.candidates
            .take(4)
            .map((e) => e.value as String)
            .join('، ');
        return 'چند حسگر با این پرسش مطابقت دارند: $names. '
            'نام یکی را بگویید؛ برای جلوگیری از اشتباه، مقدار یا زمانی حدس نمی‌زنم.';
      }
      final selected = match.selected;
      if (selected == null) {
        return timestampOnly
            ? 'نام حسگر مشخص نیست؛ نام فارسی یکی از حسگرهای مجاز '
                  'Home Assistant را بگویید. زمانی حدس نمی‌زنم.'
            : 'حسگر متناظر با پرسش در فهرست مجاز Home Assistant '
                  'پیدا نشد؛ مقدار دانشنامه را جای آن اعلام نمی‌کنم.';
      }
      final token = await readToken();
      if (token == null || token.trim().isEmpty) {
        return 'مجوز خواندن Home Assistant در دسترس نیست؛ '
            'داده حسگر تأیید نشده است.';
      }
      final client = HaReadClient(
        base: Uri.parse(parsed['base'] as String),
        token: token,
        entities: allowed.keys.toSet(),
        clock: clock,
      );
      final state = await client.state(selected.key);
      return timestampOnly
          ? LiveTimeAnswer.sensor(selected.value as String, state)
          : HaSensorLanguage.currentValue(selected.value as String, state);
    } catch (_) {
      return 'دریافت اطلاعات واقعی حسگر از Home Assistant ممکن نشد؛ '
          'اتصال یا مجوز را بررسی کنید. از دانشنامه یا Qwen '
          'برای حدس مقدار و زمان استفاده نمی‌کنم.';
    }
  }

  /// App-owned HA Doctor report. Read permission is one opt-in in the
  /// existing connection page, not an instruction from Qwen.
  Future<String> doctorReport(
    String question, {
    Set<String>? projectSourceIds,
  }) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(configKey);
      if (raw == null) {
        return 'HA Doctor: اتصال خواندنی Home Assistant تنظیم نشده است. '
            'اطلاعات زنده‌ای دریافت نشد.';
      }
      final config = jsonDecode(raw);
      if (config is! Map ||
          config['enabled'] != true ||
          config['doctorEnabled'] != true ||
          config['base'] is! String ||
          config['entities'] is! Map) {
        return 'HA Doctor: در تنظیمات اتصال Home Assistant گزینه '
            '«بررسی فقط‌خواندنی سلامت سیستم» فعال نیست. '
            'با فعال‌سازی یک‌باره، بررسی فقط هنگام درخواست انجام می‌شود.';
      }
      final names = Map<String, dynamic>.from(config['entities'] as Map);
      if (names.isEmpty ||
          names.values.any((v) => v is! String || v.trim().isEmpty)) {
        return 'HA Doctor: فهرست حسگرهای مجاز معتبر نیست.';
      }
      final token = await readToken();
      if (token == null || token.trim().isEmpty) {
        return 'HA Doctor: مجوز خواندن Home Assistant در دسترس نیست؛ '
            'هیچ وضعیتی حدس زده نمی‌شود.';
      }
      final client = HaReadClient(
        base: Uri.parse(config['base'] as String),
        token: token,
        entities: names.keys.toSet(),
        clock: clock,
      );
      final snapshot = await client.doctorSnapshot();
      final localTitles = <String>[];
      try {
        final local = await library
            .searchDetailed(question, sourceIds: projectSourceIds)
            .timeout(const Duration(seconds: 5));
        for (final evidence in local.sources) {
          if (evidence.title.trim().isNotEmpty &&
              (evidence.pageText?.trim().isNotEmpty ?? false)) {
            localTitles.add(evidence.title.trim());
          }
          if (localTitles.length >= 2) break;
        }
      } catch (_) {
        // Local references are optional, never substituted for live data.
      }
      return HaDoctorDiagnosis.report(
        snapshot,
        labels: {for (final e in names.entries) e.key: e.value as String},
        documentTitles: localTitles,
      );
    } catch (_) {
      return 'HA Doctor: جمع‌آوری شواهد کامل نشد؛ وضعیت نامعلوم است. '
          'اتصال و اختیار خواندن را بررسی کنید؛ هیچ تعمیر اجرا نشد.';
    }
  }

  Future<KnowledgeReadReport> searchDetailed(String question) =>
      searchDetailedScoped(question);

  /// Filtered variant; keep searchDetailed's original signature so existing
  /// app overrides and old project tests remain source compatible.
  Future<KnowledgeReadReport> searchDetailedScoped(
    String question, {
    Set<String>? sourceIds,
  }) async {
    final sources = <SearchResult>[];
    final checks = <Map<String, dynamic>>[];
    try {
      final report = await library.searchDetailed(question, sourceIds: sourceIds);
      sources.addAll(report.sources);
      checks.addAll(report.checks);
    } catch (_) {
      checks.add({'file': 'پوشه دانش', 'stage': 'access', 'code': 'access'});
    }
    final normalized = FolderLibrary.normalize(question);
    final pollutionAsked = RegExp(r'(الودگی|آلودگی|pm2\.?5|pm25|ذرات معلق)')
        .hasMatch(normalized);
    final historical =
        RegExp(r'(شش|شیش|۶|6)\s*ماه').hasMatch(normalized) && pollutionAsked;
    final qOutdoor = RegExp(r'(باغ|محوطه|بیرون|فضای باز)').hasMatch(normalized);
    final qIndoor = RegExp(r'(داخل|ساختمان|اتاق)').hasMatch(normalized);
    final sensorQuestion =
        pollutionAsked &&
        (historical ||
            qOutdoor ||
            qIndoor ||
            RegExp(r'(حسگر|وضعیت|مقدار|چقدر|چند)').hasMatch(normalized));
    KnowledgeReadReport unconfigured() => const KnowledgeReadReport([], [
      {'file': 'Home Assistant', 'stage': 'match', 'code': 'ha_unavailable'},
    ]);
    final raw = (await SharedPreferences.getInstance()).getString(configKey);
    if (raw == null)
      return sensorQuestion
          ? unconfigured()
          : KnowledgeReadReport(sources, checks);
    final config = jsonDecode(raw) as Map<String, dynamic>;
    if (config['enabled'] != true)
      return sensorQuestion
          ? unconfigured()
          : KnowledgeReadReport(sources, checks);
    final allowed = Map<String, dynamic>.from(config['entities'] as Map);
    final explicitMatches = allowed.entries
        .where(
          (e) =>
              normalized.contains(FolderLibrary.normalize(e.value as String)),
        )
        .toList();
    // Prefer exact configured sensor labels; a natural-language fallback may
    // identify a UNIQUE pollution sensor without inventing an entity ID.
    final wantsPm25 = RegExp(
      r'pm\s*2[.٫]?\s*5|pm25|پی\s*ام\s*(دو|۲|2)|ذرات معلق',
    ).hasMatch(normalized);
    bool pm25Label(String label) =>
        RegExp(r'pm\s*2[.٫]?\s*5|pm25|پی\s*ام\s*(دو|۲|2)').hasMatch(label);
    final pollution = allowed.entries.where((e) {
      final label = FolderLibrary.normalize(e.value.toString());
      final type = RegExp(r'(الودگی|آلودگی|pm2\.?5|pm25|ذرات معلق)')
          .hasMatch(label);
      final outside = RegExp(r'(باغ|محوطه|بیرون|فضای باز)').hasMatch(label);
      final inside = RegExp(r'(داخل|ساختمان|اتاق)').hasMatch(label);
      if (!type || (wantsPm25 && !pm25Label(label)) || (qIndoor && qOutdoor))
        return false;
      if (qOutdoor && !outside) return false;
      if (qIndoor && !inside) return false;
      return true;
    }).toList();
    final matches = explicitMatches.isNotEmpty
        ? explicitMatches
        : (sensorQuestion ? pollution : <MapEntry<String, dynamic>>[]);
    // An explicit phrase is not permission to swap indoor vs outdoor data.
    // When a question has conflicting location words, fail closed.
    final incompatibleLocation =
        (qOutdoor && qIndoor ||
        matches.any((e) {
          final label = FolderLibrary.normalize(e.value.toString());
          final indoor = RegExp(r'(داخل|ساختمان|اتاق)').hasMatch(label);
          final outdoor = RegExp(r'(باغ|محوطه|بیرون|فضای باز)').hasMatch(label);
          return (qOutdoor && (!outdoor || indoor)) ||
              (qIndoor && (!indoor || outdoor)) ||
              (wantsPm25 && !pm25Label(label));
        }));
    if (incompatibleLocation) {
      sources.clear();
      checks
        ..clear()
        ..add({
          'file': 'Home Assistant',
          'stage': 'match',
          'code': 'ha_ambiguous',
        });
      sources.add(
        _failure(
          'Home Assistant',
          'محل حسگر در پرسش با منبع ثبت‌شده سازگار نیست؛ داده دیگری را جایگزین نمی‌کنم.',
        ),
      );
      return KnowledgeReadReport(sources, checks);
    }
    if (matches.isEmpty && sensorQuestion) {
      sources.clear();
      checks
        ..clear()
        ..add({
          'file': 'Home Assistant',
          'stage': 'match',
          'code': 'ha_unavailable',
        });
      sources.add(
        _failure(
          'Home Assistant',
          'حسگر آلودگیِ مطابق محل موردنظر در فهرست مجاز نیست؛ از داده حسگر دیگری استفاده نمی‌کنم.',
        ),
      );
      return KnowledgeReadReport(sources, checks);
    }
    if (matches.isEmpty) return KnowledgeReadReport(sources, checks);
    if (matches.length > 1) {
      sources.clear();
      checks
        ..clear()
        ..add({
          'file': 'Home Assistant',
          'stage': 'match',
          'code': 'ha_ambiguous',
        });
      sources.add(
        _failure(
          'Home Assistant',
          'پرسش چند حسگر دارد؛ برای جلوگیری از حدس، نام یک حسگر مجاز را بپرسید.',
        ),
      );
      return KnowledgeReadReport(sources, checks);
    }
    final selected = matches.single;
    try {
      final token = await readToken();
      if (token == null) throw StateError('missing credential');
      final client = HaReadClient(
        base: Uri.parse(config['base'] as String),
        token: token,
        entities: allowed.keys.toSet(),
      );
      final end = clock().toUtc();
      // Explicit fixed one-hour MVP window; never infer arbitrary dates.
      final history = normalized.contains('تاریخچه');
      if (historical) {
        // The hourly statistics API requires hour-aligned bounds. Do not
        // pass the current minute/second: that would reject almost every
        // normal voice query with an invalid period error.
        final until = DateTime.utc(end.year, end.month, end.day, end.hour);
        final first = DateTime.utc(until.year, until.month - 6, 1);
        final lastDay = DateTime.utc(
          until.year,
          until.month - 5,
          1,
        ).subtract(const Duration(days: 1)).day;
        final day = until.day > lastDay ? lastDay : until.day;
        final from = DateTime.utc(first.year, first.month, day, until.hour);
        final stats = HaHourlyStatistics(
          base: client.base,
          token: token,
          entities: client.entities,
        );
        final rows = await stats.read(
          entityId: selected.key,
          fromUtc: from,
          toUtc: until,
        );
        final report = HaHourlyStatistics.report(
          entityId: selected.key,
          fromUtc: from,
          toUtc: until,
          samples: rows,
        );
        // Partial records are evidence, not a complete six-month history.
        // An empty recorder response must never produce invented numbers.
        final available = report['reported_statistic_hours'] as int;
        sources.clear();
        checks.clear();
        if (available == 0) {
          checks.add({
            'file': 'Home Assistant',
            'stage': 'coverage',
            'code': 'ha_insufficient',
            'reason': 'no_data',
            'coverage_percent': 0,
          });
          sources.add(
            _failure(
              'Home Assistant',
              'برای این شش ماه هیچ آمار ساعتی معتبری از حسگر مجاز در دسترس نیست؛ '
                  'میانگین، حداقل یا حداکثر را حدس نمی‌زنم.',
            ),
          );
        } else {
          sources.add(HaReadClient.evidence(selected.value as String, report));
          if ((report['coverage'] as double) < 1) {
            checks.add({
              'file': 'Home Assistant',
              'stage': 'coverage',
              'code': 'ha_partial_coverage',
              'coverage_percent': report['coverage_percent'],
              'valid_hours': report['valid_hours'],
              'expected_hours': report['expected_hours'],
              'missing_hours': report['missing_hours'],
            });
          }
        }
      } else {
        final data = history
            ? await client.history(
                selected.key,
                end.subtract(const Duration(hours: 1)),
                end,
              )
            : await client.state(selected.key);
        // A successful live sensor lookup supersedes unrelated ZIM title hits.
        sources
          ..clear()
          ..add(HaReadClient.evidence(selected.value as String, data));
        checks.clear();
      }
    } catch (_) {
      sources.clear();
      checks
        ..clear()
        ..add({
          'file': 'Home Assistant',
          'stage': 'request',
          'code': 'ha_unavailable',
        });
      sources.add(
        _failure(
          'Home Assistant',
          'داده واقعی دریافت نشد؛ اتصال یا مجوز را بررسی کنید. مقدار را حدس نزنید.',
        ),
      );
    }
    return KnowledgeReadReport(sources, checks);
  }

  static SearchResult _failure(String title, String text) => SearchResult(
    title: title,
    url: 'pala-status://unavailable',
    snippet: '',
    source: 'وضعیت خواندن',
    rank: 0,
    pageText: text,
    fetchedAt: DateTime.now().toUtc(),
  );
}

final offlineKnowledgeProvider = Provider<OfflineKnowledge>(
  (ref) => OfflineKnowledge(ref.read(folderLibraryProvider)),
);
