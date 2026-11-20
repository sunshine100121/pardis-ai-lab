import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/pocket_farsi_v2_pack.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pala-pocket-pack-');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  final manifest = jsonEncode({
    'constants': {
      'sample_rate': 24000,
      'ldim': 32,
      'dim': 1024,
      'layers': 6,
      'cache_capacity': 256,
    },
  });

  Archive package({String? omission, bool unsafe = false}) {
    final zip = Archive();
    for (final name in PocketFarsiPack.requiredFiles) {
      if (omission == name) continue;
      final value = switch (name) {
        'manifest.json' => manifest,
        'voice_reference.wav' => 'RIFF0000WAVEdata',
        _ => 'stub-' + name,
      };
      final bytes = utf8.encode(value);
      zip.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    if (unsafe) {
      zip.addFile(ArchiveFile('../unexpected', 1, [0]));
    }
    return zip;
  }

  Future<File> saveZip(Archive archive, String name) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  test('valid pack imports into the native Android application-files path', () async {
    final source = await saveZip(package(), 'valid.zip');
    final appFiles = Directory(p.join(tmp.path, 'app_files'));
    final imported = await PocketFarsiPack.importZip(source, appFiles: appFiles);
    expect(
      p.normalize(imported.path),
      p.normalize(p.join(appFiles.path, 'voice_models', 'pocket_farsi_v2')),
    );
    expect(await PocketFarsiPack.isPresent(appFiles: appFiles), isTrue);
    expect((await PocketFarsiPack.manifestFingerprint(appFiles: appFiles)).length, 64);
  });

  test('missing 341 MB ONNX data sidecar fails without installing', () async {
    final root = Directory(p.join(tmp.path, 'app_files'));
    final zip = await saveZip(package(omission: 'flow_lm_step.onnx.data'), 'missing.zip');
    await expectLater(
      PocketFarsiPack.importZip(zip, appFiles: root),
      throwsFormatException,
    );
    expect(await PocketFarsiPack.isPresent(appFiles: root), isFalse);
  });

  test('zip traversal is rejected with no live model replaced', () async {
    final root = Directory(p.join(tmp.path, 'app_files'));
    final zip = await saveZip(package(unsafe: true), 'bad.zip');
    await expectLater(
      PocketFarsiPack.importZip(zip, appFiles: root),
      throwsFormatException,
    );
    expect(await PocketFarsiPack.isPresent(appFiles: root), isFalse);
  });

  test('existing installation cannot be overwritten even by valid ZIP', () async {
    final root = Directory(p.join(tmp.path, 'app_files'));
    final zip = await saveZip(package(), 'valid.zip');
    final installed = await PocketFarsiPack.importZip(zip, appFiles: root);
    final marker = File(p.join(installed.path, 'owner-data-marker.txt'));
    await marker.writeAsString('keep');
    await expectLater(
      PocketFarsiPack.importZip(zip, appFiles: root),
      throwsFormatException,
    );
    expect(await marker.readAsString(), 'keep');
  });
}
