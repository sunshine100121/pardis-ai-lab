import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/persian_sherpa_models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pala_sherpa_');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> fake(
    String fileName, {
    bool piper = false,
    bool unsafe = false,
  }) async {
    final pack = Archive()
      ..addFile(ArchiveFile.string('bundle/model.onnx', 'onnx'))
      ..addFile(ArchiveFile.string('bundle/tokens.txt', 'tokens'));
    if (piper) {
      pack.addFile(ArchiveFile.string('bundle/espeak-ng-data/phontab', 'data'));
    }
    if (unsafe) {
      pack.addFile(ArchiveFile.string('bundle/../../escape', 'bad'));
    }
    final file = File(p.join(temp.path, fileName));
    await file.writeAsBytes(ZipEncoder().encode(pack));
    return file;
  }

  test('Shenava offline model can be added, selected and removed', () async {
    final root = Directory(p.join(temp.path, 'models'));
    final pack = await fake('shenava.zip');
    final model = await PersianSherpaModels.importArchive(
      pack,
      PersianSherpaKind.stt,
      root: root,
      label: 'شنوا ریزه',
    );
    expect(model.selectionId, startsWith('stt:sherpa-ctc:'));
    expect(
      await PersianSherpaModels.find(
        PersianSherpaKind.stt,
        model.id,
        root: root,
      ),
      isNotNull,
    );
    expect(
      (await PersianSherpaModels.installed(
        PersianSherpaKind.stt,
        root: root,
      )).single.id,
      model.id,
    );
    expect(await pack.exists(), isTrue);
    await PersianSherpaModels.delete(
      PersianSherpaKind.stt,
      model.id,
      root: root,
    );
    expect(
      await PersianSherpaModels.installed(PersianSherpaKind.stt, root: root),
      isEmpty,
    );
  });

  test(
    'Piper requires phonemizer assets and remains separate from STT',
    () async {
      final root = Directory(p.join(temp.path, 'models'));
      final pack = await fake('piper.zip', piper: true);
      final model = await PersianSherpaModels.importArchive(
        pack,
        PersianSherpaKind.tts,
        root: root,
      );
      expect(model.selectionId, startsWith('tts:piper:'));
      expect(
        (await PersianSherpaModels.installed(
          PersianSherpaKind.tts,
          root: root,
        )).single.id,
        model.id,
      );
      expect(
        await PersianSherpaModels.installed(PersianSherpaKind.stt, root: root),
        isEmpty,
      );
      final bad = await fake('bad-piper.zip');
      expect(
        () => PersianSherpaModels.importArchive(
          bad,
          PersianSherpaKind.tts,
          root: root,
        ),
        throwsFormatException,
      );
    },
  );

  test('reject traversal before writing outside staging', () async {
    final root = Directory(p.join(temp.path, 'models'));
    final pack = await fake('unsafe.zip', unsafe: true);
    await expectLater(
      PersianSherpaModels.importArchive(
        pack,
        PersianSherpaKind.stt,
        root: root,
      ),
      throwsFormatException,
    );
    expect(await File(p.join(temp.path, 'escape')).exists(), isFalse);
  });
}
