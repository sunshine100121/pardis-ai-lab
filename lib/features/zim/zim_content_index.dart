import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'zim_content_batches.dart';

/// A derived local index; the caller owns the database and opens it in private
/// app storage. No archive paths or source files are copied into it.
///
/// This is not yet connected to chat or to an index-management UI. Its byte
/// limits count UTF-8 text and SQLite pages; temporary journals and free disk
/// space need an additional platform-specific check before production use.
class ZimContentIndex {
  final Database db;
  final int maxTextBytes, maxDatabaseBytes;
  ZimContentIndex(
    this.db, {
    this.maxTextBytes = 64 * 1024 * 1024,
    this.maxDatabaseBytes = 256 * 1024 * 1024,
  }) {
    if (maxTextBytes < 1 || maxDatabaseBytes < 1)
      throw ArgumentError('Invalid index quota');
    db.execute(
      'CREATE TABLE IF NOT EXISTS zim_index_sources ('
      'source_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, '
      'cursor INTEGER NOT NULL, total INTEGER NOT NULL, '
      'skipped INTEGER NOT NULL, text_bytes INTEGER NOT NULL)',
    );
  }

  int get databaseBytes {
    final pages = db.select('PRAGMA page_count').single.values.first as int;
    final size = db.select('PRAGMA page_size').single.values.first as int;
    return pages * size;
  }

  static void _checkId(String id) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id))
      throw ArgumentError('Invalid source id');
  }

  static String fingerprint({
    required String archiveId,
    required int size,
    required int modified,
  }) {
    if (archiveId.isEmpty || size < 0 || modified < 0)
      throw ArgumentError('Invalid archive identity');
    return sha256
        .convert(utf8.encode(jsonEncode([archiveId, size, modified])))
        .toString();
  }

  /// Missing or changed sources fail closed. A stale index is never silently
  /// deleted or used for a different file revision.
  ({int cursor, int total, int skipped, int textBytes})? progress(
    String id,
    String fingerprint,
  ) {
    _checkId(id);
    _checkId(fingerprint);
    final rows = db.select(
      'SELECT fingerprint,cursor,total,skipped,text_bytes '
      'FROM zim_index_sources WHERE source_id=?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['fingerprint'] != fingerprint)
      throw StateError('نسخه منبع تغییر کرده است');
    return (
      cursor: row['cursor'] as int,
      total: row['total'] as int,
      skipped: row['skipped'] as int,
      textBytes: row['text_bytes'] as int,
    );
  }

  /// Commits passages and cursor together. Replaying an old batch is refused.
  /// Synchronous writes mean project scope cannot change between the final
  /// permission check and the transaction on the same Dart isolate.
  void commit({
    required String sourceId,
    required String fingerprint,
    required int expectedCursor,
    required ZimContentBatch batch,
    required bool Function() allowed,
  }) {
    _checkId(sourceId);
    _checkId(fingerprint);
    if (!allowed()) throw StateError('منبع مجاز نیست');
    if (expectedCursor < 0 ||
        batch.total < 0 ||
        batch.next < expectedCursor ||
        batch.next > batch.total ||
        batch.skipped < 0) {
      throw ArgumentError('Invalid content batch');
    }
    var last = expectedCursor - 1;
    var addedBytes = 0;
    for (final article in batch.articles) {
      if (article.entry <= last ||
          article.entry >= batch.next ||
          article.text.isEmpty) {
        throw ArgumentError('Invalid content batch entries');
      }
      last = article.entry;
      addedBytes +=
          utf8.encode(article.title).length + utf8.encode(article.text).length;
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final old = progress(sourceId, fingerprint);
      if ((old?.cursor ?? 0) != expectedCursor ||
          (old != null && old.total != batch.total)) {
        throw StateError('موقعیت نمایه تغییر کرده است');
      }
      final totalBytes =
          db
                  .select(
                    'SELECT COALESCE(SUM(text_bytes),0) AS total FROM zim_index_sources',
                  )
                  .single['total']
              as int;
      if (totalBytes + addedBytes > maxTextBytes)
        throw StateError('سقف متن نمایه پر است');
      if (!allowed()) throw StateError('محدوده منابع تغییر کرد');
      // One FTS table per opaque source id: a MATCH operation never searches
      // the postings of an unselected source, even inside SQLite's planner.
      final table = 'zim_fts_$sourceId';
      db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS $table USING fts5('
        'entry_id UNINDEXED, title, body)',
      );
      for (final article in batch.articles) {
        db.execute('INSERT INTO $table(entry_id,title,body) VALUES(?,?,?)', [
          article.entry,
          article.title,
          article.text,
        ]);
      }
      db.execute(
        'INSERT INTO zim_index_sources(source_id,fingerprint,cursor,total,skipped,text_bytes) '
        'VALUES(?,?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET '
        'cursor=excluded.cursor, skipped=excluded.skipped, text_bytes=excluded.text_bytes',
        [
          sourceId,
          fingerprint,
          batch.next,
          batch.total,
          (old?.skipped ?? 0) + batch.skipped,
          (old?.textBytes ?? 0) + addedBytes,
        ],
      );
      if (databaseBytes > maxDatabaseBytes) {
        throw StateError('سقف صفحات پایگاه نمایه پر است');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Searches only the supplied, already-authorized source revisions.
  /// Query terms are lexical; translating questions is a separate step.
  List<({String sourceId, int entry, String title, String text})> search(
    String query,
    Map<String, String> authorized, {
    int limit = 4,
  }) {
    if (limit < 1 || limit > 20) throw ArgumentError('Invalid result limit');
    final ids = <String>[];
    for (final item in authorized.entries) {
      if (progress(item.key, item.value) != null) ids.add(item.key);
    }
    final terms = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(query.toLowerCase())
        .map((m) => m.group(0)!)
        .where((s) => s.length > 1)
        .toSet()
        .take(12)
        .toList();
    if (ids.isEmpty || terms.isEmpty) return const [];
    final expression = terms.map((word) => '"$word"*').join(' OR ');
    final ranked =
        <(double, ({String sourceId, int entry, String title, String text}))>[];
    for (final id in ids) {
      final table = 'zim_fts_$id';
      final rows = db.select(
        'SELECT entry_id,title,body,bm25($table) AS rank FROM $table '
        'WHERE $table MATCH ? ORDER BY rank LIMIT ?',
        [expression, limit],
      );
      for (final row in rows) {
        ranked.add((
          (row['rank'] as num).toDouble(),
          (
            sourceId: id,
            entry: int.parse('${row['entry_id']}'),
            title: row['title'] as String,
            text: row['body'] as String,
          ),
        ));
      }
    }
    ranked.sort((a, b) => a.$1.compareTo(b.$1));
    return ranked.take(limit).map((r) => r.$2).toList();
  }
}
