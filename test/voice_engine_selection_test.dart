import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/voice/voice_choice_storage.dart';
import 'package:ondevice_llm/features/voice/voice_engine_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('separate custom STT/TTS selections survive persistence', () async {
    SharedPreferences.setMockInitialValues({});
    await VoiceChoiceStorage.choose(
      VoiceSelectionKind.stt,
      'stt:vosk:persian-large',
    );
    await VoiceChoiceStorage.choose(
      VoiceSelectionKind.tts,
      'tts:piper:fa_ir-custom',
    );
    expect(
      await VoiceChoiceStorage.current(VoiceSelectionKind.stt),
      'stt:vosk:persian-large',
    );
    expect(
      await VoiceChoiceStorage.current(VoiceSelectionKind.tts),
      'tts:piper:fa_ir-custom',
    );
    await expectLater(
      VoiceChoiceStorage.choose(
        VoiceSelectionKind.tts,
        'stt:vosk:persian-large',
      ),
      throwsFormatException,
    );
    await VoiceChoiceStorage.clear(VoiceSelectionKind.stt);
    expect(await VoiceChoiceStorage.current(VoiceSelectionKind.stt), isNull);
    expect(
      await VoiceChoiceStorage.current(VoiceSelectionKind.tts),
      'tts:piper:fa_ir-custom',
    );
  });

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

  test('official downloaded Vosk ZIP hash IDs may start with a digit', () async {
    SharedPreferences.setMockInitialValues({});
    // Official vosk-model-small-fa-0.42.zip SHA-256 starts with 977c.
    const selected = 'stt:vosk:977cb5faa538f3a8';
    final parsed = VoiceEngineSelection.parse(selected);
    expect(parsed?.kind, VoiceSelectionKind.stt);
    expect(parsed?.adapter, 'vosk');
    expect(parsed?.model, '977cb5faa538f3a8');
    await VoiceChoiceStorage.choose(VoiceSelectionKind.stt, selected);
    expect(await VoiceChoiceStorage.current(VoiceSelectionKind.stt), selected);
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
