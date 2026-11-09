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
    final paths = ['test/fixtures/zim/mini.zim', 'test/fixtures/zim/libzim-modern.zim'];
    await tester.runAsync(() async {
      await KnowledgeSources.save([for (final p in paths) await KnowledgeSources.inspect(p, 'fixture')]);
    });
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ZimTile())))));
    Future<void> finish() async {
      for (var i = 0; i < 30 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }
    await finish();
    expect(find.text('منابع دانش'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await finish();
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    await tester.tap(find.text('جداسازی').first);
    await tester.pump();
    await finish();
    expect(find.byType(Switch), findsOneWidget);
    await tester.runAsync(() async {
      expect((await KnowledgeSources.load()).single.uri, paths.last);
      for (final p in paths) { expect(await File(p).exists(), isTrue); }
    });
    expect(tester.takeException(), isNull);
  });
}
