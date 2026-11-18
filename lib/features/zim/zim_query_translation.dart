import 'dart:async';

import '../../inference/engine/llama_engine.dart';
import '../settings/domain/entities/inference_settings.dart';

/// Produces English search terms using the already-loaded local llama engine.
/// The caller must own the engine for this entire operation; this helper does
/// not start a model, choose a source, or transmit a question to a server.
class ZimQueryTranslation {
  static Future<String?> englishTerms(String question, {
    required LlamaEngine engine,
    required InferenceSettings settings,
    required String fallbackTemplate,
    required bool Function() cancelled,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (question.trim().isEmpty || question.length > 2000 || cancelled()) return null;
    if (!RegExp(r'[\u0600-\u06ff]').hasMatch(question)) return question.trim();
    if (timeout <= Duration.zero) throw ArgumentError('Invalid translation timeout');
    final result = StringBuffer();
    final clock = Stopwatch()..start();
    try {
      final output = engine.generate(
        messages: [
          {'role': 'system', 'content': 'Translate the user question into a short English search query. Output only the search terms, no explanation or answer.'},
          {'role': 'user', 'content': question},
        ],
        fallbackTemplate: fallbackTemplate,
        settings: settings.copyWith(remoteEnabled: false, thinkingModeEnabled: false,
            maxTokens: 48, temperature: 0),
      ).timeout(timeout, onTimeout: (sink) {
        engine.cancel();
        sink.addError(TimeoutException('Local query translation timed out'));
        sink.close();
      });
      await for (final chunk in output) {
        if (cancelled() || clock.elapsed > timeout || result.length + chunk.length > 1024) {
          engine.cancel();
          return null;
        }
        result.write(chunk);
      }
    } catch (_) {
      return null;
    }
    if (cancelled()) return null;
    var text = result.toString();
    if (text.contains('<think>') && !text.contains('</think>')) return null;
    text = text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), ' ');
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
    final words = RegExp(r'[A-Za-z0-9]+').allMatches(text)
        .map((m) => m.group(0)!).where((w) => w.length > 1).take(12).toList();
    return words.isEmpty ? null : words.join(' ');
  }
}
