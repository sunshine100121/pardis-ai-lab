import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:path/path.dart' as p;

import 'persian_sherpa_models.dart';
import 'sherpa_voice.dart';

/// Real NeMo CTC adapter for the Shenava Persian models in sherpa-onnx.
/// Config construction is independently testable without loading a model.
sherpa.OfflineRecognizerConfig persianCtcConfig(
  PersianSherpaModel model, {
  int threads = 4,
}) => sherpa.OfflineRecognizerConfig(
  model: sherpa.OfflineModelConfig(
    nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
      model: model.modelPath,
    ),
    tokens: model.tokensPath,
    numThreads: threads,
    debug: false,
  ),
);

sherpa.OfflineTtsConfig persianPiperConfig(
  PersianSherpaModel model, {
  int threads = 3,
}) => sherpa.OfflineTtsConfig(
  model: sherpa.OfflineTtsModelConfig(
    vits: sherpa.OfflineTtsVitsModelConfig(
      model: model.modelPath,
      tokens: model.tokensPath,
      dataDir: model.espeakPath,
    ),
    numThreads: threads,
    debug: false,
  ),
);

void _ctcWorkerMain(SendPort boot) {
  sherpa.initBindings();
  sherpa.OfflineRecognizer? recognizer;
  String? loaded;
  serveSherpaWorker(
    boot,
    (m) {
      final model = m['model'] as String;
      if (recognizer == null || loaded != model) {
        recognizer?.free();
        final dir = m['directory'] as String;
        recognizer = sherpa.OfflineRecognizer(
          sherpa.OfflineRecognizerConfig(
            model: sherpa.OfflineModelConfig(
              nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: model),
              tokens: p.join(dir, 'tokens.txt'),
              numThreads: 4,
              debug: false,
            ),
          ),
        );
        loaded = model;
      }
      final samples = (m['samples'] as TransferableTypedData)
          .materialize()
          .asFloat32List();
      final stream = recognizer!.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        recognizer!.decode(stream);
        return {'text': recognizer!.getResult(stream).text.trim()};
      } finally {
        stream.free();
      }
    },
    () => recognizer?.free(),
  );
}

void _piperWorkerMain(SendPort boot) {
  sherpa.initBindings();
  sherpa.OfflineTts? tts;
  String? loaded;
  serveSherpaWorker(
    boot,
    (m) {
      final path = m['model'] as String;
      if (tts == null || loaded != path) {
        tts?.free();
        final dir = m['directory'] as String;
        tts = sherpa.OfflineTts(
          sherpa.OfflineTtsConfig(
            model: sherpa.OfflineTtsModelConfig(
              vits: sherpa.OfflineTtsVitsModelConfig(
                model: path,
                tokens: p.join(dir, 'tokens.txt'),
                dataDir: p.join(dir, 'espeak-ng-data'),
              ),
              numThreads: 3,
              debug: false,
            ),
          ),
        );
        loaded = path;
      }
      final audio = tts!.generate(
        text: m['text'] as String,
        sid: 0,
        speed: (m['speed'] as num).toDouble().clamp(0.6, 1.6),
      );
      if (audio.samples.isEmpty || audio.sampleRate <= 0) {
        return {'error': 'این مدل Piper صدای قابل‌پخش تولید نکرد.'};
      }
      final pcm = Int16List(audio.samples.length);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (audio.samples[i].clamp(-1.0, 1.0) * 32767).round();
      }
      return {
        'pcm': TransferableTypedData.fromList([pcm]),
        'rate': audio.sampleRate,
      };
    },
    () => tts?.free(),
  );
}

/// One sentence at a time: audio is captured locally at 16 kHz and only
/// the final nonempty transcript is sent onward. Unknown engines never run.
class PersianCtcListener {
  final PersianSherpaModel model;
  final void Function(String text) onFinal;
  final void Function(String error) onError;

  PersianCtcListener({
    required this.model,
    required this.onFinal,
    required this.onError,
  });

  SherpaWorker? _worker;
  StreamSubscription<Float32List>? _subscription;
  Timer? _limit;
  final _frames = <Float32List>[];
  final _preroll = <Float32List>[];
  var _epoch = 0;
  var _speaking = false;
  var _afterSpeech = 0;
  var _sampleCount = 0;
  double _noise = 0.006;

  bool get running => _subscription != null;

  static double energy(Float32List frame) {
    if (frame.isEmpty) return 0;
    var sum = 0.0;
    for (final value in frame) {
      sum += value * value;
    }
    return math.sqrt(sum / frame.length);
  }

