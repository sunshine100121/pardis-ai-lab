import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../inference/engine/llama_engine.dart';
import '../models/domain/entities/model_info.dart';
import '../settings/domain/entities/inference_settings.dart';
import '../knowledge/knowledge_media.dart';
import '../voice/sherpa_voice.dart';
import 'zim_subtitles.dart';

/// Translation and optional speech transcription stay on the tablet.
abstract final class ZimVideoRuntime {
  static const segmentSeconds = 20;
  static const maxMovieSeconds = 60 * 60;

  static Future<String?> translateToPersian(
    String source,
    LlamaEngine engine,
    ModelFamily modelFamily,
    InferenceSettings settings, {
    bool Function()? cancelled,
  }) async {
    if (source.trim().isEmpty || cancelled?.call() == true) return null;
    if (!engine.isLoaded || engine.isBusy) {
      throw StateError('برای ترجمه، Qwen محلی باید آماده و آزاد باشد.');
    }
    final out = StringBuffer();
    Timer? timeout;
    try {
      timeout = Timer(const Duration(seconds: 60), engine.cancel);
      await for (final piece in engine.generate(
        messages: [
          {
            'role': 'system',
            'content': 'Translate the USER text accurately into natural Persian. '
                'Output only the translation. Preserve names and numbers. '
                'Do not summarize, explain, hallucinate or add statements '
                'that are not present in the source.'
          },
          {'role': 'user', 'content': source},
        ],
        fallbackTemplate: modelFamily.fallbackTemplate,
        settings: settings.copyWith(
          remoteEnabled: false,
          maxTokens: 256,
          temperature: 0,
          thinkingModeEnabled: false,
          promptCache: false,
        ),
      )) {
        if (cancelled?.call() == true) {
          engine.cancel();
          return null;
        }
        out.write(piece);
      }
      final translated = out.toString()
          .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '')
          .trim();
      return translated.isEmpty ? null : translated;
    } finally {
      timeout?.cancel();
    }
  }

  /// A failed cue retains the original with no claim of Persian accuracy.
  static Future<List<ZimSubtitleCue>> translateCaptions(
    List<ZimSubtitleCue> captions,
    LlamaEngine engine,
    ModelFamily modelFamily,
    InferenceSettings settings, {
    bool Function()? cancelled,
    void Function(int done, int total)? progress,
  }) async {
    final result = <ZimSubtitleCue>[];
    for (var i = 0; i < captions.length; i++) {
      if (cancelled?.call() == true) break;
      final cue = captions[i];
      final fa = await translateToPersian(
          cue.text, engine, modelFamily, settings, cancelled: cancelled);
      result.add(ZimSubtitleCue(cue.start, cue.end,
          fa?.trim().isNotEmpty == true ? fa! : cue.text));
      progress?.call(i + 1, captions.length);
    }
    return result;
  }

  /// Uses the already-installed local Whisper/Parakeet speech pack.
  /// Each caption spans approximately 20 seconds, not word-aligned.
  /// This is always user-triggered and never starts the microphone.
  static Future<List<ZimSubtitleCue>> transcribeVideo(
    File video,
    SherpaVoice speech,
    LlamaEngine engine,
    ModelFamily modelFamily,
    InferenceSettings settings, {
    bool Function()? cancelled,
    void Function(int done)? progress,
  }) async {
    if (!await SherpaVoice.canListen()) {
      throw StateError('بسته تشخیص گفتار آفلاین روی تبلت آماده نیست.');
    }
    if (!engine.isLoaded || engine.isBusy) {
      throw StateError('برای ترجمه، مدل Qwen محلی باید آماده باشد.');
    }
    File? wav;
    try {
      final decoded = await KnowledgeMedia.decodeAudio(video,
          maxSeconds: maxMovieSeconds, cancelled: cancelled);
      wav = decoded.$1;
      final length = decoded.$2;
      final cues = <ZimSubtitleCue>[];
      for (var index = 0; index * segmentSeconds < length; index++) {
        if (cancelled?.call() == true) break;
        final segment = await KnowledgeMedia.wavSegment(
            wav, index, seconds: segmentSeconds);
        if (segment == null) break;
        try {
          final samples = await KnowledgeMedia.transcriptionSamples(segment);
          if (!samples.any((x) => x.abs() > 0.0005)) continue;
          final heard = await speech.transcribe(samples, language: '');
          final original = heard?.text.trim() ?? '';
          if (original.isEmpty) continue;
          final alreadyPersian = heard?.language.toLowerCase()
                  .startsWith('fa') == true &&
              RegExp(r'[\u0600-\u06FF]').hasMatch(original);
          final translated = alreadyPersian ? original :
              await translateToPersian(original, engine, modelFamily,
                  settings, cancelled: cancelled);
          if (translated == null || translated.trim().isEmpty) continue;
          cues.add(ZimSubtitleCue(
            Duration(seconds: index * segmentSeconds),
            Duration(milliseconds:
                ((index + 1) * segmentSeconds * 1000)
                    .clamp(0, (length * 1000).round())),
            translated.trim(),
          ));
        } finally {
          if (await segment.exists()) await segment.delete();
          progress?.call(index + 1);
        }
      }
      return cues;
    } finally {
      if (wav != null && await wav.exists()) await wav.delete();
    }
  }
}
