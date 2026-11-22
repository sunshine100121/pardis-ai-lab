import 'dart:async';

import '../../inference/engine/llama_engine.dart';
import '../settings/domain/entities/inference_settings.dart';

/// Produces English search terms using the already-loaded local llama engine.
/// The caller must own the engine for this entire operation; this helper does
/// not start a model, choose a source, or transmit a question to a server.
class ZimQueryTranslation {
  /// Fast, fully offline bilingual search terms for frequent specialist
  /// topics. This is lexical expansion, NOT document translation, and does
  /// not start Qwen. Unknown subjects still use the existing local fallback.
  static String? fastSpecialistTerms(String question) {
    final q = question.toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک');
    if (q.trim().isEmpty || q.length > 2000) return null;
    final latin = RegExp(r'[a-z0-9]+')
        .allMatches(q.replaceAll(
          RegExp(r'[a-z0-9_.-]+\.(?:zim|pdf)\b'),
          ' ',
        ))
        .map((m) => m.group(0)!)
        .where((word) => word.length > 2 && !_englishStop.contains(word))
        .toSet();
    final terms = <String>{};
    final entries = <({RegExp pattern, List<String> terms})>[
      (pattern: RegExp(r'بادام|almond'), terms: ['almond']),
      (pattern: RegExp(r'گردو|walnut'), terms: ['walnut']),
      (pattern: RegExp(r'انجیر|\bfig\b'), terms: ['fig']),
      (pattern: RegExp(r'گیاه|کاشت|درخت|باغ|\btrees?\b|\bgarden\b|plant'), terms: ['tree', 'plant']),
      (pattern: RegExp(r'سرما|یخبندان|یخ زد|frost|\bfreez|\bcold\b'), terms: ['frost', 'cold']),
      (pattern: RegExp(r'پاییز|autumn|\bfall\b'), terms: ['autumn']),
      (pattern: RegExp(r'محافظت|نگهداری|پوشاندن|protect|\bcover\b'), terms: ['protect']),
      (pattern: RegExp(r'آبیاری|irrigat|watering'), terms: ['watering', 'irrigation']),
      (pattern: RegExp(r'هرس|prun'), terms: ['pruning']),
      (pattern: RegExp(r'خاک|\bsoil\b'), terms: ['soil']),
      (pattern: RegExp(r'اصفهان|isfahan|esfahan'), terms: ['isfahan']),
      (pattern: RegExp(r'شیراز|shiraz'), terms: ['shiraz']),
      (pattern: RegExp(r'سفر|گردشگر|جاذبه|گردشگری|sightsee|travel|touris'), terms: ['travel', 'tourism']),
      (pattern: RegExp(r'تاریخی|historical'), terms: ['historic']),
      (pattern: RegExp(r'خانه هوشمند|هوم اسیستنت|home assistant'), terms: ['home', 'assistant']),
      (pattern: RegExp(r'رازبری|raspberry'), terms: ['raspberry', 'pi']),
      (pattern: RegExp(r'سنسور|حسگر|sensor'), terms: ['sensor']),
      (pattern: RegExp(r'زیگبی|zigbee'), terms: ['zigbee']),
      (pattern: RegExp(r'دریمی|dreame'), terms: ['dreame']),
    ];
    final species = RegExp(
      r'بادام|گردو|انجیر|almond|walnut|\bfig\b',
    ).hasMatch(q);
    for (final item in entries) {
      // Generic "tree/plant" produces false title-only positives for a
      // question about a named tree. Keep the plant species as the anchor.
      if (species &&
          item.terms.contains('tree') &&
          item.terms.contains('plant')) {
        continue;
      }
      if (item.pattern.hasMatch(q)) terms.addAll(item.terms);
    }
    if (terms.isEmpty) return null;
    // Favor domain-specific nouns to source-instruction boilerplate. Qwen is
    // not invoked just to translate these common questions.
    for (final word in latin) {
      if (terms.length >= 10) break;
      if (species &&
          const {'tree', 'trees', 'plant', 'gardening'}.contains(word)) {
        continue;
      }
      if (_englishTopicTerms.contains(word)) terms.add(word);
    }
    return terms.take(12).join(' ');
  }

  static const _englishStop = <String>{
    'the', 'and', 'are', 'what', 'how', 'with', 'for', 'from',
    'that', 'this', 'only', 'search', 'source', 'local', 'offline',
    'archive', 'please', 'cite', 'evidence', 'relevant', 'provided',
    'where', 'when', 'which', 'should', 'could', 'find', 'best',
    'way', 'your', 'own', 'use', 'not', 'into', 'without',
  };
  static const _englishTopicTerms = <String>{
    'frost', 'fig', 'almond', 'walnut', 'winter', 'autumn', 'cold',
    'protect', 'protection', 'tree', 'trees', 'soil', 'pruning',
    'gardening', 'watering', 'irrigation', 'historic', 'travel',
    'tourism', 'isfahan', 'shiraz', 'zigbee', 'sensor', 'sensors',
    'raspberry', 'assistant', 'home', 'automation', 'temperature',
  };

  static Future<String?> englishTerms(
    String question, {
    required LlamaEngine engine,
    required InferenceSettings settings,
    required String fallbackTemplate,
    required bool Function() cancelled,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (question.trim().isEmpty || question.length > 2000 || cancelled())
      return null;
    if (!RegExp(r'[\u0600-\u06ff]').hasMatch(question)) return question.trim();
    if (timeout <= Duration.zero)
      throw ArgumentError('Invalid translation timeout');
    final result = StringBuffer();
    final clock = Stopwatch()..start();
    try {
      final output = engine
          .generate(
            messages: [
              {
                'role': 'system',
                'content': 'Translate the user question into a short English search query. Output only the search terms, no explanation or answer.',
              },
              {'role': 'user', 'content': question},
            ],
            fallbackTemplate: fallbackTemplate,
            settings: settings.copyWith(
              remoteEnabled: false,
              thinkingModeEnabled: false,
              maxTokens: 48,
              temperature: 0,
            ),
          )
          .timeout(
            timeout,
            onTimeout: (sink) {
              engine.cancel();
              sink.addError(
                TimeoutException('Local query translation timed out'),
              );
              sink.close();
            },
          );
      await for (final chunk in output) {
        if (cancelled() ||
            clock.elapsed > timeout ||
            result.length + chunk.length > 1024) {
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
    final words = RegExp(r'[A-Za-z0-9]+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((w) => w.length > 1)
        .take(12)
        .toList();
    return words.isEmpty ? null : words.join(' ');
  }
}
