import 'package:flutter_test/flutter_test.dart';
import 'package:ondevice_llm/features/voice/persian_stt_quality.dart';

void main() {
  test(
    'Persian Arabic yeh, kaf, diacritics, punctuation and numbers normalize',
    () {
      expect(
        PersianSttQuality.normalize('دَمَاي باغ، ۱۲ و ٢!'),
        'دمای باغ 12 و 2',
      );
      expect(PersianSttQuality.wordErrorRate('كيف؟', 'کیف'), 0);
      expect(PersianSttQuality.wordErrorRate('خاکِ رزماری', 'خاک رزماری'), 0);
    },
  );

  test('same colloquial utterance has zero word errors', () {
    const phrase = 'رطوبت خاک رزماری چطوره؟';
    expect(PersianSttQuality.wordErrorRate(phrase, phrase), 0);
  });

  test(
    'recognition errors include substitutions, deletions and insertions',
    () {
      expect(
        PersianSttQuality.wordErrorRate('الف ب ج', 'الف'),
        closeTo(2 / 3, 0.00001),
      );
      expect(PersianSttQuality.wordErrorRate('الف ب', 'الف چیز'), 0.5);
      expect(PersianSttQuality.wordErrorRate('الف', 'الف ب ج'), 2);
    },
  );

  test('an empty reference never fabricates a quality score', () {
    expect(PersianSttQuality.wordErrorRate('   ', 'تشخیص'), isNull);
    expect(PersianSttQuality.wordErrorRate('آب', ''), 1);
    expect(
      PersianSttQuality.benchmarkUtterances.length,
      greaterThanOrEqualTo(5),
    );
  });
}
