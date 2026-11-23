import 'dart:io';

import 'zim_subtitles.dart';

/// Verified local clip in app-private scratch. Delete [file] after playback.
class ZimPlayableVideo {
  const ZimPlayableVideo({
    required this.file,
    required this.cues,
    required this.revision,
    this.subtitleLanguage,
  });
  final File file;
  /// Exact approved SAF/file revision; prevents using stale caption caches.
  final String revision;
  final List<ZimSubtitleCue> cues;
  final String? subtitleLanguage;
}
