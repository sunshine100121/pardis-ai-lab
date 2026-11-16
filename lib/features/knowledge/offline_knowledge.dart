import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/network/web_search/search_models.dart';
import 'folder_library.dart';
import 'ha_read_client.dart';
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
  Future<KnowledgeReadReport> searchDetailed(String question) async {
    final sources = <SearchResult>[];
    final checks = <Map<String, dynamic>>[];
    try {
      final report = await library.searchDetailed(question);
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
        if (report['recurring_peak_supported'] != true) {
          // No model-generated claim about a habitual peak with thin data.
          sources.clear();
          final noUniquePeak = report['coverage_adequate'] == true;
          checks
            ..clear()
            ..add({
              'file': 'Home Assistant',
              'stage': 'coverage',
              'code': 'ha_insufficient',
              'reason': noUniquePeak ? 'non_unique_peak' : 'coverage',
            });
          sources.add(
            _failure(
              'Home Assistant',
              noUniquePeak
                  ? 'پوشش داده کافی است اما ساعت اوج یکتایی مشخص نیست؛ ساعت قطعی اعلام نمی‌کنم.'
                  : 'آمار ساعتی کافی برای تعیین ساعت اوج معمول وجود ندارد؛ عدد یا ساعت حدسی اعلام نمی‌کنم.',
            ),
          );
        } else {
          sources
            ..clear()
            ..add(HaReadClient.evidence(selected.value as String, report));
          checks.clear();
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
