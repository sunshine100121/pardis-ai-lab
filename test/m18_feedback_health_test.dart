import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/chat/domain/entities/turn_run.dart';
import 'package:ondevice_llm/features/health/pala_feedback_store.dart';
import 'package:ondevice_llm/features/health/pala_health_report.dart';

Future<void> seed(AppDatabase db) async {
  await db.customStatement(
    'INSERT INTO chats (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)',
    ['chat-a', 'synthetic local chat', 1000, 1000],
  );
  await db.customStatement(
    'INSERT INTO messages '
    '(id, chat_id, role, content, timestamp, sequence) VALUES (?,?,?,?,?,?)',
    ['answer-a', 'chat-a', 'assistant', 'synthetic answer', 1000, 1],
  );
  await db.customStatement(
    'INSERT INTO messages '
    '(id, chat_id, role, content, timestamp, sequence) VALUES (?,?,?,?,?,?)',
    ['question-a', 'chat-a', 'user', 'synthetic question', 1001, 2],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a vote can be changed, reason edited, or cleared without losing text',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    final store = PalaFeedbackStore(db);
    expect(await store.read('answer-a'), isNull);
    await store.write('answer-a', AnswerVote.liked,
        now: DateTime.utc(2026, 11, 20));
    expect((await store.read('answer-a'))?.vote, AnswerVote.liked);
    await store.write('answer-a', AnswerVote.disliked,
        reasonCode: 'incorrect');
    expect((await store.read('answer-a'))?.reasonCode, 'incorrect');
    await store.write('answer-a', AnswerVote.disliked, reasonCode: 'slow');
    expect((await store.read('answer-a'))?.reasonCode, 'slow');
    await store.write('answer-a', AnswerVote.liked);
    expect((await store.read('answer-a'))?.vote, AnswerVote.liked);
    expect((await store.read('answer-a'))?.reasonCode, null);
    await store.write('answer-a', null);
    expect(await store.read('answer-a'), isNull);
    final rows = await db.customSelect(
      'SELECT content FROM messages WHERE id = ?',
      variables: [Variable.withString('answer-a')],
    ).get();
    expect(rows.where((r) => r.read<String>('content') == 'synthetic answer'),
        isNotEmpty);
  });

  test('only persisted assistant answers may be rated; reasons are bounded',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    final store = PalaFeedbackStore(db);
    await expectLater(
      store.write('question-a', AnswerVote.liked),
      throwsStateError,
    );
    await expectLater(
      store.write('nonexistent', AnswerVote.disliked),
      throwsStateError,
    );
    await expectLater(
      store.write('answer-a', AnswerVote.disliked,
          reasonCode: 'private free-text payload'),
      throwsArgumentError,
    );
    expect(await store.read('answer-a'), isNull);
  });

  test('feedback cascades on answer and chat deletion, not orphaned', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    final store = PalaFeedbackStore(db);
    await store.write('answer-a', AnswerVote.liked);
    await db.deleteMessage('answer-a');
    expect(await store.read('answer-a'), isNull);
    expect(await store.allVotes(), isEmpty);
    await db.customStatement(
      'INSERT INTO messages '
      '(id, chat_id, role, content, timestamp, sequence) VALUES (?,?,?,?,?,?)',
      ['answer-b', 'chat-a', 'assistant', 'answer', 1002, 3],
    );
    await store.write('answer-b', AnswerVote.disliked);
    await db.deleteChat('chat-a');
    expect(await store.read('answer-b'), isNull);
  });

  test('existing v16 database and new feedback survive a close and reopen',
      () async {
    final tmp = await Directory.systemTemp.createTemp('pala-m18-');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File(tmp.path + '/data.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await seed(db);
    final store = PalaFeedbackStore(db);
    await store.write('answer-a', AnswerVote.disliked, reasonCode: 'sources');
    final before = await db.customSelect('PRAGMA user_version').getSingle();
    expect(before.read<int>('user_version'), 16);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final restored = await PalaFeedbackStore(db).read('answer-a');
    expect(restored?.vote, AnswerVote.disliked);
    expect(restored?.reasonCode, 'sources');
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      16,
    );
    expect((await db.getMessages('chat-a')).length, 2);
  });

  test('owner-invoked local checks store truthful outcomes and no messages',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    final store = PalaFeedbackStore(db);
    expect(await store.testEvents(), isEmpty);
    final run = await store.runQuickChecks(now: DateTime.utc(2026, 11, 20));
    expect(run.length, 2);
    expect(run.every((r) => r.passed), true);
    final events = await store.testEvents();
    expect(events.length, 2);
    expect(events.map((e) => e.checkId),
        containsAll(['db_read', 'feedback_integrity']));
  });

  test('no samples and unobserved retrieval produce unknown, never 100',
      () {
    final w = PalaHealthCalculator.summarize(
      days: 7, now: DateTime.utc(2026, 11, 20),
      answers: const [], tests: const [],
    );
    expect(w.index, isNull);
    expect(w.positiveRate, isNull);
    expect(w.retrievalErrorRate, isNull);
    expect(w.testPassRate, isNull);
    expect(w.daily.length, 7);
    expect(w.daily.every((d) => d.answers == 0), isTrue);
    expect(w.missing.length, greaterThan(3));
  });

  test('formula uses 40/30/15/15, with sample thresholds and daily bins',
      () {
    final now = DateTime.utc(2026, 11, 20, 12);
    final samples = [
      for (int i = 0; i < 20; i++)
        PalaAnswerObservation(
          at: now.subtract(Duration(days: i % 3, hours: 1)),
          status: i == 0 ? 'error' : 'complete',
          vote: i < 8 ? AnswerVote.liked :
              i < 10 ? AnswerVote.disliked : null,
          retrievalError: i < 5 ? i == 1 : null,
          firstTokenMs: i < 3 ? (1000 + i * 100).toDouble() : null,
          tokensPerSecond: 20,
        ),
    ];
    final tests = [
      for (int i = 0; i < 4; i++)
        PalaHealthTestEvent(
          checkId: 'fixture-' + i.toString(),
          passed: i != 3, at: now,
        ),
    ];
    final w = PalaHealthCalculator.summarize(
      days: 7, now: now, answers: samples, tests: tests,
    );
    expect(w.index, 84);
    expect(w.liked, 8);
    expect(w.disliked, 2);
    expect(w.activeDays, 3);
    expect(w.positiveRate, 0.8);
    expect(w.retrievalObserved, 5);
    expect(w.retrievalErrors, 1);
    expect(w.medianFirstTokenMs, 1100);
    expect(w.meanTokensPerSecond, 20);
    expect(w.testPassRate, 0.75);
    expect(w.daily.fold<int>(0, (sum, d) => sum + d.answers), 20);
    expect(PalaHealthCalculator.summarize(
      days: 7, now: now, answers: samples,
      tests: tests, truncated: true,
    ).index, isNull);
  });

  test('7-day and 30-day windows differ, no invented speed or vote',
      () {
    final now = DateTime.utc(2026, 11, 20);
    final all = [
      PalaAnswerObservation(
        at: now.subtract(const Duration(days: 2)),
        status: 'complete',
        vote: AnswerVote.liked,
      ),
      PalaAnswerObservation(
        at: now.subtract(const Duration(days: 15)),
        status: 'interrupted',
      ),
    ];
    final week = PalaHealthCalculator.summarize(
      days: 7, now: now, answers: all, tests: const [],
    );
    final month = PalaHealthCalculator.summarize(
      days: 30, now: now, answers: all, tests: const [],
    );
    expect(week.answers, 1);
    expect(month.answers, 2);
    expect(week.medianFirstTokenMs, null);
    expect(month.meanRecallMs, null);
    expect(month.index, null);
  });

  test('existing source read checks distinguish missing from explicit errors',
      () {
    TurnRun run(Map<String, dynamic> metrics) => TurnRun(
      settings: const {},
      engine: const {},
      metrics: metrics,
      modelId: 'fake',
      modelName: 'fake',
      presetId: 'default',
      presetName: 'default',
      sources: 0,
      at: DateTime.utc(2026, 11, 20),
    );
    PalaAnswerObservation observation(Map<String, dynamic> metrics) =>
        PalaHealthCalculator.fromRun(
          timestamp: DateTime.utc(2026, 11, 20),
          status: 'complete',
          vote: null,
          runJson: run(metrics).encode(),
        );
    expect(observation(const {}).retrievalError, isNull);
    expect(observation(const {
      'offlineKnowledge': {
        'checks': [{'code': 'pdf_page_scan_failed'}],
      },
    }).retrievalError, true);
    expect(observation(const {
      'offlineKnowledge': {
        'checks': [{'code': 'zim_index_ready'}],
      },
    }).retrievalError, false);
  });
}
