import 'package:html/parser.dart' as html_parser;

/// Offline article image metadata. No network requests or binary image copies.
/// Actual image bytes must be read from the same approved ZIM archive only.
class ZimImageCandidate {
  const ZimImageCandidate({
    required this.reference,
    required this.caption,
    required this.score,
  });

  final String reference;
  final String caption;
  final int score;
}

class ZimImageSelection {
  const ZimImageSelection(this.foundCount, this.candidates);

  /// Show two local images first, then offer the others on a user request.
  static const initialCount = 2;
  static const candidateLimit = 6;

  final int foundCount;
  final List<ZimImageCandidate> candidates;

  List<ZimImageCandidate> get initial => candidates.take(initialCount).toList();
  List<ZimImageCandidate> get more => candidates.skip(initialCount).toList();

  static final _words = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true);
  static final _extension = RegExp(
    r'\.(?:jpe?g|png|webp|gif)$',
    caseSensitive: false,
  );

  static String? _localImagePath(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || raw.length > 2048 || raw.startsWith('//')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
    return _extension.hasMatch(uri.path) ? uri.path : null;
  }

  /// Metadata-only discovery. Deliberately rejects remote/data/blob links;
  /// never loads an entire multimedia ZIM or fetches images from the web.
  static ZimImageSelection fromArticleHtml(
    String articleHtml,
    String question,
  ) {
    // A text-only preview can be much longer than needed for image selection.
    // Limit parsing work independently of the size of the archive.
    final body = articleHtml.length > 1024 * 1024
        ? articleHtml.substring(0, 1024 * 1024)
        : articleHtml;
    final document = html_parser.parse(body);
    final terms = _words
        .allMatches(question.toLowerCase())
        .map((m) => m.group(0)!)
        .toSet();
    final seen = <String>{};
    final found = <ZimImageCandidate>[];
    for (final img in document.querySelectorAll('img')) {
      // Some Kiwix pages keep a small placeholder in src and the real
      // local asset in data-src or srcset. Never fall back to a remote URL.
      final srcset = img.attributes['srcset']
          ?.split(',')
          .first
          .trim()
          .split(RegExp(r'\s+'))
          .first;
      final path =
          _localImagePath(img.attributes['src']) ??
          _localImagePath(img.attributes['data-src']) ??
          _localImagePath(srcset);
      if (path == null || !seen.add(path)) continue;
      final alt = img.attributes['alt'] ?? '';
      final title = img.attributes['title'] ?? '';
      final caption = [
        alt,
        title,
        img.parent?.localName == 'figure'
            ? img.parent?.querySelector('figcaption')?.text ?? ''
            : '',
      ].where((t) => t.trim().isNotEmpty).join(' ').trim();
      final text = '$caption $path'.toLowerCase();
      // Prioritise the asked symptom/problem, not merely a general photo
      // of the same tree. This is a transparent lexical ranking, not
      // image recognition or a diagnosis of a photographed pest.
      const focus = {
        'آفت', 'آفات', 'بیماری', 'بیماریها', 'بیماری‌ها', 'نشانه',
        'symptom', 'pest', 'disease', 'damage',
      };
      final matches = terms.fold<int>(
        0,
        (score, term) =>
            score + (text.contains(term) ? (focus.contains(term) ? 20 : 10) : 0),
      );
      final isDecoration = RegExp(
        r'logo|icon|badge|sprite|placeholder|favicon',
        caseSensitive: false,
      ).hasMatch(text);
      found.add(
        ZimImageCandidate(
          reference: path,
          caption: caption,
          score: matches - (isDecoration ? 200 : 0),
        ),
      );
    }
    found.sort((a, b) => b.score.compareTo(a.score));
    return ZimImageSelection(
      found.length,
      List.unmodifiable(found.take(candidateLimit)),
    );
  }
}