  /// 16 kHz, 512-sample windows. A threshold adapts slowly to idle noise,
  /// with a floor so quiet rooms do not trigger on every digital hiss.
  static bool containsVoice(double rms, double idleNoise) =>
      rms >= math.max(0.018, idleNoise * 3.2);

  Future<bool> start() async {
    if (running) return true;
    if (model.kind != PersianSherpaKind.stt) return false;
    final epoch = ++_epoch;
    _frames.clear();
    _preroll.clear();
    _speaking = false;
    _afterSpeech = 0;
    _sampleCount = 0;
    _noise = 0.006;
    _subscription = VoiceAudioChannel.frames().listen(_receive);
    try {
      if (!await VoiceAudioChannel.startMic() || epoch != _epoch) {
        await stop();
        return false;
      }
      _limit = Timer(const Duration(seconds: 30), () => unawaited(_finish()));
      return true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void _receive(Float32List frame) {
    if (!running) return;
    final rms = energy(frame);
    final speech = containsVoice(rms, _noise);
    if (!_speaking) {
      _preroll.add(frame);
      if (_preroll.length > 9) _preroll.removeAt(0);
      if (!speech) {
        _noise = 0.98 * _noise + 0.02 * rms;
        return;
      }
      _speaking = true;
      _frames.addAll(_preroll);
      _preroll.clear();
    }
    _frames.add(frame);
    _sampleCount += frame.length;
    if (speech) {
      _afterSpeech = 0;
    } else {
      _afterSpeech += frame.length;
      // About one second of silence ends a conversational utterance.
      if (_afterSpeech >= 16000) {
        unawaited(_finish());
      }
    }
    if (_sampleCount >= 30 * 16000) unawaited(_finish());
  }

  Future<void> _finish() async {
    if (!running) return;
    final epoch = _epoch;
    await _pauseMicrophone();
    if (_sampleCount < 6400) {
      if (epoch == _epoch) onError('هیچ جمله فارسی معتبری تشخیص داده نشد.');
      return;
    }
    final samples = Float32List(_frames.fold(0, (n, f) => n + f.length));
    var offset = 0;
    for (final frame in _frames) {
      samples.setAll(offset, frame);
      offset += frame.length;
    }
    try {
      final worker = _worker ??= await SherpaWorker.spawn(_ctcWorkerMain);
      final result = await worker.call({
        'model': model.modelPath,
        'directory': model.directory.path,
        'samples': TransferableTypedData.fromList([samples]),
      });
      if (epoch != _epoch) return;
      if (result['error'] != null) {
        onError('موتور شنوا نتوانست گفتار را پردازش کند.');
      } else {
        final text = (result['text'] as String? ?? '').trim();
        if (text.isEmpty) {
          onError('گفتار مشخصی تشخیص داده نشد.');
        } else {
          onFinal(text);
        }
      }
    } catch (_) {
      if (epoch == _epoch) onError('بارگذاری یا اجرای مدل شنوا ناموفق بود.');
    } finally {
      _worker?.dispose();
      _worker = null;
      _frames.clear();
    }
  }

  Future<void> _pauseMicrophone() async {
    _limit?.cancel();
    _limit = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await VoiceAudioChannel.stopMic();
    } catch (_) {}
  }

  Future<void> stop() async {
    _epoch++;
    await _pauseMicrophone();
    _frames.clear();
    _preroll.clear();
    _worker?.dispose();
    _worker = null;
  }

  void dispose() => unawaited(stop());
}

class PersianPiperSpeaker {
  SherpaWorker? _worker;
  var _epoch = 0;
  bool _playing = false;

  Future<bool> play(
    PersianSherpaModel model,
    String text, {
    double speed = 1,
  }) async {
    if (model.kind != PersianSherpaKind.tts || text.trim().isEmpty) return false;
    final epoch = ++_epoch;
    final worker = _worker ??= await SherpaWorker.spawn(_piperWorkerMain);
    final result = await worker.call({
      'model': model.modelPath,
      'directory': model.directory.path,
      'text': text,
      'speed': speed,
    });
    if (epoch != _epoch) return false;
    if (result['error'] != null) {
      throw StateError('مدل Piper نتوانست صدا تولید کند.');
    }
    final samples = (result['pcm'] as TransferableTypedData)
        .materialize()
        .asInt16List();
    _playing = true;
    try {
      return await VoiceAudioChannel.play(
        SpeechAudio(samples, result['rate'] as int),
      );
    } finally {
      _playing = false;
    }
  }

  Future<void> stop() async {
    _epoch++;
    if (_playing) {
      _playing = false;
      await VoiceAudioChannel.stopPlayback();
    }
  }

  void dispose() {
    unawaited(stop());
    _worker?.dispose();
    _worker = null;
  }
}
