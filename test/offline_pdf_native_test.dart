import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:ondevice_llm/features/knowledge/folder_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real PDF text layer is read locally with page markers',() async {
    final doc=pw.Document()..addPage(pw.Page(build:(_)=>pw.Text('Orchid nutrient concentration is 42.')));
    final text=await FolderLibrary.readPdf(Uint8List.fromList(await doc.save()));
    expect(text,contains('--- Page 1 ---'));
    expect(text,contains('Orchid nutrient concentration is 42.'));
  });
}
