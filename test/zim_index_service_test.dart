import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_content_index.dart';
import 'package:ondevice_llm/features/zim/zim_index_service.dart';
import 'package:ondevice_llm/features/zim/zim_index_storage.dart';

import 'offline_zim_reliability_test.dart' show FixtureFolder;
import 'support/persian_zim_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('owner-started service stops and resumes only the allowed ZIM', () async {
    final directory = await Directory.systemTemp.createTemp('pala-index-service-');
    addTearDown(() => directory.delete(recursive: true));
    final garden = persianZim(englishGarden: true);
    final medical = persianZim();
    final folder = FixtureFolder({'medical.zim': medical, 'garden.zim': garden});
    final opened = <String>[];
    folder.overrideOpen = (uri) async { opened.add(uri); return folder.files[uri]!.fresh(); };
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final storage = ZimIndexStorage(directory: directory, maxDatabaseBytes: 2 * 1024 * 1024,
      reserveBytes: 1, availableBytes: () async => 16 * 1024 * 1024);
    final service = ZimIndexService(library, storage);
    final stopped = await service.run(uri: 'garden.zim', allowed: () => true,
      entriesPerBatch: 1, onProgress: (_, __, ___) => service.stop());
    expect(stopped.cancelled, isTrue);
    expect(stopped.cursor, greaterThan(0));
    expect(stopped.cursor, lessThan(stopped.total));
    final resumed = await service.run(uri: 'garden.zim', allowed: () => true, entriesPerBatch: 2);
    expect(resumed.cancelled, isFalse);
    expect(resumed.cursor, resumed.total);
    expect(opened, isNotEmpty);
    expect(opened.every((uri) => uri == 'garden.zim'), isTrue);
    final db = sqlite3.open(storage.indexPath);
    final index = ZimContentIndex(db);
    final id = FolderLibrary.sourceId('garden.zim');
    final fingerprint = ZimContentIndex.fingerprint(
      archiveId: '01000000000000000000000000000000', size: garden.size, modified: 1);
    expect(index.search('walnut irrigation', {id: fingerprint}).single.title, 'Plant care');
    db.close();
  });

  test('insufficient headroom prevents opening or creating the index', () async {
    final directory = await Directory.systemTemp.createTemp('pala-index-space-');
    addTearDown(() => directory.delete(recursive: true));
    final folder = FixtureFolder({'garden.zim': persianZim(englishGarden: true)});
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final storage = ZimIndexStorage(directory: directory, maxDatabaseBytes: 100,
      reserveBytes: 100, availableBytes: () async => 0);
    final service = ZimIndexService(library, storage);
    await expectLater(service.run(uri: 'garden.zim', allowed: () => true), throwsStateError);
    expect(folder.opened, isEmpty);
    expect(await File(storage.indexPath).exists(), isFalse);
  });
}
