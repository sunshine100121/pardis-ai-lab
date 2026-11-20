import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/pocket_farsi_v2_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pocket = MethodChannel('pala/pocket_farsi_v2_audio');
  const audio = MethodChannel('ondevice_llm/voice_audio');

  tearDown(() async {
    messenger.setMockMethodCallHandler(pocket, null);
    messenger.setMockMethodCallHandler(audio, null);
  });

  test('an actual PCM response uses existing local playback without switching voices',
      () async {
    var calls = 0;
    var played = 0;
    messenger.setMockMethodCallHandler(pocket, (call) async {
      expect(call.method, 'synthesize');
      expect((call.arguments as Map)['text'], 'سلام');
      calls++;
      return {
        'engine': 'pocket-farsi-v2-native-onnx-prototype',
        'audioGenerated': true,
        'rate': 24000,
        'pcm': Uint8List.fromList([0, 0, 1, 0, 255, 127, 0, 128]),
        'generationMs': 800,
        'audioMs': 1,
      };
    });
    messenger.setMockMethodCallHandler(audio, (call) async {
      expect(call.method, 'play');
      expect((call.arguments as Map)['rate'], 24000);
      played++;
      return true;
    });

    final timing = await PocketFarsiV2Audio.synthesizeAndPlay('سلام');
    expect(calls, 1);
    expect(played, 1);
    expect(timing['generationMs'], 800);
  });

  test('missing actual synthesized audio must not trigger playback', () async {
    var played = false;
    messenger.setMockMethodCallHandler(pocket, (call) async {
      return {'audioGenerated': false, 'rate': 24000};
    });
    messenger.setMockMethodCallHandler(audio, (call) async {
      played = true;
      return true;
    });
    await expectLater(
      PocketFarsiV2Audio.synthesizeAndPlay('سلام'),
      throwsStateError,
    );
    expect(played, false);
  });

  test('native model error remains an error; no silent Piper fallback', () async {
    messenger.setMockMethodCallHandler(pocket, (call) async {
      throw PlatformException(code: 'POCKET_AUDIO_UNVERIFIED');
    });
    await expectLater(
      PocketFarsiV2Audio.synthesizeAndPlay('سلام'),
      throwsA(isA<PlatformException>()),
    );
  });
  test('cancellation and runtime release are explicit native actions', () async {
    final called = <String>[];
    messenger.setMockMethodCallHandler(pocket, (call) async {
      called.add(call.method);
      return true;
    });
    await PocketFarsiV2Audio.cancelSynthesis();
    await PocketFarsiV2Audio.release();
    expect(called, ['cancel', 'release']);
  });

}
