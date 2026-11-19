import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/voice_engine_selection.dart';

void main() {
  test('model identities are separate for STT and TTS', () {
    final stt = VoiceEngineSelection.parse('stt:vosk:persian-large');
    final tts = VoiceEngineSelection.parse('tts:piper:fa_ir-custom');
    expect(stt?.kind, VoiceSelectionKind.stt);
    expect(stt?.adapter, 'vosk');
    expect(stt?.id, 'stt:vosk:persian-large');
    expect(tts?.kind, VoiceSelectionKind.tts);
    expect(tts?.model, 'fa_ir-custom');
    expect(tts?.id, 'tts:piper:fa_ir-custom');
  });

  test('invalid and unsafe model identities are not accepted', () {
    for (final candidate in [
      'stt:vosk:../private',
      'tts:piper:../private',
      'stt:vosk:my model',
      'stt:vosk:my/model',
      'https://example.net/file',
      'tts:piper:',
      'stt:vosk:\\..\\file',
    ]) {
      expect(VoiceEngineSelection.parse(candidate), isNull);
    }
  });
}
