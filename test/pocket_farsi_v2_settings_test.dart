import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/pocket_farsi_v2_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pocket test controls are hidden until Advanced is expanded',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PocketFarsiExperimentalSettings(),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('pocket-experimental-advanced')), findsOneWidget);
    expect(find.byKey(const Key('pocket-import-zip')), findsNothing);
    await tester.tap(find.text('Pocket Farsi v2 · آزمایشی و پیشرفته'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pocket-import-zip')), findsOneWidget);
    expect(find.byKey(const Key('pocket-inspect')), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byKey(const Key('pocket-test-voice')))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('pocket-conversation-opt-in')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('pocket-conversation-restore')), findsOneWidget);
  });
}
