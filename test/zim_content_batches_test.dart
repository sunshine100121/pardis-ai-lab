import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/zim/zim_archive.dart';
import 'package:ondevice_llm/features/zim/zim_content_batches.dart';

import 'support/persian_zim_fixture.dart';

void main() {
  test(
    'embedded index detection reports presence, not search support',
    () async {
      for (final exists in [false, true]) {
        final source = persianZim(embeddedIndex: exists);
        final archive = await ZimArchive.open(
          'fixture',
          openSource: (_) async => source,
        );
        expect(await archive.hasEmbeddedFullTextIndex(), exists);
        await archive.close();
        expect(source.closed, isTrue);
      }
    },
  );

  test('bounded batches resume and read body independently of title', () async {
    final source = persianZim(englishGarden: true);
    var allowed = true;
    final reader = await ZimContentBatches.open(
      'garden',
      allowed: () => allowed,
      openSource: (_) async => source,
    );
    addTearDown(reader.close);
    final rssBefore = ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    var cursor = 0;
    final results = <({int entry, String title, String text})>[];
    while (cursor < reader.archive.entryCount) {
      final batch = await reader.read(cursor: cursor, limit: 2);
      expect(batch.next, greaterThan(cursor));
      expect(batch.skipped, 0);
      results.addAll(batch.articles);
      cursor = batch.next;
    }
    watch.stop();
    print(
      'synthetic batch scan: ${watch.elapsedMilliseconds} ms, ${source.bytesRead} bytes read, RSS before $rssBefore and after ${ProcessInfo.currentRss} bytes; not a device peak',
    );
    final article = results.singleWhere((a) => a.title == 'Plant care');
    expect(article.title.toLowerCase(), isNot(contains('walnut')));
    expect(article.text.toLowerCase(), contains('walnut'));
    expect(article.text.toLowerCase(), contains('watering'));
    expect(article.text.toLowerCase(), contains('how can i care'));
    final paused = await reader.read(cursor: 0, cancelled: () => true);
    expect(paused.cancelled, isTrue);
    expect(paused.next, 0);
    allowed = false;
    await expectLater(reader.read(cursor: 0), throwsStateError);
  });

  test('an unapproved source is not opened', () async {
    var opens = 0;
    await expectLater(
      ZimContentBatches.open(
        'medical',
        allowed: () => false,
        openSource: (_) async {
          opens++;
          return persianZim();
        },
      ),
      throwsStateError,
    );
    expect(opens, 0);
  });
}
