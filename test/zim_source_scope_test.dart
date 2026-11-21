import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/zim/zim_source_scope.dart';

void main() {
  test('general chat accepts twelve owner-enabled ZIM archives, not eight', () {
    final files = [
      for (var i = 0; i < 12; i++)
        {
          'uri': 'content://owner/encyclopedia-$i.zim',
          'name': 'encyclopedia-$i.zim',
          'enabled': true,
        },
      {
        'uri': 'content://owner/unapproved.zim',
        'name': 'unapproved.zim',
        'enabled': false,
      },
      {
        'uri': 'content://owner/notes.pdf',
        'name': 'notes.pdf',
        'enabled': true,
      },
    ];
    final ids = ZimSourceScope.enabledArchives({'files': files});
    expect(ids, hasLength(12));
    expect(
      ids,
      contains(FolderLibrary.sourceId('content://owner/encyclopedia-11.zim')),
    );
    expect(
      ids,
      isNot(contains(FolderLibrary.sourceId('content://owner/unapproved.zim'))),
    );
    expect(
      ids,
      isNot(contains(FolderLibrary.sourceId('content://owner/notes.pdf'))),
    );
  });

  test('malformed library state never expands public source authorization', () {
    expect(ZimSourceScope.enabledArchives({}), isEmpty);
    expect(
      ZimSourceScope.enabledArchives({
        'files': [
          {'uri': null, 'name': 'fake.zim', 'enabled': true},
          {'uri': 'good', 'name': 20, 'enabled': true},
          {'uri': 'no', 'name': 'disabled.zim', 'enabled': 'true'},
        ],
      }),
      isEmpty,
    );
  });
}
