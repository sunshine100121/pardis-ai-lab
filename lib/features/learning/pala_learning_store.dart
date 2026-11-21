import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/database/app_database.dart';
import 'pala_learning_policy.dart';

enum LearningState { proposed, active, disabled }

class OwnerLearningCase {
  final String id, chatId, answerId, question, correction;
  final LearningState state;
  final bool beforeTestPassed, afterTestPassed;
  final DateTime? testedAt;
  const OwnerLearningCase({
    required this.id,
    required this.chatId,
    required this.answerId,
    required this.question,
    required this.correction,
    required this.state,
    required this.beforeTestPassed,
    required this.afterTestPassed,
    this.testedAt,
  });
}

class OwnerLearningMatch {
  final String caseId, correction;
  final double similarity;
  const OwnerLearningMatch(this.caseId, this.correction, this.similarity);
  String get ownerMarkedAnswer =>
      'طبق اصلاحی که شما قبلاً برای پرسش مشابه تأیید کرده‌اید '
          '(نه تأیید مستقل درستی آن):\n\n' +
      correction +
      '\n\n'
          'برای بازگشت، این اصلاح را در «سلامت و عملکرد PALA ← اصلاح‌های من» '
          'غیرفعال کنید.';
}

class PalaLearningStore {
  final AppDatabase db;
  const PalaLearningStore(this.db);

  OwnerLearningCase _read(dynamic row) {
    final tested = row.readNullable<int>('tested_ms');
    return OwnerLearningCase(
      id: row.read<String>('id'),
      chatId: row.read<String>('chat_id'),
      answerId: row.read<String>('source_answer_id'),
      question: row.read<String>('question'),
      correction: row.read<String>('correction'),
      state: LearningState.values.byName(row.read<String>('state')),
      beforeTestPassed: row.read<int>('before_pass') == 1,
      afterTestPassed: row.read<int>('after_pass') == 1,
      testedAt: tested == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(tested, isUtc: true),
    );
  }

  Future<List<OwnerLearningCase>> all({String? chatId}) async {
    final sql =
        'SELECT * FROM pala_owner_learning ' +
        (chatId == null ? '' : 'WHERE chat_id = ? ') +
        'ORDER BY updated_ms DESC LIMIT 200';
    final rows = await db
        .customSelect(
          sql,
          variables: [if (chatId != null) Variable.withString(chatId)],
        )
        .get();
    return [for (final row in rows) _read(row)];
  }

