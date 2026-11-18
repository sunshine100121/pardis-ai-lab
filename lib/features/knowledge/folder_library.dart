import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../data/network/web_search/search_models.dart';
import '../attachments/domain/document_text.dart';
import '../zim/zim_source.dart';
import '../zim/zim_wikipedia.dart';
import 'knowledge_read_report.dart';

typedef LibraryFile = ({String uri, String name, int size, int modified});

abstract interface class FolderAccess {
  Future<bool> pick();
  Future<({String? tree, List<LibraryFile> files})> list();
  Future<ZimSource> open(String uri);
}

class AndroidFolderAccess implements FolderAccess {
  static const channel = MethodChannel('pala/documents');
  @override
  Future<bool> pick() async =>
      await channel.invokeMethod<bool>('pickTree') ?? false;
  @override
  Future<({String? tree, List<LibraryFile> files})> list() async {
    final data = (await channel.invokeMapMethod<String, dynamic>('listTree'))!;
    return (
      tree: data['tree'] as String?,
      files: [
        for (final f in data['files'] as List)
          (
            uri: f['uri'] as String,
            name: f['name'] as String,
            size: (f['size'] as num).toInt(),
            modified: (f['modified'] as num).toInt(),
          ),
      ],
    );
  }

  @override
  Future<ZimSource> open(String uri) => ZimSource.open(uri);
}

/// Only metadata and a bounded, rebuildable text index are persisted.
/// Original files are never written, removed or copied to app storage.
class FolderLibrary {
  static const key = 'pala_folder_library_v1';
  static const diagnosticsKey = 'pala_zim_read_status_v1';
  static const maxDocumentBytes = 8 * 1024 * 1024;
  static const maxIndexBytes = 2 * 1024 * 1024;
  static const extensions = {
    'zim',
    'pdf',
    'epub',
    'docx',
    'txt',
    'md',
    'markdown',
    'rtf',
  };
  final FolderAccess access;
  final Future<String> Function(Uint8List) pdfText;
  final Duration lookupTimeout;
  FolderLibrary({
    FolderAccess? access,
    Future<String> Function(Uint8List)? pdfText,
    this.lookupTimeout = const Duration(seconds: 8),
  }) : access = access ?? AndroidFolderAccess(),
       pdfText = pdfText ?? readPdf;
  bool _refreshing = false;
  int _pendingZimCleanup = 0;
  static const _maxPendingZimCleanup = 2;

  static bool supported(String name) =>
      extensions.contains(name.split('.').last.toLowerCase());
  static String sourceId(String uri) =>
      sha256.convert(utf8.encode(uri)).toString();
  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ');
  static Future<String> readPdf(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    try {
      final text = StringBuffer();
      for (var i = 0; i < document.pages.length; i++) {
        final page = (await document.pages[i].loadText())?.fullText ?? '';
        text.writeln('--- Page ${i + 1} ---\n$page');
        if (text.length > DocumentText.maxChars) break;
      }
      if (text
          .toString()
          .replaceAll(RegExp(r'--- Page \d+ ---'), '')
          .trim()
          .isEmpty) {
        throw const FormatException(
          'این PDF متن قابل‌خواندن ندارد؛ OCR مطمئن در این مسیر فعال نیست.',
        );
      }
      return text.toString();
    } finally {
      await document.dispose();
    }
  }

