import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../data/network/web_search/search_models.dart';
import '../../inference/engine/llama_engine.dart';
import '../knowledge/folder_library.dart';
import '../settings/domain/entities/inference_settings.dart';
import 'zim_content_index.dart';
import 'zim_index_citations.dart';
import 'zim_index_storage.dart';
import 'zim_query_translation.dart';
import 'zim_wikipedia.dart';

/// Project-only retrieval from an existing derived index. The caller owns the
/// local inference engine and supplies live project authorization.
class ZimIndexedProjectSearch {
  final FolderLibrary library;
  final ZimIndexStorage storage;
  static int _pendingClose = 0;
  ZimIndexedProjectSearch(this.library, this.storage);

  Future<({List<SearchResult> sources, int incomplete, int skipped, int errors})> search({
    required String question,
    required Set<String> sourceIds,
    required bool Function(String sourceId) allowed,
    required bool Function() cancelled,
    required LlamaEngine engine,
    required InferenceSettings settings,
    required String fallbackTemplate,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    const empty = (sources: <SearchResult>[], incomplete: 0, skipped: 0, errors: 0);
    if (sourceIds.isEmpty || cancelled() || !await File(storage.indexPath).exists()) return empty;
    final db = sqlite3.open(storage.indexPath, mode: OpenMode.readWrite);
    try {
      final index = ZimContentIndex(db, maxDatabaseBytes: storage.maxDatabaseBytes);
      final data = await library.state();
      final live = await library.access.list();
      final files = {for (final f in live.files) f.uri: f};
      final authorized = <String, ZimIndexedSource>{};
      final expected = <String, ({String uri, int size, int modified, String name})>{};
      var incomplete = 0, skipped = 0, errors = 0;
      for (final row in (data['files'] as List).whereType<Map>()) {
        final uri = row['uri'];
        if (uri is! String || row['name'] is! String || row['enabled'] != true) continue;
        final id = FolderLibrary.sourceId(uri);
        if (!sourceIds.contains(id) || !allowed(id) || cancelled() || !index.containsSource(id)) continue;
        final file = files[uri];
        if (file == null || file.name != row['name'] || file.size != row['size'] ||
            file.modified != row['modified'] || !file.name.toLowerCase().endsWith('.zim')) {
          errors++;
          continue;
        }
        if (_pendingClose >= 2) { errors++; continue; }
        final wiki = ZimWikipedia(uri, openSource: (path) {
          if (!allowed(id) || cancelled()) throw StateError('محدوده پروژه تغییر کرد');
          return library.access.open(path);
        });
        var timedOut = false;
        try {
          final info = await (() async => (
            id: await wiki.archiveIdentity(), name: await wiki.name(),
            date: await wiki.archiveMetadata('Date'), language: await wiki.archiveMetadata('Language'),
          ))().timeout(timeout);
          if (!allowed(id) || cancelled()) continue;
          final fingerprint = ZimContentIndex.fingerprint(
            archiveId: info.id, size: file.size, modified: file.modified);
          final progress = index.progress(id, fingerprint);
          if (progress == null) continue;
          if (progress.cursor < progress.total) incomplete++;
          skipped += progress.skipped;
          authorized[id] = (fingerprint: fingerprint, archiveId: info.id,
            name: info.name, date: info.date, language: info.language);
          expected[id] = (uri: uri, size: file.size, modified: file.modified, name: file.name);
        } on TimeoutException {
          timedOut = true;
          errors++;
        } catch (_) {
          errors++;
        } finally {
          if (timedOut) {
            _pendingClose++;
            unawaited(wiki.close().whenComplete(() => _pendingClose--));
          } else {
            await wiki.close();
          }
        }
      }
      if (authorized.isEmpty || cancelled()) {
        return (sources: <SearchResult>[], incomplete: incomplete, skipped: skipped, errors: errors);
      }
      final query = await ZimQueryTranslation.englishTerms(question, engine: engine,
        settings: settings, fallbackTemplate: fallbackTemplate, cancelled: cancelled);
      if (query == null) errors++;
      if (cancelled()) return (sources: <SearchResult>[], incomplete: incomplete, skipped: skipped, errors: errors);
      final latest = await library.state();
      final current = await library.access.list();
      for (final id in authorized.keys.toList()) {
        final wanted = expected[id]!;
        final rowCount = (latest['files'] as List).whereType<Map>().where((r) =>
          r['uri'] == wanted.uri && r['enabled'] == true && r['size'] == wanted.size &&
          r['modified'] == wanted.modified && r['name'] == wanted.name).length;
        final liveCount = current.files.where((f) => f.uri == wanted.uri && f.size == wanted.size &&
          f.modified == wanted.modified && f.name == wanted.name).length;
        if (!allowed(id) || cancelled() || rowCount != 1 || liveCount != 1) {
          authorized.remove(id);
          errors++;
        }
      }
      if (cancelled()) return (sources: <SearchResult>[], incomplete: incomplete, skipped: skipped, errors: errors);
      final citations = ZimIndexCitations(index);
      final original = citations.search(question, authorized);
      final translated = query != null && query.trim() != question.trim()
          ? citations.search(query, authorized) : <SearchResult>[];
      // Do not let one language fill the result limit before the other has
      // a chance. Both queries search only the same permitted sources.
      final seen = <String>{};
      final combined = <SearchResult>[];
      for (var i = 0; i < 4; i++) {
        for (final list in [original, translated]) {
          if (i < list.length && seen.add(list[i].url) && combined.length < 4) combined.add(list[i]);
        }
      }
      return (sources: combined, incomplete: incomplete, skipped: skipped, errors: errors);
    } finally {
      db.close();
    }
  }
}
