import 'dart:io';

import 'zim_subtitles.dart';

/// Verified local clip in app-private scratch. Delete [file] after playback.
class ZimPlayableVideo {
  const ZimPlayableVideo({
    required this.file,
    required this.cues,
    this.subtitleLanguage,
  });
  final File file;
  final List<ZimSubtitleCue> cues;
  final String? subtitleLanguage;
}
