import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/settings/presentation/screens/folder_knowledge_page.dart';
import 'offline_folder_library_test.dart' show TestFolder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Persian folder actions, persisted toggle and URI only under Advanced',(tester) async {
    SharedPreferences.setMockInitialValues({});
    final access=TestFolder()..add('notes.txt',Uint8List.fromList(utf8.encode('Orchid nutrient concentration is 42.')));
    final library=FolderLibrary(access:access);
    await library.refresh(pick:true);
    await tester.pumpWidget(ProviderScope(overrides:[folderLibraryProvider.overrideWithValue(library)],
      child:const MaterialApp(home:FolderKnowledgePage())));
    await tester.pumpAndSettle();
    expect(find.text('پوشه دانش'),findsOneWidget);
    expect(find.text('بازخوانی منابع'),findsOneWidget);
    expect(find.text('notes.txt'),findsOneWidget);
    expect(find.text('content://test/tree/knowledge'),findsNothing);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect((await library.state())['files'][0]['enabled'],false);
    expect(access.picks,1);
  });
}
