/// Persistent identity for a future speech adapter plus model.
/// Parsing proves a safe ID, never that an adapter or model is installed.
enum VoiceSelectionKind { stt, tts }

class VoiceEngineSelection {
  final VoiceSelectionKind kind;
  final String adapter;
  final String model;
  const VoiceEngineSelection(this.kind, this.adapter, this.model);

  static final RegExp _format = RegExp(
    r'^(stt|tts):([a-z][a-z0-9_-]{0,31}):([a-z0-9][a-z0-9._-]{0,47}),
  );

  static VoiceEngineSelection? parse(String? id) {
    if (id == null || id.length > 96) return null;
    final match = _format.firstMatch(id);
    if (match == null) return null;
    return VoiceEngineSelection(
      match.group(1) == 'stt' ? VoiceSelectionKind.stt : VoiceSelectionKind.tts,
      match.group(2)!,
      match.group(3)!,
    );
  }

  String get id => '${kind.name}:$adapter:$model';
}
,
  );

  static VoiceEngineSelection? parse(String? id) {
    if (id == null || id.length > 96) return null;
    final match = _format.firstMatch(id);
    if (match == null) return null;
    return VoiceEngineSelection(
      match.group(1) == 'stt' ? VoiceSelectionKind.stt : VoiceSelectionKind.tts,
      match.group(2)!,
      match.group(3)!,
    );
  }

  String get id => '${kind.name}:$adapter:$model';
}
