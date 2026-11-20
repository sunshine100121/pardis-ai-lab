import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ondevice_llm/data/network/web_search/search_models.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/chat/domain/project_knowledge_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('باغبانی پردیس keeps one-time facts, sources and instructions after restart',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    final manager = first.read(conversationWorkspaceProvider.notifier);
    await manager.ready;
    await manager.saveProject(
      name: 'باغبانی پردیس',
      instructions: 'فارسی و کوتاه، اول اطلاعات تاییدشده باغ.',
      collection: 'pardis-gardening',
      memoryNotes: 'باغ آزمایشی: دو درخت گردو و آبیاری قطره‌ای.',
      sourceIds: const ['zim-botany', 'pdf-pruning'],
      sharedCollections: const ['general-science'],
    );
    await manager.saveProject(
      name: 'راهنمای رایانه',
      instructions: 'فقط درباره رایانه',
      collection: 'computers',
      memoryNotes: 'اطلاعات آزمایشی درباره لپ‌تاپ.',
    );
    final projects = first.read(conversationWorkspaceProvider).projects;
    final garden = projects.first;
    final computer = projects.last;
    await manager.assign(['garden-chat'], garden.id);
    final lastBoundary =
        first.read(conversationWorkspaceProvider).boundaryFor('garden-chat');
    expect(lastBoundary, isNotNull);
    first.dispose();

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(conversationWorkspaceProvider.notifier).ready;
    final state = restored.read(conversationWorkspaceProvider);
    expect(state.projectFor('garden-chat')?.id, garden.id);
    expect(state.projectFor('garden-chat')?.memoryNotes,
        contains('دو درخت گردو'));
    expect(state.projects.first.instructions, contains('فارسی و کوتاه'));
    expect(state.projects.first.sourceIds, ['zim-botany', 'pdf-pruning']);
    expect(state.projects.first.sharedCollections, ['general-science']);
    expect(state.projects.last.id, computer.id);
    expect(state.projects.last.memoryNotes, isNot(contains('دو درخت گردو')));
    expect(state.mayUseInContext(
        'garden-chat', DateTime.utc(2020, 1, 1)), isFalse);
    expect(state.mayUseInContext(
        'garden-chat', DateTime.utc(2035, 1, 1)), isTrue);
  });

  test('moving a chat keeps project settings but isolates old conversation',
      () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(conversationWorkspaceProvider.notifier);
    await notifier.ready;
    await notifier.saveProject(
      name: 'باغبانی پردیس',
      instructions: 'تنها داده باغبانی',
      memoryNotes: 'پاییز آزمایشی باغ سرد است.',
      sharedCollections: const ['science'],
    );
    await notifier.saveProject(
      name: 'پروژه خودرو',
      instructions: 'فقط خودرو',
      memoryNotes: 'ماشین آزمایشی قرمز است.',
    );
    final work = container.read(conversationWorkspaceProvider).projects;
    await notifier.assign(['move-chat'], work.first.id);
    await notifier.assign(['move-chat'], work.last.id);
    final moved = container.read(conversationWorkspaceProvider);
    expect(moved.projectFor('move-chat')?.id, work.last.id);
    expect(moved.projectFor('move-chat')?.memoryNotes, contains('قرمز'));
    expect(moved.projectFor('move-chat')?.memoryNotes, isNot(contains('پاییز')));
    expect(moved.projects.first.memoryNotes, contains('پاییز'));
    final before = moved.boundaryFor('move-chat')!;
    expect(moved.mayUseInContext(
        'move-chat', before.subtract(const Duration(milliseconds: 1))), isFalse);
    expect(moved.mayUseInContext(
        'move-chat', before.add(const Duration(milliseconds: 1))), isTrue);
    // Moving twice to the same project does not silently reset the history.
    await notifier.assign(['move-chat'], work.last.id);
    expect(container.read(conversationWorkspaceProvider)
        .scopeStarts['move-chat'], moved.scopeStarts['move-chat']);
    await notifier.assign(['move-chat'], null);
    final general = container.read(conversationWorkspaceProvider);
    expect(general.projectFor('move-chat'), isNull);
    expect(general.scopeStarts['move-chat'], isNot(moved.scopeStarts['move-chat']));
  });

  test('older project metadata loads without opting into shared knowledge',
      () async {
    SharedPreferences.setMockInitialValues({
      ConversationWorkspaceNotifier.key:
          '{"projects":[{"id":"garden","name":"باغبانی پردیس",'
          '"collection":"garden","sourceIds":["local-pdf"]}],'
          '"memberships":{"old-chat":"garden"},"states":{}}',
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(conversationWorkspaceProvider.notifier).ready;
    final project = c.read(conversationWorkspaceProvider).projects.single;
    expect(project.sourceIds, ['local-pdf']);
    expect(project.sharedCollections, isEmpty);
    expect(c.read(conversationWorkspaceProvider).scopeStarts, isEmpty);
  });

  test('ranking favors topic coverage; specialist only wins ties', () {
    SearchResult evidence(String title, String url, String collection, String text) =>
        SearchResult(
          title: title,
          url: url,
          snippet: '',
          source: 'Knowledge · ' + collection,
          rank: 1,
          pageText: text,
        );
    final specialist = evidence('باغبانی', 'knowledge://garden',
        'gardening', 'درخت گردو و آبیاری قطره‌ای');
    final shared = evidence('دانش عمومی', 'knowledge://science',
        'science', 'درخت گردو آبیاری قطره‌ای در زمستان');
    final unrelated = evidence('آب و هوا', 'knowledge://wrong',
        'gardening', 'تحقیق مستقل');
    final result = ProjectKnowledgePolicy.rank(
      'آبیاری درخت گردو در زمستان',
      [unrelated, specialist, shared, shared],
      specialistCollection: 'gardening',
    );
    expect(result.map((s) => s.url), [
      'knowledge://science',
      'knowledge://garden',
      'knowledge://wrong',
    ]);
    final tie = ProjectKnowledgePolicy.rank(
      'درخت گردو',
      [shared, specialist],
      specialistCollection: 'gardening',
    );
    expect(tie.first.url, 'knowledge://garden');
  });

  test('project cannot silently expand shared resources or lose them on rename',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(conversationWorkspaceProvider.notifier);
    await n.ready;
    await n.saveProject(name: 'باغبانی پردیس', sharedCollections: const ['general']);
    final saved = c.read(conversationWorkspaceProvider).projects.single;
    await n.saveProject(id: saved.id, name: 'باغبانی پردیس جدید');
    expect(c.read(conversationWorkspaceProvider).projects.single
        .sharedCollections, ['general']);
    await expectLater(
      n.saveProject(id: saved.id, name: saved.name,
          sharedCollections: const ['one', 'two', 'three', 'four', 'five']),
      throwsFormatException,
    );
    expect(c.read(conversationWorkspaceProvider).projects.single
        .sharedCollections, ['general']);
  });
}
