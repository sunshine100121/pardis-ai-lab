import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/persian_sherpa_models.dart';
import 'package:ondevice_llm/features/voice/persian_sherpa_runtime.dart';

import 'dart:io';

void main() {
  final root = Directory('/synthetic-models');
  final stt = PersianSherpaModel(
    id: '0123456789abcdef',
    label: 'شنوا',
    directory: root,
    onnxFile: 'model.onnx',
    kind: PersianSherpaKind.stt,
  );
  final tts = PersianSherpaModel(
    id: 'fedcba9876543210',
    label: 'Piper فارسی',
    directory: root,
    onnxFile: 'fa_IR-gyro-medium.onnx',
    kind: PersianSherpaKind.tts,
  );

  test('NeMo-CTC Shenava is truly a sherpa offline recognizer config', () {
    final config = persianCtcConfig(stt);
    expect(config.model.nemoCtc.model, '/synthetic-models/model.onnx');
    expect(config.model.tokens, '/synthetic-models/tokens.txt');
    expect(config.model.numThreads, 4);
  });

  test('Piper/VITS uses native ONNX with local Persian phonemizer files', () {
    final config = persianPiperConfig(tts);
    expect(config.model.vits.model, contains('gyro-medium.onnx'));
    expect(config.model.vits.tokens, '/synthetic-models/tokens.txt');
    expect(config.model.vits.dataDir, '/synthetic-models/espeak-ng-data');
  });

  test('speech segmentation rejects silence and preserves clear voice', () {
    expect(PersianCtcListener.energy(Float32List(512)), 0);
    expect(PersianCtcListener.containsVoice(0.002, 0.002), isFalse);
    expect(PersianCtcListener.containsVoice(0.06, 0.002), isTrue);
    expect(PersianCtcListener.containsVoice(0.02, 0.03), isFalse);
  });
}
