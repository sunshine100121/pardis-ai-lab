import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../data/storage/model_storage.dart';

/// Two installed adapters: NeMo-CTC (e.g. Persian Shenava) and Piper VITS.
/// The models are data packs, never executable plugins.
enum PersianSherpaKind { stt, tts }

class PersianSherpaModel {
  final String id;
  final String label;
  final Directory directory;
  final String onnxFile;
  final PersianSherpaKind kind;

  const PersianSherpaModel({
    required this.id,
    required this.label,
    required this.directory,
    required this.onnxFile,
    required this.kind,
  });

  String get selectionId =>
      '${kind == PersianSherpaKind.stt ? 'stt:sherpa-ctc' : 'tts:piper'}:$id';
  String get modelPath => p.join(directory.path, onnxFile);
  String get tokensPath => p.join(directory.path, 'tokens.txt');
  String get espeakPath => p.join(directory.path, 'espeak-ng-data');
}

/// Import-only library. No network requests and no automatic model download.
/// The pinned sherpa_onnx dependency provides the actual inference runtime.
abstract final class PersianSherpaModels {
  static const _prefix = 'pala-sherpa-';
  static const _meta = '.pala-sherpa.json';
  static const maxArchiveBytes = 1500000000;
  static const maxUnpackedBytes = 3500000000;
  static final _modelId = RegExp(r'^[a-f0-9]{16}$');

