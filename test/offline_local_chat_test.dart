import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/core/providers/shared_providers.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/data/network/web_search/search_models.dart';
import 'package:ondevice_llm/features/knowledge/offline_knowledge.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/chat/presentation/providers/chat_provider.dart';
import 'package:ondevice_llm/features/models/presentation/providers/model_manager_provider.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'chat_test.dart' show TestEngine,TestSettings,TestModels;

class EvidenceForLocal extends OfflineKnowledge {
  EvidenceForLocal():super(FolderLibrary());
  @override
  Future<List<SearchResult>> search(String question) async=>[
    SearchResult(title:'small.pdf · صفحه 2',url:'pala-knowledge://fixture',snippet:'',source:'AI Knowledge',rank:1,
      pageText:'Orchid nutrient concentration is 42 ppm according to this laboratory report.',fetchedAt:DateTime.utc(2026,11,14))];
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('folder evidence reaches the existing local Qwen conversation input',() async {
    SharedPreferences.setMockInitialValues({});
    final db=AppDatabase.forTesting(NativeDatabase.memory());
    final engine=TestEngine();
    final container=ProviderContainer(overrides:[
      appDatabaseProvider.overrideWithValue(db),llamaEngineProvider.overrideWithValue(engine),
      settingsProvider.overrideWith(TestSettings.new),modelManagerProvider.overrideWith(TestModels.new),
      offlineKnowledgeProvider.overrideWithValue(EvidenceForLocal()),
    ]);
    addTearDown(() async {container.dispose(); await db.close();});
    await container.read(chatProvider.notifier).send('What is the orchid nutrient concentration?');
    final prompt=engine.receivedMessages.toString();
    expect(prompt,contains('42 ppm'));
    expect(prompt,contains('small.pdf'));
  });
}
