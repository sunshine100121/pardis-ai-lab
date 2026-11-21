import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/health/answer_feedback_bar.dart';
import 'package:ondevice_llm/features/health/pala_feedback_store.dart';
import 'package:ondevice_llm/features/learning/pala_learning_page.dart';
import 'package:ondevice_llm/features/learning/pala_learning_store.dart';

Future<AppDatabase> fixture() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  await db.customStatement(
    'INSERT INTO chats(id,title,created_at,updated_at) VALUES(?,?,?,?)',
    ['chat', 'fixture', 100, 100],
  );
  await db.customStatement(
    'INSERT INTO messages(id,chat_id,role,content,timestamp,sequence) '
    'VALUES(?,?,?,?,?,?)',
    ['question', 'chat', 'user', 'علت لکه های زرد روی برگ انجیر چیست', 100, 1],
  );
  await db.customStatement(
    'INSERT INTO messages(id,chat_id,role,content,timestamp,sequence) '
    'VALUES(?,?,?,?,?,?)',
    ['answer', 'chat', 'assistant', 'پاسخ اولیه ساختگی', 101, 2],
  );
  return db;
}

Widget app(AppDatabase db, Widget child) => ProviderScope(
  overrides: [appDatabaseProvider.overrideWithValue(db)],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('feedback only proposes; approval and rollback need owner tap', (
    tester,
  ) async {
    final db = await fixture();
    addTearDown(db.close);
    await PalaFeedbackStore(db).write('answer', AnswerVote.disliked);

    await tester.pumpWidget(
      app(db, const AnswerFeedbackBar(messageId: 'answer')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('m19-propose-correction-answer')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('m19-propose-correction-answer')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('m19-owner-correction-field')),
      'لکه های زرد همیشه نشانه آفت نیستند و باید نور و آبیاری بررسی شوند.',
    );
    await tester.tap(find.byKey(const Key('m19-submit-correction')));
    await tester.pumpAndSettle();

    final store = PalaLearningStore(db);
    final cases = await store.all();
    expect(cases, hasLength(1));
    final draft = cases.single;
    expect(draft.state, LearningState.proposed);
    expect(await store.match('chat', draft.question), null);

    await tester.pumpWidget(app(db, const PalaLearningPage()));
    await tester.pumpAndSettle();
    final approveKey = Key('m19-approve-' + draft.id);
    await tester.tap(find.byKey(approveKey));
    await tester.pumpAndSettle();
    expect((await store.byId(draft.id))?.state, LearningState.active);
    expect(
      (await store.match('chat', 'چرا برگ انجیر لکه زرد دارد؟'))?.correction,
      draft.correction,
    );
    final disableKey = Key('m19-disable-' + draft.id);
    await tester.tap(find.byKey(disableKey));
    await tester.pumpAndSettle();
    expect(await store.match('chat', draft.question), null);
    expect((await store.byId(draft.id))?.state, LearningState.disabled);
  });
}