  static Future<Directory> _root(Directory? given) async {
    final root = given ?? await ModelStorage.modelsDir();
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static String _folderName(PersianSherpaKind kind, String id) =>
      '$_prefix${kind.name}-$id';

  static Future<PersianSherpaModel?> _inspect(
    Directory dir,
    PersianSherpaKind kind,
    String id,
  ) async {
    if (!_modelId.hasMatch(id)) return null;
    final file = File(p.join(dir.path, _meta));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['kind'] != kind.name ||
          decoded['sha256'] is! String ||
          !(decoded['sha256'] as String).startsWith(id) ||
          decoded['model'] is! String) {
        return null;
      }
      final onnx = decoded['model'] as String;
      if (p.basename(onnx) != onnx || !onnx.endsWith('.onnx')) return null;
      final model = File(p.join(dir.path, onnx));
      final tokens = File(p.join(dir.path, 'tokens.txt'));
      if (!await model.exists() ||
          !await tokens.exists() ||
          await model.length() == 0 ||
          await tokens.length() == 0) {
        return null;
      }
      if (kind == PersianSherpaKind.tts &&
          !await File(p.join(dir.path, 'espeak-ng-data', 'phontab')).exists()) {
        return null;
      }
      final label = decoded['label'] is String ? decoded['label'] as String : '';
      return PersianSherpaModel(
        id: id,
        label: label.isEmpty ? '${kind.name} $id' : label,
        directory: dir,
        onnxFile: onnx,
        kind: kind,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<PersianSherpaModel?> find(
    PersianSherpaKind kind,
    String id, {
    Directory? root,
  }) async {
    if (!_modelId.hasMatch(id)) return null;
    final parent = await _root(root);
    return _inspect(
      Directory(p.join(parent.path, _folderName(kind, id))),
      kind,
      id,
    );
  }

  static Future<List<PersianSherpaModel>> installed(
    PersianSherpaKind kind, {
    Directory? root,
  }) async {
    final parent = await _root(root);
    final found = <PersianSherpaModel>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final prefix = '$_prefix${kind.name}-';
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix)) continue;
      final model = await _inspect(entity, kind, name.substring(prefix.length));
      if (model != null) found.add(model);
    }
    found.sort((a, b) => a.label.compareTo(b.label));
    return found;
  }

  /// Accept ZIP or official sherpa-onnx .tar.bz2 model archives selected by
  /// the owner. This does not change or delete the stock Vosk/Whisper packs.
  static Future<PersianSherpaModel> importArchive(
    File archiveFile,
    PersianSherpaKind kind, {
    Directory? root,
    String? label,
  }) async {
    if (!await archiveFile.exists()) {
      throw const FormatException('بسته انتخاب‌شده پیدا نشد.');
    }
    final fileName = archiveFile.path.toLowerCase();
    if (!(fileName.endsWith('.zip') || fileName.endsWith('.tar.bz2'))) {
      throw const FormatException('بسته باید ZIP یا TAR.BZ2 باشد.');
    }
    final bytes = await archiveFile.length();
    if (bytes <= 0 || bytes > maxArchiveBytes) {
      throw const FormatException('اندازه بسته مدل مجاز نیست.');
    }
    final hash = (await sha256.bind(archiveFile.openRead()).first).toString();
    final id = hash.substring(0, 16);
    final parent = await _root(root);
    final target = Directory(p.join(parent.path, _folderName(kind, id)));
    final present = await find(kind, id, root: parent);
    if (present != null) return present;
    if (await target.exists()) {
      throw const FormatException('پوشه ناقص مدل موجود است؛ جایگزینی انجام نشد.');
    }
    final stage = await Directory(
      p.join(parent.path, '.pala-sherpa-stage-$id-${DateTime.now().microsecondsSinceEpoch}'),
    ).create();
    try {
      await Isolate.run(() => _extract(archiveFile.path, stage.path));
      final tokens = File(p.join(stage.path, 'tokens.txt'));
      if (!await tokens.exists() || await tokens.length() == 0) {
        throw const FormatException('فایل واژگان tokens.txt وجود ندارد.');
      }
      final onnxFiles = <String>[];
      await for (final item in stage.list(followLinks: false)) {
        if (item is File && item.path.endsWith('.onnx')) {
          onnxFiles.add(p.basename(item.path));
        }
      }
      if (onnxFiles.length != 1 ||
          await File(p.join(stage.path, onnxFiles.single)).length() == 0) {
        throw const FormatException('بسته باید دقیقاً یک مدل ONNX معتبر داشته باشد.');
      }
      if (kind == PersianSherpaKind.stt && onnxFiles.single != 'model.onnx') {
        throw const FormatException('بسته شنوا باید model.onnx داشته باشد.');
      }
      if (kind == PersianSherpaKind.tts &&
          !await File(p.join(stage.path, 'espeak-ng-data', 'phontab')).exists()) {
        throw const FormatException('بسته Piper به espeak-ng-data نیاز دارد.');
      }
      final text = (label ?? p.basename(archiveFile.path)).trim();
      await File(p.join(stage.path, _meta)).writeAsString(jsonEncode({
        'kind': kind.name,
        'model': onnxFiles.single,
        'sha256': hash,
        'label': text.length > 72 ? text.substring(0, 72) : text,
      }));
      if (await target.exists()) {
        throw const FormatException('مدل هم‌زمان اضافه شد؛ فایلی جایگزین نشد.');
      }
      await stage.rename(target.path);
      final imported = await find(kind, id, root: parent);
      if (imported == null) {
        throw const FormatException('مدل پس از ورود قابل استفاده نیست.');
      }
      return imported;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static void _extract(String inputPath, String outputPath) {
    final isZip = inputPath.toLowerCase().endsWith('.zip');
    final tarFile = '$outputPath.tmp.tar';
    if (!isZip) {
      final input = InputFileStream(inputPath);
      final output = OutputFileStream(tarFile);
      try {
        BZip2Decoder().decodeStream(input, output);
      } finally {
        input.closeSync();
        output.closeSync();
      }
      if (File(tarFile).lengthSync() > maxUnpackedBytes) {
        File(tarFile).deleteSync();
        throw const FormatException('اندازه فایل بازشده بیش از حد مجاز است.');
      }
    }
    final source = InputFileStream(isZip ? inputPath : tarFile);
    final names = <String>{};
    var total = 0;
    try {
      final archive = isZip
          ? ZipDecoder().decodeStream(source)
          : TarDecoder().decodeStream(source);
      for (final item in archive) {
        if (!item.isFile) continue;
        if (item.isSymbolicLink) {
          throw const FormatException('لینک نمادین داخل بسته مجاز نیست.');
        }
        final raw = item.name.replaceAll('\\', '/');
        if (raw.startsWith('/') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(raw) ||
            raw.split('/').any((part) => part == '..' || part == '.')) {
          throw const FormatException('مسیر ناامن در بسته مدل.');
        }
        final parts = raw.split('/');
        final rootFiles = raw == 'tokens.txt' ||
            raw == 'model.onnx' ||
            raw.startsWith('espeak-ng-data/') ||
            (parts.length == 1 && raw.endsWith('.onnx'));
        final relative = rootFiles
            ? raw
            : (parts.length > 1 ? parts.skip(1).join('/') : '');
        if (relative.isEmpty) continue;
        final clean = p.posix.normalize(relative);
        if (clean == '..' ||
            clean.startsWith('../') ||
            clean.startsWith('/') ||
            !names.add(clean) ||
            names.length > 15000) {
          throw const FormatException('مسیر تکراری یا نامعتبر در بسته مدل.');
        }
        total += item.size;
        if (item.size < 0 || total > maxUnpackedBytes) {
          throw const FormatException('اندازه بسته استخراج‌شده غیرمجاز است.');
        }
        final file = File(p.join(outputPath, clean));
        file.parent.createSync(recursive: true);
        final output = OutputFileStream(file.path);
        try {
          item.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (file.lengthSync() != item.size) {
          throw const FormatException('فایل مدل ناقص استخراج شد.');
        }
      }
    } finally {
      source.closeSync();
      if (!isZip && File(tarFile).existsSync()) File(tarFile).deleteSync();
    }
  }

  static Future<void> delete(
    PersianSherpaKind kind,
    String id, {
    Directory? root,
  }) async {
    final model = await find(kind, id, root: root);
    if (model == null) throw const FormatException('مدل معتبر پیدا نشد.');
    await model.directory.delete(recursive: true);
  }
}
