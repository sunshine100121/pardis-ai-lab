import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/conversation_voice_policy.dart';

void main() {
  bool ready({
    bool closed = false,
    bool away = false,
    bool muted = false,
    bool naturalMode = false,
    bool isListening = false,
    bool isSpeaking = false,
    bool isThinking = false,
    bool chatGenerating = false,
  }) => ConversationVoicePolicy.canStartMicrophone(
    closed: closed,
    away: away,
    muted: muted,
    naturalMode: naturalMode,
    isListening: isListening,
    isSpeaking: isSpeaking,
    isThinking: isThinking,
    chatGenerating: chatGenerating,
  );

  test('Persian microphone runs only in idle and foreground', () {
    expect(ready(), isTrue);
    expect(ready(closed: true), isFalse);
    expect(ready(away: true), isFalse);
    expect(ready(muted: true), isFalse);
    expect(ready(naturalMode: true), isFalse);
  });
  test('never record over a previous voice, Qwen or active recording', () {
    expect(ready(isListening: true), isFalse);
    expect(ready(isSpeaking: true), isFalse);
    expect(ready(isThinking: true), isFalse);
    expect(ready(chatGenerating: true), isFalse);
  });

  bool resume({
    bool closed = false,
    bool away = false,
    bool muted = false,
    bool naturalMode = false,
    bool turnActive = false,
    bool chatGenerating = false,
    bool speaking = false,
    bool playbackFailed = false,
    bool cancelled = false,
  }) => ConversationVoicePolicy.canResumeAfterSpeech(
    closed: closed,
    away: away,
    muted: muted,
    naturalMode: naturalMode,
    turnActive: turnActive,
    chatGenerating: chatGenerating,
    speaking: speaking,
    playbackFailed: playbackFailed,
    cancelled: cancelled,
  );

  test('conversation resumes only after completed, successful speech', () {
    expect(resume(), isTrue);
    expect(resume(turnActive: true), isFalse);
    expect(resume(chatGenerating: true), isFalse);
    expect(resume(speaking: true), isFalse);
    expect(resume(away: true), isFalse);
    expect(resume(muted: true), isFalse);
    expect(resume(playbackFailed: true), isFalse);
    expect(resume(cancelled: true), isFalse);
    expect(resume(closed: true), isFalse);
  });
}
