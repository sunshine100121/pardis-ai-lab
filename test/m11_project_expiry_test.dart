import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('project memory expiry is not a deletion of source history', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    addTearDown(first.dispose);
    final work = first.read(conversationWorkspaceProvider.notifier);
    await work.ready;
    await work.saveProject(name: 'باغ', memoryNotes: 'متن دستی بدون انقضا');
    await work.saveProject(name: 'آشپزخانه');
    final ids = first.read(conversationWorkspaceProvider).projects;
    await work.assign(['garden-chat'], ids.first.id);
    await work.rememberChatMessage(
      projectId: ids.first.id,
      chatId: 'garden-chat',
      messageId: 'old',
      note: 'درخت گردو آبیاری قطره‌ای دارد.',
      notedAt: DateTime.utc(2026, 11, 10),
      expiresAt: DateTime.utc(2026, 11, 15),
    );
    await work.rememberChatMessage(
      projectId: ids.first.id,
      chatId: 'garden-chat',
      messageId: 'live',
      note: 'درخت سیب آبیاری منظم دارد.',
      notedAt: DateTime.utc(2026, 11, 19),
      expiresAt: DateTime.utc(2026, 12, 20),
    );

    final gardenNotes = first.read(conversationWorkspaceProvider)
        .projectFor('garden-chat')!.memoryNotes;
    final today = DateTime.utc(2026, 11, 20);
    final visible = ProjectMemoryEntry.activeNotes(gardenNotes, now: today);
    expect(visible, contains('متن دستی بدون انقضا'));
    expect(visible, contains('درخت سیب'));
    expect(visible, isNot(contains('درخت گردو')));
    expect(
      ProjectMemoryEntry.noteFor(
        gardenNotes, chatId: 'garden-chat', messageId: 'old',
      ),
      'درخت گردو آبیاری قطره‌ای دارد.',
    );

    final second = ProviderContainer();
    addTearDown(second.dispose);
    final notifier = second.read(conversationWorkspaceProvider.notifier);
    await notifier.ready;
    final restored = second.read(conversationWorkspaceProvider).projects;
    expect(restored.last.memoryNotes, isEmpty);
    expect(
      ProjectMemoryEntry.activeNotes(restored.first.memoryNotes, now: today),
      isNot(contains('درخت گردو')),
    );
    expect(
      ProjectMemoryGate.relevant(
        'چه اطلاعاتی از باغ من ثبت کردی؟',
        ProjectMemoryEntry.activeNotes(restored.first.memoryNotes, now: today),
      ),
      isTrue,
    );
    await notifier.forgetChatMessage(
      projectId: ids.first.id,
      chatId: 'garden-chat',
      messageId: 'old',
    );
    expect(
      second.read(conversationWorkspaceProvider).projects.first.memoryNotes,
      isNot(contains('درخت گردو')),
    );
  });

  test('invalid expiry fails closed; legacy notes remain', () {
    const notes =
        '• درخت گردو بزرگ است (تأیید مالک؛ تاریخ: 2026-11-01؛ '
        'انقضا: broken؛ گفتگو: chat; پیام: one)\n'
        'درخت سیب زنده است.';
    final visible = ProjectMemoryEntry.activeNotes(notes);
    expect(visible, isNot(contains('درخت گردو')));
    expect(visible, contains('درخت سیب'));
  });
}
