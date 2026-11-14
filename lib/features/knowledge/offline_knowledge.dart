import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/network/web_search/search_models.dart';
import 'folder_library.dart';
import 'ha_read_client.dart';

class OfflineKnowledge {
  static const configKey='pala_ha_read_config_v1';
  static const tokenKey='pala_ha_read_token_v1';
  static const secure=FlutterSecureStorage();
  final FolderLibrary library;
  OfflineKnowledge(this.library);
  Future<List<SearchResult>> search(String question) async {
    final sources=<SearchResult>[];
    try { sources.addAll(await library.search(question)); }
    catch(_) { sources.add(_failure('پوشه دانش','منابع محلی در دسترس نیستند؛ مجوز یا بازخوانی پوشه را بررسی کنید.')); }
    final raw=(await SharedPreferences.getInstance()).getString(configKey);
    if(raw==null) return sources;
    final config=jsonDecode(raw) as Map<String,dynamic>;
    if(config['enabled']!=true) return sources;
    final allowed=Map<String,dynamic>.from(config['entities'] as Map);
    final normalized=FolderLibrary.normalize(question);
    final matches=allowed.entries.where((e)=>normalized.contains(FolderLibrary.normalize(e.value as String))).toList();
    if(matches.isEmpty) return sources;
    if(matches.length>1) { sources.add(_failure('Home Assistant','پرسش چند حسگر دارد؛ برای جلوگیری از حدس، نام یک حسگر مجاز را بپرسید.')); return sources; }
    final selected=matches.single;
    try {
      final token=await secure.read(key:tokenKey);
      if(token==null) throw StateError('missing credential');
      final client=HaReadClient(base:Uri.parse(config['base'] as String),token:token,entities:allowed.keys.toSet());
      final end=DateTime.now().toUtc();
      // Explicit fixed one-hour MVP window; never infer arbitrary dates.
      final history=normalized.contains('تاریخچه');
      final data=history ? await client.history(selected.key,end.subtract(const Duration(hours:1)),end) : await client.state(selected.key);
      sources.add(HaReadClient.evidence(selected.value as String,data));
    } catch(_) { sources.add(_failure('Home Assistant','داده واقعی دریافت نشد؛ اتصال یا مجوز را بررسی کنید. مقدار را حدس نزنید.')); }
    return sources;
  }
  static SearchResult _failure(String title,String text) => SearchResult(title:title,url:'pala-status://unavailable',snippet:'',
    source:'وضعیت خواندن',rank:0,pageText:text,fetchedAt:DateTime.now().toUtc());
}
final offlineKnowledgeProvider=Provider<OfflineKnowledge>((ref)=>OfflineKnowledge(ref.read(folderLibraryProvider)));
