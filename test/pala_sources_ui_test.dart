import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/zim/knowledge_sources.dart';
import 'package:ondevice_llm/features/zim/zim_tile.dart';

void main() {
  testWidgets('source controls disable and detach one encyclopedia while preserving both originals', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // File reads and decompression isolates must originate in the real async
    // zone. pumpAndSettle alone only advances the widget test's fake clock.
    await tester.runAsync(() async {
      final paths = ['test/fixtures/zim/mini.zim', 'test/fixtures/zim/libzim-modern.zim'];
      await KnowledgeSources.save([for (final p in paths) await KnowledgeSources.inspect(p, 'fixture')]);
      Future<void> finishIO() async {
        for (var i = 0; i < 250; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
        }
        fail('Source inspection did not finish within five seconds of real I/O time');
      }
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ZimTile())))));
      await finishIO();
      expect(find.text('منابع دانش'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      await finishIO();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
      await tester.tap(find.text('جداسازی').first);
      await tester.pump();
      await finishIO();
      expect(find.byType(Switch), findsOneWidget);
      expect((await KnowledgeSources.load()).single.uri, paths.last);
      for (final p in paths) { expect(await File(p).exists(), isTrue); }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
