import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/core/platform/desktop_host.dart';
import 'package:ondevice_llm/data/local/database/app_database.dart';
import 'package:ondevice_llm/data/storage/model_storage.dart';
import 'package:ondevice_llm/features/settings/data/remote_key_store.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/settings/presentation/providers/settings_provider.dart';
import 'local_backup_service_test.dart' show BackupPaths;

class RetainedKeys implements RemoteKeyStore {
  int writes=0,deletes=0;
  @override
  Future<Map<String,String>> readAll() async=>{'retained-profile':'synthetic-key-not-exported'};
  @override
  Future<void> write(String id,String value) async { writes++; }
  @override
  Future<void> delete(String id) async { deletes++; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('v16 data, existing model path/bytes and owner settings survive an upgrade-style reopen',() async {
    final root=await Directory.systemTemp.createTemp('pala-in-place-upgrade-');
    final previous=PathProviderPlatform.instance;
    PathProviderPlatform.instance=BackupPaths(root.path,root.path);
    DesktopHost.active=false;
    addTearDown(() async { PathProviderPlatform.instance=previous; await root.delete(recursive:true); });
    final settings=const InferenceSettings(localeCode:'fa',remoteEnabled:false,temperature:0.42,contextSize:4096,
      systemPrompt:'متن ساختگی آزمون؛ داده واقعی مالک نیست.');
    final saved=jsonEncode(settings.toJson());
    SharedPreferences.setMockInitialValues({'inference_settings_v1':saved,
      'thinking_off_2026_09_28':true,'sampling_defaults_2026_10_04':true,
      'retained_unknown_preference':'must-survive'});
    final model=await ModelStorage.modelFile('qwen3.5-4b-Q4_K_M.gguf');
    final fixture=List<int>.generate(4096,(i)=>i%256);
    await model.writeAsBytes(fixture,flush:true);
    final hash=sha256.convert(await model.readAsBytes()).toString();
    final modified=(await model.stat()).modified;
    final database=File('${root.path}/data.sqlite');
    var db=AppDatabase.forTesting(NativeDatabase(database));
    await db.customStatement('INSERT INTO models (id,display_name,file_name,size_bytes,family,quantization,is_downloaded,local_path) VALUES (?,?,?,?,?,?,?,?)',
      ['owner-qwen','Existing Qwen','qwen3.5-4b-Q4_K_M.gguf',fixture.length,'qwen','q4_k_m',1,model.path]);
    await db.customStatement('INSERT INTO chats (id,title,model_id,created_at,updated_at) VALUES (?,?,?,?,?)',
      ['retained-chat','Existing conversation','owner-qwen',1000,1000]);
    await db.customStatement('INSERT INTO messages (id,chat_id,role,content,timestamp,sequence) VALUES (?,?,?,?,?,?)',
      ['retained-message','retained-chat','user','Synthetic retained content',1000,1]);
    Future<List<Map<String,dynamic>>> rows(String table) async=>[
      for(final r in await db.customSelect('SELECT * FROM $table ORDER BY id').get()) r.data];
    final before={for(final table in ['models','chats','messages']) table:await rows(table)};
    expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'),16);
    await db.close();
    db=AppDatabase.forTesting(NativeDatabase(database));
    addTearDown(db.close);
    for(final table in before.keys) { expect(await rows(table),before[table]); }
    expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'),16);
    final keys=RetainedKeys();
    final container=ProviderContainer(overrides:[remoteKeyStoreProvider.overrideWithValue(keys)]);
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ready;
    final loaded=container.read(settingsProvider);
    expect(loaded.localeCode,'fa'); expect(loaded.temperature,0.42); expect(loaded.contextSize,4096);
    expect(loaded.systemPrompt,settings.systemPrompt);
    expect(loaded.remoteApiKeys['retained-profile'],'synthetic-key-not-exported');
    expect(keys.writes,0); expect(keys.deletes,0);
    final prefs=await SharedPreferences.getInstance();
    expect(prefs.getString('inference_settings_v1'),saved);
    expect(prefs.getString('retained_unknown_preference'),'must-survive');
    expect((await ModelStorage.modelFile(model.uri.pathSegments.last)).path,model.path);
    expect(sha256.convert(await model.readAsBytes()).toString(),hash);
    expect((await model.stat()).modified,modified);
    expect(await (await ModelStorage.modelsDir()).list().length,1);
  });
}
