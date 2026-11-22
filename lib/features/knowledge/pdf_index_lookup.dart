import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../zim/zim_index_storage.dart';
import 'pdf_page_index.dart';

/// null = no complete revision index; [] = complete index with no matches.
/// Only reads app-private derived data; original SAF files remain unopened.
abstract final class PdfIndexLookup {
  static Future<List<({int page, String text})>?> read({
    required String sourceId,
    required int size,
    required int modified,
    required String query,
  }) async {
    final storage = await ZimIndexStorage.android();
    if (storage == null) return null;
    final dbPath = path.join(
      storage.directory.path,
      'pala-pdf-page-index-v1.sqlite',
    );
    if (!await File(dbPath).exists()) return null;
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final index = PdfPageIndex(db, initialize: false);
      if (index.status(sourceId, size: size, modified: modified)?.complete !=
          true) {
        return null;
      }
      return index.search(
        sourceId: sourceId,
        size: size,
        modified: modified,
        query: query,
      );
    } finally {
      db?.close();
    }
  }
}