  /// Reads all text pages one by one, retaining only the best four matches.
  /// The caller checks source identity, approval and maximum input bytes.
  static Future<List<({int page, int score, String text})>> findPdfPages(
    Uint8List bytes,
    Set<String> questionTerms,
  ) async {
    if (questionTerms.isEmpty) return const [];
    if (bytes.length > maxDocumentBytes) {
      throw const FormatException('سند برای خواندن مستقیم بزرگ است');
    }
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    try {
      final results = <({int page, int score, String text})>[];
      for (var i = 0; i < document.pages.length; i++) {
        final text = (await document.pages[i].loadText())?.fullText ?? '';
        final normalized = normalize(text);
        final score = questionTerms.where(normalized.contains).length;
        if (score == 0) continue;
        final first = questionTerms
            .map(normalized.indexOf)
            .where((offset) => offset >= 0)
            .fold<int>(text.length, (a, b) => a < b ? a : b);
        final start = (first - 200).clamp(0, text.length);
        final end = (start + 1500).clamp(0, text.length);
        results.add((
          page: i + 1,
          score: score,
          text: text.substring(start, end).trim(),
        ));
        results.sort((a, b) => b.score.compareTo(a.score));
        if (results.length > 4) results.removeLast();
      }
      return results;
    } finally {
      await document.dispose();
    }
  }

