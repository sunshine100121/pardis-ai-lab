import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
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
}
