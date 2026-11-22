import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqlite3/sqlite3.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/knowledge/pdf_page_index.dart';
import 'package:ondevice_llm/features/knowledge/pdf_index_service.dart';
import 'package:ondevice_llm/features/zim/zim_index_storage.dart';

import 'offline_folder_library_test.dart' show TestFolder;
import 'offline_pdf_native_test.dart' show PdfTestPaths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('page index is transactional, resumable and never serves partial or stale revisions', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = PdfPageIndex(db);
    index.begin(sourceId: 'book', size: 200, modified: 5, totalPages: 129);
    index.append(
      sourceId: 'book',
      size: 200,
      modified: 5,
      pages: [(page: 1, text: 'Welcome to the book.')],
    );
    expect(
      index.search(sourceId: 'book', size: 200, modified: 5, query: 'Welcome'),
      isEmpty,
    );
    for (var page = 2; page <= 129; page += 16) {
      final end = page + 15 <= 129 ? page + 15 : 129;
      index.append(
        sourceId: 'book',
        size: 200,
        modified: 5,
        pages: [
          for (var n = page; n <= end; n++)
            (
              page: n,
              text: n == 129
                  ? 'Unique orchard canopy evidence on the last page.'
                  : 'This chapter discusses a botanical reference.',
            ),
        ],
      );
    }
    final matches = index.search(
      sourceId: 'book',
      size: 200,
      modified: 5,
      query: '«Unique orchard canopy evidence»',
    );
    expect(matches, hasLength(1));
    expect(matches.single.page, 129);
    expect(
      index.search(sourceId: 'book', size: 200, modified: 6, query: 'orchard'),
      isEmpty,
    );
    index.begin(sourceId: 'book', size: 200, modified: 6, totalPages: 129);
    expect(
      index.search(sourceId: 'book', size: 200, modified: 5, query: 'orchard'),
      isEmpty,
    );
    expect(index.status('book', size: 200, modified: 6)?.nextPage, 1);
    index.discard('book');
    expect(index.status('book', size: 200, modified: 6), isNull);
  });

  test('empty scanned pages are flagged as needing OCR, never invented', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = PdfPageIndex(db);
    index.begin(sourceId: 'scan', size: 25, modified: 1, totalPages: 2);
    index.append(
      sourceId: 'scan',
      size: 25,
      modified: 1,
      pages: [(page: 1, text: ''), (page: 2, text: '  ')],
    );
    expect(index.status('scan', size: 25, modified: 1)?.needsOcr, 2);
    expect(
      index.search(sourceId: 'scan', size: 25, modified: 1, query: 'walnut'),
      isEmpty,
    );
  });

  test('OCR-derived text stays marked as OCR evidence and not PDF text layer', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final index = PdfPageIndex(db);
    index.begin(sourceId: 'scan-ocr', size: 42, modified: 8, totalPages: 2);
    index.append(
      sourceId: 'scan-ocr',
      size: 42,
      modified: 8,
      pages: [
        (page: 1, text: 'Text-layer source passage.'),
        (page: 2, text: 'Recognized Persian OCR passage.'),
      ],
      recognizedByOcr: {2},
    );
    expect(
      index.search(sourceId: 'scan-ocr', size: 42, modified: 8,
          query: '«Recognized Persian OCR passage»').single.ocr,
      true,
    );
    expect(
      index.search(sourceId: 'scan-ocr', size: 42, modified: 8,
          query: '«Text-layer source passage»').single.ocr,
      false,
    );
    expect(index.status('scan-ocr', size: 42, modified: 8)?.needsOcr, 0);
  });

  test(
    'one index pass resumes after stop and later skips PDFium scans',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('pala-m03-pdf-index-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = PdfTestPaths(dir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await dir.delete(recursive: true);
      });
      final pdf = pw.Document();
      for (var page = 1; page <= 130; page++) {
        pdf.addPage(
          pw.Page(
            build: (_) => pw.Text(
              page == 127
                  ? 'Distinct persimmon greenhouse signature on page 127.'
                  : 'Ordinary horticulture chapter $page.',
            ),
          ),
        );
      }
      final original = Uint8List.fromList(await pdf.save());
      final folder = TestFolder()..add('indexed.pdf', original);
      final library = FolderLibrary(access: folder);
      await library.refresh();
      final storage = ZimIndexStorage(
        directory: dir,
        availableBytes: () async => 1024 * 1024 * 1024,
        reserveBytes: 0,
        maxDatabaseBytes: 64 * 1024 * 1024,
      );
      final first = PdfIndexService(library, storage);
      final partial = await first.run(
        uri: 'indexed.pdf',
        allowed: () => true,
        onProgress: (page, total) {
          if (page == 16) first.stop();
        },
      );
      expect(partial.cancelled, true);
      expect(partial.scanned, 16);
      final resumed = PdfIndexService(library, storage);
      final finished = await resumed.run(
        uri: 'indexed.pdf',
        allowed: () => true,
      );
      expect(finished.cancelled, false);
      expect(finished.scanned, 130);
      expect(finished.total, 130);
      expect(finished.needsOcr, 0);

      final db = sqlite3.open(resumed.indexPath, mode: OpenMode.readOnly);
      final index = PdfPageIndex(db, initialize: false);
      final matches = index.search(
        sourceId: FolderLibrary.sourceId('indexed.pdf'),
        size: original.length,
        modified: 1,
        query: '«Distinct persimmon greenhouse signature»',
      );
      expect(matches.single.page, 127);
      db.close();

      final opensBefore = folder.opens;
      final cached = FolderLibrary(
        access: folder,
        indexedPdfSearch:
            ({
              required sourceId,
              required size,
              required modified,
              required query,
            }) async {
              final db = sqlite3.open(
                resumed.indexPath,
                mode: OpenMode.readOnly,
              );
              try {
                return PdfPageIndex(db, initialize: false).search(
                  sourceId: sourceId,
                  size: size,
                  modified: modified,
                  query: query,
                );
              } finally {
                db.close();
              }
            },
      );
      final report = await cached.searchDetailed(
        'در indexed.pdf عبارت «Distinct persimmon greenhouse signature» را پیدا کن',
      );
      expect(report.sources, hasLength(1));
      expect(report.sources.single.title, contains('صفحه 127'));
      expect(report.checks.single['code'], 'pdf_index_hit');
      expect(folder.opens, opensBefore);
      expect(folder.bytes['indexed.pdf'], original);
      await cached.setEnabled('indexed.pdf', false);
      expect(
        (await cached.searchDetailed(
          '«Distinct persimmon greenhouse signature»',
        )).sources,
        isEmpty,
      );
    },
  );
}
