import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/platform/device_info.dart';

/// Conservative headroom check for a derived index stored in Android's
/// app-specific external files directory, matching DeviceStorage's StatFs.
/// It is not a reservation: free space may change after this check.
class ZimIndexStorage {
  static const defaultReserveBytes = 256 * 1024 * 1024;
  final Directory directory;
  final int maxDatabaseBytes, reserveBytes;
  final Future<int?> Function() availableBytes;

  ZimIndexStorage({
    required this.directory,
    required this.availableBytes,
    this.maxDatabaseBytes = 256 * 1024 * 1024,
    this.reserveBytes = defaultReserveBytes,
  }) {
    if (maxDatabaseBytes < 1 || reserveBytes < 0)
      throw ArgumentError('Invalid storage limit');
  }

  /// Android's path provider and native storageInfo use getExternalFilesDir.
  /// On unsupported platforms, or if its directory is absent, fail closed.
  static Future<ZimIndexStorage?> android() async {
    if (!Platform.isAndroid) return null;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null || !await dir.exists()) return null;
      return ZimIndexStorage(
        directory: dir,
        availableBytes: () async =>
            (await DeviceStorage.read())?.availableBytes,
      );
    } catch (_) {
      return null;
    }
  }

  String get indexPath =>
      path.join(directory.path, 'pala-zim-content-index-v1.sqlite');

  Future<bool> hasHeadroom() async {
    try {
      if (!await directory.exists()) return false;
      final free = await availableBytes();
      if (free == null || free < 0) return false;
      // Reserve room for the configured database, a same-sized journal or
      // temporary file, and unrelated device activity. Recheck every batch.
      return free >= reserveBytes + 2 * maxDatabaseBytes;
    } catch (_) {
      return false;
    }
  }
}
