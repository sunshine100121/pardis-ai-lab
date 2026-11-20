import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ondevice_llm/features/voice/voice_choice_storage.dart';
import 'package:ondevice_llm/features/voice/voice_engine_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'pala_voice_android_tts_engine_v1': 'hayai.local',
      'pala_voice_android_tts_voice_v1': 'gyro',
    });
  });

  test('Pocket adapter selection requires explicit action, keeps Gyro', () async {
    expect(await VoiceChoiceStorage.current(VoiceSelectionKind.tts), isNull);
    const id = 'tts:pocket-farsi-v2:onnx';
    final parsed = VoiceEngineSelection.parse(id);
    expect(parsed?.adapter, 'pocket-farsi-v2');
    expect(parsed?.model, 'onnx');
    await VoiceChoiceStorage.choose(VoiceSelectionKind.tts, id);
    expect(await VoiceChoiceStorage.current(VoiceSelectionKind.tts), id);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pala_voice_android_tts_engine_v1'), 'hayai.local');
    expect(prefs.getString('pala_voice_android_tts_voice_v1'), 'gyro');
    await VoiceChoiceStorage.clear(VoiceSelectionKind.tts);
    expect(await VoiceChoiceStorage.current(VoiceSelectionKind.tts), isNull);
  });
}
