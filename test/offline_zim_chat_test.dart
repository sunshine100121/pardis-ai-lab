import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/core/providers/shared_providers.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/chat/domain/entities/chat_message.dart';
import 'package:ondevice_llm/features/chat/domain/entities/turn_run.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/chat/presentation/providers/chat_provider.dart';
import 'package:ondevice_llm/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/knowledge/knowledge_read_report.dart';
import 'package:ondevice_llm/features/knowledge/offline_knowledge.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/memory/presentation/providers/memory_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/tools/domain/tool_spec.dart';
import 'package:ondevice_llm/features/zim/zim_index_service.dart';
import 'package:ondevice_llm/features/zim/zim_index_storage.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';

import 'chat_test.dart'
    show
        TestEngine,
        TestSettings,
        TestModels,
        TestSearch,
        AlwaysWebSettings,
        FakeWikipedia;
import 'offline_zim_reliability_test.dart' show FixtureFolder;
import 'support/persian_zim_fixture.dart';

class ProjectTestSettings extends AlwaysWebSettings {
  @override
  InferenceSettings build() => super.build().copyWith(memoryEnabled: true);
}

class ProjectTranslateEngine extends TestEngine {
  @override
  Stream<String> generate({
    required List<Map<String, Object>> messages,
    required String fallbackTemplate,
    required InferenceSettings settings,
    String assistantPrefix = '',
    List<ToolSpec> tools = const [],
    String toolChoice = 'auto',
  }) async* {
    if ('${messages.first['content']}'.contains('short English search query')) {
      yield 'walnut tree watering irrigation';
      return;
    }
    yield* super.generate(
      messages: messages,
      fallbackTemplate: fallbackTemplate,
      settings: settings,
      assistantPrefix: assistantPrefix,
      tools: tools,
      toolChoice: toolChoice,
    );
  }
}

class MissingEncyclopedia extends OfflineKnowledge {
  final String code;
  MissingEncyclopedia(this.code) : super(FolderLibrary());
  @override
  Future<KnowledgeReadReport> searchDetailed(String question) async =>
      KnowledgeReadReport([], [
        {
          'file': 'دانشنامه فارسی.zim',
          'code': code,
          'stage': 'content',
          'elapsedMs': 8,
        },
      ]);
}

class EvidenceDoesNotFit extends TestEngine {
  @override
  Future<Map<String, dynamic>> previewPrompt({
    required List<Map<String, Object>> messages,
    required String fallbackTemplate,
    required InferenceSettings settings,
    String assistantPrefix = '',
    List<ToolSpec> tools = const [],
  }) async {
    if (messages.last['content'].toString().contains('خوزستان'))
      return {'fits': false};
    return super.previewPrompt(
      messages: messages,
      fallbackTemplate: fallbackTemplate,
      settings: settings,
      assistantPrefix: assistantPrefix,
      tools: tools,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('unreadable workspace stops a turn without querying or overwriting metadata', () async {
    SharedPreferences.setMockInitialValues({
      ConversationWorkspaceNotifier.key: '{invalid',
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final engine = TestEngine();
    final folder = FixtureFolder({'garden.zim': persianZim()});
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        llamaEngineProvider.overrideWithValue(engine),
        settingsProvider.overrideWith(TestSettings.new),
        modelManagerProvider.overrideWith(TestModels.new),
        offlineKnowledgeProvider.overrideWithValue(
          OfflineKnowledge(FolderLibrary(access: folder)),
        ),
      ],
    );
    try {
      expect(
        await container.read(chatProvider.notifier).send('پرسش ساختگی'),
        isFalse,
      );
      expect(
        container.read(chatProvider).error,
        contains('اطلاعات محدوده پروژه‌ها'),
      );
      expect(engine.receivedMessages, isNull);
      expect(folder.opened, isEmpty);
      expect(await db.allChats(), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          ConversationWorkspaceNotifier.key,
        ),
        '{invalid',
      );
    } finally {
      container.dispose();
      await db.close();
    }
  });
  Future<({ChatMessage answer, TestEngine engine})> run(
    OfflineKnowledge knowledge,
    String question, {
    TestEngine? injectedEngine,
    bool reopen = false,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final engine = injectedEngine ?? TestEngine();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        llamaEngineProvider.overrideWithValue(engine),
        settingsProvider.overrideWith(TestSettings.new),
        modelManagerProvider.overrideWith(TestModels.new),
        offlineKnowledgeProvider.overrideWithValue(knowledge),
      ],
    );
    try {
      expect(await container.read(chatProvider.notifier).send(question), true);
      final answer = container
          .read(chatProvider)
          .messages
          .lastWhere((m) => m.role == ChatRole.assistant);
      // Check persisted data, not just a transient state notice.
      final saved = await (db.select(
        db.messages,
      )..where((m) => m.id.equals(answer.id))).getSingle();
      expect(saved.runJson, answer.runJson);
      expect(saved.sourcesJson, answer.sourcesJson);
      if (reopen) {
        final notifier = container.read(chatProvider.notifier);
        notifier.newChat();
        await notifier.openChat(saved.chatId);
        final restored = container
            .read(chatProvider)
            .messages
            .lastWhere((m) => m.id == answer.id);
        expect(restored.runJson, saved.runJson);
        return (answer: restored, engine: engine);
      }
      return (answer: answer, engine: engine);
    } finally {
      container.dispose();
      await db.close();
    }
  }

