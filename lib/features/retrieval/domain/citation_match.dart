import 'evidence.dart';
import 'claim_passages.dart';

/// The app's provenance decision, never a citation number supplied by Qwen.
class CitationDecision {
  const CitationDecision({
    required this.text,
    required this.verifiedClaims,
    required this.internalClaims,
    required this.unverifiedClaims,
    required this.caution,
  });

  final String text;
  final int verifiedClaims;
  final int internalClaims;
  final int unverifiedClaims;
  final bool caution;

  bool get insufficientEvidence =>
      unverifiedClaims > 0 || (verifiedClaims == 0 && internalClaims > 0);

  Map<String, dynamic> toJson() => {
    'verified': verifiedClaims,
    'internal': internalClaims,
    'unverified': unverifiedClaims,
    'insufficient': insufficientEvidence,
    'caution': caution,
  };
}

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

  /// The final display contract is rebuilt from fetched page bodies, never
  /// from model-authored [1], [2], [۰] or plausible in-range numbers. Supply
  /// an empty string for an unread/snippet-only source to preserve numbering.
  /// This is a conservative lexical check, not a semantic truth certificate.
  static CitationDecision appControlled(
    String answer,
    List<String> fetchedEvidence, {
    bool labelModelKnowledge = true,
    bool sensitiveAdvice = false,
  }) {
    final prepared = ClaimPassages.prepare(fetchedEvidence);
    var verified = 0, internal = 0, unverified = 0;
    final out = <String>[];
    var inCodeFence = false;
    final boundary = RegExp(
      r'(?<=[.!?؟])\s+(?=[\p{L}\p{N}*"(])',
      unicode: true,
    );
    for (final line in answer.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        inCodeFence = !inCodeFence;
        out.add(line);
        continue;
      }
      if (inCodeFence) {
        out.add(line);
        continue;
      }
      final headingsOrTables =
          trimmed.startsWith('|') ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('---');
      final items = <String>[];
      for (final sentence in line.split(boundary)) {
        final plain = _withoutModelMarkers(sentence);
        if (plain.trim().isEmpty || headingsOrTables) {
          items.add(plain);
          continue;
        }
        final tokens = EvidenceRanker.terms(plain).toSet();
        if (tokens.length < minWords) {
          items.add(plain);
          continue;
        }
        final match = ClaimPassages.best(plain, prepared);
        if (match != null &&
            match.states &&
            fetchedEvidence[match.source].trim().isNotEmpty) {
          verified++;
          items.add(_insertNumber(plain, '[${match.source + 1}]'));
        } else {
          unverified++;
          if (labelModelKnowledge) {
            internal++;
            items.add(_insertNumber(plain, '[۰]'));
          } else {
            items.add(plain);
          }
        }
      }
      out.add(items.join(' '));
    }
    final caution = sensitiveAdvice && unverified > 0;
    var text = out.join('\n');
    if (caution) {
      text +=
          '\n\n⚠️ برای اقدام حساس، این بخش پاسخ شاهد کافی ندارد؛ '
          'پیش از تغییر یا اجرای توصیه، آن را با منبع معتبر یا متخصص بررسی کنید.';
    }
    return CitationDecision(
      text: text,
      verifiedClaims: verified,
      internalClaims: internal,
      unverifiedClaims: unverified,
      caution: caution,
    );
  }

  /// [n] in inline code is an example or array index, not a source marker.
  /// Only standalone model-written numeric markers outside code are removed.
  static String _withoutModelMarkers(String sentence) {
    final marker = RegExp(r'\[\s*[0-9۰-۹٠-٩]+(?:\s*[,،]\s*[0-9۰-۹٠-٩]+)*\s*\]');
    final inline = RegExp(r'`[^`\n]*`');
    final out = StringBuffer();
    var at = 0;
    for (final code in inline.allMatches(sentence)) {
      out.write(sentence.substring(at, code.start).replaceAll(marker, ''));
      out.write(code[0]);
      at = code.end;
    }
    out.write(sentence.substring(at).replaceAll(marker, ''));
    return out
        .toString()
        .replaceAll(RegExp(r' {2,}'), ' ')
        .replaceAllMapped(RegExp(r'\s+([.!?؟،؛])'), (match) => match.group(1)!)
        .trimRight();
  }

  static String _insertNumber(String sentence, String number) {
    final tail = _tail.firstMatch(sentence);
    if (tail == null) return '$sentence $number';
    final before = sentence.substring(0, tail.start).trimRight();
    return '$before $number${tail.group(1) ?? ''}';
  }

  /// A narrow, conservative warning for actionable medical, electrical,
  /// toxic-chemical or financial guidance; never call unsupported advice safe.
  static bool sensitiveRecommendation(String question) {
    final topic = RegExp(
      r'(دارو|درمان|دوز|سمپاش|سم\s|آفت.?کش|ولتاژ|برق|اینورتر|باتری|'
      r'اتصال سیم|سرمایه.?گذاری|ترید|medical|medication|dosage|'
      r'voltage|wiring|battery|poison|investment)',
      caseSensitive: false,
    );
    final action = RegExp(
      r'(چطور|چگونه|باید|مقدار|چه\s*قدر|روش|تنظیم|تغییر|قطع|وصل|'
      r'استفاده|درمان|مصرف|توصیه|انجام|چه\s*کنم|how|should|'
      r'amount|adjust|change|dose|recommend|use|take)',
      caseSensitive: false,
    );
    return topic.hasMatch(question) && action.hasMatch(question);
  }

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
            // One claim has one evidence decision: multiple model markers must
            // not multiply the same verified citation.
            var inserted = false;
            return sentence.replaceAllMapped(_marker, (_) {
              if (inserted || verified.isEmpty) return '';
              inserted = true;
              return verified;
            });
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
