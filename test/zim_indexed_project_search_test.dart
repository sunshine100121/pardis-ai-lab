import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/settings/domain/entities/inference_settings.dart';
import 'package:ondevice_llm/features/tools/domain/tool_spec.dart';
import 'package:ondevice_llm/features/zim/zim_index_service.dart';
import 'package:ondevice_llm/features/zim/zim_index_storage.dart';
import 'package:ondevice_llm/features/zim/zim_indexed_project_search.dart';

import 'offline_zim_reliability_test.dart' show FixtureFolder;
import 'support/persian_zim_fixture.dart';
import 'zim_query_translation_test.dart' show FakeLocalQueryEngine;

class RevokingEngine extends FakeLocalQueryEngine {
  final void Function() revoke;
  RevokingEngine(this.revoke) : super(const []);
  @override
  Stream<String> generate({required List<Map<String, Object>> messages,
    required String fallbackTemplate, required InferenceSettings settings,
    String assistantPrefix = '', List<ToolSpec> tools = const [],
    String toolChoice = 'auto'}) async* {
    revoke();
    yield 'walnut watering';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('project search translates and cites an indexed English article without opening medical source', () async {
    final dir = await Directory.systemTemp.createTemp('pala-project-search-');
    addTearDown(() => dir.delete(recursive: true));
    final garden = persianZim(englishGarden: true, duplicateGardenTitle: true, archive: 'Gardening fixture');
    final medical = persianZim(englishGarden: true, archive: 'Medical fixture');
    final folder = FixtureFolder({'medical.zim': medical, 'garden.zim': garden});
    final opened = <String>[];
    folder.overrideOpen = (uri) async { opened.add(uri); return folder.files[uri]!.fresh(); };
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final storage = ZimIndexStorage(directory: dir, maxDatabaseBytes: 2 * 1024 * 1024,
      reserveBytes: 1, availableBytes: () async => 16 * 1024 * 1024);
    final service = ZimIndexService(library, storage);
    await service.run(uri: 'garden.zim', allowed: () => true);
    await service.run(uri: 'medical.zim', allowed: () => true);
    opened.clear();
    final id = FolderLibrary.sourceId('garden.zim');
    final engine = FakeLocalQueryEngine(['walnut tree watering irrigation']);
    var allowed = true;
    final search = ZimIndexedProjectSearch(library, storage);
    final result = await search.search(question: 'آبیاری درخت گردو', sourceIds: {id},
      allowed: (source) => allowed && source == id, cancelled: () => false,
      engine: engine, settings: const InferenceSettings(), fallbackTemplate: '');
    expect(opened, ['garden.zim']);
    expect(result.sources.single.source, 'Gardening fixture');
    expect(result.sources.single.title, 'Plant care — Gardening fixture');
    expect(result.sources.single.pageText, contains('walnut'));
    expect(result.sources.single.url, 'zim://01000000000000000000000000000000/Plant_care?entry=0');
    final reopened = await library.article(result.sources.single.url,
      result.sources.single.archiveId!, result.sources.single.archiveDate,
      allowSource: (uri) => uri == 'garden.zim');
    expect(reopened?.pageText, contains('walnut'));
    final other = await library.article(result.sources.single.url.replaceFirst('entry=0', 'entry=1'),
      result.sources.single.archiveId!, result.sources.single.archiveDate,
      allowSource: (uri) => uri == 'garden.zim');
    expect(other?.pageText, contains('مریخ'));
    expect(other?.pageText, isNot(contains('walnut')));
    expect(opened.every((uri) => uri == 'garden.zim'), isTrue);
    expect(result.incomplete, 0);
    opened.clear();
    final revoked = await search.search(question: 'آبیاری درخت گردو', sourceIds: {id},
      allowed: (source) => allowed && source == id, cancelled: () => false,
      engine: RevokingEngine(() => allowed = false), settings: const InferenceSettings(), fallbackTemplate: '');
    expect(revoked.sources, isEmpty);
    expect(opened, ['garden.zim']);
  });
}
