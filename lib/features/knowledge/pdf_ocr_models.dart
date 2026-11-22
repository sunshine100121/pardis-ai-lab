import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Explicit, one-time owner setup. These official Tesseract fast models are
/// required only for OCR; ordinary PDF and Qwen use remains fully offline.
/// We verify the Git blob SHA-1 AND exact byte size of each fixed revision.
class PdfOcrModels {
  static const revision = '87416418657359cb625c412a48b6e1d6d41c29bd';
  static const models = {
    'fas': (bytes: 431500, blob: '1a17ee02076107e73abd15d2038389150c8f824f'),
    'eng': (bytes: 4113088, blob: 'bbef4675053b5b468cdb477053e28b1c698ba08e'),
  };

  static Future<Directory> dataDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'pala-pdf-ocr'));
  }

  static Future<bool> ready() async {
    final root = await dataDirectory();
    for (final item in models.entries) {
      if (!await _verified(
        File(path.join(root.path, 'tessdata', '${item.key}.traineddata')),
        item.value.bytes,
        item.value.blob,
      )) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> _verified(File file, int length, String blob) async {
    try {
      if (!await file.exists() || await file.length() != length) return false;
      // Official models are below 5 MiB; one bounded buffer avoids depending
      // on an unpinned chunked-hash sink implementation.
      final bytes = await file.readAsBytes();
      if (bytes.length != length) return false;
      final gitBlob = <int>[
        ...utf8.encode('blob $length\x00'),
        ...bytes,
      ];
      return sha1.convert(gitBlob).toString() == blob;
    } catch (_) {
      return false;
    }
  }

  /// Called only after the user explicitly chooses "prepare Persian OCR".
  /// Never sends a PDF, question, image or private data to the internet.
  /// Failed/changed downloads are discarded; no unverified model is used.
  static Future<Directory> prepare({
    void Function(String language, int received, int total)? onProgress,
    HttpClient Function()? clientFactory,
  }) async {
    final root = await dataDirectory();
    final modelsDir = Directory(path.join(root.path, 'tessdata'));
    await modelsDir.create(recursive: true);
    final client = (clientFactory ?? HttpClient.new)();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      for (final item in models.entries) {
        final file = File(path.join(modelsDir.path, '${item.key}.traineddata'));
        if (await _verified(file, item.value.bytes, item.value.blob)) continue;
        final temp = File('${file.path}.partial');
        if (await temp.exists()) await temp.delete();
        try {
          final url = Uri.https(
            'raw.githubusercontent.com',
            '/tesseract-ocr/tessdata_fast/$revision/${item.key}.traineddata',
          );
          final request = await client.getUrl(url);
          request.followRedirects = false;
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            throw StateError('دریافت مدل OCR ${item.key} انجام نشد');
          }
          var received = 0;
          final sink = temp.openWrite();
          try {
            await for (final chunk in response) {
              received += chunk.length;
              if (received > item.value.bytes) {
                throw StateError('اندازه مدل OCR غیرمجاز است');
              }
              sink.add(chunk);
              onProgress?.call(item.key, received, item.value.bytes);
            }
          } finally {
            await sink.close();
          }
          if (received != item.value.bytes ||
              !await _verified(temp, item.value.bytes, item.value.blob)) {
            throw StateError('مدل OCR با نسخه رسمی مطابقت ندارد');
          }
          if (await file.exists()) await file.delete();
          await temp.rename(file.path);
        } catch (_) {
          if (await temp.exists()) await temp.delete();
          rethrow;
        }
      }
      return root;
    } finally {
      client.close(force: true);
    }
  }
}
