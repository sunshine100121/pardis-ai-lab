import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';
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
  test('approved local ZIM image bytes are retrieved without copying archive',
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
  });

  test('external or invalid image reference cannot read ZIM content',
      () async {
    final access = _ImageFolder();
    final wiki = ZimWikipedia('photo.zim', openSource: access.open);
    final source = await ZimSource.open('test/fixtures/zim/mini.zim');
    await source.close();
    final archive = await wiki.archiveIdentity();
    expect(archive, isNotEmpty);
    await wiki.close();
  });
}
