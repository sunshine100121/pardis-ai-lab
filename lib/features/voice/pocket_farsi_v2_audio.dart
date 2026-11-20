import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'sherpa_voice.dart';

/// Isolated prototype for native Persian Pocket Farsi v2. NOT the default
/// TTS engine; no automatic fallback from Gyro. Never downloads assets.
abstract final class PocketFarsiV2Audio {
  static const _channel = MethodChannel('pala/pocket_farsi_v2_audio');

  /// Explicit diagnostic invocation only. Generated PCM is played by the
  /// existing local voice channel; failed synthesis leaves Gyro unchanged.
  static Future<Map<String, num>> synthesizeAndPlay(String persianText) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'synthesize',
      {'text': persianText},
    );
    if (response == null ||
        response['engine'] != 'pocket-farsi-v2-native-onnx-prototype' ||
        response['audioGenerated'] != true ||
        response['rate'] != 24000 ||
        response['pcm'] is! Uint8List) {
      throw StateError('Pocket Farsi v2 has not generated verified audio');
    }
    final bytes = response['pcm'] as Uint8List;
    if (bytes.isEmpty || bytes.lengthInBytes.isOdd) {
      throw StateError('The generated PCM output is invalid');
    }
    final values = Int16List(bytes.lengthInBytes ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < values.length; i++) {
      values[i] = data.getInt16(i * 2, Endian.little);
    }
    final played = await VoiceAudioChannel.play(SpeechAudio(values, 24000));
    if (!played) {
      throw StateError('Pocket Farsi v2 audio playback was interrupted');
    }
    return {
      'generationMs': (response['generationMs'] as num?) ?? 0,
      'audioMs': (response['audioMs'] as num?) ?? 0,
    };
  }
}
