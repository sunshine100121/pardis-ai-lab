import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/health/answer_feedback_bar.dart';
import 'package:ondevice_llm/features/health/pala_feedback_store.dart';
import 'package:ondevice_llm/features/health/pala_health_page.dart';

Future<AppDatabase> fixture() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  await db.customStatement(
    'INSERT INTO chats (id, title, created_at, updated_at) '
    'VALUES (?,?,?,?)',
    ['chat', 'Synthetic local', 100, 100],
  );
  await db.customStatement(
    'INSERT INTO messages (id, chat_id, role, content, timestamp, sequence) '
    'VALUES (?,?,?,?,?,?)',
    ['answer', 'chat', 'assistant', 'Synthetic response', 100, 1],
  );
  return db;
}

Widget app(AppDatabase db, Widget child) => ProviderScope(
  overrides: [appDatabaseProvider.overrideWithValue(db)],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tap like, change to dislike, give optional reason, undo', (
    tester,
  ) async {
    final db = await fixture();
    addTearDown(db.close);
    final store = PalaFeedbackStore(db);
    await tester.pumpWidget(
      app(db, const AnswerFeedbackBar(messageId: 'answer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pala-like-answer')));
    await tester.pumpAndSettle();
    expect((await store.read('answer'))?.vote, AnswerVote.liked);
    await tester.tap(find.byKey(const Key('pala-dislike-answer')));
    await tester.pumpAndSettle();
    expect((await store.read('answer'))?.vote, AnswerVote.disliked);
    await tester.tap(find.byKey(const Key('pala-feedback-reason-answer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feedback-reason-incorrect')));
    await tester.pumpAndSettle();
    expect((await store.read('answer'))?.reasonCode, 'incorrect');
    await tester.tap(find.byKey(const Key('pala-dislike-answer')));
    await tester.pumpAndSettle();
    expect(await store.read('answer'), isNull);
    await tester.tap(find.byKey(const Key('pala-like-answer')));
    await tester.pumpAndSettle();
    expect((await store.read('answer'))?.vote, AnswerVote.liked);
    expect((await store.read('answer'))?.reasonCode, null);
  });

  testWidgets(
    'health page refuses fake score and runs two actual local checks',
    (tester) async {
      final db = await fixture();
      addTearDown(db.close);
      await tester.pumpWidget(app(db, const PalaHealthPage()));
      await tester.pumpAndSettle();
      expect(find.text('داده کافی نیست'), findsOneWidget);
      expect(find.byKey(const Key('pala-health-index')), findsOneWidget);
      await tester.tap(find.text('۳۰ روز'));
      await tester.pumpAndSettle();
      expect(find.text('داده کافی نیست'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('pala-run-health-checks')),
        300,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 25,
      );
      await tester.tap(find.byKey(const Key('pala-run-health-checks')));
      await tester.pumpAndSettle();
      final results = await PalaFeedbackStore(db).testEvents();
      expect(results.length, 2);
      expect(results.every((event) => event.passed), isTrue);
      // The dashboard's ListView builds lazily; after provider refresh the
      // statistics row may be outside the viewport. Verify its real display.
      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('۲ موفق از ۲'),
        250,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 30,
      );
      expect(find.text('۲ موفق از ۲'), findsOneWidget);
    },
  );
}
