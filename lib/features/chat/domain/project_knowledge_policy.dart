import '../../../data/network/web_search/search_models.dart';

/// Deterministic ranking of already-authorized local evidence.
/// Specialized sources win ties; shared ones win if more relevant.
abstract final class ProjectKnowledgePolicy {
  static final _words = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true);
  static const _stop = <String>{
    'است',
    'هست',
    'برای',
    'چرا',
    'چگونه',
    'درمورد',
    'درباره',
    'what',
    'about',
    'which',
    'where',
    'this',
    'that',
    'from',
    'the',
    'and',
    'are',
    'was',
    'with',
    'لطفا',
  };

  static Set<String> terms(String input) => {
    for (final match in _words.allMatches(
      input.toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک'),
    ))
      if (!_stop.contains(match.group(0)!)) match.group(0)!,
  };

  static List<SearchResult> rank(
    String question,
    Iterable<SearchResult> candidates, {
    required String specialistCollection,
    int maxResults = 16,
  }) {
    if (maxResults < 1 || maxResults > 32) {
      throw ArgumentError.value(maxResults, 'maxResults');
    }
    final query = terms(question);
    final scored =
        <({SearchResult source, int overlap, int specialized, int order})>[];
    final seen = <String>{};
    var index = 0;
    for (final source in candidates) {
      if (source.sponsored ||
          source.url.trim().isEmpty ||
          !seen.add(source.url)) {
        continue;
      }
      final body = source.pageText?.trim() ?? '';
      if (body.isEmpty && source.snippet.trim().isEmpty) continue;
      final excerpt =
          source.title + ' ' + (body.isNotEmpty ? body : source.snippet);
      final haystack = excerpt
          .toLowerCase()
          .replaceAll('ي', 'ی')
          .replaceAll('ك', 'ک');
      final coverage = query.where(haystack.contains).length;
      final specialist =
          specialistCollection.trim().isNotEmpty &&
          source.source == 'Knowledge · ' + specialistCollection.trim();
      scored.add((
        source: source,
        overlap: coverage,
        specialized: specialist ? 1 : 0,
        order: index++,
      ));
    }
    scored.sort((a, b) {
      final relevance = b.overlap.compareTo(a.overlap);
      if (relevance != 0) return relevance;
      final preferred = b.specialized.compareTo(a.specialized);
      if (preferred != 0) return preferred;
      return a.order.compareTo(b.order);
    });
    return [
      for (var i = 0; i < scored.length && i < maxResults; i++)
        scored[i].source.withRank(i + 1),
    ];
  }
}
