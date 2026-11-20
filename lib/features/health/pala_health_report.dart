import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database/app_database.dart';
import '../chat/domain/entities/turn_run.dart';
import 'pala_feedback_store.dart';

/// Aggregates metadata on this device only, never message text or photos.
class PalaAnswerObservation {
  final DateTime at;
  final String status;
  final AnswerVote? vote;
  final double? firstTokenMs, tokensPerSecond, recallMs;
  /// Null means no structured retrieval observation.
  final bool? retrievalError;
  const PalaAnswerObservation({
    required this.at,
    required this.status,
    this.vote,
    this.firstTokenMs,
    this.tokensPerSecond,
    this.recallMs,
    this.retrievalError,
  });
  bool get failed => status == 'error' || status == 'interrupted';
}

class PalaDailyHealth {
  final DateTime day;
  final int answers, rated, liked, failures;
  const PalaDailyHealth({
    required this.day,
    required this.answers,
    required this.rated,
    required this.liked,
    required this.failures,
  });
}

class PalaHealthWindow {
  final int days, answers, failures, stopped, liked, disliked;
  final int retrievalObserved, retrievalErrors, measuredLatency;
  final int testCount, testPasses, activeDays;
  final double? medianFirstTokenMs, meanTokensPerSecond, meanRecallMs;
  final int? index;
  final List<String> missing;
  final List<PalaDailyHealth> daily;
  const PalaHealthWindow({
    required this.days,
    required this.answers,
    required this.failures,
    required this.stopped,
    required this.liked,
    required this.disliked,
    required this.retrievalObserved,
    required this.retrievalErrors,
    required this.measuredLatency,
    required this.testCount,
    required this.testPasses,
    required this.activeDays,
    required this.medianFirstTokenMs,
    required this.meanTokensPerSecond,
    required this.meanRecallMs,
    required this.index,
    required this.missing,
    required this.daily,
  });
  int get rated => liked + disliked;
  double? get positiveRate => rated == 0 ? null : liked / rated;
  double? get failedRate => answers == 0 ? null : failures / answers;
  double? get retrievalErrorRate =>
      retrievalObserved == 0 ? null : retrievalErrors / retrievalObserved;
  double? get testPassRate =>
      testCount == 0 ? null : testPasses / testCount;
}

abstract final class PalaHealthCalculator {
  static double? _median(List<double> numbers) {
    if (numbers.isEmpty) return null;
    numbers.sort();
    final n = numbers.length;
    return n.isOdd ? numbers[n ~/ 2] : (numbers[n ~/ 2 - 1] + numbers[n ~/ 2]) / 2;
  }

  static double? _mean(List<double> numbers) =>
      numbers.isEmpty ? null : numbers.reduce((a, b) => a + b) / numbers.length;

  static PalaHealthWindow summarize({
    required int days,
    required DateTime now,
    required List<PalaAnswerObservation> answers,
    required List<PalaHealthTestEvent> tests,
    bool truncated = false,
  }) {
    assert(days == 7 || days == 30);
    final utc = now.toUtc();
    final since = utc.subtract(Duration(days: days));
    final current = answers.where((a) =>
        !a.at.toUtc().isBefore(since) &&
        !a.at.toUtc().isAfter(utc) &&
        a.status != 'generating').toList();
    final localTests = tests.where((t) =>
        !t.at.toUtc().isBefore(since) &&
        !t.at.toUtc().isAfter(utc)).toList();
    final liked = current.where((a) => a.vote == AnswerVote.liked).length;
    final disliked = current.where((a) => a.vote == AnswerVote.disliked).length;
    final failures = current.where((a) => a.failed).length;
    final stopped = current.where((a) => a.status == 'stopped').length;
    final retrieval = current.where((a) => a.retrievalError != null).toList();
    final retrievalErrors = retrieval.where((a) => a.retrievalError!).length;
    final latency = <double>[
      for (final a in current)
        if (a.firstTokenMs != null &&
            a.firstTokenMs!.isFinite && a.firstTokenMs! > 0)
          a.firstTokenMs!,
    ];
    final speed = <double>[
      for (final a in current)
        if (a.tokensPerSecond != null &&
            a.tokensPerSecond!.isFinite && a.tokensPerSecond! > 0)
          a.tokensPerSecond!,
    ];
    final recall = <double>[
      for (final a in current)
        if (a.recallMs != null && a.recallMs!.isFinite && a.recallMs! >= 0)
          a.recallMs!,
    ];
    final daily = List<PalaDailyHealth>.generate(days, (i) {
      final day = DateTime.utc(utc.year, utc.month, utc.day)
          .subtract(Duration(days: days - 1 - i));
      final selected = current.where((a) {
        final t = a.at.toUtc();
        return t.year == day.year && t.month == day.month && t.day == day.day;
      }).toList();
      return PalaDailyHealth(
        day: day,
        answers: selected.length,
        rated: selected.where((a) => a.vote != null).length,
        liked: selected.where((a) => a.vote == AnswerVote.liked).length,
        failures: selected.where((a) => a.failed).length,
      );
    });
    final activeDays = daily.where((d) => d.answers > 0).length;
    final missing = <String>[
      if (truncated) 'نمونه پاسخ‌ها از سقف گزارش بیشتر است',
      if (current.length < 20) 'حداقل ۲۰ پاسخ (فعلاً ' + current.length.toString() + ')',
      if (liked + disliked < 10) 'حداقل ۱۰ رأی (فعلاً ' + (liked + disliked).toString() + ')',
      if (retrieval.length < 5) 'حداقل ۵ گزارش بازیابی (فعلاً ' + retrieval.length.toString() + ')',
      if (localTests.length < 4) 'حداقل ۴ نتیجه آزمون محلی (فعلاً ' + localTests.length.toString() + ')',
      if (activeDays < (days == 7 ? 3 : 7))
        'فعالیت در ' + (days == 7 ? '۳' : '۷') + ' روز متفاوت (فعلاً ' + activeDays.toString() + ')',
    ];
    // A transparent operational/sample index, NOT an intelligence score.
    // 40% rating, 30% non-error, 15% no explicit retrieval error,
    // 15% passed user-invoked on-device checks. No missing denominator.
    final int? index = missing.isEmpty
        ? (100 *
            (0.40 * liked / (liked + disliked) +
             0.30 * (1 - failures / current.length) +
             0.15 * (1 - retrievalErrors / retrieval.length) +
             0.15 * localTests.where((t) => t.passed).length /
                 localTests.length)).round().clamp(0, 100).toInt()
        : null;
    return PalaHealthWindow(
      days: days,
      answers: current.length,
      failures: failures,
      stopped: stopped,
      liked: liked,
      disliked: disliked,
      retrievalObserved: retrieval.length,
      retrievalErrors: retrievalErrors,
      measuredLatency: latency.length,
      testCount: localTests.length,
      testPasses: localTests.where((t) => t.passed).length,
      activeDays: activeDays,
      medianFirstTokenMs: _median(latency),
      meanTokensPerSecond: _mean(speed),
      meanRecallMs: _mean(recall),
      index: index,
      missing: missing,
      daily: daily,
    );
  }

