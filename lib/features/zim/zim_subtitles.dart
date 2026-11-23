/// Local SRT / WebVTT tracks and user-requested offline speech transcripts.
class ZimSubtitleCue {
  const ZimSubtitleCue(this.start, this.end, this.text);
  final Duration start, end;
  final String text;
}

abstract final class ZimSubtitles {
  static const maxCaptionCharacters = 1024 * 1024;

  static List<ZimSubtitleCue> parse(String raw) {
    if (raw.length > maxCaptionCharacters) {
      throw const FormatException('زیرنویس بیش از حد بزرگ است');
    }
    final normalized = raw
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));
    final result = <ZimSubtitleCue>[];
    final pattern = RegExp(
      r'((?:\d{1,3}:)?\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*'
      r'((?:\d{1,3}:)?\d{2}:\d{2}[,.]\d{1,3})',
    );
    for (final block in blocks) {
      final lines = block.split('\n');
      final at = lines.indexWhere((line) => pattern.hasMatch(line));
      if (at < 0 || at + 1 >= lines.length) continue;
      final match = pattern.firstMatch(lines[at])!;
      final start = _timestamp(match.group(1)!);
      final end = _timestamp(match.group(2)!);
      if (start == null || end == null || end <= start) continue;
      final text = lines
          .skip(at + 1)
          .map(
            (line) => line
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .replaceAll(RegExp(r'\{\\an\d+\}'), '')
                .trim(),
          )
          .where((line) => line.isNotEmpty)
          .join('\n');
      if (text.isEmpty) continue;
      result.add(ZimSubtitleCue(start, end, text));
      if (result.length >= 5000) break;
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return List.unmodifiable(result);
  }

  static Duration? _timestamp(String raw) {
    final parts = raw.replaceAll(',', '.').split(':');
    if (parts.length != 2 && parts.length != 3) return null;
    final last = parts.last.split('.');
    if (last.length != 2) return null;
    final seconds = int.tryParse(last[0]);
    final fraction = int.tryParse(last[1].padRight(3, '0'));
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts[0]) : 0;
    if (seconds == null ||
        minutes == null ||
        hours == null ||
        fraction == null ||
        minutes > 59 ||
        seconds > 59)
      return null;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: fraction,
    );
  }

  static String? at(List<ZimSubtitleCue> cues, Duration elapsed) {
    for (final cue in cues) {
      if (cue.start > elapsed) break;
      if (cue.start <= elapsed && elapsed < cue.end) return cue.text;
    }
    return null;
  }

  static String clock(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String fullText(List<ZimSubtitleCue> cues) =>
      cues.map((c) => '${clock(c.start)}  ${c.text}').join('\n\n');

  static String srt(List<ZimSubtitleCue> cues) {
    String stamp(Duration d) =>
        '${clock(d)},${(d.inMilliseconds % 1000).toString().padLeft(3, '0')}';
    return [
      for (var i = 0; i < cues.length; i++)
        '${i + 1}\n${stamp(cues[i].start)} --> ${stamp(cues[i].end)}\n${cues[i].text}',
    ].join('\n\n');
  }
}
