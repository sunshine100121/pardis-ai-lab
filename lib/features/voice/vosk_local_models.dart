import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../data/storage/model_storage.dart';

class VoskLocalModel {
  final String id;
  final String name;
  final String path;
  const VoskLocalModel(this.id, this.name, this.path);

  String get selectionId => 'stt:vosk:$id';
}

/// Optional import of the owner's Vosk ZIP packs to an app-private directory.
/// No download, shell execution, network recognizer, or deletion of the stock
/// Persian pack. Each model can be selected independently of other packs.
abstract final class VoskLocalModels {
  static const _prefix = 'pala-vosk-';
  static const _metadata = '.pala-model.json';
  static const _maxArchiveBytes = 1_500_000_000;
  static const _maxUnpackedBytes = 4_000_000_000;
  static final _idFormat = RegExp(r'^[a-f0-9]{16}$');
  static const _required = ['am/final.mdl', 'conf/model.conf'];

  /// Vosk supports either a compact split graph or a compiled static graph.
  /// Do not reject a valid large model solely because it uses HCLG.fst.
  static Future<bool> _modelFilesPresent(Directory dir) async {
    Future<bool> present(String relative) async {
      final file = File(p.join(dir.path, relative));
      return await file.exists() && await file.length() > 0;
    }

    for (final name in _required) {
      if (!await present(name)) return false;
    }
    return await present('graph/HCLG.fst') ||
        (await present('graph/Gr.fst') && await present('graph/HCLr.fst'));
  }

  static Future<Directory> _root(Directory? provided) async {
    final root = provided ?? await ModelStorage.modelsDir();
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static Future<bool> _ready(Directory dir) async {
    if (!await File(p.join(dir.path, _metadata)).exists()) return false;
    return _modelFilesPresent(dir);
  }

  static Future<String?> pathFor(String id, {Directory? root}) async {
    if (!_idFormat.hasMatch(id)) return null;
    final parent = await _root(root);
    final dir = Directory(p.join(parent.path, '$_prefix$id'));
    return await _ready(dir) ? dir.path : null;
  }

  static Future<List<VoskLocalModel>> installed({Directory? root}) async {
    final parent = await _root(root);
    final models = <VoskLocalModel>[];
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(_prefix)) continue;
      final id = name.substring(_prefix.length);
      if (!_idFormat.hasMatch(id) || !await _ready(entry)) continue;
      try {
        final meta = jsonDecode(
          await File(p.join(entry.path, _metadata)).readAsString(),
        );
        if (meta is! Map || meta['sha256'] is! String) continue;
        if (!(meta['sha256'] as String).startsWith(id)) continue;
        final label = meta['name'] is String ? meta['name'] as String : '';
        models.add(
          VoskLocalModel(id, label.isEmpty ? 'Vosk $id' : label, entry.path),
        );
      } catch (_) {
        // Never use an incomplete or damaged model.
      }
    }
    models.sort((a, b) => a.name.compareTo(b.name));
    return models;
  }

  static Future<VoskLocalModel> importZip(
    File archiveFile, {
    Directory? root,
    String? displayName,
  }) async {
    if (!await archiveFile.exists()) {
      throw const FormatException('فایل مدل انتخابی موجود نیست.');
    }
    final size = await archiveFile.length();
    if (size <= 0 || size > _maxArchiveBytes) {
      throw const FormatException('اندازه فایل مدل برای ورود محلی معتبر نیست.');
    }
    final digest = (await sha256.bind(archiveFile.openRead()).first).toString();
    final id = digest.substring(0, 16);
    final parent = await _root(root);
    final target = Directory(p.join(parent.path, '$_prefix$id'));
    final name = (displayName ?? p.basenameWithoutExtension(archiveFile.path))
        .trim();
    final label = name.length > 70 ? name.substring(0, 70) : name;
    if (await target.exists()) {
      if (!await _ready(target)) {
        throw const FormatException(
          'نسخه ناقص مدل موجود است؛ جایگزین خودکار مجاز نیست.',
        );
      }
      return (await installed(root: parent)).firstWhere((m) => m.id == id);
    }
    final stage = await Directory(
      p.join(
        parent.path,
        '.pala-vosk-import-$id-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create();
    try {
      await Isolate.run(() => _extract(archiveFile.path, stage.path));
      if (!await _modelFilesPresent(stage)) {
        throw const FormatException(
          'ساختار فایل Vosk کامل نیست؛ نصب انجام نشد.',
        );
      }
      await File(p.join(stage.path, _metadata)).writeAsString(
        jsonEncode({'name': label, 'sha256': digest, 'archiveBytes': size}),
      );
      if (await target.exists()) {
        throw const FormatException(
          'مدل هم‌زمان وارد شده است؛ هیچ فایلی جایگزین نشد.',
        );
      }
      await stage.rename(target.path);
      return VoskLocalModel(
        id,
        label.isEmpty ? 'Vosk $id' : label,
        target.path,
      );
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  static void _extract(String archivePath, String outPath) {
    final input = InputFileStream(archivePath);
    final seen = <String>{};
    var total = 0;
    try {
      final zip = ZipDecoder().decodeStream(input);
      for (final entry in zip) {
        if (!entry.isFile) continue;
        if (entry.isSymbolicLink) {
          throw const FormatException('لینک نمادین در مدل مجاز نیست.');
        }
        final raw = entry.name.replaceAll('\\', '/');
        if (raw.startsWith('/') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(raw) ||
            raw.split('/').any((part) => part == '..' || part == '.')) {
          throw const FormatException('مسیر ناامن در فایل ZIP یافت شد.');
        }
        final parts = raw.split('/');
        final directlyRooted = const {
          'am',
          'conf',
          'graph',
          'ivector',
          'rescore',
        }.contains(parts.first);
        final relative = directlyRooted
            ? raw
            : (parts.length >= 2 ? parts.skip(1).join('/') : '');
        if (relative.isEmpty) continue;
        final safe = p.posix.normalize(relative);
        if (safe.isEmpty ||
            safe == '..' ||
            safe.startsWith('../') ||
            p.posix.isAbsolute(safe) ||
            !seen.add(safe)) {
          throw const FormatException('فایل تکراری یا مسیر ناامن در مدل.');
        }
        total += entry.size;
        if (entry.size < 0 || total > _maxUnpackedBytes) {
          throw const FormatException(
            'اندازه مدل استخراج‌شده بیش از سقف ایمن است.',
          );
        }
        final file = File(p.join(outPath, safe));
        file.parent.createSync(recursive: true);
        final output = OutputFileStream(file.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (file.lengthSync() != entry.size) {
          throw const FormatException('فایل مدل ناقص استخراج شد.');
        }
      }
    } finally {
      input.closeSync();
    }
  }

  static Future<void> delete(String id, {Directory? root}) async {
    if (!_idFormat.hasMatch(id))
      throw const FormatException('شناسه مدل معتبر نیست.');
    final parent = await _root(root);
    final dir = Directory(p.join(parent.path, '$_prefix$id'));
    if (!await _ready(dir)) throw const FormatException('مدل معتبر پیدا نشد.');
    await dir.delete(recursive: true);
  }
}
