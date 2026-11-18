import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_content_index.dart';
import 'package:ondevice_llm/features/zim/zim_index_step.dart';

import 'support/persian_zim_fixture.dart';

void main() {
  test('one-source steps resume and index all sections of an English article', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db);
    final job = ZimIndexStep(index);
    final source = persianZim(englishGarden: true);
    final opened = <SparseZimSource>[];
    var cursor = 0;
    var total = 1;
    while (cursor < total) {
      final result = await job.run(uri: 'garden.zim', size: source.size, modified: 1,
        allowed: () => true, sourceUnchanged: () async => true,
        hasStorageHeadroom: () async => true, limit: 1,
        openSource: (_) async { final fresh = source.fresh(); opened.add(fresh); return fresh; });
      expect(result.cursor, greaterThan(cursor));
      cursor = result.cursor;
      total = result.total;
    }
    expect(opened.every((s) => s.closed), isTrue);
    final id = FolderLibrary.sourceId('garden.zim');
    final fingerprint = ZimContentIndex.fingerprint(
      archiveId: '01000000000000000000000000000000', size: source.size, modified: 1);
    final hits = index.search('walnut irrigation', {id: fingerprint});
    expect(hits.single.title, 'Plant care');
    expect(hits.single.text, contains('walnut'));
    expect(hits.single.text, contains('How can I care'));
    expect(index.progress(id, fingerprint)?.cursor, total);
  });

  test('scope, free space and changed source fail before a batch commits', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db);
    final job = ZimIndexStep(index);
    final source = persianZim(englishGarden: true);
    var opens = 0;
    Future<void> run({required bool Function() allowed,
      required Future<bool> Function() unchanged, required Future<bool> Function() space}) async {
      await job.run(uri: 'garden.zim', size: source.size, modified: 1,
        allowed: allowed, sourceUnchanged: unchanged, hasStorageHeadroom: space,
        openSource: (_) async { opens++; return source.fresh(); });
    }
    await expectLater(run(allowed: () => false, unchanged: () async => true,
      space: () async => true), throwsStateError);
    await expectLater(run(allowed: () => true, unchanged: () async => true,
      space: () async => false), throwsStateError);
    expect(opens, 0);
    var checks = 0;
    await expectLater(run(allowed: () => true, unchanged: () async => ++checks == 1,
      space: () async => true), throwsStateError);
    expect(opens, 1);
    final id = FolderLibrary.sourceId('garden.zim');
    final fingerprint = ZimContentIndex.fingerprint(
      archiveId: '01000000000000000000000000000000', size: source.size, modified: 1);
    expect(index.progress(id, fingerprint), isNull);
  });
}
