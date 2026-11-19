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
      final raw = (img.attributes['src'] ?? img.attributes['data-src'] ?? '')
          .trim();
      if (raw.isEmpty || raw.length > 2048) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null ||
          uri.hasScheme ||
          uri.hasAuthority ||
          raw.startsWith('//')) {
        continue;
      }
      final path = uri.path;
      if (!_extension.hasMatch(path) || !seen.add(path)) continue;
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
      final matches = terms.where(text.contains).length;
      final isDecoration = RegExp(
        r'logo|icon|badge|sprite|placeholder|favicon',
        caseSensitive: false,
      ).hasMatch(text);
      found.add(
        ZimImageCandidate(
          reference: path,
          caption: caption,
          score: matches * 10 - (isDecoration ? 20 : 0),
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
