/// Offline-only local evaluation; no guessed STT accuracy is reported.
/// Local, deterministic evaluation of a Persian STT transcript.
/// WER = edit errors / reference words. It can exceed 100% on insertions;
/// it must not be silently clamped or mistaken for a model accuracy claim.
abstract final class PersianSttQuality {
  static const benchmarkUtterances = [
    'دمای باغ الان چند درجه است؟',
    'رطوبت خاک رزماری چطوره؟',
    'لامپ آشپزخونه رو روشن کن',
    'آب مخزن الان چقدره؟',
    'فردا بارون میاد یا نه؟',
  ];

  static String normalize(String input) {
    final digits = '۰۱۲۳۴۵۶۷۸۹';
    final arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    final fixed = input.toLowerCase()
        .replaceAll('ي', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll('ة', 'ه')
        .replaceAll('ۀ', 'ه')
        .replaceAll(RegExp(r'[\u064b-\u065f\u0670\u0640]'), '')
        .replaceAll(RegExp(r'[\u200c\u200d]'), ' ')
        .replaceAllMapped(RegExp(r'[۰-۹٠-٩]'), (match) {
          final digit = match.group(0)!;
          final i = digits.indexOf(digit);
          return (i >= 0 ? i : arabicDigits.indexOf(digit)).toString();
        })
        .replaceAll(RegExp(r'[،؛؟!.,:;«»()\[\]\/\-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return fixed;
  }

  static List<String> words(String input) {
    final normalized = normalize(input);
    return normalized.isEmpty ? const [] : normalized.split(' ');
  }

  static int substitutionsInsertionsDeletions(
    List<String> reference,
    List<String> recognized,
  ) {
    var previous = List<int>.generate(recognized.length + 1, (i) => i);
    for (var row = 1; row <= reference.length; row++) {
      final next = List<int>.filled(recognized.length + 1, 0);
      next[0] = row;
      for (var col = 1; col <= recognized.length; col++) {
        final replace = previous[col - 1] +
            (reference[row - 1] == recognized[col - 1] ? 0 : 1);
        final insert = next[col - 1] + 1;
        final delete = previous[col] + 1;
        next[col] = [replace, insert, delete].reduce(
          (a, b) => a < b ? a : b,
        );
      }
      previous = next;
    }
    return previous.last;
  }

  static double? wordErrorRate(String reference, String recognized) {
    final expected = words(reference);
    if (expected.isEmpty) return null;
    return substitutionsInsertionsDeletions(
      expected,
      words(recognized),
    ) / expected.length;
  }
}