  test('Persian project chat receives indexed English evidence and excludes medical archive', () async {
    final directory = await Directory.systemTemp.createTemp('pala-chat-index-');
    addTearDown(() => directory.delete(recursive: true));
    final folder = FixtureFolder({
      'medical.zim': persianZim(
        englishGarden: true,
        archive: 'Medical fixture',
      ),
      'garden.zim': persianZim(
        englishGarden: true,
        archive: 'Gardening fixture',
      ),
    });
    final opened = <String>[];
    folder.overrideOpen = (uri) async {
      opened.add(uri);
      return folder.files[uri]!.fresh();
    };
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final storage = ZimIndexStorage(
      directory: directory,
      maxDatabaseBytes: 2 * 1024 * 1024,
      reserveBytes: 1,
      availableBytes: () async => 16 * 1024 * 1024,
    );
    final service = ZimIndexService(library, storage);
    await service.run(uri: 'garden.zim', allowed: () => true);
    await service.run(uri: 'medical.zim', allowed: () => true);
    opened.clear();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final engine = ProjectTranslateEngine();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        llamaEngineProvider.overrideWithValue(engine),
        settingsProvider.overrideWith(ProjectTestSettings.new),
        modelManagerProvider.overrideWith(TestModels.new),
        offlineKnowledgeProvider.overrideWithValue(OfflineKnowledge(library)),
        zimIndexStorageProvider.overrideWith((ref) async => storage),
      ],
    );
    try {
      final workspace = container.read(conversationWorkspaceProvider.notifier);
      await workspace.ready;
      await workspace.saveProject(
        name: 'باغ ساختگی',
        sourceIds: [FolderLibrary.sourceId('garden.zim')],
      );
      final id = container
          .read(conversationWorkspaceProvider)
          .projects
          .single
          .id;
      final chat = container.read(chatProvider.notifier);
      chat.newChat(projectId: id);
      expect(await chat.send('آبیاری درخت گردو چگونه است؟'), isTrue);
      expect(opened, isNotEmpty);
      expect(opened.every((uri) => uri == 'garden.zim'), isTrue);
      expect(engine.receivedMessages.toString(), contains('walnut'));
      expect(engine.receivedMessages.toString(), contains('Gardening fixture'));
      expect(engine.receivedMessages.toString(), contains('Answer in Persian'));
      expect(
        engine.receivedMessages.toString(),
        isNot(contains('Medical fixture')),
      );
      final answer = container.read(chatProvider).messages.last;
      final citations = jsonDecode(answer.sourcesJson) as List;
      expect(citations.single['title'], 'Plant care — Gardening fixture');
      expect(citations.single['url'], startsWith('zim://'));
    } finally {
      container.dispose();
      await db.close();
    }
  });

  test(
    'project chat searches only selected sources and never starts web search',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final engine = TestEngine();
      final search = TestSearch();
      final wiki = FakeWikipedia();
      final folder = FixtureFolder({
        'garden.zim': persianZim(archive: 'منبع باغبانی آزمون'),
        'medical.zim': persianZim(archive: 'منبع پزشکی آزمون'),
      });
      final opened = <String>[];
      folder.overrideOpen = (uri) async {
        opened.add(uri);
        return folder.files[uri]!.fresh();
      };
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          llamaEngineProvider.overrideWithValue(engine),
          settingsProvider.overrideWith(ProjectTestSettings.new),
          modelManagerProvider.overrideWith(TestModels.new),
          offlineKnowledgeProvider.overrideWithValue(OfflineKnowledge(library)),
          duckDuckGoScraperProvider.overrideWithValue(search),
          wikipediaClientProvider.overrideWithValue(wiki),
        ],
      );
      try {
        final workspace = container.read(
          conversationWorkspaceProvider.notifier,
        );
        await MemoryStore(db).add('اطلاعات خصوصی ساختگی پروژه دیگر');
        await workspace.ready;
        await workspace.saveProject(
          name: 'باغ ساختگی',
          sourceIds: [FolderLibrary.sourceId('garden.zim')],
        );
        final projectId = container
            .read(conversationWorkspaceProvider)
            .projects
            .single
            .id;
        final chat = container.read(chatProvider.notifier);
        chat.newChat(projectId: projectId);
        expect(await chat.send('بهبهان کجاست؟'), isTrue);
        expect(opened, ['garden.zim']);
        expect(search.calls, 0);
        expect(wiki.asked, isEmpty);
        expect(
          engine.receivedMessages.toString(),
          contains('منبع باغبانی آزمون'),
        );
        expect(
          engine.receivedMessages.toString(),
          isNot(contains('منبع پزشکی آزمون')),
        );
        expect(
          engine.receivedMessages.toString(),
          isNot(contains('اطلاعات خصوصی ساختگی پروژه دیگر')),
        );
        chat.newChat(projectId: projectId);
        engine.receivedMessages = null;
        expect(await chat.send('در اینترنت درباره بهبهان جستجو کن'), isTrue);
        expect(engine.receivedMessages, isNull);
        expect(search.calls, 0);
        expect(
          container.read(chatProvider).messages.last.content,
          contains('به اینترنت ارسال نشد'),
        );
        chat.newChat(projectId: projectId);
        engine.receivedMessages = null;
        expect(await chat.send('دمای باغ الان چقدره؟'), isTrue);
        expect(engine.receivedMessages, isNull);
        expect(
          container.read(chatProvider).messages.last.content,
          contains('حدس زده نمی‌شود'),
        );
        await workspace.saveProject(
          id: projectId,
          name: 'باغ ساختگی',
          sourceIds: [],
        );
        chat.newChat(projectId: projectId);
        opened.clear();
        engine.receivedMessages = null;
        expect(await chat.send('بهبهان کجاست؟'), isTrue);
        expect(opened, isEmpty);
        expect(engine.receivedMessages, isNull);
        expect(
          container.read(chatProvider).messages.last.content,
          contains('شاهد مرتبطی پیدا نشد'),
        );
      } finally {
        container.dispose();
        await db.close();
      }
    },
  );

  test('direct modern Persian ZIM evidence reaches local chat and retained real citations', () async {
    final library = FolderLibrary(
      access: FixtureFolder({'fa.zim': persianZim(large: true)}),
    );
    await library.refresh();
    final result = await run(
      OfflineKnowledge(library),
      'طبق ویکی‌پدیا بهبهان کجاست؟',
    );
    expect(result.engine.receivedMessages.toString(), contains('خوزستان'));
    expect(
      result.engine.receivedMessages.toString(),
      contains('دانشنامهٔ فارسی آزمون'),
    );
    final sources = jsonDecode(result.answer.sourcesJson) as List;
    expect(sources, hasLength(1));
    expect(sources.single['title'], 'بهبهان — دانشنامهٔ فارسی آزمون');
    expect(sources.single['url'], startsWith('zim://'));
    final status =
        TurnRun.decode(result.answer.runJson)!.metrics['offlineKnowledge']
            as Map;
    expect(status['supplied'], true);
    expect((status['checks'] as List).single['code'], 'found');
  });
  test('retrieved article dropped by context fitting cannot count as a supplied citation', () async {
    final library = FolderLibrary(
      access: FixtureFolder({'fa.zim': persianZim()}),
    );
    await library.refresh();
    final result = await run(
      OfflineKnowledge(library),
      'طبق ویکی‌پدیا بهبهان کجاست؟',
      injectedEngine: EvidenceDoesNotFit(),
    );
    expect(result.engine.receivedMessages, isNull);
    expect(jsonDecode(result.answer.sourcesJson), isEmpty);
    final status =
        TurnRun.decode(result.answer.runJson)!.metrics['offlineKnowledge']
            as Map;
    expect(status['supplied'], false);
    expect(status['delivery'], 'context_limit');
  });
  for (final code in ['not_found', 'timeout', 'format', 'access']) {
    test(
      'explicit encyclopedia request refuses before generation when $code',
      () async {
        final result = await run(
          MissingEncyclopedia(code),
          'با استناد به دانشنامه درباره مریخ بگو',
        );
        expect(result.engine.receivedMessages, isNull);
        expect(result.answer.content, contains('پاسخ مستند تولید نمی‌کنم'));
        expect(jsonDecode(result.answer.sourcesJson), isEmpty);
        final status =
            TurnRun.decode(result.answer.runJson)!.metrics['offlineKnowledge']
                as Map;
        expect(status['supplied'], false);
        expect((status['checks'] as List).single['code'], code);
      },
    );
  }
  test(
    'ordinary factual answer retains independent no-source status',
    () async {
      final result = await run(
        MissingEncyclopedia('not_found'),
        'بهبهان کجاست؟',
      );
      expect(result.engine.receivedMessages, isNotNull);
      expect(jsonDecode(result.answer.sourcesJson), isEmpty);
      final status =
          TurnRun.decode(result.answer.runJson)!.metrics['offlineKnowledge']
              as Map;
      expect(status['requiredEncyclopedia'], false);
      expect(status['supplied'], false);
      expect(
        TurnRun.decode(result.answer.runJson)!.metrics['modelKnowledge'],
        true,
      );
    },
  );
  testWidgets('model knowledge label is rendered from the saved run', (
    tester,
  ) async {
    final result = (await tester.runAsync(
      () =>
          run(MissingEncyclopedia('not_found'), 'بهبهان کجاست؟', reopen: true),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatBubble(message: result.answer),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-knowledge-source')), findsOneWidget);
    expect(find.textContaining('منبع [۰]'), findsOneWidget);
  });
  for (final code in ['ha_unavailable', 'ha_ambiguous', 'ha_insufficient']) {
    test(
      'failed HA evidence cannot produce a model-invented number: $code',
      () async {
        final result = await run(
          MissingEncyclopedia(code),
          'آلودگی باغ در شش ماه چگونه بوده است؟',
        );
        expect(result.engine.receivedMessages, isNull);
        expect(jsonDecode(result.answer.sourcesJson), isEmpty);
        expect(result.answer.content, contains('عددی اعلام نمی‌کنم'));
        final status =
            TurnRun.decode(result.answer.runJson)!.metrics['offlineKnowledge']
                as Map;
        expect((status['checks'] as List).single['code'], code);
      },
    );
  }
  testWidgets(
    'source status survives reopening and stays separate from model prose and citations',
    (tester) async {
      final result = (await tester.runAsync(
        () => run(MissingEncyclopedia('timeout'), 'طبق ویکی‌پدیا مریخ چیست؟'),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatBubble(message: result.answer),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('knowledge-source-status')), findsOneWidget);
      expect(
        find.textContaining('مقالهٔ قابل‌استناد به مدل داده نشد'),
        findsOneWidget,
      );
      await tester.tap(find.text('جزئیات خواندن دانشنامه'));
      await tester.pumpAndSettle();
      expect(find.textContaining('مهلت خواندن در مرحله'), findsOneWidget);
      expect(find.text('Wikipedia'), findsNothing);
    },
  );
  testWidgets(
    'retrieved encyclopedia chip shows the real article and archive names',
    (tester) async {
      final result = (await tester.runAsync(() async {
        final library = FolderLibrary(
          access: FixtureFolder({'fa.zim': persianZim()}),
        );
        await library.refresh();
        return run(OfflineKnowledge(library), 'بهبهان کجاست');
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatBubble(message: result.answer),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('بهبهان — دانشنامهٔ فارسی آزمون'), findsOneWidget);
      expect(find.byKey(const Key('knowledge-source-status')), findsOneWidget);
    },
  );
}
