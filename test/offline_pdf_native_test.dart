import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_folder_library_test.dart' show TestFolder;

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:ondevice_llm/features/knowledge/folder_library.dart';
import 'package:ondevice_llm/features/knowledge/knowledge_read_report.dart';
import 'package:ondevice_llm/features/zim/zim_source.dart';

class PdfTestPaths extends PathProviderPlatform {
  final String path;
  PdfTestPaths(this.path);
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}


class _MeasuredPdfSource implements ZimSource {
  final Uint8List data;
  bool closed = false;
  int largestRead = 0;
  int readCalls = 0;
  _MeasuredPdfSource(this.data);

  @override
  Future<int> length() async => data.length;

  @override
  Future<Uint8List> readAt(int offset, int count) async {
    if (count > largestRead) largestRead = count;
    if (count > FolderLibrary.maxPdfReadChunkBytes) {
      throw StateError('PDF access exceeded bounded read size');
    }
    readCalls++;
    return Uint8List.sublistView(data, offset, offset + count);
  }

  @override
  Future<void> close() async { closed = true; }
}

class _MeasuredPdfFolder extends TestFolder {
  final sources = <_MeasuredPdfSource>[];
  @override
  Future<ZimSource> open(String uri) async {
    opens++;
    final source = _MeasuredPdfSource(bytes[uri]!);
    sources.add(source);
    return source;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real PDF text layer is read locally with page markers', () async {
    final folder = await Directory.systemTemp.createTemp('pala-pdf-native-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = PdfTestPaths(folder.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await folder.delete(recursive: true);
    });
    final doc = pw.Document()
      ..addPage(
        pw.Page(build: (_) => pw.Text('Orchid nutrient concentration is 42.')),
      );
    final text = await FolderLibrary.readPdf(
      Uint8List.fromList(await doc.save()),
    );
    expect(text, contains('--- Page 1 ---'));
    expect(text, contains('Orchid nutrient concentration is 42.'));
  });

  test('310-page PDF finds page 297 through bounded reads with no duplicate file', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('pala-pdf-310-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = PdfTestPaths(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await dir.delete(recursive: true);
    });
    final document = pw.Document();
    for (var page = 1; page <= 310; page++) {
      document.addPage(
        pw.Page(
          build: (_) => pw.Text(
            page == 297
                ? 'Unique apricot canopy late chapter page marker 297.'
                : 'Common overview for a chapter of the garden handbook.',
          ),
        ),
      );
    }
    final bytes = Uint8List.fromList(await document.save());
    final folder = _MeasuredPdfFolder()..add('garden-handbook.pdf', bytes);
    // Only metadata/short preview is persisted. Full pages must be read
    // afresh from the approved source rather than copied into the index.
    final library = FolderLibrary(
      access: folder,
      pdfText: (_) async => '--- Page 1 ---\nCommon overview only.',
    );
    await library.refresh();
    final results = await library.searchDetailed(
      'unique apricot canopy marker',
      sourceIds: {FolderLibrary.sourceId('garden-handbook.pdf')},
    );
    expect(results.sources, isNotEmpty);
    expect(results.sources.first.title, contains('garden-handbook.pdf'));
    expect(results.sources.first.title, contains('صفحه 297'));
    expect(results.sources.first.pageText, contains('late chapter page marker'));
    expect(results.checks.single['pagesScanned'], 310);
    expect(results.checks.single['pagesWithText'], 310);
    expect(folder.sources, hasLength(2));
    expect(folder.sources.last.largestRead,
        lessThanOrEqualTo(FolderLibrary.maxPdfReadChunkBytes));
    expect(folder.sources.last.readCalls, greaterThan(1));
    expect(folder.sources.every((source) => source.closed), isTrue);
    expect(folder.bytes['garden-handbook.pdf'], bytes);
    expect(await library.indexBytes(), lessThan(FolderLibrary.maxIndexBytes));
  });

  test('image-only PDF reports missing text layer, never fabricated OCR', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('pala-pdf-scan-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = PdfTestPaths(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await dir.delete(recursive: true);
    });
    final document = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Container(width: 60, height: 60)));
    final bytes = Uint8List.fromList(await document.save());
    final folder = TestFolder()..add('scanned-image.pdf', bytes);
    final library = FolderLibrary(access: folder);
    await library.refresh();
    final result = await library.searchDetailed(
      'apricot disease',
      sourceIds: {FolderLibrary.sourceId('scanned-image.pdf')},
    );
    expect(result.sources, isEmpty);
    expect(result.checks.single['code'], 'pdf_no_text');
    expect(
      KnowledgeReadReport.checkLabel(result.checks.single),
      contains('OCR'),
    );
    expect(folder.bytes['scanned-image.pdf'], bytes);
  });

  test('an approved long PDF retrieves evidence on page 105', () async {
    SharedPreferences.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp('pala-pdf-long-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = PdfTestPaths(folder.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await folder.delete(recursive: true);
    });
    final doc = pw.Document();
    for (var i = 1; i <= 110; i++) {
      final text = i == 105
          ? 'Rare orchid mycorrhiza tracer appears only on this page.'
          : 'Background chapter with neutral botanical descriptions.';
      doc.addPage(pw.Page(build: (_) => pw.Text(text)));
    }
    final bytes = Uint8List.fromList(await doc.save());
    final access = TestFolder()..add('long.pdf', bytes);
    final library = FolderLibrary(
      access: access,
      pdfText: (_) async => '--- Page 1 ---\nUnrelated preview only.',
    );
    await library.refresh();
    final report = await library.searchDetailed(
      'orchid mycorrhiza tracer',
      sourceIds: {FolderLibrary.sourceId('long.pdf')},
    );
    expect(report.sources, isNotEmpty);
    expect(report.sources.first.title, contains('صفحه 105'));
    expect(report.sources.first.pageText, contains('mycorrhiza tracer'));
    expect(access.bytes['long.pdf'], bytes);
  });
}

// Temporary format patch locator.
