import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/chat/domain/conversation_workspace.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';

import 'support/persian_zim_fixture.dart';

class FixtureFolder implements FolderAccess {
  final Map<String, SparseZimSource> files;
  final List<ZimSource> opened = [];
  int listCalls = 0;
  bool revoked = false;
  Future<ZimSource> Function(String)? overrideOpen;
  FixtureFolder(this.files);
  @override
  Future<bool> pick() async => true;
  @override
  Future<({String? tree, List<LibraryFile> files})> list() async {
    listCalls++;
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
  test('unreadable project metadata is not overwritten', () async {
    SharedPreferences.setMockInitialValues({
      ConversationWorkspaceNotifier.key: '{invalid',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final workspace = container.read(conversationWorkspaceProvider.notifier);
    await workspace.ready;
    expect(container.read(conversationWorkspaceProvider).readable, isFalse);
    await expectLater(workspace.saveProject(name: 'ساختگی'), throwsStateError);
    expect(
      (await SharedPreferences.getInstance()).getString(
        ConversationWorkspaceNotifier.key,
      ),
      '{invalid',
    );
  });
  test(
    'project selection is persistent and filters before opening sources',
    () async {
      final folder = FixtureFolder({
        'garden.zim': persianZim(archive: 'منبع باغبانی آزمون'),
        'medical.zim': persianZim(archive: 'منبع پزشکی آزمون'),
      });
      final opened = <String>[];
      folder.overrideOpen = (uri) async {
        opened.add(uri);
        return folder.files[uri]!.fresh();
      };
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final gardenId = FolderLibrary.sourceId('garden.zim');
      final first = ProviderContainer();
      await first.read(conversationWorkspaceProvider.notifier).ready;
      await first
          .read(conversationWorkspaceProvider.notifier)
          .saveProject(name: 'پروژه ساختگی', sourceIds: [gardenId]);
      final id = first.read(conversationWorkspaceProvider).projects.single.id;
      first.dispose();
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      await reopened.read(conversationWorkspaceProvider.notifier).ready;
      final project = reopened
          .read(conversationWorkspaceProvider)
          .projects
          .single;
      expect(project.sourceIds, [gardenId]);
      final report = await library.searchDetailed(
        'مریخ',
        sourceIds: project.sourceIds.toSet(),
      );
      expect(opened, ['garden.zim']);
      expect(report.sources.single.source, 'منبع باغبانی آزمون');
      await reopened
          .read(conversationWorkspaceProvider.notifier)
          .saveProject(id: id, name: 'نام تازه');
      expect(
        reopened.read(conversationWorkspaceProvider).projects.single.sourceIds,
        [gardenId],
      );
      opened.clear();
      final before = folder.listCalls;
      final empty = await library.searchDetailed('مریخ', sourceIds: {});
      expect(empty.sources, isEmpty);
      expect(opened, isEmpty);
      expect(folder.listCalls, before);
    },
  );
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
  test('ninth active archive is searched and its article can be reopened', () async {
    final access = FixtureFolder({
      for (var i = 0; i < 8; i++) 'short-$i.zim': persianZim(shortText: true),
      'ninth.zim': persianZim(large: true, archive: 'دانشنامهٔ نهم آزمون'),
    });
    final library = FolderLibrary(access: access);
    await library.refresh();
    final rssBefore = ProcessInfo.currentRss;
    final timer = Stopwatch()..start();
    final result = await library.searchDetailed('بهبهان کجاست');
    timer.stop();
    final rssAfter = ProcessInfo.currentRss;
    final bytesRead = result.checks.fold<int>(
      0,
      (sum, check) => sum + ((check['readBytes'] as int?) ?? 0),
    );
    print(
      'synthetic nine-archive lookup: ${timer.elapsedMilliseconds} ms, $bytesRead bytes read, RSS before $rssBefore and after $rssAfter bytes; not a peak or device measurement',
    );
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
  });
  test(
    'reopening a citation opens only sources allowed by the project',
    () async {
      final access = FixtureFolder({
        'medical.zim': persianZim(archive: 'آرشیو پزشکی ساختگی'),
        'garden.zim': persianZim(archive: 'آرشیو باغ ساختگی'),
      });
      final opened = <String>[];
      access.overrideOpen = (uri) async {
        opened.add(uri);
        return access.files[uri]!.fresh();
      };
      final library = FolderLibrary(access: access);
      await library.refresh();
      final result = await library.searchDetailed(
        'بهبهان',
        sourceIds: {FolderLibrary.sourceId('garden.zim')},
      );
      final citation = result.sources.single;
      opened.clear();
      final article = await library.article(
        citation.url,
        citation.archiveId!,
        citation.archiveDate,
        allowSource: (uri) => uri == 'garden.zim',
      );
      expect(article?.source, 'آرشیو باغ ساختگی');
      expect(opened, ['garden.zim']);
      opened.clear();
      expect(
        await library.article(
          citation.url,
          citation.archiveId!,
          citation.archiveDate,
          allowSource: (_) => false,
        ),
        isNull,
      );
      expect(opened, isEmpty);
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
  test('stalled reads are bounded across repeated searches', () async {
    final folder = FixtureFolder({
      'slow-a.zim': persianZim(),
      'slow-b.zim': persianZim(),
      'later.zim': persianZim(),
    });
    final a = DelayedSource(persianZim());
    final b = DelayedSource(persianZim());
    folder.overrideOpen = (uri) async => uri == 'slow-a.zim' ? a : b;
    final library = FolderLibrary(
      access: folder,
      lookupTimeout: const Duration(milliseconds: 20),
    );
    await library.refresh();
    try {
      final first = await library.searchDetailed('مریخ');
      expect(first.checks.map((c) => c['code']), [
        'timeout',
        'timeout',
        'deferred_timeout',
      ]);
      expect(folder.opened, hasLength(2));
      final repeated = await library.searchDetailed('مریخ');
      expect(
        repeated.checks.map((c) => c['code']),
        everyElement('deferred_timeout'),
      );
      expect(folder.opened, hasLength(2));
    } finally {
      a.gate.complete();
      b.gate.complete();
      await Future.wait([a.released.future, b.released.future])
          .timeout(const Duration(seconds: 1));
    }
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
