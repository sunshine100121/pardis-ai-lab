import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ondevice_llm/features/knowledge/pdf_ocr_models.dart';

import 'offline_pdf_native_test.dart' show PdfTestPaths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OCR never pretends readiness without exact local language models',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'pala-ocr-model-check-',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = PdfTestPaths(dir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await dir.delete(recursive: true);
      });
      expect(PdfOcrModels.models.keys.toSet(), {'fas', 'eng'});
      expect(PdfOcrModels.models['fas']!.bytes, 431500);
      expect(PdfOcrModels.models['eng']!.bytes, 4113088);
      expect(await PdfOcrModels.ready(), false);
      final root = await PdfOcrModels.dataDirectory();
      expect(await root.exists(), false); // no background creation/download
    },
  );
}
