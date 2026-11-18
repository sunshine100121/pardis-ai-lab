import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ondevice_llm/features/zim/zim_content_batches.dart';
import 'package:ondevice_llm/features/zim/zim_content_index.dart';

import 'support/persian_zim_fixture.dart';

void main() {
  const garden =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const medical =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const fingerprint =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const changed =
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
  test(
    'batches index a relevant English body whose title is unrelated',
    () async {
      final source = persianZim(englishGarden: true);
      final reader = await ZimContentBatches.open(
        'garden',
        allowed: () => true,
        openSource: (_) async => source,
      );
      addTearDown(reader.close);
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final index = ZimContentIndex(db);
      var cursor = 0;
      while (cursor < reader.archive.entryCount) {
        final batch = await reader.read(cursor: cursor, limit: 2);
        index.commit(
          sourceId: garden,
          fingerprint: fingerprint,
          expectedCursor: cursor,
          batch: batch,
          allowed: () => true,
        );
        cursor = batch.next;
      }
      final results = index.search('walnut watering', {garden: fingerprint});
      expect(results.single.title, 'Plant care');
      expect(results.single.text, contains('walnut'));
      expect(
        index.progress(garden, fingerprint)?.cursor,
        reader.archive.entryCount,
      );
    },
  );
  test('index commits cursor atomically, persists and filters sources before search', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pala-zim-index-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.sqlite');
    var db = sqlite3.open(file.path);
    var index = ZimContentIndex(db);
    const gardenBatch = ZimContentBatch(
      [
        (
          entry: 0,
          title: 'Plant care',
          text: 'Deep watering helps a walnut tree in dry weather.',
        ),
      ],
      1,
      3,
      0,
      false,
    );
    index.commit(
      sourceId: garden,
      fingerprint: fingerprint,
      expectedCursor: 0,
      batch: gardenBatch,
      allowed: () => true,
    );
    expect(
      () => index.commit(
        sourceId: garden,
        fingerprint: fingerprint,
        expectedCursor: 0,
        batch: gardenBatch,
        allowed: () => true,
      ),
      throwsStateError,
    );
    db.close();
    db = sqlite3.open(file.path);
    index = ZimContentIndex(db);
    expect(index.progress(garden, fingerprint)?.cursor, 1);
    const medicalBatch = ZimContentBatch(
      [
        (
          entry: 0,
          title: 'Clinical note',
          text: 'A walnut allergy needs clinical advice.',
        ),
      ],
      1,
      1,
      0,
      false,
    );
    index.commit(
      sourceId: medical,
      fingerprint: fingerprint,
      expectedCursor: 0,
      batch: medicalBatch,
      allowed: () => true,
    );
    final hits = index.search('walnut watering', {garden: fingerprint});
    expect(hits, hasLength(1));
    expect(hits.single.title, 'Plant care');
    expect(hits.single.text, contains('walnut'));
    expect(hits.single.sourceId, garden);
    // An unavailable unselected index must not even be consulted.
    db.execute('DROP TABLE zim_fts_$medical');
    expect(
      index.search('walnut', {garden: fingerprint}).single.sourceId,
      garden,
    );
    expect(index.search('walnut', {}), isEmpty);
    expect(() => index.search('walnut', {garden: changed}), throwsStateError);
    expect(index.progress(garden, fingerprint)?.cursor, 1);
    expect(
      () => index.commit(
        sourceId: garden,
        fingerprint: fingerprint,
        expectedCursor: 1,
        batch: const ZimContentBatch([], 2, 3, 0, false),
        allowed: () => false,
      ),
      throwsStateError,
    );
    expect(index.progress(garden, fingerprint)?.cursor, 1);
    db.close();
    print(
      'synthetic SQLite index size: ${await file.length()} bytes; excludes source archive and is not a device estimate',
    );
  });

  test('logical quota failure leaves the index and cursor unchanged', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db, maxTextBytes: 8);
    expect(
      () => index.commit(
        sourceId: garden,
        fingerprint: fingerprint,
        expectedCursor: 0,
        batch: const ZimContentBatch(
          [(entry: 0, title: 'Long title', text: 'Long text')],
          1,
          1,
          0,
          false,
        ),
        allowed: () => true,
      ),
      throwsStateError,
    );
    expect(index.progress(garden, fingerprint), isNull);
    expect(index.search('long', {garden: fingerprint}), isEmpty);
  });

  test('database page quota refuses an oversized batch atomically', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = ZimContentIndex(db, maxDatabaseBytes: 64 * 1024);
    final text = List.filled(80 * 1024, 'x').join();
    expect(
      () => index.commit(
        sourceId: garden,
        fingerprint: fingerprint,
        expectedCursor: 0,
        batch: ZimContentBatch(
          [(entry: 0, title: 'test', text: text)],
          1,
          1,
          0,
          false,
        ),
        allowed: () => true,
      ),
      throwsStateError,
    );
    expect(index.progress(garden, fingerprint), isNull);
  });
}