  Future<OwnerLearningCase?> byId(String id) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM pala_owner_learning WHERE id = ?',
          variables: [Variable.withString(id)],
        )
        .get();
    return rows.isEmpty ? null : _read(rows.single);
  }

  /// Only a saved disliked assistant answer is eligible. The owner's last
  /// preceding question is read from SQLite; a model may not invent it.
  Future<OwnerLearningCase> propose({
    required String sourceAnswerId,
    required String correction,
    DateTime? now,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT a.chat_id AS chat_id, a.status AS answer_status, '
          'u.content AS question, u.attachments_json AS attachments_json '
          'FROM messages a '
          'JOIN pala_answer_feedback f ON f.message_id=a.id AND f.vote=-1 '
          'JOIN messages u ON u.chat_id=a.chat_id AND u.role=? '
          'AND u.sequence<a.sequence '
          'WHERE a.id=? AND a.role=? '
          'ORDER BY u.sequence DESC LIMIT 1',
          variables: [
            Variable.withString('user'),
            Variable.withString(sourceAnswerId),
            Variable.withString('assistant'),
          ],
        )
        .get();
    if (rows.isEmpty ||
        rows.single.read<String>('answer_status') != 'complete') {
      throw StateError('پاسخ ذخیره‌شده و نپسندیده پیدا نشد.');
    }
    final row = rows.single;
    final question = row.read<String>('question');
    if ((row.readNullable<String>('attachments_json') ?? '[]').trim() != '[]' ||
        !PalaLearningPolicy.safe(question: question, correction: correction)) {
      throw StateError('این اصلاح مناسب یادگیری مستقیم و امن نیست.');
    }
    final id = const Uuid().v4();
    final chatId = row.read<String>('chat_id');
    final ms = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    await db.customStatement(
      'INSERT INTO pala_owner_learning '
      '(id,chat_id,source_answer_id,question,normalized_question,'
      'correction,state,before_pass,after_pass,created_ms,updated_ms) '
      'VALUES (?,?,?,?,?,?,?,0,0,?,?)',
      [
        id,
        chatId,
        sourceAnswerId,
        question,
        PalaLearningPolicy.normalize(question),
        correction.trim(),
        'proposed',
        ms,
        ms,
      ],
    );
    return (await byId(id))!;
  }

  /// Bounded same-chat local lookup; does not call the model or cloud.
  Future<OwnerLearningMatch?> match(String chatId, String question) async {
    if (!PalaLearningPolicy.eligibleQuestion(question)) return null;
    final rows = await db
        .customSelect(
          "SELECT id,question,correction FROM pala_owner_learning "
          "WHERE chat_id=? AND state='active' "
          'ORDER BY updated_ms DESC LIMIT 40',
          variables: [Variable.withString(chatId)],
        )
        .get();
    OwnerLearningMatch? best;
    for (final row in rows) {
      final score = PalaLearningPolicy.similarity(
        row.read<String>('question'),
        question,
      );
      if (score < PalaLearningPolicy.minSimilarity ||
          (best != null && score <= best.similarity))
        continue;
      best = OwnerLearningMatch(
        row.read<String>('id'),
        row.read<String>('correction'),
        score,
      );
    }
    return best;
  }

  /// Must be called by an owner gesture. Test BEFORE, enable, test AFTER,
  /// store both outcomes atomically. All errors roll back the activation.
  Future<OwnerLearningCase> approve(String id, {DateTime? now}) async {
    return db.transaction(() async {
      final c = await byId(id);
      if (c == null || c.state == LearningState.active) {
        throw StateError('پیشنهاد قابل تأیید پیدا نشد.');
      }
      if (!PalaLearningPolicy.safe(
        question: c.question,
        correction: c.correction,
      ))
        throw StateError('پیشنهاد امن نیست.');
      final before = await match(c.chatId, c.question);
      final beforePassed = before?.correction == c.correction;
      await db.customStatement(
        "UPDATE pala_owner_learning SET state='disabled' "
        "WHERE chat_id=? AND normalized_question=? AND state='active'",
        [c.chatId, PalaLearningPolicy.normalize(c.question)],
      );
      final ms = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
      await db.customStatement(
        "UPDATE pala_owner_learning SET state='active', updated_ms=? "
        "WHERE id=?",
        [ms, id],
      );
      final after = await match(c.chatId, c.question);
      if (after?.caseId != id || after?.correction != c.correction) {
        throw StateError(
          'آزمون پس از اصلاح ناموفق شد؛ فعال‌سازی بازگردانده شد.',
        );
      }
      await db.customStatement(
        'UPDATE pala_owner_learning SET before_pass=?,after_pass=1,'
        'tested_ms=?,updated_ms=? WHERE id=?',
        [beforePassed ? 1 : 0, ms, ms, id],
      );
      return (await byId(id))!;
    });
  }

  Future<void> disable(String id, {DateTime? now}) async {
    await db.customStatement(
      "UPDATE pala_owner_learning SET state='disabled', updated_ms=? "
      "WHERE id=? AND state='active'",
      [(now ?? DateTime.now()).toUtc().millisecondsSinceEpoch, id],
    );
  }

  /// Repeated dislikes are suggestions only; no unattended modifications.
  Future<List<(String, int)>> repeatedWeaknesses({DateTime? now}) async {
    final since = (now ?? DateTime.now())
        .toUtc()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final rows = await db
        .customSelect(
          'SELECT reason_code AS reason, COUNT(*) AS count '
          'FROM pala_answer_feedback '
          'WHERE vote=-1 AND reason_code IS NOT NULL AND updated_ms >= ? '
          'GROUP BY reason_code HAVING COUNT(*)>=3 '
          'ORDER BY count DESC LIMIT 6',
          variables: [Variable.withInt(since)],
        )
        .get();
    return [
      for (final row in rows)
        (row.read<String>('reason'), row.read<int>('count')),
    ];
  }
}

final palaLearningStoreProvider = Provider<PalaLearningStore>(
  (ref) => PalaLearningStore(ref.watch(appDatabaseProvider)),
);
final palaLearningListProvider = FutureProvider<List<OwnerLearningCase>>(
  (ref) => ref.watch(palaLearningStoreProvider).all(),
);
final palaLearningWeaknessesProvider = FutureProvider<List<(String, int)>>(
  (ref) => ref.watch(palaLearningStoreProvider).repeatedWeaknesses(),
);
