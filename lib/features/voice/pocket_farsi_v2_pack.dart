import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Experimental Pocket pack import. Does not download models, change TTS,
/// overwrite installed data, or construct a 500MB Uint8List in Dart.
abstract final class PocketFarsiPack {
  static const maxArchiveBytes = 650 * 1024 * 1024;
  static const maxUnpackedBytes = 700 * 1024 * 1024;

  static const requiredFiles = <String>{
    'manifest.json',
    'flow_lm_step.onnx',
    'flow_lm_step.onnx.data',
    'mimi_encoder.onnx',
    'mimi_encoder.onnx.data',
    'mimi_decoder_step_kv.onnx',
    'mimi_decoder_step_kv.onnx.data',
    'g2p_encoder.onnx',
    'g2p_decoder.onnx',
    'g2p_decoder.onnx.data',
    'weights.npz',
    'decode_state_init.npz',
    'tokenizer_ph.model',
    'voice_reference.wav',
  };

  static Future<Directory> destination({Directory? appFiles}) async {
    final root = appFiles ?? await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'voice_models', 'pocket_farsi_v2'));
  }

  static Future<bool> isPresent({Directory? appFiles}) async {
    final dir = await destination(appFiles: appFiles);
    if (!await dir.exists()) return false;
    try {
      await verifyFiles(dir);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Structural check only. Model inference, pronunciation and CPU memory
  /// must be verified separately on the real tablet.
  static Future<void> verifyFiles(Directory dir) async {
    final found = <String>{};
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || await FileSystemEntity.isLink(entity.path)) {
        throw const FormatException('فایل نامعتبر در بسته Pocket.');
      }
      final name = p.basename(entity.path);
      if (!requiredFiles.contains(name) || !found.add(name)) {
        throw const FormatException('فایل اضافی یا تکراری در بسته Pocket.');
      }
      if (await entity.length() <= 0) {
        throw const FormatException('فایل خالی در بسته Pocket.');
      }
    }
    if (!found.containsAll(requiredFiles)) {
      throw FormatException(
        'بسته Pocket ناقص است: ' + requiredFiles.difference(found).join(', '),
      );
    }
    final manifest = jsonDecode(
      await File(p.join(dir.path, 'manifest.json')).readAsString(),
    );
    if (manifest is! Map || manifest['constants'] is! Map) {
      throw const FormatException('manifest مدل معتبر نیست.');
    }
    final c = manifest['constants'] as Map;
    if (c['sample_rate'] != 24000 ||
        c['ldim'] != 32 ||
        c['dim'] != 1024 ||
        c['layers'] == null ||
        c['cache_capacity'] == null) {
      throw const FormatException('نسخه مدل ONNX ناسازگار است.');
    }
    final wav = File(p.join(dir.path, 'voice_reference.wav'));
    final head = await wav.openRead(0, 12).fold<List<int>>(
      <int>[],
      (a, chunk) => a..addAll(chunk),
    );
    if (head.length != 12 ||
        ascii.decode(head.sublist(0, 4)) != 'RIFF' ||
        ascii.decode(head.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('صدای مرجع باید WAV معتبر باشد.');
    }
  }

  /// A deliberately explicit, owner-initiated ZIP import for an ADVANCED
  /// diagnostic path, never an automatic installation or voice-selection.
  static Future<Directory> importZip(File archiveFile, {Directory? appFiles}) async {
    final bytes = await archiveFile.length();
    if (!archiveFile.path.toLowerCase().endsWith('.zip') ||
        bytes <= 0 ||
        bytes > maxArchiveBytes) {
      throw const FormatException('فایل ZIP مدل Pocket معتبر نیست.');
    }
    final root = appFiles ?? await getApplicationSupportDirectory();
    final target = await destination(appFiles: root);
    if (await target.exists()) {
      throw const FormatException(
        'مدل Pocket قبلاً موجود است؛ هیچ داده‌ای جایگزین نشد.',
      );
    }
    await target.parent.create(recursive: true);
    final stage = await Directory(
      p.join(
        target.parent.path,
        '.pala-pocket-stage-' +
            DateTime.now().microsecondsSinceEpoch.toString(),
      ),
    ).create();
    try {
      await Isolate.run(() => _extractSafe(archiveFile.path, stage.path));
      await verifyFiles(stage);
      if (await target.exists()) {
        throw const FormatException('بسته هم‌زمان نصب شده است.');
      }
      await stage.rename(target.path);
      return target;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static void _extractSafe(String path, String dest) {
    final source = InputFileStream(path);
    final names = <String>{};
    var total = 0;
    try {
      final archive = ZipDecoder().decodeStream(source);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        if (entry.isSymbolicLink) {
          throw const FormatException('لینک نمادین مجاز نیست.');
        }
        final raw = entry.name.replaceAll('\\', '/');
        if (raw.startsWith('/') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(raw) ||
            raw.split('/').any((s) => s == '.' || s == '..' || s.isEmpty)) {
          throw const FormatException('مسیر ناامن در فایل ZIP.');
        }
        final parts = raw.split('/');
        final name = parts.last;
        if (parts.length > 2 ||
            !requiredFiles.contains(name) ||
            !names.add(name)) {
          throw const FormatException('فایل اضافی یا تکراری در ZIP.');
        }
        if (entry.size <= 0 || total + entry.size > maxUnpackedBytes) {
          throw const FormatException('حجم بسته از سقف مجاز بیشتر است.');
        }
        total += entry.size;
        final file = File(p.join(dest, name));
        final output = OutputFileStream(file.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (file.lengthSync() != entry.size) {
          throw const FormatException('فایل ناقص استخراج شد.');
        }
      }
      if (!names.containsAll(requiredFiles)) {
        throw const FormatException('بسته مدل Pocket ناقص است.');
      }
    } finally {
      source.closeSync();
    }
  }

  static Future<String> manifestFingerprint({Directory? appFiles}) async {
    final dir = await destination(appFiles: appFiles);
    final file = File(p.join(dir.path, 'manifest.json'));
    if (!await file.exists()) throw const FormatException('مدل نصب نشده است.');
    return sha256.convert(await file.readAsBytes()).toString();
  }
}
