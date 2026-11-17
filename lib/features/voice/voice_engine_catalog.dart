/// Small in-app catalog for the speech adapters PALA actually knows how to
/// run. New models add one descriptor and an adapter route; this is not a
/// user-loaded plugin system.
enum VoiceEngineKind { stt, tts }

class VoiceEngineDescriptor {
  final String id;
  final String name;
  final VoiceEngineKind kind;
  final Set<String> languages;
  final String? modelPackId;
  const VoiceEngineDescriptor({
    required this.id,
    required this.name,
    required this.kind,
    required this.languages,
    this.modelPackId,
  });

  bool supports(String language) => languages.contains(language);
}

abstract final class VoiceEngineCatalog {
  static const androidStt = VoiceEngineDescriptor(
    id: 'android-local',
    name: 'Android on-device',
    kind: VoiceEngineKind.stt,
    languages: {'fa'},
  );
  static const whisperFa = VoiceEngineDescriptor(
    id: 'whisper-fa',
    name: 'Whisper multilingual',
    kind: VoiceEngineKind.stt,
    languages: {'fa', 'en', 'fr', 'es'},
    modelPackId: 'whisper-base',
  );
  static const voskFa = VoiceEngineDescriptor(
    id: 'vosk-fa',
    name: 'Vosk Persian',
    kind: VoiceEngineKind.stt,
    languages: {'fa'},
    modelPackId: 'vosk-small-fa-0.42',
  );
  static const stt = [androidStt, whisperFa, voskFa];

  /// Android engines are enumerated at runtime. These app-local voices remain
  /// available only for the languages their installed packs actually speak.
  static const kokoro = VoiceEngineDescriptor(
    id: 'kokoro',
    name: 'Kokoro',
    kind: VoiceEngineKind.tts,
    languages: {'en', 'fr', 'es'},
    modelPackId: 'kokoro-v1.0',
  );
  static const supertonic = VoiceEngineDescriptor(
    id: 'supertonic-2',
    name: 'Supertonic 2',
    kind: VoiceEngineKind.tts,
    languages: {'en'},
    modelPackId: 'supertonic-2',
  );

  static String androidEngineName(String packageId) {
    final lower = packageId.toLowerCase();
    if (lower.contains('hayai')) return 'HayaiTTS · $packageId';
    return packageId;
  }
}
