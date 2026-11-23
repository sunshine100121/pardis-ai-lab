import 'package:html/parser.dart' as html_parser;

/// Metadata-only link to a movie referenced by an HTML article in this ZIM.
class ZimVideoCandidate {
  const ZimVideoCandidate({
    required this.reference,
    required this.caption,
    this.subtitleReference,
    this.subtitleLanguage,
  });
  final String reference, caption;
  final String? subtitleReference, subtitleLanguage;
}

abstract final class ZimVideoSelection {
  static const maxVideos = 6;
  static const maxArticleHtml = 1024 * 1024;
  static final _videoExt = RegExp(
    r'\.(mp4|m4v|webm|ogv)$',
    caseSensitive: false,
  );
  static final _captionExt = RegExp(r'\.(vtt|srt)$', caseSensitive: false);

  /// Local relative paths only: no network, script or data URIs.
  static String? localReference(String? value, {bool caption = false}) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty || raw.length > 2048 || raw.startsWith('//')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasFragment ||
        uri.hasQuery ||
        uri.userInfo.isNotEmpty)
      return null;
    if (uri.pathSegments.any((s) => s == '..' || s == '.')) return null;
    return (caption ? _captionExt : _videoExt).hasMatch(uri.path)
        ? uri.path
        : null;
  }

  /// Never reads or downloads the media itself.
  static List<ZimVideoCandidate> fromArticleHtml(String html) {
    final limited = html.length <= maxArticleHtml
        ? html
        : html.substring(0, maxArticleHtml);
    final document = html_parser.parse(limited);
    final results = <ZimVideoCandidate>[];
    final seen = <String>{};
    void add(
      String? reference,
      String label, {
      String? subtitles,
      String? language,
    }) {
      final path = localReference(reference);
      if (path == null || !seen.add(path) || results.length >= maxVideos)
        return;
      results.add(
        ZimVideoCandidate(
          reference: path,
          caption: label.trim().isEmpty ? 'ویدئوی دانشنامه' : label.trim(),
          subtitleReference: localReference(subtitles, caption: true),
          subtitleLanguage: language,
        ),
      );
    }

    for (final video in document.querySelectorAll('video')) {
      final tracks = video
          .querySelectorAll('track')
          .where(
            (t) => localReference(t.attributes['src'], caption: true) != null,
          )
          .toList();
      tracks.sort((a, b) {
        int rank(String? l) =>
            l?.toLowerCase().startsWith('fa') == true ? 0 : 1;
        return rank(a.attributes['srclang'])
            .compareTo(rank(b.attributes['srclang']));
      });
      final track = tracks.isEmpty ? null : tracks.first;
      final caption =
          video.attributes['title'] ??
          video.parent?.querySelector('figcaption')?.text ??
          video.attributes['aria-label'] ??
          'ویدئوی دانشنامه';
      add(
        video.attributes['src'],
        caption,
        subtitles: track?.attributes['src'],
        language: track?.attributes['srclang'],
      );
      for (final source in video.querySelectorAll('source')) {
        add(
          source.attributes['src'],
          caption,
          subtitles: track?.attributes['src'],
          language: track?.attributes['srclang'],
        );
      }
    }
    for (final link in document.querySelectorAll('a[href]')) {
      add(link.attributes['href'], link.text);
    }
    return List.unmodifiable(results);
  }
}
