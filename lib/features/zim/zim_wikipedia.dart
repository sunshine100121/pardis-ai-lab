import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/network/web_search/search_models.dart';
import '../../data/network/web_search/web_page_reader.dart';
import '../../data/network/web_search/wikipedia_client.dart';
import '../retrieval/domain/evidence.dart';
import 'zim_archive.dart';
import 'zim_content_batches.dart';
import 'zim_source.dart';

/// Offline Wikipedia from a Kiwix ZIM file the tester imported (tester
/// answers 2026-10-07, item 9). It answers the same question as
/// [WikipediaClient.lookup], the article on the question's subject, with
/// no network: the article is found by title in the file.
class ZimWikipedia {
  final String path;
  Future<ZimArchive>? _opening;
  bool _closed = false;
  String? _name;
  final Future<ZimSource> Function(String)? openSource;
  final void Function(String)? onStage;

  ZimWikipedia(this.path, {this.openSource, this.onStage});

  /// Where an imported ZIM lives: one file, replaced on import.
  static String fileIn(String supportDir) =>
      p.join(supportDir, 'zim', 'wikipedia.zim');

  Future<ZimArchive> _open() async {
    if (_closed) return Future.error(StateError('Offline Wikipedia is closed'));
    final opening = _opening ??= ZimArchive.open(path, openSource: openSource);
    try {
      return await opening;
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<String?> archiveMetadata(String key) async =>
      (await _open()).metadata(key);
  Future<String> archiveIdentity() async => (await _open()).identity;

  /// The file's own title ("Wikipedia (English) top 50,000"), for Settings.
  Future<String> name() async {
    if (_name != null) return _name!;
    final title = (await (await _open()).metadata('Title'))?.trim() ?? '';
    return _name = title.isNotEmpty ? title : p.basename(path);
  }

  Future<void> close() async {
    _closed = true;
    try {
      await (await _opening)?.close();
    } catch (_) {}
  }

  Future<SearchResult?> article(String title) async {
    final zim = await _open();
    final e = await zim.findByTitle(title);
    if (e == null || !e.isArticle) return null;
    return toResult(
      e.title,
      utf8.decode(await zim.content(e), allowMalformed: true),
      await name(),
      archiveDate: await zim.metadata('Date'),
      archiveId: zim.identity,
      language: await zim.metadata('Language'),
    );
  }

  /// Opens an indexed entry by its exact archive position, preventing a
  /// duplicate title from resolving to another article.
  Future<SearchResult?> articleAt(
    int entryIndex, {
    required String expectedTitle,
  }) async {
    final zim = await _open();
    if (entryIndex < 0 || entryIndex >= zim.entryCount) return null;
    final entry = await zim.entry(entryIndex);
    if (!entry.isArticle || entry.title != expectedTitle) return null;
    return _resultFromText(
      entry.title,
      ZimContentBatches.extractBody(
        utf8.decode(await zim.content(entry), allowMalformed: true),
      ),
      await name(),
      archiveDate: await zim.metadata('Date'),
      archiveId: zim.identity,
      language: await zim.metadata('Language'),
      limit: false,
    );
  }

  /// Titles the question could name, longest first: "Nikon Z30", "Eiffel
  /// Tower", "Paris". Each run of up to four words is tried as written, in
  /// Title Case and with only its first letter capitalised, which is how
  /// Wikipedia titles are written.
  static String normalize(String text) => text
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('‌', ' ')
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');

  static const _persianQuestionWords = {
    'کجاست',
    'کجا',
    'چگونه',
    'چطور',
    'چجوری',
    'چقدر',
    'برای',
    'چیست',
    'چیه',
    'چی',
    'است',
    'هست',
    'درباره',
    'درمورد',
    'مورد',
    'توضیح',
    'بده',
    'بگو',
    'لطفا',
    'لطفاً',
    'را',
    'رو',
    'به',
    'از',
    'در',
    'با',
    'و',
    'طبق',
    'بر',
    'اساس',
    'پاسخ',
    'مستند',
    'استناد',
    'منبع',
    'منابع',
    'دانشنامه',
    'ویکی',
    'پدیا',
    'ویکیپدیا',
    'کن',
    'کنید',
    'دهید',
    'چیستند',
  };

  static String subjectQuery(String query) {
    if (!RegExp(r'[\u0600-\u06FF]').hasMatch(query)) return query;
    return normalize(query)
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((s) => s.isNotEmpty && !_persianQuestionWords.contains(s))
        .join(' ');
  }

  static bool requiresEncyclopedia(String question) {
    final q = normalize(question).toLowerCase();
    return RegExp(r'ویکی\s*پدیا|دانشنامه|wikipedia|encyclop').hasMatch(q) &&
        RegExp(
          r'استناد|مستند|طبق|بر اساس|با توجه|(?:^|\s)از(?:\s|$)|according|source|based on',
        ).hasMatch(q);
  }

  static List<String> candidates(String query) {
    query = subjectQuery(query);
    final words = [
      for (final w in query.split(RegExp(r'\s+')))
        if (w.replaceAll(
              RegExp(r"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$", unicode: true),
              '',
            )
            case final clean when clean.isNotEmpty)
          clean,
    ];
    final out = <String>[];
    void add(String s) {
      if (!out.contains(s)) out.add(s);
    }

    String cap(String w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1);
    final product = WikipediaClient.productName(query);
    if (product != null) {
      add(product);
      add(product.split(' ').map(cap).join(' '));
    }
    for (var n = 4; n >= 1; n--) {
      for (var i = 0; i + n <= words.length; i++) {
        final run = words.sublist(i, i + n);
        // A run must start and end on a content word ("the Eiffel Tower"
        // is tried as "Eiffel Tower").
        if (EvidenceRanker.terms(run.first).isEmpty ||
            EvidenceRanker.terms(run.last).isEmpty) {
          continue;
        }
        final text = run.join(' ');
        add(text);
        add(run.map(cap).join(' '));
        final lower = text.toLowerCase();
        add(cap(lower));
      }
    }
    for (final title in List<String>.of(out)) {
      add(normalize(title));
      add(title.replaceAll('ی', 'ي').replaceAll('ک', 'ك'));
      if (RegExp(r'[\u0600-\u06FF]').hasMatch(title))
        add(title.replaceAll(' ', '\u200c'));
    }
    return out;
  }

  /// The article on [query]'s subject as a read source, or null when the
  /// file has none that [WikipediaClient.bestTitle] accepts.
  Future<SearchResult?> lookup(String query) async {
    onStage?.call('open');
    final zim = await _open();
    onStage?.call('title');
    final tried = <int>{};
    for (final title in candidates(query).take(60)) {
      if (_closed) throw StateError('Offline Wikipedia is closed');
      // Validate the matched alias, not the resolved redirect title. A real
      // exact redirect can legitimately have a different canonical name.
      if (WikipediaClient.bestTitle(normalize(subjectQuery(query)), [
            normalize(title),
          ]) ==
          null)
        continue;
      final e = await zim.findByTitle(title);
      if (e == null || !e.isArticle || !tried.add(e.index)) continue;
      onStage?.call('content');
      final html = utf8.decode(await zim.content(e), allowMalformed: true);
      onStage?.call('metadata');
      final archiveName = await name();
      final date = await zim.metadata('Date');
      final language = await zim.metadata('Language');
      onStage?.call('extract');
      final result = toResult(
        e.title,
        html,
        archiveName,
        archiveDate: date,
        archiveId: zim.identity,
        language: language,
      );
      if (result != null) {
        onStage?.call('complete');
        return result;
      }
      onStage?.call('text_unusable');
    }
    return null;
  }

  /// An article's HTML as a source; null for a short page (a stub or a
  /// disambiguation list is worse than nothing).
  static SearchResult? toResult(
    String title,
    String html,
    String file, {
    String? archiveDate,
    String? archiveId,
    String? language,
  }) {
    var (_, text) = WebPageReader.extract(html);
    return _resultFromText(
      title,
      text,
      file,
      archiveDate: archiveDate,
      archiveId: archiveId,
      language: language,
    );
  }

  static SearchResult? _resultFromText(
    String title,
    String text,
    String file, {
    String? archiveDate,
    String? archiveId,
    String? language,
    bool limit = true,
  }) {
    text = text.trim();
    if (text.length < 80 || RegExp(r'may refer to:').hasMatch(text)) {
      return null;
    }
    if (limit && text.length > WikipediaClient.maxChars) {
      text = text.substring(0, WikipediaClient.maxChars);
    }
    final lead = text
        .split('\n')
        .firstWhere(
          (l) => l.trim().length > 40,
          orElse: () => text.split('\n').first,
        );
    final encoded = Uri.encodeComponent(title.replaceAll(' ', '_'));
    final url = archiveId == null
        ? 'zim://$encoded'
        : 'zim://$archiveId/$encoded';
    return SearchResult(
      title: '$title — $file',
      url: url,
      snippet: lead.length > 300 ? '${lead.substring(0, 300)}…' : lead,
      source: file,
      rank: 0,
      pageText: text,
      finalUrl: url,
      fetchedAt: DateTime.now(),
      outlet: file,
      archiveDate: archiveDate,
      archiveId: archiveId,
      archiveLanguage: language,
    );
  }

  /// Whether [path] is a ZIM file (checks the magic number).
  static Future<bool> isZim(String path) async {
    try {
      final f = await File(path).open();
      try {
        final b = await f.read(4);
        return b.length == 4 &&
            (b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24) == 72173914;
      } finally {
        await f.close();
      }
    } catch (_) {
      return false;
    }
  }
}
