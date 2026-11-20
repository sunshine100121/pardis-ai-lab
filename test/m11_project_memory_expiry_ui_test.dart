import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/chat/presentation/widgets/project_memory_expiry.dart';

const originalNotes =
    'یادداشت دستی بدون زمان.\n'
    '• درخت سیب باغ ۵ عدد است. (تأیید مالک؛ تاریخ: 2026-11-18T00:00:00.000Z؛ '
    'گفتگو: garden-chat؛ پیام: first)\n'
    '• گلخانه کاکتوس دارد. (تأیید مالک؛ تاریخ: 2026-11-18T00:00:00.000Z؛ '
    'گفتگو: garden-chat؛ پیام: second)';

void main() {
  test('per-note expiration edits only exact approved line, not manual notes', () {
    final approved = ProjectMemoryEntry.approvedLines(originalNotes);
    expect(approved, hasLength(2));
    expect(ProjectMemoryEntry.contentOf(approved.first), 'درخت سیب باغ ۵ عدد است.');
    final expires = DateTime.utc(2026, 11, 27);
    final changed = ProjectMemoryEntry.changeExpiry(
      originalNotes,
      line: approved.first,
      expiresAt: expires,
    );
    expect(changed, contains('انقضا: 2026-11-27T00:00:00.000Z'));
    expect(changed, contains('یادداشت دستی بدون زمان.'));
    expect(changed, contains(approved.last));
    expect(ProjectMemoryEntry.approvedLines(changed), hasLength(2));
    final updatedFirst = ProjectMemoryEntry.approvedLines(changed).first;
    expect(ProjectMemoryEntry.expiresAtOf(updatedFirst), expires);
    expect(
      ProjectMemoryEntry.activeNotes(changed, now: DateTime.utc(2026, 11, 28)),
      isNot(contains('درخت سیب باغ ۵ عدد است.')),
    );
    expect(
      ProjectMemoryEntry.activeNotes(changed, now: DateTime.utc(2026, 11, 28)),
      contains('گلخانه کاکتوس دارد.'),
    );
    expect(
      ProjectMemoryEntry.changeExpiry(
        changed,
        line: updatedFirst,
        expiresAt: null,
      ),
      originalNotes,
    );
    expect(
      () => ProjectMemoryEntry.changeExpiry(
        originalNotes,
        line: 'یادداشت دستی بدون زمان.',
        expiresAt: expires,
      ),
      throwsFormatException,
    );
  });

  testWidgets('one popup sets and clears expiry without editing other notes',
      (tester) async {
    final controller = TextEditingController(text: originalNotes);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectMemoryExpiryEditor(notes: controller),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('project-memory-expiry-menu-0')), findsOneWidget);
    expect(find.byKey(const Key('project-memory-expiry-menu-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('project-memory-expiry-menu-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('۷ روز').last);
    await tester.pumpAndSettle();
    expect(controller.text, contains('؛ انقضا: '));
    expect(controller.text, contains('یادداشت دستی بدون زمان.'));
    expect(controller.text, contains(ProjectMemoryEntry.approvedLines(originalNotes).last));
    final first = ProjectMemoryEntry.approvedLines(controller.text).first;
    expect(ProjectMemoryEntry.expiresAtOf(first), isNotNull);
    await tester.tap(find.byKey(const Key('project-memory-expiry-menu-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تا حذف دستی').last);
    await tester.pumpAndSettle();
    expect(controller.text, originalNotes);
    expect(tester.takeException(), isNull);
  });
}
