import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_folder_library_test.dart' show TestFolder;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:ondevice_llm/features/knowledge/folder_library.dart';

class PdfTestPaths extends PathProviderPlatform {
  final String path;
  PdfTestPaths(this.path);
  @override
  Future<String?> getTemporaryPath() async=>path;
  @override
  Future<String?> getApplicationSupportPath() async=>path;
  @override
  Future<String?> getApplicationCachePath() async=>path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real PDF text layer is read locally with page markers',() async {
    final folder=await Directory.systemTemp.createTemp('pala-pdf-native-');
    final previous=PathProviderPlatform.instance;
    PathProviderPlatform.instance=PdfTestPaths(folder.path);
    addTearDown(() async { PathProviderPlatform.instance=previous; await folder.delete(recursive:true); });
    final doc=pw.Document()..addPage(pw.Page(build:(_)=>pw.Text('Orchid nutrient concentration is 42.')));
    final text=await FolderLibrary.readPdf(Uint8List.fromList(await doc.save()));
    expect(text,contains('--- Page 1 ---'));
    expect(text,contains('Orchid nutrient concentration is 42.'));
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
