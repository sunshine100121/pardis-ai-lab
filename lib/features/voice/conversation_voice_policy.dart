/// Prevent overlapping microphone recording, Qwen generation, and TTS.
/// This pure policy never starts any native audio engine.
abstract final class ConversationVoicePolicy {
  static bool canStartMicrophone({
    required bool closed,
    required bool away,
    required bool muted,
    required bool naturalMode,
    required bool isListening,
    required bool isSpeaking,
    required bool isThinking,
    required bool chatGenerating,
  }) =>
      !closed &&
      !away &&
      !muted &&
      !naturalMode &&
      !isListening &&
      !isSpeaking &&
      !isThinking &&
      !chatGenerating;
}
