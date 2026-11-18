import '../../data/network/web_search/search_models.dart';
import '../../data/network/web_search/wikipedia_client.dart';
import 'zim_content_index.dart';

/// Metadata must be verified against the currently selected, unchanged file
/// before use. Only those authorized source ids enter the index query.
typedef ZimIndexedSource = ({
  String fingerprint,
  String archiveId,
  String name,
  String? date,
  String? language,
});

class ZimIndexCitations {
  final ZimContentIndex index;
  const ZimIndexCitations(this.index);

  List<SearchResult> search(
    String query,
    Map<String, ZimIndexedSource> authorized, {
    int limit = 4,
  }) {
    final hits = index.search(query, {
      for (final item in authorized.entries) item.key: item.value.fingerprint,
    }, limit: limit);
    return [
      for (final hit in hits)
        if (authorized[hit.sourceId] case final source?)
          _citation(hit.sourceId, hit.entry, hit.title, hit.text, source, query),
    ];
  }

  SearchResult _citation(
    String sourceId,
    int entry,
    String title,
    String text,
    ZimIndexedSource source,
    String query,
  ) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceId) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(source.archiveId) ||
        source.name.trim().isEmpty ||
        title.trim().isEmpty ||
        entry < 0) {
      throw const FormatException('مشخصات استناد دانشنامه معتبر نیست');
    }
    final trimmed = text.trim();
    final lower = trimmed.toLowerCase();
    var match = -1;
    for (final word in RegExp(
      r'[\p{L}\p{N}]+',
      unicode: true,
    ).allMatches(query.toLowerCase())) {
      final term = word.group(0)!;
      if (term.length < 3) continue;
      final at = lower.indexOf(term);
      if (at >= 0 && (match < 0 || at < match)) match = at;
    }
    var start = match < 0
        ? 0
        : (match - WikipediaClient.maxChars ~/ 4).clamp(0, trimmed.length);
    var end = (start + WikipediaClient.maxChars).clamp(0, trimmed.length);
    if (start > 0 &&
        start < trimmed.length &&
        trimmed.codeUnitAt(start) >= 0xdc00 &&
        trimmed.codeUnitAt(start) <= 0xdfff)
      start--;
    if (end < trimmed.length &&
        end > 0 &&
        trimmed.codeUnitAt(end - 1) >= 0xd800 &&
        trimmed.codeUnitAt(end - 1) <= 0xdbff)
      end++;
    final body = trimmed.substring(start, end);
    final url =
        'zim://${source.archiveId}/${Uri.encodeComponent(title.replaceAll(' ', '_'))}?entry=$entry&source=$sourceId';
    return SearchResult(
      title: '$title — ${source.name}',
      url: url,
      snippet: body.length > 300 ? '${body.substring(0, 300)}…' : body,
      source: source.name,
      rank: 0,
      pageText: body,
      finalUrl: url,
      fetchedAt: DateTime.now(),
      outlet: source.name,
      archiveDate: source.date,
      archiveId: source.archiveId,
      archiveLanguage: source.language,
    );
  }
}
