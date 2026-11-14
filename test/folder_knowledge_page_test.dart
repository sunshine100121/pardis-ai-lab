import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/settings/presentation/screens/folder_knowledge_page.dart';
import 'package:ondevice_llm/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:ondevice_llm/l10n/app_localizations.dart';
import 'offline_folder_library_test.dart' show TestFolder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local citation opens its evidence without a technical URL or browser action',(tester) async {
    await tester.pumpWidget(MaterialApp(locale:const Locale('fa'),
      localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:Builder(builder:(context)=>Scaffold(body:TextButton(onPressed:()=>showSourceSheet(context,{
        'title':'small.pdf · صفحه 2','url':'pala-knowledge://opaque-file-id','retrievalStatus':'page_read',
        'excerpt':'Orchid concentration: 42 ppm.','number':1,'fetchedAt':'2026-11-14T10:00:00Z',
      }),child:const Text('منبع'))))));
    await tester.tap(find.text('منبع'));
    await tester.pumpAndSettle();
    expect(find.text('Orchid concentration: 42 ppm.'),findsOneWidget);
    expect(find.text('opaque-file-id'),findsNothing);
    expect(find.byIcon(Icons.open_in_new),findsNothing);
  });
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
