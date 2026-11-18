import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';

import 'support/persian_zim_fixture.dart';

class FixtureFolder implements FolderAccess {
  final Map<String, SparseZimSource> files;
  final List<ZimSource> opened = [];
  bool revoked = false;
  Future<ZimSource> Function(String)? overrideOpen;
  FixtureFolder(this.files);
  @override
  Future<bool> pick() async => true;
  @override
  Future<({String? tree, List<LibraryFile> files})> list() async {
    if (revoked) throw StateError('revoked');
    return (
      tree: 'content://fixture/tree/knowledge',
      files: [
        for (final e in files.entries)
          (uri: e.key, name: e.key, size: e.value.size, modified: 1),
      ],
    );
  }

  @override
  Future<ZimSource> open(String uri) async {
    final source =
        await (overrideOpen?.call(uri) ?? Future.value(files[uri]!.fresh()));
    opened.add(source);
    return source;
  }
}

class DelayedSource implements ZimSource {
  final SparseZimSource source;
  final gate = Completer<void>(), released = Completer<void>();
  DelayedSource(this.source);
  @override
  Future<int> length() => source.length();
  @override
  Future<Uint8List> readAt(int offset, int count) async {
    await gate.future;
    return source.readAt(offset, count);
  }

  @override
  Future<void> close() async {
    await source.close();
    released.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Persian subject and source instructions prioritize actual article names',
    () {
      expect(ZimWikipedia.candidates('بهبهان کجاست؟').first, 'بهبهان');
      expect(
        ZimWikipedia.candidates('با استناد به ویکی‌پدیا دربارهٔ مريخ توضیح بده')
            .first,
        'مریخ',
      );
      expect(
        ZimWikipedia.requiresEncyclopedia('طبق ویکی‌پدیا بهبهان کجاست؟'),
        true,
      );
      expect(
        ZimWikipedia.requiresEncyclopedia('از دانشنامه درباره مریخ بگو'),
        true,
      );
      expect(ZimWikipedia.requiresEncyclopedia('بهبهان کجاست'), false);
    },
  );
  test(
    'ninth active archive is searched and its article can be reopened',
    () async {
      final access = FixtureFolder({
        for (var i = 0; i < 8; i++) 'short-$i.zim': persianZim(shortText: true),
        'ninth.zim': persianZim(large: true, archive: 'دانشنامهٔ نهم آزمون'),
      });
      final library = FolderLibrary(access: access);
      await library.refresh();
      final result = await library.searchDetailed('بهبهان کجاست');
      expect(result.checks, hasLength(9));
      expect(result.checks.last['code'], 'found');
      expect(access.opened, hasLength(9));
      expect(
        access.opened.every((source) => (source as SparseZimSource).closed),
        isTrue,
      );
      final citation = result.sources.single;
      expect(citation.source, 'دانشنامهٔ نهم آزمون');
      final article = await library.article(
        citation.url,
        citation.archiveId!,
        citation.archiveDate,
      );
      expect(article?.pageText, contains('خوزستان'));
    },
  );
  for (final question in [
    'مریخ',
    'بهبهان',
    'بهبهان کجاست',
    'طبق ویکی‌پدیا بهبهان کجاست؟',
  ]) {
    test('real Persian ZIM retrieval: $question', () async {
      final source = persianZim();
      final wiki = ZimWikipedia('fixture', openSource: (_) async => source);
      try {
        final result = await wiki.lookup(question);
        expect(result, isNotNull);
        expect(result!.source, 'دانشنامهٔ فارسی آزمون');
        expect(
          result.title,
          contains(question == 'مریخ' ? 'بهرام (سیاره)' : 'بهبهان'),
        );
        expect(result.pageText, isNot(contains('<p>')));
        expect(result.url, startsWith('zim://${result.archiveId}/'));
      } finally {
        await wiki.close();
      }
      expect(source.closed, true);
    });
  }
  test(
    'large stored cluster and >4 GiB offsets need only bounded random reads',
    () async {
      final source = persianZim(large: true);
      final wiki = ZimWikipedia(
        'virtual-large.zim',
        openSource: (_) async => source,
      );
      try {
        expect((await wiki.lookup('مریخ'))!.pageText, contains('چهارمین'));
        expect(
          (await wiki.lookup('بهبهان کجاست'))!.pageText,
          contains('خوزستان'),
        );
        expect(source.highestOffset, greaterThan(1 << 32));
        expect(source.maxRead, lessThanOrEqualTo(4096));
        expect(source.bytesRead, lessThan(64 * 1024));
      } finally {
        await wiki.close();
      }
    },
  );
  test(
    'failed archive stays visible without hiding a successful encyclopedia',
    () async {
      final folder = FixtureFolder({
        'broken.zim': persianZim(),
        'valid.zim': persianZim(),
      });
      folder.overrideOpen = (uri) async {
        final source = folder.files[uri]!.fresh();
        if (uri == 'broken.zim') source.pieces[0] = Uint8List(80);
        return source;
      };
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final report = await library.searchDetailed('بهبهان کجاست');
      expect(report.sources, hasLength(1));
      expect(report.checks.map((c) => c['code']), ['format', 'found']);
      expect(
        (await SharedPreferences.getInstance()).getString(
          FolderLibrary.diagnosticsKey,
        ),
        contains('format'),
      );
      expect(report.sources.every((s) => s.url.startsWith('zim://')), true);
    },
  );
  test('timeout reports the actual stage and releases late I/O without waiting in UI', () async {
    final folder = FixtureFolder({'slow.zim': persianZim()});
    final slow = DelayedSource(persianZim());
    folder.overrideOpen = (_) async => slow;
    final library = FolderLibrary(
      access: folder,
      lookupTimeout: const Duration(milliseconds: 20),
    );
    await library.refresh();
    final report = await library.searchDetailed('مریخ');
    expect(report.sources, isEmpty);
    expect(report.checks.single['code'], 'timeout');
    expect(report.checks.single['stage'], 'open');
    final snapshot = jsonEncode(report.checks);
    slow.gate.complete();
    await slow.released.future.timeout(const Duration(seconds: 1));
    expect(slow.source.closed, true);
    expect(jsonEncode(report.checks), snapshot);
  });
  test(
    'not-found, revoked access, persistence and disabled sources are distinct',
    () async {
      final folder = FixtureFolder({'fa.zim': persianZim()});
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final absent = await library.searchDetailed('عنوان ساختگی ناموجود');
      expect(absent.sources, isEmpty);
      expect(absent.checks.single['code'], 'not_found');
      final persisted = (await SharedPreferences.getInstance()).getString(
        FolderLibrary.diagnosticsKey,
      )!;
      expect(persisted, isNot(contains('عنوان ساختگی ناموجود')));
      expect(persisted, isNot(contains('content://')));
      await library.setEnabled('fa.zim', false);
      expect((await library.searchDetailed('مریخ')).checks, isEmpty);
      folder.revoked = true;
      await expectLater(library.searchDetailed('مریخ'), throwsStateError);
    },
  );
  test(
    'matched title with unusable text is reported without a citation',
    () async {
      final folder = FixtureFolder({'short.zim': persianZim(shortText: true)});
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final report = await library.searchDetailed('مریخ');
      expect(report.sources, isEmpty);
      expect(report.checks.single['code'], 'text_unusable');
    },
  );
}
