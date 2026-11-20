import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/persian_stt_policy.dart';

void main() {
  test('legacy default selects Android even when Whisper is installed', () {
    expect(PersianSttPolicy.selected(''), 'android-local');
    expect(PersianSttPolicy.selected('whisper-fa'), 'whisper-fa');
    expect(PersianSttPolicy.selected('vosk-fa'), 'vosk-fa');
    expect(PersianSttPolicy.selected('parakeet-v3'), 'android-local');
    expect(
      PersianSttPolicy.selected('stt:vosk:persian-large'),
      'stt:vosk:persian-large',
    );
    expect(
      PersianSttPolicy.ready(
        setting: 'stt:vosk:persian-large',
        androidReady: true,
        whisperReady: true,
        voskReady: true,
      ),
      false,
    );
    expect(
      PersianSttPolicy.ready(
        setting: '',
        androidReady: false,
        whisperReady: true,
        voskReady: true,
      ),
      false,
    );
  });

  test('installed imported Vosk overrides a legacy Whisper preference', () {
    expect(
      PersianSttPolicy.effective('whisper-fa', customVoskReady: true),
      'vosk-fa',
    );
    expect(
      PersianSttPolicy.effective('whisper-fa', customVoskReady: false),
      'whisper-fa',
    );
  });

  test('fallback is manual and does not start or download any engine', () {
    expect(
      PersianSttPolicy.unavailable(
        setting: 'android-local',
        androidReady: false,
        whisperReady: true,
        voskReady: false,
      ),
      contains('Whisper'),
    );
    expect(
      PersianSttPolicy.unavailable(
        setting: 'vosk-fa',
        androidReady: true,
        whisperReady: false,
        voskReady: false,
      ),
      contains('Android'),
    );
    expect(
      PersianSttPolicy.unavailable(
        setting: 'android-local',
        androidReady: false,
        whisperReady: false,
        voskReady: false,
      ),
      contains('هیچ موتور فارسی'),
    );
    expect(
      PersianSttPolicy.unavailable(
        setting: 'stt:vosk:persian-large',
        androidReady: true,
        whisperReady: true,
        voskReady: true,
      ),
      contains('آداپتور اجرایی'),
    );
  });

  test('only a real nonempty final sentence is a Qwen question', () {
    expect(PersianSttPolicy.finalPrompt('   '), isNull);
    expect(
      PersianSttPolicy.finalPrompt('  دمای باغ الان چقدره؟  '),
      'دمای باغ الان چقدره؟',
    );
  });
}
