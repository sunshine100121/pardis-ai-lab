import 'evidence.dart';
import 'claim_passages.dart';

/// Citations for an answer written from sources that cites none: small
/// models drop the [n] markers (phone, 2026-10-04: the WHO pandemic date,
/// right and from five sources, cited none of them). Each sentence gets the
/// source that shares most of its words and holds every figure it states;
/// a sentence no source supports stays uncited. Code, tables and headings
/// are left as written.
class CitationMatch {
  static final _marker = RegExp(r'\[[0-9۰-۹٠-٩]+(?:\s*,\s*[0-9۰-۹٠-٩]+)*\]');
  // Not inside "the U.S. is": a lowercase word goes on the sentence
  // (phone, 2026-10-08: "in the U.S [1]. is $499.99").
  static final _sentence = RegExp(
    r'(?<=[.!?])\s+(?=[\p{Lu}\p{Lt}\p{Lo}\p{N}*"(])',
    unicode: true,
  );
  static final _tail = RegExp(r'([.!?:;]*[*_)"]*)\s*$');

  /// Fewest content words a sentence needs before it is matched.
  static const minWords = 3;

  static bool hasCitations(String answer) => _marker.hasMatch(answer);

  /// A model citation is valid only when actual fetched evidence has its ID.
  /// Keep Markdown code examples unchanged.
  static String stripUnknown(String answer, int sourceCount) {
    if (sourceCount < 0) throw ArgumentError('Invalid source count');
    final marker = RegExp(r'\[([0-9۰-۹٠-٩]+(?:\s*,\s*[0-9۰-۹٠-٩]+)*)\]');
    var code = false;
    final lines = answer.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('```')) {
        code = !code;
        continue;
      }
      if (code) continue;
      lines[i] = lines[i].replaceAllMapped(marker, (match) {
        final valid = <int>{};
        for (final part in match.group(1)!.split(',')) {
          final ascii = String.fromCharCodes([
            for (final rune in part.trim().runes)
              if (rune >= 0x06f0 && rune <= 0x06f9)
                rune - 0x06f0 + 48
              else if (rune >= 0x0660 && rune <= 0x0669)
                rune - 0x0660 + 48
              else
                rune,
          ]);
          final number = int.tryParse(ascii);
          if (number != null && number > 0 && number <= sourceCount) {
            valid.add(number);
          }
        }
        return valid.isEmpty ? '' : '[' + valid.join(', ') + ']';
      });
    }
    return lines.join('\n');
  }

  /// A citation's number must point to evidence that supports its sentence.
  /// A plausible-looking in-range number alone is not proof. Verify the
  /// claim against all supplied passages and attach only the best supported
  /// source. Claims lacking a supporting passage stay visibly uncited.
  static String verifyEvidence(String answer, List<String> sources) {
    if (sources.isEmpty) return stripUnknown(answer, 0);
    final prepared = ClaimPassages.prepare(sources);
    final lines = answer.split('\n');
    var code = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        code = !code;
        continue;
      }
      if (code || line.trimLeft().startsWith('|')) continue;
      lines[i] = line
          .split(_sentence)
          .map((sentence) {
            if (!_marker.hasMatch(sentence)) return sentence;
            final plain = sentence.replaceAll(_marker, '').trim();
            final supported = EvidenceRanker.terms(plain).length >= minWords
                ? ClaimPassages.best(plain, prepared)
                : null;
            final verified = supported != null && supported.states
                ? '[' + (supported.source + 1).toString() + ']'
                : '';
            // One claim has one evidence decision: multiple model markers must\n        // not multiply the same verified citation.\n        var inserted = false;\n        return sentence.replaceAllMapped(_marker, (_) {\n          if (inserted || verified.isEmpty) return '';\n          inserted = true;\n          return verified;\n        });
          })
          .join(' ');
    }
    return lines.join('\n');
  }

  /// [answer] with " [n]" after each sentence a source of [sources]
  /// supports, numbered from 1 in [sources] order. Unchanged when the
  /// answer already cites or nothing matches; with [fill], an answer that
  /// cites only some sentences gets the uncited ones matched too.
  static String attach(
    String answer,
    List<String> sources, {
    bool fill = false,
  }) {
    if (sources.isEmpty || (!fill && hasCitations(answer))) return answer;
    final prepared = ClaimPassages.prepare(sources);
    final lines = answer.split('\n');
    var code = false;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trimLeft();
      if (trimmed.startsWith('```')) {
        code = !code;
        continue;
      }
      if (code || trimmed.startsWith('|') || trimmed.startsWith('#')) continue;
      lines[i] = lines[i]
          .split(_sentence)
          .map((s) => _marker.hasMatch(s) ? s : _cite(s, prepared))
          .join(' ');
    }
    return lines.join('\n');
  }

  static String _cite(String sentence, List<Object> prepared) {
    final words = EvidenceRanker.terms(sentence).toSet();
    if (words.length < minWords) return sentence;
    final match = ClaimPassages.best(sentence, prepared);
    if (match == null || !match.states) return sentence;
    final tail = _tail.firstMatch(sentence)!;
    return '${sentence.substring(0, tail.start)} [${match.source + 1}]${tail[1]}';
  }
}
