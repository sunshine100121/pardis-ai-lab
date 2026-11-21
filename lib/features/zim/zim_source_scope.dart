import '../knowledge/folder_library.dart';

/// The general chat may use every owner-enabled local ZIM. A project must
/// continue using ONLY its explicitly assigned source IDs; never merge scopes.
/// No arbitrary eight-archive cap: the database, device and index quotas
/// still bound actual indexing work.
abstract final class ZimSourceScope {
  static Set<String> enabledArchives(Map<String, dynamic> libraryState) {
    final files = libraryState['files'];
    if (files is! List) return <String>{};
    return {
      for (final item in files)
        if (item is Map &&
            item['enabled'] == true &&
            item['uri'] is String &&
            item['name'] is String &&
            (item['name'] as String).toLowerCase().endsWith('.zim'))
          FolderLibrary.sourceId(item['uri'] as String),
    };
  }
}
