import 'dart:async';

import 'package:sqlite3/sqlite3.dart';

import '../knowledge/folder_library.dart';
import 'zim_content_index.dart';
import 'zim_content_batches.dart';
import 'zim_index_step.dart';
import 'zim_index_storage.dart';

/// Owner-triggered, one-source indexing. It does not schedule background work
/// or widen project scope. The caller must keep [allowed] current as project
/// selections change and may stop between or during batches.
class ZimIndexService {
  final FolderLibrary library;
  final ZimIndexStorage storage;
  bool _running = false, _stop = false;
  ZimIndexService(this.library, this.storage);
  bool get running => _running;
  void stop() => _stop = true;

  Future<({int cursor, int total, int skipped, bool cancelled})> run({
    required String uri,
    required bool Function() allowed,
    void Function(int cursor, int total, int skipped)? onProgress,
    int entriesPerBatch = 16,
  }) async {
    if (_running) throw StateError('نمایه‌سازی دیگری در حال اجراست');
    if (!allowed()) throw StateError('منبع خارج از محدوده پروژه است');
    if (entriesPerBatch < 1 ||
        entriesPerBatch > ZimContentBatches.maxEntriesPerBatch) {
      throw ArgumentError('Invalid batch size');
    }
    _running = true;
    _stop = false;
    Database? db;
    try {
      if (!await storage.hasHeadroom())
        throw StateError('فضای کافی برای نمایه‌سازی تأیید نشد');
      if (!allowed()) throw StateError('محدوده منابع تغییر کرد');
      final state = await library.state();
      final entries = (state['files'] as List)
          .whereType<Map>()
          .where((row) => row['uri'] == uri && row['enabled'] == true)
          .toList();
      if (entries.length != 1 ||
          entries.single['name'] is! String ||
          !(entries.single['name'] as String).toLowerCase().endsWith('.zim')) {
        throw StateError('دانشنامه فعال و یکتا پیدا نشد');
      }
      final row = entries.single;
      final size = (row['size'] as num).toInt();
      final modified = (row['modified'] as num).toInt();
      Future<bool> unchanged() async {
        if (!allowed()) return false;
        final current = await library.state();
        final selected = (current['files'] as List)
            .whereType<Map>()
            .where(
              (r) =>
                  r['uri'] == uri &&
                  r['enabled'] == true &&
                  r['size'] == size &&
                  r['modified'] == modified,
            )
            .toList();
        if (selected.length != 1) return false;
        final live = await library.access.list();
        return live.files
                .where(
                  (f) =>
                      f.uri == uri &&
                      f.size == size &&
                      f.modified == modified &&
                      f.name == row['name'],
                )
                .length ==
            1;
      }

      if (!await unchanged() || !allowed())
        throw StateError('مشخصات منبع تغییر کرده است');
      if (!await storage.hasHeadroom())
        throw StateError('فضای کافی برای نمایه‌سازی تأیید نشد');
      if (!allowed()) throw StateError('محدوده منابع تغییر کرد');
      if (_stop) return (cursor: 0, total: 0, skipped: 0, cancelled: true);
      db = sqlite3.open(storage.indexPath);
      final index = ZimContentIndex(
        db,
        maxDatabaseBytes: storage.maxDatabaseBytes,
        maxTextBytes: (storage.maxDatabaseBytes ~/ 2).clamp(1, storage.maxDatabaseBytes),
      );
      final step = ZimIndexStep(index);
      var result = (cursor: 0, total: 0, skipped: 0, cancelled: false);
      while (!_stop) {
        result = await step.run(
          uri: uri,
          size: size,
          modified: modified,
          allowed: allowed,
          sourceUnchanged: unchanged,
          hasStorageHeadroom: storage.hasHeadroom,
          openSource: library.access.open,
          cancelled: () => _stop,
          limit: entriesPerBatch,
        );
        onProgress?.call(result.cursor, result.total, result.skipped);
        if (result.cancelled || result.cursor >= result.total) break;
        await Future<void>.delayed(Duration.zero);
      }
      return (
        cursor: result.cursor,
        total: result.total,
        skipped: result.skipped,
        cancelled: result.cancelled || _stop,
      );
    } finally {
      db?.close();
      _running = false;
    }
  }
}
