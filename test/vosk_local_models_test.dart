import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/vosk_local_models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pala_vosk_models_');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> makeZip(
    String name, {
    bool malicious = false,
    bool staticGraph = false,
  }) async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('model/am/final.mdl', 'model'))
      ..addFile(ArchiveFile.string('model/conf/model.conf', 'config'));
    if (staticGraph) {
      archive.addFile(ArchiveFile.string('model/graph/HCLG.fst', 'static'));
    } else {
      archive
        ..addFile(ArchiveFile.string('model/graph/Gr.fst', 'grammar'))
        ..addFile(ArchiveFile.string('model/graph/HCLr.fst', 'hclr'));
    }
    if (malicious) {
      archive.addFile(ArchiveFile.string('model/../../escape.txt', 'escape'));
    }
    final file = File(p.join(temp.path, name));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  test('owner can import and list an extra Vosk model offline', () async {
    final zip = await makeZip('persian-v2.zip');
    final root = Directory(p.join(temp.path, 'models'));
    final result = await VoskLocalModels.importZip(
      zip,
      root: root,
      displayName: 'فارسی سفارشی',
    );
    expect(result.selectionId, startsWith('stt:vosk:'));
    expect(await VoskLocalModels.pathFor(result.id, root: root), result.path);
    final available = await VoskLocalModels.installed(root: root);
    expect(available.single.name, 'فارسی سفارشی');
    expect(available.single.id, result.id);
    expect((await VoskLocalModels.importZip(zip, root: root)).id, result.id);
    await VoskLocalModels.delete(result.id, root: root);
    expect(await VoskLocalModels.installed(root: root), isEmpty);
    expect(await zip.exists(), isTrue);
  });

  test('a larger Vosk model with HCLG graph also imports', () async {
    final zip = await makeZip('persian-large.zip', staticGraph: true);
    final root = Directory(p.join(temp.path, 'models'));
    final model = await VoskLocalModels.importZip(zip, root: root);
    expect(await VoskLocalModels.pathFor(model.id, root: root), model.path);
    expect((await VoskLocalModels.installed(root: root)).single.id, model.id);
  });

  test(
    'unsafe archive cannot write outside app-owned model directory',
    () async {
      final zip = await makeZip('unsafe.zip', malicious: true);
      final root = Directory(p.join(temp.path, 'models'));
      await expectLater(
        VoskLocalModels.importZip(zip, root: root),
        throwsFormatException,
      );
      expect(await File(p.join(temp.path, 'escape.txt')).exists(), isFalse);
      expect(await VoskLocalModels.installed(root: root), isEmpty);
    },
  );
}
