import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database/app_database.dart';

/// Owner feedback is local to the existing encrypted-backup-compatible
/// SQLite database. It is never sent to Qwen, GitHub or an external API.
enum AnswerVote { liked, disliked }

class AnswerFeedback {
  final String messageId;
  final AnswerVote vote;
  final String? reasonCode;
  final DateTime updatedAt;
  const AnswerFeedback({
    required this.messageId,
    required this.vote,
    this.reasonCode,
    required this.updatedAt,
  });
}

abstract final class FeedbackReasons {
  static const labels = <String, String>{
    'incorrect': 'اطلاعات نادرست',
    'incomplete': 'پاسخ ناقص',
    'irrelevant': 'نامرتبط',
    'slow': 'پاسخ کند',
    'sources': 'منابع نامعتبر یا ناموجود',
    'other': 'سایر',
  };
}

class PalaHealthTestEvent {
  final String checkId;
  final bool passed;
  final DateTime at;
  const PalaHealthTestEvent({
    required this.checkId,
    required this.passed,
    required this.at,
  });
}

class PalaFeedbackStore {
  final AppDatabase db;
  const PalaFeedbackStore(this.db);

  Future<AnswerFeedback?> read(String messageId) async {
    final rows = await db
        .customSelect(
          'SELECT message_id, vote, reason_code, updated_ms '
          'FROM pala_answer_feedback WHERE message_id = ?',
          variables: [Variable.withString(messageId)],
          readsFrom: {db.messages},
        )
        .get();
    if (rows.isEmpty) return null;
    final r = rows.single;
    final v = r.read<int>('vote');
    return AnswerFeedback(
      messageId: r.read<String>('message_id'),
      vote: v == 1 ? AnswerVote.liked : AnswerVote.disliked,
      reasonCode: r.readNullable<String>('reason_code'),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        r.read<int>('updated_ms'),
        isUtc: true,
      ),
    );
  }

  /// The same id retains only the latest vote; changing or clearing it is
  /// atomic. The foreign key deletes feedback with its original message.
  Future<void> write(
    String messageId,
    AnswerVote? vote, {
    String? reasonCode,
    DateTime? now,
  }) async {
    if (vote == AnswerVote.disliked &&
        reasonCode != null &&
        !FeedbackReasons.labels.containsKey(reasonCode)) {
      throw ArgumentError.value(reasonCode, 'reasonCode');
    }
    await db.transaction(() async {
      final rows = await db
          .customSelect(
            'SELECT role, status FROM messages WHERE id = ?',
            variables: [Variable.withString(messageId)],
          )
          .get();
      if (rows.isEmpty ||
          rows.single.read<String>('role') != 'assistant' ||
          rows.single.read<String>('status').contains('generating')) {
        throw StateError('Only a saved assistant answer can be rated');
      }
      if (vote == null) {
        await db.customStatement(
          'DELETE FROM pala_answer_feedback WHERE message_id = ?',
          [messageId],
        );
        return;
      }
      await db.customStatement(
        'INSERT INTO pala_answer_feedback '
        '(message_id, vote, reason_code, updated_ms) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET '
        'vote=excluded.vote, reason_code=excluded.reason_code, '
        'updated_ms=excluded.updated_ms',
        [
          messageId,
          vote == AnswerVote.liked ? 1 : -1,
          vote == AnswerVote.disliked ? reasonCode : null,
          (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
        ],
      );
    });
  }

  Future<Map<String, AnswerFeedback>> allVotes() async {
    final rows = await db
        .customSelect(
          'SELECT message_id, vote, reason_code, updated_ms '
          'FROM pala_answer_feedback',
          readsFrom: {db.messages},
        )
        .get();
    return {
      for (final r in rows)
        r.read<String>('message_id'): AnswerFeedback(
          messageId: r.read<String>('message_id'),
          vote: r.read<int>('vote') == 1
              ? AnswerVote.liked
              : AnswerVote.disliked,
          reasonCode: r.readNullable<String>('reason_code'),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('updated_ms'),
            isUtc: true,
          ),
        ),
    };
  }

  Future<List<PalaHealthTestEvent>> testEvents() async {
    final rows = await db
        .customSelect(
          'SELECT check_id, passed, at_ms FROM pala_health_test_events '
          'ORDER BY at_ms DESC LIMIT 2000',
        )
        .get();
    return [
      for (final r in rows)
        PalaHealthTestEvent(
          checkId: r.read<String>('check_id'),
          passed: r.read<int>('passed') == 1,
          at: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('at_ms'),
            isUtc: true,
          ),
        ),
    ];
  }

  /// Explicit, quick, local checks; they do not run in the background,
  /// access Home Assistant or consume the Work quota.
  Future<List<PalaHealthTestEvent>> runQuickChecks({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final out = <PalaHealthTestEvent>[];
    final checks = <(String, Future<bool> Function())>[
      (
        'db_read',
        () async {
          final row = await db.customSelect('SELECT 1 AS ok').getSingle();
          return row.read<int>('ok') == 1;
        },
      ),
      (
        'feedback_integrity',
        () async {
          final row = await db
              .customSelect(
                'SELECT COUNT(*) AS broken FROM pala_answer_feedback f '
                'LEFT JOIN messages m ON m.id = f.message_id '
                'WHERE m.id IS NULL OR m.role != ?',
                variables: [Variable.withString('assistant')],
              )
              .getSingle();
          return row.read<int>('broken') == 0;
        },
      ),
    ];
    for (final check in checks) {
      var passed = false;
      try {
        passed = await check.$2();
      } catch (_) {
        passed = false;
      }
      out.add(PalaHealthTestEvent(checkId: check.$1, passed: passed, at: at));
      // If the database itself failed, report the failed test without
      // pretending its result was durably saved.
      await db.customStatement(
        'INSERT INTO pala_health_test_events '
        '(at_ms, check_id, passed) VALUES (?, ?, ?)',
        [at.millisecondsSinceEpoch, check.$1, passed ? 1 : 0],
      );
    }
    return out;
  }
}

final palaFeedbackStoreProvider = Provider<PalaFeedbackStore>(
  (ref) => PalaFeedbackStore(ref.watch(appDatabaseProvider)),
);

final answerFeedbackProvider = FutureProvider.family<AnswerFeedback?, String>(
  (ref, messageId) => ref.watch(palaFeedbackStoreProvider).read(messageId),
);
