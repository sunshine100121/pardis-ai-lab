import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/zim/zim_image_selection.dart';
import 'package:ondevice_llm/features/zim/zim_inline_gallery.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';
import 'package:ondevice_llm/features/zim/zim_archive.dart';
import 'package:ondevice_llm/features/zim/zim_wikipedia.dart';

import 'support/persian_zim_fixture.dart';

class _ImageFolder implements FolderAccess {
  final SparseZimSource original = persianZim(illustrated: true);
  final opened = <String>[];
  @override
  Future<bool> pick() async => false;
  @override
  Future<({String? tree, List<LibraryFile> files})> list() async => (
    tree: 'content://fixture/tree/images',
    files: [
      (uri: 'photo.zim', name: 'photo.zim', size: original.size, modified: 42),
    ],
  );
  @override
  Future<ZimSource> open(String uri) async {
    opened.add(uri);
    return original.fresh();
  }
}

void main() {
  test('search previews only approved local archive citations, bounded to four', () {
    final sources = <Map<String, dynamic>>[
      {'url': 'https://example.org/pear', 'archiveId': 'remote'},
      {'url': 'zim://first/pear', 'archiveId': 'wrong'},
      for (var i = 0; i < 8; i++)
        {'url': 'zim://archive$i/pear', 'archiveId': 'archive$i'},
    ];
    final previews = localSearchPreviewSources(sources);
    expect(previews, hasLength(4));
    expect(previews.first['archiveId'], 'archive0');
    expect(previews.last['archiveId'], 'archive3');
    expect(localSearchPreviewSources(sources, maxPreviews: 0), isEmpty);
  });

  test(
    'tries the next approved article when first citation has no photos',
    () async {
      final seen = <String>[];
      final sources = <Map<String, dynamic>>[
        {'url': 'https://example.com/remote', 'archiveId': 'remote'},
        {
          'url': 'zim://first/pear',
          'archiveId': 'first',
          'title': 'درخت گلابی',
        },
        {
          'url': 'zim://second/aphid',
          'archiveId': 'second',
          'title': 'آفت گلابی',
        },
      ];
      final match = await findFirstLocalGallery(sources, (source) async {
        seen.add(source['archiveId'] as String);
        if (source['archiveId'] == 'first') {
          return const ZimLocalGallery(0, []);
        }
        return ZimLocalGallery(1, [
          ZimLocalImage(
            caption: 'شته گلابی',
            bytes: Uint8List.fromList([137, 80, 78, 71]),
            reference: 'I/pear-aphid.png',
          ),
        ]);
      });
      expect(seen, ['first', 'second']);
      expect(match?.citation['archiveId'], 'second');
      expect(match?.gallery.images.single.caption, 'شته گلابی');
    },
  );

  test(
    'revoked or failing archive does not suppress another cited archive',
    () async {
      final sources = <Map<String, dynamic>>[
        {'url': 'zim://revoked/a', 'archiveId': 'revoked'},
        {'url': 'zim://allowed/b', 'archiveId': 'allowed'},
      ];
      final match = await findFirstLocalGallery(sources, (source) async {
        if (source['archiveId'] == 'revoked') {
          throw StateError('SAF permission revoked');
        }
        return ZimLocalGallery(1, [
          ZimLocalImage(
            caption: 'local',
            bytes: Uint8List.fromList([137, 80, 78, 71]),
            reference: 'I/valid.png',
          ),
        ]);
      });
      expect(match?.citation['archiveId'], 'allowed');
    },
  );

  test(
    'deduplicates citations and bounds large multi-source searches',
    () async {
      final sources = <Map<String, dynamic>>[
        for (var i = 0; i < 10; i++)
          {'url': 'zim://archive$i/pear', 'archiveId': 'archive$i'},
      ]..insert(1, {'url': 'zim://archive0/pear', 'archiveId': 'archive0'});
      final reads = <String>[];
      final match = await findFirstLocalGallery(sources, (source) async {
        reads.add(source['archiveId'] as String);
        return const ZimLocalGallery(0, []);
      });
      expect(reads, ['archive0', 'archive1', 'archive2', 'archive3']);
      expect(match?.citation['archiveId'], 'archive0');
      expect(match?.gallery.images, isEmpty);
    },
  );

  test(
    'approved local ZIM image bytes are retrieved without copying archive',
    () async {
      SharedPreferences.setMockInitialValues({});
      final access = _ImageFolder();
      final library = FolderLibrary(access: access);
      await library.refresh();
      final wiki = ZimWikipedia('photo.zim', openSource: access.open);
      final id = await wiki.archiveIdentity();
      await wiki.close();
      final citation = Uri(
        scheme: 'zim',
        host: id,
        path: '/بهبهان',
        queryParameters: {
          'entry': '0',
          'source': FolderLibrary.sourceId('photo.zim'),
        },
      ).toString();
      final result = await library.articleGallery(
        citation,
        id,
        '2026-11-15',
        question: 'آفت گلابی',
        allowSource: (uri) => uri == 'photo.zim',
      );
      expect(result, isNotNull);
      expect(result!.referencedCount, 2);
      expect(result.images, hasLength(2));
      expect(result.images.first.caption, contains('آفت'));
      expect(result.images.first.bytes.length, greaterThan(50));
      expect(result.images.first.bytes.take(4).toList(), [137, 80, 78, 71]);
      expect(access.opened, everyElement('photo.zim'));
      final before = access.opened.length;
      expect(
        await library.articleGallery(
          citation,
          id,
          '2026-11-15',
          question: 'آفت گلابی',
          allowSource: (_) => false,
        ),
        isNull,
      );
      expect(access.opened.length, before);
    },
  );

  test(
    'illustrated archives beyond 4 GiB are opened with bounded reads',
    () async {
      final source = persianZim(large: true, illustrated: true);
      final wiki = ZimWikipedia('large.zim', openSource: (_) async => source);
      try {
        final gallery = await wiki.gallery('بهبهان', question: 'آفت گلابی');
        expect(gallery?.images, hasLength(2));
        expect(source.highestOffset, greaterThan(1 << 32));
        expect(source.bytesRead, lessThan(512 * 1024));
        expect(source.maxRead, lessThanOrEqualTo(4096));
      } finally {
        await wiki.close();
      }
    },
  );

  test(
    'remote, data and unsupported image references never read media',
    () async {
      final access = _ImageFolder();
      final archive = await ZimArchive.open(
        'photo.zim',
        openSource: access.open,
      );
      try {
        final article = await archive.findByTitle('بهبهان');
        expect(article, isNotNull);
        expect(
          await archive.imageBytes(article!, 'https://example.org/p.png'),
          isNull,
        );
        expect(
          await archive.imageBytes(article, '//example.org/p.png'),
          isNull,
        );
        expect(
          await archive.imageBytes(article, 'data:image/png;base64,AA'),
          isNull,
        );
        expect(
          await archive.imageBytes(
            article,
            '../I/pear-pest.png',
            maxImageBytes: 0,
          ),
          isNull,
        );
        expect(
          await archive.imageBytes(article, '../I/pear-pest.png'),
          isNotNull,
        );
      } finally {
        await archive.close();
      }
    },
  );
}
