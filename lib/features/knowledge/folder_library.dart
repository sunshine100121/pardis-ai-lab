import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/network/web_search/search_models.dart';
import '../attachments/domain/document_text.dart';
import '../zim/zim_source.dart';
import '../zim/zim_wikipedia.dart';
import '../zim/zim_image_selection.dart';
import '../zim/zim_video_selection.dart';
import '../zim/zim_subtitles.dart';
import '../zim/zim_archive.dart';
import '../zim/zim_local_video.dart';
import 'knowledge_read_report.dart';
import 'pdf_index_lookup.dart';

typedef LibraryFile = ({String uri, String name, int size, int modified});
typedef IndexedPdfSearch =
    Future<List<({int page, String text, bool ocr})>?> Function({
      required String sourceId,
      required int size,
      required int modified,
      required String query,
    });

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
  final IndexedPdfSearch indexedPdfSearch;
  final Duration lookupTimeout;
  FolderLibrary({
    FolderAccess? access,
    Future<String> Function(Uint8List)? pdfText,
    IndexedPdfSearch? indexedPdfSearch,
    this.lookupTimeout = const Duration(seconds: 8),
  }) : access = access ?? AndroidFolderAccess(),
       pdfText = pdfText ?? readPdf,
       indexedPdfSearch = indexedPdfSearch ?? PdfIndexLookup.read;
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

  /// A PDF opened directly from the approved read-only SAF/file descriptor.
  /// No full-document Uint8List, duplicate archive or persisted text index.
  /// PDFium may request offsets out of order; readAt is serialized for local
  /// RandomAccessFile providers and split into small bounded chunks.
  static const maxPdfReadChunkBytes = 64 * 1024;
  static const maxPdfCachedBytes = 1024 * 1024;

  static Future<
    ({
      List<({int page, int score, String text})> matches,
      int pagesScanned,
      int pagesWithText,
    })
  >
  scanPdfSource(
    ZimSource source,
    int expectedBytes,
    Set<String> questionTerms, {
    required String sourceName,
    int startPage = 1,
    Future<void> Function(int totalPages)? onOpened,
    Future<void> Function(int page, String text, bool wasOcr)? onPageText,
    Future<String?> Function(PdfPage page)? ocrPage,
    bool Function()? cancelled,
  }) async {
    if (expectedBytes <= 0 || await source.length() != expectedBytes) {
      throw const FormatException('اندازه PDF تغییر کرده یا نامعتبر است');
    }
    await pdfrxFlutterInitialize();
    Future<void> previousRead = Future<void>.value();
    Future<int> read(Uint8List buffer, int position, int size) async {
      final waiting = previousRead;
      final release = Completer<void>();
      previousRead = release.future;
      await waiting;
      try {
        if (position < 0 || size < 0 || size > buffer.length) {
          throw RangeError('PDF read request');
        }
        if (position >= expectedBytes || size == 0) return 0;
        final needed = size < expectedBytes - position
            ? size
            : expectedBytes - position;
        var copied = 0;
        while (copied < needed) {
          final count = (needed - copied) < maxPdfReadChunkBytes
              ? needed - copied
              : maxPdfReadChunkBytes;
          final chunk = await source.readAt(position + copied, count);
          if (chunk.isEmpty || chunk.length > count) {
            throw const FormatException('خواندن ناقص PDF');
          }
          buffer.setRange(copied, copied + chunk.length, chunk);
          copied += chunk.length;
        }
        return copied;
      } finally {
        release.complete();
      }
    }

    final document = await PdfDocument.openCustom(
      read: read,
      fileSize: expectedBytes,
      sourceName: sourceName,
      maxSizeToCacheOnMemory: maxPdfCachedBytes,
    );
    try {
      final matches = <({int page, int score, String text})>[];
      var pagesWithText = 0;
      if (startPage < 1 || startPage > document.pages.length + 1) {
        throw RangeError('PDF resume cursor outside document');
      }
      await onOpened?.call(document.pages.length);
      for (var i = startPage - 1; i < document.pages.length; i++) {
        if (cancelled?.call() == true) break;
        // Preserve bounded reads and the actual PDF page numbering.
        var text = (await document.pages[i].loadText())?.fullText ?? '';
        var wasOcr = false;
        if (text.trim().isEmpty && ocrPage != null) {
          final recognized = await ocrPage(document.pages[i]);
          if (recognized != null && recognized.trim().isNotEmpty) {
            text = recognized;
            wasOcr = true;
          }
        }
        await onPageText?.call(i + 1, text, wasOcr);
        if (text.trim().isEmpty) continue;
        pagesWithText++;
        if (questionTerms.isEmpty) continue;
        final normalized = normalize(text);
        final score = questionTerms.where(normalized.contains).length;
        if (score == 0) continue;
        final first = questionTerms
            .map(normalized.indexOf)
            .where((offset) => offset >= 0)
            .fold<int>(text.length, (a, b) => a < b ? a : b);
        final start = (first - 200).clamp(0, text.length);
        final end = (start + 1500).clamp(0, text.length);
        matches.add((
          page: i + 1,
          score: score,
          text: text.substring(start, end).trim(),
        ));
        matches.sort((a, b) => b.score.compareTo(a.score));
        if (matches.length > 4) matches.removeLast();
      }
      return (
        matches: matches,
        pagesScanned: document.pages.length,
        pagesWithText: pagesWithText,
      );
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
          if (file.size < 0) {
            throw const FormatException('اندازه فایل نامعتبر است');
          }
          if (file.name.toLowerCase().endsWith('.pdf') &&
              file.size > maxDocumentBytes) {
            row['status'] =
                'PDF بزرگ؛ نمایه آغازین ساخته نشد؛ جست‌وجوی تدریجی همه صفحات '
                'هنگام پرسش انجام می‌شود (تشخیص متن در زمان جست‌وجو)';
            continue;
          }
          if (file.size > maxDocumentBytes) {
            throw const FormatException(
              'فایل غیر PDF بیش از ۸ MiB؛ بدون ساخت کپی رد شد.',
            );
          }
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
      // A complete, revision-matching index skips the costly PDFium scan.
      // Incomplete/revoked indexes never return evidence; the existing
      // bounded read-only page scan remains the safe fallback.
      if ((f['name'] as String).toLowerCase().endsWith('.pdf') &&
          terms.isNotEmpty) {
        List<({int page, String text, bool ocr})>? indexed;
        try {
          indexed = await indexedPdfSearch(
            sourceId: sourceId(f['uri'] as String),
            size: now.size,
            modified: now.modified,
            query: question,
          );
        } catch (_) {
          checks.add({'file': f['name'], 'code': 'pdf_index_error'});
        }
        if (indexed != null) {
          // Revalidate the current SAF permission and owner enablement even
          // for a SQLite hit; never trust old cached excerpts blindly.
          final still = await access.list();
          final currentFile = still.files
              .where((item) => item.uri == f['uri'])
              .firstOrNull;
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
          for (final hit in indexed) {
            final snippet = hit.text.length > 1500
                ? hit.text.substring(0, 1500)
                : hit.text;
            found.add((
              terms.where(normalize(hit.text).contains).length,
              SearchResult(
                title: "${f['name']} · صفحه ${hit.page}",
                url:
                    'pala-knowledge://${sourceId(f['uri'] as String)}?page=${hit.page}',
                snippet: '',
                source: hit.ocr
                    ? 'پوشه AI Knowledge · متن استخراج‌شده با OCR'
                    : 'پوشه AI Knowledge',
                rank: 100,
                pageText: snippet,
                fetchedAt: DateTime.now().toUtc(),
              ),
            ));
          }
          checks.add({
            'file': f['name'],
            'code': 'pdf_index_hit',
            'pagesScanned': 0,
            'pagesMatched': indexed.length,
          });
          continue;
        }
        // M15: no additional scan, copy or allocation; measure the
        // existing approved-page lookup from open through final cleanup.
        final pageScanClock = Stopwatch()..start();
        try {
          final source = await access.open(f['uri'] as String);
          late ({
            List<({int page, int score, String text})> matches,
            int pagesScanned,
            int pagesWithText,
          })
          scan;
          try {
            final length = await source.length();
            if (length != now.size) {
              throw const FormatException('اندازه PDF تغییر کرده است');
            }
            scan = await scanPdfSource(
              source,
              length,
              terms,
              sourceName:
                  'pala-pdf:${sourceId(f['uri'] as String)}:${now.modified}',
            );
          } finally {
            await source.close();
          }
          // A SAF grant, file revision or approval can change during the
          // scan. Fail closed rather than serving text from a stale file.
          final still = await access.list();
          final currentFile = still.files
              .where((item) => item.uri == f['uri'])
              .firstOrNull;
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
          if (scan.pagesWithText == 0) {
            checks.add({
              'file': f['name'],
              'code': 'pdf_no_text',
              'pagesScanned': scan.pagesScanned,
            });
            continue;
          }
          for (final hit in scan.matches) {
            final id = sourceId(f['uri'] as String);
            found.add((
              hit.score,
              SearchResult(
                title: '${f['name']} · صفحه ${hit.page}',
                url: 'pala-knowledge://$id?page=${hit.page}',
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
            'pagesScanned': scan.pagesScanned,
            'pagesWithText': scan.pagesWithText,
            'pagesMatched': scan.matches.length,
          });
          continue;
        } catch (_) {
          checks.add({'file': f['name'], 'code': 'pdf_page_scan_failed'});
          // No stale excerpts or unverified synthetic page labels.
          continue;
        } finally {
          pageScanClock.stop();
          // Every existing PDF result path (success, no text, error or
          // changed source) appends its own status before leaving the loop.
          // Never persist source text, prompt or private document bytes.
          if (checks.isNotEmpty && checks.last['file'] == f['name']) {
            checks.last['elapsedMs'] = pageScanClock.elapsedMilliseconds;
          }
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


  /// Scoped read from the exact, currently enabled ZIM and article.
  /// SAF, project and source revision are checked before and after reading.
  Future<T?> _withVideoArticle<T>(
    String url, String archiveId, String? date,
    Future<T?> Function(
      ZimArchive archive, ZimEntry article, LibraryFile source,
    ) read, {
    bool Function(String uri)? allowSource,
  }) async {
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'zim' ||
        parsed.host != archiveId || parsed.pathSegments.length != 1 ||
        parsed.hasFragment ||
        parsed.queryParametersAll.keys.any(
          (key) => key != 'entry' && key != 'source',
        ) ||
        (parsed.queryParametersAll['entry']?.length ?? 0) > 1 ||
        (parsed.queryParametersAll['source']?.length ?? 0) > 1) return null;
    final rawIndex = parsed.queryParameters['entry'];
    final index = rawIndex == null ? null : int.tryParse(rawIndex);
    if (rawIndex != null && (index == null || index < 0)) return null;
    final exactSource = parsed.queryParameters['source'];
    if (exactSource != null &&
        (!RegExp(r'^[0-9a-f]{64}$').hasMatch(exactSource) || index == null)) {
      return null;
    }
    final initial = await access.list();
    final current = {for (final f in initial.files) f.uri: f};
    final data = await state();
    for (final row in data['files'] as List) {
      final fileUri = row['uri'] as String;
      if (exactSource != null && FolderLibrary.sourceId(fileUri) != exactSource) {
        continue;
      }
      if (row['enabled'] != true || allowSource?.call(fileUri) == false) {
        continue;
      }
      final source = current[fileUri];
      if (source == null || !source.name.toLowerCase().endsWith('.zim') ||
          source.size != row['size'] || source.modified != row['modified']) {
        continue;
      }
      ZimArchive? archive;
      try {
        archive = await ZimArchive.open(fileUri, openSource: (uri) async {
          if (allowSource?.call(uri) == false) {
            throw StateError('محدوده منابع پروژه تغییر کرده است');
          }
          return access.open(uri);
        });
        if (archive.identity != archiveId ||
            await archive.metadata('Date') != date) continue;
        final title = parsed.pathSegments.single.replaceAll('_', ' ');
        final article = index == null
            ? await archive.findByTitle(title)
            : index < archive.entryCount ? await archive.entry(index) : null;
        if (article == null || !article.isArticle || article.title != title) {
          continue;
        }
        final result = await read(archive, article, source);
        if (allowSource?.call(fileUri) == false) return null;
        final after = await access.list();
        final same = after.files.where((f) => f.uri == fileUri).firstOrNull;
        final latest = await state();
        final enabled = (latest['files'] as List).any(
          (f) => f['uri'] == fileUri && f['enabled'] == true &&
              f['size'] == source.size && f['modified'] == source.modified,
        );
        if (!enabled || same == null || same.size != source.size ||
            same.modified != source.modified) return null;
        return result;
      } catch (_) {
        // Optional media never prevents reading the underlying article.
      } finally {
        await archive?.close();
      }
    }
    return null;
  }

  /// Metadata only: no media bytes until the owner explicitly plays.
  Future<List<ZimVideoCandidate>?> articleVideos(
    String url, String archiveId, String? date, {
    bool Function(String uri)? allowSource,
  }) => _withVideoArticle(url, archiveId, date,
      (archive, article, source) async {
    final html = utf8.decode(await archive.content(article),
        allowMalformed: true);
    return ZimVideoSelection.fromArticleHtml(html);
  }, allowSource: allowSource);

  /// Scratch video is removed if permission, archive revision or user choice
  /// changes. Extraction never writes to the actual ZIM source.
  Future<ZimPlayableVideo?> openArticleVideo(
    String url, String archiveId, String? date, String videoReference, {
    bool Function(String uri)? allowSource,
    bool Function()? cancelled,
  }) async {
    File? scratch;
    ZimPlayableVideo? opened;
    try {
      opened = await _withVideoArticle(url, archiveId, date,
          (archive, article, source) async {
        if (cancelled?.call() == true) return null;
        final html = utf8.decode(await archive.content(article),
            allowMalformed: true);
        final listed = ZimVideoSelection.fromArticleHtml(html);
        final match = listed.where((v) => v.reference == videoReference)
            .firstOrNull;
        if (match == null) return null;
        final suffix = p.extension(videoReference).toLowerCase();
        final tmp = await getTemporaryDirectory();
        scratch = File(p.join(tmp.path, 'pala-zim-video',
            '${const Uuid().v4()}$suffix'));
        final ok = await archive.extractLocalVideo(article,
            videoReference, scratch!, cancelled: cancelled);
        if (!ok || cancelled?.call() == true) return null;
        var cues = <ZimSubtitleCue>[];
        if (match.subtitleReference != null) {
          try {
            final subtitle = await archive.localSubtitle(
                article, match.subtitleReference!);
            if (subtitle != null) cues = ZimSubtitles.parse(subtitle);
          } catch (_) {
            // Broken subtitles must not prevent offline video playback.
          }
        }
        return ZimPlayableVideo(
          file: scratch!, cues: cues,
          revision: '${source.size}:${source.modified}',
          subtitleLanguage: match.subtitleLanguage,
        );
      }, allowSource: allowSource);
      return opened;
    } finally {
      if (opened == null && scratch != null && await scratch!.exists()) {
        await scratch!.delete();
      }
    }
  }

  /// Read bounded images from a verified, approved local ZIM article.
  /// SAF permission, archive revision and project membership are checked
  /// before and after I/O. No remote image URL is ever opened here.
  Future<ZimLocalGallery?> articleGallery(
    String url,
    String archiveId,
    String? date, {
    required String question,
    int maxImages = 2,
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
        (uri.queryParametersAll['source']?.length ?? 0) > 1) {
      return null;
    }
    final entryText = uri.queryParameters['entry'];
    final entry = entryText == null ? null : int.tryParse(entryText);
    if (entryText != null && (entry == null || entry < 0)) return null;
    final sourceId = uri.queryParameters['source'];
    if (sourceId != null &&
        (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceId) || entry == null)) {
      return null;
    }
    final listing = await access.list();
    final live = {for (final f in listing.files) f.uri: f};
    final data = await state();
    for (final row in data['files'] as List) {
      final fileUri = row['uri'] as String;
      if (sourceId != null && FolderLibrary.sourceId(fileUri) != sourceId) {
        continue;
      }
      if (allowSource != null && !allowSource(fileUri)) continue;
      final file = live[fileUri];
      if (row['enabled'] != true ||
          file == null ||
          !file.name.toLowerCase().endsWith('.zim') ||
          file.size != row['size'] ||
          file.modified != row['modified']) {
        continue;
      }
      final wiki = ZimWikipedia(
        fileUri,
        openSource: (uri) {
          if (allowSource != null && !allowSource(uri)) {
            throw StateError('محدوده منابع پروژه تغییر کرده است.');
          }
          return access.open(uri);
        },
      );
      try {
        if (await wiki.archiveIdentity() != archiveId ||
            await wiki.archiveMetadata('Date') != date) {
          continue;
        }
        final result = await wiki.gallery(
          uri.pathSegments.single.replaceAll('_', ' '),
          entryIndex: entry,
          question: question,
          maxImages: maxImages,
        );
        if (allowSource != null && !allowSource(fileUri)) return null;
        final checked = await access.list();
        final current = checked.files
            .where((f) => f.uri == fileUri)
            .firstOrNull;
        if (current == null ||
            current.size != file.size ||
            current.modified != file.modified) {
          return null;
        }
        return result;
      } catch (_) {
        // Optional pictures never prevent a valid textual answer.
      } finally {
        await wiki.close();
      }
    }
    return null;
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
