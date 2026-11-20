import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/memory/domain/memory_policy.dart';
import 'package:ondevice_llm/features/memory/presentation/providers/memory_preferences.dart';
import 'package:ondevice_llm/features/memory/presentation/providers/memory_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retention options and strict cross-project isolation', () {
    final now = DateTime(2026, 11, 20);
    expect(MemoryRetention.sevenDays.expiresFrom(now), DateTime(2026, 11, 27));
    expect(MemoryRetention.thirtyDays.expiresFrom(now), DateTime(2026, 12, 20));
    expect(MemoryRetention.ninetyDays.expiresFrom(now), DateTime(2027, 2, 18));
    expect(MemoryRetention.untilDeleted.expiresFrom(now), isNull);
    expect(MemoryScopePolicy.isVisible(
      scope: MemoryScope.project,
      itemProjectId: 'garden',
      currentProjectId: 'garden',
    ), isTrue);
    expect(MemoryScopePolicy.isVisible(
      scope: MemoryScope.project,
      itemProjectId: 'garden',
      currentProjectId: 'work',
    ), isFalse);
    expect(MemoryScopePolicy.isVisible(
      scope: MemoryScope.conversation,
      itemChatId: 'chat-a',
      currentChatId: 'chat-b',
    ), isFalse);
    expect(MemoryScopePolicy.isVisible(
      scope: MemoryScope.general,
      currentProjectId: 'garden',
    ), isFalse);
  });

  test('automatic learning requires explicit low-risk user evidence', () {
    expect(MemoryAdmissionPolicy.mayPersist(
      mode: MemoryLearningMode.automatic,
      evidence: MemoryEvidence.explicitUserStatement,
      content: 'The user prefers concise answers',
    ), isTrue);
    expect(MemoryAdmissionPolicy.mayPersist(
      mode: MemoryLearningMode.automatic,
      evidence: MemoryEvidence.modelProposal,
      content: 'The user prefers concise answers',
    ), isFalse);
    expect(MemoryAdmissionPolicy.mayPersist(
      mode: MemoryLearningMode.confirm,
      evidence: MemoryEvidence.explicitUserStatement,
      content: 'The user prefers concise answers',
    ), isFalse);
    expect(MemoryAdmissionPolicy.mayPersist(
      mode: MemoryLearningMode.automatic,
      evidence: MemoryEvidence.explicitUserStatement,
      content: 'The user has a secret bank account',
    ), isFalse);
    expect(MemoryAdmissionPolicy.needsApproval(
      mode: MemoryLearningMode.automatic,
      evidence: MemoryEvidence.modelProposal,
    ), isTrue);
  });

  test('learning, retention and tone persist after provider is reopened',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    await first.read(memoryPreferencesProvider.notifier).ready;
    await first.read(memoryPreferencesProvider.notifier).update(
      const MemoryPreferences(
        learning: MemoryLearningMode.confirm,
        retention: MemoryRetention.ninetyDays,
        responseStyle: MemoryResponseStyle.formal,
      ),
    );
    first.dispose();
    final reopened = ProviderContainer();
    addTearDown(reopened.dispose);
    await reopened.read(memoryPreferencesProvider.notifier).ready;
    final saved = reopened.read(memoryPreferencesProvider);
    expect(saved.learning, MemoryLearningMode.confirm);
    expect(saved.retention, MemoryRetention.ninetyDays);
    expect(saved.responseStyle, MemoryResponseStyle.formal);
  });

  test('fact survives database reopening; edit preserves expiry/source', () async {
    final dir = await Directory.systemTemp.createTemp('pala-memory-m11-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(dir.path + '/pala.sqlite');
    final db = AppDatabase.forTesting(NativeDatabase(file));
    final store = MemoryStore(db);
    final end = DateTime.now().add(const Duration(days: 30));
    final fact = await store.add(
      'The user prefers Persian answers',
      sourceChatId: 'c1',
      sourceMessageId: 'm1',
      expiresAt: end,
    );
    await store.pin(fact, true);
    await store.edit(fact, 'The user prefers concise Persian answers');
    await db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final found = (await reopened.allMemories()).single;
    expect(found.content, 'The user prefers concise Persian answers');
    expect(found.pinned, isTrue);
    expect(found.sourceChatId, 'c1');
    expect(found.sourceMessageId, 'm1');
    // Drift stores DateTime values at whole-second resolution.
    expect((found.expiresAt?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        end.millisecondsSinceEpoch ~/ 1000);
  });

  test('unapproved proposals are never added to durable memory', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(c.dispose);
    c.read(memorySuggestionsProvider.notifier).propose(
      'The user prefers short answers',
      sourceChatId: 'c1',
    );
    expect(c.read(memorySuggestionsProvider), hasLength(1));
    expect(await db.allMemories(), isEmpty);
    c.read(memorySuggestionsProvider.notifier).clear();
    expect(await db.allMemories(), isEmpty);
  });
  test('expired memories are physically deleted on memory-store read', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MemoryStore(db);
    await store.add(
      'The user prefers short explanations',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    await store.add('The user prefers Persian');
    final rows = await store.all();
    expect(rows, hasLength(1));
    expect(rows.single.content, 'The user prefers Persian');
    expect(await db.allMemories(), hasLength(1));
  });

}
