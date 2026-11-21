import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/memory/domain/memory_policy.dart';
import 'package:ondevice_llm/features/memory/presentation/memory_policy_controls.dart';
import 'package:ondevice_llm/features/memory/presentation/providers/memory_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('owner approval persists one proposed memory with expiry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await container.read(memoryPreferencesProvider.notifier).ready;
    await container
        .read(memoryPreferencesProvider.notifier)
        .update(const MemoryPreferences(retention: MemoryRetention.sevenDays));
    container
        .read(memorySuggestionsProvider.notifier)
        .propose(
          'The user prefers concise Persian answers',
          sourceChatId: 'c42',
          sourceMessageId: 'm7',
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: MemoryPendingSuggestions()),
          ),
        ),
      ),
    );
    expect(await db.allMemories(), isEmpty);
    await tester.tap(find.text('تأیید و ذخیره'));
    await tester.pumpAndSettle();
    final saved = (await db.allMemories()).single;
    expect(saved.content, 'The user prefers concise Persian answers');
    expect(saved.sourceChatId, 'c42');
    expect(saved.sourceMessageId, 'm7');
    expect(saved.expiresAt, isNotNull);
    expect(
      saved.expiresAt!.difference(DateTime.now()).inDays,
      inInclusiveRange(6, 7),
    );
    expect(container.read(memorySuggestionsProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner rejection keeps the durable memory table unchanged', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container
        .read(memorySuggestionsProvider.notifier)
        .propose('The model thinks the user owns a motorcycle');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: MemoryPendingSuggestions()),
        ),
      ),
    );
    await tester.tap(find.text('رد کردن'));
    await tester.pumpAndSettle();
    expect(container.read(memorySuggestionsProvider), isEmpty);
    expect(await db.allMemories(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
