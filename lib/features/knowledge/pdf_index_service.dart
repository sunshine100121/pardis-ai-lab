import 'dart:async';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../zim/zim_index_storage.dart';
import 'folder_library.dart';
import 'pdf_page_index.dart';

/// Owner-initiated and stoppable PDF text-layer indexing, never background
/// scanning. Reuses the existing bounded SAF/PDFium reader. The original PDF
/// is not copied or mutated; only derived page text is stored in SQLite.
class PdfIndexService {
  final FolderLibrary library;
  final ZimIndexStorage storage;
  final Database Function(String path) openDatabase;
  bool _running = false;
  bool _stop = false;

  PdfIndexService(
    this.library,
    this.storage, {
    Database Function(String path)? openDatabase,
  }) : openDatabase = openDatabase ?? sqlite3.open;

  bool get running => _running;
  void stop() => _stop = true;

  String get indexPath =>
      path.join(storage.directory.path, 'pala-pdf-page-index-v1.sqlite');

  Future<({int scanned, int total, int needsOcr, bool cancelled})> run({
    required String uri,
    required bool Function() allowed,
    void Function(int page, int total)? onProgress,
  }) async {
    if (_running) throw StateError('نمایه‌سازی PDF دیگری در حال اجراست');
    if (!allowed()) throw StateError('اجازه دسترسی به PDF وجود ندارد');
    _running = true;
    _stop = false;
    Database? db;
    try {
      if (!await storage.hasHeadroom()) {
        throw StateError('فضای کافی برای نمایه PDF تأیید نشد');
      }
      final libraryState = await library.state();
      final files = (libraryState['files'] as List)
          .whereType<Map>()
          .where(
            (f) =>
                f['uri'] == uri &&
                f['enabled'] == true &&
                f['name'] is String &&
                (f['name'] as String).toLowerCase().endsWith('.pdf'),
          )
          .toList();
      if (files.length != 1) {
        throw StateError('PDF فعال و یکتا در پوشه مجاز پیدا نشد');
      }
      final row = files.single;
      final name = row['name'] as String;
      final size = (row['size'] as num).toInt();
      final modified = (row['modified'] as num).toInt();
      final id = FolderLibrary.sourceId(uri);
      Future<bool> unchanged() async {
        if (!allowed()) return false;
        final fresh = await library.state();
        final selected = (fresh['files'] as List).whereType<Map>().where(
          (r) =>
              r['uri'] == uri &&
              r['enabled'] == true &&
              r['size'] == size &&
              r['modified'] == modified,
        );
        if (selected.length != 1) return false;
        final live = await library.access.list();
        return live.files.where(
              (f) =>
                  f.uri == uri &&
                  f.name == name &&
                  f.size == size &&
                  f.modified == modified,
            ).length ==
            1;
      }

      if (!await unchanged()) throw StateError('PDF تغییر کرده است');
      db = openDatabase(indexPath);
      final index = PdfPageIndex(
        db,
        maxDatabaseBytes: storage.maxDatabaseBytes,
      );
      var cursor = index.status(id, size: size, modified: modified);
      if (cursor?.complete == true) {
        return (
          scanned: cursor!.totalPages,
          total: cursor.totalPages,
          needsOcr: cursor.needsOcr,
          cancelled: false,
        );
      }
      var total = cursor?.totalPages ?? 0;
      final pending = <({int page, String text})>[];
      Future<void> commit() async {
        if (pending.isEmpty) return;
        if (!await unchanged() || !await storage.hasHeadroom()) {
          throw StateError('PDF یا فضای ذخیره‌سازی هنگام نمایه تغییر کرد');
        }
        index.append(
          sourceId: id,
          size: size,
          modified: modified,
          pages: List.of(pending),
        );
        pending.clear();
        cursor = index.status(id, size: size, modified: modified);
        onProgress?.call((cursor?.nextPage ?? 1) - 1, total);
      }

      // This source remains open for the current run, avoiding extra copies.
      final source = await library.access.open(uri);
      try {
        await FolderLibrary.scanPdfSource(
          source,
          size,
          const <String>{},
          sourceName: 'pala-pdf-index:$id:$modified',
          startPage: cursor?.nextPage ?? 1,
          cancelled: () => _stop || !allowed(),
          onOpened: (pageCount) async {
            if (!await unchanged()) throw StateError('مجوز PDF تغییر کرد');
            index.begin(
              sourceId: id,
              size: size,
              modified: modified,
              totalPages: pageCount,
            );
            total = pageCount;
          },
          onPageText: (page, text) async {
            pending.add((page: page, text: text));
            if (pending.length >= 16) await commit();
          },
        );
        if (!_stop) await commit();
      } finally {
        await source.close();
      }
      // A cancelled or revoked run never exposes incomplete index results.
      cursor = index.status(id, size: size, modified: modified);
      if (!await unchanged()) throw StateError('مجوز PDF لغو شد');
      return (
        scanned: (cursor?.nextPage ?? 1) - 1,
        total: total,
        needsOcr: cursor?.needsOcr ?? 0,
        cancelled: _stop || cursor?.complete != true,
      );
    } finally {
      db?.close();
      _running = false;
    }
  }
}
