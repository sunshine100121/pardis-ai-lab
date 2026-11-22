import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Rebuildable, private page-text index. Never edits or copies the source PDF.
/// A revision is searchable only when EVERY page was inspected and committed.
class PdfPageIndex {
  final Database db;
  final int maxDatabaseBytes;
  final int maxPageBytes;

  PdfPageIndex(
    this.db, {
    this.maxDatabaseBytes = 256 * 1024 * 1024,
    this.maxPageBytes = 128 * 1024,
  }) {
    if (maxDatabaseBytes <= 0 || maxPageBytes <= 0) {
      throw ArgumentError('Invalid PDF index quota');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS pala_pdf_documents (
        id TEXT PRIMARY KEY,
        size_bytes INTEGER NOT NULL,
        modified INTEGER NOT NULL,
        total_pages INTEGER NOT NULL,
        next_page INTEGER NOT NULL DEFAULT 1,
        pages_with_text INTEGER NOT NULL DEFAULT 0,
        needs_ocr INTEGER NOT NULL DEFAULT 0,
        complete INTEGER NOT NULL DEFAULT 0
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS pala_pdf_pages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL,
        page INTEGER NOT NULL,
        text TEXT NOT NULL,
        UNIQUE(source_id, page)
      )
    ''');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS pala_pdf_fts
      USING fts5(normalized, tokenize='unicode61')
    ''');
  }

  static String normalize(String value) => value
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  ({int nextPage, int totalPages, bool complete, int needsOcr})? status(
    String sourceId, {
    required int size,
    required int modified,
  }) {
    final rows = db.select(
      'SELECT * FROM pala_pdf_documents WHERE id = ?',
      [sourceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['size_bytes'] != size || row['modified'] != modified) {
      return null;
    }
    return (
      nextPage: row['next_page'] as int,
      totalPages: row['total_pages'] as int,
      complete: row['complete'] == 1,
      needsOcr: row['needs_ocr'] as int,
    );
  }

  /// Initialize or resume a revision. If the original file changed, its old
  /// derived index is removed before any new result can be returned.
  void begin({
    required String sourceId,
    required int size,
    required int modified,
    required int totalPages,
  }) {
    if (size <= 0 || totalPages <= 0 || sourceId.isEmpty) {
      throw ArgumentError('Invalid source revision');
    }
    final previous = status(sourceId, size: size, modified: modified);
    if (previous != null && previous.totalPages == totalPages) return;
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'DELETE FROM pala_pdf_fts WHERE rowid IN '
        '(SELECT id FROM pala_pdf_pages WHERE source_id = ?)',
        [sourceId],
      );
      db.execute('DELETE FROM pala_pdf_pages WHERE source_id = ?', [sourceId]);
      db.execute('DELETE FROM pala_pdf_documents WHERE id = ?', [sourceId]);
      db.execute(
        'INSERT INTO pala_pdf_documents '
        '(id,size_bytes,modified,total_pages,next_page,complete) '
        'VALUES (?,?,?,?,1,0)',
        [sourceId, size, modified, totalPages],
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Commit a short, ordered batch. A crash can lose the current batch only.
  /// Empty text marks a page requiring OCR, not a fictitious search result.
  void append({
    required String sourceId,
    required int size,
    required int modified,
    required List<({int page, String text})> pages,
  }) {
    if (pages.isEmpty || pages.length > 16) {
      throw ArgumentError('Use 1..16 PDF pages per transaction');
    }
    final current = status(sourceId, size: size, modified: modified);
    if (current == null || current.complete) {
      throw StateError('PDF index revision is missing or already complete');
    }
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].page != current.nextPage + i) {
        throw StateError('Noncontiguous PDF page batch');
      }
      if (utf8.encode(pages[i].text).length > maxPageBytes) {
        throw StateError('PDF page exceeds bounded text quota');
      }
    }
    if (pages.last.page > current.totalPages) {
      throw StateError('Page outside PDF');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      var textPages = 0, ocrPages = 0;
      for (final item in pages) {
        final clean = item.text.trim();
        if (clean.isEmpty) {
          ocrPages++;
        } else {
          textPages++;
        }
        db.execute(
          'INSERT INTO pala_pdf_pages (source_id,page,text) VALUES (?,?,?)',
          [sourceId, item.page, clean],
        );
        if (clean.isNotEmpty) {
          final id = db.lastInsertRowId;
          db.execute(
            'INSERT INTO pala_pdf_fts (rowid,normalized) VALUES (?,?)',
            [id, normalize(clean)],
          );
        }
      }
      final nextPage = pages.last.page + 1;
      db.execute(
        'UPDATE pala_pdf_documents SET next_page = ?, '
        'pages_with_text = pages_with_text + ?, '
        'needs_ocr = needs_ocr + ?, complete = ? WHERE id = ?',
        [
          nextPage,
          textPages,
          ocrPages,
          nextPage > current.totalPages ? 1 : 0,
          sourceId,
        ],
      );
      final used = db.select('PRAGMA page_count').single.values.first as int;
      final pageSize = db.select('PRAGMA page_size').single.values.first as int;
      if (used * pageSize > maxDatabaseBytes) {
        throw StateError('PDF index storage cap reached');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Only complete and revision-matching indexes can be queried.
  /// Quoted phrases take priority. All other terms are literal FTS tokens.
  List<({int page, String text})> search({
    required String sourceId,
    required int size,
    required int modified,
    required String query,
    int limit = 4,
  }) {
    final state = status(sourceId, size: size, modified: modified);
    if (state == null || !state.complete || limit < 1 || limit > 12) {
      return [];
    }
    final quoted = RegExp(r'[«\u201c"]([^»\u201d"]{4,})[»\u201d"]')
        .firstMatch(query);
    final clean = normalize(quoted?.group(1) ?? query);
    final terms = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true)
        .allMatches(clean)
        .map((m) => m.group(0)!)
        .toSet()
        .take(24)
        .toList();
    if (terms.isEmpty) return [];
    // The FTS grammar is assembled from quoted normalized tokens only.
    // Never interpolate an untrusted raw MATCH expression.
    final expression = quoted != null
        ? '"${terms.join(' ')}"'
        : terms.map((t) => '"$t"').join(' OR ');
    final rows = db.select('''
      SELECT p.page AS page, p.text AS text
      FROM pala_pdf_fts
      JOIN pala_pdf_pages p ON p.id = pala_pdf_fts.rowid
      WHERE pala_pdf_fts MATCH ? AND p.source_id = ?
      ORDER BY bm25(pala_pdf_fts)
      LIMIT ?
    ''', [expression, sourceId, limit]);
    return [
      for (final row in rows)
        (page: row['page'] as int, text: row['text'] as String),
    ];
  }

  /// May be called when a file is disabled or its SAF permission is revoked.
  void discard(String sourceId) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'DELETE FROM pala_pdf_fts WHERE rowid IN '
        '(SELECT id FROM pala_pdf_pages WHERE source_id = ?)',
        [sourceId],
      );
      db.execute('DELETE FROM pala_pdf_pages WHERE source_id = ?', [sourceId]);
      db.execute('DELETE FROM pala_pdf_documents WHERE id = ?', [sourceId]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
