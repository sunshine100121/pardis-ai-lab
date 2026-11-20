import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Experimental read-only ONNX probe. NOT a selectable voice/TTS engine.
/// Never silently switches the user's HayaiTTS/Gyro, installs packs or
/// invokes an online endpoint. Missing weights are a normal outcome.
abstract final class PocketFarsiV2Probe {
  static const _channel = MethodChannel('pala/pocket_farsi_v2_probe');

  @visibleForTesting
  static MethodChannel get channel => _channel;

  static Future<Map<String, dynamic>> inspect() async =>
      Map<String, dynamic>.from(
        (await _channel.invokeMapMethod<String, dynamic>('inspect')) ?? {},
      );

  /// Real native ByT5 ONNX graphs only. No generated audio yet.
  /// Latin words, numbers and other unported normalization cases fail closed.
  static Future<String> phonemise(String persianText) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'phonemise',
      {'text': persianText},
    );
    if (result?['audioGenerated'] != false || result?['stage'] != 'g2p-only') {
      throw StateError('Pocket speech inference is not verified');
    }
    return result?['phonemes'] as String? ?? '';
  }
}
