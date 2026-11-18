import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/core/providers/shared_providers.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/chat/presentation/providers/chat_provider.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'package:ondevice_llm/features/zim/zim_article_page.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/settings/presentation/screens/folder_knowledge_page.dart';
import 'package:ondevice_llm/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';

import 'offline_folder_library_test.dart' show TestFolder;
import 'offline_zim_reliability_test.dart' show FixtureFolder;
import 'support/persian_zim_fixture.dart';
import 'chat_test.dart' show TestEngine, TestModels, TestSettings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('project citation opens only its selected archive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final folder = FixtureFolder({
      'medical.zim': persianZim(archive: 'پزشکی ساختگی'),
      'garden.zim': persianZim(archive: 'باغ ساختگی'),
    });
    final opened = <String>[];
    folder.overrideOpen = (uri) async {
      opened.add(uri);
      return folder.files[uri]!.fresh();
    };
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final citation = (await library.searchDetailed(
      'بهبهان',
      sourceIds: {FolderLibrary.sourceId('garden.zim')},
    )).sources.single;
    opened.clear();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        folderLibraryProvider.overrideWithValue(library),
        llamaEngineProvider.overrideWithValue(TestEngine()),
        settingsProvider.overrideWith(TestSettings.new),
        modelManagerProvider.overrideWith(TestModels.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final workspace = container.read(conversationWorkspaceProvider.notifier);
    await workspace.ready;
    await workspace.saveProject(
      name: 'باغ ساختگی',
      sourceIds: [FolderLibrary.sourceId('garden.zim')],
    );
    final project = container
        .read(conversationWorkspaceProvider)
        .projects
        .single;
    container.read(chatProvider.notifier).newChat(projectId: project.id);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ZimArticlePage(
            url: citation.url,
            title: citation.title,
            excerpt: 'متن ذخیره‌شده',
            archiveId: citation.archiveId,
            archiveDate: citation.archiveDate,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, ['garden.zim']);
    expect(find.textContaining('خوزستان'), findsOneWidget);
  });
  testWidgets('successful archive check is visible after reopening the page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final folder = FixtureFolder({'fa.zim': persianZim()});
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final report = await library.searchDetailed('مریخ');
    expect(report.checks.single['code'], 'found');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [folderLibraryProvider.overrideWithValue(library)],
        child: const MaterialApp(home: FolderKnowledgePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('آخرین آزمایش، بازیابی مقاله را تأیید کرد'),
      findsOneWidget,
    );
    expect(find.text('fa.zim'), findsOneWidget);
  });
  testWidgets(
    'local citation opens its evidence without a technical URL or browser action',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSourceSheet(context, {
                  'title': 'small.pdf · صفحه 2',
                  'url': 'pala-knowledge://opaque-file-id',
                  'retrievalStatus': 'page_read',
                  'excerpt': 'Orchid concentration: 42 ppm.',
                  'number': 1,
                  'fetchedAt': '2026-11-14T10:00:00Z',
                }),
                child: const Text('منبع'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('منبع'));
      await tester.pumpAndSettle();
      expect(find.text('Orchid concentration: 42 ppm.'), findsOneWidget);
      expect(find.text('opaque-file-id'), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    },
  );
  testWidgets(
    'Persian folder actions, persisted toggle and URI only under Advanced',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final access = TestFolder()
        ..add(
          'notes.txt',
          Uint8List.fromList(
            utf8.encode('Orchid nutrient concentration is 42.'),
          ),
        );
      final library = FolderLibrary(access: access);
      await library.refresh(pick: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [folderLibraryProvider.overrideWithValue(library)],
          child: const MaterialApp(home: FolderKnowledgePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('پوشه دانش'), findsOneWidget);
      expect(find.text('بازخوانی منابع'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('content://test/tree/knowledge'), findsNothing);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect((await library.state())['files'][0]['enabled'], false);
      expect(access.picks, 1);
    },
  );
}
