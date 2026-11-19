import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/core/providers/shared_providers.dart';
import 'package:ondevice_llm/core/theme/app_theme.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/chat/domain/chat_draft_store.dart';
import 'package:ondevice_llm/features/chat/presentation/providers/chat_provider.dart';
import 'package:ondevice_llm/features/chat/presentation/screens/chat_screen.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/effective_settings_provider.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';

import 'chat_test.dart' show TestEngine, TestModels, TestSettings;

class _Paths extends PathProviderPlatform {
  final String path;
  Completer<void>? gate;
  _Paths(this.path);
  @override
  Future<String?> getApplicationSupportPath() async {
    final pending = gate;
    if (pending != null) await pending.future;
    return path;
  }
}

void main() {
  test(
    'only an owner-specific matching note can justify a no-source answer',
    () {
      expect(
        ProjectMemoryGate.relevant(
          'در باغ من چند درخت گردو وجود دارد؟',
          'در باغ من ۵ درخت گردو وجود دارد.',
        ),
        isTrue,
      );
      expect(
        ProjectMemoryGate.relevant(
          'آبیاری درخت گردو طبق تحقیقات علمی چگونه است؟',
          'در باغ من ۵ درخت گردو وجود دارد.',
        ),
        isFalse,
      );
      expect(
        ProjectMemoryGate.relevant(
          'در باغ من چند درخت گردو وجود دارد؟',
          'گلخانه این پروژه فقط کاکتوس دارد.',
        ),
        isFalse,
      );
      expect(
        ProjectMemoryGate.relevant(
          'در باغ من چند درخت گردو وجود دارد؟',
          'در باغ من سیب داریم.\nگردو فقط در فهرست خرید است.',
        ),
        isFalse,
        reason: 'Unrelated memory lines must not combine into evidence',
      );
      expect(
        ProjectMemoryGate.relevant(
          'در باغ من چند درخت گردو وجود دارد؟',
          'در باغ من ۵ درخت گردو وجود دارد.\nگلخانه فقط کاکتوس دارد.',
        ),
        isTrue,
      );
    },
  );

  test('owner memory understands colloquial phrases and explicit overviews',
      () {
    const saved = '• درخت گردو آبیاری قطره‌ای دارد. '
        '(تأیید مالک؛ تاریخ: 2026-11-18T00:00:00Z؛ '
        'گفتگو: garden-chat؛ پیام: first)';
    expect(
      ProjectMemoryGate.relevant(
        'در مورد درخت گردوی من چی یادت هست؟',
        saved,
      ),
      isTrue,
    );
    expect(
      ProjectMemoryGate.relevant(
        'روش آبیاری درخت گردوی من چیه؟',
        saved,
      ),
      isTrue,
    );
    expect(
      ProjectMemoryGate.relevant(
        'چه اطلاعاتی از باغ من ثبت کردی؟',
        saved,
      ),
      isTrue,
    );
    expect(
      ProjectMemoryGate.relevant(
        'در مورد فشار خون من چی یادت هست؟',
        saved,
      ),
      isFalse,
    );
    expect(
      ProjectMemoryGate.relevant(
        'این روش آبیاری طبق تحقیقات علمی بهتر است؟',
        saved,
      ),
      isFalse,
    );
  });

  test(
    'owner-edited project notes persist without mixing project scopes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      addTearDown(first.dispose);
      final workspace = first.read(conversationWorkspaceProvider.notifier);
      await workspace.ready;
      await workspace.saveProject(
        name: 'باغبانی آزمایشی',
        memoryNotes: 'در این باغ آزمایشی یک درخت گردو وجود دارد.',
      );
      await workspace.saveProject(name: 'سلامت آزمایشی');
      final garden = first.read(conversationWorkspaceProvider).projects.first;
      await workspace.assign(['garden-chat'], garden.id);
      await workspace.rememberChatMessage(
        projectId: garden.id,
        chatId: 'garden-chat',
        messageId: 'message-1',
        note: 'درخت گردوی آزمایشی آبیاری قطره‌ای دارد.',
        notedAt: DateTime(2026, 11, 18),
      );
      await expectLater(
        workspace.rememberChatMessage(
          projectId: garden.id,
          chatId: 'unrelated-chat',
          messageId: 'message-2',
          note: 'اطلاعات نامرتبط',
          notedAt: DateTime(2026, 11, 18),
        ),
        throwsStateError,
      );

      final second = ProviderContainer();
      addTearDown(second.dispose);
      final restored = second.read(conversationWorkspaceProvider.notifier);
      await restored.ready;
      final stored = second.read(conversationWorkspaceProvider);
      expect(
        stored.projectFor('garden-chat')?.memoryNotes,
        contains('در این باغ آزمایشی یک درخت گردو وجود دارد.'),
      );
      expect(stored.projects.last.memoryNotes, isEmpty);
      expect(
        stored.projectFor('garden-chat')?.memoryNotes,
        contains('درخت گردوی آزمایشی آبیاری قطره‌ای دارد.'),
      );
      expect(
        stored.projectFor('garden-chat')?.memoryNotes,
        contains('message-1'),
      );
      await restored.saveProject(id: garden.id, name: garden.name);
      final updated = second.read(conversationWorkspaceProvider);
      expect(
        updated.projectFor('garden-chat')?.memoryNotes,
        contains('درخت گردوی آزمایشی آبیاری قطره‌ای دارد.'),
      );
    },
  );

  test('renaming a project preserves instructions, sources and saved memory',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    addTearDown(first.dispose);
    final editor = first.read(conversationWorkspaceProvider.notifier);
    await editor.ready;
    await editor.saveProject(
      name: 'باغ',
      instructions: 'پاسخ‌ها به فارسی باشند.',
      collection: 'gardening',
      memoryNotes: 'دو درخت آزمایشی دارم.',
      sourceIds: const ['source-garden'],
    );
    final id = first.read(conversationWorkspaceProvider).projects.single.id;
    // An older caller may supply only name/id and must not erase fields.
    await editor.saveProject(id: id, name: 'باغ پردیس');
    final second = ProviderContainer();
    addTearDown(second.dispose);
    final restored = second.read(conversationWorkspaceProvider.notifier);
    await restored.ready;
    final saved = second.read(conversationWorkspaceProvider).projects.single;
    expect(saved.name, 'باغ پردیس');
    expect(saved.instructions, 'پاسخ‌ها به فارسی باشند.');
    expect(saved.collection, 'gardening');
    expect(saved.memoryNotes, 'دو درخت آزمایشی دارم.');
    expect(saved.sourceIds, ['source-garden']);
    // Explicit clearing through the editor must still be possible.
    await restored.saveProject(
      id: id,
      name: 'باغ پردیس',
      instructions: '',
      collection: '',
    );
    final cleared = second.read(conversationWorkspaceProvider).projects.single;
    expect(cleared.instructions, isEmpty);
    expect(cleared.collection, isEmpty);
    expect(cleared.memoryNotes, 'دو درخت آزمایشی دارم.');
    expect(cleared.sourceIds, ['source-garden']);
  });

  test('legacy workspace metadata loads and failed update preserves stored data',
      () async {
    final original = jsonEncode({
      'projects': [
        {
          'id': 'legacy-garden',
          'name': 'باغ قدیمی',
          'instructions': 'فقط منابع باغبانی.',
          'collection': 'garden-index',
        },
      ],
      'memberships': {'garden-chat': 'legacy-garden'},
      'states': <String, String>{},
    });
    SharedPreferences.setMockInitialValues({
      ConversationWorkspaceNotifier.key: original,
    });
    final first = ProviderContainer();
    addTearDown(first.dispose);
    final editor = first.read(conversationWorkspaceProvider.notifier);
    await editor.ready;
    final legacy = first.read(conversationWorkspaceProvider).projects.single;
    expect(legacy.memoryNotes, isEmpty);
    expect(legacy.sourceIds, isEmpty);
    await editor.saveProject(id: legacy.id, name: 'باغ قدیمی اصلاح‌شده');
    final second = ProviderContainer();
    addTearDown(second.dispose);
    final reopened = second.read(conversationWorkspaceProvider.notifier);
    await reopened.ready;
    final project = second.read(conversationWorkspaceProvider).projects.single;
    expect(project.instructions, 'فقط منابع باغبانی.');
    expect(project.collection, 'garden-index');
    expect(project.memoryNotes, isEmpty);
    expect(project.name, 'باغ قدیمی اصلاح‌شده');
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(ConversationWorkspaceNotifier.key);
    await expectLater(
      reopened.saveProject(
        id: project.id,
        name: project.name,
        memoryNotes: List.filled(6100, 'ا').join(),
      ),
      throwsFormatException,
    );
    expect(prefs.getString(ConversationWorkspaceNotifier.key), previous);
  });

  test('unreadable saved project metadata fails closed without overwriting it',
      () async {
    const malformed = '{"projects": broken-json';
    SharedPreferences.setMockInitialValues({
      ConversationWorkspaceNotifier.key: malformed,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final editor = container.read(conversationWorkspaceProvider.notifier);
    await editor.ready;
    expect(container.read(conversationWorkspaceProvider).readable, isFalse);
    await expectLater(
      editor.saveProject(name: 'جدید'),
      throwsStateError,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ConversationWorkspaceNotifier.key), malformed);
  });

  test('approved message memory can be revised and removed per project',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    addTearDown(first.dispose);
    final workspace = first.read(conversationWorkspaceProvider.notifier);
    await workspace.ready;
    await workspace.saveProject(
      name: 'باغبانی',
      memoryNotes: 'یادداشت دستی ثابت.',
    );
    await workspace.saveProject(
      name: 'خانه',
      memoryNotes: 'اطلاعات خانه.',
    );
    final projects = first.read(conversationWorkspaceProvider).projects;
    final gardenId = projects.first.id;
    final homeId = projects.last.id;
    await workspace.assign(['garden-chat'], gardenId);
    await workspace.assign(['home-chat'], homeId);
    final date = DateTime.utc(2026, 11, 18);
    await workspace.rememberChatMessage(
      projectId: gardenId,
      chatId: 'garden-chat',
      messageId: 'first',
      note: 'درخت گردو\nآبیاری قطره‌ای دارد.',
      notedAt: date,
    );
    await workspace.rememberChatMessage(
      projectId: gardenId,
      chatId: 'garden-chat',
      messageId: 'second',
      note: 'درخت سیب داریم.',
      notedAt: date,
    );
    var saved = first.read(conversationWorkspaceProvider).projects.first;
    expect(
      ProjectMemoryEntry.noteFor(
        saved.memoryNotes,
        chatId: 'garden-chat',
        messageId: 'first',
      ),
      'درخت گردو آبیاری قطره‌ای دارد.',
    );
    expect(
      ProjectMemoryEntry.noteFor(
        saved.memoryNotes,
        chatId: 'home-chat',
        messageId: 'first',
      ),
      isNull,
    );
    await workspace.rememberChatMessage(
      projectId: gardenId,
      chatId: 'garden-chat',
      messageId: 'first',
      note: 'درخت گردو آبیاری بارانی دارد.',
      notedAt: date,
    );
    saved = first.read(conversationWorkspaceProvider).projects.first;
    expect(saved.memoryNotes, isNot(contains('آبیاری قطره‌ای')));
    expect(saved.memoryNotes, contains('آبیاری بارانی'));
    expect(saved.memoryNotes, contains('درخت سیب داریم.'));
    expect(saved.memoryNotes.split('پیام: first)').length, 2);
    await expectLater(
      workspace.forgetChatMessage(
        projectId: homeId,
        chatId: 'garden-chat',
        messageId: 'first',
      ),
      throwsStateError,
    );
    await workspace.forgetChatMessage(
      projectId: gardenId,
      chatId: 'garden-chat',
      messageId: 'first',
    );
    final second = ProviderContainer();
    addTearDown(second.dispose);
    final restored = second.read(conversationWorkspaceProvider.notifier);
    await restored.ready;
    final state = second.read(conversationWorkspaceProvider);
    final notes = state.projectFor('garden-chat')!.memoryNotes;
    expect(notes, contains('یادداشت دستی ثابت.'));
    expect(notes, contains('درخت سیب داریم.'));
    expect(notes, isNot(contains('آبیاری بارانی')));
    expect(
      ProjectMemoryEntry.noteFor(
        notes,
        chatId: 'garden-chat',
        messageId: 'first',
      ),
      isNull,
    );
    expect(state.projectFor('home-chat')!.memoryNotes, 'اطلاعات خانه.');
  });

  testWidgets('project tabs isolate drafts and scope the drawer history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('pala-project-tabs-'),
    ))!;
    final previousPaths = PathProviderPlatform.instance;
    final paths = _Paths(dir.path);
    PathProviderPlatform.instance = paths;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026);
    Chat chat(String id, String title) => Chat(
      id: id,
      title: title,
      createdAt: now,
      updatedAt: now,
      pinned: false,
      tags: '[]',
      overridesJson: '{}',
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        llamaEngineProvider.overrideWithValue(TestEngine()),
        settingsProvider.overrideWith(TestSettings.new),
        modelManagerProvider.overrideWith(TestModels.new),
        chatsProvider.overrideWith(
          (_) => Stream.value([
            chat('general-chat', 'گفتگوی عمومی ساختگی'),
            chat('garden-chat', 'گفتگوی باغ ساختگی'),
          ]),
        ),
      ],
    );
    addTearDown(() async {
      if (paths.gate != null && !paths.gate!.isCompleted)
        paths.gate!.complete();
      container.dispose();
      await db.close();
      PathProviderPlatform.instance = previousPaths;
      await dir.delete(recursive: true);
    });
    final workspace = container.read(conversationWorkspaceProvider.notifier);
    await workspace.ready;
    await workspace.saveProject(name: 'باغبانی ساختگی');
    final projectId = container
        .read(conversationWorkspaceProvider)
        .projects
        .single
        .id;
    await tester.runAsync(() async {
      await ChatDraftStore(root: () async => dir).save(
        'new-project-$projectId',
        const ChatDraft(text: 'پیش‌نویس قبلی ساختگی'),
      );
    });
    await workspace.assign(['garden-chat'], projectId);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
          locale: const Locale('fa'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> waitForDraft(String expected) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        final text = tester
            .widget<TextField>(find.byKey(const Key('message-input')))
            .controller!
            .text;
        if (text == expected) return;
      }
      fail('The selected project draft was not restored.');
    }

    await tester.enterText(
      find.byKey(const Key('message-input')),
      'پیش‌نویس عمومی ساختگی',
    );
    paths.gate = Completer<void>();
    await tester.tap(find.byKey(ValueKey('project-tab-$projectId')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('project-tab-general')));
    await tester.pump();
    paths.gate!.complete();
    paths.gate = null;
    await waitForDraft('پیش‌نویس عمومی ساختگی');
    await tester.tap(find.byKey(ValueKey('project-tab-$projectId')));
    await tester.pumpAndSettle();
    await waitForDraft('پیش‌نویس قبلی ساختگی');
    expect(container.read(newChatProjectProvider), projectId);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      'پیش‌نویس قبلی ساختگی',
    );
    await tester.enterText(
      find.byKey(const Key('message-input')),
      'پیش‌نویس باغ ساختگی',
    );
    await tester.tap(find.byKey(const Key('project-tab-general')));
    await tester.pumpAndSettle();
    await waitForDraft('پیش‌نویس عمومی ساختگی');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      'پیش‌نویس عمومی ساختگی',
    );
    await tester.tap(find.byKey(ValueKey('project-tab-$projectId')));
    await tester.pumpAndSettle();
    await waitForDraft('پیش‌نویس باغ ساختگی');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      'پیش‌نویس باغ ساختگی',
    );
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('گفتگوی باغ ساختگی'), findsOneWidget);
    expect(find.text('گفتگوی عمومی ساختگی'), findsNothing);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('گفتگوی باغ ساختگی'))).pop();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('project-tab-$projectId')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
