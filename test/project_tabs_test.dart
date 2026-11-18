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
import 'package:ondevice_llm/features/chat/presentation/providers/chat_provider.dart';
import 'package:ondevice_llm/features/chat/presentation/screens/chat_screen.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/effective_settings_provider.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';

import 'chat_test.dart' show TestEngine, TestModels, TestSettings;

class _Paths extends PathProviderPlatform {
  final String path;
  _Paths(this.path);
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  testWidgets('project tabs isolate drafts and scope the drawer history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('pala-project-tabs-'),
    ))!;
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
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
    await tester.tap(find.byKey(ValueKey('project-tab-$projectId')));
    await tester.pumpAndSettle();
    await waitForDraft('');
    expect(container.read(newChatProjectProvider), projectId);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      isEmpty,
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
  });
}
