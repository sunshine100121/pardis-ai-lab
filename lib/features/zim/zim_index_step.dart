import '../knowledge/folder_library.dart';
import 'zim_content_batches.dart';
import 'zim_content_index.dart';
import 'zim_source.dart';

/// One explicitly requested indexing step; it neither schedules itself nor
/// broadens the caller's source authorization. The caller must recheck free
/// storage and the selected file metadata on every invocation.
class ZimIndexStep {
  final ZimContentIndex index;
  const ZimIndexStep(this.index);

  Future<({int cursor, int total, int skipped, bool cancelled})> run({
    required String uri,
    required int size,
    required int modified,
    required bool Function() allowed,
    required Future<bool> Function() sourceUnchanged,
    required Future<bool> Function() hasStorageHeadroom,
    Future<ZimSource> Function(String)? openSource,
    bool Function()? cancelled,
    int limit = 16,
  }) async {
    void checkScope() {
      if (!allowed()) throw StateError('منبع خارج از محدوده پروژه است');
    }

    checkScope();
    if (size < 0 || modified < 0)
      throw ArgumentError('Invalid source metadata');
    if (cancelled?.call() == true) {
      throw StateError('نمایه‌سازی پیش از شروع متوقف شد');
    }
    if (!await hasStorageHeadroom())
      throw StateError('فضای کافی برای نمایه‌سازی تأیید نشد');
    checkScope();
    if (!await sourceUnchanged())
      throw StateError('مشخصات منبع تغییر کرده است');
    checkScope();
    final reader = await ZimContentBatches.open(
      uri,
      allowed: allowed,
      openSource: (path) async {
        checkScope();
        final source = await (openSource ?? ZimSource.open)(path);
        try {
          if (await source.length() != size)
            throw StateError('اندازه منبع تغییر کرده است');
          checkScope();
          return source;
        } catch (_) {
          await source.close();
          rethrow;
        }
      },
    );
    try {
      checkScope();
      final id = FolderLibrary.sourceId(uri);
      final fingerprint = ZimContentIndex.fingerprint(
        archiveId: reader.archive.identity,
        size: size,
        modified: modified,
      );
      final before = index.progress(id, fingerprint);
      final cursor = before?.cursor ?? 0;
      if (before != null && before.total != reader.archive.entryCount) {
        throw StateError('تعداد مدخل‌های منبع تغییر کرده است');
      }
      final batch = await reader.read(
        cursor: cursor,
        limit: limit,
        cancelled: cancelled,
      );
      checkScope();
      if (!await sourceUnchanged())
        throw StateError('مشخصات منبع تغییر کرده است');
      checkScope();
      if (!await hasStorageHeadroom())
        throw StateError('فضای کافی برای نمایه‌سازی تأیید نشد');
      checkScope();
      if (!await sourceUnchanged())
        throw StateError('مشخصات منبع تغییر کرده است');
      checkScope();
      if (batch.next != cursor) {
        index.commit(
          sourceId: id,
          fingerprint: fingerprint,
          expectedCursor: cursor,
          batch: batch,
          allowed: allowed,
        );
      }
      final progress = index.progress(id, fingerprint);
      return (
        cursor: progress?.cursor ?? cursor,
        total: reader.archive.entryCount,
        skipped: progress?.skipped ?? 0,
        cancelled: batch.cancelled,
      );
    } finally {
      await reader.close();
    }
  }
}
