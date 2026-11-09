import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Read-only, seekable storage. No import, cache file or write fallback.
abstract interface class ZimSource {
  Future<Uint8List> readAt(int offset, int count);
  Future<int> length();
  Future<void> close();
  static Future<ZimSource> open(String location) async =>
      location.startsWith('content:')
          ? AndroidZimSource.open(location)
          : FileZimSource(await File(location).open(mode: FileMode.read));
}

class FileZimSource implements ZimSource {
  final RandomAccessFile file;
  FileZimSource(this.file);
  @override
  Future<Uint8List> readAt(int offset, int count) async {
    await file.setPosition(offset);
    return file.read(count);
  }
  @override
  Future<int> length() => file.length();
  @override
  Future<void> close() async { await file.close(); }
}

class AndroidZimSource implements ZimSource {
  static const channel = MethodChannel('pala/documents');
  final int handle, size;
  bool _closed = false;
  AndroidZimSource._(this.handle, this.size);
  static Future<AndroidZimSource> open(String uri) async {
    final m = (await channel.invokeMapMethod<String, Object?>('open', uri))!;
    return AndroidZimSource._((m['handle'] as num).toInt(), (m['size'] as num).toInt());
  }
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAt(int offset, int count) async {
    if (_closed) throw StateError('ZIM source closed');
    if (offset < 0 || count < 0) throw RangeError('ZIM range');
    final builder = BytesBuilder(copy: false);
    var at = offset;
    var left = count;
    while (left > 0 && at < size) {
      final n = [left, 1024 * 1024, size - at].reduce((a, b) => a < b ? a : b);
      final bytes = (await channel.invokeMethod<Uint8List>('read', {
        'handle': handle, 'offset': at, 'count': n,
      }))!;
      if (bytes.isEmpty) break;
      builder.add(bytes);
      at += bytes.length;
      left -= bytes.length;
    }
    return builder.takeBytes();
  }
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await channel.invokeMethod<void>('close', handle);
  }
}