  static double? _numeric(Map<String, dynamic> metrics, String key) {
    final v = metrics[key];
    return v is num && v.isFinite ? v.toDouble() : null;
  }

  static bool? _readError(Map<String, dynamic> metrics) {
    final offline = metrics['offlineKnowledge'];
    if (offline is! Map) return null;
    final checks = offline['checks'];
    if (checks is! List || checks.isEmpty) return null;
    final codes = [
      for (final entry in checks)
        if (entry is Map && entry['code'] is String)
          (entry['code'] as String).toLowerCase(),
    ];
    if (codes.isEmpty) return null;
    return codes.any((code) =>
        code.contains('failed') ||
        code.contains('unavailable') ||
        code.contains('timeout') ||
        code.contains('denied') ||
        code.contains('error'));
  }

  static PalaAnswerObservation fromRun({
    required DateTime timestamp,
    required String status,
    required AnswerVote? vote,
    String? runJson,
  }) {
    final metrics = TurnRun.decode(runJson)?.metrics ?? const <String, dynamic>{};
    final stages = metrics['stages'];
    return PalaAnswerObservation(
      at: timestamp,
      status: status.startsWith('alternative:')
          ? status.substring('alternative:'.length)
          : status.startsWith('superseded:') ? 'superseded' : status,
      vote: vote,
      firstTokenMs: _numeric(metrics, 'firstTokenMs'),
      tokensPerSecond: _numeric(metrics, 'tokensPerSecond'),
      recallMs: stages is Map && stages['recallMs'] is num
          ? (stages['recallMs'] as num).toDouble()
          : null,
      retrievalError: _readError(metrics),
    );
  }
}

class PalaHealthReport {
  final PalaHealthWindow week, month;
  final bool limited;
  const PalaHealthReport({required this.week, required this.month, required this.limited});
}

class PalaHealthRepository {
  final AppDatabase db;
  final PalaFeedbackStore feedback;
  const PalaHealthRepository(this.db, this.feedback);

  Future<PalaHealthReport> load({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final since = at.subtract(const Duration(days: 30));
    // Project only metadata: no large assistant text, image or prompt.
    final q = db.selectOnly(db.messages)
      ..addColumns([
        db.messages.id,
        db.messages.timestamp,
        db.messages.status,
        db.messages.runJson,
      ])
      ..where(db.messages.role.equals('assistant') &
          db.messages.timestamp.isBiggerOrEqualValue(since))
      ..orderBy([OrderingTerm.desc(db.messages.timestamp)])
      ..limit(5001);
    final rows = await q.get();
    final limited = rows.length > 5000;
    final votes = await feedback.allVotes();
    final observations = <PalaAnswerObservation>[
      for (final r in rows.take(5000))
        PalaHealthCalculator.fromRun(
          timestamp: r.read(db.messages.timestamp)!,
          status: r.read(db.messages.status)!,
          vote: votes[r.read(db.messages.id)!]?.vote,
          runJson: r.read(db.messages.runJson),
        ),
    ];
    final tests = await feedback.testEvents();
    return PalaHealthReport(
      week: PalaHealthCalculator.summarize(
        days: 7, now: at, answers: observations,
        tests: tests, truncated: limited,
      ),
      month: PalaHealthCalculator.summarize(
        days: 30, now: at, answers: observations,
        tests: tests, truncated: limited,
      ),
      limited: limited,
    );
  }
}

final palaHealthReportProvider = FutureProvider<PalaHealthReport>((ref) {
  return PalaHealthRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(palaFeedbackStoreProvider),
  ).load();
});