  Future<Map<String, dynamic>> state() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    return raw == null
        ? {'tree': null, 'files': <dynamic>[]}
        : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _save(Map<String, dynamic> value) async {
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > maxIndexBytes)
      throw const FormatException(
        'سقف ۲ MiB نمایه پر شده است؛ منابع کمتری فعال کنید.',
      );
    await (await SharedPreferences.getInstance()).setString(key, encoded);
  }

  Future<int> indexBytes() async =>
      utf8.encode(jsonEncode(await state())).length;
  Future<void> setEnabled(String uri, bool enabled) async {
    final data = await state();
    for (final f in data['files'] as List) {
      if (f['uri'] == uri) f['enabled'] = enabled;
    }
    await _save(data);
  }

  Future<void> refresh({bool pick = false}) async {
    if (_refreshing) throw StateError('بازخوانی در حال انجام است');
    _refreshing = true;
    try {
      if (pick && !await access.pick()) return;
      final listing = await access.list();
      final previous = await state();
      final old = {for (final f in previous['files'] as List) f['uri']: f};
      final files = <Map<String, dynamic>>[];
      var readBytes = 0, indexed = 0;
      for (final file in listing.files.where((f) => supported(f.name))) {
        final same = old[file.uri];
        final enabled = same?['enabled'] != false;
        final row = <String, dynamic>{
          'uri': file.uri,
          'name': file.name,
          'size': file.size,
          'modified': file.modified,
          'enabled': enabled,
          'status': 'آمادهٔ جست‌وجو',
          'passages': <dynamic>[],
        };
        files.add(row);
        if (file.name.toLowerCase().endsWith('.zim')) {
          row['status'] =
              'شناسایی شده؛ بازشدن و بازیابی مقاله هنوز تأیید نشده است';
          continue;
        }
        try {
          if (!enabled) {
            row['status'] = 'غیرفعال؛ برای ساخت نمایه بازخوانی کنید';
            continue;
          }
          if (file.size < 0 || file.size > maxDocumentBytes)
            throw const FormatException(
              'اندازه نامعلوم یا بیش از ۸ MiB؛ بدون ساخت کپی رد شد.',
            );
          if (same != null &&
              same['size'] == file.size &&
              same['modified'] == file.modified &&
              (same['passages'] as List).isNotEmpty) {
            row['passages'] = same['passages'];
            row['status'] = same['status'];
            continue;
          }
          if (indexed >= 32 || readBytes + file.size > 64 * 1024 * 1024)
            throw const FormatException(
              'سقف بازخوانی ۳۲ سند یا ۶۴ MiB پر شد؛ منابع کمتری فعال کنید.',
            );
          indexed++;
          readBytes += file.size;
          final source = await access.open(file.uri);
          late Uint8List bytes;
          try {
            final length = await source.length();
            if (length != file.size || length > maxDocumentBytes)
              throw const FormatException(
                'اندازه فایل تغییر کرده است؛ دوباره بازخوانی کنید.',
              );
            bytes = await source.readAt(0, length);
            if (bytes.length != length)
              throw const FormatException('خواندن فایل ناقص بود');
          } finally {
            await source.close();
          }
          final extracted = await DocumentText.extract(
            bytes,
            file.name,
            pdfText: pdfText,
            localeCode: 'fa',
          ).timeout(const Duration(seconds: 20));
          if (extracted.text.trim().isEmpty)
            throw const FormatException('متن قابل‌خواندن موجود نیست');
          row['passages'] = passages(extracted.text);
          row['status'] = 'نمایهٔ محدود؛ حداکثر ۲۴ قطعه از ابتدای سند';
          // Keep the serialized index bounded even with many documents.
          if (utf8.encode(jsonEncode(files)).length > maxIndexBytes - 16384) {
            row['passages'] = <dynamic>[];
            row['status'] = 'سقف نمایه پر است؛ این منبع نمایه نشد';
          }
        } catch (e) {
          row['status'] = e is FormatException
              ? e.message
              : 'خواندن منبع ناموفق بود؛ مجوز و قالب را بررسی کنید';
        }
      }
      await _save({'tree': listing.tree, 'files': files});
    } finally {
      _refreshing = false;
    }
  }

  static List<Map<String, dynamic>> passages(String text) {
    final marks = RegExp(
      r'^--- (?:Page (\d+)|فصل: (.+)) ---\s*$',
      multiLine: true,
    ).allMatches(text).toList();
    final out = <Map<String, dynamic>>[];
    void add(String body, String location) {
      for (var at = 0; at < body.length && out.length < 24; at += 1500) {
        final end = (at + 1500).clamp(0, body.length);
        final chunk = body.substring(at, end).trim();
        if (chunk.isNotEmpty) out.add({'location': location, 'text': chunk});
      }
    }

    if (marks.isEmpty) {
      add(text, 'بخش متن');
    } else {
      for (var i = 0; i < marks.length && out.length < 24; i++) {
        final mark = marks[i];
        add(
          text.substring(
            mark.end,
            i + 1 < marks.length ? marks[i + 1].start : text.length,
          ),
          mark[1] != null ? 'صفحه ${mark[1]}' : 'فصل ${mark[2]}',
        );
      }
    }
    return out;
  }

  Future<List<SearchResult>> search(String question) async =>
      (await searchDetailed(question)).sources;
  Future<KnowledgeReadReport> searchDetailed(
    String question, {
    Set<String>? sourceIds,
  }) async {
    // An empty project has explicitly approved ZERO sources. Skip even SAF
    // directory enumeration, which can be slow on Android content providers.
    if (sourceIds != null && sourceIds.isEmpty) {
      return const KnowledgeReadReport([], []);
    }
    final data = await state();
    if (data['tree'] == null) return const KnowledgeReadReport([], []);
    final live = await access
        .list(); // Revoked grants and moved/changed files fail closed.
    final current = {for (final f in live.files) f.uri: f};
    final terms = normalize(question)
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((s) => s.length > 2)
        .toSet();
    final found = <(int, SearchResult)>[];
    final checks = <Map<String, dynamic>>[];
    for (final f in data['files'] as List) {
      if (sourceIds != null &&
          !sourceIds.contains(sourceId(f['uri'] as String)))
        continue;
      final now = current[f['uri']];
      if (f['enabled'] != true) continue;
      if (now == null ||
          now.name != f['name'] ||
          now.size != f['size'] ||
          now.modified != f['modified']) {
        if ((f['name'] as String).toLowerCase().endsWith('.zim'))
          checks.add({'file': f['name'], 'code': 'changed'});
        continue;
      }
      if ((f['name'] as String).toLowerCase().endsWith('.zim')) {
        if (_pendingZimCleanup >= _maxPendingZimCleanup) {
          checks.add({'file': f['name'], 'code': 'deferred_timeout'});
          continue;
        }
        final clock = Stopwatch()..start();
        final check = <String, dynamic>{
          'file': f['name'],
          'stage': 'open',
          'code': 'not_found',
          'fileSize': now.size,
          'fileModified': now.modified,
          'readCalls': 0,
          'readBytes': 0,
          'highestOffset': 0,
        };
        checks.add(check);
        final wiki = ZimWikipedia(
          f['uri'] as String,
          openSource: (uri) async =>
              _MeteredZimSource(await access.open(uri), check),
          onStage: (stage) {
            if (check['code'] != 'timeout') check['stage'] = stage;
          },
        );
        var timedOut = false;
        try {
          final result = await wiki.lookup(question).timeout(lookupTimeout);
          if (result != null) {
            found.add((100, result));
            check['code'] = 'found';
            check['article'] = result.title;
            check['archive'] = result.source;
          } else if (check['stage'] == 'text_unusable') {
            check['code'] = 'text_unusable';
          }
        } on TimeoutException {
          timedOut = true;
          check['code'] = 'timeout';
        } on FormatException {
          check['code'] = 'format';
        } catch (_) {
          check['code'] = 'access';
        } finally {
          check['elapsedMs'] = clock.elapsedMilliseconds;
          // Closing marks the lookup closed immediately; already accepted native
          // I/O/decompression finishes before the descriptor is released. Do not
          // turn an expired lookup into an unbounded UI wait for that cleanup.
          if (timedOut) {
            _pendingZimCleanup++;
            unawaited(
              wiki.close().whenComplete(() {
                _pendingZimCleanup--;
              }),
            );
          } else {
            await wiki.close();
          }
        }
        continue;
      }
      // Preview metadata contains only early passages. On a miss, inspect
      // the full text layer of the same authorized, unchanged PDF on demand.
      if ((f['name'] as String).toLowerCase().endsWith('.pdf') &&
          terms.isNotEmpty &&
          now.size >= 0 &&
          now.size <= maxDocumentBytes &&
          !(f['passages'] as List).any((p) {
            final excerpt = normalize(p['text'] as String);
            final overlap = terms.where(excerpt.contains).length;
            return overlap >= (terms.length == 1 ? 1 : 2);
          })) {
        try {
          final source = await access.open(f['uri'] as String);
          late Uint8List bytes;
          try {
            final length = await source.length();
            if (length != now.size || length > maxDocumentBytes) {
              throw StateError('اندازه فایل تغییر کرده است');
            }
            bytes = await source.readAt(0, length);
            if (bytes.length != length) throw StateError('خواندن ناقص');
          } finally {
            await source.close();
          }
          final matches = await findPdfPages(bytes, terms);
          // A SAF grant, file revision or project selection may change
          // during a long scan; do not return evidence from a stale source.
          final still = await access.list();
          final currentFile = still.files.where(
            (item) => item.uri == f['uri'],
          ).firstOrNull;
          final saved = await state();
          final approved = (saved['files'] as List).whereType<Map>().any(
            (row) =>
                row['uri'] == f['uri'] &&
                row['enabled'] == true &&
                row['size'] == now.size &&
                row['modified'] == now.modified,
          );
          if (!approved ||
              currentFile == null ||
              currentFile.size != now.size ||
              currentFile.modified != now.modified ||
              currentFile.name != now.name) {
            checks.add({'file': f['name'], 'code': 'changed'});
            continue;
          }
          for (final hit in matches) {
            final id = sourceId(f['uri'] as String);
            found.add((
              hit.score,
              SearchResult(
                title: (f['name'] as String) + ' · صفحه ' +
                    hit.page.toString(),
                url: 'pala-knowledge://' + id +
                    '?page=' + hit.page.toString(),
                snippet: '',
                source: 'پوشه AI Knowledge',
                rank: hit.score,
                pageText: hit.text,
                fetchedAt: DateTime.now().toUtc(),
              ),
            ));
          }
          checks.add({
            'file': f['name'],
            'code': 'pdf_page_scan',
            'pagesMatched': matches.length,
          });
          continue;
        } catch (_) {
          checks.add({'file': f['name'], 'code': 'pdf_page_scan_failed'});
          // Do not substitute potentially stale preview evidence after
          // the source failed its live read or permission checks.
          continue;
        }
      }
      for (final p in f['passages'] as List) {
        final text = normalize(p['text'] as String);
        final score = terms.where(text.contains).length;
        if (score == 0) continue;
        final id = sourceId(f['uri'] as String);
        found.add((
          score,
          SearchResult(
            title: '${f['name']} · ${p['location']}',
            url: 'pala-knowledge://$id',
            snippet: '',
            source: 'پوشه AI Knowledge',
            rank: score,
            pageText: p['text'] as String,
            fetchedAt: DateTime.now().toUtc(),
          ),
        ));
      }
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    // Persist status only: no question, article text, URI, token or model output.
    await (await SharedPreferences.getInstance()).setString(
      diagnosticsKey,
      jsonEncode(checks),
    );
    return KnowledgeReadReport(found.take(4).map((e) => e.$2).toList(), [
      for (final c in checks) Map<String, dynamic>.from(c),
    ]);
  }

  Future<SearchResult?> article(
    String url,
    String archiveId,
    String? date, {
    bool Function(String uri)? allowSource,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'zim' ||
        uri.host != archiveId ||
        uri.pathSegments.length != 1 ||
        uri.hasFragment ||
        uri.queryParametersAll.keys.any(
          (key) => key != 'entry' && key != 'source',
        ) ||
        (uri.queryParametersAll['entry']?.length ?? 0) > 1 ||
        (uri.queryParametersAll['source']?.length ?? 0) > 1)
      return null;
    final entryText = uri.queryParameters['entry'];
    final entry = entryText == null ? null : int.tryParse(entryText);
    if (entryText != null && (entry == null || entry < 0)) return null;
    final sourceId = uri.queryParameters['source'];
    if (sourceId != null &&
        (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceId) || entry == null))
      return null;
    final listing = await access.list();
    final live = {for (final f in listing.files) f.uri: f};
    final data = await state();
    for (final row in data['files'] as List) {
      if (sourceId != null &&
          FolderLibrary.sourceId(row['uri'] as String) != sourceId)
        continue;
      if (allowSource != null && !allowSource(row['uri'] as String)) continue;
      final file = live[row['uri']];
      if (row['enabled'] != true ||
          file == null ||
          !file.name.toLowerCase().endsWith('.zim') ||
          file.size != row['size'] ||
          file.modified != row['modified'])
        continue;
      final wiki = ZimWikipedia(
        file.uri,
        openSource: (uri) {
          if (allowSource != null && !allowSource(uri)) {
            throw StateError('محدوده منابع پروژه تغییر کرده است.');
          }
          return access.open(uri);
        },
      );
      try {
        if (await wiki.archiveIdentity() != archiveId ||
            await wiki.archiveMetadata('Date') != date)
          continue;
        final title = uri.pathSegments.single.replaceAll('_', ' ');
        return entry == null
            ? await wiki.article(title)
            : await wiki.articleAt(entry, expectedTitle: title);
      } catch (_) {
        /* Keep the saved excerpt if access was revoked. */
      } finally {
        await wiki.close();
      }
    }
    return null;
  }
}

final folderLibraryProvider = Provider<FolderLibrary>((ref) => FolderLibrary());

class _MeteredZimSource implements ZimSource {
  final ZimSource source;
  final Map<String, dynamic> check;
  _MeteredZimSource(this.source, this.check);
  @override
  Future<int> length() => source.length();
  @override
  Future<Uint8List> readAt(int offset, int count) async {
    check['readCalls'] = (check['readCalls'] as int) + 1;
    if (offset > (check['highestOffset'] as int))
      check['highestOffset'] = offset;
    final bytes = await source.readAt(offset, count);
    check['readBytes'] = (check['readBytes'] as int) + bytes.length;
    return bytes;
  }

  @override
  Future<void> close() => source.close();
}
