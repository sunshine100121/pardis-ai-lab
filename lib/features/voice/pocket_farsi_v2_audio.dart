import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'sherpa_voice.dart';

class PocketGeneratedAudio {
  final SpeechAudio audio;
  final int generationMs;
  final int audioMs;

  const PocketGeneratedAudio(this.audio, this.generationMs, this.audioMs);
}

/// Experimental, explicitly invoked PCM bridge. NOT a selectable default TTS.
/// Each call runs native ONNX locally, without network or paid APIs.
abstract final class PocketFarsiV2Audio {
  static const _channel = MethodChannel('pala/pocket_farsi_v2_audio');

  static Future<PocketGeneratedAudio> synthesize(String persianText) async {
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
    if (bytes.isEmpty || bytes.lengthInBytes.isOdd ||
        bytes.lengthInBytes > 24000 * 90 * 2) {
      throw StateError('Pocket Farsi v2 PCM is empty or out of bounds');
    }
    final values = Int16List(bytes.lengthInBytes ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < values.length; i++) {
      values[i] = data.getInt16(i * 2, Endian.little);
    }
    return PocketGeneratedAudio(
      SpeechAudio(values, 24000),
      (response['generationMs'] as num?)?.toInt() ?? 0,
      (response['audioMs'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<bool> play(PocketGeneratedAudio clip) =>
      VoiceAudioChannel.play(clip.audio);

  static Future<void> stopPlayback() => VoiceAudioChannel.stopPlayback();

  /// Compatibility with earlier explicit diagnostic invocations.
  static Future<Map<String, num>> synthesizeAndPlay(String text) async {
    final clip = await synthesize(text);
    if (!await play(clip)) {
      throw StateError('Pocket Farsi v2 audio playback was interrupted');
    }
    return {
      'generationMs': clip.generationMs,
      'audioMs': clip.audioMs,
    };
  }
}
